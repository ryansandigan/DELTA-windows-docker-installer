#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for certificate/private-key validation, and for the shell
    payload the OpenSSL container is given.

.DESCRIPTION
    The failure these were written for, as an operator reported it:

        (the installer pulls postgis/postgis:17-3.5)
        sh: 1: set: Illegal option -
        ...
        The certificate cannot be used.
            The certificate and key could not be compared.
            OpenSSL reported: sh: 1: set: Illegal option -

    with a certificate and key that were, in fact, a valid pair.

    The cause was not the certificate. Every multi-line shell payload in this
    installer is a PowerShell here-string in a .ps1 file, and a .ps1 file's
    line endings are decided by git (core.autocrlf, and there is no
    .gitattributes), by whichever editor last wrote the file, and by
    tools\build-release.ps1, which copies whatever is on disk into the
    package. When that file carries CRLF, the first line of the payload
    reaches the container as:

        set -e<CR>

    and a CR is not whitespace to a POSIX shell - it is an ordinary character
    in the last word of the line. Measured against postgis/postgis:17-3.5,
    whose /bin/sh is dash, and which is the image this installer runs openssl
    in:

        printf 'set -e\r\n' | sh
        sh: 1: set: Illegal option -^M

    `set` is a special builtin, so dash abandons the script and exits 2. The
    caller gets no stdout, so Test-DeltaCertificateMaterial correctly reports
    that it could not compare anything - and quotes the one line it was given.

    So the invariants pinned here are:

      - nothing this installer hands to `sh -c` contains a carriage return,
        whatever the .ps1 file's line endings are;
      - the operator's own paths never reach Docker - both files are staged
        into one throwaway temporary directory and only that directory is
        mounted, which is why a certificate on D:\ works at all, and which is
        also why the comparison can mount writably without exposing anything
        of the operator's;
      - the container has no network and is removed when it exits;
      - a matching pair is accepted, a mismatched key is rejected as a
        mismatch, a key chosen as the certificate is rejected as an unparseable
        certificate, and a Docker or OpenSSL failure is still surfaced rather
        than swallowed.

    The functions under test are the real ones, dot-sourced from lib\. Docker
    is replaced by a recording stand-in that ALSO models dash's own handling of
    `set`, so the reported failure is reproduced here rather than described:
    revert the fix and this suite fails with the operator's message.

    Nothing here starts a container, writes to an installation, or changes
    anything on this host. Real RSA key material is generated in memory and
    written to temporary directories that are removed on the way out.

    -Live additionally runs the real thing against the real Docker engine. It
    is off by default because every other suite here is hostless; when it is
    on, it needs a working Linux engine and pulls nothing it does not already
    have.

    Exits 0 if every test passes, 1 otherwise.

.PARAMETER Live
    Also validate against the real Docker engine and the real OpenSSL image.

.EXAMPLE
    .\tools\Test-CertificateValidation.ps1

.EXAMPLE
    .\tools\Test-CertificateValidation.ps1 -Live
#>

[CmdletBinding()]
param(
    [switch]$Live,
    [string]$LiveImage = 'postgis/postgis:17-3.5'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot

$Script:Passed = 0
$Script:Failed = 0

. (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')
# Delta.Config.ps1 for Protect-DeltaSecretFile, which the self-signed path
# calls on the key it has just written.
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Network.ps1')

# Nothing animates during a test run: the frames would interleave with the
# assertions and the transcript of a failure would be unreadable.
Set-DeltaActivityMode -Mode 'off'

# ---------------------------------------------------------------------------
# Assertion helpers (same shape as the other suites here)
# ---------------------------------------------------------------------------

function Assert-That {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()]$Condition
    )
    if ($Condition) { Write-Host "    [PASS] $Description" -ForegroundColor Green; $Script:Passed++ }
    else            { Write-Host "    [FAIL] $Description" -ForegroundColor Red;   $Script:Failed++ }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()]$Expected,
        [Parameter(Mandatory)][AllowNull()]$Actual
    )
    if ($Expected -eq $Actual) { Write-Host "    [PASS] $Description" -ForegroundColor Green; $Script:Passed++ }
    else {
        Write-Host "    [FAIL] $Description" -ForegroundColor Red
        Write-Host "           expected: [$Expected]" -ForegroundColor Red
        Write-Host "           actual:   [$Actual]"   -ForegroundColor Red
        $Script:Failed++
    }
}

function Start-TestCase {
    param([Parameter(Mandatory)][string]$Name)
    Write-Host ''
    Write-Host "==> $Name" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Real key material
#
# Generated here rather than committed, so no private key ever lives in this
# repository and every run exercises fresh material. .NET Framework's RSA has
# no ExportPkcs8PrivateKey - that is .NET Core - so the PKCS#1 structure is
# written out by hand. It is a real key in a real format: the -Live section
# below hands these very files to OpenSSL.
# ---------------------------------------------------------------------------

function ConvertTo-DerLength {
    param([Parameter(Mandatory)][int]$Length)

    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    if ($Length -lt 0x80) { $bytes.Add([byte]$Length); return $bytes.ToArray() }

    $value = $Length
    $tail = New-Object 'System.Collections.Generic.List[byte]'
    while ($value -gt 0) {
        $tail.Insert(0, [byte]($value -band 0xFF))
        $value = $value -shr 8
    }
    $bytes.Add([byte](0x80 -bor $tail.Count))
    $bytes.AddRange($tail)
    return $bytes.ToArray()
}

function New-DerInteger {
    <#
      DER INTEGER from a big-endian magnitude: leading zero bytes are dropped,
      and one is put back when the high bit would otherwise make the value
      negative.
    #>
    param([Parameter(Mandatory)][byte[]]$Value)

    $trimmed = New-Object 'System.Collections.Generic.List[byte]'
    $trimmed.AddRange($Value)
    while ($trimmed.Count -gt 1 -and $trimmed[0] -eq 0) { $trimmed.RemoveAt(0) }
    if (($trimmed[0] -band 0x80) -ne 0) { $trimmed.Insert(0, [byte]0) }

    $out = New-Object 'System.Collections.Generic.List[byte]'
    $out.Add([byte]0x02)
    $out.AddRange([byte[]](ConvertTo-DerLength -Length $trimmed.Count))
    $out.AddRange($trimmed)
    return $out.ToArray()
}

function New-DerSequence {
    param([Parameter(Mandatory)][byte[]]$Content)

    $out = New-Object 'System.Collections.Generic.List[byte]'
    $out.Add([byte]0x30)
    $out.AddRange([byte[]](ConvertTo-DerLength -Length $Content.Count))
    $out.AddRange($Content)
    return $out.ToArray()
}

function Read-DerTlv {
    <#
      One DER tag/length/value header, so the stand-in below can read a real
      key rather than be told what is in it.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Offset
    )

    $tag = $Bytes[$Offset]
    $i = $Offset + 1
    $length = [int]$Bytes[$i]
    $i++
    if (($length -band 0x80) -ne 0) {
        $count = $length -band 0x7F
        $length = 0
        for ($k = 0; $k -lt $count; $k++) {
            $length = ($length -shl 8) -bor [int]$Bytes[$i]
            $i++
        }
    }
    return [PSCustomObject]@{ Tag = $tag; Start = $i; Length = $length; End = $i + $length }
}

