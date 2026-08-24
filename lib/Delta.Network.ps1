# =============================================================================
# Delta.Network.ps1 - port occupancy and ownership, port resolution, TLS mode,
#                     certificate validation and staging, URL construction
#
# Dot-source Delta.Common.ps1, Delta.Config.ps1, Delta.Docker.ps1 and
# Delta.Stack.ps1 first: this file uses Invoke-DeltaCompose and the Compose
# status reader from Delta.Stack.ps1 to answer "is this port ours?".
#
# Assessment references: A§10 (networking and ports), A§11 (HTTPS and
# certificates), A§14/A§15 (the port/TLS flow), A§24 (secrets and ACLs).
# =============================================================================

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$Script:DeltaDefaultHttpPort  = 80
$Script:DeltaDefaultHttpsPort = 443
$Script:DeltaSuggestedHttpPort  = 8080
$Script:DeltaSuggestedHttpsPort = 8443

# Staged certificate material always lands on these names, so the generated
# NGINX configuration is stable regardless of what the operator's files were
# called.
$Script:DeltaCertificateFileName = 'delta.crt'
$Script:DeltaCertificateKeyName  = 'delta.key'

# Certificate cryptography runs in the database image's OpenSSL. That image is
# already required and already pulled, it is the only one of the three that
# ships the openssl binary (nginx:alpine and the DELTA image do not - measured),
# and using a container avoids both a vendored BouncyCastle DLL and any
# involvement of the Windows certificate store, which A§23 removes from this
# product entirely.
$Script:DeltaOpenSslImageEnvKey = 'DB_IMAGE'

# ---------------------------------------------------------------------------
# URL construction (A§11.3)
#
# The single helper. PUBLIC_URL, the HTTP->HTTPS redirect, the completion
# summary and - later - the access guide all come through here, because the
# way these three come to disagree is by each formatting a URL itself.
# ---------------------------------------------------------------------------

function Get-DeltaPublicUrl {
    <#
      Builds the canonical public URL for a scheme/host/port triple, omitting
      the port when it is that scheme's default and including it otherwise:

        http  + 80   -> http://host
        http  + 8080 -> http://host:8080
        https + 443  -> https://host
        https + 8443 -> https://host:8443

      Never a trailing slash, so every consumer can append a path directly.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('http', 'https')][string]$Scheme,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port
    )

    $default = if ($Scheme -eq 'https') { $Script:DeltaDefaultHttpsPort } else { $Script:DeltaDefaultHttpPort }
    if ($Port -eq $default) {
        return "${Scheme}://${HostName}"
    }
    return "${Scheme}://${HostName}:${Port}"
}

function Get-DeltaPublicUrlParts {
    <#
      The inverse of Get-DeltaPublicUrl: takes a PUBLIC_URL and returns the
      scheme, host and port it was built from, with the scheme's default port
      filled in when the URL omits it.

      It lives here, beside the constructor, for the reason the constructor
      exists: there is one place that knows how a DELTA public URL is put
      together, and taking one apart is the same knowledge read backwards. A
      caller that needed only the hostname and wrote its own -replace would be
      the second implementation.

      Returns IsValid plus Reason. An unparseable or non-HTTP value is reported,
      never guessed at.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Url)

    $result = [PSCustomObject]@{
        IsValid  = $false
        Reason   = $null
        Scheme   = $null
        HostName = $null
        Port     = 0
        Url      = $Url
    }

    if ([string]::IsNullOrWhiteSpace($Url)) {
        $result.Reason = 'No URL was supplied.'
        return $result
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url.Trim(), [System.UriKind]::Absolute, [ref]$uri)) {
        $result.Reason = "'$Url' is not an absolute URL."
        return $result
    }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
        $result.Reason = "'$Url' does not use http or https."
        return $result
    }

    # Uri.Host strips the brackets from an IPv6 literal, which is the form the
    # rest of this installer works in.
    $result.Scheme   = $uri.Scheme
    $result.HostName = $uri.Host
    $result.Port     = if ($uri.IsDefaultPort) {
        if ($uri.Scheme -eq 'https') { $Script:DeltaDefaultHttpsPort } else { $Script:DeltaDefaultHttpPort }
    } else { $uri.Port }

    if (-not $result.HostName) {
        $result.Reason = "'$Url' has no host part."
        return $result
    }

    $result.IsValid = $true
    return $result
}

# ---------------------------------------------------------------------------
# Port occupancy and ownership (A§10.2)
# ---------------------------------------------------------------------------

function Get-DeltaPortListeners {
    <#
      Every LISTEN socket on $Port, with the owning process and - when the
      owner is a Windows service - its service name, so a conflict can be
      reported as something an operator recognises.

      Get-NetTCPConnection is the detector, and all matching listeners are
      enumerated rather than only the first: a port can be bound on several
      addresses, and during the assessment a TcpListener bind probe reported
      an actively published Docker port as free because Docker had bound only
      ::1. A bind probe is never used here.
    #>
    param([Parameter(Mandatory)][int]$Port)

    $listeners = New-Object 'System.Collections.Generic.List[object]'
    $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)

    foreach ($connection in $connections) {
        $processId = [int]$connection.OwningProcess
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue

        $serviceName = $null
        $serviceDisplayName = $null
        try {
            $service = Get-CimInstance -ClassName Win32_Service -Filter "ProcessId = $processId" -ErrorAction Stop | Select-Object -First 1
            if ($service) {
                $serviceName = [string]$service.Name
                $serviceDisplayName = [string]$service.DisplayName
            }
        }
        catch { }

        $null = $listeners.Add([PSCustomObject]@{
            Port               = $Port
            LocalAddress       = [string]$connection.LocalAddress
            ProcessId          = $processId
            ProcessName        = if ($process) { $process.ProcessName } else { $null }
            ServiceName        = $serviceName
            ServiceDisplayName = $serviceDisplayName
        })
    }

    return $listeners.ToArray()
}

function Format-DeltaPortOwner {
    <#
      One human-readable line naming who holds a port. The service name is
      included when there is one, because "W3SVC (World Wide Web Publishing
      Service)" is actionable in a way that "svchost, PID 1234" is not.
    #>
    param([Parameter(Mandatory)][object[]]$Listeners)

    $descriptions = foreach ($listener in $Listeners) {
        $who = if ($listener.ProcessName) { $listener.ProcessName } else { 'an unidentified process' }
        $text = "$who (PID $($listener.ProcessId))"
        if ($listener.ServiceName) {
            $text += ", Windows service $($listener.ServiceName)"
            if ($listener.ServiceDisplayName) { $text += " - $($listener.ServiceDisplayName)" }
        }
        "$text on $($listener.LocalAddress)"
    }
    return (($descriptions | Select-Object -Unique) -join '; ')
}

