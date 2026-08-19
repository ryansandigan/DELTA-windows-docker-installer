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
    #>
    param(
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$MountPath,
        [switch]$Writable,
        [int]$TimeoutSeconds = 180
    )

    $mount = if ($Writable) { "${MountPath}:/work" } else { "${MountPath}:/work:ro" }
    return (Invoke-DeltaDockerCommand -Arguments @(
        'run', '--rm', '--network', 'none', '-v', $mount, '--entrypoint', 'sh', $Image, '-c', $Command
    ) -TimeoutSeconds $TimeoutSeconds)
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

        $capture = Invoke-DeltaOpenSsl -Image $OpenSslImage -MountPath $staging -Command @'
set -e
openssl x509 -in /work/cert.pem -noout -pubkey > /work/from-cert.pub 2>/work/cert.err || { echo "CERT_PARSE_FAILED"; cat /work/cert.err; exit 0; }
openssl pkey -in /work/key.pem -pubout > /work/from-key.pub 2>/work/key.err || { echo "KEY_PARSE_FAILED"; cat /work/key.err; exit 0; }
if cmp -s /work/from-cert.pub /work/from-key.pub; then echo "PAIR_MATCH"; else echo "PAIR_MISMATCH"; fi
'@ -Writable

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
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$OpenSslImage,
        [int]$Days = 825
    )

    Write-Step 'Generating a self-signed certificate'
    Write-Detail "Common name: $HostName (also valid for localhost and 127.0.0.1)"

    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }

    $command = @"
set -e
openssl req -x509 -newkey rsa:2048 -sha256 -days $Days -nodes \
  -keyout /work/$Script:DeltaCertificateKeyName \
  -out /work/$Script:DeltaCertificateFileName \
  -subj "/CN=$HostName" \
  -addext "subjectAltName=DNS:$HostName,DNS:localhost,IP:127.0.0.1" 2>/work/openssl.err
echo GENERATED
"@

    $capture = Invoke-DeltaOpenSsl -Image $OpenSslImage -MountPath $OutputDirectory -Command $command -Writable

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

    $capture = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @('exec', '-T', 'nginx', 'nginx', '-t') -TimeoutSeconds 120
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

    $capture = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @('exec', '-T', 'nginx', 'nginx', '-s', 'reload') -TimeoutSeconds 120
    return ($capture.ExitCode -eq 0)
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
    Write-Host '     Recommended for production.'
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
        [ValidateSet('none', 'supplied', 'self-signed')][string]$TlsMode,
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

    # --- TLS mode ---------------------------------------------------------
    $currentMode = & $readExisting 'TLS_MODE' $null
    if (-not $currentMode) {
        $currentMode = if ((& $readExisting 'TLS_ENABLED' 'false') -eq 'true') { 'supplied' } else { 'none' }
    }

    $mode = $TlsMode
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

    # --- certificate ------------------------------------------------------
    $certsDirectory = Join-Path -Path $InstallRoot -ChildPath 'certs'
    $stagedCertificate = Join-Path $certsDirectory $Script:DeltaCertificateFileName
    $stagedKey         = Join-Path $certsDirectory $Script:DeltaCertificateKeyName

    $sourceCertificate = $CertificatePath
    $sourceKey         = $CertificateKeyPath

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
            $generated = New-DeltaSelfSignedCertificate -HostName $resolvedHost -OutputDirectory $certsDirectory -OpenSslImage $OpenSslImage
            if (-not $generated.Succeeded) {
                $result.Reason = $generated.Reason
                return $result
            }
            $sourceCertificate = $generated.CertificatePath
            $sourceKey = $generated.KeyPath
        }
    }

    while ($true) {
        if (-not $sourceCertificate -or -not $sourceKey) {
            if ((Test-Path -LiteralPath $stagedCertificate) -and (Test-Path -LiteralPath $stagedKey)) {
                $sourceCertificate = $stagedCertificate
                $sourceKey = $stagedKey
            }
            elseif ($AllowPrompt) {
                Write-Host ''
                $sourceCertificate = (Read-Host -Prompt 'Path to the certificate file (PEM .crt/.pem)').Trim('"', ' ')
                $sourceKey         = (Read-Host -Prompt 'Path to the private key file (PEM .key/.pem)').Trim('"', ' ')
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