function Get-Pkcs1Modulus {
    <#
      The RSA modulus out of a PKCS#1 private key PEM, base64-encoded the same
      way RSAParameters.Modulus is - so a key and a certificate can be compared
      exactly as `openssl pkey -pubout` against `openssl x509 -pubkey` does.

      Returns $null for anything that is not a PKCS#1 private key, which is how
      the stand-in reproduces OpenSSL's own refusal to read one.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $text -or $text -notmatch '-----BEGIN (RSA )?PRIVATE KEY-----') { return $null }

    $der = [Convert]::FromBase64String((($text -replace '-----[^-]+-----', '') -replace '\s', ''))

    $sequence = Read-DerTlv -Bytes $der -Offset 0
    if ($sequence.Tag -ne 0x30) { return $null }

    $version = Read-DerTlv -Bytes $der -Offset $sequence.Start
    if ($version.Tag -ne 0x02) { return $null }

    $modulus = Read-DerTlv -Bytes $der -Offset $version.End
    if ($modulus.Tag -ne 0x02) { return $null }

    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    $bytes.AddRange([byte[]]$der[$modulus.Start..($modulus.End - 1)])
    # DER pads a leading zero on so the integer is not negative; RSAParameters
    # does not carry it, so drop it before comparing the two.
    while ($bytes.Count -gt 1 -and $bytes[0] -eq 0) { $bytes.RemoveAt(0) }

    return [Convert]::ToBase64String($bytes.ToArray())
}

function ConvertTo-PemText {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][byte[]]$Der
    )

    $base64 = [Convert]::ToBase64String($Der)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("-----BEGIN $Label-----")
    for ($i = 0; $i -lt $base64.Length; $i += 64) {
        $lines.Add($base64.Substring($i, [Math]::Min(64, $base64.Length - $i)))
    }
    $lines.Add("-----END $Label-----")
    return (($lines -join "`n") + "`n")
}

function New-TestKeyPair {
    <#
      A real 2048-bit RSA key and a real self-signed certificate over it,
      written as PEM. The certificate goes through .NET's own
      CertificateRequest, so it is exactly the kind of file
      Test-DeltaCertificateMaterial parses with X509Certificate2.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [string]$Subject = 'CN=delta.ncscm.gov.jo',
        [int]$NotBeforeDays = -1,
        [int]$NotAfterDays = 365
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        $null = New-Item -ItemType Directory -Path $Directory -Force
    }

    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
        $Subject, $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $certificate = $request.CreateSelfSigned(
        [DateTimeOffset]::UtcNow.AddDays($NotBeforeDays),
        [DateTimeOffset]::UtcNow.AddDays($NotAfterDays))

    $p = $rsa.ExportParameters($true)
    $content = New-Object 'System.Collections.Generic.List[byte]'
    $content.AddRange([byte[]](New-DerInteger -Value ([byte[]]@(0))))
    foreach ($field in @($p.Modulus, $p.Exponent, $p.D, $p.P, $p.Q, $p.DP, $p.DQ, $p.InverseQ)) {
        $content.AddRange([byte[]](New-DerInteger -Value $field))
    }

    $certificatePath = Join-Path $Directory "$BaseName.pem"
    $keyPath         = Join-Path $Directory "$BaseName-key.pem"

    Set-Content -LiteralPath $certificatePath -Encoding Ascii -NoNewline `
        -Value (ConvertTo-PemText -Label 'CERTIFICATE' -Der $certificate.RawData)
    Set-Content -LiteralPath $keyPath -Encoding Ascii -NoNewline `
        -Value (ConvertTo-PemText -Label 'RSA PRIVATE KEY' -Der ([byte[]](New-DerSequence -Content $content.ToArray())))

    return [PSCustomObject]@{
        CertificatePath = $certificatePath
        KeyPath         = $keyPath
        Modulus         = [Convert]::ToBase64String($p.Modulus)
    }
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

$Script:WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("delta-cert-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $Script:WorkRoot -Force

# A directory with a space in it, because the mount argument is built by string
# concatenation and then quoted by ConvertTo-DeltaCommandLine.
$Script:SpacedDir = Join-Path $Script:WorkRoot 'Certificates For DELTA'

# The operator's real filenames from the report, so the reversed-selection case
# below is the one they actually hit.
$Script:Pair       = New-TestKeyPair -Directory $Script:WorkRoot -BaseName 'delta.ncscm.gov.jo'
$Script:OtherPair  = New-TestKeyPair -Directory $Script:WorkRoot -BaseName 'unrelated'
$Script:SpacedPair = New-TestKeyPair -Directory $Script:SpacedDir -BaseName 'delta.ncscm.gov.jo'

# ---------------------------------------------------------------------------
# The Docker stand-in
#
# Records every call, and models the container closely enough that the reported
# failure is REPRODUCED here rather than asserted about: it applies dash's own
# rule for `set` to the payload it is actually given, and when that rule
# rejects the payload it answers exactly what postgis/postgis:17-3.5 answered
# when this was measured - exit 2, no stdout, one line on stderr.
# ---------------------------------------------------------------------------

# Measured: docker run --rm --entrypoint sh postgis/postgis:17-3.5 -c "set -e`r`n..."
$Script:DashSetError = 'sh: 1: set: Illegal option -'

$Script:DockerCalls = New-Object 'System.Collections.Generic.List[object]'
$Script:DockerBehaviour = 'shell'   # 'shell' | 'engine-failure'

function Get-ShellPayloadFrom {
    <#
      The argument after '-c', which is what the container's shell is given.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)

    for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
        if ($Arguments[$i] -eq '-c') { return $Arguments[$i + 1] }
    }
    return $null
}

