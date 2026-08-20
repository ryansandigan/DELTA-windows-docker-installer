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

# ===========================================================================
# Phase 7 - management mode
#
# Rerunning setup.ps1 on a registered installation opens this instead of the
# installer (A§17.1): the mode is chosen from the detected state, never from a
# switch. Nothing in this section generates configuration, pulls an image,
# regenerates a secret, or removes a container, a network or a volume - the
# management utility acts on an installation that already exists and leaves
# everything persistent exactly as it found it.
# ===========================================================================

# The Compose services this installation owns, in the order they are reported
# and started (A§3).
$Script:DeltaManagedServices = @('db', 'delta', 'nginx')

# ---------------------------------------------------------------------------
# Status (A§17.3)
# ---------------------------------------------------------------------------

function Get-DeltaManagementStatus {
    <#
      Everything the status block shows, gathered once.

      The runtime half comes from exactly ONE `docker compose ps --format json`
      call per refresh (A§17.3), through Get-DeltaComposeServiceStatus - never
      one query per service. The configuration half comes from reading .env
      through Get-DeltaStackConfiguration, which reads and never writes: asking
      the generator what is configured would make reading the configuration a
      mutating act on the file that holds every secret.

      Reachability is measured, not inferred. Containers being up is not
      evidence that the application answers, so when NGINX is running the
      configured endpoint is actually requested and the result reported as it
      is. When NGINX is not running the endpoint is reported as untested rather
      than as unreachable, because those are different facts.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [switch]$SkipEndpointProbe
    )

    $status = [PSCustomObject]@{
        InstallRoot   = $InstallRoot
        State         = $null
        StateFile     = $null
        Configuration = $null
        Engine        = $null
        DockerReady   = $false
        Services      = @()
        ServiceRows   = @()
        RunningCount  = 0
        Unhealthy     = @()
        Missing       = @()
        AllRunning    = $false
        PublicUrl     = $null
        LoopbackUrl   = $null
        Endpoint      = $null
        Startup       = $null
        StartupTask   = $null
        Backups       = $null
    }

    $status.Configuration = Get-DeltaStackConfiguration -InstallRoot $InstallRoot

    $engine = Get-DeltaDockerEngineState
    $status.Engine = $engine
    $status.DockerReady = ($engine.Status -eq 'ready')

    # The one Compose query. It is skipped entirely when the engine is not
    # usable, because a failing query would produce no information and a
    # misleading delay.
    if ($status.DockerReady -and $status.Configuration) {
        $status.Services = @(Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $status.Configuration.ProjectName)
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($service in $Script:DeltaManagedServices) {
        $observed = $status.Services | Where-Object { $_.Service -eq $service } | Select-Object -First 1
        $row = [PSCustomObject]@{
            Service = $service
            State   = 'Unknown'
            Detail  = ''
            Health  = $null
            Warn    = $false
        }

        if (-not $status.DockerReady) {
            $row.State = 'Docker down'
            $row.Detail = 'not observable until the Docker engine is running'
            $row.Warn = $true
        }
        elseif (-not $observed) {
            $row.State = 'Missing'
            $row.Detail = 'no container exists for this service'
            $row.Warn = $true
            $status.Missing += $service
        }
        elseif ($observed.State -eq 'running') {
            $row.State = 'Running'
            $row.Health = $observed.Health
            $status.RunningCount++
            switch ($observed.Health) {
                'healthy'   { $row.Detail = 'healthy' }
                'unhealthy' { $row.Detail = 'UNHEALTHY - see View Logs (menu option 9)'; $row.Warn = $true; $status.Unhealthy += $service }
                'starting'  { $row.Detail = 'starting - the healthcheck has not passed yet' }
                default     { $row.Detail = if ($observed.Status) { $observed.Status } else { 'running; no health reported' } }
            }
        }
        else {
            $row.State = 'Stopped'
            $row.Detail = if ($observed.Status) { $observed.Status } else { $observed.State }
            $row.Warn = $true
        }
        $null = $rows.Add($row)
    }
    $status.ServiceRows = $rows.ToArray()
    $status.AllRunning = ($status.DockerReady -and $status.RunningCount -eq $Script:DeltaManagedServices.Count)

    # The classification A§28 defines, with the Docker evidence this function
    # has just gathered supplied to it.
    $dockerStatus = 'unknown'
    if (-not $status.DockerReady) { $dockerStatus = 'unavailable' }
    elseif ($status.RunningCount -eq 0) { $dockerStatus = 'stopped' }
    else { $dockerStatus = 'running' }

    $status.State = Get-DeltaInstallationState -InstallRoot $InstallRoot -DockerStatus $dockerStatus
    $status.StateFile = $status.State.StateFile

    if ($status.Configuration) {
        $scheme = if ($status.Configuration.TlsEnabled) { 'https' } else { 'http' }
        $port = if ($status.Configuration.TlsEnabled) { [int]$status.Configuration.HttpsPort } else { [int]$status.Configuration.HttpPort }
        $status.PublicUrl = Get-DeltaPublicUrl -Scheme $scheme -HostName $status.Configuration.HostName -Port $port
        # The probe always goes to loopback: it tests that this machine's
        # published port reaches DELTA, which is the claim the status block
        # makes. Whether a name resolves elsewhere is DNS's business, and
        # probing a hostname this host cannot resolve would report a working
        # installation as broken.
        $status.LoopbackUrl = Get-DeltaPublicUrl -Scheme $scheme -HostName 'localhost' -Port $port

        $nginxRow = $status.ServiceRows | Where-Object { $_.Service -eq 'nginx' } | Select-Object -First 1
        if (-not $SkipEndpointProbe -and $nginxRow -and $nginxRow.State -eq 'Running') {
            $status.Endpoint = Test-DeltaHttpEndpoint -Url ($status.LoopbackUrl + '/') -TimeoutSeconds 15
        }
    }

    # Phase 6's record, displayed and never re-measured here: "configured" and
    # "proven by a real restart" are different claims and stay different.
    $stateRead = Read-DeltaInstallState -InstallRoot $InstallRoot
    if ($stateRead.Exists -and $stateRead.IsValid -and (@($stateRead.Data.PSObject.Properties.Name) -contains 'unattendedStartup')) {
        $status.Startup = $stateRead.Data.unattendedStartup
    }
    if ($status.Configuration) {
        $status.StartupTask = Get-DeltaStartupTaskState -ProjectName $status.Configuration.ProjectName
    }

    # Filesystem only - no second Compose query, which would undo the one-query
    # rule this function exists to keep (A§17.3).
    $backups = @(Get-DeltaBackupFile -Directory (Get-DeltaBackupDirectory -InstallRoot $InstallRoot))
    $totalBytes = 0
    if ($backups.Count -gt 0) { $totalBytes = ($backups | Measure-Object -Property Length -Sum).Sum }
    $status.Backups = [PSCustomObject]@{
        Count      = $backups.Count
        Latest     = $(if ($backups.Count -gt 0) { $backups[0] } else { $null })
        TotalBytes = $totalBytes
    }

    return $status
}

function Write-DeltaStatusRow {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [AllowEmptyString()][string]$State,
        [AllowEmptyString()][string]$Detail,
        [string]$Colour
    )

    # PadRight plus an explicit separator, not PadRight alone: a state value
    # longer than the column ('docker-unavailable') would otherwise run
    # straight into the detail with no space between them.
    $text = '  {0}{1} {2}' -f $Label.PadRight(15), $State.PadRight(13), $Detail
    if ($Colour) { Write-Host $text.TrimEnd() -ForegroundColor $Colour }
    else { Write-Host $text.TrimEnd() }
    Write-DeltaLogLine -Message ("status  {0} | {1} | {2}" -f $Label, $State, $Detail) -Level 'DETAIL'
}

