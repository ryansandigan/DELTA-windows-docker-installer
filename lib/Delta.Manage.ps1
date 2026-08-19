# =============================================================================
# Delta.Manage.ps1 - administrator credential reset
#
# Dot-source Delta.Common.ps1, Delta.Config.ps1, Delta.Docker.ps1 and
# Delta.Stack.ps1 first.
#
# Assessment references: A§20.2 (reuse the SQL, replace the transport),
# A§13 (this runs automatically during first install, before NGINX publishes
# host ports), A§24 (the seeded credential is published in a public image).
#
# This file holds the reset *primitive*. The management menu that will also
# call it is a later phase; nothing here draws a menu.
# =============================================================================

# The account the DELTA schema seeds. Its bcrypt hash ships inside a public
# image, which is why resetting it is the single most important security action
# this installer takes.
$Script:DeltaSeededAdminEmail = 'admin@admin.com'

# ---------------------------------------------------------------------------
# Prompts (adapted from the reference installer)
# ---------------------------------------------------------------------------

function Show-DeltaAdminResetConfirmation {
    <#
      The explicit confirmation gate, kept from the reference installer: there
      is deliberately no default, because resetting a live credential is
      significant enough that the operator types Y or nothing happens.

      Not used on the first-install path - there the reset is mandatory and
      unconditional, and asking "may I close the published-password hole?"
      would be a question with only one safe answer.
    #>
    param([Parameter(Mandatory)][string]$Email)

    while ($true) {
        Show-Section -Title 'Reset administrator credential'
        Write-Host 'This will replace the stored credential for:'
        Write-Host ''
        Write-Host "  $Email"
        Write-Host ''
        Write-Host 'Continue?'
        Write-Host ''
        Write-Host '  [Y] Yes'
        Write-Host '  [N] No'
        Write-Host ''
        $choice = Read-Host -Prompt 'Selection'

        switch ($choice.Trim().ToUpperInvariant()) {
            'Y' { return $true }
            'N' { return $false }
            default { Write-DeltaWarning "'$choice' is not a valid option." }
        }
    }
}

function Read-DeltaAdminResetMethod {
    <#
      How the new credential is chosen. Production operators generally want to
      set their own; an unattended or test installation is better served by a
      generated one, which is the default here because it is the safe answer
      when somebody presses Enter.
    #>
    param([switch]$AllowCancel)

    while ($true) {
        Write-Host ''
        Write-Host 'How would you like to set the new administrator credential?'
        Write-Host ''
        Write-Host '  1. Generate one for me (recommended - shown once, at the end)'
        Write-Host '  2. Type one now'
        if ($AllowCancel) { Write-Host '  3. Cancel' }
        Write-Host ''
        $choice = Read-Host -Prompt 'Selection [1]'
        if ([string]::IsNullOrWhiteSpace($choice)) { return 'Generate' }

        switch ($choice.Trim()) {
            '1' { return 'Generate' }
            '2' { return 'Manual' }
            '3' { if ($AllowCancel) { return 'Cancel' } }
        }
        Write-DeltaWarning "'$choice' is not a valid option."
    }
}

function Read-DeltaAdminNewPassword {
    <#
      Prompts twice and requires a match, so a typo does not silently become
      the administrator credential. Returned as a SecureString and converted to
      plain text only at the point it is actually needed - the same handling
      every other operator-typed credential in this project gets.
    #>
    while ($true) {
        $first  = Read-Host -Prompt 'Enter the new administrator password' -AsSecureString
        $second = Read-Host -Prompt 'Confirm the new administrator password' -AsSecureString

        $plainFirst  = ConvertTo-DeltaPlainText -SecureString $first
        $plainSecond = ConvertTo-DeltaPlainText -SecureString $second

        try {
            if ($plainFirst.Length -eq 0) {
                Write-DeltaWarning 'The password cannot be empty.'
                continue
            }
            if ($plainFirst.Length -lt 12) {
                Write-DeltaWarning 'Use at least 12 characters - this account administers every tenant in the installation.'
                continue
            }
            if ($plainFirst -cne $plainSecond) {
                Write-DeltaWarning 'The two entries did not match.'
                continue
            }
        }
        finally {
            $plainFirst  = $null
            $plainSecond = $null
        }

        return $first
    }
}

