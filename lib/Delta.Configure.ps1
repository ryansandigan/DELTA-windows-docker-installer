# =============================================================================
# Delta.Configure.ps1 - configuration management: SMTP, administrator
#                       credential, TLS certificate replacement
#
# Dot-source Delta.Common.ps1, Delta.Config.ps1, Delta.Docker.ps1,
# Delta.Stack.ps1, Delta.Network.ps1 and Delta.Manage.ps1 first.
#
# Assessment references: A§20.1 (SMTP - variables, persistence, and the
# recreate-not-restart rule), A§20.2 (administrator reset - reuse the SQL,
# replace the transport), A§11 (TLS modes and certificate validation),
# A§8.3 (nginx -t before reload), A§24 (secret handling).
#
# This file is the third seam the phasing plan anticipated for this library
# (backup, update, configuration management). It owns no primitives: the
# certificate validation is Phase 4's, the administrator reset is Phase 5's,
# the .env writer is Phase 1's, the Compose invocation is Phase 3's and the
# NGINX upstream refresh is Phase 9's. What lives here is the operator-facing
# flow around them.
#
# Three operations, three independent blast radii:
#
#   SMTP        writes .env, then recreates ONLY the delta container, because
#               environment changes need recreation and `restart` will not
#               pick them up (A§20.1). Nothing else is touched.
#   Certificate replaces two files in certs\ and reloads NGINX. No container is
#               recreated - not delta, not db, not nginx.
#   Admin reset touches one database row through Phase 5's primitive. No
#               container lifecycle at all.
#
# A failure in one cannot damage the other two: they share no state beyond the
# installation itself, and each restores what it changed.
# =============================================================================

# The seven variables the built server actually reads. Verified against the
# running image rather than taken from documentation:
#   grep -oE '(SMTP|EMAIL)_[A-Z_]+' /delta/build/server/index.js | sort -u
# returns exactly these, and the bundle's own default is
# `EMAIL_TRANSPORT || "file"` with a validator that accepts only 'file' or
# 'smtp'. Nothing else in this file invents a variable DELTA does not read.
$Script:DeltaSmtpKeys = @(
    'EMAIL_TRANSPORT'
    'EMAIL_FROM'
    'SMTP_HOST'
    'SMTP_PORT'
    'SMTP_USER'
    'SMTP_PASS'
    'SMTP_SECURE'
)

# How long to wait for a TCP connection to the SMTP server before calling it
# unreachable. Short on purpose: this is a sanity check on what the operator
# typed, not a mail-delivery test.
$Script:DeltaSmtpProbeTimeoutSeconds = 10

# ---------------------------------------------------------------------------
# SMTP (A§20.1)
# ---------------------------------------------------------------------------

function Get-DeltaSmtpConfiguration {
    <#
      The SMTP settings currently in .env.

      SMTP_PASS is deliberately NOT returned. The screen that follows has to be
      able to say "a password is configured" and to leave it alone, and it can
      do both from a boolean; reading the value would put a live credential
      into a variable, into a pipeline, and eventually into somebody's
      transcript, for no gain.
    #>
    param([Parameter(Mandatory)][string]$InstallRoot)

    $envPath = Join-Path -Path $InstallRoot -ChildPath '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { return $null }

    $read = {
        param($Key)
        $value = Get-DeltaEnvValue -Path $envPath -Key $Key
        if ($null -eq $value) { return '' }
        return $value
    }

    $password = Get-DeltaEnvValue -Path $envPath -Key 'SMTP_PASS'

    return [PSCustomObject]@{
        Path           = $envPath
        Transport      = & $read 'EMAIL_TRANSPORT'
        From           = & $read 'EMAIL_FROM'
        Host           = & $read 'SMTP_HOST'
        Port           = & $read 'SMTP_PORT'
        User           = & $read 'SMTP_USER'
        Secure         = & $read 'SMTP_SECURE'
        HasPassword    = (-not [string]::IsNullOrEmpty($password))
        IsConfigured   = (-not [string]::IsNullOrEmpty((& $read 'EMAIL_TRANSPORT')))
    }
}

function Show-DeltaSmtpCurrentSettings {
    <#
      What is configured now, with the password represented by whether it
      exists rather than by its value.
    #>
    param([Parameter(Mandatory)][AllowNull()][object]$Current)

    Write-Host 'Current email configuration'
    if (-not $Current -or -not $Current.IsConfigured) {
        Write-Detail 'EMAIL_TRANSPORT is not set, so DELTA is using its own default: file.'
        Write-Detail 'Mail is written to the container log instead of being sent.'
        return
    }

    Write-Detail "EMAIL_TRANSPORT  $($Current.Transport)"
    Write-Detail "EMAIL_FROM       $(if ($Current.From) { $Current.From } else { '(not set)' })"
    if ($Current.Transport -eq 'smtp') {
        Write-Detail "SMTP_HOST        $(if ($Current.Host) { $Current.Host } else { '(not set)' })"
        Write-Detail "SMTP_PORT        $(if ($Current.Port) { $Current.Port } else { '(not set)' })"
        Write-Detail "SMTP_SECURE      $(if ($Current.Secure) { $Current.Secure } else { '(not set)' })"
        Write-Detail "SMTP_USER        $(if ($Current.User) { $Current.User } else { '(not set)' })"
        Write-Detail "SMTP_PASS        $(if ($Current.HasPassword) { '(configured - not shown)' } else { '(not set)' })"
    }
}

function Read-DeltaEmailTransportChoice {
    <#
      Which transport to use. Adapted from the reference installer's function
      of the same name, including Cancel as a first-class option: this screen
      is the flow's gate, and choosing Cancel must leave .env completely
      untouched.

      'file' is DELTA's own default and writes mail to the log instead of
      sending it - which is the right answer for a test installation and is
      described as such rather than as an error state.
    #>
    param([AllowNull()][string]$CurrentTransport)

    while ($true) {
        Write-Host ''
        Write-Host 'Choose the email transport:'
        Write-Host ''
        Write-Host '  1. File  - DELTA writes mail to its log instead of sending it (DELTA''s default)'
        Write-Host '  2. SMTP  - DELTA sends mail through a mail server you configure'
        Write-Host '  3. Cancel'
        Write-Host ''
        $choice = ([string](Read-Host -Prompt 'Selection')).Trim()

        switch ($choice) {
            '1' { return 'file' }
            '2' { return 'smtp' }
            '3' { return 'Cancel' }
            default { Write-DeltaWarning "'$choice' is not a valid option." }
        }
    }
}