function Test-DeltaContainerFromInstallation {
    <#
      Whether a container was created from *this* installation's compose file,
      read from the container's own
      com.docker.compose.project.config_files label.

      This is what makes port ownership a statement about this installation
      rather than about the name it happens to use. Two installations that
      chose the same Compose project name are still distinguishable, and an
      unrelated project can never be mistaken for ours.
    #>
    param(
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][string]$ComposeFile
    )

    $capture = Invoke-DeltaDockerCommand -Arguments @(
        'container', 'inspect', $ContainerName,
        '--format', '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
    ) -TimeoutSeconds 60

    if ($capture.ExitCode -ne 0 -or -not $capture.StdOut) { return $false }

    $configFiles = ($capture.StdOut -split "`r?`n" | Select-Object -First 1).Trim()
    if (-not $configFiles) { return $false }

    $expected = $ComposeFile.Trim()
    foreach ($candidate in ($configFiles -split ',')) {
        if ($candidate.Trim() -and [string]::Equals($candidate.Trim(), $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-DeltaProjectPublishedPorts {
    <#
      The host ports published by *this* installation's Compose project.

      This is the ownership test, and it is deliberately narrow. It is not
      "something Docker-ish holds the port" - Docker holds the port for every
      container on the host, including other projects' - it is "a container in
      the Compose project this installation owns, described by this
      installation's own compose file and .env, publishes this port". An
      unrelated Compose project on the same port is therefore foreign, which
      is the whole point of the check.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName
    )

    $ports = New-Object 'System.Collections.Generic.List[object]'

    $composeFile = Join-Path -Path $InstallRoot -ChildPath 'docker-compose.yml'
    if (-not (Test-Path -LiteralPath $composeFile -PathType Leaf)) {
        return $ports.ToArray()
    }

    foreach ($service in (Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $ProjectName)) {
        if ($service.State -ne 'running') { continue }

        # A project name on its own is not proof of ownership: `docker compose
        # ps --project-name X` lists whatever carries that label, whichever
        # compose file it came from - measured, by pointing this installer's
        # compose file at an unrelated project's name and getting that
        # project's container back. So the container's own
        # com.docker.compose.project.config_files label must also point at
        # *this* installation's compose file before its ports count as ours.
        if (-not (Test-DeltaContainerFromInstallation -ContainerName $service.Name -ComposeFile $composeFile)) {
            continue
        }

        foreach ($publisher in @($service.Ports)) {
            if (-not $publisher) { continue }
            $published = 0
            if ($publisher.PSObject.Properties.Name -contains 'PublishedPort') {
                $published = [int]$publisher.PublishedPort
            }
            if ($published -le 0) { continue }
            $null = $ports.Add([PSCustomObject]@{
                Port        = $published
                TargetPort  = if ($publisher.PSObject.Properties.Name -contains 'TargetPort') { [int]$publisher.TargetPort } else { 0 }
                Service     = $service.Service
                Container   = $service.Name
            })
        }
    }

    return $ports.ToArray()
}

function Test-DeltaPortState {
    <#
      Classifies one candidate port into exactly one of three states:

        free    - nothing is listening
        owned   - listening, and this installation's own Compose project
                  publishes it, so it is not a conflict at all
        foreign - listening, and somebody else has it

      On a rerun the installation's own published port is always in LISTEN
      (held by Docker's relay on its behalf), so without the owned state every
      rerun would report a conflict against itself and push the operator into
      changing a port that works.
    #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName
    )

    $listeners = Get-DeltaPortListeners -Port $Port
    if ($listeners.Count -eq 0) {
        return [PSCustomObject]@{ Port = $Port; State = 'free'; Listeners = @(); Owner = $null; OwnedBy = $null }
    }

    $ours = @(Get-DeltaProjectPublishedPorts -InstallRoot $InstallRoot -ProjectName $ProjectName | Where-Object { $_.Port -eq $Port })
    if ($ours.Count -gt 0) {
        return [PSCustomObject]@{
            Port      = $Port
            State     = 'owned'
            Listeners = $listeners
            Owner     = Format-DeltaPortOwner -Listeners $listeners
            OwnedBy   = "$($ours[0].Container) (service $($ours[0].Service)) in Compose project '$ProjectName'"
        }
    }

    return [PSCustomObject]@{
        Port      = $Port
        State     = 'foreign'
        Listeners = $listeners
        Owner     = Format-DeltaPortOwner -Listeners $listeners
        OwnedBy   = $null
    }
}

function Resolve-DeltaPort {
    <#
      Settles one published port, following A§14.

      A free port is adopted in silence - no question is asked, because that is
      the overwhelmingly common case and a question is a cost. A port this
      installation already publishes is likewise adopted in silence. Only a
      genuine foreign conflict interrupts the operator, and then the incumbent
      is named and left completely alone: DELTA moves, the incumbent stays.

      The operator's alternative re-enters this same function, so there is one
      detector and one behaviour rather than a second, divergent check for
      replacement ports.

      With -AllowPrompt:$false (a port supplied on the command line, or any
      non-interactive run) a conflict is reported and refused rather than
      prompted, because inventing a different port on the operator's behalf is
      exactly the silent surprise this flow exists to avoid.
    #>
    param(
        [Parameter(Mandatory)][string]$Purpose,
        [Parameter(Mandatory)][int]$Candidate,
        [Parameter(Mandatory)][int]$Suggested,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [int]$OtherPort = 0,
        [string]$OtherPurpose,
        [bool]$AllowPrompt = $true
    )

    $port = $Candidate

    while ($true) {
        if (-not (Test-DeltaIntegerInRange -Value "$port" -Minimum 1 -Maximum 65535)) {
            $message = "$port is not a valid TCP port. Ports run from 1 to 65535."
            if (-not $AllowPrompt) { return [PSCustomObject]@{ Succeeded = $false; Port = 0; Reason = $message } }
            Write-DeltaWarning $message
        }
        elseif ($OtherPort -gt 0 -and $port -eq $OtherPort) {
            $message = "Port $port is already the $OtherPurpose port. HTTP and HTTPS cannot share one port."
            if (-not $AllowPrompt) { return [PSCustomObject]@{ Succeeded = $false; Port = 0; Reason = $message } }
            Write-DeltaWarning $message
        }
        else {
            $state = Test-DeltaPortState -Port $port -InstallRoot $InstallRoot -ProjectName $ProjectName

            if ($state.State -eq 'free') {
                Write-Detail "[ ok ]     $Purpose port $port is free."
                return [PSCustomObject]@{ Succeeded = $true; Port = $port; Reason = $null; State = 'free' }
            }
            if ($state.State -eq 'owned') {
                Write-Detail "[ ok ]     $Purpose port $port is already published by this installation ($($state.OwnedBy))."
                return [PSCustomObject]@{ Succeeded = $true; Port = $port; Reason = $null; State = 'owned' }
            }

            Write-DeltaWarning "Port $port is in use by $($state.Owner)."
            Write-Detail 'That process is left running and untouched - DELTA moves instead.'
            if (-not $AllowPrompt) {
                return [PSCustomObject]@{
                    Succeeded = $false; Port = 0; State = 'foreign'
                    Reason = "Port $port is in use by $($state.Owner). Choose a different $Purpose port."
                }
            }
            if ($port -eq $Suggested) { $Suggested = $port + 1 }
        }

        Write-Host ''
        $answer = Read-Host -Prompt "Enter a different $Purpose port [$Suggested]"
        Write-DeltaLogLine -Message "Operator entered a $Purpose port: '$answer'" -Level 'DETAIL'

        if ([string]::IsNullOrWhiteSpace($answer)) {
            $port = $Suggested
            continue
        }
        if ($answer.Trim() -in @('q', 'Q', 'cancel')) {
            return [PSCustomObject]@{ Succeeded = $false; Port = 0; Reason = "Port selection was cancelled." }
        }
        if (-not (Test-DeltaIntegerInRange -Value $answer -Minimum 1 -Maximum 65535)) {
            Write-DeltaWarning "'$($answer.Trim())' is not a whole number between 1 and 65535."
            continue
        }

        $port = [int]$answer.Trim()
        if ($port -lt 1024) {
            Write-DeltaWarning "Port $port is a privileged port. That is allowed - this installer runs elevated - but it is unusual for a web service other than 80 or 443."
        }
    }
}

# ---------------------------------------------------------------------------
# Certificates (A§11.2)
# ---------------------------------------------------------------------------

function Invoke-DeltaOpenSsl {
    <#
      Runs openssl in a throwaway container against a read-only mount of the
      directory holding the material. Nothing is written back unless the
      caller mounts something writable, the container is removed immediately,
      and the private key never appears in an argument, an environment
      variable or a log line - only file paths inside the container do.

      No secret is ever passed to openssl here. The certificate sources this
      installer accepts are a PEM certificate and an unencrypted PEM key, and
      neither needs a password to read - so there is no password channel to get
      wrong.

      The command is normalised to LF endings before it reaches sh. The scripts
      below are here-strings in a .ps1 file, so their line endings are whatever
      git, an editor or the release packager last left on disk - and a CR is a
      literal character to this image's dash, not whitespace. See
      ConvertTo-DeltaShellScript for what that costs when it is not done.
    #>
    param(
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$MountPath,
        [switch]$Writable,
        [int]$TimeoutSeconds = 180
    )

    $script = ConvertTo-DeltaShellScript -Script $Command

    # Starting a container is never instant, and on the first certificate
    # operation of an installation the image may not be local yet - which turns
    # a "checking your certificate" pause into a silent minute. -WhenIdle, so
    # the callers below that name what they are actually doing keep their own
    # message and this adds nothing.
    $mount = if ($Writable) { "${MountPath}:/work" } else { "${MountPath}:/work:ro" }
    return (Invoke-DeltaActivity -Message 'Running OpenSSL in a container' -WhenIdle -ScriptBlock {
        Invoke-DeltaDockerCommand -Arguments @(
            'run', '--rm', '--network', 'none', '-v', $mount, '--entrypoint', 'sh', $Image, '-c', $script
        ) -TimeoutSeconds $TimeoutSeconds
    })
}

function Test-DeltaPrivateKeyEncrypted {
    <#
      Whether a PEM private key is passphrase-protected, decided from the two
      textual markers the format guarantees - "BEGIN ENCRYPTED PRIVATE KEY"
      (PKCS#8) or a "Proc-Type: 4,ENCRYPTED" header (legacy OpenSSL). Adapted
      from the reference installer.

      NGINX cannot use an encrypted key without an ssl_password_file, which
      would mean storing the passphrase in plaintext next to the key and
      buying nothing, so an encrypted key is rejected with an instruction
      rather than accommodated.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $false }
    return [bool]($content -match 'BEGIN ENCRYPTED PRIVATE KEY' -or $content -match 'Proc-Type:\s*4\s*,\s*ENCRYPTED')
}

function Test-DeltaCertificateMaterial {
    <#
      Validates a certificate and private key before either is allowed
      anywhere near the live configuration (A§11.2):

        1. both files exist and are readable
        2. the certificate parses
        3. the private key is not passphrase-protected
        4. the private key matches the certificate
        5. the certificate is not expired; expiry within 30 days warns

      Step 4 is the one that matters. Existence and parseability catch typos;
      "the private key does not match the certificate" is the defect that
      otherwise sails through generation and surfaces as a cryptic NGINX error
      at startup. It is checked by comparing the public key derived from the
      key with the public key inside the certificate, which is format- and
      algorithm-agnostic.

      Returns IsValid plus a Reason naming the specific defect - never a
      generic "invalid certificate", because the operator has to know which of
      the two files to go and fix.
    #>
    param(
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$OpenSslImage
    )

    $result = [PSCustomObject]@{
        IsValid         = $false
        Reason          = $null
        Warning         = $null
        Subject         = $null
        Issuer          = $null
        NotBefore       = $null
        NotAfter        = $null
        DaysRemaining   = $null
        Thumbprint      = $null
        IsSelfSigned    = $false
        CertificatePath = $CertificatePath
        KeyPath         = $KeyPath
    }

    if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        $result.Reason = "The certificate file '$CertificatePath' does not exist."
        return $result
    }
    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        $result.Reason = "The private key file '$KeyPath' does not exist."
        return $result
    }

    $certificate = $null
    try {
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
    }
    catch {
        $result.Reason = "The certificate file '$CertificatePath' could not be parsed as an X.509 certificate: $($_.Exception.Message)"
        return $result
    }

    $result.Subject      = $certificate.Subject
    $result.Issuer       = $certificate.Issuer
    $result.NotBefore    = $certificate.NotBefore
    $result.NotAfter     = $certificate.NotAfter
    $result.Thumbprint   = $certificate.Thumbprint
    $result.IsSelfSigned = ($certificate.Subject -eq $certificate.Issuer)
    $result.DaysRemaining = [int][math]::Floor(($certificate.NotAfter - (Get-Date)).TotalDays)

    if (Test-DeltaPrivateKeyEncrypted -Path $KeyPath) {
        $result.Reason = "The private key '$KeyPath' is passphrase-protected. NGINX cannot use it without storing that passphrase in plaintext beside the key, which gains nothing. Supply a decrypted key (openssl rsa -in encrypted.key -out decrypted.key)."
        return $result
    }

    # --- the pair match ---------------------------------------------------
    # Both files are staged into one directory so a single read-only mount
    # covers them, whatever paths the operator gave.
    $staging = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("delta-cert-" + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path $staging -Force
        Copy-Item -LiteralPath $CertificatePath -Destination (Join-Path $staging 'cert.pem') -Force
        Copy-Item -LiteralPath $KeyPath -Destination (Join-Path $staging 'key.pem') -Force

        $capture = Invoke-DeltaActivity -Message 'Checking the certificate and key' -ScriptBlock {
            Invoke-DeltaOpenSsl -Image $OpenSslImage -MountPath $staging -Command @'
set -e
openssl x509 -in /work/cert.pem -noout -pubkey > /work/from-cert.pub 2>/work/cert.err || { echo "CERT_PARSE_FAILED"; cat /work/cert.err; exit 0; }
openssl pkey -in /work/key.pem -pubout > /work/from-key.pub 2>/work/key.err || { echo "KEY_PARSE_FAILED"; cat /work/key.err; exit 0; }
if cmp -s /work/from-cert.pub /work/from-key.pub; then echo "PAIR_MATCH"; else echo "PAIR_MISMATCH"; fi
'@ -Writable
        }

        $output = (($capture.StdOut + "`n" + $capture.StdErr)).Trim()

        if ($output -match 'CERT_PARSE_FAILED') {
            $result.Reason = "OpenSSL could not read '$CertificatePath' as a PEM certificate. It may be a DER/PKCS#12 file rather than PEM."
            return $result
        }
        if ($output -match 'KEY_PARSE_FAILED') {
            $result.Reason = "OpenSSL could not read '$KeyPath' as a private key."
            return $result
        }
        if ($output -match 'PAIR_MISMATCH') {
            $result.Reason = "The private key does not match the certificate. '$KeyPath' is a valid key and '$CertificatePath' is a valid certificate, but they are not a pair - NGINX would refuse to start with them."
            return $result
        }
        if ($output -notmatch 'PAIR_MATCH') {
            $result.Reason = "The certificate and key could not be compared. OpenSSL reported: $output"
            return $result
        }
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($certificate.NotAfter -lt (Get-Date)) {
        $result.Reason = "The certificate expired on $($certificate.NotAfter.ToString('yyyy-MM-dd')). Browsers will refuse it."
        return $result
    }
    if ($certificate.NotBefore -gt (Get-Date)) {
        $result.Reason = "The certificate is not valid until $($certificate.NotBefore.ToString('yyyy-MM-dd'))."
        return $result
    }
    if ($result.DaysRemaining -le 30) {
        $result.Warning = "The certificate expires in $($result.DaysRemaining) day(s), on $($certificate.NotAfter.ToString('yyyy-MM-dd')). Plan its replacement now."
    }

    $result.IsValid = $true
    return $result
}

function Get-DeltaCertificateName {
    <#
      Every hostname a certificate claims: the subjectAltName DNS entries, plus
      the subject's CN when there is no SAN at all.

      SAN is read from the extension rather than from OpenSSL, so this needs no
      container and no Docker engine - Domain Management has to be able to
      answer "does the certificate cover this?" while it is drawing a screen,
      not only while it is running a transaction.

      X509Extension.Format() is the only in-box reader, and its labels are
      produced by Windows rather than by the certificate, so the pattern accepts
      both the Windows form ("DNS Name=host") and the OpenSSL form ("DNS:host").
      If a SAN extension is present but nothing could be read out of it, that is
      reported as undetermined - never as "no names", which a caller would
      correctly turn into "not covered" and be wrong.
    #>
    param([Parameter(Mandatory)][string]$CertificatePath)

    $result = [PSCustomObject]@{
        Determined = $false
        Reason     = $null
        Names      = @()
        Subject    = $null
        HasSan     = $false
    }

    if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        $result.Reason = "There is no certificate at '$CertificatePath'."
        return $result
    }

    $certificate = $null
    try {
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
    }
    catch {
        $result.Reason = "The certificate could not be parsed: $($_.Exception.Message)"
        return $result
    }

    $result.Subject = $certificate.Subject
    $names = New-Object 'System.Collections.Generic.List[string]'

    $san = $certificate.Extensions | Where-Object { $_.Oid -and $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
    if ($san) {
        $result.HasSan = $true
        $text = $null
        try { $text = $san.Format($true) } catch { $text = $null }
        if ($text) {
            foreach ($match in [regex]::Matches($text, '(?i)\bDNS[^=:\r\n]*[=:]\s*([^\s,;]+)')) {
                $value = $match.Groups[1].Value.Trim()
                if ($value) { $null = $names.Add($value) }
            }
        }
        if ($names.Count -eq 0) {
            $result.Reason = 'The certificate has a subjectAltName extension, but this host could not read the names out of it.'
            return $result
        }
    }
    else {
        # No SAN. Browsers have not honoured a bare CN for years, but a
        # certificate can still legitimately be built that way and the operator
        # is better served by being shown what it claims than by being told
        # nothing.
        if ($certificate.Subject -match '(?i)(?:^|,)\s*CN\s*=\s*([^,]+)') {
            $null = $names.Add($Matches[1].Trim())
        }
        if ($names.Count -eq 0) {
            $result.Reason = 'The certificate has neither a subjectAltName extension nor a readable common name.'
            return $result
        }
    }

    $unique = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $names) {
        if ($seen.Add($name)) { $null = $unique.Add($name) }
    }

    $result.Names = $unique.ToArray()
    $result.Determined = $true
    return $result
}