function Show-DeltaManagementStatus {
    <#
      The A§17.3 status block.

      When Docker is not running this does not print four rows of "Unknown":
      it says what is not observable and why, and then shows everything that IS
      known without Docker - where the installation is, what it is configured
      to serve, which images it is pinned to, and what happens after a restart.
    #>
    param([Parameter(Mandatory)][object]$Status)

    $configuration = $Status.Configuration
    Write-Host 'Status'

    $registered = ''
    if ($Status.StateFile -and $Status.StateFile.IsValid) {
        $data = $Status.StateFile.Data
        $bits = @()
        if (@($data.PSObject.Properties.Name) -contains 'installedAt' -and $data.installedAt) { $bits += "installed $($data.installedAt)" }
        if (@($data.PSObject.Properties.Name) -contains 'deltaSchemaVersion' -and $data.deltaSchemaVersion) { $bits += "DELTA schema $($data.deltaSchemaVersion)" }
        $registered = ($bits -join ', ')
    }
    Write-DeltaStatusRow -Label 'DELTA' -State $Status.State.State -Detail "$($Status.InstallRoot)  $registered"

    if ($Status.DockerReady) {
        Write-DeltaStatusRow -Label 'Docker' -State 'Running' -Detail "engine $($Status.Engine.ServerVersion), $($Status.Engine.OSType) containers, backend $($Status.Engine.Backend)"
    }
    else {
        $detail = switch ($Status.Engine.Status) {
            'cli-absent' { 'the docker CLI is not on PATH for this session' }
            'engine-down' { 'Docker Desktop is not running, so nothing in the stack can be reached' }
            'wrong-mode' { "Docker is in $($Status.Engine.OSType)-container mode; DELTA needs Linux containers" }
            default { $Status.Engine.Detail }
        }
        Write-DeltaStatusRow -Label 'Docker' -State 'Not running' -Detail $detail -Colour 'Yellow'
    }

    foreach ($row in $Status.ServiceRows) {
        $colour = if ($row.Warn) { 'Yellow' } else { $null }
        $detail = $row.Detail
        if ($row.Service -eq 'delta' -and $configuration -and $row.State -eq 'Running') {
            $image = $configuration.DeltaImageTag
            if ($configuration.DeltaImage -match 'sha256:([0-9a-f]{7})') { $image = "$image @$($Matches[1])" }
            if ($image) { $detail = "$detail   image $image" }
        }
        Write-DeltaStatusRow -Label $row.Service -State $row.State -Detail $detail -Colour $colour
    }

    if ($configuration) {
        Write-DeltaStatusRow -Label 'Access' -State '' -Detail $Status.PublicUrl
        if ($Status.Endpoint) {
            if ($Status.Endpoint.Succeeded) {
                Write-DeltaStatusRow -Label '' -State '' -Detail "reachable - GET $($Status.LoopbackUrl)/ returned HTTP $($Status.Endpoint.StatusCode)" -Colour 'Green'
            }
            elseif ($Status.Endpoint.Error) {
                Write-DeltaStatusRow -Label '' -State '' -Detail "NOT reachable - $($Status.Endpoint.Error)" -Colour 'Yellow'
            }
            else {
                Write-DeltaStatusRow -Label '' -State '' -Detail "NOT reachable - GET $($Status.LoopbackUrl)/ returned HTTP $($Status.Endpoint.StatusCode)" -Colour 'Yellow'
            }
        }
        else {
            Write-DeltaStatusRow -Label '' -State '' -Detail 'not tested - NGINX is not running, so nothing was requested'
        }
    }
    else {
        Write-DeltaStatusRow -Label 'Access' -State 'Unknown' -Detail "$($Status.InstallRoot)\.env could not be read" -Colour 'Yellow'
    }

    # Phase 6's distinction, preserved exactly: configured is not proven.
    if ($Status.Startup) {
        $mechanism = [string]$Status.Startup.mechanism
        if ([bool]$Status.Startup.rebootTested) {
            Write-DeltaStatusRow -Label 'Restart' -State 'Proven' -Detail "returns unattended via $mechanism; measured by a real restart"
        }
        elseif ([bool]$Status.Startup.configured) {
            Write-DeltaStatusRow -Label 'Restart' -State 'Configured' -Detail "$mechanism - CONFIGURED but NOT YET PROVEN by a real restart"
        }
        else {
            Write-DeltaStatusRow -Label 'Restart' -State 'Not set up' -Detail 'DELTA stays down after a restart until somebody signs in' -Colour 'Yellow'
        }
        if ($Status.StartupTask -and $Status.Startup.mechanism -eq 'startup-task' -and -not $Status.StartupTask.Exists) {
            Write-DeltaStatusRow -Label '' -State '' -Detail "the recorded startup task '$($Status.Startup.taskName)' no longer exists" -Colour 'Yellow'
        }
    }

    if ($Status.Backups) {
        if ($Status.Backups.Count -gt 0) {
            $latest = $Status.Backups.Latest
            Write-DeltaStatusRow -Label 'Backups' -State ([string]$Status.Backups.Count) `
                -Detail ("newest {0} ({1}), {2} on disk" -f $latest.Name, (Format-DeltaByteSize $latest.Length), (Format-DeltaByteSize $Status.Backups.TotalBytes))
        }
        else {
            Write-DeltaStatusRow -Label 'Backups' -State 'None' -Detail 'no database backup has been taken yet - menu option 2 takes one' -Colour 'Yellow'
        }
    }

    if (-not $Status.DockerReady) {
        Write-Host ''
        Write-Host 'Docker diagnostics'
        Write-Detail "docker CLI       $(if ($Status.Engine.Path) { $Status.Engine.Path } else { 'not found on PATH' })"
        Write-Detail "client version   $(if ($Status.Engine.ClientVersion) { $Status.Engine.ClientVersion } else { 'unknown' })"
        if ($Status.Engine.RawError) {
            foreach ($line in (@($Status.Engine.RawError -split "`r?`n") | Select-Object -First 4)) {
                if ($line.Trim()) { Write-Detail "  $line" }
            }
        }
        Write-Detail ''
        Write-Detail 'Nothing has been changed. Choose "Start DELTA" to start Docker Desktop and bring the'
        Write-Detail 'stack back up, or start Docker Desktop yourself and refresh this screen.'
        Write-Detail "Startup log      $($Status.InstallRoot)\logs\installer\startup.log"
    }
}

# ---------------------------------------------------------------------------
# Lifecycle: stop and restart
#
# Start is Phase 6's Start-DeltaInstallation, unchanged and uncopied: the menu
# entry and the startup task call the same function, so manual recovery and
# unattended recovery cannot drift apart.
# ---------------------------------------------------------------------------

function Stop-DeltaInstallation {
    <#
      `docker compose stop` for this installation's project, and nothing else.

      Not `down`, and never `down -v`. Stop is the least surprising reading of
      "Stop DELTA", it is reversible, and it removes no container, no network,
      no volume and no bind-mounted file (A§9.3). The command is scoped by
      --project-name, --project-directory, --file and --env-file, so it acts on
      this installation's three services and cannot reach another project.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [int]$TimeoutSeconds = 300
    )

    $result = [PSCustomObject]@{ Succeeded = $false; Reason = $null; Services = @() }

    Write-Step "Stopping DELTA (Compose project $($Configuration.ProjectName))"
    Write-Detail 'This stops the containers. Nothing is removed - not the containers, the network, the'
    Write-Detail 'data volume, the uploads, the certificates or the configuration.'

    $capture = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName `
        -Arguments @('stop') -TimeoutSeconds $TimeoutSeconds

    if ($capture.ExitCode -ne 0) {
        $result.Reason = "docker compose stop failed: $((($capture.StdErr + ' ' + $capture.StdOut)).Trim())"
        return $result
    }

    $result.Services = @(Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName)
    $running = @($result.Services | Where-Object { $_.State -eq 'running' })
    if ($running.Count -gt 0) {
        $result.Reason = "These services are still running after the stop: $((($running | ForEach-Object { $_.Service }) -join ', '))."
        return $result
    }

    $result.Succeeded = $true
    Write-Success 'DELTA is stopped.'
    return $result
}

function Restart-DeltaInstallation {
    <#
      Stop, then start - composed from the two primitives that already exist
      rather than a third lifecycle implementation.

      Because the start half is Start-DeltaInstallation, a restart keeps every
      guarantee a startup has: the persistent-data precheck runs before `up`,
      the services come up in order gated on health, the container's own
      migration is verified afterwards (the image runs psql without
      ON_ERROR_STOP, so container health is not evidence), and the configured
      endpoint is requested. Nothing is regenerated, repinned or pulled.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [int]$EngineTimeoutSeconds = 300
    )

    $result = [PSCustomObject]@{ Succeeded = $false; Reason = $null; Stop = $null; Start = $null }

    $result.Stop = Stop-DeltaInstallation -InstallRoot $InstallRoot -Configuration $Configuration
    if (-not $result.Stop.Succeeded) {
        $result.Reason = $result.Stop.Reason
        return $result
    }

    $result.Start = Start-DeltaInstallation -InstallRoot $InstallRoot -EngineTimeoutSeconds $EngineTimeoutSeconds
    if (-not $result.Start.Succeeded) {
        $result.Reason = $result.Start.Reason
        return $result
    }

    $result.Succeeded = $true
    return $result
}

# ---------------------------------------------------------------------------
# Access guide (A§20.3)
# ---------------------------------------------------------------------------

function Show-DeltaAccessGuide {
    <#
      Where DELTA is and how to sign in to it, adapted from the reference
      installer's guide of the same name.

      Two changes from the native version. Every URL is built by
      Get-DeltaPublicUrl - the single helper of A§11.3 - from the persisted
      hostname, ports and TLS setting, so the guide agrees with PUBLIC_URL, the
      NGINX redirect and the completion summary by construction. And the
      native text "public access requires a configured reverse proxy" is gone:
      under Docker, NGINX *is* the reverse proxy, and it is already serving.

      The paths are the reference installer's, verified against the running
      application: /, /en/admin/login, /en/user/login.

      It never claims reachability it has not tested. The endpoint is requested
      here, and if it does not answer the guide says so.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [object]$Endpoint,
        [switch]$SkipProbe
    )

    $scheme = if ($Configuration.TlsEnabled) { 'https' } else { 'http' }
    $port = if ($Configuration.TlsEnabled) { [int]$Configuration.HttpsPort } else { [int]$Configuration.HttpPort }
    $baseUrl = Get-DeltaPublicUrl -Scheme $scheme -HostName $Configuration.HostName -Port $port
    $loopback = Get-DeltaPublicUrl -Scheme $scheme -HostName 'localhost' -Port $port

    Show-Section -Title 'DELTA Access Guide' -Subtitle $baseUrl

    Write-Host 'Addresses'
    Write-Detail "Application          $baseUrl/"
    Write-Detail "Administrator        $baseUrl/en/admin/login"
    Write-Detail "Users                $baseUrl/en/user/login"
    Write-Detail ''

    Write-Host 'How it is served'
    Write-Detail "NGINX listens on this machine and proxies to the DELTA container on its private"
    Write-Detail "network. Nothing else is published: DELTA's own port 3000 and PostgreSQL's 5432"
    Write-Detail "are not reachable from this machine or any other."
    if ($Configuration.TlsEnabled) {
        Write-Detail "HTTPS                port $($Configuration.HttpsPort) ($($Configuration.TlsMode) certificate)"
        Write-Detail "HTTP                 port $($Configuration.HttpPort), redirects to $baseUrl"
    }
    else {
        Write-Detail "HTTP                 port $($Configuration.HttpPort)"
        Write-Detail 'HTTPS                not configured'
    }
    Write-Detail ''

    if (-not $SkipProbe -and -not $Endpoint) {
        $Endpoint = Test-DeltaHttpEndpoint -Url ($loopback + '/') -TimeoutSeconds 15
    }

    Write-Host 'Reachability'
    if (-not $Endpoint) {
        Write-DeltaWarning 'Not tested on this run, so this guide makes no claim that DELTA is answering.'
    }
    elseif ($Endpoint.Succeeded) {
        Write-Detail "Checked just now: GET $loopback/ returned HTTP $($Endpoint.StatusCode)."
        if ($Configuration.HostName -ne 'localhost') {
            Write-Detail "That proves this machine serves DELTA on port $port. Whether $($Configuration.HostName)"
            Write-Detail 'reaches it from elsewhere additionally depends on DNS and the firewall.'
        }
    }
    else {
        $why = if ($Endpoint.Error) { $Endpoint.Error } else { "HTTP $($Endpoint.StatusCode)" }
        Write-DeltaWarning "DELTA did NOT answer at $loopback/ ($why)."
        Write-DeltaWarning 'The addresses above are what is configured, not what is currently working.'
        Write-Detail 'Check the status block and the container logs (menu option 9).'
    }

    Write-Detail ''
    Write-Host 'Signing in'
    Write-Detail "The administrator account is the one this installer secured during installation."
    Write-Detail 'Its password was shown once and is stored nowhere; if it has been lost, replace it'
    Write-Detail 'rather than looking for it.'

    if ($Configuration.TlsEnabled -and $Configuration.TlsMode -eq 'self-signed') {
        Write-Detail ''
        Write-DeltaWarning 'The certificate is self-signed, so browsers warn until it is trusted or replaced.'
    }
    if (-not $Configuration.TlsEnabled) {
        Write-Detail ''
        Write-DeltaWarning 'Plain HTTP is suitable for localhost testing only. DELTA marks its session cookies'
        Write-DeltaWarning 'Secure, so users reaching this server by hostname will not stay signed in.'
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Log views (A§21.2)
#
# Docker's own mechanisms, and a file tail for the bind-mounted NGINX access
# log. No aggregation, no collector, no index.
#
# The Ctrl+C contract is the delicate part. `docker compose logs -f` is a
# client-side stream and interrupting it must terminate the viewer and nothing
# else - it must never stop a container, and it must not take the management
# utility down with it. A raw Ctrl+C in a Windows console is delivered to every
# process in the group, which would kill setup.ps1 as well as the docker CLI,
# so while a viewer is running the console is switched to deliver Ctrl+C as
# *input*. The viewer reads that keystroke, stops its own child process, and
# returns to the menu. The console mode is restored in a finally block.
# ---------------------------------------------------------------------------

function Test-DeltaViewerInterrupt {
    <#
      True when the operator has asked the current viewer to stop: Ctrl+C, Q or
      Escape. Returns false - never throws - when there is no interactive
      console to read from.
    #>
    try {
        if (-not [Console]::KeyAvailable) { return $false }
        $key = [Console]::ReadKey($true)
    }
    catch {
        return $false
    }

    if ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) { return $true }
    if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { return $true }
    return $false
}

function Stop-DeltaProcessTree {
    <#
      Ends a viewer's process and everything it started, descendants first.

      Killing only the process this function was given is not enough, and that
      was measured here rather than assumed: `docker compose` is a CLI plugin,
      so `docker.exe compose logs -f` starts a separate docker-compose.exe that
      does the actual streaming. Killing the docker.exe front-end alone left
      docker-compose.exe running with no parent - still following the logs,
      still writing to the console the operator had just returned to the menu
      in, and still holding the inherited output handle open. Five of them
      accumulated during one validation run.

      Descendants are killed before their parent so a process cannot be
      orphaned into invisibility half way through. Failures are ignored: a
      process that has already exited is the outcome this wants.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)

    $children = @()
    try { $children = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction Stop) } catch { }
    foreach ($child in $children) {
        Stop-DeltaProcessTree -ProcessId ([int]$child.ProcessId)
    }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction Stop } catch { }
}