function Read-DeltaEmailSettingValue {
    <#
      One non-secret setting. The current value is shown as the bracketed
      default and bare Enter keeps it, which is this project's convention
      everywhere an existing value can be kept.

      A value containing BOTH quote characters is refused, because that is the
      one shape .env's KEY="value" / KEY='value' framing cannot represent -
      the same rule Set-DeltaEnvValues enforces, applied here so the operator
      finds out while they can still retype it.

      $Validator is a scriptblock returning a human-readable error for a bad
      answer and $null for a good one, so each field states its own rule
      without this function hardcoding any of them.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [AllowNull()][AllowEmptyString()][string]$CurrentValue,
        [scriptblock]$Validator,
        [switch]$Optional
    )

    while ($true) {
        $hasCurrent = -not [string]::IsNullOrEmpty($CurrentValue)
        $hint = if ($hasCurrent) { " [$CurrentValue]" } elseif ($Optional) { ' [optional]' } else { '' }
        $answer = ([string](Read-Host -Prompt ($Prompt + $hint))).Trim()

        if (-not $answer) {
            if ($hasCurrent) { return $CurrentValue }
            if ($Optional) { return '' }
            Write-DeltaWarning 'A value is required.'
            continue
        }
        if ($answer.Contains('"') -and $answer.Contains("'")) {
            Write-DeltaWarning 'A value cannot contain both single and double quotes.'
            continue
        }
        if ($Validator) {
            $problem = & $Validator $answer
            if ($problem) { Write-DeltaWarning $problem; continue }
        }
        return $answer
    }
}

function Read-DeltaSmtpPassword {
    <#
      The SMTP_PASS prompt. Masked, entered twice, and the two must match -
      the same rule every operator-chosen credential in this project follows.

      Bare Enter on the first prompt returns $null, meaning "leave the
      existing value exactly as it is". That matters: the current password is
      a live credential this screen must never display, so "keep it" has to be
      expressible without retyping it, and the caller then never reads, echoes
      or rewrites that line at all.

      Returns a SecureString, converted to plain text only at the single point
      it is written to .env.
    #>
    param([Parameter(Mandatory)][bool]$HasCurrent)

    $hint = if ($HasCurrent) { 'Enter = keep the configured password' } else { 'Enter = leave unset' }
    while ($true) {
        $first = Read-Host -Prompt "SMTP password [$hint]" -AsSecureString
        $plainFirst = ConvertTo-DeltaPlainText -SecureString $first
        try {
            if ($plainFirst.Length -eq 0) { return $null }
            if ($plainFirst.Contains('"') -and $plainFirst.Contains("'")) {
                Write-DeltaWarning 'The password cannot contain both single and double quotes.'
                continue
            }

            $second = Read-Host -Prompt 'Confirm SMTP password' -AsSecureString
            $plainSecond = ConvertTo-DeltaPlainText -SecureString $second
            try {
                if ($plainFirst -cne $plainSecond) {
                    Write-DeltaWarning 'The passwords did not match. Try again.'
                    continue
                }
            }
            finally { $plainSecond = $null }
            return $first
        }
        finally { $plainFirst = $null }
    }
}

function Test-DeltaEmailFrom {
    <#
      Whether a value is usable as EMAIL_FROM.

      DELTA passes EMAIL_FROM straight to nodemailer's `from` field, which
      takes an RFC 5322 mailbox - so a display name is not an exotic extra, it
      is the ordinary form. DELTA's own built-in fallback is
      '"Example" <no-reply@example.com>', which settles the question: the
      application does not merely tolerate the display-name form, it ships it
      as its default. DELTA's own validator asks only that the value contain an
      "@" and a ".".

      An earlier version of this installer accepted a bare address only, which
      refused '"DELTA" <sender@example.org>' - a value the application is
      perfectly happy with. An installer must not be stricter than the thing it
      configures.

      Accepted:
        sender@example.org
        <sender@example.org>
        DELTA Notifications <sender@example.org>
        "DELTA" <sender@example.org>

      Still rejected: anything without an "@", a domain without a dot,
      unbalanced angle brackets, a bare address containing spaces, and
      trailing rubbish after the closing bracket.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $result = [PSCustomObject]@{
        IsValid     = $false
        Reason      = $null
        Address     = $null
        DisplayName = $null
    }

    $candidate = ([string]$Value).Trim()
    if (-not $candidate) {
        $result.Reason = 'A sender address is required.'
        return $result
    }
    # .env can frame a value in single or double quotes but has no escaping
    # convention every consumer agrees on, so a value needing both is refused
    # here - while the operator can still retype it - rather than at the write.
    if ($candidate.Contains('"') -and $candidate.Contains("'")) {
        $result.Reason = 'A sender address cannot contain both single and double quotes.'
        return $result
    }

    # local@domain.tld - no whitespace, no angle brackets, exactly one @, and a
    # dot in the domain, which is what DELTA itself checks for.
    $addr = '[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+'

    if ($candidate -match "^(?<addr>$addr)`$") {
        $result.Address = $Matches['addr']
        $result.IsValid = $true
        return $result
    }
    if ($candidate -match "^(?:(?<disp>`"[^`"]*`"|[^<>@`"]+?)\s*)?<(?<addr>$addr)>`$") {
        $result.Address = $Matches['addr']
        if ($Matches['disp']) { $result.DisplayName = $Matches['disp'].Trim() }
        $result.IsValid = $true
        return $result
    }

    # Name the specific defect - "invalid" on its own tells the operator
    # nothing about which half of the value to go and fix.
    if ($candidate -notmatch '@') {
        $result.Reason = "'$candidate' has no @, so it is not an email address."
    }
    elseif (($candidate -match '<') -ne ($candidate -match '>')) {
        $result.Reason = "'$candidate' has an unbalanced angle bracket. Use: `"Display Name`" <address@example.org>"
    }
    elseif ($candidate -match '<' -and $candidate -notmatch '>\s*$') {
        $result.Reason = "'$candidate' has something after the closing angle bracket."
    }
    elseif ((($candidate -split '@').Count - 1) -gt 1 -and $candidate -notmatch '<') {
        $result.Reason = "'$candidate' has more than one @."
    }
    elseif ($candidate -match '@[^\s<>@]*$' -and $candidate -notmatch '@[^\s<>@]*\.[^\s<>@]+') {
        $result.Reason = "The domain in '$candidate' has no dot. DELTA requires one."
    }
    elseif ($candidate -match '\s' -and $candidate -notmatch '<') {
        $result.Reason = "'$candidate' contains spaces. Use a plain address, or a display name with the address in angle brackets: `"DELTA`" <delta@example.org>"
    }
    else {
        $result.Reason = "'$candidate' is not a valid sender address. Use delta@example.org or `"DELTA`" <delta@example.org>."
    }
    return $result
}