function Test-DeltaCertificateCoversName {
    <#
      Whether one certificate name covers one hostname, by RFC 6125's rule as
      browsers actually apply it: an exact case-insensitive match, or a
      left-most wildcard that matches exactly one label.

      *.example.org covers a.example.org and does NOT cover example.org or
      a.b.example.org. Getting that wrong in the permissive direction would
      have Domain Management telling an operator HTTPS is fine for a hostname
      every browser is about to reject.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CertificateName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Domain
    )

    if (-not $CertificateName -or -not $Domain) { return $false }

    $name = $CertificateName.Trim().TrimEnd('.')
    $candidate = $Domain.Trim().TrimEnd('.')

    if ([string]::Equals($name, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if (-not $name.StartsWith('*.')) { return $false }

    $suffix = $name.Substring(1)          # ".example.org"
    if ($candidate.Length -le $suffix.Length) { return $false }
    if (-not $candidate.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

    # Exactly one label may stand where the wildcard is.
    $label = $candidate.Substring(0, $candidate.Length - $suffix.Length)
    return (-not $label.Contains('.'))
}

function Get-DeltaCertificateDomainCoverage {
    <#
      Which of the configured domains the certificate in use actually covers.

      This is the seam A§11 needs once NGINX serves more than one hostname:
      "the certificate hostname is the PUBLIC_URL hostname" stops being true the
      moment a second domain is accepted, and the honest answer is per-domain.

      Returns Determined plus one row per domain. When the names cannot be read,
      Determined is false and no row claims anything - "we could not tell" and
      "not covered" are different facts and are reported as different facts.
    #>
    param(
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Domains
    )

    $names = Get-DeltaCertificateName -CertificatePath $CertificatePath

    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($domain in $Domains) {
        $matched = $null
        if ($names.Determined) {
            foreach ($name in $names.Names) {
                if (Test-DeltaCertificateCoversName -CertificateName $name -Domain $domain) { $matched = $name; break }
            }
        }
        $null = $rows.Add([PSCustomObject]@{
            Domain    = $domain
            IsCovered = [bool]$matched
            MatchedBy = $matched
        })
    }

    $uncovered = @($rows | Where-Object { -not $_.IsCovered })

    return [PSCustomObject]@{
        Determined      = $names.Determined
        Reason          = $names.Reason
        Names           = $names.Names
        Subject         = $names.Subject
        Rows            = $rows.ToArray()
        Uncovered       = @($uncovered | ForEach-Object { $_.Domain })
        CoversAll       = ($names.Determined -and $uncovered.Count -eq 0)
        CertificatePath = $CertificatePath
    }
}

# ---------------------------------------------------------------------------
# Certificate input (A§11.2)
#
# NGINX consumes PEM and nothing else, so PEM is the only format an operator
# supplies: a .crt/.cer/.pem certificate and a .key/.pem private key. That is
# exactly the set the reference installer's NGINX path accepts too.
#
# Nothing is converted. A format that has to be transformed before NGINX can
# read it is a step that can fail, a secret that has to be carried, and a
# second thing to keep correct - and none of that is bought by this
# installation, which serves the files it is given. PKCS#12, DER, PKCS#7 and
# the Windows certificate store are all out: the last of those is removed from
# this product by A§23 outright, and the rest are simply not what NGINX reads.
#
# An operator holding a .pfx converts it once, with the tool of their choice,
# and supplies the resulting pair.
# ---------------------------------------------------------------------------

$Script:DeltaPemCertificateExtensions = @('.crt', '.cer', '.pem')
$Script:DeltaPemKeyExtensions         = @('.key', '.pem')

function Read-DeltaCertificateFilePair {
    <#
      Collects an existing certificate and its private key: two Windows file
      selection dialogs, the certificate first and the key second, which is the
      order and the shape the reference installer's
      Install-DeltaSslCertificateFiles uses.

      Both flows that ask an operator for a certificate they already hold call
      this one function: the installer's HTTPS choice ("I have a certificate")
      in Invoke-DeltaNetworkStage below, and Certificate Management's
      Read-DeltaCertificateSource in Delta.Tls.ps1. It lives here, beside the
      extension lists and Test-DeltaCertificateMaterial, rather than up in
      Delta.Tls.ps1 where it started: the installer stage cannot call into a
      library loaded after it without inverting the layering, and two operators
      being asked for the same two files should not be able to be asked
      differently.

      The filters come from the same extension lists the validator checks
      against, so what the dialog offers and what the installer accepts cannot
      drift apart. "All files" stays as the second entry, as the reference's
      filters have it - a correctly-named certificate in an unusual place is
      still one the operator has to be able to reach, and the extension is
      checked afterwards regardless of how the file was found.

      Cancelling either dialog cancels the whole selection and returns $null.
      Each caller decides what that means for it - the menu reports "nothing
      was changed" and returns to itself, the installer returns to the HTTPS
      question - but neither treats it as an error, which is this installer's
      convention throughout and why this does not adopt the reference's
      Stop-Setup on a missing selection.

      Nothing is validated here beyond the dialog's own CheckFileExists. The
      certificate, the key, their pairing, the dates and the domain coverage
      are all decided by Test-DeltaCertificateMaterial,
      Resolve-DeltaCertificateInput and the activation gate, unchanged - this
      function's only job is to find out which two files the operator means.
    #>

    $certificateFilter = Get-DeltaFileDialogFilter -Description 'Certificate files' -Extensions $Script:DeltaPemCertificateExtensions
    $keyFilter         = Get-DeltaFileDialogFilter -Description 'Private key files' -Extensions $Script:DeltaPemKeyExtensions

    if (-not (Test-DeltaFileDialogSupported)) {
        # No dialog is possible in this session. Say so, then fall back to
        # typing rather than leaving the operator unable to install a
        # certificate at all.
        Write-Host ''
        Write-DeltaWarning 'This session cannot open a file selection window, so the paths have to be typed.'
        Write-Detail 'That happens on Server Core, or when PowerShell is not running on an STA thread.'
        Write-Host ''
        Write-Host 'Leave either blank to cancel.'
        $typedCertificate = ([string](Read-Host -Prompt "Certificate file ($($Script:DeltaPemCertificateExtensions -join '/'))")).Trim('"', ' ')
        if (-not $typedCertificate) { return $null }
        $typedKey = ([string](Read-Host -Prompt "Private key file ($($Script:DeltaPemKeyExtensions -join '/'))")).Trim('"', ' ')
        if (-not $typedKey) { return $null }
        return [PSCustomObject]@{ Kind = 'pem'; CertificatePath = $typedCertificate; KeyPath = $typedKey }
    }

    Write-Host ''
    Write-Step 'Selecting the certificate file'
    Write-Detail 'A file selection window has opened. Cancel it to go back without changing anything.'
    $certificate = Select-DeltaSslFile -Title 'Select the SSL certificate file' -Filter $certificateFilter
    if (-not $certificate) {
        Write-Detail 'No certificate was selected.'
        return $null
    }
    Write-Detail $certificate

    Write-Step 'Selecting the private key file'
    Write-Detail 'A second window has opened for the private key.'
    $key = Select-DeltaSslFile -Title 'Select the SSL private key file' -Filter $keyFilter
    if (-not $key) {
        Write-Detail 'No private key was selected.'
        return $null
    }
    Write-Detail $key

    return [PSCustomObject]@{ Kind = 'pem'; CertificatePath = $certificate; KeyPath = $key }
}

function Get-DeltaCertificateSourceKind {
    <#
      Classifies an operator-supplied certificate file by extension: 'pem' or
      'unsupported'.

      Extension, not content sniffing, and deliberately so - it is what the
      reference installer checks, it is what the operator can see and correct,
      and a file whose extension lies is caught moments later by the parse that
      follows. Case-insensitive, because Windows filesystems are.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return 'unsupported' }
    $extension = ([System.IO.Path]::GetExtension($Path)).ToLowerInvariant()

    if ($Script:DeltaPemCertificateExtensions -contains $extension) { return 'pem' }
    return 'unsupported'
}

function Get-DeltaCertificateDetail {
    <#
      Everything about a certificate that is safe to show an operator, read
      from the file itself. The private key beside it is never opened, parsed
      or described beyond whether the file exists - that is the caller's
      question, answered from the filesystem, not from key material.

      Nothing here is derived twice: the SAN names come from
      Get-DeltaCertificateName, which is also what coverage is decided from, so
      the inspection view and the coverage verdict cannot disagree.
    #>
    param([Parameter(Mandatory)][string]$CertificatePath)

    $result = [PSCustomObject]@{
        Exists           = $false
        IsReadable       = $false
        Reason           = $null
        Subject          = $null
        Issuer           = $null
        SerialNumber     = $null
        Thumbprint       = $null
        NotBefore        = $null
        NotAfter         = $null
        DaysRemaining    = $null
        IsExpired        = $false
        IsNotYetValid    = $false
        IsSelfSigned     = $false
        KeyAlgorithm     = $null
        KeySize          = $null
        SignatureAlgorithm = $null
        SanNames         = @()
        NamesDetermined  = $false
        CertificatePath  = $CertificatePath
    }

    if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        $result.Reason = "There is no certificate at '$CertificatePath'."
        return $result
    }
    $result.Exists = $true

    $certificate = $null
    try {
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
    }
    catch {
        $result.Reason = "The certificate could not be parsed: $($_.Exception.Message)"
        return $result
    }

    $now = Get-Date
    $result.IsReadable    = $true
    $result.Subject       = $certificate.Subject
    $result.Issuer        = $certificate.Issuer
    $result.SerialNumber  = $certificate.SerialNumber
    $result.Thumbprint    = $certificate.Thumbprint
    $result.NotBefore     = $certificate.NotBefore
    $result.NotAfter      = $certificate.NotAfter
    $result.DaysRemaining = [int][math]::Floor(($certificate.NotAfter - $now).TotalDays)
    $result.IsExpired     = ($certificate.NotAfter -lt $now)
    $result.IsNotYetValid = ($certificate.NotBefore -gt $now)
    $result.IsSelfSigned  = ($certificate.Subject -eq $certificate.Issuer)
    $result.SignatureAlgorithm = $(if ($certificate.SignatureAlgorithm) { $certificate.SignatureAlgorithm.FriendlyName } else { $null })

    # Key facts are reported only when they can be read. A key algorithm this
    # host's .NET cannot describe is left blank rather than guessed at - A§27's
    # rule that nothing is claimed that was not established.
    try {
        if ($certificate.PublicKey -and $certificate.PublicKey.Oid) {
            $result.KeyAlgorithm = $certificate.PublicKey.Oid.FriendlyName
        }
        if ($certificate.PublicKey -and $certificate.PublicKey.Key) {
            $result.KeySize = [int]$certificate.PublicKey.Key.KeySize
        }
    }
    catch { }

    $names = Get-DeltaCertificateName -CertificatePath $CertificatePath
    $result.NamesDetermined = $names.Determined
    $result.SanNames        = @($names.Names)

    return $result
}