function Show-DeltaTailBanner {
    param([Parameter(Mandatory)][string]$What)

    Show-Section -Title $What
    Write-Host 'Press Ctrl+C (or Q) to stop watching and return to the menu.'
    Write-Host 'This only stops the viewer. It does not stop DELTA or any container.'
    Write-Host ''
}

function Watch-DeltaComposeLogs {
    <#
      `docker compose logs --follow` for one service, or for the whole project
      when no service is named, scoped to this installation's project.

      The CLI is started as a child that writes straight to this console, and
      is stopped by this function when the operator interrupts. Killing the
      docker CLI ends a read-only stream; it sends nothing to any container.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [string[]]$Service = @(),
        [int]$Tail = 200,
        [Parameter(Mandatory)][string]$Title
    )

    $docker = Get-Command -Name 'docker' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $docker) {
        Write-DeltaWarning 'The docker CLI was not found, so container logs cannot be shown.'
        return
    }

    $composeFile = Join-Path -Path $InstallRoot -ChildPath 'docker-compose.yml'
    $envFile     = Join-Path -Path $InstallRoot -ChildPath '.env'
    $arguments = @(
        'compose'
        '--project-name', $ProjectName
        '--project-directory', $InstallRoot
        '--file', $composeFile
        '--env-file', $envFile
        'logs', '--follow', '--no-color', '--tail', "$Tail"
    ) + $Service

    Show-DeltaTailBanner -What $Title

    $process = $null
    $previousMode = $null
    try {
        try { $previousMode = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { }

        $process = Start-Process -FilePath $docker.Source `
            -ArgumentList (ConvertTo-DeltaCommandLine -Arguments $arguments) `
            -NoNewWindow -PassThru

        while (-not $process.HasExited) {
            if (Test-DeltaViewerInterrupt) { break }
            Start-Sleep -Milliseconds 120
        }
    }
    finally {
        if ($process -and -not $process.HasExited) {
            Stop-DeltaProcessTree -ProcessId $process.Id
            try { $null = $process.WaitForExit(5000) } catch { }
        }
        if ($null -ne $previousMode) {
            try { [Console]::TreatControlCAsInput = $previousMode } catch { }
        }
        Write-Host ''
        Write-DeltaLogLine -Message "Closed the log viewer: $Title" -Level 'DETAIL'
    }
}