function Invoke-DashSetRule {
    <#
      dash's own handling of `set`, applied to the payload's first line.

      dash walks the characters of an option word and rejects the first one
      that is not an option letter. A CR is not an option letter, so `set -e`
      followed by a carriage return is "Illegal option -" with an invisible
      CR after the dash - which is the whole of the reported bug, and why the
      message looks like it is complaining about nothing.

      Returns $null when the line is acceptable, or the error dash prints.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Payload)

    # Split on LF only, and match with [ \t] rather than \s - a regex \s
    # matches CR, which would quietly hide the very character under test.
    $firstLine = ($Payload -split "`n")[0]
    if ($firstLine -notmatch '^[ \t]*set[ \t]+(.+)$') { return $null }

    $word = $Matches[1]
    if ($word -notmatch '^[-+][a-zA-Z]+$') { return $Script:DashSetError }
    return $null
}

function Invoke-DeltaDockerCommand {
    <#
      Shadows the real one for this script's scope. Starts nothing.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 120,
        [AllowNull()][string]$StandardInput
    )

    $payload = Get-ShellPayloadFrom -Arguments $Arguments
    $null = $Script:DockerCalls.Add([PSCustomObject]@{
        Arguments   = $Arguments
        CommandLine = ConvertTo-DeltaCommandLine -Arguments $Arguments
        Payload     = $payload
    })

    if ($Script:DockerBehaviour -eq 'engine-failure') {
        return [PSCustomObject]@{
            ExitCode = -1; StdOut = ''; StdErr = 'error during connect: Docker Desktop is not running.'
            TimedOut = $false; Started = $false; Error = 'not-found'
        }
    }

    # The shell gets the payload before openssl sees anything at all.
    $shellError = Invoke-DashSetRule -Payload $payload
    if ($shellError) {
        return [PSCustomObject]@{
            ExitCode = 2; StdOut = ''; StdErr = $shellError
            TimedOut = $false; Started = $true; Error = $null
        }
    }

    # The script survived the shell, so answer as openssl would - read the
    # staged files out of whatever directory was actually mounted, which is
    # also how the mount is proven to be the one carrying the material.
    $mount = $null
    for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
        if ($Arguments[$i] -eq '-v') { $mount = $Arguments[$i + 1] }
    }
    $hostPath = ($mount -replace ':/work(:ro)?$', '')

    $certificateFile = Join-Path $hostPath 'cert.pem'
    $keyFile         = Join-Path $hostPath 'key.pem'

    $certificate = $null
    try { $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certificateFile) }
    catch { return [PSCustomObject]@{ ExitCode = 0; StdOut = "CERT_PARSE_FAILED`nunable to load certificate"; StdErr = ''; TimedOut = $false; Started = $true; Error = $null } }

    $keyModulus = $null
    try { $keyModulus = Get-Pkcs1Modulus -Path $keyFile } catch { $keyModulus = $null }
    if (-not $keyModulus) {
        return [PSCustomObject]@{ ExitCode = 0; StdOut = "KEY_PARSE_FAILED`nCould not read private key"; StdErr = ''; TimedOut = $false; Started = $true; Error = $null }
    }

    # openssl compares the public key derived from the key with the public key
    # inside the certificate. The modulus is what distinguishes one RSA key
    # from another, so comparing the two moduli is that same test - done here
    # against the bytes actually on disk, so the verdict is real rather than
    # scripted by the fixture that wrote them.
    $certificateModulus = [Convert]::ToBase64String($certificate.PublicKey.Key.ExportParameters($false).Modulus)

    $verdict = if ($keyModulus -eq $certificateModulus) { 'PAIR_MATCH' } else { 'PAIR_MISMATCH' }
    return [PSCustomObject]@{ ExitCode = 0; StdOut = $verdict; StdErr = ''; TimedOut = $false; Started = $true; Error = $null }
}

function Reset-DockerRecorder {
    param([string]$Behaviour = 'shell')
    $Script:DockerCalls.Clear()
    $Script:DockerBehaviour = $Behaviour
}

# ===========================================================================
# 1. The regression: nothing reaches sh with a carriage return in it
# ===========================================================================

Start-TestCase 'The OpenSSL payload never carries a carriage return'

Reset-DockerRecorder
$null = Test-DeltaCertificateMaterial `
    -CertificatePath $Script:Pair.CertificatePath -KeyPath $Script:Pair.KeyPath -OpenSslImage 'test/openssl'

Assert-Equal 'one container is started to compare the pair' 1 $Script:DockerCalls.Count

$payload = $Script:DockerCalls[0].Payload
Assert-That  'a shell payload was passed at all'      ($null -ne $payload)
Assert-That  'it contains no carriage return'         (-not $payload.Contains([char]13))
Assert-That  'it still begins with set -e'            ($payload -match "^set -e`n")
Assert-That  'and it is still the real comparison script' `
    (($payload -match 'openssl x509 -in /work/cert\.pem -noout -pubkey') -and
     ($payload -match 'openssl pkey -in /work/key\.pem -pubout') -and
     ($payload -match 'cmp -s /work/from-cert\.pub /work/from-key\.pub'))

Start-TestCase 'The self-signed generation payload never carries one either'

# The other multi-line payload, and the worse of the two: its openssl call is
# spread over five lines with backslash continuations, so a CR does not merely
# break `set` - it is what the backslash escapes.
Reset-DockerRecorder
$generationDir = Join-Path $Script:WorkRoot 'generated'
$null = New-DeltaSelfSignedCertificate -HostName 'delta.ncscm.gov.jo' `
    -OutputDirectory $generationDir -OpenSslImage 'test/openssl'