function Test-DeltaSmtpEndpoint {
    <#
      The A§20.1 validation, and deliberately no more than it: the host
      resolves, and a TCP connection to host:port is accepted. A real send
      test needs a recipient and a mailbox to look in, and belongs to the
      application rather than to an installer.

      Reported as three distinct outcomes - resolved-and-connected, resolved
      but refused, and did not resolve - because they send the operator to
      three different places.
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = $Script:DeltaSmtpProbeTimeoutSeconds
    )

    $result = [PSCustomObject]@{ Succeeded = $false; Resolved = $false; Addresses = @(); Reason = $null }

    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($HostName)
        $result.Addresses = @($addresses | ForEach-Object { $_.IPAddressToString })
        $result.Resolved = ($result.Addresses.Count -gt 0)
    }
    catch {
        $result.Reason = "'$HostName' did not resolve: $($_.Exception.Message)"
        return $result
    }
    if (-not $result.Resolved) {
        $result.Reason = "'$HostName' did not resolve to any address."
        return $result
    }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            $result.Reason = "'$HostName' resolved to $($result.Addresses -join ', ') but did not accept a connection on port $Port within $TimeoutSeconds seconds."
            return $result
        }
        $client.EndConnect($connect)
        $result.Succeeded = $true
        $result.Reason = "Connected to ${HostName}:$Port."
    }
    catch {
        $result.Reason = "'$HostName' resolved to $($result.Addresses -join ', ') but the connection to port $Port was refused: $($_.Exception.Message)"
    }
    finally {
        try { $client.Close() } catch { }
    }

    return $result
}

function Get-DeltaContainerSmtpEnvironment {
    <#
      What the running delta container actually has in its environment, which
      is the only thing that proves a recreation applied the change - .env is
      what we asked for, this is what happened.

      Secret-safe by construction: the command run inside the container pipes
      env through sed to replace every value with a marker, so SMTP_PASS is
      reported as set or not set and its value never crosses the container
      boundary, never reaches this process, and never reaches a transcript.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName
    )

    $result = [PSCustomObject]@{ Succeeded = $false; Values = @{}; Reason = $null }

    # Non-secret keys are echoed with their values; SMTP_PASS is echoed only as
    # <set>/<unset>. Building it this way keeps the redaction inside the
    # container rather than trusting this side to strip it afterwards.
    $script = @'
for k in EMAIL_TRANSPORT EMAIL_FROM SMTP_HOST SMTP_PORT SMTP_USER SMTP_SECURE; do
  v=$(printenv "$k" 2>/dev/null || true)
  echo "$k=$v"
done
if [ -n "$(printenv SMTP_PASS 2>/dev/null || true)" ]; then echo "SMTP_PASS=<set>"; else echo "SMTP_PASS=<unset>"; fi
'@

    $capture = Invoke-DeltaActivity -Message 'Reading the delta container environment' -WhenIdle -ScriptBlock {
        Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @(
            'exec', '-T', 'delta', 'sh', '-c', $script
        ) -TimeoutSeconds 120
    }

    if ($capture.ExitCode -ne 0) {
        $result.Reason = "The delta container's environment could not be read: $((($capture.StdErr + ' ' + $capture.StdOut)).Trim())"
        return $result
    }

    $values = @{}
    foreach ($line in ($capture.StdOut -split "`r?`n")) {
        if ($line -match '^([A-Z_]+)=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
    }
    $result.Values = $values
    $result.Succeeded = ($values.Count -gt 0)
    if (-not $result.Succeeded) { $result.Reason = 'The container returned no environment values.' }
    return $result
}

function Set-DeltaSmtpEnvironment {
    <#
      Writes the collected settings into .env in one atomic operation.

      Only the keys this operation owns are written, and a $null value means
      "do not touch that key at all" - which is how "keep the configured
      password" reaches the file without the password ever being read.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )

    $envPath = Join-Path -Path $InstallRoot -ChildPath '.env'
    $write = [ordered]@{}
    foreach ($key in $Script:DeltaSmtpKeys) {
        if ($Values.Contains($key) -and $null -ne $Values[$key]) {
            $write[$key] = [string]$Values[$key]
        }
    }
    if ($write.Count -eq 0) { return $false }

    Set-DeltaEnvValues -Path $envPath -Values $write
    return $true
}

