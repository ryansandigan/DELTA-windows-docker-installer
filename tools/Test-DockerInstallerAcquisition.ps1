#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for how the installer obtains "Docker Desktop Installer.exe".

.DESCRIPTION
    Covers Resolve-DeltaDockerInstaller's acquisition order and the
    verification that stands between a downloaded binary and running it:

      1. -DockerInstallerPath, when the operator supplied one
      2. installers\ beside setup.ps1, for a site that staged it
      3. an automatic download from Docker's documented URL

    Step 3 is the reason this file exists. It used to be opt-in behind
    -AllowDockerDownload, so the ordinary fresh machine - no Docker, nothing
    staged - stopped at "No Docker Desktop installer was found" instead of
    fetching the installer it was perfectly able to fetch. The default-on
    behaviour is asserted here so it cannot quietly become opt-in again.

    Deliberately dependency-free and offline, matching Test-Release.ps1: no
    Pester, no modules, and no network. Invoke-WebRequest and
    Get-AuthenticodeSignature are replaced with scripted stand-ins, so every
    download outcome - success, transport failure, truncation, an HTML error
    page, an unsigned binary, someone else's valid signature - is reproducible
    on a machine with no internet access and Docker already installed.

    Nothing here runs an installer, touches Docker, or reads the live
    installation. The functions under test are the real ones, dot-sourced from
    lib\Delta.Docker.ps1.

    Exits 0 if every test passes, 1 otherwise.

.PARAMETER KeepArtifacts
    Leaves the temporary working directories on disk and prints their paths,
    instead of deleting them. For inspecting a failure.

.EXAMPLE
    .\tools\Test-DockerInstallerAcquisition.ps1
#>