function Watch-DeltaFileTail {
    <#
      Follows a Windows file the way `Get-Content -Wait` does, but interruptibly
      and without holding the file open: each poll reopens it, reads whatever
      has been appended since the last read, and writes it out.

      Reopening is what makes this safe next to log rotation. When the file is
      renamed and recreated - which is exactly what the NGINX access-log
      rotation does - the viewer notices that it has shrunk, says so, and
      carries on with the new file instead of silently going quiet.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Tail = 200,
        [Parameter(Mandatory)][string]$Title
    )

    Show-DeltaTailBanner -What $Title
    Write-Host "File: $Path"
    Write-Host ''

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-DeltaWarning 'That log file does not exist yet.'
        Write-Detail 'It appears as soon as something writes to it. Press Enter to return to the menu.'
        $null = Read-Host
        return
    }

    try {
        Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop | ForEach-Object { Write-Host $_ }
    }
    catch {
        Write-DeltaWarning "The end of the file could not be read: $($_.Exception.Message)"
    }

    $position = 0
    try { $position = (Get-Item -LiteralPath $Path).Length } catch { }

    $previousMode = $null
    try {
        try { $previousMode = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { }

        while ($true) {
            if (Test-DeltaViewerInterrupt) { break }

            $length = $null
            try { $length = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length } catch { $length = $null }

            if ($null -eq $length) {
                Start-Sleep -Milliseconds 500
                continue
            }
            if ($length -lt $position) {
                Write-Host '--- the log file was rotated or truncated; following the new file ---'
                $position = 0
            }
            if ($length -gt $position) {
                $stream = $null
                try {
                    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
                    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
                    $null = $stream.Seek($position, [System.IO.SeekOrigin]::Begin)
                    $reader = New-Object System.IO.StreamReader($stream)
                    $text = $reader.ReadToEnd()
                    $position = $stream.Position
                    if ($text) {
                        foreach ($line in ($text -split "`r?`n")) {
                            if ($line -ne '') { Write-Host $line }
                        }
                    }
                }
                catch {
                    Write-DeltaWarning "Reading $Path failed: $($_.Exception.Message)"
                }
                finally {
                    if ($stream) { $stream.Dispose() }
                }
            }

            Start-Sleep -Milliseconds 400
        }
    }
    finally {
        if ($null -ne $previousMode) {
            try { [Console]::TreatControlCAsInput = $previousMode } catch { }
        }
        Write-Host ''
        Write-DeltaLogLine -Message "Closed the log viewer: $Title" -Level 'DETAIL'
    }
}

function Confirm-DeltaStackUnaffected {
    <#
      Run immediately after every log viewer returns. It answers the one
      question the Ctrl+C contract is about - "did interrupting the viewer stop
      anything?" - with a `docker compose ps` rather than with reassurance.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration
    )

    $services = @(Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName)
    if ($services.Count -eq 0) {
        Write-DeltaWarning 'docker compose ps returned nothing; the containers could not be checked.'
        return
    }

    $summary = ($services | ForEach-Object {
        $health = if ($_.Health) { " ($($_.Health))" } else { '' }
        "$($_.Service) $($_.State)$health"
    }) -join ', '

    $stopped = @($services | Where-Object { $_.State -ne 'running' })
    if ($stopped.Count -eq 0) {
        Write-Success "Containers after closing the viewer: $summary"
        Write-Detail 'Closing a log view does not affect the stack.'
    }
    else {
        Write-DeltaWarning "Containers after closing the viewer: $summary"
    }
}