function Invoke-DeltaSmtpConfiguration {
    <#
      Menu option 5.

      The shape is: collect -> validate -> snapshot -> write -> apply ->
      verify, and every failure after "write" restores the previous values and
      says exactly how far the restoration got.

      Applying means recreating the delta container. `docker compose restart`
      does NOT pick up environment changes - it restarts the same container
      with the same environment - and that is the specific mistake A§20.1
      warns about. Recreation runs DELTA's own migration step, which is a
      no-op at a stable schema version but is not nothing, so this is treated
      as a real lifecycle operation with a health gate and an endpoint check.

      Only the delta service is recreated: --no-deps keeps Compose away from
      the database, whose container, volume and data are untouched throughout.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [bool]$AllowPrompt = $true
    )

    $result = [PSCustomObject]@{
        Succeeded        = $false
        Cancelled        = $false
        Stage            = 'start'
        Transport        = $null
        Reason           = $null
        EnvBackup        = $null
        EnvRestored      = $false
        RuntimeRestored  = $false
        Recreated        = $false
        ContainerEnv     = $null
        Http             = $null
    }

    Show-Section -Title 'Configure SMTP' -Subtitle $InstallRoot

    if (-not $AllowPrompt) {
        $result.Stage = 'prompt'
        $result.Reason = 'SMTP configuration is interactive and this run is non-interactive. Nothing was changed.'
        return $result
    }

    $current = Get-DeltaSmtpConfiguration -InstallRoot $InstallRoot
    if (-not $current) {
        $result.Stage = 'configuration'
        $result.Reason = "'$InstallRoot' has no readable .env, so there is nothing to configure."
        return $result
    }
    Show-DeltaSmtpCurrentSettings -Current $current

    # --- collect ----------------------------------------------------------
    $result.Stage = 'collect'
    $values = $null
    $transport = $null

    while ($true) {
        $transport = Read-DeltaEmailTransportChoice -CurrentTransport $current.Transport
        if ($transport -eq 'Cancel') {
            $result.Cancelled = $true
            $result.Stage = 'cancelled'
            $result.Reason = 'Cancelled. No configuration was changed and no container was recreated.'
            return $result
        }

        $collected = [ordered]@{ 'EMAIL_TRANSPORT' = $transport }

        Write-Host ''
        # Required, not optional: DELTA validates EMAIL_FROM on every page load
        # and shows a configuration-error page when it is missing or has no "@"
        # and ".". An empty answer here would break the login page.
        #
        # Both mailbox forms are accepted, because nodemailer accepts both and
        # DELTA's own fallback uses the display-name one.
        Write-Detail 'Either delta@example.org or "DELTA" <delta@example.org>.'
        $collected['EMAIL_FROM'] = Read-DeltaEmailSettingValue -Prompt 'From address (EMAIL_FROM)' -CurrentValue $current.From -Validator {
            param($v)
            $check = Test-DeltaEmailFrom -Value $v
            if (-not $check.IsValid) { return $check.Reason }
            return $null
        }

        if ($transport -eq 'file') {
            # Nothing else is read in file mode, and the SMTP_* keys are left
            # exactly as they are rather than being blanked: switching back to
            # smtp later should not mean retyping a server that never changed.
            $values = $collected
            break
        }

        $collected['SMTP_HOST'] = Read-DeltaEmailSettingValue -Prompt 'SMTP server host (SMTP_HOST)' -CurrentValue $current.Host -Validator {
            param($v)
            if ($v -match '\s') { return 'A host name cannot contain spaces.' }
            return $null
        }
        $collected['SMTP_PORT'] = Read-DeltaEmailSettingValue -Prompt 'SMTP server port (SMTP_PORT)' -CurrentValue $(if ($current.Port) { $current.Port } else { '587' }) -Validator {
            param($v)
            if (-not (Test-DeltaIntegerInRange -Value $v -Minimum 1 -Maximum 65535)) { return "'$v' is not a port number between 1 and 65535." }
            return $null
        }
        $collected['SMTP_SECURE'] = Read-DeltaEmailSettingValue -Prompt 'Use implicit TLS on connect - true for port 465, false for 587/25 (SMTP_SECURE)' -CurrentValue $(if ($current.Secure) { $current.Secure } else { 'false' }) -Validator {
            param($v)
            if ($v -notin @('true', 'false')) { return "Enter true or false." }
            return $null
        }
        # SMTP_USER and SMTP_PASS are NOT optional once the transport is smtp:
        # DELTA requires SMTP_HOST, SMTP_PORT, SMTP_USER and SMTP_PASS to be
        # present and reports each missing one as a configuration error on the
        # login page. An unauthenticated relay is therefore not expressible
        # through this screen - which is DELTA's constraint, not this
        # installer's, and it is better to say so here than to write a
        # configuration that renders an error page.
        $collected['SMTP_USER'] = Read-DeltaEmailSettingValue -Prompt 'SMTP username (SMTP_USER)' -CurrentValue $current.User -Validator {
            param($v)
            if ($v -match '\s') { return 'A username cannot contain spaces.' }
            return $null
        }

        $secure = Read-DeltaSmtpPassword -HasCurrent $current.HasPassword
        if (-not $secure -and -not $current.HasPassword) {
            Write-DeltaWarning 'DELTA requires an SMTP password when the transport is smtp - without one it will'
            Write-DeltaWarning 'show a configuration error on the login page. Enter one, or choose the file'
            Write-DeltaWarning 'transport instead.'
            $current = Get-DeltaSmtpConfiguration -InstallRoot $InstallRoot
            continue
        }
        if ($secure) {
            # Converted at the single point it is needed and released
            # immediately afterwards; it is never logged, never displayed and
            # never placed on a command line.
            $plain = ConvertTo-DeltaPlainText -SecureString $secure
            try {
                Register-DeltaSecretValue -Value $plain
                $collected['SMTP_PASS'] = $plain
            }
            finally { $plain = $null }
        }
        # else: the key is absent from $collected, so that .env line is not touched.

        # --- validate before anything is written --------------------------
        Write-Host ''
        Write-Step "Checking $($collected['SMTP_HOST']):$($collected['SMTP_PORT'])"
        $probe = Test-DeltaSmtpEndpoint -HostName $collected['SMTP_HOST'] -Port ([int]$collected['SMTP_PORT'])
        if ($probe.Succeeded) {
            Write-Detail "[ ok ]     $($probe.Reason)"
            $values = $collected
            break
        }

        Write-DeltaFailure ''
        Write-DeltaFailure 'That mail server could not be reached.'
        Write-Detail $probe.Reason
        Write-Detail ''
        Write-Detail 'Nothing has been written. This checks only that the host resolves and accepts a'
        Write-Detail 'connection - it does not test credentials or send mail.'
        Write-Host ''
        if (-not (Read-DeltaYesNoConfirmation -Body { Write-Host 'Re-enter the SMTP settings?' })) {
            $result.Cancelled = $true
            $result.Stage = 'cancelled'
            $result.Reason = 'Cancelled after a failed connection check. No configuration was changed.'
            return $result
        }
        # Re-read so the loop shows what is actually in .env, not what was typed.
        $current = Get-DeltaSmtpConfiguration -InstallRoot $InstallRoot
    }

    $result.Transport = $transport

    # --- snapshot ---------------------------------------------------------
    # Two things are preserved: a full timestamped copy of .env (hardened the
    # same way .env is), and the previous values of exactly the keys about to
    # change, which is what the restore path writes back.
    $result.Stage = 'snapshot'
    $envPath = Join-Path -Path $InstallRoot -ChildPath '.env'
    $previous = [ordered]@{}
    foreach ($key in $Script:DeltaSmtpKeys) {
        if ($key -eq 'SMTP_PASS') { continue }   # never read; never restored by value
        if ($values.Contains($key)) {
            $existing = Get-DeltaEnvValue -Path $envPath -Key $key
            if ($null -ne $existing) { $previous[$key] = $existing }
        }
    }
    $result.EnvBackup = Backup-DeltaEnvFile -Path $envPath

    # --- write ------------------------------------------------------------
    $result.Stage = 'write'
    $written = @($values.Keys | Where-Object { $Script:DeltaSmtpKeys -contains $_ -and $null -ne $values[$_] })
    try {
        $null = Set-DeltaSmtpEnvironment -InstallRoot $InstallRoot -Values $values
    }
    catch {
        $result.Reason = "The SMTP settings could not be written to .env: $($_.Exception.Message). No container was recreated."
        return $result
    }
    finally {
        # The plain password does not outlive the write.
        if ($values.Contains('SMTP_PASS')) { $values['SMTP_PASS'] = $null }
    }
    # Names only - EMAIL_TRANSPORT, SMTP_HOST and so on. No value is echoed,
    # which keeps SMTP_PASS out of the console as well as out of the log.
    Write-Detail "Wrote $($written.Count) setting(s) into ${envPath}: $($written -join ', ')"

    # --- apply ------------------------------------------------------------
    $result.Stage = 'apply'
    Write-Host ''
    Write-Step 'Applying the configuration'
    Write-Detail 'Environment changes need the container to be recreated; `docker compose restart` would'
    Write-Detail 'restart the same container with the same environment and change nothing.'

    $apply = Update-DeltaApplicationContainer -InstallRoot $InstallRoot -Configuration $Configuration
    $result.Recreated = $apply.Recreated
    $result.Http = $apply.Http

    if (-not $apply.Succeeded) {
        # Put .env back, then try to put the RUNNING container back. The two
        # are reported separately because they are different claims and the
        # second one can fail on its own.
        Write-DeltaFailure ''
        Write-DeltaFailure 'The new SMTP configuration could not be applied.'
        Write-Detail $apply.Reason
        Write-Detail ''
        Write-Step 'Restoring the previous SMTP configuration'

        $restoreValues = [ordered]@{}
        foreach ($key in $previous.Keys) { $restoreValues[$key] = $previous[$key] }
        # A key that did not exist before is set back to empty rather than
        # deleted: .env has no "unset" and an empty value is what DELTA reads
        # as absent.
        foreach ($key in $values.Keys) {
            if ($key -eq 'SMTP_PASS') { continue }
            if (-not $previous.Contains($key)) { $restoreValues[$key] = '' }
        }

        try {
            if ($restoreValues.Count -gt 0) { Set-DeltaEnvValues -Path $envPath -Values $restoreValues }
            $result.EnvRestored = $true
            Write-Detail '.env restored to its previous SMTP values.'
        }
        catch {
            Write-DeltaWarning "The previous SMTP values could not be written back: $($_.Exception.Message)"
            Write-DeltaWarning "A full copy of the previous .env is at $($result.EnvBackup)."
        }

        if ($result.EnvRestored) {
            $back = Update-DeltaApplicationContainer -InstallRoot $InstallRoot -Configuration $Configuration
            $result.RuntimeRestored = $back.Succeeded
            if ($back.Succeeded) {
                Write-Success 'The running container has been recreated with the previous configuration and is healthy.'
            }
            else {
                Write-DeltaFailure 'The container could NOT be brought back with the previous configuration.'
                Write-Detail $back.Reason
                Write-Detail 'DELTA may not be serving. The database and its data are untouched.'
                Write-Detail "The previous .env is also saved at $($result.EnvBackup)."
            }
        }

        $result.Stage = 'apply'
        $result.Reason = $apply.Reason
        return $result
    }

    # --- verify -----------------------------------------------------------
    $result.Stage = 'verify'
    $containerEnv = Get-DeltaContainerSmtpEnvironment -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName
    $result.ContainerEnv = $containerEnv
    if (-not $containerEnv.Succeeded) {
        Write-DeltaWarning "The configuration was applied but the container's environment could not be read back: $($containerEnv.Reason)"
    }
    elseif ($containerEnv.Values['EMAIL_TRANSPORT'] -ne $transport) {
        $result.Reason = "The container reports EMAIL_TRANSPORT='$($containerEnv.Values['EMAIL_TRANSPORT'])' but '$transport' was configured. The recreation did not pick up the new environment."
        return $result
    }

    $result.Stage = 'complete'
    $result.Succeeded = $true
    $result.Reason = "SMTP configuration applied; transport is '$transport'."
    return $result
}