Assert-Equal 'one container is started to generate'   1 $Script:DockerCalls.Count
$generationPayload = $Script:DockerCalls[0].Payload
Assert-That 'it contains no carriage return'          (-not $generationPayload.Contains([char]13))
Assert-That 'it still begins with set -e'             ($generationPayload -match "^set -e`n")
Assert-That 'its line continuations end the line'     ($generationPayload -notmatch '\\[^\n]')
Assert-That 'and it still asks for a 2048-bit self-signed certificate' `
    ($generationPayload -match 'openssl req -x509 -newkey rsa:2048 -sha256')

Start-TestCase 'The normaliser is what guarantees it, whatever the file on disk says'

# Proven against the helper directly, because the .ps1 file this suite reads
# may itself be checked out either way - so a test that only inspected the
# payload would pass for the wrong reason on an LF checkout.
Assert-Equal 'CRLF becomes LF' "set -e`nopenssl`n" (ConvertTo-DeltaShellScript -Script "set -e`r`nopenssl`r`n")
Assert-Equal 'a lone CR becomes LF too' "a`nb" (ConvertTo-DeltaShellScript -Script "a`rb")
Assert-Equal 'LF is left exactly as it is' "a`nb`n" (ConvertTo-DeltaShellScript -Script "a`nb`n")
Assert-Equal 'an empty script is not an error' '' (ConvertTo-DeltaShellScript -Script '')
Assert-That  'and nothing else about the text is touched' `
    ((ConvertTo-DeltaShellScript -Script "echo 'a  b'`ttail") -eq "echo 'a  b'`ttail")

Start-TestCase 'Invoke-DeltaOpenSsl normalises even a caller that hands it CRLF'

Reset-DockerRecorder
$null = Invoke-DeltaOpenSsl -Image 'test/openssl' -MountPath $Script:WorkRoot -Command "set -e`r`necho HI`r`n"
Assert-That 'the CR never reaches the container' (-not $Script:DockerCalls[0].Payload.Contains([char]13))
Assert-Equal 'and the script is otherwise unchanged' "set -e`necho HI`n" $Script:DockerCalls[0].Payload

# ===========================================================================
# 2. Why a carriage return was fatal, and that it no longer happens
# ===========================================================================

Start-TestCase "The reported failure is reproduced when a CR does reach the shell"

# The stand-in applies dash's own rule, so this is the operator's bug, not a
# description of it.
Assert-Equal 'dash rejects `set -e` with a trailing CR' `
    $Script:DashSetError (Invoke-DashSetRule -Payload "set -e`r`nopenssl x509")
Assert-Equal 'and accepts it without one' `
    $null (Invoke-DashSetRule -Payload "set -e`nopenssl x509")

Reset-DockerRecorder
$broken = Invoke-DeltaDockerCommand -Arguments @(
    'run', '--rm', '--entrypoint', 'sh', 'test/openssl', '-c', "set -e`r`necho PAIR_MATCH")
Assert-Equal 'the shell exits 2'                2 $broken.ExitCode
Assert-Equal 'nothing reaches stdout'           '' $broken.StdOut
Assert-Equal 'and the operator gets one line'   $Script:DashSetError $broken.StdErr

Start-TestCase 'A valid pair is no longer reported as uncomparable'

Reset-DockerRecorder
$valid = Test-DeltaCertificateMaterial `
    -CertificatePath $Script:Pair.CertificatePath -KeyPath $Script:Pair.KeyPath -OpenSslImage 'test/openssl'

Assert-That  'the pair is accepted'   $valid.IsValid
Assert-Equal 'with no reason'         $null $valid.Reason
Assert-That  'the certificate parsed' ($valid.Subject -match 'delta\.ncscm\.gov\.jo')
Assert-That  'its expiry was read'    ($valid.DaysRemaining -gt 30)

# The exact sentence from the report must not be reachable for a good pair.
Assert-That 'the operator never sees the shell error' `
    (($valid.Reason -notmatch 'Illegal option') -and ($valid.Reason -notmatch 'sh: 1:'))

# ===========================================================================
# 3. What the container is actually asked to do
# ===========================================================================

Start-TestCase 'The operator paths never reach Docker - only the staging mount does'

Reset-DockerRecorder
$null = Test-DeltaCertificateMaterial `
    -CertificatePath $Script:Pair.CertificatePath -KeyPath $Script:Pair.KeyPath -OpenSslImage 'test/openssl'

$call = $Script:DockerCalls[0]
$mountArgument = $call.Arguments[[array]::IndexOf($call.Arguments, '-v') + 1]

Assert-That 'the mount is a staging directory, not the operator source' `
    ($mountArgument -match 'delta-cert-[0-9a-f]{32}:/work')
Assert-That 'neither operator path is anywhere in the command line' `
    (($call.CommandLine -notmatch [regex]::Escape($Script:Pair.CertificatePath)) -and
     ($call.CommandLine -notmatch [regex]::Escape($Script:Pair.KeyPath)))
Assert-That 'the container gets no network'    (($call.Arguments -contains '--network') -and ($call.Arguments -contains 'none'))
Assert-That 'it is removed when it exits'      ($call.Arguments -contains '--rm')

# The comparison mount is writable, because the script writes the two derived
# public keys into it and then compares them. What makes that safe is what is
# mounted: a throwaway staging directory holding copies, never the directory
# the operator's certificate actually lives in.
Assert-That 'the writable mount is the staging copy, not the operator directory' `
    (($mountArgument -match ':/work$') -and
     ($mountArgument -match ([regex]::Escape([System.IO.Path]::GetTempPath()))))

Start-TestCase 'A writable mount is used only where something must be written'