function New-DeltaSelfSignedCertificate {
    <#
      Generates a self-signed certificate and key straight into the staging
      directory, using OpenSSL in a container.

      Deliberately not New-SelfSignedCertificate: that writes into the Windows
      certificate store and would then need exporting and converting, and A§23
      removes Windows certificate-store involvement from this product outright
      - the container terminates TLS from mounted PEM files and nothing else.

      Browsers will warn on the result. That is stated plainly wherever this
      mode is offered rather than dressed up.

      -AdditionalName adds further subjectAltName DNS entries. It exists so a
      generated certificate covers the whole configured domain set rather than
      only the primary: NGINX may accept several hostnames, and issuing a
      certificate that covers one of them and then reporting the rest as
      uncovered would be this function creating the defect Domain Management
      then reports. Names are validated by the caller; the defensive check
      below is the boundary that keeps a shell metacharacter out of the command
      regardless.
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$OpenSslImage,
        [string[]]$AdditionalName = @(),
        [int]$Days = 825
    )

    # Every name that reaches the OpenSSL command line is checked here, at the
    # point of use. A hostname is letters, digits, dots and hyphens; anything
    # else is refused rather than quoted, because there is no quoting that makes
    # an unexpected value safe to hand to a shell.
    $subjectNames = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in (@($HostName) + @($AdditionalName) + @('localhost'))) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $candidate = $name.Trim()
        if ($candidate -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$') {
            Stop-Setup "Refusing to generate a certificate for '$candidate': it is not a plain hostname."
        }
        if ($seen.Add($candidate)) { $null = $subjectNames.Add($candidate) }
    }

    Write-Step 'Generating a self-signed certificate'
    if ($subjectNames.Count -gt 2) {
        Write-Detail "Common name: $HostName (also valid for $((@($subjectNames) | Select-Object -Skip 1) -join ', ') and 127.0.0.1)"
    }
    else {
        Write-Detail "Common name: $HostName (also valid for localhost and 127.0.0.1)"
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }

    $subjectAltName = (($subjectNames | ForEach-Object { "DNS:$_" }) + @('IP:127.0.0.1')) -join ','

    $command = @"