function Update-DeltaApplicationContainer {
    <#
      Recreate the delta container so an environment change takes effect, then
      prove the result.

      Shared by the apply and the restore paths of the SMTP flow, which is
      what makes "we put it back" mean exactly the same operation as "we
      applied it" - a restore that used a weaker check than the change it
      undoes is how a half-restored installation gets reported as recovered.

      Sequence, and each step is a stop:
        1. the db service must be running - --no-deps means Compose will not
           start it, and a delta container without a database is not an
           improvement
        2. up -d --no-deps delta
        3. refresh NGINX's upstream. Phase 9 measured this: proxy_pass has no
           resolver, so NGINX caches the container address at config load, and
           a recreated container on a different address returns 502 from a
           completely healthy stack until nginx -s reload
        4. bounded wait for health
        5. a real request through NGINX
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [int]$HealthTimeoutSeconds = 300
    )

    $result = [PSCustomObject]@{
        Succeeded   = $false
        Recreated   = $false
        NginxReload = $null
        Http        = $null
        Reason      = $null
    }

    $services = @(Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName)
    $db = $services | Where-Object { $_.Service -eq 'db' } | Select-Object -First 1
    if (-not $db -or $db.State -ne 'running') {
        $result.Reason = "The database container is not running ($(if ($db) { $db.Status } else { 'no container' })), so the application container was not recreated."
        return $result
    }

    # The health wait below announces itself once this returns, so the pair is
    # continuous: container recreation, then waiting for it to come up.
    $up = Invoke-DeltaActivity -Message 'Recreating the DELTA application container' -ScriptBlock {
        Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Arguments @(
            'up', '-d', '--no-deps', 'delta'
        ) -TimeoutSeconds 900
    }
    if ($up.ExitCode -ne 0) {
        $result.Reason = "Recreating the DELTA container failed: $((($up.StdErr + ' ' + $up.StdOut)).Trim())"
        return $result
    }
    $result.Recreated = $true

    $result.NginxReload = Update-DeltaNginxUpstream -InstallRoot $InstallRoot -Configuration $Configuration

    $health = Wait-DeltaServiceHealthy -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Service 'delta' -TimeoutSeconds $HealthTimeoutSeconds
    if (-not $health.Succeeded) {
        Show-DeltaServiceLogs -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Service 'delta' -Tail 30
        $result.Reason = "The DELTA container did not become healthy within $HealthTimeoutSeconds seconds."
        return $result
    }

    $scheme = if ($Configuration.TlsEnabled) { 'https' } else { 'http' }
    $port = if ($Configuration.TlsEnabled) { [int]$Configuration.HttpsPort } else { [int]$Configuration.HttpPort }
    $url = (Get-DeltaPublicUrl -Scheme $scheme -HostName 'localhost' -Port $port) + '/'
    $result.Http = Test-DeltaHttpEndpoint -Url $url -TimeoutSeconds 60
    if (-not $result.Http.Succeeded) {
        $result.Reason = "The container was recreated and is healthy, but $url did not answer (HTTP $($result.Http.StatusCode) $($result.Http.Error))."
        return $result
    }

    Write-Detail "[ ok ]     GET $url returned $($result.Http.StatusCode)"
    $result.Succeeded = $true
    return $result
}