Reset-DockerRecorder
$null = New-DeltaSelfSignedCertificate -HostName 'delta.ncscm.gov.jo' `
    -OutputDirectory (Join-Path $Script:WorkRoot 'generated2') -OpenSslImage 'test/openssl'
$generationMount = $Script:DockerCalls[0].Arguments[[array]::IndexOf($Script:DockerCalls[0].Arguments, '-v') + 1]
Assert-That 'generation mounts the output directory writable' ($generationMount -match ':/work$')

# ===========================================================================
# 4. The validation itself, which the fix must not have weakened
# ===========================================================================

Start-TestCase 'A private key chosen as the certificate is rejected'

# The operator's first attempt: the two files selected the wrong way round.
# This is refused before Docker is involved at all - X509Certificate2 cannot
# parse a private key - and that is the correct outcome, not the bug.
Reset-DockerRecorder
$reversed = Test-DeltaCertificateMaterial `
    -CertificatePath $Script:Pair.KeyPath -KeyPath $Script:Pair.CertificatePath -OpenSslImage 'test/openssl'

Assert-That  'it is refused'                    (-not $reversed.IsValid)
Assert-That  'and named as a certificate problem' ($reversed.Reason -match 'could not be parsed as an X\.509 certificate')
Assert-That  'the offending file is identified' ($reversed.Reason -match [regex]::Escape($Script:Pair.KeyPath))
Assert-Equal 'no container was started for it'  0 $Script:DockerCalls.Count

Start-TestCase 'A mismatched private key is rejected as a mismatch'

Reset-DockerRecorder
$mismatch = Test-DeltaCertificateMaterial `
    -CertificatePath $Script:Pair.CertificatePath -KeyPath $Script:OtherPair.KeyPath -OpenSslImage 'test/openssl'

Assert-That 'it is refused'                    (-not $mismatch.IsValid)
Assert-That 'and told apart from a parse failure' ($mismatch.Reason -match 'does not match the certificate')
Assert-That 'both files are named'             (($mismatch.Reason -match [regex]::Escape($Script:OtherPair.KeyPath)) -and
                                                ($mismatch.Reason -match [regex]::Escape($Script:Pair.CertificatePath)))
Assert-That 'and the operator is told what would happen' ($mismatch.Reason -match 'NGINX would refuse to start')

Start-TestCase 'A missing file is reported as a missing file'

$absent = Test-DeltaCertificateMaterial `
    -CertificatePath (Join-Path $Script:WorkRoot 'no-such.pem') -KeyPath $Script:Pair.KeyPath -OpenSslImage 'test/openssl'
Assert-That 'the certificate is reported'  ($absent.Reason -match 'does not exist')

$absentKey = Test-DeltaCertificateMaterial `
    -CertificatePath $Script:Pair.CertificatePath -KeyPath (Join-Path $Script:WorkRoot 'no-such-key.pem') -OpenSslImage 'test/openssl'
Assert-That 'and so is the key'            ($absentKey.Reason -match 'private key file .* does not exist')

Start-TestCase 'An encrypted private key is still refused with an instruction'

$encryptedKey = Join-Path $Script:WorkRoot 'encrypted-key.pem'
Set-Content -LiteralPath $encryptedKey -Encoding Ascii -Value @(
    '-----BEGIN ENCRYPTED PRIVATE KEY-----'
    'MIIFHDBOBgkqhkiG9w0BBQ0wQTApBgkqhkiG9w0BBQwwHAQI'
    '-----END ENCRYPTED PRIVATE KEY-----')

Reset-DockerRecorder
$encrypted = Test-DeltaCertificateMaterial `
    -CertificatePath $Script:Pair.CertificatePath -KeyPath $encryptedKey -OpenSslImage 'test/openssl'

Assert-That  'it is refused'                   (-not $encrypted.IsValid)
Assert-That  'and says why'                    ($encrypted.Reason -match 'passphrase-protected')
Assert-That  'and how to fix it'               ($encrypted.Reason -match 'openssl rsa -in')
Assert-Equal 'without starting a container'    0 $Script:DockerCalls.Count

Start-TestCase 'An expired certificate is still refused'

$expired = New-TestKeyPair -Directory $Script:WorkRoot -BaseName 'expired' -NotBeforeDays -400 -NotAfterDays -30
$expiredCheck = Test-DeltaCertificateMaterial `
    -CertificatePath $expired.CertificatePath -KeyPath $expired.KeyPath -OpenSslImage 'test/openssl'
Assert-That 'it is refused'    (-not $expiredCheck.IsValid)
Assert-That 'and says expired' ($expiredCheck.Reason -match 'expired on')

Start-TestCase 'A certificate close to expiry is accepted with a warning'

$soon = New-TestKeyPair -Directory $Script:WorkRoot -BaseName 'expiring' -NotAfterDays 10
$soonCheck = Test-DeltaCertificateMaterial `
    -CertificatePath $soon.CertificatePath -KeyPath $soon.KeyPath -OpenSslImage 'test/openssl'
Assert-That 'it is accepted'  $soonCheck.IsValid
Assert-That 'and warned about' ($soonCheck.Warning -match 'expires in')

Start-TestCase 'A Docker or OpenSSL failure is surfaced, never swallowed'