set -e
openssl req -x509 -newkey rsa:2048 -sha256 -days $Days -nodes \
  -keyout /work/$Script:DeltaCertificateKeyName \
  -out /work/$Script:DeltaCertificateFileName \
  -subj "/CN=$HostName" \
  -addext "subjectAltName=$subjectAltName" 2>/work/openssl.err
echo GENERATED
"@

    # RSA-2048 keygen plus a container start. Seconds at best, and the operator
    # has just answered a question, so the terminal would otherwise sit idle.
    $capture = Invoke-DeltaActivity -Message 'Generating the certificate' -ScriptBlock {
        Invoke-DeltaOpenSsl -Image $OpenSslImage -MountPath $OutputDirectory -Command $command -Writable
    }

    $certificatePath = Join-Path $OutputDirectory $Script:DeltaCertificateFileName
    $keyPath         = Join-Path $OutputDirectory $Script:DeltaCertificateKeyName
    $errorFile       = Join-Path $OutputDirectory 'openssl.err'

    if (Test-Path -LiteralPath $errorFile) {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }

    if ($capture.StdOut -notmatch 'GENERATED' -or -not (Test-Path -LiteralPath $certificatePath) -or -not (Test-Path -LiteralPath $keyPath)) {
        return [PSCustomObject]@{
            Succeeded = $false
            Reason    = "Generating a self-signed certificate failed: $((($capture.StdErr + ' ' + $capture.StdOut)).Trim())"
        }
    }

    Protect-DeltaSecretFile -Path $keyPath
    Write-Detail "Generated $certificatePath and its private key."
    Write-DeltaWarning 'This is a self-signed certificate. Browsers will show a warning until it is trusted or replaced. Suitable for internal testing, not for public use.'

    return [PSCustomObject]@{
        Succeeded       = $true
        Reason          = $null
        CertificatePath = $certificatePath
        KeyPath         = $keyPath
    }
}