function ConvertTo-DeltaPlainText {
    <#
      SecureString to plain text, at the point it is genuinely needed. Uses
      NetworkCredential rather than manual Marshal calls - the standard,
      PowerShell 5.1-compatible idiom, adapted from the reference installer.
    #>
    param([Parameter(Mandatory)][SecureString]$SecureString)
    return [System.Net.NetworkCredential]::new('', $SecureString).Password
}

# ---------------------------------------------------------------------------
# The reset itself
# ---------------------------------------------------------------------------

function Get-DeltaAdminAccountState {
    <#
      Reads the administrator row without touching it - the read-only lookup
      the reference installer does first, so "the account does not exist" is
      reported precisely rather than as a failed update.

      Returns the row count and an md5 digest of the stored bcrypt hash. The
      digest, not the hash: it is enough to prove the stored credential changed
      and it is safe to print, whereas the hash itself is the credential
      material that is public in the image and should not be echoed around.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [string]$Email = $Script:DeltaSeededAdminEmail
    )

    $escaped = $Email.Replace("'", "''")
    $query = "select count(*)::text || '|' || coalesce(md5(max(password)), '') from public.super_admin_users where email = '$escaped';"

    $capture = Invoke-DeltaPsql -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName `
        -User $Configuration.PostgresUser -Database $Configuration.PostgresDb -Query $query -TuplesOnly

    $result = [PSCustomObject]@{
        Email      = $Email
        Found      = $false
        RowCount   = 0
        HashDigest = $null
        Error      = $null
    }

    if ($capture.ExitCode -ne 0) {
        $result.Error = (($capture.StdErr + ' ' + $capture.StdOut)).Trim()
        return $result
    }

    $line = ($capture.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($line -match '^(\d+)\|(.*)$') {
        $result.RowCount   = [int]$Matches[1]
        $result.HashDigest = $Matches[2]
        $result.Found      = ($result.RowCount -gt 0)
    }
    return $result
}

function Set-DeltaAdminPassword {
    <#
      Replaces the stored credential for one administrator account.

      The SQL is the reference installer's, unchanged in substance (A§20.2):

          \getenv password DELTA_ADMIN_NEW_PASSWORD
          UPDATE public.super_admin_users
             SET password = crypt(:'password', gen_salt('bf', 10))
           WHERE email = '<email>' RETURNING email;

      It is the same pgcrypto bcrypt call the schema itself seeds accounts
      with, so it changes what the stored hash is and never how the application
      verifies it. The \getenv indirection keeps the password out of the SQL
      text and out of psql's arguments.

      Only the transport changes. Instead of finding psql.exe on Windows and
      connecting over TCP, psql runs in the database container - and with it
      goes everything the native version needed for connectivity.

      The password reaches the container through an environment variable that
      is *inherited*, not written on a command line: `docker compose exec -e
      NAME` (no value) passes the caller's own variable through, so the
      credential never appears in any process's arguments on either side.
      Verified on this host. The SQL arrives on stdin via `psql -f -`, so it is
      never written to a file either.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][SecureString]$Password
    )

    $escaped = $Email.Replace("'", "''")
    $sql = @"
\getenv password DELTA_ADMIN_NEW_PASSWORD
UPDATE public.super_admin_users SET password = crypt(:'password', gen_salt('bf', 10)) WHERE email = '$escaped' RETURNING email;
"@

    $composeFile = Join-Path -Path $InstallRoot -ChildPath 'docker-compose.yml'
    $envFile     = Join-Path -Path $InstallRoot -ChildPath '.env'

    $arguments = @(
        'compose'
        '--project-name', $Configuration.ProjectName
        '--project-directory', $InstallRoot
        '--file', $composeFile
        '--env-file', $envFile
        'exec', '-T'
        '-e', 'DELTA_ADMIN_NEW_PASSWORD'
        'db'
        'psql', '-U', $Configuration.PostgresUser, '-d', $Configuration.PostgresDb
        '--set', 'ON_ERROR_STOP=on', '--tuples-only', '--no-align', '--quiet'
        '-f', '-'
    )

    $previous = $env:DELTA_ADMIN_NEW_PASSWORD
    $capture = $null
    try {
        $plain = ConvertTo-DeltaPlainText -SecureString $Password
        # Registered before the value can reach any external process, so even
        # output this installer did not format itself is redacted on its way to
        # the transcript.
        Register-DeltaSecretValue -Value $plain
        $env:DELTA_ADMIN_NEW_PASSWORD = $plain
        $plain = $null

        $capture = Invoke-DeltaDockerCommand -Arguments $arguments -TimeoutSeconds 120 -StandardInput $sql
    }
    finally {
        if ($null -eq $previous) { Remove-Item Env:\DELTA_ADMIN_NEW_PASSWORD -ErrorAction SilentlyContinue }
        else { $env:DELTA_ADMIN_NEW_PASSWORD = $previous }
    }

    $result = [PSCustomObject]@{ Succeeded = $false; UpdatedEmails = @(); Error = $null }

    if ($capture.ExitCode -ne 0) {
        $result.Error = (($capture.StdErr + "`n" + $capture.StdOut)).Trim()
        return $result
    }

    # RETURNING email is the point: exit code 0 only says psql ran, while the
    # returned rows say which account actually changed.
    $result.UpdatedEmails = @($capture.StdOut -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($result.UpdatedEmails.Count -ne 1) {
        $result.Error = "The update affected $($result.UpdatedEmails.Count) row(s) instead of exactly one. Refusing to report success for an ambiguous update."
        return $result
    }
    if ($result.UpdatedEmails[0] -ne $Email) {
        $result.Error = "The update returned '$($result.UpdatedEmails[0])' rather than '$Email'."
        return $result
    }

    $result.Succeeded = $true
    return $result
}