# The engine is down: no stdout, so nothing can be concluded about the pair.
# The one thing that must not happen is the pair being accepted.
Reset-DockerRecorder -Behaviour 'engine-failure'
$engineDown = Test-DeltaCertificateMaterial `
    -CertificatePath $Script:Pair.CertificatePath -KeyPath $Script:Pair.KeyPath -OpenSslImage 'test/openssl'

Assert-That 'the pair is NOT accepted'      (-not $engineDown.IsValid)
Assert-That 'the failure is reported'       ($engineDown.Reason -match 'could not be compared')
Assert-That 'and what Docker said is quoted' ($engineDown.Reason -match 'Docker Desktop is not running')

# ===========================================================================
# 5. Paths: a non-system drive, and spaces
# ===========================================================================

Start-TestCase 'A certificate and key on a non-system drive are validated normally'

# The operator's material was on D:\. It works because both files are copied
# into one staging directory first and only that directory is mounted - the
# source drive never reaches Docker at all. Run against a real second volume
# when this host has one; the staging assertions above cover the mechanism
# either way.
$otherVolume = @(Get-PSDrive -PSProvider FileSystem |
    Where-Object { $_.Name.Length -eq 1 -and $_.Name -ne 'C' -and $_.Root -match '^[A-Z]:\\$' -and (Test-Path -LiteralPath $_.Root) } |
    Select-Object -First 1)

if ($otherVolume.Count -eq 1) {
    $volumeRoot = $otherVolume[0].Root
    $volumeDir  = Join-Path $volumeRoot ("delta-cert-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $volumePair = New-TestKeyPair -Directory $volumeDir -BaseName 'delta.ncscm.gov.jo'

        Reset-DockerRecorder
        $volumeCheck = Test-DeltaCertificateMaterial `
            -CertificatePath $volumePair.CertificatePath -KeyPath $volumePair.KeyPath -OpenSslImage 'test/openssl'

        Assert-That  "a pair on $volumeRoot is accepted" $volumeCheck.IsValid
        Assert-That  'and no CR reached the shell'       (-not $Script:DockerCalls[0].Payload.Contains([char]13))
        Assert-That  "the $volumeRoot path is not what gets mounted" `
            ($Script:DockerCalls[0].CommandLine -notmatch [regex]::Escape($volumeDir))

        Reset-DockerRecorder
        $volumeMismatch = Test-DeltaCertificateMaterial `
            -CertificatePath $volumePair.CertificatePath -KeyPath $Script:OtherPair.KeyPath -OpenSslImage 'test/openssl'
        Assert-That "a mismatch on $volumeRoot is still caught" `
            ((-not $volumeMismatch.IsValid) -and ($volumeMismatch.Reason -match 'does not match'))
    }
    finally {
        Remove-Item -LiteralPath $volumeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
else {
    Write-Host '    [skip] this host has only one filesystem volume' -ForegroundColor DarkGray
    Assert-That 'the staging copy is what makes any drive work' `
        ((Get-Command Test-DeltaCertificateMaterial).Definition -match 'GetTempPath')
}

Start-TestCase 'Paths containing spaces survive into the docker command line'

Reset-DockerRecorder
$spacedCheck = Test-DeltaCertificateMaterial `
    -CertificatePath $Script:SpacedPair.CertificatePath -KeyPath $Script:SpacedPair.KeyPath -OpenSslImage 'test/openssl'

Assert-That 'a pair under a spaced directory is accepted' $spacedCheck.IsValid
Assert-That 'and no CR reached the shell'                 (-not $Script:DockerCalls[0].Payload.Contains([char]13))

# The staging directory has no space in it, so the mount argument is the wrong
# place to prove the quoting. The payload does contain spaces and newlines, and
# it must arrive as ONE argument.
$commandLine = $Script:DockerCalls[0].CommandLine
Assert-That 'the multi-line payload is quoted as a single argument' `
    ($commandLine -match '"set -e[\s\S]*PAIR_MISMATCH[^"]*"')

Start-TestCase 'A mount path containing a space is quoted correctly'

# Directly against the quoter, with the argument vector Invoke-DeltaOpenSsl
# builds - a spaced staging path is not reachable through GetTempPath here, but
# the caller passes MountPath straight through and a site could relocate TEMP.
Reset-DockerRecorder
$null = Invoke-DeltaOpenSsl -Image 'test/openssl' -MountPath $Script:SpacedDir -Command "echo hi`n"
$spacedMountLine = $Script:DockerCalls[0].CommandLine
Assert-That 'the mount argument is quoted whole' `
    ($spacedMountLine -match ('"' + [regex]::Escape($Script:SpacedDir) + ':/work:ro"'))

# ===========================================================================
# 6. The managed key's Windows ACL, and what a container can do with it
#
# The failure these were written for:
#
#     nginx: [emerg] cannot load certificate key "/etc/nginx/certs/delta.key":
#     BIO_new_file() failed (... Permission denied ...)
#
# with the key plainly present and non-empty on the host, and with even
# container root refused. Inside the container the file showed as:
#
#     ----------  0000  root root  delta.key
#
# Docker Desktop's WSL2 backend reaches a Windows drive over 9p, and the 9p
# server runs on the Windows side as the LOGGED-ON USER - not SYSTEM, and with
# no ACL-bypass privilege. WSL synthesises each file's Linux mode from that
# account's effective access, so a key hardened to Administrators + SYSTEM is
# projected as 0000 whenever that account's token holds BUILTIN\Administrators
# as deny-only, which is every ordinary administrator under UAC. Signed in as
# the built-in Administrator with Admin Approval Mode off - the usual Windows
# Server posture - the same ACL works, which is why the Server installations
# never showed it.
#
# The fix names the one account that is never deny-only, and gives it Read.
# ===========================================================================

# icacls output is one file heading plus indented ACE lines; the trailing two
# summary lines are noise. Parsed rather than string-matched wholesale so an
# assertion can be about a specific principal's specific rights.
function Get-AclEntries {
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(& icacls.exe $Path 2>&1)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $lines) {
        $text = [string]$line
        if ($text -match '^\s*$' -or $text -match 'Successfully processed') { continue }
        # The first line carries the path before the first ACE.
        $text = $text -replace ('^' + [regex]::Escape($Path) + '\s*'), ''
        if ($text -match '^\s*([^:]+):\(([^)]*)\)\s*$') {
            $null = $entries.Add([PSCustomObject]@{
                Principal = $Matches[1].Trim()
                Rights    = $Matches[2].Trim()
            })
        }
    }
    return $entries
}

$Script:CurrentUserSid  = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
$Script:CurrentUserName = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Translate([Security.Principal.NTAccount]).Value

Start-TestCase 'The Docker read account is the installing user, named by SID'

$dockerSid = Get-DeltaDockerFileReadSid
Assert-That  'a principal is identified'        ($null -ne $dockerSid)
Assert-Equal 'it is the current user, as a SID' "*$Script:CurrentUserSid" $dockerSid
Assert-That  'given to icacls in *S-1- form, so no name has to resolve' `
    ($dockerSid -match '^\*S-1-[\d-]+$')

Start-TestCase 'Install-DeltaCertificate stages a key the Docker account can read'

$aclRoot = Join-Path $Script:WorkRoot 'install-root'
$null = New-Item -ItemType Directory -Path $aclRoot -Force