function Show-DeltaSmtpOutcome {
    <#
      Menu option 5's report.

      The restoration lines are deliberately two separate statements. ".env
      restored" and "the running container was recreated with it" are
      different facts, and a message that merged them into one cheerful
      "rolled back" would hide the case where the file is correct and the
      container is not.
    #>
    param(
        [Parameter(Mandatory)][object]$Outcome,
        # The menu pauses so its report is read before the menu repaints over
        # it. The installer's post-install offer does not: nothing overwrites
        # its output, and a second "press Enter" between a finished
        # installation and its completion summary is a prompt for no reason.
        [bool]$PauseForMenu = $true
    )

    Write-Host ''
    if ($Outcome.Succeeded) {
        Write-Success "SMTP configuration applied - transport '$($Outcome.Transport)'."
        if ($Outcome.ContainerEnv -and $Outcome.ContainerEnv.Succeeded) {
            Write-Detail 'The running container reports:'
            foreach ($key in @('EMAIL_TRANSPORT', 'EMAIL_FROM', 'SMTP_HOST', 'SMTP_PORT', 'SMTP_SECURE', 'SMTP_USER', 'SMTP_PASS')) {
                if ($Outcome.ContainerEnv.Values.ContainsKey($key)) {
                    $shown = $Outcome.ContainerEnv.Values[$key]
                    if (-not $shown) { $shown = '(not set)' }
                    Write-Detail ("  {0,-16} {1}" -f $key, $shown)
                }
            }
        }
        if ($Outcome.Http) { Write-Detail "Endpoint       HTTP $($Outcome.Http.StatusCode)" }
        if ($Outcome.EnvBackup) { Write-Detail "Previous .env  $($Outcome.EnvBackup)" }
        Write-Detail ''
        Write-Detail 'Only the DELTA application container was recreated. The database container, its'
        Write-Detail 'volume, NGINX, uploads and certificates were not touched.'
    }
    elseif ($Outcome.Cancelled) {
        Write-Detail $Outcome.Reason
    }
    else {
        Write-DeltaFailure 'The SMTP configuration was not applied.'
        Write-Detail "Stage reached  $($Outcome.Stage)"
        Write-Detail $Outcome.Reason
        Write-Detail ''
        if ($Outcome.EnvRestored) { Write-Detail '.env: the previous SMTP values were written back.' }
        elseif ($Outcome.Stage -in @('write', 'apply')) { Write-DeltaWarning ".env: NOT restored automatically. A full copy is at $($Outcome.EnvBackup)." }
        else { Write-Detail '.env: unchanged - the failure happened before anything was written.' }

        if ($Outcome.RuntimeRestored) { Write-Detail 'Runtime: the container was recreated with the previous configuration and is healthy.' }
        elseif ($Outcome.Recreated) { Write-DeltaWarning 'Runtime: the container was recreated but has NOT been confirmed healthy on the previous configuration.' }
        else { Write-Detail 'Runtime: no container was recreated.' }
    }

    if ($PauseForMenu) {
        Write-Host ''
        Write-Detail 'Press Enter to return to the menu.'
        $null = Read-Host
    }
}