function Invoke-DeltaLogsMenu {
    <#
      The five log views of A§21.2, plus the installer's own Windows-side log.

      Each container view is `docker compose logs -f --tail N <service>` scoped
      to this project. The NGINX access log is the bind-mounted Windows file,
      because that is where the access stream is written (A§8.4, deviation D3) -
      it deliberately does not appear in `docker compose logs nginx`, where the
      error stream does.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [bool]$DockerReady = $true
    )

    $accessLog  = Get-DeltaNginxAccessLogPath -InstallRoot $InstallRoot
    $startupLog = Join-Path -Path $InstallRoot -ChildPath 'logs\installer\startup.log'

    while ($true) {
        Show-Section -Title 'View Logs'
        $note = if ($DockerReady) { '' } else { '   (unavailable - Docker is not running)' }
        Write-Host "  1. DELTA Application Logs      docker compose logs -f delta$note"
        Write-Host "  2. NGINX Access Log            $accessLog"
        Write-Host "  3. NGINX Error Log             docker compose logs -f nginx$note"
        Write-Host "  4. PostgreSQL Logs             docker compose logs -f db$note"
        Write-Host "  5. All Container Logs          docker compose logs -f$note"
        Write-Host "  S. Installer / startup log     $startupLog"
        Write-Host '  0. Back'
        Write-Host ''
        # Cast first: Read-Host returns $null at end of input, and calling
        # .Trim() on that would end the session with an exception instead of a
        # menu.
        $choice = ([string](Read-Host -Prompt 'Selection')).Trim().ToUpperInvariant()

        $containerView = $null
        switch ($choice) {
            '1' { $containerView = @{ Service = @('delta'); Tail = 200; Title = 'DELTA Application Logs' } }
            '3' { $containerView = @{ Service = @('nginx'); Tail = 200; Title = 'NGINX Error Log (container stderr)' } }
            '4' { $containerView = @{ Service = @('db');    Tail = 200; Title = 'PostgreSQL Logs' } }
            '5' { $containerView = @{ Service = @();        Tail = 100; Title = 'All Container Logs' } }
            '2' {
                Watch-DeltaFileTail -Path $accessLog -Tail 200 -Title 'NGINX Access Log'
                if ($DockerReady) { Confirm-DeltaStackUnaffected -InstallRoot $InstallRoot -Configuration $Configuration }
            }
            'S' {
                $path = $startupLog
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $newest = Get-ChildItem -LiteralPath (Join-Path -Path $InstallRoot -ChildPath 'logs\installer') -Filter 'setup-*.log' -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($newest) { $path = $newest.FullName }
                }
                Watch-DeltaFileTail -Path $path -Tail 200 -Title 'Installer / startup log'
            }
            '0' { return }
            default { Write-DeltaWarning "'$choice' is not a valid option." }
        }

        if ($containerView) {
            if (-not $DockerReady) {
                Write-DeltaWarning 'Container logs come from the Docker engine, which is not running.'
                Write-Detail 'Start DELTA from the main menu first, or read the NGINX access log (option 2),'
                Write-Detail 'which is a Windows file and does not need Docker.'
            }
            else {
                Watch-DeltaComposeLogs -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName `
                    -Service $containerView.Service -Tail $containerView.Tail -Title $containerView.Title
                Confirm-DeltaStackUnaffected -InstallRoot $InstallRoot -Configuration $Configuration
            }
        }
    }
}

# ---------------------------------------------------------------------------
# NGINX access-log rotation (A§26 U4)
#
# The assessment's recommended default, and nothing more: rename the current
# access log, tell NGINX to reopen it, keep seven rotations. It is not a log
# rotation framework - it knows one file, in one directory, belonging to this
# installation.
# ---------------------------------------------------------------------------

$Script:DeltaNginxRotationRetain   = 7
$Script:DeltaNginxRotationTaskTime = '03:30'
$Script:DeltaNginxRotationScript   = 'rotate-nginx-logs.ps1'

function Get-DeltaNginxAccessLogPath {
    param([Parameter(Mandatory)][string]$InstallRoot)
    return (Join-Path -Path $InstallRoot -ChildPath 'logs\nginx\access.log')
}

function Invoke-DeltaNginxLogRotation {
    <#
      Rotates <InstallRoot>\logs\nginx\access.log once.

        1. rename it to access.log.<timestamp>
        2. `nginx -s reopen`, so NGINX starts writing to a fresh access.log at
           the path its configuration names - the active logging path never
           changes
        3. delete rotations beyond the newest $Retain

      The rename happens inside the NGINX container when NGINX is running.
      That is deliberate: the file is open by a process inside the Linux VM, and
      a rename issued there has the POSIX semantics NGINX expects, while one
      issued from Windows against a file another process holds open is a sharing
      violation waiting to happen. When NGINX is not running, nothing holds the
      file and the rename is done on the Windows side with no signal to send.

      Idempotent: an absent or empty access log is "nothing to do", not a
      failure, so the scheduled run is a no-op on a quiet installation.
      Retention only ever considers files named access.log.* in this
      installation's own logs\nginx directory; no other file is examined, let
      alone deleted.

      Failures are reported and never escalated - a log that could not be
      rotated must not take a serving stack down with it.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [object]$Configuration,
        [int]$Retain = $Script:DeltaNginxRotationRetain,
        [switch]$Force
    )

    $result = [PSCustomObject]@{
        Succeeded  = $false
        Rotated    = $false
        LogPath    = $null
        RotatedTo  = $null
        Reopened   = $false
        Removed    = @()
        Retained   = @()
        Reason     = $null
    }

    if (-not $Configuration) {
        $Configuration = Get-DeltaStackConfiguration -InstallRoot $InstallRoot
    }
    if (-not $Configuration) {
        $result.Reason = "'$InstallRoot' has no .env, so there is no installation to rotate logs for."
        return $result
    }

    $logPath = Get-DeltaNginxAccessLogPath -InstallRoot $InstallRoot
    $logDirectory = Split-Path -Path $logPath -Parent
    $result.LogPath = $logPath

    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        $result.Succeeded = $true
        $result.Reason = "There is no access log at '$logPath' yet. Nothing to rotate."
        return $result
    }

    $size = (Get-Item -LiteralPath $logPath).Length
    if ($size -eq 0 -and -not $Force) {
        $result.Succeeded = $true
        $result.Reason = 'The access log is empty. Nothing to rotate.'
        return $result
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $rotatedName = "access.log.$stamp"
    $suffix = 1
    while (Test-Path -LiteralPath (Join-Path -Path $logDirectory -ChildPath $rotatedName)) {
        $rotatedName = "access.log.$stamp-$suffix"
        $suffix++
    }
    $rotatedPath = Join-Path -Path $logDirectory -ChildPath $rotatedName

    $nginxRunning = $false
    $services = @(Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName)
    $nginx = $services | Where-Object { $_.Service -eq 'nginx' } | Select-Object -First 1
    if ($nginx -and $nginx.State -eq 'running') { $nginxRunning = $true }

    if ($nginxRunning) {
        $move = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Arguments @(
            'exec', '-T', 'nginx', 'mv', '/var/log/nginx/access.log', "/var/log/nginx/$rotatedName"
        ) -TimeoutSeconds 120
        if ($move.ExitCode -ne 0) {
            $result.Reason = "The access log could not be renamed inside the NGINX container: $((($move.StdErr + ' ' + $move.StdOut)).Trim())"
            return $result
        }
        $result.Rotated = $true
        $result.RotatedTo = $rotatedPath

        $reopen = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Arguments @(
            'exec', '-T', 'nginx', 'nginx', '-s', 'reopen'
        ) -TimeoutSeconds 120
        if ($reopen.ExitCode -ne 0) {
            $result.Reason = "The access log was rotated to '$rotatedName', but `nginx -s reopen` failed: $((($reopen.StdErr + ' ' + $reopen.StdOut)).Trim()). NGINX is still serving; it is writing to the rotated file until it is reopened or restarted."
            return $result
        }
        $result.Reopened = $true

        # NGINX recreates the file as it reopens; give it a moment and confirm,
        # because "the active logging path is back" is the point of the signal.
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
            Start-Sleep -Milliseconds 250
        }
        if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
            $result.Reason = "NGINX accepted the reopen signal but '$logPath' has not reappeared yet. It is created on the next request."
        }
    }
    else {
        try {
            Move-Item -LiteralPath $logPath -Destination $rotatedPath -ErrorAction Stop
        }
        catch {
            $result.Reason = "The access log could not be renamed: $($_.Exception.Message)"
            return $result
        }
        $result.Rotated = $true
        $result.RotatedTo = $rotatedPath
        # No signal to send: NGINX is not running, and it opens the configured
        # path again when it next starts.
    }

    # Retention. Only this directory, only this installation's rotations, and
    # never the active file.
    $rotations = @(Get-ChildItem -LiteralPath $logDirectory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'access.log.*' -and $_.Name -ne 'access.log' } |
        Sort-Object LastWriteTime -Descending)

    $result.Retained = @($rotations | Select-Object -First $Retain | ForEach-Object { $_.Name })
    foreach ($old in ($rotations | Select-Object -Skip $Retain)) {
        try {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop
            $result.Removed += $old.Name
        }
        catch {
            Write-DeltaWarning "An old rotation could not be deleted: $($old.FullName) - $($_.Exception.Message)"
        }
    }

    $result.Succeeded = $true
    if (-not $result.Reason) {
        $result.Reason = "Rotated to $rotatedName; $($result.Retained.Count) rotation(s) retained, $($result.Removed.Count) deleted."
    }
    return $result
}

function Get-DeltaLogRotationTaskName {
    param([Parameter(Mandatory)][string]$ProjectName)
    return "DELTA (Docker) - $ProjectName - NGINX log rotation"
}

function Get-DeltaLogRotationTaskState {
    <#
      The registered rotation task for this installation, if there is one, read
      the same way Phase 6 reads the startup task - including the bracket
      escaping, because -TaskName is a wildcard filter and this name contains
      brackets.
    #>
    param([Parameter(Mandatory)][string]$ProjectName)

    $result = [PSCustomObject]@{
        Name      = (Get-DeltaLogRotationTaskName -ProjectName $ProjectName)
        Exists    = $false
        Enabled   = $false
        UserId    = $null
        Execute   = $null
        Arguments = $null
    }

    $escaped = [System.Management.Automation.WildcardPattern]::Escape($result.Name)
    $task = Get-ScheduledTask -TaskName $escaped -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $task) { return $result }

    $result.Exists = $true
    $result.Enabled = ($task.Settings.Enabled -ne $false)
    $result.UserId = $task.Principal.UserId

    $action = @($task.Actions) | Select-Object -First 1
    if ($action) {
        $result.Execute = [string]$action.Execute
        $result.Arguments = [string]$action.Arguments
    }
    return $result
}

function Sync-DeltaLogRotationTask {
    <#
      Reconciles the one scheduled task this phase owns: daily, run
      rotate-nginx-logs.ps1 for this installation.

      Reconciled rather than merely created. A rerun compares the registered
      command line with the one this installation needs and replaces the task
      only when they differ, so repeated runs never produce a second task and
      never rewrite an identical one. A task left pointing at a moved installer
      would fail silently at 03:30, which is the worst way for this to break.

      It runs as the installing account with LogonType S4U - whether or not
      that user is signed in, with no stored password - for the reason Phase 6
      established: Docker Desktop's engine, its CLI plugins and this
      installation's volumes belong to that user, and SYSTEM sees none of them.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$UserId
    )

    $result = [PSCustomObject]@{
        Name      = (Get-DeltaLogRotationTaskName -ProjectName $ProjectName)
        Succeeded = $false
        Action    = 'none'
        UserId    = $UserId
        Reason    = $null
    }

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        $result.Reason = "The rotation script was not found at '$ScriptPath'. No task was registered - a task pointing at a missing script is worse than no task."
        return $result
    }

    if (-not $UserId) {
        $UserId = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).Name
        $result.UserId = $UserId
    }

    $arguments = ConvertTo-DeltaCommandLine -Arguments @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass'
        '-File', $ScriptPath
        '-InstallRoot', $InstallRoot
    )

    $existing = Get-DeltaLogRotationTaskState -ProjectName $ProjectName
    if ($existing.Exists -and $existing.Enabled -and
        $existing.Execute -eq 'powershell.exe' -and $existing.Arguments -eq $arguments) {
        $result.Succeeded = $true
        $result.Action = 'unchanged'
        $result.UserId = $existing.UserId
        return $result
    }

    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -Daily -At $Script:DeltaNginxRotationTaskTime
        $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType S4U -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit ([System.TimeSpan]::FromMinutes(15)) `
            -MultipleInstances IgnoreNew

        $null = Register-ScheduledTask -TaskName $result.Name -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings `
            -Description "Rotates the NGINX access log of the DELTA Compose project '$ProjectName' and keeps the last $Script:DeltaNginxRotationRetain rotations. Registered by the DELTA installer; it runs one script once a day and exits." `
            -Force -ErrorAction Stop
    }
    catch {
        $result.Reason = "The log-rotation task could not be registered: $($_.Exception.Message)"
        return $result
    }

    $after = Get-DeltaLogRotationTaskState -ProjectName $ProjectName
    if (-not $after.Exists) {
        $result.Reason = 'The log-rotation task was registered without error but cannot be read back.'
        return $result
    }

    $result.Succeeded = $true
    $result.Action = if ($existing.Exists) { 'replaced' } else { 'created' }
    $result.UserId = $after.UserId
    return $result
}

function Initialize-DeltaLogRotation {
    <#
      Makes sure this installation has its rotation task, and records what was
      configured in .delta-install.json.

      The state file is written only when something actually changed, so
      opening the management menu on an installation that is already configured
      leaves every byte of it alone.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration
    )

    $scriptPath = Join-Path -Path $ScriptRoot -ChildPath $Script:DeltaNginxRotationScript
    $sync = Sync-DeltaLogRotationTask -ProjectName $Configuration.ProjectName -InstallRoot $InstallRoot -ScriptPath $scriptPath

    if (-not $sync.Succeeded) {
        Write-DeltaWarning "NGINX access-log rotation is not scheduled: $($sync.Reason)"
        Write-Detail "You can rotate it by hand with:  .\$($Script:DeltaNginxRotationScript) -InstallRoot $InstallRoot"
        return $sync
    }

    if ($sync.Action -eq 'unchanged') {
        return $sync
    }

    Write-Detail "NGINX access-log rotation $($sync.Action): scheduled task '$($sync.Name)', daily at $Script:DeltaNginxRotationTaskTime, keeping $Script:DeltaNginxRotationRetain rotations."
    $null = Write-DeltaInstallState -InstallRoot $InstallRoot -Properties ([ordered]@{
        nginxLogRotation = [ordered]@{
            configured   = $true
            mechanism    = 'scheduled-task'
            taskName     = $sync.Name
            taskUserId   = $sync.UserId
            schedule     = "daily $Script:DeltaNginxRotationTaskTime"
            retain       = $Script:DeltaNginxRotationRetain
            script       = $scriptPath
            logPath      = (Get-DeltaNginxAccessLogPath -InstallRoot $InstallRoot)
            configuredAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    })
    return $sync
}