$staged = Install-DeltaCertificate -InstallRoot $aclRoot `
    -CertificatePath $Script:Pair.CertificatePath -KeyPath $Script:Pair.KeyPath

Assert-That 'the key is staged'         (Test-Path -LiteralPath $staged.KeyPath -PathType Leaf)
Assert-That 'the certificate is staged' (Test-Path -LiteralPath $staged.CertificatePath -PathType Leaf)
Assert-Equal 'NGINX is pointed at the container path' '/etc/nginx/certs/delta.key' $staged.ContainerKeyPath

$keyAcl = Get-AclEntries -Path $staged.KeyPath
$userAce = @($keyAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName })

Assert-Equal 'the Docker account has exactly one entry' 1 $userAce.Count
Assert-Equal 'and it is Read, nothing more'             'R' $userAce[0].Rights
Assert-That  'SYSTEM keeps full control' `
    (@($keyAcl | Where-Object { $_.Principal -match 'SYSTEM$' -and $_.Rights -eq 'F' }).Count -eq 1)
Assert-That  'Administrators keeps full control' `
    (@($keyAcl | Where-Object { $_.Principal -match 'Administrators$' -and $_.Rights -eq 'F' }).Count -eq 1)

Start-TestCase 'No broad principal is introduced'

foreach ($broad in @('Everyone', 'Users', 'Authenticated Users')) {
    Assert-Equal "no ACE for $broad" 0 `
        (@($keyAcl | Where-Object { $_.Principal -match ([regex]::Escape($broad) + '$') }).Count)
}
# Belt and braces, against the source rather than one run's output: the words
# the requirement forbids must not appear as grants anywhere in the hardening.
$Script:ConfigText = Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1') -Raw
Assert-That 'the hardening never grants Everyone'  ($Script:ConfigText -notmatch '(?i)/grant[^\r\n]*Everyone')
Assert-That 'nor BUILTIN\Users'                    ($Script:ConfigText -notmatch '(?i)/grant[^\r\n]*BUILTIN\\Users')
Assert-That 'nor Authenticated Users'              ($Script:ConfigText -notmatch '(?i)/grant[^\r\n]*Authenticated Users')
Assert-That 'and still strips them with /remove:g' ($Script:ConfigText -match '(?i)icacls\.exe \$Path /remove:g \$principal')
foreach ($broad in @('BUILTIN\Users', 'Everyone', 'NT AUTHORITY\Authenticated Users')) {
    Assert-That "$broad is still on the strip list" `
        ($Script:ConfigText -match ('(?s)\$broadPrincipals\s*=\s*@\([^)]*' + [regex]::Escape("'$broad'")))
}

Start-TestCase 'The certificate itself is left readable and unhardened'

# delta.crt is public material. It was never hardened, and it must stay that
# way - the operator's own evidence had it as -rwxrwxrwx while the key was 0000.
$certAcl = Get-AclEntries -Path $staged.CertificatePath
Assert-That 'the certificate has no restrictive rewrite' `
    (@($certAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName -and $_.Rights -eq 'R' }).Count -eq 0)
Assert-That 'and it is still readable by this process' `
    ((Get-Content -LiteralPath $staged.CertificatePath -Raw).Length -gt 0)

Start-TestCase 'A rerun repairs the exact ACL the operator reported'

# The reported starting state, reproduced precisely: Administrators + SYSTEM
# and nothing else. /inheritance:r drops the INHERITED entries only, so the
# explicit one this installer just wrote has to be removed by name as well -
# which is also a fair model of a key staged before the fix existed.
$brokenKey = $staged.KeyPath
$null = & icacls.exe $brokenKey /inheritance:r /C 2>&1
$null = & icacls.exe $brokenKey /remove:g "*$Script:CurrentUserSid" /C 2>&1
$null = & icacls.exe $brokenKey /grant 'NT AUTHORITY\SYSTEM:(F)' /C 2>&1
$null = & icacls.exe $brokenKey /grant 'BUILTIN\Administrators:(F)' /C 2>&1

$brokenAcl = Get-AclEntries -Path $brokenKey
Assert-Equal 'the broken state has no entry for the Docker account' 0 `
    (@($brokenAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName }).Count)
Assert-Equal 'only the two the operator saw' 2 $brokenAcl.Count

# Rerunning the installer runs Install-DeltaCertificate again, on every path
# that reaches TLS - that is what makes this a repair and not a reinstall.
$repaired = Install-DeltaCertificate -InstallRoot $aclRoot `
    -CertificatePath $Script:Pair.CertificatePath -KeyPath $Script:Pair.KeyPath
$repairedAcl = Get-AclEntries -Path $repaired.KeyPath
$repairedAce = @($repairedAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName })

Assert-Equal 'the rerun restores the Docker read entry' 1 $repairedAce.Count
Assert-Equal 'still Read, not widened by the repair'    'R' $repairedAce[0].Rights
Assert-That  'and the hardening is still in place' `
    ((@($repairedAcl | Where-Object { $_.Principal -match 'SYSTEM$' }).Count -eq 1) -and
     (@($repairedAcl | Where-Object { $_.Principal -match 'Everyone$' }).Count -eq 0))

Start-TestCase 'Without the switch, nothing gains the extra entry'

# .env, its backups and the key backups in certs\ are never opened by a
# container, so they keep the narrower ACL. This is the least-privilege half of
# the fix and it is the one a future refactor is most likely to erode.
$plainSecret = Join-Path $Script:WorkRoot 'plain-secret.env'
Set-Content -LiteralPath $plainSecret -Value 'SECRET=1' -Encoding Ascii
$null = & icacls.exe $plainSecret /inheritance:r /C 2>&1
$null = & icacls.exe $plainSecret /grant 'BUILTIN\Administrators:(F)' /C 2>&1
Protect-DeltaSecretFile -Path $plainSecret

$plainAcl = Get-AclEntries -Path $plainSecret
Assert-Equal 'no Docker read entry is added by default' 0 `
    (@($plainAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName }).Count)
Assert-That  'and it is still hardened' `
    ((@($plainAcl | Where-Object { $_.Principal -match 'SYSTEM$' }).Count -eq 1) -and
     (@($plainAcl | Where-Object { $_.Principal -match 'Administrators$' }).Count -eq 1))