# ---------------------------------------------------------------------------
# The post-install SMTP offer
#
# One question at the end of a fresh installation, and nothing more. The
# configuration itself is Invoke-DeltaSmtpConfiguration above - the same
# collect -> validate -> snapshot -> write -> apply -> verify path menu option
# 5 runs, with the same rollback - so there is exactly one SMTP implementation
# and this section only decides whether it runs.
# ---------------------------------------------------------------------------

function Show-DeltaSmtpDeferralNotice {
    <#
      What an operator who has not configured SMTP needs to know: that the
      installation is fine, what happens to mail instead, and how to come back
      to it. Said the same way whichever route got here - declined, cancelled,
      failed, or non-interactive - because the situation is the same in all
      four cases.

      "Written to the container log" is DELTA's own behaviour on
      EMAIL_TRANSPORT=file, which is what a fresh .env already sets, so this
      describes the state the installation is actually in rather than a
      degraded one.
    #>

    Write-Host ''
    Write-Detail 'SMTP is not configured. DELTA is fully usable: it writes outgoing email messages'
    Write-Detail 'to the DELTA container log instead of sending them (menu option 10, View Logs).'
    Write-Detail 'To set up email later, run setup.ps1 again and choose "5. Configure SMTP".'
}

function Invoke-DeltaPostInstallSmtpOffer {
    <#
      Offers SMTP configuration once, at the end of a successful installation.

      Optional in the strong sense. This runs after DELTA is installed,
      published and verified, and nothing it does can change that verdict: a
      declined offer, a cancelled flow, a failed apply, an unexpected error and
      a non-interactive run all end the same way - the installation is still
      successful and the operator is told how to configure email later. That is
      also why the whole body is wrapped: setup.ps1's top-level catch turns any
      escaping exception into a failed install, and an optional extra must not
      be able to do that.

      A failure is retryable rather than terminal. Invoke-DeltaSmtpConfiguration
      already restores .env and the running container when an apply fails, so a
      second attempt starts from the same place the first one did - which is
      what makes offering the retry honest rather than hopeful.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [bool]$AllowPrompt = $true
    )

    $result = [PSCustomObject]@{
        Configured = $false
        Attempts   = 0
        Outcome    = $null
    }

    try {
        Write-Host ''
        Write-Step 'Email (SMTP)'
        Write-Detail 'DELTA uses email when creating user accounts and for account services such as'
        Write-Detail 'password resets. A mail server is not required to run DELTA; without SMTP,'
        Write-Detail 'outgoing messages are written to the application log instead of being sent.'
        Write-Host ''
        Write-Detail 'You can configure SMTP now or at any time later.'

        if (-not $AllowPrompt) {
            Write-Detail 'This run is non-interactive, so SMTP was not configured.'
            Show-DeltaSmtpDeferralNotice
            return $result
        }

        Write-Host ''
        if (-not (Read-DeltaInlineConfirmation -Prompt 'Configure SMTP now? [y/N]')) {
            Show-DeltaSmtpDeferralNotice
            return $result
        }

        while ($true) {
            $result.Attempts++

            $outcome = Invoke-DeltaSmtpConfiguration -InstallRoot $InstallRoot -Configuration $Configuration -AllowPrompt $true
            $result.Outcome = $outcome
            Show-DeltaSmtpOutcome -Outcome $outcome -PauseForMenu $false

            if ($outcome.Succeeded) {
                $result.Configured = $true
                return $result
            }

            Write-Host ''
            if (-not (Read-DeltaInlineConfirmation -Prompt 'Try SMTP configuration again? [y/N]')) {
                Show-DeltaSmtpDeferralNotice
                return $result
            }
        }
    }
    catch {
        Write-DeltaWarning "SMTP configuration stopped with an error: $($_.Exception.Message)"
        Write-Detail 'The installation itself is unaffected.'
        Write-DeltaLogLine -Message $_.ScriptStackTrace -Level 'ERROR'
        Show-DeltaSmtpDeferralNotice
        return $result
    }
}

# ---------------------------------------------------------------------------
# Administrator credential (A§20.2)
# ---------------------------------------------------------------------------

function Invoke-DeltaAdminResetOperation {
    <#
      Menu option 6.

      Phase 5 already built the whole reset - confirmation gate, read-only
      account lookup, generate-or-type, the `\getenv` transport that keeps the
      credential off every command line, and a three-part proof that it worked.
      This adds the menu framing and nothing else; reimplementing any of it
      would create a second way to change the same credential.

      Nothing here recreates a container or touches configuration: the
      operation changes one database row.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [bool]$AllowPrompt = $true
    )

    Show-Section -Title 'Reset Administrator Password' -Subtitle $InstallRoot

    if (-not $AllowPrompt) {
        Write-Detail 'Resetting the administrator credential is interactive and this run is non-interactive.'
        Write-Detail 'Nothing was changed.'
        return [PSCustomObject]@{ Succeeded = $false; Cancelled = $false; Reason = 'Non-interactive run.' }
    }

    $reset = Invoke-DeltaAdminPasswordReset -InstallRoot $InstallRoot -Configuration $Configuration -AllowPrompt $AllowPrompt

    Write-Host ''
    if ($reset.Cancelled) {
        Write-Detail 'Cancelled. The administrator credential is unchanged.'
    }
    elseif ($reset.Succeeded) {
        Write-Success "The administrator credential for $($reset.Email) has been replaced."
        if ($reset.WasGenerated -and $reset.Password) {
            # Shown exactly once, to the console only. The redacting log never
            # receives it, and it is not written to .env or the state file.
            $plain = ConvertTo-DeltaPlainText -SecureString $reset.Password
            try {
                Write-Host ''
                Write-Host '  Generated password (shown once - copy it now):'
                Write-Host ''
                Write-Host "      $plain"
                Write-Host ''
            }
            finally { $plain = $null }
        }
        Write-Detail "Sign in at $((Get-DeltaPublicUrl -Scheme $(if ($Configuration.TlsEnabled) { 'https' } else { 'http' }) -HostName $Configuration.HostName -Port $(if ($Configuration.TlsEnabled) { [int]$Configuration.HttpsPort } else { [int]$Configuration.HttpPort })))/en/admin/login"
        Write-Detail 'No container was restarted or recreated, and no other configuration changed.'
    }
    else {
        Write-DeltaFailure 'The administrator credential was NOT changed.'
        Write-Detail $reset.Reason
        Write-Detail 'Nothing else was modified.'
    }

    Write-Host ''
    Write-Detail 'Press Enter to return to the menu.'
    $null = Read-Host
    return $reset
}