[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$Script:WorkRoot    = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("delta-docker-acq-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Script:Passed = 0
$Script:Failed = 0

# The library under test, plus what it is built on. Dot-sourced rather than
# copied so these assertions run against the shipping code.
. (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')

# ---------------------------------------------------------------------------
# Assertion helpers (same shape as Test-Release.ps1)
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
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Expected,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Actual
    )
    if ($Expected -ceq $Actual) { Write-Host "    [PASS] $Description" -ForegroundColor Green; $Script:Passed++ }
    else {
        Write-Host "    [FAIL] $Description" -ForegroundColor Red
        Write-Host "           expected: '$Expected'" -ForegroundColor Red
        Write-Host "           actual:   '$Actual'" -ForegroundColor Red
        $Script:Failed++
    }
}

function Start-TestCase {
    param([Parameter(Mandatory)][string]$Name)
    Write-Host ''
    Write-Host "==> $Name" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Scripted stand-ins
#
# A function shadows a cmdlet of the same name, so the library calls these
# without knowing. Each test sets $Script:DownloadBehaviour and
# $Script:SignatureBehaviour and then asserts what the real code did with the
# result.
# ---------------------------------------------------------------------------

$Script:DownloadBehaviour  = 'good'
$Script:SignatureBehaviour = 'docker'
$Script:DownloadCalls      = 0
$Script:LastDownloadUri    = $null

function Invoke-WebRequest {
    param(
        [string]$Uri,
        [string]$OutFile,
        [switch]$UseBasicParsing,
        [string]$ErrorAction
    )

    $Script:DownloadCalls++
    $Script:LastDownloadUri = $Uri

    switch ($Script:DownloadBehaviour) {
        'throw'     { throw 'The remote name could not be resolved: desktop.docker.com' }
        'tiny'      { New-TestFile -Path $OutFile -Bytes 512 -Executable $true }
        'html'      { New-TestFile -Path $OutFile -Bytes 4KB -Executable $false }
        'nothing'   { }   # reports success, writes no file
        default     { New-TestFile -Path $OutFile -Bytes 4KB -Executable $true }
    }
}

function Get-AuthenticodeSignature {
    param([string]$LiteralPath, [string]$ErrorAction)

    switch ($Script:SignatureBehaviour) {
        'unsigned' { return [PSCustomObject]@{ Status = 'NotSigned';    SignerCertificate = $null } }
        'tampered' { return [PSCustomObject]@{ Status = 'HashMismatch'; SignerCertificate = [PSCustomObject]@{ Subject = 'CN=Docker Inc, O=Docker Inc, C=US' } } }
        # Contains the word "Docker" on purpose: a substring search over the
        # whole subject accepts this, which is the bug these tests caught.
        'stranger' { return [PSCustomObject]@{ Status = 'Valid';        SignerCertificate = [PSCustomObject]@{ Subject = 'CN=Definitely Not Docker Ltd, O=Definitely Not Docker Ltd, C=XX' } } }
        'lookalike'{ return [PSCustomObject]@{ Status = 'Valid';        SignerCertificate = [PSCustomObject]@{ Subject = 'CN=Evil, O=Not Docker Inc, L=Nowhere, C=XX' } } }
        'nosubject'{ return [PSCustomObject]@{ Status = 'Valid';        SignerCertificate = [PSCustomObject]@{ Subject = '' } } }
        'cnonly'   { return [PSCustomObject]@{ Status = 'Valid';        SignerCertificate = [PSCustomObject]@{ Subject = 'CN=Docker Inc' } } }
        'throw'    { throw 'The signature could not be read.' }
        default    { return [PSCustomObject]@{ Status = 'Valid';        SignerCertificate = [PSCustomObject]@{ Subject = 'CN=Docker Inc, O=Docker Inc, L=Palo Alto, S=California, C=US' } } }
    }
}

function New-TestFile {
    <#
      A file of a given length, optionally starting with the MZ header a real
      Windows executable has. SetLength rather than writing the bytes: the size
      matters, the middle does not.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Bytes,
        [bool]$Executable = $true
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $stream = [System.IO.File]::Create($Path)
    try {
        $head = if ($Executable) { [byte[]]@(0x4D, 0x5A) } else { [System.Text.Encoding]::ASCII.GetBytes('<h') }
        $stream.Write($head, 0, $head.Length)
        $stream.SetLength($Bytes)
    }
    finally { $stream.Dispose() }
}

function New-Sandbox {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $Script:WorkRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Reset-Scenario {
    param([string]$Download = 'good', [string]$Signature = 'docker')
    $Script:DownloadBehaviour  = $Download
    $Script:SignatureBehaviour = $Signature
    $Script:DownloadCalls      = 0
    $Script:LastDownloadUri    = $null
    # Each case gets a clean destination, since the code deletes leftovers.
    $leftover = Join-Path $env:TEMP $Script:DeltaDockerInstallerName
    if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force }
}

New-Item -ItemType Directory -Path $Script:WorkRoot -Force | Out-Null

# The shipped floor is 100 MB, which is right for a ~600 MB installer and
# wrong for a test that would then have to write 100 MB files. The threshold
# is lowered here and the shipped value asserted separately below, so both the
# behaviour and the real constant are covered.
$Script:RealMinimumBytes = $Script:DeltaDockerInstallerMinimumBytes
$Script:DeltaDockerInstallerMinimumBytes = 2KB

Write-Host ''
Write-Host '==> DELTA Docker installer acquisition tests' -ForegroundColor Cyan
Write-Host "    Library under test: $(Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')"
Write-Host "    Sandboxes:          $Script:WorkRoot"

# ---------------------------------------------------------------------------

Start-TestCase 'The shipped constants are what they should be'

Assert-Equal -Description 'download URL is Docker''s documented Windows amd64 link' `
    -Expected 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' -Actual $Script:DeltaDockerInstallerUrl
Assert-Equal -Description 'installer file name' -Expected 'Docker Desktop Installer.exe' -Actual $Script:DeltaDockerInstallerName
Assert-Equal -Description 'size floor is 100 MB' -Expected (100MB) -Actual $Script:RealMinimumBytes
Assert-Equal -Description 'signer pattern is anchored, not a substring search' -Expected '^Docker\b' -Actual $Script:DeltaDockerInstallerSignerPattern

# ---------------------------------------------------------------------------

Start-TestCase 'Priority 1: an explicitly supplied path wins'

$sandbox = New-Sandbox 'supplied'
$supplied = Join-Path $sandbox 'my-docker-installer.exe'
New-TestFile -Path $supplied -Bytes 4KB
# A staged copy exists too, and must lose.
New-TestFile -Path (Join-Path $sandbox "installers\$Script:DeltaDockerInstallerName") -Bytes 4KB

Reset-Scenario
$r = Resolve-DeltaDockerInstaller -InstallerPath $supplied -SearchRoot $sandbox
Assert-Equal -Description 'source is supplied' -Expected 'supplied' -Actual $r.Source
Assert-Equal -Description 'path is the supplied file' -Expected $supplied -Actual $r.Path
Assert-Equal -Description 'nothing was downloaded' -Expected 0 -Actual $Script:DownloadCalls
Assert-That  -Description 'no error' -Condition ($null -eq $r.Error)

Start-TestCase 'A supplied path that does not exist fails without downloading'

Reset-Scenario
$r = Resolve-DeltaDockerInstaller -InstallerPath (Join-Path $sandbox 'absent.exe') -SearchRoot $sandbox
Assert-That  -Description 'no path resolved' -Condition ($null -eq $r.Path)
Assert-That  -Description 'the error names the missing path' -Condition ($r.Error -match 'absent\.exe')
Assert-Equal -Description 'it did NOT silently fall through to a download' -Expected 0 -Actual $Script:DownloadCalls

# ---------------------------------------------------------------------------

Start-TestCase 'Priority 2: a staged installers\ copy is used, and nothing is downloaded'

$sandbox = New-Sandbox 'staged'
$staged = Join-Path $sandbox "installers\$Script:DeltaDockerInstallerName"
New-TestFile -Path $staged -Bytes 4KB

Reset-Scenario
$r = Resolve-DeltaDockerInstaller -SearchRoot $sandbox
Assert-Equal -Description 'source is staged' -Expected 'staged' -Actual $r.Source
Assert-Equal -Description 'path is the staged file' -Expected $staged -Actual $r.Path
Assert-Equal -Description 'nothing was downloaded' -Expected 0 -Actual $Script:DownloadCalls

Start-TestCase 'A staged copy is trusted as-is, without signature verification'

# The operator put it there deliberately; an air-gapped site may repackage it.
Reset-Scenario -Signature 'unsigned'
$r = Resolve-DeltaDockerInstaller -SearchRoot $sandbox
Assert-Equal -Description 'still accepted' -Expected 'staged' -Actual $r.Source
Assert-That  -Description 'no verification was recorded for it' -Condition ($null -eq $r.Verification)

# ---------------------------------------------------------------------------

Start-TestCase 'Priority 3: a fresh machine downloads automatically (the regression)'

$sandbox = New-Sandbox 'fresh-machine'

Reset-Scenario
# -AllowDownload is deliberately NOT passed: the default must be to download.
$r = Resolve-DeltaDockerInstaller -SearchRoot $sandbox
Assert-Equal -Description 'source is downloaded' -Expected 'downloaded' -Actual $r.Source
Assert-Equal -Description 'the download was attempted exactly once' -Expected 1 -Actual $Script:DownloadCalls
Assert-Equal -Description 'it fetched Docker''s documented URL' -Expected $Script:DeltaDockerInstallerUrl -Actual $Script:LastDownloadUri
Assert-That  -Description 'no error' -Condition ($null -eq $r.Error)
Assert-That  -Description 'the file it returns exists' -Condition (Test-Path -LiteralPath $r.Path -PathType Leaf)
Assert-That  -Description 'it did NOT report the old "no installer was found"' -Condition ($null -eq $r.Error)

Start-TestCase 'With no SearchRoot at all, it still downloads rather than giving up'

Reset-Scenario
$r = Resolve-DeltaDockerInstaller
Assert-Equal -Description 'source is downloaded' -Expected 'downloaded' -Actual $r.Source
Assert-Equal -Description 'downloaded once' -Expected 1 -Actual $Script:DownloadCalls

Start-TestCase 'The download can still be forbidden explicitly'

Reset-Scenario
$r = Resolve-DeltaDockerInstaller -SearchRoot $sandbox -AllowDownload $false
Assert-That  -Description 'no path resolved' -Condition ($null -eq $r.Path)
Assert-Equal -Description 'nothing was downloaded' -Expected 0 -Actual $Script:DownloadCalls
Assert-That  -Description 'the error says downloading was not permitted' -Condition ($r.Error -match 'not permitted')
Assert-That  -Description 'the error still names installers\' -Condition ($r.Error -match 'installers')
Assert-That  -Description 'the error still names -DockerInstallerPath' -Condition ($r.Error -match '-DockerInstallerPath')

# ---------------------------------------------------------------------------

Start-TestCase 'A verified download is accepted'

Reset-Scenario -Download 'good' -Signature 'docker'
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'verify-good')
Assert-Equal -Description 'accepted' -Expected 'downloaded' -Actual $r.Source
Assert-That  -Description 'verification was recorded' -Condition ($null -ne $r.Verification)
Assert-That  -Description 'verification passed' -Condition $r.Verification.IsValid
Assert-Equal -Description 'signature status reported' -Expected 'Valid' -Actual $r.Verification.SignatureStatus
Assert-That  -Description 'the signer is reported' -Condition ($r.Verification.Signer -match 'Docker')
Assert-That  -Description 'the verified file is kept' -Condition (Test-Path -LiteralPath $r.Path -PathType Leaf)

Start-TestCase 'A truncated download or an error page is refused'

Reset-Scenario -Download 'tiny'
$destination = Join-Path $env:TEMP $Script:DeltaDockerInstallerName
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'verify-tiny')
Assert-That  -Description 'not accepted' -Condition ($null -eq $r.Path)
Assert-That  -Description 'the error says it was not verified' -Condition ($r.Error -match 'could not be verified')
Assert-That  -Description 'the error explains what a tiny file means' -Condition ($r.Error -match 'truncated transfer or an error page')
Assert-That  -Description 'the unverified file was deleted' -Condition (-not (Test-Path -LiteralPath $destination))

Start-TestCase 'HTML served with a 200 is refused (no MZ header)'

Reset-Scenario -Download 'html'
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'verify-html')
Assert-That  -Description 'not accepted' -Condition ($null -eq $r.Path)
Assert-That  -Description 'the error names the missing MZ header' -Condition ($r.Error -match 'not a Windows executable')
Assert-That  -Description 'the file was deleted' -Condition (-not (Test-Path -LiteralPath $destination))

Start-TestCase 'An unsigned binary is refused'

Reset-Scenario -Signature 'unsigned'
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'verify-unsigned')
Assert-That  -Description 'not accepted' -Condition ($null -eq $r.Path)
Assert-That  -Description 'the error names the signature status' -Condition ($r.Error -match 'NotSigned')
Assert-That  -Description 'the error says it was not run' -Condition ($r.Error -match 'not run')
Assert-That  -Description 'the file was deleted' -Condition (-not (Test-Path -LiteralPath $destination))

Start-TestCase 'A tampered binary is refused'

Reset-Scenario -Signature 'tampered'
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'verify-tampered')
Assert-That  -Description 'not accepted' -Condition ($null -eq $r.Path)
Assert-That  -Description 'the error names HashMismatch' -Condition ($r.Error -match 'HashMismatch')
Assert-That  -Description 'the file was deleted' -Condition (-not (Test-Path -LiteralPath $destination))

Start-TestCase 'A validly signed binary from somebody other than Docker is refused'

# The publisher check must test the organisation, anchored. Both of these
# subjects contain the word "Docker", so a substring search over the whole
# distinguished name would accept them - which it did, until this test.
foreach ($case in @(
    @{ Behaviour = 'stranger';  Label = 'Definitely Not Docker Ltd' }
    @{ Behaviour = 'lookalike'; Label = 'Not Docker Inc' }
)) {
    Reset-Scenario -Signature $case.Behaviour
    $r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox "verify-$($case.Behaviour)")
    Assert-That -Description "'$($case.Label)' is not accepted" -Condition ($null -eq $r.Path)
    Assert-That -Description "'$($case.Label)' is named in the error" -Condition ($r.Error -match [regex]::Escape($case.Label))
    Assert-That -Description "'$($case.Label)': a valid signature alone was not enough" -Condition ($r.Error -match 'rather than Docker')
    Assert-That -Description "'$($case.Label)': the file was deleted" -Condition (-not (Test-Path -LiteralPath $destination))
}

Start-TestCase 'A certificate with no readable publisher is refused'

Reset-Scenario -Signature 'nosubject'
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'verify-nosubject')
Assert-That -Description 'not accepted' -Condition ($null -eq $r.Path)
Assert-That -Description 'the error says no publisher could be read' -Condition ($r.Error -match 'no publisher could be read')

Start-TestCase 'A subject with only a CN falls back to it and is accepted'

Reset-Scenario -Signature 'cnonly'
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'verify-cnonly')
Assert-Equal -Description 'accepted' -Expected 'downloaded' -Actual $r.Source
Assert-Equal -Description 'the CN was used as the publisher' -Expected 'Docker Inc' -Actual $r.Verification.SignerOrganisation

Start-TestCase 'The subject parser reads the field, not the whole string'

Assert-Equal -Description 'reads O= from a full DN' -Expected 'Docker Inc' `
    -Actual (Get-DeltaCertificateSubjectPart -Subject 'CN=Docker Inc, O=Docker Inc, L=Palo Alto, S=California, C=US' -Key 'O')
Assert-Equal -Description 'reads CN= from a full DN' -Expected 'Docker Inc' `
    -Actual (Get-DeltaCertificateSubjectPart -Subject 'CN=Docker Inc, O=Docker Inc, C=US' -Key 'O')
Assert-Equal -Description 'handles a quoted value containing a comma' -Expected 'Docker Inc, Limited' `
    -Actual (Get-DeltaCertificateSubjectPart -Subject 'CN=x, O="Docker Inc, Limited", C=US' -Key 'O')
Assert-That  -Description 'returns nothing for an absent key' `
    -Condition ($null -eq (Get-DeltaCertificateSubjectPart -Subject 'CN=x, C=US' -Key 'O'))
Assert-That  -Description 'returns nothing for an empty subject' `
    -Condition ($null -eq (Get-DeltaCertificateSubjectPart -Subject '' -Key 'O'))
Assert-Equal -Description 'does not match O inside another key''s value' -Expected 'Docker Inc' `
    -Actual (Get-DeltaCertificateSubjectPart -Subject 'CN=NO=tricky, O=Docker Inc, C=US' -Key 'O')

Start-TestCase 'A signature that cannot be read is refused'

Reset-Scenario -Signature 'throw'
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'verify-sigthrow')
Assert-That  -Description 'not accepted' -Condition ($null -eq $r.Path)
Assert-That  -Description 'the error says the signature could not be read' -Condition ($r.Error -match 'could not be read')

Start-TestCase 'A download that reports success but writes nothing is refused'

Reset-Scenario -Download 'nothing'
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'verify-empty')
Assert-That  -Description 'not accepted' -Condition ($null -eq $r.Path)
Assert-That  -Description 'the error says nothing was written' -Condition ($r.Error -match 'Nothing was written')

# ---------------------------------------------------------------------------

Start-TestCase 'A failed transfer is reported and leaves nothing behind'

Reset-Scenario -Download 'throw'
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'download-fails')
Assert-That  -Description 'not accepted' -Condition ($null -eq $r.Path)
Assert-That  -Description 'the error says the download failed' -Condition ($r.Error -match 'Downloading Docker Desktop failed')
Assert-That  -Description 'the transport error is quoted' -Condition ($r.Error -match 'could not be resolved')
Assert-That  -Description 'no partial file is left behind' -Condition (-not (Test-Path -LiteralPath $destination))

Start-TestCase 'A leftover from an earlier attempt cannot masquerade as this one'

Reset-Scenario -Download 'throw'
New-TestFile -Path $destination -Bytes 4KB          # stale "good" file from a previous run
$r = Resolve-DeltaDockerInstaller -SearchRoot (New-Sandbox 'leftover')
Assert-That  -Description 'the stale file was not returned' -Condition ($null -eq $r.Path)
Assert-That  -Description 'the stale file was removed' -Condition (-not (Test-Path -LiteralPath $destination))

# ---------------------------------------------------------------------------

Start-TestCase 'The manual fallback instructions survive every failure'

$sandbox = New-Sandbox 'fallback'
$text = (& { Show-DeltaDockerInstallerFallback -SearchRoot $sandbox } 6>&1 | Out-String)
Assert-That -Description 'names the download URL'        -Condition ($text -match [regex]::Escape($Script:DeltaDockerInstallerUrl))
Assert-That -Description 'names the installers\ folder'  -Condition ($text -match 'installers')
Assert-That -Description 'gives the full staged path'    -Condition ($text -match [regex]::Escape($Script:DeltaDockerInstallerName))
Assert-That -Description 'names -DockerInstallerPath'    -Condition ($text -match '-DockerInstallerPath')
Assert-That -Description 'tells them to rerun setup.ps1' -Condition ($text -match 'setup\.ps1')

$text = (& { Show-DeltaDockerInstallerFallback } 6>&1 | Out-String)
Assert-That -Description 'works with no SearchRoot too'  -Condition ($text -match 'installers\\ folder next to setup\.ps1')

# ---------------------------------------------------------------------------

Start-TestCase 'setup.ps1 no longer gates the download behind a switch'

$setupText = [System.IO.File]::ReadAllText((Join-Path $Script:ProjectRoot 'setup.ps1'))
Assert-That -Description 'the runtime stage is passed -AllowDownload from -NoDockerDownload' `
    -Condition ($setupText -match '-AllowDownload \$allowDockerDownload')
Assert-That -Description '-AllowDockerDownload no longer gates it' `
    -Condition ($setupText -notmatch '-AllowDownload:\$AllowDockerDownload')
Assert-That -Description '-NoDockerDownload is a real parameter' `
    -Condition ($setupText -match '(?m)^\s*\[switch\]\$NoDockerDownload,')
Assert-That -Description '-AllowDockerDownload is still accepted for compatibility' `
    -Condition ($setupText -match '(?m)^\s*\[switch\]\$AllowDockerDownload,')
Assert-That -Description 'supplying both is resolved explicitly, not silently' `
    -Condition ($setupText -match 'both supplied')

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '==> Summary' -ForegroundColor Cyan
Write-Host "    Passed: $Script:Passed"
Write-Host "    Failed: $Script:Failed"

if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }

if ($KeepArtifacts) {
    Write-Host "    Sandboxes kept at $Script:WorkRoot"
}
else {
    Remove-Item -LiteralPath $Script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Script:Failed -gt 0) {
    Write-Host ''
    Write-Host 'Docker installer acquisition tests FAILED.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'All Docker installer acquisition tests passed.' -ForegroundColor Green
exit 0