Start-TestCase 'The key backup beside the key stays narrow'

# Backup-DeltaCertificateMaterial writes delta.key.bak-<stamp> INTO certs\,
# which is the mounted directory. It is not NGINX's key and must not acquire
# the read entry just because it shares a directory with one.
Assert-That 'the backup is protected without -AllowDockerRead' `
    ((Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'lib\Delta.Configure.ps1') -Raw) -match
     '(?s)Copy-Item -LiteralPath \$current\.KeyPath -Destination \$result\.KeyBackup -Force\s*\r?\n\s*Protect-DeltaSecretFile -Path \$result\.KeyBackup\s*\r?\n')

Start-TestCase 'A restored key is readable again after a rollback'

Assert-That 'Restore-DeltaCertificateMaterial re-applies the Docker read entry' `
    ((Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'lib\Delta.Configure.ps1') -Raw) -match
     'Protect-DeltaSecretFile -Path \$current\.KeyPath -AllowDockerRead')

Start-TestCase 'Compose still mounts certs read-only'

$composeTemplate = Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'templates\docker-compose.yml.template') -Raw
Assert-That 'the certs mount carries :ro' ($composeTemplate -match '\./certs:/etc/nginx/certs:ro')
Assert-That 'and nothing mounts certs writable' ($composeTemplate -notmatch '\./certs:/etc/nginx/certs\s*$')

# ===========================================================================
# 7. The real engine (-Live only)
# ===========================================================================

if ($Live) {
    Start-TestCase "Live: the real OpenSSL container against real material ($LiveImage)"

    # The stand-in is dropped for this section: the REAL Invoke-DeltaDockerCommand
    # from lib\Delta.Docker.ps1 is restored, so these calls start real
    # containers. Read-only, no network, removed on exit.
    Remove-Item -LiteralPath 'function:Invoke-DeltaDockerCommand' -Force
    . (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')

    $imageCheck = Invoke-DeltaDockerCommand -Arguments @('image', 'inspect', $LiveImage) -TimeoutSeconds 60
    if ($imageCheck.ExitCode -ne 0) {
        Write-Host "    [skip] $LiveImage is not present locally, and this suite pulls nothing" -ForegroundColor DarkGray
    }
    else {
        $liveValid = Test-DeltaCertificateMaterial `
            -CertificatePath $Script:Pair.CertificatePath -KeyPath $Script:Pair.KeyPath -OpenSslImage $LiveImage
        Assert-That 'a real matching pair is accepted by real OpenSSL' $liveValid.IsValid
        Assert-That 'and no shell error is reported' `
            (($null -eq $liveValid.Reason) -or ($liveValid.Reason -notmatch 'Illegal option'))

        $liveMismatch = Test-DeltaCertificateMaterial `
            -CertificatePath $Script:Pair.CertificatePath -KeyPath $Script:OtherPair.KeyPath -OpenSslImage $LiveImage
        Assert-That 'a real mismatch is rejected by real OpenSSL' `
            ((-not $liveMismatch.IsValid) -and ($liveMismatch.Reason -match 'does not match the certificate'))

        $liveGeneration = New-DeltaSelfSignedCertificate -HostName 'delta.ncscm.gov.jo' `
            -OutputDirectory (Join-Path $Script:WorkRoot 'live-generated') -OpenSslImage $LiveImage
        Assert-That 'real self-signed generation succeeds' $liveGeneration.Succeeded

        if ($liveGeneration.Succeeded) {
            $liveGeneratedCheck = Test-DeltaCertificateMaterial `
                -CertificatePath $liveGeneration.CertificatePath -KeyPath $liveGeneration.KeyPath -OpenSslImage $LiveImage
            Assert-That 'and what it generated validates as a pair' $liveGeneratedCheck.IsValid
        }
    }

    Start-TestCase 'Live: the staged key through the real certs bind mount'

    # The whole point, end to end: the managed key, its real ACL, and the mount
    # Compose actually declares. Nothing here prints a byte of the key - the
    # container reports its size and its mode, and that is all that leaves it.
    $liveCertsDir = Split-Path -Parent $staged.KeyPath
    $expectedBytes = (Get-Item -LiteralPath $staged.KeyPath).Length

    $probe = 'cd /etc/nginx/certs; ' +
             'for f in delta.crt delta.key; do ' +
             'echo $f mode=$(stat -c %a $f) bytes=$(dd if=$f bs=1 2>/dev/null | wc -c); done; ' +
             'echo -n write=; (echo x >> delta.key) 2>/dev/null && echo ALLOWED || echo REFUSED'

    $mountProbe = Invoke-DeltaDockerCommand -Arguments @(
        'run', '--rm', '--network', 'none',
        '-v', "${liveCertsDir}:/etc/nginx/certs:ro",
        '--entrypoint', 'sh', $LiveImage, '-c', $probe) -TimeoutSeconds 300

    $probeOut = ($mountProbe.StdOut + "`n" + $mountProbe.StdErr)

    Assert-Equal 'the probe container ran' 0 $mountProbe.ExitCode
    Assert-That  'the certificate is readable in the container' `
        ($probeOut -match 'delta\.crt mode=\d+ bytes=[1-9]\d*')
    Assert-That  "the private key is readable in the container ($expectedBytes bytes on the host)" `
        ($probeOut -match "delta\.key mode=\d+ bytes=$expectedBytes")
    Assert-That  'the key is NOT mode 0000 - the reported failure' `
        ($probeOut -notmatch 'delta\.key mode=0 ')
    Assert-That  'and the container cannot write to it through the :ro mount' `
        ($probeOut -match 'write=REFUSED')
}

# --- teardown ---------------------------------------------------------------

Remove-Item -LiteralPath $Script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('-' * 60)
Write-Host "  passed: $Script:Passed"
Write-Host "  failed: $Script:Failed"
Write-Host ('-' * 60)
Write-Host ''
if (-not $Live) {
    Write-Host '  Docker was replaced by a stand-in that models the container shell.'
    Write-Host '  Run with -Live to validate against the real engine as well.'
    Write-Host ''
}

if ($Script:Failed -gt 0) { exit 1 }
exit 0