# ---------------------------------------------------------------------------
# TLS certificate replacement (A§11, A§8.3)
# ---------------------------------------------------------------------------

function Get-DeltaInstalledCertificate {
    <#
      What certs\delta.crt currently is, for display. Reads the certificate
      only - the private key beside it is never opened, parsed or described
      beyond whether the file exists.
    #>
    param([Parameter(Mandatory)][string]$InstallRoot)

    $certPath = Join-Path -Path $InstallRoot -ChildPath "certs\$Script:DeltaCertificateFileName"
    $keyPath  = Join-Path -Path $InstallRoot -ChildPath "certs\$Script:DeltaCertificateKeyName"

    $result = [PSCustomObject]@{
        Exists          = (Test-Path -LiteralPath $certPath -PathType Leaf)
        KeyExists       = (Test-Path -LiteralPath $keyPath -PathType Leaf)
        CertificatePath = $certPath
        KeyPath         = $keyPath
        Subject         = $null
        Issuer          = $null
        NotAfter        = $null
        DaysRemaining   = $null
        Thumbprint      = $null
        Reason          = $null
    }
    if (-not $result.Exists) { return $result }

    try {
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath)
        $result.Subject       = $certificate.Subject
        $result.Issuer        = $certificate.Issuer
        $result.NotAfter      = $certificate.NotAfter
        $result.Thumbprint    = $certificate.Thumbprint
        $result.DaysRemaining = [int][math]::Floor(($certificate.NotAfter - (Get-Date)).TotalDays)
    }
    catch {
        $result.Reason = "The installed certificate could not be parsed: $($_.Exception.Message)"
    }
    return $result
}

function Get-DeltaServedCertificateThumbprint {
    <#
      The thumbprint of the certificate NGINX is actually presenting, which is
      what proves a reload took effect - the file on disk only proves what was
      staged.

      Trust is deliberately not enforced: a self-signed certificate is a
      legitimate configuration here, and refusing to look at it would mean the
      installer could not verify the certificate it just installed. The
      relaxed callback is restored in a finally block, exactly as
      Test-DeltaHttpEndpoint does it.
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 15
    )

    $previous = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    $captured = $null
    $client = $null
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
            param($senderObject, $certificate, $chain, $errors)
            $script:DeltaCapturedCertificate = $certificate
            return $true
        }
        $client = New-Object System.Net.Sockets.TcpClient
        $connect = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            return $null
        }
        $client.EndConnect($connect)

        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, {
            param($senderObject, $certificate, $chain, $errors)
            $script:DeltaCapturedCertificate = $certificate
            return $true
        })
        try {
            $ssl.AuthenticateAsClient($HostName)
            if ($ssl.RemoteCertificate) {
                $captured = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)).Thumbprint
            }
        }
        finally { $ssl.Dispose() }
    }
    catch {
        return $null
    }
    finally {
        if ($client) { try { $client.Close() } catch { } }
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
    }
    return $captured
}

function Backup-DeltaCertificateMaterial {
    <#
      Timestamped copies of the certificate and key currently in certs\,
      taken before either is replaced. The key copy gets the same ACL as the
      original - a backup of a private key with an inherited ACL beside a
      locked-down one would undo the hardening completely.
    #>
    param([Parameter(Mandatory)][string]$InstallRoot)

    $current = Get-DeltaInstalledCertificate -InstallRoot $InstallRoot
    $result = [PSCustomObject]@{ CertificateBackup = $null; KeyBackup = $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    if ($current.Exists) {
        $result.CertificateBackup = "$($current.CertificatePath).bak-$stamp"
        Copy-Item -LiteralPath $current.CertificatePath -Destination $result.CertificateBackup -Force
    }
    if ($current.KeyExists) {
        $result.KeyBackup = "$($current.KeyPath).bak-$stamp"
        Copy-Item -LiteralPath $current.KeyPath -Destination $result.KeyBackup -Force
        Protect-DeltaSecretFile -Path $result.KeyBackup
    }
    return $result
}

function Restore-DeltaCertificateMaterial {
    <#
      Puts the backed-up certificate and key back, and re-applies the key's
      ACL. Returns whether both halves were restored - the caller must not
      claim a rollback on a partial result.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Backup
    )

    $current = Get-DeltaInstalledCertificate -InstallRoot $InstallRoot
    $restored = $true

    if ($Backup.CertificateBackup -and (Test-Path -LiteralPath $Backup.CertificateBackup -PathType Leaf)) {
        try { Copy-Item -LiteralPath $Backup.CertificateBackup -Destination $current.CertificatePath -Force }
        catch { $restored = $false }
    }
    else { $restored = $false }

    if ($Backup.KeyBackup -and (Test-Path -LiteralPath $Backup.KeyBackup -PathType Leaf)) {
        try {
            Copy-Item -LiteralPath $Backup.KeyBackup -Destination $current.KeyPath -Force
            Protect-DeltaSecretFile -Path $current.KeyPath
        }
        catch { $restored = $false }
    }
    else { $restored = $false }

    return $restored
}

# ---------------------------------------------------------------------------
# Certificate Management itself lives in lib\Delta.Tls.ps1.
#
# It was moved out of this file when Certificate Management gained the ability
# to enable and disable HTTPS rather than only replace a certificate: that is a
# TLS state transition touching .env, the Compose file, the NGINX
# configuration, the published ports and the firewall, which is a different and
# much larger thing than the SMTP and administrator-credential operations this
# file exists for.
#
# The four primitives above stayed here, unchanged and still Phase 10's: they
# are consumed by Delta.Tls.ps1 rather than reimplemented, and uninstall.ps1
# loads this file without needing the transition logic at all.
# ---------------------------------------------------------------------------