function Install-DeltaCertificate {
    <#
      Copies validated material into <InstallRoot>\certs\ under the fixed names
      the generated NGINX configuration expects, and restricts the private key
      to Administrators and SYSTEM - the same ACL .env carries, because it is
      the same class of secret (A§24). The directory is mounted read-only into
      NGINX.

      A no-op when the source is already the staged file, so a rerun that
      re-validates what is already in place does not copy a file onto itself.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$KeyPath
    )

    $certsDirectory = Join-Path -Path $InstallRoot -ChildPath 'certs'
    if (-not (Test-Path -LiteralPath $certsDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $certsDirectory -Force
    }

    $targetCertificate = Join-Path $certsDirectory $Script:DeltaCertificateFileName
    $targetKey         = Join-Path $certsDirectory $Script:DeltaCertificateKeyName

    if ((Resolve-Path -LiteralPath $CertificatePath).Path -ne $targetCertificate) {
        Copy-Item -LiteralPath $CertificatePath -Destination $targetCertificate -Force
    }
    if ((Resolve-Path -LiteralPath $KeyPath).Path -ne $targetKey) {
        Copy-Item -LiteralPath $KeyPath -Destination $targetKey -Force
    }

    Protect-DeltaSecretFile -Path $targetKey

    return [PSCustomObject]@{
        CertificatePath = $targetCertificate
        KeyPath         = $targetKey
        ContainerCertificatePath = "/etc/nginx/certs/$Script:DeltaCertificateFileName"
        ContainerKeyPath         = "/etc/nginx/certs/$Script:DeltaCertificateKeyName"
    }
}

# ---------------------------------------------------------------------------
# NGINX configuration validation (A§8.3)
# ---------------------------------------------------------------------------

function Test-DeltaNginxConfiguration {
    <#
      Runs `nginx -t` inside the running nginx container and reads its exit
      code directly - never through a pipeline, which would report the
      pipeline's status instead of NGINX's.

      It has to run inside the project: `proxy_pass http://delta:3000` makes
      nginx resolve the upstream name at configuration-test time, so the same
      test in a throwaway container fails with "host not found in upstream
      'delta'" even when the configuration is perfect. Measured on this host.

      When nginx is not running there is nothing to test against, and that is
      reported as "not verified" rather than as a pass - the configuration is
      then validated by NGINX itself at startup, where the health gate catches
      a failure.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName
    )

    $running = @(Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $ProjectName |
        Where-Object { $_.Service -eq 'nginx' -and $_.State -eq 'running' })

    if ($running.Count -eq 0) {
        return [PSCustomObject]@{ Tested = $false; Succeeded = $false; Output = $null; Reason = 'NGINX is not running yet, so its configuration will be validated when it starts.' }
    }

    $capture = Invoke-DeltaActivity -Message 'Testing the NGINX configuration' -WhenIdle -ScriptBlock {
        Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @('exec', '-T', 'nginx', 'nginx', '-t') -TimeoutSeconds 120
    }
    $output = (($capture.StdOut + "`n" + $capture.StdErr)).Trim()

    return [PSCustomObject]@{
        Tested    = $true
        Succeeded = ($capture.ExitCode -eq 0)
        Output    = $output
        Reason    = if ($capture.ExitCode -eq 0) { $null } else { $output }
    }
}

function Invoke-DeltaNginxReload {
    <#
      Reloads NGINX's workers in place. Needed because conf.d is a bind mount:
      `docker compose up -d` sees an unchanged container definition and does
      not restart nginx when only the file's contents changed, so without an
      explicit reload a regenerated configuration would sit on disk unused.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName
    )

    $capture = Invoke-DeltaActivity -Message 'Reloading NGINX' -WhenIdle -ScriptBlock {
        Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @('exec', '-T', 'nginx', 'nginx', '-s', 'reload') -TimeoutSeconds 120
    }
    return ($capture.ExitCode -eq 0)
}

# ---------------------------------------------------------------------------
# Windows Firewall (A§24: rules only for the ports actually published)
#
# Two rules at most, named stably so they can be found and updated rather than
# duplicated, and grouped so this installer can tell its own rules from
# everybody else's. Nothing here touches a rule outside that group, and nothing
# here disables a firewall profile.
# ---------------------------------------------------------------------------

$Script:DeltaFirewallGroup = 'DELTA (Docker)'

function Get-DeltaFirewallRuleName {
    <#
      The rule name for one endpoint of one installation.

      The Compose project name is part of it deliberately: two installations on
      one machine publish different ports, and a globally-named rule would mean
      the second installation silently repointing the first one's rule at its
      own port. Measured during Phase 5 development, when exactly that
      happened.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][ValidateSet('HTTP', 'HTTPS')][string]$Endpoint
    )
    # No brackets in the name: -DisplayName is matched as a wildcard pattern,
    # so "[delta5]" would be read as a character class and never match the rule
    # it names. Measured - it produced duplicate rules on every run.
    return "DELTA (Docker) - $ProjectName - $Endpoint"
}

function Get-DeltaOwnedFirewallRule {
    <#
      Finds one of this installer's rules by exact display name.

      The lookup is by group, then compared in PowerShell, because
      -DisplayName is a wildcard filter: any project name containing a
      wildcard metacharacter would silently fail to match its own rule.
    #>
    param([Parameter(Mandatory)][string]$DisplayName)

    return @(Get-NetFirewallRule -Group $Script:DeltaFirewallGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $DisplayName })
}