# ---------------------------------------------------------------------------
# The menu (A§17.3)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Database backup (A§19)
#
# One operation, and it either produces a dump that has been proven to parse or
# it produces nothing at all. That is not fastidiousness: Phase 9's update takes
# a backup first and treats it as the only rollback path an irreversible
# forward-only migration has (A§25). A file left on disk that nobody has read
# back would be trusted by that update. So every failure - pg_dump exiting
# non-zero, an empty file, a dump pg_restore cannot parse - ends with the file
# deleted.
#
# Three constraints from the assessment shape the transport:
#
#   * pg_dump runs in the db container, never in the delta container. DELTA's
#     image ships pg_dump 15.19 and the server is 17.x; the client refuses
#     outright with "aborting because of server version mismatch" (A§19.1, D5).
#   * `exec -T`, always. A TTY would rewrite the byte stream.
#   * The bytes go from the child's stdout straight into the Windows file
#     through Invoke-DeltaComposeBinary. Not via a string, not via a file
#     written inside the container and copied out.
#
# No credential appears anywhere in this path: pg_dump connects over the
# container's local socket as POSTGRES_USER, so there is no password to pass,
# on a command line or otherwise.
# ---------------------------------------------------------------------------

# delta-YYYYMMDD-HHmmss.dump (A§19.2) - sortable, unambiguous, and the only
# shape retention will ever consider deleting.
$Script:DeltaBackupNamePattern    = '^delta-(\d{8})-(\d{6})\.dump$'
$Script:DeltaBackupRetainCount    = 10
$Script:DeltaBackupRetainDays     = 30
$Script:DeltaBackupTimeoutSeconds = 1800

# Every PostgreSQL custom-format archive starts with these five bytes. Checking
# them costs nothing and turns "pg_restore could not read this" into "this is
# not a dump at all" for the operator; it does not replace the pg_restore parse,
# which is the actual verification.
$Script:DeltaBackupMagic = [byte[]]@(0x50, 0x47, 0x44, 0x4D, 0x50)  # "PGDMP"

function Format-DeltaByteSize {
    param([Parameter(Mandatory)][AllowNull()][object]$Bytes)

    $value = 0.0
    if ($null -ne $Bytes) { $value = [double]$Bytes }
    if ($value -ge 1GB) { return ('{0:N2} GB' -f ($value / 1GB)) }
    if ($value -ge 1MB) { return ('{0:N2} MB' -f ($value / 1MB)) }
    if ($value -ge 1KB) { return ('{0:N1} KB' -f ($value / 1KB)) }
    return ('{0:N0} bytes' -f $value)
}

function Get-DeltaBackupDirectory {
    param([Parameter(Mandatory)][string]$InstallRoot)
    return (Join-Path -Path $InstallRoot -ChildPath 'backups')
}

function Get-DeltaBackupFile {
    <#
      The dumps in one installation's own backups directory, newest first.

      Only files whose name matches delta-YYYYMMDD-HHmmss.dump exactly are
      returned. That is what keeps retention away from an operator's .env
      snapshot, a note, a copy of somebody else's dump, or anything else that
      happens to be in the folder.

      The effective timestamp is the one encoded in the name, because the name
      is the record of when the backup was taken; a file whose name does not
      parse as a date cannot match the pattern at all, so LastWriteTime is only
      ever a fallback for an unreadable-but-matching name.
    #>
    param([Parameter(Mandatory)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }

    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in (Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue)) {
        $match = [regex]::Match($item.Name, $Script:DeltaBackupNamePattern)
        if (-not $match.Success) { continue }

        $stamp = $item.LastWriteTime
        $parsed = [datetime]::MinValue
        $text = '{0}-{1}' -f $match.Groups[1].Value, $match.Groups[2].Value
        if ([datetime]::TryParseExact($text, 'yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $stamp = $parsed
        }

        $null = $files.Add([PSCustomObject]@{
            Name      = $item.Name
            FullName  = $item.FullName
            Length    = $item.Length
            Timestamp = $stamp
        })
    }

    return @($files | Sort-Object -Property Timestamp, Name -Descending)
}

function Test-DeltaBackupArchive {
    <#
      Proves that a file on disk is a dump PostgreSQL can actually read back.

      `pg_restore --list` is the verification (A§19.3). It runs in the db
      container - the same tooling that wrote the dump, the same major version
      as the server - and the archive reaches it on stdin through the same
      byte-exact transport that wrote it, so nothing on the Windows side
      re-encodes it on the way back in.

      A file existing is not evidence. A non-zero size is not evidence. Only a
      successful parse that yields at least one table-of-contents entry is.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 600
    )

    $result = [PSCustomObject]@{
        Verified   = $false
        SizeBytes  = 0
        TocEntries = 0
        Reason     = $null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Reason = "No file was produced at '$Path'."
        return $result
    }

    $result.SizeBytes = (Get-Item -LiteralPath $Path).Length
    if ($result.SizeBytes -le 0) {
        $result.Reason = 'The dump file is empty (0 bytes).'
        return $result
    }

    if ($result.SizeBytes -ge $Script:DeltaBackupMagic.Length) {
        $header = New-Object byte[] $Script:DeltaBackupMagic.Length
        $stream = $null
        try {
            $stream = [System.IO.File]::OpenRead($Path)
            $null = $stream.Read($header, 0, $header.Length)
        }
        catch {
            $result.Reason = "The dump file could not be read back: $($_.Exception.Message)"
            return $result
        }
        finally {
            if ($stream) { $stream.Dispose() }
        }

        for ($i = 0; $i -lt $header.Length; $i++) {
            if ($header[$i] -ne $Script:DeltaBackupMagic[$i]) {
                $result.Reason = 'The file does not begin with the PGDMP marker, so it is not a PostgreSQL custom-format archive.'
                return $result
            }
        }
    }

    $capture = Invoke-DeltaComposeBinary -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @(
        'exec', '-T', 'db', 'pg_restore', '--list'
    ) -InputFile $Path -TimeoutSeconds $TimeoutSeconds

    if ($capture.ExitCode -ne 0) {
        $detail = (($capture.StdErr + ' ' + $capture.StdOut)).Trim()
        if (-not $detail) { $detail = "pg_restore --list exited $($capture.ExitCode)." }
        $result.Reason = "pg_restore --list could not parse the dump: $detail"
        return $result
    }

    # A custom-format archive lists its table of contents as "id; oid oid TYPE
    # name owner" lines; the ';'-prefixed lines above them are the header
    # comment and are not entries.
    $entries = @($capture.StdOut -split "`r?`n" | Where-Object { $_ -match '^\s*\d+;\s' })
    $result.TocEntries = $entries.Count
    if ($result.TocEntries -le 0) {
        $result.Reason = 'pg_restore --list returned no table-of-contents entries, so the archive carries nothing to restore.'
        return $result
    }

    $result.Verified = $true
    $result.Reason = "pg_restore --list parsed the archive: $($result.TocEntries) table-of-contents entries."
    return $result
}

function Invoke-DeltaBackupRetention {
    <#
      The minimal A§19.3 policy, and nothing more.

      A dump is deleted only when BOTH are true:
        * it is not among the newest $RetainCount dumps, and
        * it is older than $RetainDays days.

      So the newest ten survive however old they are, everything from the last
      thirty days survives however many there are, and only the surplus that is
      also old goes. Anything not named delta-YYYYMMDD-HHmmss.dump is never
      examined, let alone deleted, and neither is the backup just created.

      This runs only after a new backup has been verified, and a failure here is
      reported on its own terms: an old file that could not be deleted has no
      bearing on whether the new dump is valid.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [int]$RetainCount = $Script:DeltaBackupRetainCount,
        [int]$RetainDays  = $Script:DeltaBackupRetainDays,
        [string]$ExcludePath,
        [datetime]$Now = (Get-Date)
    )

    $result = [PSCustomObject]@{
        Succeeded     = $true
        Removed       = @()
        RemovedBytes  = 0
        RetainedCount = 0
        Failures      = @()
        Reason        = $null
    }

    $files = @(Get-DeltaBackupFile -Directory $Directory)
    if ($files.Count -eq 0) {
        $result.Reason = 'There are no dumps to consider.'
        return $result
    }

    $cutoff = $Now.AddDays(-$RetainDays)
    $removed = New-Object 'System.Collections.Generic.List[object]'
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $retained = 0
    $index = 0

    foreach ($file in $files) {
        $index++
        $withinNewest = ($index -le $RetainCount)
        $withinWindow = ($file.Timestamp -ge $cutoff)
        $isNewBackup  = ($ExcludePath -and ($file.FullName -eq $ExcludePath))

        if ($withinNewest -or $withinWindow -or $isNewBackup) {
            $retained++
            continue
        }

        try {
            $size = $file.Length
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $null = $removed.Add([PSCustomObject]@{ Name = $file.Name; Length = $size; Timestamp = $file.Timestamp })
            $result.RemovedBytes += $size
        }
        catch {
            $retained++
            $null = $failures.Add("$($file.Name) - $($_.Exception.Message)")
        }
    }

    $result.Removed       = $removed.ToArray()
    $result.Failures      = $failures.ToArray()
    $result.RetainedCount = $retained
    $result.Succeeded     = ($failures.Count -eq 0)
    $result.Reason = "$($result.Removed.Count) old dump(s) removed, $retained retained, $(Format-DeltaByteSize $result.RemovedBytes) reclaimed."
    if ($failures.Count -gt 0) {
        $result.Reason += " $($failures.Count) could not be deleted."
    }
    return $result
}