function Test-DeltaAdminPassword {
    <#
      Confirms that a candidate password verifies against what is now stored,
      using pgcrypto's own comparison - `password = crypt(candidate, password)`
      is exactly how a bcrypt credential is checked.

      This is what turns "psql exited 0" into evidence: it proves the stored
      hash accepts the new credential. The candidate travels the same way the
      reset did, through an inherited environment variable and stdin, so it
      never appears in an argument list.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][SecureString]$Password
    )

    $escaped = $Email.Replace("'", "''")
    $sql = @"
\getenv candidate DELTA_ADMIN_NEW_PASSWORD
SELECT (password = crypt(:'candidate', password)) FROM public.super_admin_users WHERE email = '$escaped';
"@

    $composeFile = Join-Path -Path $InstallRoot -ChildPath 'docker-compose.yml'
    $envFile     = Join-Path -Path $InstallRoot -ChildPath '.env'

    $arguments = @(
        'compose'
        '--project-name', $Configuration.ProjectName
        '--project-directory', $InstallRoot
        '--file', $composeFile
        '--env-file', $envFile
        'exec', '-T'
        '-e', 'DELTA_ADMIN_NEW_PASSWORD'
        'db'
        'psql', '-U', $Configuration.PostgresUser, '-d', $Configuration.PostgresDb
        '--set', 'ON_ERROR_STOP=on', '--tuples-only', '--no-align', '--quiet'
        '-f', '-'
    )

    $previous = $env:DELTA_ADMIN_NEW_PASSWORD
    $capture = $null
    try {
        $plain = ConvertTo-DeltaPlainText -SecureString $Password
        Register-DeltaSecretValue -Value $plain
        $env:DELTA_ADMIN_NEW_PASSWORD = $plain
        $plain = $null
        $capture = Invoke-DeltaDockerCommand -Arguments $arguments -TimeoutSeconds 120 -StandardInput $sql
    }
    finally {
        if ($null -eq $previous) { Remove-Item Env:\DELTA_ADMIN_NEW_PASSWORD -ErrorAction SilentlyContinue }
        else { $env:DELTA_ADMIN_NEW_PASSWORD = $previous }
    }

    if ($capture.ExitCode -ne 0) {
        return [PSCustomObject]@{ Verified = $false; Error = (($capture.StdErr + ' ' + $capture.StdOut)).Trim() }
    }

    $line = ($capture.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    return [PSCustomObject]@{ Verified = ($line -eq 't'); Error = $null }
}