function Set-DeltaFirewallRule {
    <#
      Ensures exactly one inbound allow rule exists for one TCP port,
      idempotently.

      An existing rule of ours is removed and recreated rather than edited.
      Set-NetFirewallRule treats -Group as both a selector and a settable
      property, so editing in place hits a parameter-set ambiguity ("Parameter
      set cannot be resolved") - measured. Remove-and-recreate is unambiguous,
      leaves exactly the intended rule, and only ever touches a rule that
      carries this installer's own name and group.

      Never fatal. A host where policy forbids local firewall rules still has a
      working installation - it just is not reachable from other machines yet,
      which is something to tell the operator, not a reason to fail an install
      that otherwise succeeded (A§13).
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Description
    )

    $result = [PSCustomObject]@{ DisplayName = $DisplayName; Port = $Port; Succeeded = $false; Action = 'created'; Error = $null }

    try {
        # @(...) at the call site, not only inside the function: `return @(x)`
        # unrolls a single-element array back to a scalar, and a lone
        # CimInstance has no .Count at all - so the existing rule went
        # unnoticed and every run added another duplicate. Measured.
        $existing = @(Get-DeltaOwnedFirewallRule -DisplayName $DisplayName)
        if ($existing.Count -gt 0) {
            $existing | Remove-NetFirewallRule -ErrorAction Stop
            $result.Action = 'replaced'
        }

        $null = New-NetFirewallRule -DisplayName $DisplayName -Group $Script:DeltaFirewallGroup `
            -Description $Description -Direction Inbound -Action Allow -Enabled True `
            -Protocol TCP -LocalPort $Port -Profile Any -ErrorAction Stop
        $result.Succeeded = $true
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Remove-DeltaFirewallRule {
    <#
      Removes one of this installer's own rules by its stable name - used only
      to retire the HTTPS rule when an installation stops serving HTTPS. It
      never removes anything it did not create: the name is one of the two
      constants above, and the rule must carry this installer's group.
    #>
    param([Parameter(Mandatory)][string]$DisplayName)

    try {
        $existing = @(Get-DeltaOwnedFirewallRule -DisplayName $DisplayName)
        if ($existing.Count -eq 0) { return $false }
        $existing | Remove-NetFirewallRule -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-DeltaFirewallConfiguration {
    <#
      Opens exactly the ports this installation publishes, and nothing else.

      DELTA's 3000 and PostgreSQL's 5432 are never opened: they are not
      published to Windows at all, so a rule for them would be a hole into
      nothing. The HTTPS rule exists only while TLS is enabled, and is retired
      when it is not.

      Failure warns and names the port that could not be opened. The install
      continues.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][int]$HttpPort,
        [int]$HttpsPort,
        [bool]$TlsEnabled = $false
    )

    Write-Step 'Configuring Windows Firewall'

    $applied = New-Object 'System.Collections.Generic.List[object]'
    $failures = New-Object 'System.Collections.Generic.List[object]'

    $httpRule  = Get-DeltaFirewallRuleName -ProjectName $ProjectName -Endpoint 'HTTP'
    $httpsRule = Get-DeltaFirewallRuleName -ProjectName $ProjectName -Endpoint 'HTTPS'

    $http = Set-DeltaFirewallRule -DisplayName $httpRule -Port $HttpPort `
        -Description "Inbound HTTP to the DELTA reverse proxy on port $HttpPort. Created by the DELTA Docker installer."
    if ($http.Succeeded) {
        $null = $applied.Add($http)
        Write-Detail "[ ok ]     $httpRule $($http.Action) for TCP $HttpPort"
    }
    else {
        $null = $failures.Add($http)
    }

    if ($TlsEnabled -and $HttpsPort -gt 0) {
        $https = Set-DeltaFirewallRule -DisplayName $httpsRule -Port $HttpsPort `
            -Description "Inbound HTTPS to the DELTA reverse proxy on port $HttpsPort. Created by the DELTA Docker installer."
        if ($https.Succeeded) {
            $null = $applied.Add($https)
            Write-Detail "[ ok ]     $httpsRule $($https.Action) for TCP $HttpsPort"
        }
        else {
            $null = $failures.Add($https)
        }
    }
    else {
        if (Remove-DeltaFirewallRule -DisplayName $httpsRule) {
            Write-Detail "Removed $httpsRule - this installation does not serve HTTPS."
        }
    }

    foreach ($failure in $failures) {
        Write-DeltaWarning "Could not open TCP $($failure.Port) in Windows Firewall ($($failure.DisplayName)): $($failure.Error)"
        Write-DeltaWarning "DELTA is installed and works on this machine, but other machines will not reach it on port $($failure.Port) until that port is allowed."
    }

    return [PSCustomObject]@{
        Succeeded = ($failures.Count -eq 0)
        Applied   = $applied.ToArray()
        Failures  = $failures.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Stage orchestration
# ---------------------------------------------------------------------------

function Read-DeltaTlsModeChoice {
    param([string]$Current)

    Write-Host ''
    Write-Host 'HTTPS'
    Write-Host ''
    Write-Host '  1. No HTTPS - plain HTTP only.'
    Write-Host '     Suitable for localhost testing only. DELTA marks its session cookies Secure,'
    Write-Host '     so users reaching this server by hostname over plain HTTP will not stay signed in.'
    Write-Host ''
    Write-Host '  2. I have a certificate - supply a certificate and private key (PEM).'
    Write-Host '     Recommended for production. A file selection window opens for each;'
    Write-Host '     cancel it to come back here.'
    Write-Host ''
    Write-Host '  3. Generate a self-signed certificate.'
    Write-Host '     Browsers will show a warning. Suitable for internal testing.'
    Write-Host ''

    $default = switch ($Current) { 'supplied' { '2' } 'self-signed' { '3' } default { '1' } }

    while ($true) {
        $answer = Read-Host -Prompt "Choose 1, 2 or 3 [$default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }
        switch ($answer.Trim()) {
            '1' { return 'none' }
            '2' { return 'supplied' }
            '3' { return 'self-signed' }
            default { Write-DeltaWarning 'Enter 1, 2 or 3.' }
        }
    }
}

function Invoke-DeltaNetworkStage {
    <#
      Settles everything the generated configuration needs to know about how
      this installation is reached: the hostname, the HTTP port, whether TLS
      is on, the certificate material, and the HTTPS port - in that order,
      because port and TLS resolution must precede configuration generation
      (A§25).

      Existing .env values are the defaults, so a rerun that changes nothing
      asks nothing and changes nothing.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$OpenSslImage,
        [int]$HttpPort,
        [int]$HttpsPort,
        [string]$HostName,
        # The empty string is in the set on purpose: a caller that simply
        # forwards an unsupplied -TlsMode passes '', and that has to mean
        # "decide from .env or ask", not "invalid argument".
        [ValidateSet('none', 'supplied', 'self-signed', '')][string]$TlsMode,
        [string]$CertificatePath,
        [string]$CertificateKeyPath,
        [bool]$AllowPrompt = $true
    )

    Write-Step 'Resolving ports and TLS'

    $envPath = Join-Path -Path $InstallRoot -ChildPath '.env'
    $existing = Read-DeltaEnvFile -Path $envPath
    $readExisting = {
        param($key, $fallback)
        if ($existing.Entries.Contains($key)) {
            $value = [string]$existing.Entries[$key]
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }
        return $fallback
    }

    $result = [PSCustomObject]@{
        Succeeded       = $false
        Reason          = $null
        HostName        = $null
        HttpPort        = 0
        HttpsPort       = 0
        TlsEnabled      = $false
        TlsMode         = 'none'
        PublicUrl       = $null
        Certificate     = $null
        CertificateFile = $null
        KeyFile         = $null
    }

    # --- hostname ---------------------------------------------------------
    $resolvedHost = if ($HostName) { $HostName } else { & $readExisting 'DELTA_HOSTNAME' 'localhost' }
    $result.HostName = $resolvedHost
    Write-Detail "[ ok ]     hostname $resolvedHost"

    # --- HTTP port --------------------------------------------------------
    $httpCandidate = if ($HttpPort -gt 0) { $HttpPort } else { [int](& $readExisting 'HTTP_PORT' "$Script:DeltaDefaultHttpPort") }
    $httpAllowPrompt = $AllowPrompt -and ($HttpPort -le 0)

    $http = Resolve-DeltaPort -Purpose 'HTTP' -Candidate $httpCandidate -Suggested $Script:DeltaSuggestedHttpPort `
        -InstallRoot $InstallRoot -ProjectName $ProjectName -AllowPrompt $httpAllowPrompt
    if (-not $http.Succeeded) {
        $result.Reason = $http.Reason
        return $result
    }
    $result.HttpPort = $http.Port

    # --- TLS mode and certificate ------------------------------------------
    $currentMode = & $readExisting 'TLS_MODE' $null
    if (-not $currentMode) {
        $currentMode = if ((& $readExisting 'TLS_ENABLED' 'false') -eq 'true') { 'supplied' } else { 'none' }
    }

    $certsDirectory = Join-Path -Path $InstallRoot -ChildPath 'certs'
    $stagedCertificate = Join-Path $certsDirectory $Script:DeltaCertificateFileName
    $stagedKey         = Join-Path $certsDirectory $Script:DeltaCertificateKeyName

    # The HTTPS question and the certificate that answers it are one decision
    # taken in two steps, so both sit inside this loop. An operator who chooses
    # "I have a certificate" and then closes the file picker has not failed the
    # installation - they have changed their mind, and the right place to put
    # them is back at the HTTPS question, where self-signed and plain HTTP are
    # still on offer. Only a prompted run can reach that path; -TlsMode with
    # -AllowPrompt $false still resolves in a single pass.
    #
    # -TlsMode and -CertificatePath pre-answer their own step and are consumed
    # on the first pass only: a second pass exists precisely because the
    # operator came back to choose again.
    $mode = $TlsMode
    $sourceCertificate = $CertificatePath
    $sourceKey         = $CertificateKeyPath

    while ($true) {
        if (-not $mode) {
            if ($AllowPrompt) { $mode = Read-DeltaTlsModeChoice -Current $currentMode }
            else { $mode = $currentMode }
        }
        $result.TlsMode = $mode

        if ($mode -eq 'none') {
            $result.TlsEnabled = $false
            $result.HttpsPort = [int](& $readExisting 'HTTPS_PORT' "$Script:DeltaDefaultHttpsPort")
            $result.PublicUrl = Get-DeltaPublicUrl -Scheme 'http' -HostName $resolvedHost -Port $result.HttpPort
            Write-Detail "[ ok ]     TLS disabled; public address $($result.PublicUrl)"
            Write-DeltaWarning 'Plain HTTP is suitable for localhost testing only - DELTA marks its session cookies Secure, so users reaching this server by hostname will not stay signed in.'
            $result.Succeeded = $true
            return $result
        }

        if ($mode -eq 'self-signed') {
            if ((Test-Path -LiteralPath $stagedCertificate) -and (Test-Path -LiteralPath $stagedKey) -and -not $CertificatePath) {
                # A rerun keeps a certificate that is already in place and still
                # valid rather than quietly issuing a new one under everybody.
                $existingCheck = Test-DeltaCertificateMaterial -CertificatePath $stagedCertificate -KeyPath $stagedKey -OpenSslImage $OpenSslImage
                if ($existingCheck.IsValid) {
                    Write-Detail '[ ok ]     an existing valid certificate is already staged; keeping it.'
                    $sourceCertificate = $stagedCertificate
                    $sourceKey = $stagedKey
                }
            }
            if (-not $sourceCertificate) {
                # A generated certificate covers the whole configured domain set,
                # not just the primary. On a fresh installation that set is the
                # primary alone; on a rerun of an installation with additional
                # domains, issuing for the primary only would manufacture the
                # coverage gap Domain Management then has to report.
                $additionalNames = @((Get-DeltaDomainModel -InstallRoot $InstallRoot).Additional)
                $generated = New-DeltaSelfSignedCertificate -HostName $resolvedHost -OutputDirectory $certsDirectory -OpenSslImage $OpenSslImage -AdditionalName $additionalNames
                if (-not $generated.Succeeded) {
                    $result.Reason = $generated.Reason
                    return $result
                }
                $sourceCertificate = $generated.CertificatePath
                $sourceKey = $generated.KeyPath
            }
        }

        $cancelled = $false

        while ($true) {
            if (-not $sourceCertificate -or -not $sourceKey) {
                if ((Test-Path -LiteralPath $stagedCertificate) -and (Test-Path -LiteralPath $stagedKey)) {
                    $sourceCertificate = $stagedCertificate
                    $sourceKey = $stagedKey
                }
                elseif ($AllowPrompt) {
                    # The same two dialogs Certificate Management opens, from
                    # the same function - an operator holding a bundle from
                    # their CA picks the two files rather than transcribing
                    # two paths into a console.
                    $selection = Read-DeltaCertificateFilePair
                    if (-not $selection) {
                        $cancelled = $true
                        break
                    }
                    $sourceCertificate = $selection.CertificatePath
                    $sourceKey         = $selection.KeyPath
                }
                else {
                    $result.Reason = 'HTTPS was requested but no certificate and key were supplied, and there is none staged in certs\.'
                    return $result
                }
            }

            $check = Test-DeltaCertificateMaterial -CertificatePath $sourceCertificate -KeyPath $sourceKey -OpenSslImage $OpenSslImage
            if ($check.IsValid) {
                $result.Certificate = $check
                break
            }

            Write-DeltaFailure ''
            Write-DeltaFailure 'The certificate cannot be used.'
            Write-Detail $check.Reason
            if (-not $AllowPrompt) {
                $result.Reason = $check.Reason
                return $result
            }
            $sourceCertificate = $null
            $sourceKey = $null
        }

        if (-not $cancelled) { break }

        # Back to the HTTPS question, with the choice they made last time as
        # the default so pressing Enter reopens the picker. Nothing has been
        # written to the installation at this point - the certificate is only
        # staged below, after it validates.
        Write-Host ''
        Write-Detail 'No certificate was selected, so HTTPS has not been configured yet.'
        $currentMode = $mode
        $mode = $null
    }

    $staged = Install-DeltaCertificate -InstallRoot $InstallRoot -CertificatePath $sourceCertificate -KeyPath $sourceKey
    $result.CertificateFile = $staged.ContainerCertificatePath
    $result.KeyFile         = $staged.ContainerKeyPath

    Write-Detail "[ ok ]     certificate $($result.Certificate.Subject)"
    Write-Detail "[ ok ]     issued by   $($result.Certificate.Issuer)"
    Write-Detail "[ ok ]     valid until $($result.Certificate.NotAfter.ToString('yyyy-MM-dd')) ($($result.Certificate.DaysRemaining) days)"
    if ($result.Certificate.Warning) { Write-DeltaWarning $result.Certificate.Warning }

    # --- HTTPS port -------------------------------------------------------
    $httpsCandidate = if ($HttpsPort -gt 0) { $HttpsPort } else { [int](& $readExisting 'HTTPS_PORT' "$Script:DeltaDefaultHttpsPort") }
    $httpsAllowPrompt = $AllowPrompt -and ($HttpsPort -le 0)

    $https = Resolve-DeltaPort -Purpose 'HTTPS' -Candidate $httpsCandidate -Suggested $Script:DeltaSuggestedHttpsPort `
        -InstallRoot $InstallRoot -ProjectName $ProjectName -OtherPort $result.HttpPort -OtherPurpose 'HTTP' -AllowPrompt $httpsAllowPrompt
    if (-not $https.Succeeded) {
        $result.Reason = $https.Reason
        return $result
    }

    $result.HttpsPort  = $https.Port
    $result.TlsEnabled = $true
    $result.PublicUrl  = Get-DeltaPublicUrl -Scheme 'https' -HostName $resolvedHost -Port $result.HttpsPort
    Write-Detail "[ ok ]     public address $($result.PublicUrl)"

    $result.Succeeded = $true
    return $result
}