function New-DeltaDatabaseBackup {
    <#
      Produces <InstallRoot>\backups\delta-YYYYMMDD-HHmmss.dump, or produces
      nothing.

      The sequence is fixed:

        1. the db container must be running - there is nothing to dump otherwise
        2. pg_dump -Fc in the db container, stdout streamed byte-for-byte into
           the target file
        3. pg_dump must have exited 0
        4. the file must exist and be non-empty
        5. pg_restore --list must parse it

      Anything that fails at 2-5 deletes the file before returning. The caller -
      an operator at the menu today, Phase 9's update tomorrow - is never handed
      a path to a file that was not read back successfully.

      Retention runs only after verification passes, and its outcome is reported
      separately: a dump that verified is a valid backup whether or not an old
      file could be tidied away.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [object]$Configuration,
        [switch]$SkipRetention,
        [int]$RetainCount = $Script:DeltaBackupRetainCount,
        [int]$RetainDays  = $Script:DeltaBackupRetainDays,
        [int]$TimeoutSeconds = $Script:DeltaBackupTimeoutSeconds
    )

    $result = [PSCustomObject]@{
        Succeeded    = $false
        Path         = $null
        FileName     = $null
        SizeBytes    = 0
        DurationSecs = 0
        Verification = $null
        Retention    = $null
        Stage        = 'start'
        Reason       = $null
        Deleted      = $false
    }

    if (-not $Configuration) {
        $Configuration = Get-DeltaStackConfiguration -InstallRoot $InstallRoot
    }
    if (-not $Configuration) {
        $result.Stage = 'configuration'
        $result.Reason = "'$InstallRoot' has no readable .env, so there is no installation to back up."
        return $result
    }

    # The db container has to be running. Starting it here would turn "back up
    # the database" into a lifecycle operation the operator did not ask for.
    $services = @(Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName)
    $db = $services | Where-Object { $_.Service -eq 'db' } | Select-Object -First 1
    if (-not $db -or $db.State -ne 'running') {
        $result.Stage = 'precheck'
        $observed = if ($db) { $db.Status } else { 'no container exists for the db service' }
        $result.Reason = "The database container is not running ($observed). Start DELTA first, then take the backup."
        return $result
    }

    $directory = Get-DeltaBackupDirectory -InstallRoot $InstallRoot
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        try { $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop }
        catch {
            $result.Stage = 'precheck'
            $result.Reason = "The backups directory '$directory' could not be created: $($_.Exception.Message)"
            return $result
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $fileName = "delta-$stamp.dump"
    $target = Join-Path -Path $directory -ChildPath $fileName
    if (Test-Path -LiteralPath $target) {
        # Two backups inside one second. Waiting a second keeps the documented
        # name shape exact rather than inventing a variant of it.
        Start-Sleep -Seconds 1
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $fileName = "delta-$stamp.dump"
        $target = Join-Path -Path $directory -ChildPath $fileName
    }
    $result.Path = $target
    $result.FileName = $fileName

    Write-Step "Backing up database '$($Configuration.PostgresDb)' to $fileName"
    Write-Detail 'pg_dump -Fc runs inside the db container; the stream is written straight to the file.'

    $started = Get-Date
    $result.Stage = 'dump'
    $capture = Invoke-DeltaComposeBinary -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Arguments @(
        'exec', '-T', 'db',
        'pg_dump', '-U', $Configuration.PostgresUser, '-d', $Configuration.PostgresDb, '-Fc'
    ) -OutputFile $target -TimeoutSeconds $TimeoutSeconds
    $result.DurationSecs = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)

    $failure = $null
    if ($capture.Error -eq 'not-found') {
        $failure = 'The docker CLI was not found on PATH, so pg_dump was never run.'
    }
    elseif ($capture.TimedOut) {
        $failure = "pg_dump did not finish within $TimeoutSeconds seconds and was stopped. The partial dump is not a backup."
    }
    elseif ($capture.Error) {
        $failure = "The backup could not be started: $($capture.Error)"
    }
    elseif ($capture.ExitCode -ne 0) {
        $detail = $capture.StdErr
        if (-not $detail) { $detail = "pg_dump exited $($capture.ExitCode) with no message." }
        $failure = "pg_dump failed (exit $($capture.ExitCode)): $detail"
    }

    if ($failure) {
        $result.Reason = $failure
        $result.Deleted = Remove-DeltaFailedBackup -Path $target
        return $result
    }

    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        $result.Reason = 'pg_dump reported success but no file was produced.'
        return $result
    }

    $result.SizeBytes = (Get-Item -LiteralPath $target).Length
    if ($result.SizeBytes -le 0) {
        $result.Reason = 'pg_dump reported success but the dump file is empty (0 bytes).'
        $result.Deleted = Remove-DeltaFailedBackup -Path $target
        return $result
    }

    Write-Detail "Wrote $(Format-DeltaByteSize $result.SizeBytes) in $($result.DurationSecs)s. Verifying."

    $result.Stage = 'verify'
    $verification = Test-DeltaBackupArchive -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Path $target
    $result.Verification = $verification
    if (-not $verification.Verified) {
        $result.Reason = "The dump did not verify: $($verification.Reason)"
        $result.Deleted = Remove-DeltaFailedBackup -Path $target
        return $result
    }

    $result.Stage = 'retention'
    if (-not $SkipRetention) {
        $result.Retention = Invoke-DeltaBackupRetention -Directory $directory -RetainCount $RetainCount -RetainDays $RetainDays -ExcludePath $target
    }

    $result.Stage = 'complete'
    $result.Succeeded = $true
    $result.Reason = "Verified backup written to $target ($(Format-DeltaByteSize $result.SizeBytes))."
    return $result
}

function Remove-DeltaFailedBackup {
    <#
      Deletes a dump that did not complete or did not verify.

      This is the guarantee Phase 9 rests on: after a failed backup there is no
      file in backups\ that anything could later mistake for one. When the
      deletion itself fails the operator is told loudly and by name, because the
      residue is then exactly the hazard this function exists to remove.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        Write-Detail "Deleted the unverified dump: $Path"
        return $true
    }
    catch {
        Write-DeltaWarning "The unverified dump could not be deleted: $Path - $($_.Exception.Message)"
        Write-DeltaWarning 'Delete it by hand. It is not a backup and must not be relied on.'
        return $false
    }
}

function Invoke-DeltaBackupOperation {
    <#
      Menu option 2. Runs the backup and reports it - path, size, verification
      and retention - in the operator's terms.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration
    )

    Show-Section -Title 'Backup Database' -Subtitle (Get-DeltaBackupDirectory -InstallRoot $InstallRoot)

    $backup = New-DeltaDatabaseBackup -InstallRoot $InstallRoot -Configuration $Configuration

    Write-Host ''
    if ($backup.Succeeded) {
        Write-Success 'Backup complete and verified.'
        Write-Detail "File           $($backup.Path)"
        Write-Detail "Size           $(Format-DeltaByteSize $backup.SizeBytes)"
        Write-Detail "Taken in       $($backup.DurationSecs)s"
        Write-Detail "Verification   $($backup.Verification.Reason)"
        if ($backup.Retention) {
            Write-Detail "Retention      $($backup.Retention.Reason)"
            foreach ($old in $backup.Retention.Removed) {
                Write-Detail "               removed $($old.Name) ($(Format-DeltaByteSize $old.Length))"
            }
            if (-not $backup.Retention.Succeeded) {
                Write-DeltaWarning 'Some old dumps could not be deleted. This does not affect the backup just taken.'
                foreach ($failure in $backup.Retention.Failures) { Write-Detail "               $failure" }
            }
        }
        Write-Detail ''
        Write-Detail 'Restoring is a manual, destructive procedure - see "Restoring the database" in README.md.'
    }
    else {
        Write-DeltaFailure 'The backup failed. No backup was produced.'
        Write-Detail "Stage reached  $($backup.Stage)"
        Write-Detail $backup.Reason
        if ($backup.Path) {
            if ($backup.Deleted) {
                Write-Detail 'The partial file was deleted, so nothing in backups\ can be mistaken for a valid backup.'
            }
            elseif (Test-Path -LiteralPath $backup.Path -PathType Leaf) {
                Write-DeltaWarning "A file remains at $($backup.Path). It is NOT a backup."
            }
        }
        Write-Detail 'The database, the stack and every existing backup are unchanged.'
    }

    Write-Host ''
    Write-Detail 'Press Enter to return to the menu.'
    $null = Read-Host
    return $backup
}