function Invoke-DeltaAdminPasswordReset {
    <#
      Replaces the seeded administrator credential and proves it worked.

      Two modes:

        -Automatic  the first-install security bootstrap. No confirmation gate -
                    the reset is mandatory, and asking permission to close a
                    published-credential hole would be a question with one safe
                    answer. The operator still chooses generate-or-type when the
                    run is interactive.

        (default)   the operator-initiated path, with the reference installer's
                    confirmation gate and a Cancel option.

      The order is the reference installer's: read-only lookup first, so a
      missing or ambiguous account is reported precisely and nothing is touched;
      then the method choice; then the update; then verification.

      Success is never inferred from an exit code. Three things must hold: the
      UPDATE returned exactly the intended account, the stored hash digest
      changed, and the new credential verifies against what is now stored.

      The password is returned to the caller (as a SecureString) so the
      completion summary can show a generated one exactly once. It is never
      written to .env, to the state file, or to the transcript.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [string]$Email = $Script:DeltaSeededAdminEmail,
        [switch]$Automatic,
        [bool]$AllowPrompt = $true,
        [SecureString]$NewPassword
    )

    $result = [PSCustomObject]@{
        Succeeded      = $false
        Cancelled      = $false
        Email          = $Email
        Method         = $null
        Password       = $null
        WasGenerated   = $false
        HashChanged    = $false
        Verified       = $false
        Reason         = $null
    }

    if (-not $Automatic) {
        if (-not (Show-DeltaAdminResetConfirmation -Email $Email)) {
            $result.Cancelled = $true
            $result.Reason = 'The operator declined.'
            return $result
        }
    }

    Write-Step 'Securing the administrator account'

    # --- read-only lookup, before anything is touched ---------------------
    $before = Get-DeltaAdminAccountState -InstallRoot $InstallRoot -Configuration $Configuration -Email $Email
    if ($before.Error) {
        $result.Reason = "The administrator account could not be read: $($before.Error)"
        return $result
    }
    if (-not $before.Found) {
        $result.Reason = "The administrator account '$Email' does not exist in this database. The schema may not have loaded as expected."
        return $result
    }
    if ($before.RowCount -gt 1) {
        $result.Reason = "Expected exactly one account for '$Email' but found $($before.RowCount). Refusing to continue with an ambiguous match."
        return $result
    }
    Write-Detail "Found the seeded administrator account $Email."

    # --- choose the new credential ----------------------------------------
    if ($NewPassword) {
        $result.Method = 'Supplied'
        $password = $NewPassword
    }
    else {
        $method = 'Generate'
        if ($AllowPrompt) {
            $method = Read-DeltaAdminResetMethod -AllowCancel:(-not $Automatic)
        }
        if ($method -eq 'Cancel') {
            $result.Cancelled = $true
            $result.Reason = 'The operator cancelled.'
            return $result
        }
        if ($method -eq 'Manual') {
            $result.Method = 'Typed'
            $password = Read-DeltaAdminNewPassword
        }
        else {
            $result.Method = 'Generated'
            $result.WasGenerated = $true
            # The same CSPRNG the rest of the installation's secrets come from.
            $plain = New-DeltaPassword -Length 20
            $password = ConvertTo-SecureString -String $plain -AsPlainText -Force
            $plain = $null
        }
    }

    # --- update -----------------------------------------------------------
    $update = Set-DeltaAdminPassword -InstallRoot $InstallRoot -Configuration $Configuration -Email $Email -Password $password
    if (-not $update.Succeeded) {
        $result.Reason = "The administrator credential could not be updated: $($update.Error)"
        return $result
    }

    # --- prove it ---------------------------------------------------------
    $after = Get-DeltaAdminAccountState -InstallRoot $InstallRoot -Configuration $Configuration -Email $Email
    $result.HashChanged = ($after.HashDigest -and $before.HashDigest -and $after.HashDigest -ne $before.HashDigest)

    $verify = Test-DeltaAdminPassword -InstallRoot $InstallRoot -Configuration $Configuration -Email $Email -Password $password
    $result.Verified = $verify.Verified

    if (-not $result.HashChanged) {
        $result.Reason = 'The stored credential did not change. Refusing to report the account as secured.'
        return $result
    }
    if (-not $result.Verified) {
        $result.Reason = "The new credential does not verify against the stored hash. $($verify.Error)"
        return $result
    }

    Write-Detail "[ ok ]     stored credential replaced for $Email"
    Write-Detail '[ ok ]     the published default credential no longer authenticates'
    Write-Detail '[ ok ]     the new credential verifies against the stored hash'

    $result.Password  = $password
    $result.Succeeded = $true
    return $result
}

# ---------------------------------------------------------------------------
# Start DELTA (A§16.3 Layer 4, Phase 6)
#
# One operation that takes an installed-but-not-running DELTA to a reachable
# one. It is what the startup task runs after a reboot, and what Phase 7's
# menu entry will call - the same code path either way, so that manual
# recovery and automatic recovery cannot behave differently.
#
# Everything it does is already owned by something else: the engine by
# Delta.Docker.ps1, the persistent-data precheck and the ordered, health-gated
# startup by Delta.Stack.ps1. This function sequences them and reports; it
# reimplements none of them, and it supervises nothing - it runs once and
# returns.
# ---------------------------------------------------------------------------