function Show-DeltaPhasePlaceholder {
    <#
      An operation the completed product has and this build does not yet. It
      names the phase that delivers it and returns; it never half-does the
      thing, and it changes nothing.
    #>
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][int]$Phase,
        [Parameter(Mandatory)][string]$Description
    )

    Show-Section -Title $Operation
    Write-Detail "$Description"
    Write-Detail ''
    Write-Detail "This operation is delivered by Phase $Phase of the installer and is not implemented in"
    Write-Detail 'this build. Nothing was changed. Press Enter to return to the menu.'
    Write-DeltaLogLine -Message "Placeholder selected: $Operation (Phase $Phase)" -Level 'DETAIL'
    $null = Read-Host
}

function Show-DeltaUnavailableOperation {
    <#
      A runtime operation was selected while the Docker engine is not usable.
      The menu does not offer those operations in that state, so this is the
      defensive path for a number typed anyway: it says why, pauses so the
      message is actually read, and changes nothing.
    #>
    param([Parameter(Mandatory)][string]$Operation)

    Write-Host ''
    Write-DeltaWarning "$Operation needs the Docker engine, which is not running."
    Write-Detail 'Choose "Start DELTA" to start Docker Desktop and bring the stack up first.'
    Write-Detail 'Nothing was changed. Press Enter to refresh the status.'
    $null = Read-Host
}

function Show-DeltaManagementMenu {
    <#
      Draws the menu and returns the operator's selection.

      The numbering is A§17.3's and does not move as later phases fill the
      entries in - which is the point of building this shell first. Start DELTA
      is offered as S when the engine or any service is not running; when
      everything is up there is nothing for it to do, so it is not shown.

      When the Docker engine is not usable, the operations that need it are not
      offered at all rather than being offered and then failing noisily.
    #>
    param([Parameter(Mandatory)][object]$Status)

    $canRun = $Status.DockerReady
    $offerStart = (-not $Status.AllRunning)

    Write-Host ''
    if ($canRun) {
        Write-Host '  1. Update DELTA                  (Phase 9 - not implemented yet)'
        Write-Host '  2. Backup Database'
        Write-Host '  3. Stop DELTA'
        Write-Host '  4. Restart DELTA'
        Write-Host '  5. Configure SMTP                (Phase 10 - not implemented yet)'
        Write-Host '  6. Reset Administrator Password  (Phase 10 - not implemented yet)'
        Write-Host '  7. Certificate Management        (Phase 10 - not implemented yet)'
    }
    else {
        Write-Host '  Operations 1-7 need the Docker engine and are not offered until it is running.'
    }
    Write-Host '  8. DELTA Access Guide'
    Write-Host '  9. View Logs'
    if ($offerStart) {
        if ($canRun) { Write-Host '  S. Start DELTA' }
        else { Write-Host '  S. Start DELTA                   (starts Docker Desktop first)' }
    }
    Write-Host '  0. Exit'
    Write-Host ''
    Write-Host '  (Enter refreshes the status)'
    Write-Host ''

    return ([string](Read-Host -Prompt 'Selection')).Trim().ToUpperInvariant()
}

function Invoke-DeltaManagementMode {
    <#
      The management utility: what running setup.ps1 on a registered
      installation does instead of installing (A§17.1).

      It never re-runs the installation. No prerequisite check, no Docker
      install, no port or TLS resolution, no artefact generation, no image
      pull, no digest repin, no security bootstrap. It reads the installation,
      reports it, and performs the operations the operator chooses.

      Returns the process exit code.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [bool]$AllowPrompt = $true
    )

    # A scheduled task can start with a PATH that an interactive sign-in would
    # have given it; this repairs only this process's PATH and only if docker
    # does not already resolve.
    $null = Initialize-DeltaDockerPath

    $rotationInitialised = $false

    while ($true) {
        $status = Get-DeltaManagementStatus -InstallRoot $InstallRoot

        Show-Section -Title 'DELTA Docker Management' -Subtitle $InstallRoot
        Show-DeltaManagementStatus -Status $status

        if (-not $status.Configuration) {
            Write-Host ''
            Write-DeltaFailure "This installation's .env could not be read, so there is nothing to manage."
            Write-Detail "Expected $InstallRoot\.env."
            return $Script:DeltaExitStackFailed
        }

        # Once per session: make sure the U4 rotation task exists and matches
        # this installation. It needs no Docker and changes nothing else.
        if (-not $rotationInitialised) {
            $rotationInitialised = $true
            $null = Initialize-DeltaLogRotation -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Configuration $status.Configuration
        }

        if (-not $AllowPrompt) {
            Write-Host ''
            Write-Detail 'Running non-interactively, so the status above is all this run does.'
            return $Script:DeltaExitSuccess
        }

        $choice = Show-DeltaManagementMenu -Status $status

        switch ($choice) {
            '' { continue }
            '0' {
                Write-Host ''
                Write-Detail 'Leaving the management utility. DELTA is unaffected by exiting.'
                return $Script:DeltaExitSuccess
            }
            '1' {
                if (-not $status.DockerReady) { Show-DeltaUnavailableOperation -Operation 'Update DELTA'; continue }
                Show-DeltaPhasePlaceholder -Operation 'Update DELTA' -Phase 9 `
                    -Description 'Compares the pinned image digest with the one behind prod-latest, backs the database up, pulls, recreates the DELTA container and verifies the migration.'
            }
            '2' {
                if (-not $status.DockerReady) { Show-DeltaUnavailableOperation -Operation 'Backup Database'; continue }
                $null = Invoke-DeltaBackupOperation -InstallRoot $InstallRoot -Configuration $status.Configuration
            }
            '3' {
                if (-not $status.DockerReady) { Show-DeltaUnavailableOperation -Operation 'Stop DELTA'; continue }
                $stop = Stop-DeltaInstallation -InstallRoot $InstallRoot -Configuration $status.Configuration
                if (-not $stop.Succeeded) {
                    Write-DeltaFailure ''
                    Write-DeltaFailure 'DELTA was not stopped.'
                    Write-Detail $stop.Reason
                }
                Write-Host ''
                Write-Detail 'Press Enter to refresh the status.'
                $null = Read-Host
            }
            '4' {
                if (-not $status.DockerReady) { Show-DeltaUnavailableOperation -Operation 'Restart DELTA'; continue }
                $restart = Restart-DeltaInstallation -InstallRoot $InstallRoot -Configuration $status.Configuration
                if ($restart.Succeeded) {
                    Write-Success 'DELTA restarted: all three services are healthy and the endpoint answered.'
                }
                else {
                    Write-DeltaFailure ''
                    Write-DeltaFailure 'The restart did not complete.'
                    Write-Detail $restart.Reason
                    Write-Detail 'Nothing was deleted, reconfigured or regenerated.'
                }
                Write-Host ''
                Write-Detail 'Press Enter to refresh the status.'
                $null = Read-Host
            }
            '5' {
                if (-not $status.DockerReady) { Show-DeltaUnavailableOperation -Operation 'Configure SMTP'; continue }
                Show-DeltaPhasePlaceholder -Operation 'Configure SMTP' -Phase 10 `
                    -Description 'Collects the SMTP settings, writes them to .env and applies them by recreating the DELTA container.'
            }
            '6' {
                if (-not $status.DockerReady) { Show-DeltaUnavailableOperation -Operation 'Reset Administrator Password'; continue }
                Show-DeltaPhasePlaceholder -Operation 'Reset Administrator Password' -Phase 10 `
                    -Description 'Replaces the stored administrator credential and verifies the replacement against the database.'
            }
            '7' {
                if (-not $status.DockerReady) { Show-DeltaUnavailableOperation -Operation 'Certificate Management'; continue }
                Show-DeltaPhasePlaceholder -Operation 'Certificate Management' -Phase 10 `
                    -Description 'Replaces or renews the TLS certificate, validates it, and reloads NGINX only after nginx -t passes.'
            }
            '8' {
                # No -Endpoint: the guide probes when it is displayed rather
                # than reusing the status block's result, which may have been
                # measured before the operator went to lunch.
                Show-DeltaAccessGuide -InstallRoot $InstallRoot -Configuration $status.Configuration
                Write-Detail 'Press Enter to return to the menu.'
                $null = Read-Host
            }
            '9' {
                Invoke-DeltaLogsMenu -InstallRoot $InstallRoot -Configuration $status.Configuration -DockerReady $status.DockerReady
            }
            'S' {
                $start = Start-DeltaInstallation -InstallRoot $InstallRoot
                if (-not $start.Succeeded) {
                    Write-DeltaFailure ''
                    Write-DeltaFailure 'DELTA did not start.'
                    Write-Detail $start.Reason
                    Write-Detail "Stage reached: $($start.Stage)"
                    Write-Detail 'Nothing was deleted, reconfigured or regenerated.'
                }
                Write-Host ''
                Write-Detail 'Press Enter to refresh the status.'
                $null = Read-Host
            }
            default {
                Write-DeltaWarning "'$choice' is not a valid option."
            }
        }
    }
}