function Start-DeltaInstallation {
    <#
      Starts Docker if it is not running, waits for the Linux engine, checks
      that the database volume is still there, brings the stack up in order
      with health gating, and verifies that DELTA answers over HTTP.

      Returns Succeeded, a Stage naming where it got to, and a Reason. The
      stages are deliberately named after the things an operator would have to
      diagnose: configuration, engine, precheck, stack, verify.

      What it will not do, by construction:
        - it never runs the security bootstrap (no -SecurityBootstrap is
          passed), because the credential of an existing installation is not
          this operation's business;
        - it never generates or rewrites .env, docker-compose.yml or the NGINX
          configuration - it reads the configuration that is already there;
        - it never pulls, never updates an image pin, never touches a volume,
          and has no path to `docker compose down` in any form.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [int]$EngineTimeoutSeconds = $Script:DeltaEngineStartTimeoutSeconds,
        [switch]$SkipEngineStart
    )

    $result = [PSCustomObject]@{
        Succeeded     = $false
        Stage         = 'configuration'
        Reason        = $null
        Configuration = $null
        Engine        = $null
        EngineStarted = $false
        Precheck      = $null
        Start         = $null
        Url           = $null
        Elapsed       = $null
    }
    $started = Get-Date

    # --- configuration ----------------------------------------------------
    $state = Read-DeltaInstallState -InstallRoot $InstallRoot
    if (-not $state.Exists) {
        $result.Reason = "There is no DELTA installation registered at '$InstallRoot' ($($state.Path) does not exist). Nothing was started."
        return $result
    }
    if (-not $state.IsValid) {
        $result.Reason = "The installation state at '$InstallRoot' could not be read: $($state.Error). Nothing was started."
        return $result
    }

    $configuration = Get-DeltaStackConfiguration -InstallRoot $InstallRoot
    if (-not $configuration) {
        $result.Reason = "'$InstallRoot' has no .env, so there is no configuration to start from. Nothing was started."
        return $result
    }
    $result.Configuration = $configuration
    Write-Step "Starting DELTA in $InstallRoot"
    Write-Detail "Compose project $($configuration.ProjectName), data volume $($configuration.PgDataVolume)"

    # --- engine -----------------------------------------------------------
    $result.Stage = 'engine'
    $engine = Get-DeltaDockerEngineState
    $result.Engine = $engine

    if ($engine.Status -ne 'ready' -and -not $SkipEngineStart) {
        Write-Detail "The Docker engine is not ready ($($engine.Status)). Starting Docker Desktop."
        $engine = Start-DeltaDockerEngine -TimeoutSeconds $EngineTimeoutSeconds
        $result.Engine = $engine
        $result.EngineStarted = ($engine.Status -eq 'ready')
    }

    if ($engine.Status -ne 'ready') {
        $result.Reason = "The Docker engine did not become available (state: $($engine.Status)). $(if ($engine.RawError) { $engine.RawError } else { $engine.Detail })"
        return $result
    }
    Write-Detail "[ ok ]     Docker engine $($engine.ServerVersion), $($engine.OSType) containers, backend $($engine.Backend)"

    # --- persistent data ---------------------------------------------------
    # Before `up`, always. If the volume has gone, starting the stack would
    # initialise an empty cluster and DELTA would build a brand-new schema -
    # the installation would come back up looking healthy with all data gone
    # (A§9.4). After an unattended boot, with nobody watching, that is the
    # single worst thing this operation could do.
    $result.Stage = 'precheck'
    $result.Precheck = Test-DeltaPersistentDataPrecheck -InstallRoot $InstallRoot -Configuration $configuration
    if (-not $result.Precheck.Succeeded) {
        $result.Reason = $result.Precheck.Reason
        return $result
    }

    # --- the stack ---------------------------------------------------------
    $result.Stage = 'stack'
    $result.Start = Start-DeltaStack -InstallRoot $InstallRoot -Configuration $configuration -AllowPrompt $false
    if (-not $result.Start.Succeeded) {
        $result.Stage = $result.Start.Stage
        $result.Reason = $result.Start.Reason
        return $result
    }

    $result.Stage = 'verify'
    $result.Url = $result.Start.Http.Url
    $result.Elapsed = [int]((Get-Date) - $started).TotalSeconds
    $result.Succeeded = $true
    Write-Success "DELTA answered HTTP $($result.Start.Http.StatusCode) at $($result.Url) after $($result.Elapsed)s."
    return $result
}
