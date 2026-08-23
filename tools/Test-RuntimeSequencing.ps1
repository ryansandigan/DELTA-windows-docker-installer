#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for the order Invoke-DeltaRuntimeStage does things in, and
    for the Docker detection that order depends on.

.DESCRIPTION
    The failure these cover, in the sequence an operator reported it:

        run setup.ps1
        -> accept the Docker Desktop licence
        -> the installer then discovers WSL is missing and installs it
        -> Windows must restart
        -> run setup.ps1 again
        -> be asked to accept the Docker Desktop licence again

    Two separate faults produced that. The disclosure was shown before the
    backend prerequisite was satisfied, so the acceptance was spent on an
    installation that a restart came between; and "is Docker installed" was
    answered by `Get-Command docker`, which says nothing when the application
    is installed and this process's PATH predates it.

    So the invariants pinned here are:

      - a prerequisite that needs a restart stops the run BEFORE any Docker
        prompt, download or installation;
      - the licensing prompt appears exactly once, only when an installation is
        genuinely about to be attempted in that same run;
      - Docker Desktop installed, docker CLI visible, and Docker engine ready
        are three separate facts, and only the first being false may lead to an
        installation;
      - a stale PATH, a stopped engine and an engine that is still starting are
        none of them "Docker is missing".

    Every host probe is replaced by a scripted stand-in - the same shadowing
    technique Test-DockerInstallerAcquisition.ps1 uses - so all six scenarios
    run offline, on any machine, whatever it has installed. The orchestration
    under test is the real Invoke-DeltaRuntimeStage, and the detection under
    test is the real Get-DeltaDockerPresence composing the stand-ins.

    Nothing here installs anything, enables a Windows feature, touches Docker,
    or restarts anything.

    Exits 0 if every test passes, 1 otherwise.

.EXAMPLE
    .\tools\Test-RuntimeSequencing.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$Script:WorkRoot    = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("delta-seq-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Script:TestRegRoot = 'HKCU:\Software\DELTA-sequencing-tests'

$Script:Passed = 0
$Script:Failed = 0

. (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')

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
# The simulated machine
#
# One hashtable describes the host under test. The stand-ins below read it, and
# the ones that change a real machine change it here instead - so "Docker was
# installed, and now the CLI exists on disk but not on this process's PATH" is
# a state the test can actually reach rather than assert about.
# ---------------------------------------------------------------------------

function Reset-Machine {
    param([hashtable]$Overrides = @{})

    $Script:Machine = @{
        IsServerSku          = $false
        Caption              = 'Microsoft Windows 11 Pro'

        # 'ok' | 'remediable' | 'blocked'
        Virtualization       = 'ok'
        RepairSucceeds       = $true
        RepairNeedsRestart   = $true

        PendingReboot        = $false

        # 'ready' | 'absent' | 'outdated'
        Wsl                  = 'ready'
        WslInstallSucceeds   = $true

        DesktopRegistered    = $false
        DesktopVersion       = $null
        CliOnDisk            = $false
        CliOnPath            = $false

        # 'ready' | 'engine-down' | 'wrong-mode' | 'error'
        Engine               = 'ready'
        EngineAfterStart     = 'ready'

        ComposeVersion       = '2.29.0'

        InstallerAvailable   = $true
        InstallSucceeds      = $true
        InstallExitCode      = 0
        InstallNeedsReboot   = $false

        AcceptServerSku      = $true
        AcceptLicence        = $true

        PriorPrerequisiteFact = $null
    }

    foreach ($key in $Overrides.Keys) { $Script:Machine[$key] = $Overrides[$key] }

    $Script:Calls = @{
        ServerSkuAsked      = 0
        ServerSkuDisclosed  = 0
        LicensingAsked      = 0
        WslInstalled        = 0
        VirtualizationFixed = 0
        InstallerResolved   = 0
        DockerInstalled     = 0
        EngineStarted       = 0
        PathRepaired        = 0
    }
    $Script:SavedFacts = New-Object System.Collections.ArrayList
}

# ---------------------------------------------------------------------------
# Scripted stand-ins for every host probe the stage makes
#
# Defined AFTER the library is dot-sourced, so they shadow it. Get-DeltaDockerPresence
# is deliberately NOT shadowed: composing these three leaves correctly is the
# thing under test.
# ---------------------------------------------------------------------------

function Get-DeltaWindowsInfo {
    return [PSCustomObject]@{
        Caption     = $Script:Machine.Caption
        IsServerSku = $Script:Machine.IsServerSku
        SystemDrive = 'C:'
    }
}

function Test-DeltaWindowsPrerequisite {
    param([object]$WindowsInfo)
    return (New-DeltaCheckResult -Name 'Windows edition and build' -Severity 'ok' -Detail 'simulated')
}

function Test-DeltaDiskSpacePrerequisite {
    param([string]$InstallRoot, [object]$WindowsInfo)
    return (New-DeltaCheckResult -Name 'Disk space' -Severity 'ok' -Detail 'simulated')
}

function Test-DeltaVirtualizationPrerequisite {
    param([object]$WindowsInfo, [object]$Capability)

    $check = switch ($Script:Machine.Virtualization) {
        'ok'         { New-DeltaCheckResult -Name 'Hardware virtualization' -Severity 'ok' -Detail 'simulated' }
        'remediable' { New-DeltaCheckResult -Name 'Hardware virtualization' -Severity 'notice' -Detail 'simulated' -Reason 'VirtualMachinePlatform is off.' }
        default      { New-DeltaCheckResult -Name 'Hardware virtualization' -Severity 'blocked' -Detail 'simulated' -Reason 'No virtualization.' -Remedy 'Enable it in firmware.' }
    }

    $verdict = switch ($Script:Machine.Virtualization) {
        'ok'         { 'available' }
        'remediable' { 'remediable' }
        default      { 'unavailable' }
    }

    Add-Member -InputObject $check -MemberType NoteProperty -Name 'Capability' -Value ([PSCustomObject]@{
        Verdict       = $verdict
        Reason        = 'simulated'
        RepairActions = @('virtual-machine-platform')
    })
    return $check
}

function Repair-DeltaVirtualizationPrerequisite {
    param([object]$Capability)
    $Script:Calls.VirtualizationFixed++
    # A real repair leaves the feature enabled, so a re-measure after the
    # restart reports 'ok'. Modelling that is what keeps the reboot-loop test
    # honest.
    if ($Script:Machine.RepairSucceeds) { $Script:Machine.Virtualization = 'ok' }
    return [PSCustomObject]@{
        Attempted       = @('VirtualMachinePlatform')
        Succeeded       = $Script:Machine.RepairSucceeds
        RestartRequired = ($Script:Machine.RepairSucceeds -and $Script:Machine.RepairNeedsRestart)
        Failures        = @()
    }
}

function Test-DeltaPendingReboot {
    return [PSCustomObject]@{
        IsPending = $Script:Machine.PendingReboot
        Signals   = @(if ($Script:Machine.PendingReboot) { 'Session Manager: PendingFileRenameOperations' })
    }
}

function Get-DeltaWslState {
    return [PSCustomObject]@{
        Status         = $Script:Machine.Wsl
        Version        = $(if ($Script:Machine.Wsl -eq 'ready') { '2.7.11' } else { $null })
        KernelVersion  = $null
        DefaultVersion = $(if ($Script:Machine.Wsl -eq 'ready') { '2' } else { $null })
        Detail         = 'simulated'
    }
}

function Install-DeltaWsl {
    $Script:Calls.WslInstalled++
    if ($Script:Machine.WslInstallSucceeds) {
        # The platform is installed but not in effect until the restart. The
        # next run's Get-DeltaWslState reports it ready, which is what the
        # resume scenario models by starting from Wsl = 'ready'.
        return [PSCustomObject]@{ Succeeded = $true; ExitCode = 0; Detail = 'simulated' }
    }
    return [PSCustomObject]@{ Succeeded = $false; ExitCode = 1; Detail = 'simulated failure' }
}

function Get-DeltaDockerDesktopInstallState {
    param([string[]]$UninstallKeyPath, [string[]]$ProgramRoot)

    $installed = [bool]($Script:Machine.DesktopRegistered -or $Script:Machine.CliOnDisk)
    return [PSCustomObject]@{
        Installed       = $installed
        Version         = $Script:Machine.DesktopVersion
        InstallLocation = $(if ($installed) { 'C:\Program Files\Docker\Docker' } else { $null })
        DesktopExe      = $(if ($Script:Machine.DesktopRegistered) { 'C:\Program Files\Docker\Docker\Docker Desktop.exe' } else { $null })
        CliPath         = $(if ($Script:Machine.CliOnDisk) { 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' } else { $null })
        BinDirectory    = $(if ($Script:Machine.CliOnDisk) { 'C:\Program Files\Docker\Docker\resources\bin' } else { $null })
        Sources         = @(if ($Script:Machine.DesktopRegistered) { 'registry' }; if ($Script:Machine.CliOnDisk) { 'filesystem' })
        Evidence        = 'simulated'
    }
}

function Initialize-DeltaDockerPath {
    param([string[]]$SearchPath)

    if ($Script:Machine.CliOnPath) {
        return [PSCustomObject]@{ Resolved = $true; Repaired = $false; Path = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' }
    }
    if ($Script:Machine.CliOnDisk) {
        $Script:Calls.PathRepaired++
        $Script:Machine.CliOnPath = $true
        return [PSCustomObject]@{ Resolved = $true; Repaired = $true; Path = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' }
    }
    return [PSCustomObject]@{ Resolved = $false; Repaired = $false; Path = $null }
}

function New-EngineState {
    param([string]$Status)

    if ($Status -eq 'cli-absent') {
        return [PSCustomObject]@{
            Status = 'cli-absent'; OSType = $null; ServerVersion = $null; KernelVersion = $null
            OperatingSystem = $null; Backend = $null; ClientVersion = $null; Path = $null
            Detail = 'The docker CLI was not found on PATH.'; RawError = $null
        }
    }
    return [PSCustomObject]@{
        Status          = $Status
        OSType          = $(if ($Status -eq 'wrong-mode') { 'windows' } elseif ($Status -eq 'ready') { 'linux' } else { $null })
        ServerVersion   = $(if ($Status -in @('ready', 'wrong-mode')) { '27.4.0' } else { $null })
        KernelVersion   = '6.6.0-microsoft-standard-WSL2'
        OperatingSystem = 'Docker Desktop'
        Backend         = 'wsl-2'
        ClientVersion   = '27.4.0'
        Path            = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
        Detail          = 'simulated'
        RawError        = $(if ($Status -eq 'engine-down') { 'error during connect: open //./pipe/docker_engine' } else { $null })
    }
}

function Get-DeltaDockerEngineState {
    if (-not $Script:Machine.CliOnPath) { return (New-EngineState -Status 'cli-absent') }
    return (New-EngineState -Status $Script:Machine.Engine)
}

function Start-DeltaDockerEngine {
    param([int]$TimeoutSeconds)
    $Script:Calls.EngineStarted++
    $Script:Machine.Engine = $Script:Machine.EngineAfterStart
    return (New-EngineState -Status $Script:Machine.Engine)
}

function Set-DeltaDockerLinuxEngine {
    $Script:Machine.Engine = 'ready'
    return (New-EngineState -Status 'ready')
}

function Get-DeltaComposeState {
    $version = $Script:Machine.ComposeVersion
    return [PSCustomObject]@{
        Available   = [bool]$version
        Version     = $version
        Major       = $(if ($version) { [int]($version -split '\.')[0] } else { 0 })
        IsSupported = [bool]($version -and [int]($version -split '\.')[0] -ge 2)
        Detail      = 'simulated'
    }
}

function Show-DeltaServerSkuCaveat {
    param([object]$WindowsInfo, [switch]$RequireConfirmation)

    if (-not $WindowsInfo.IsServerSku) { return $true }
    if ($RequireConfirmation) {
        $Script:Calls.ServerSkuAsked++
        return $Script:Machine.AcceptServerSku
    }
    $Script:Calls.ServerSkuDisclosed++
    return $true
}

function Confirm-DeltaDockerLicensing {
    $Script:Calls.LicensingAsked++
    return $Script:Machine.AcceptLicence
}

function Resolve-DeltaDockerInstaller {
    param([string]$InstallerPath, [string]$SearchRoot, [bool]$AllowDownload)

    $Script:Calls.InstallerResolved++
    if ($Script:Machine.InstallerAvailable) {
        return [PSCustomObject]@{ Path = 'C:\staged\Docker Desktop Installer.exe'; Source = 'staged'; Error = $null }
    }
    return [PSCustomObject]@{ Path = $null; Source = $null; Error = 'No Docker Desktop installer was found.' }
}

function Show-DeltaDockerInstallerFallback { param([string]$SearchRoot) }

function Get-DeltaDockerInstallLogPaths { return @() }

function Install-DeltaDockerDesktop {
    param([string]$InstallerPath, [switch]$AcceptLicense)

    $Script:Calls.DockerInstalled++

    if (-not $Script:Machine.InstallSucceeds) {
        return [PSCustomObject]@{
            Succeeded = $false; ExitCode = $Script:Machine.InstallExitCode; RebootRequired = $false
            LogPaths = @(); Detail = 'simulated failure'
        }
    }

    # What a real successful install leaves behind: files on disk, a
    # registration, an engine that is not up yet, and a PATH in THIS process
    # that still predates all of it.
    $Script:Machine.DesktopRegistered = $true
    $Script:Machine.DesktopVersion    = '4.37.1'
    $Script:Machine.CliOnDisk         = $true
    $Script:Machine.CliOnPath         = $false
    $Script:Machine.Engine            = 'engine-down'
    $Script:Machine.PendingReboot     = $Script:Machine.InstallNeedsReboot

    return [PSCustomObject]@{
        Succeeded = $true; ExitCode = 0
        RebootRequired = $Script:Machine.InstallNeedsReboot
        LogPaths = @(); Detail = 'simulated'
    }
}

function Save-DeltaRuntimeFacts {
    param([string]$InstallRoot, [System.Collections.IDictionary]$Facts)
    $null = $Script:SavedFacts.Add($Facts)
    return [PSCustomObject]@{ Persisted = $true; Path = "$InstallRoot\.delta-install.json"; Reason = $null }
}

function Get-DeltaRuntimeFact {
    param([string]$InstallRoot, [string]$Name)
    if ($Name -eq 'prerequisites') { return $Script:Machine.PriorPrerequisiteFact }
    return $null
}

# ---------------------------------------------------------------------------

function Invoke-Stage {
    <#
      Runs the real stage against the simulated machine, with the installer's
      own console output suppressed. Write-Host writes to the information
      stream in PowerShell 5.1, so 6>$null silences the transcript without
      touching what the stage returns.
    #>
    return (Invoke-DeltaRuntimeStage -InstallRoot 'C:\DELTA' -ScriptRoot $Script:ProjectRoot -AllowDownload $true 6>$null)
}

function Test-FactSaved {
    param([string]$Key)
    foreach ($fact in $Script:SavedFacts) {
        if ($fact.Contains($Key)) { return $true }
    }
    return $false
}

Write-Host ''
Write-Host '==> DELTA installer sequencing and Docker detection tests' -ForegroundColor Cyan
Write-Host "    Library under test: $(Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')"

# ===========================================================================
# Scenario A - clean system, a prerequisite needs a restart
# ===========================================================================

Start-TestCase 'Scenario A1: a Windows feature must be enabled - restart requested, nothing about Docker touched'

Reset-Machine @{ Virtualization = 'remediable'; Wsl = 'absent'; DesktopRegistered = $false; CliOnDisk = $false }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is reboot-required' -Expected 'reboot-required' -Actual $runtime.Outcome
Assert-Equal -Description 'it stopped in the prerequisite stage' -Expected 'prerequisites' -Actual $runtime.Stage
Assert-Equal -Description 'the Windows feature was enabled once' -Expected 1 -Actual $Script:Calls.VirtualizationFixed
Assert-Equal -Description 'NO licensing prompt was shown' -Expected 0 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'NO Docker installer was acquired' -Expected 0 -Actual $Script:Calls.InstallerResolved
Assert-Equal -Description 'NO Docker installation was started' -Expected 0 -Actual $Script:Calls.DockerInstalled
Assert-That  -Description 'the reason names the restart' -Condition ($runtime.Reason -match 'restart')
Assert-That  -Description 'the prerequisite work is recorded for the resumed run' -Condition (Test-FactSaved -Key 'prerequisites')

Start-TestCase 'Scenario A2: the WSL platform is missing - installed BEFORE the licence is ever mentioned'

Reset-Machine @{ Virtualization = 'ok'; Wsl = 'absent'; DesktopRegistered = $false; CliOnDisk = $false }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is reboot-required' -Expected 'reboot-required' -Actual $runtime.Outcome
Assert-Equal -Description 'it stopped in the backend-prerequisite stage' -Expected 'docker-backend-prerequisites' -Actual $runtime.Stage
Assert-Equal -Description 'the WSL platform was installed once' -Expected 1 -Actual $Script:Calls.WslInstalled
Assert-That  -Description 'it reports that WSL was installed' -Condition $runtime.WslInstalled
Assert-Equal -Description 'NO licensing prompt was shown' -Expected 0 -Actual $Script:Calls.LicensingAsked
Assert-That  -Description 'the licensing prompt is recorded as not asked' -Condition (-not $runtime.Prompted['licensing'])
Assert-Equal -Description 'NO Docker installer was acquired' -Expected 0 -Actual $Script:Calls.InstallerResolved
Assert-Equal -Description 'NO Docker installation was started' -Expected 0 -Actual $Script:Calls.DockerInstalled
Assert-That  -Description 'no Docker installation was even attempted' -Condition (-not $runtime.DockerInstallAttempted)
Assert-That  -Description 'the reason says nothing about Docker has been accepted or installed' -Condition (
    $runtime.Reason -match 'nothing about Docker has been downloaded, accepted or installed yet')
Assert-Equal -Description 'the backend planned for the new install is wsl-2' -Expected 'wsl-2' -Actual $runtime.Backend.Backend
Assert-That  -Description 'no Linux distribution is required' -Condition (-not $runtime.Backend.RequiresLinuxDistribution)

Start-TestCase 'Scenario A3: a Server SKU is not asked to accept anything before the prerequisite restart either'

Reset-Machine @{ IsServerSku = $true; Wsl = 'absent'; DesktopRegistered = $false; CliOnDisk = $false }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is reboot-required' -Expected 'reboot-required' -Actual $runtime.Outcome
Assert-Equal -Description 'the server-edition notice was NOT put to the operator' -Expected 0 -Actual $Script:Calls.ServerSkuAsked
Assert-Equal -Description 'the licensing prompt was NOT shown' -Expected 0 -Actual $Script:Calls.LicensingAsked

# ===========================================================================
# Scenario B - resumed after the prerequisite restart
# ===========================================================================

Start-TestCase 'Scenario B: prerequisites satisfied, Docker absent - asked once, installed once'

Reset-Machine @{
    Virtualization        = 'ok'
    Wsl                   = 'ready'
    DesktopRegistered     = $false
    CliOnDisk             = $false
    EngineAfterStart      = 'ready'
    PriorPrerequisiteFact = [PSCustomObject]@{ restartRequestedAt = '2026-08-20T09:00:00.0000000Z'; actions = @('wsl-platform') }
}
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is ready' -Expected 'ready' -Actual $runtime.Outcome
Assert-Equal -Description 'the WSL platform was NOT installed again' -Expected 0 -Actual $Script:Calls.WslInstalled
Assert-Equal -Description 'the Windows feature was NOT enabled again' -Expected 0 -Actual $Script:Calls.VirtualizationFixed
Assert-Equal -Description 'the licensing prompt appeared exactly once' -Expected 1 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'Docker Desktop was installed exactly once' -Expected 1 -Actual $Script:Calls.DockerInstalled
Assert-That  -Description 'the licence acceptance was recorded' -Condition ($runtime.Caveats['licensing'])
Assert-Equal -Description 'the engine was brought up after the install' -Expected 1 -Actual $Script:Calls.EngineStarted
Assert-That  -Description 'the freshly installed CLI was found off PATH, not declared missing' -Condition ($Script:Calls.PathRepaired -ge 1)
Assert-That  -Description 'the completed prerequisite work was acknowledged, not repeated' -Condition (Test-FactSaved -Key 'prerequisites')
Assert-That  -Description 'the installation was recorded' -Condition (Test-FactSaved -Key 'dockerInstall')

Start-TestCase 'Scenario B2: the same run, where Docker''s own installer demands a restart'

Reset-Machine @{ Wsl = 'ready'; DesktopRegistered = $false; CliOnDisk = $false; InstallNeedsReboot = $true }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is reboot-required' -Expected 'reboot-required' -Actual $runtime.Outcome
Assert-Equal -Description 'Docker Desktop was installed once' -Expected 1 -Actual $Script:Calls.DockerInstalled
Assert-Equal -Description 'the licensing prompt appeared once' -Expected 1 -Actual $Script:Calls.LicensingAsked
Assert-That  -Description 'the reason promises no repeat install or prompt' -Condition (
    $runtime.Reason -match 'the licence has been accepted and the installation is not repeated')
Assert-That  -Description 'the post-install detection found Docker Desktop' -Condition $runtime.Presence.Installed

Start-TestCase 'Scenario B3: declining the licence installs nothing and is reported as declined'

Reset-Machine @{ Wsl = 'ready'; DesktopRegistered = $false; CliOnDisk = $false; AcceptLicence = $false }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is declined' -Expected 'declined' -Actual $runtime.Outcome
Assert-Equal -Description 'the licensing prompt appeared once' -Expected 1 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'nothing was acquired' -Expected 0 -Actual $Script:Calls.InstallerResolved
Assert-Equal -Description 'nothing was installed' -Expected 0 -Actual $Script:Calls.DockerInstalled

# ===========================================================================
# Scenario C - Docker Desktop already installed
# ===========================================================================

Start-TestCase 'Scenario C: prerequisites satisfied, Docker Desktop installed and ready - no prompt at all'

Reset-Machine @{ Wsl = 'ready'; DesktopRegistered = $true; CliOnDisk = $true; CliOnPath = $true; Engine = 'ready' }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is ready' -Expected 'ready' -Actual $runtime.Outcome
Assert-Equal -Description 'NO licensing prompt' -Expected 0 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'NO Docker installation' -Expected 0 -Actual $Script:Calls.DockerInstalled
Assert-Equal -Description 'NO installer acquisition' -Expected 0 -Actual $Script:Calls.InstallerResolved
Assert-Equal -Description 'NO WSL installation' -Expected 0 -Actual $Script:Calls.WslInstalled
Assert-Equal -Description 'the presence verdict is ready' -Expected 'ready' -Actual $runtime.Presence.Condition
Assert-Equal -Description 'the backend is left as it is' -Expected 'existing' -Actual $runtime.Backend.Backend
Assert-That  -Description 'an existing installation needs no WSL platform work' -Condition (-not $runtime.Backend.RequiresWslPlatform)

Start-TestCase 'Scenario C2: an existing Hyper-V-backend Docker is not pushed onto WSL'

# WSL is genuinely absent AND Docker Desktop is installed and working. The
# installer must leave both alone: adding WSL to a host whose Docker does not
# use it is a change nobody asked for.
Reset-Machine @{ Wsl = 'absent'; DesktopRegistered = $true; CliOnDisk = $true; CliOnPath = $true; Engine = 'ready' }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is ready' -Expected 'ready' -Actual $runtime.Outcome
Assert-Equal -Description 'WSL was NOT installed' -Expected 0 -Actual $Script:Calls.WslInstalled
Assert-Equal -Description 'no licensing prompt' -Expected 0 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'no reboot was requested' -Expected 'ready' -Actual $runtime.Outcome

Start-TestCase 'Scenario C3: a Server SKU with Docker already installed is told, not asked'

Reset-Machine @{ IsServerSku = $true; DesktopRegistered = $true; CliOnDisk = $true; CliOnPath = $true; Engine = 'ready' }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is ready' -Expected 'ready' -Actual $runtime.Outcome
Assert-Equal -Description 'the notice was disclosed' -Expected 1 -Actual $Script:Calls.ServerSkuDisclosed
Assert-Equal -Description 'and NOT put as a question' -Expected 0 -Actual $Script:Calls.ServerSkuAsked
Assert-Equal -Description 'no licensing prompt' -Expected 0 -Actual $Script:Calls.LicensingAsked

# ===========================================================================
# Scenario D - installed, but the CLI is not on this process's PATH
# ===========================================================================

Start-TestCase 'Scenario D: Docker Desktop installed, docker not on PATH - resolved, never reinstalled'

Reset-Machine @{ DesktopRegistered = $true; CliOnDisk = $true; CliOnPath = $false; Engine = 'ready' }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is ready' -Expected 'ready' -Actual $runtime.Outcome
Assert-Equal -Description 'NO licensing prompt' -Expected 0 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'NO Docker installation' -Expected 0 -Actual $Script:Calls.DockerInstalled
Assert-Equal -Description 'the PATH was repaired for this process' -Expected 1 -Actual $Script:Calls.PathRepaired
Assert-That  -Description 'the repair is reported' -Condition $runtime.Presence.PathRepaired
Assert-That  -Description 'the CLI is reported present after the repair' -Condition $runtime.Presence.CliPresent

Start-TestCase 'Scenario D2: registered but docker.exe genuinely missing is reported, not reinstalled over'

Reset-Machine @{ DesktopRegistered = $true; CliOnDisk = $false; CliOnPath = $false }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is blocked' -Expected 'blocked' -Actual $runtime.Outcome
Assert-Equal -Description 'the presence verdict is broken' -Expected 'broken' -Actual $runtime.Presence.Condition
Assert-Equal -Description 'NO licensing prompt' -Expected 0 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'NO Docker installation' -Expected 0 -Actual $Script:Calls.DockerInstalled
Assert-That  -Description 'it says the CLI could not be located' -Condition ($runtime.Reason -match 'could not be located')

# ===========================================================================
# Scenario E - installed, engine still starting
# ===========================================================================

Start-TestCase 'Scenario E: Docker installed, engine down - started and waited for, never reinstalled'

Reset-Machine @{ DesktopRegistered = $true; CliOnDisk = $true; CliOnPath = $true; Engine = 'engine-down'; EngineAfterStart = 'ready' }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is ready' -Expected 'ready' -Actual $runtime.Outcome
Assert-Equal -Description 'the engine was started' -Expected 1 -Actual $Script:Calls.EngineStarted
Assert-Equal -Description 'NO licensing prompt' -Expected 0 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'NO Docker installation' -Expected 0 -Actual $Script:Calls.DockerInstalled

Start-TestCase 'Scenario E2: an engine that never comes up is a failed engine, not a missing Docker'

Reset-Machine @{ DesktopRegistered = $true; CliOnDisk = $true; CliOnPath = $true; Engine = 'engine-down'; EngineAfterStart = 'engine-down' }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is blocked' -Expected 'blocked' -Actual $runtime.Outcome
Assert-That  -Description 'the reason is about the engine' -Condition ($runtime.Reason -match 'engine is not usable')
Assert-Equal -Description 'NO licensing prompt' -Expected 0 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'NO Docker installation' -Expected 0 -Actual $Script:Calls.DockerInstalled

Start-TestCase 'Scenario E3: Windows-container mode is switched, not reinstalled'

Reset-Machine @{ DesktopRegistered = $true; CliOnDisk = $true; CliOnPath = $true; Engine = 'wrong-mode' }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is ready' -Expected 'ready' -Actual $runtime.Outcome
Assert-Equal -Description 'NO Docker installation' -Expected 0 -Actual $Script:Calls.DockerInstalled
Assert-Equal -Description 'NO licensing prompt' -Expected 0 -Actual $Script:Calls.LicensingAsked

# ===========================================================================
# Scenario F - rerunning a completed installation
# ===========================================================================

Start-TestCase 'Scenario F: rerunning against a fully working host changes nothing'

Reset-Machine @{ Wsl = 'ready'; DesktopRegistered = $true; CliOnDisk = $true; CliOnPath = $true; Engine = 'ready' }
$first = Invoke-Stage
$firstCalls = $Script:Calls.Clone()
$second = Invoke-Stage

Assert-Equal -Description 'the first run is ready' -Expected 'ready' -Actual $first.Outcome
Assert-Equal -Description 'the second run is ready too' -Expected 'ready' -Actual $second.Outcome
Assert-Equal -Description 'no prerequisite was re-enabled' -Expected 0 -Actual $Script:Calls.VirtualizationFixed
Assert-Equal -Description 'no WSL install across either run' -Expected 0 -Actual $Script:Calls.WslInstalled
Assert-Equal -Description 'no Docker install across either run' -Expected 0 -Actual $Script:Calls.DockerInstalled
Assert-Equal -Description 'no licensing prompt across either run' -Expected 0 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'the second run added no engine starts' -Expected $firstCalls.EngineStarted -Actual $Script:Calls.EngineStarted

Start-TestCase 'Scenario F2: setup.ps1 sends a registered installation to management before the runtime stage'

# The call sites, not the library manifest at the top of the file - both
# function names appear there too, in the other order.
$setupText   = [System.IO.File]::ReadAllText((Join-Path $Script:ProjectRoot 'setup.ps1'))
$manageCall  = $setupText.IndexOf('$exitCode = Invoke-DeltaManagementMode')
$runtimeCall = $setupText.IndexOf('$runtime = Invoke-DeltaRuntimeStage')
Assert-That -Description 'management mode is dispatched' -Condition ($manageCall -gt 0)
Assert-That -Description 'it is decided before the runtime stage runs' -Condition ($manageCall -lt $runtimeCall)
Assert-That -Description 'the dispatch is driven by the detected state' -Condition (
    $setupText -match "if \(\`$state\.State -eq 'installed' -and -not \`$Reconfigure\)")

# ===========================================================================
# A blocked prerequisite still stops before anything Docker
# ===========================================================================

Start-TestCase 'A host that cannot virtualize is stopped before Docker is detected or acquired'

Reset-Machine @{ Virtualization = 'blocked'; DesktopRegistered = $false; CliOnDisk = $false }
$runtime = Invoke-Stage

Assert-Equal -Description 'the outcome is blocked' -Expected 'blocked' -Actual $runtime.Outcome
Assert-Equal -Description 'no licensing prompt' -Expected 0 -Actual $Script:Calls.LicensingAsked
Assert-Equal -Description 'nothing was acquired' -Expected 0 -Actual $Script:Calls.InstallerResolved
Assert-Equal -Description 'nothing was installed' -Expected 0 -Actual $Script:Calls.DockerInstalled

Start-TestCase 'A repair that cannot be applied does not loop and does not install Docker over it'

Reset-Machine @{ Virtualization = 'remediable'; RepairSucceeds = $false; Wsl = 'ready'; DesktopRegistered = $false; CliOnDisk = $false }
$runtime = Invoke-Stage

Assert-Equal -Description 'the feature enable was attempted exactly once' -Expected 1 -Actual $Script:Calls.VirtualizationFixed
Assert-That  -Description 'no restart was requested for a repair that did not happen' -Condition ($runtime.Outcome -ne 'reboot-required')

# ===========================================================================
# Docker Desktop install-state detection, against real fixtures
# ===========================================================================

Start-TestCase 'Get-DeltaDockerDesktopInstallState reads the Windows registration'

# From here on the real detection functions are under test, so the library is
# re-loaded to undo every stand-in above. No scenario runs after this point.
. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')

# The one exception. The fixture's docker.exe is a text file, and running it to
# ask for a version would prove nothing and take a while; what the presence
# probe has to get right here is whether it resolves at all.
function Get-DeltaDockerEngineState {
    if (Get-Command -Name 'docker' -CommandType Application -ErrorAction SilentlyContinue) {
        return (New-EngineState -Status 'engine-down')
    }
    return (New-EngineState -Status 'cli-absent')
}

$emptyRoot = Join-Path $Script:WorkRoot 'empty'
$fakeRoot  = Join-Path $Script:WorkRoot 'Docker\Docker'
$fakeBin   = Join-Path $fakeRoot 'resources\bin'
$null = New-Item -ItemType Directory -Path $emptyRoot -Force
$null = New-Item -ItemType Directory -Path $fakeBin -Force

try {
    $uninstall = "$Script:TestRegRoot\Uninstall"
    $null = New-Item -Path "$uninstall\Docker Desktop" -Force
    $null = New-ItemProperty -Path "$uninstall\Docker Desktop" -Name 'DisplayName' -Value 'Docker Desktop' -PropertyType String -Force
    $null = New-ItemProperty -Path "$uninstall\Docker Desktop" -Name 'DisplayVersion' -Value '4.37.1' -PropertyType String -Force
    $null = New-ItemProperty -Path "$uninstall\Docker Desktop" -Name 'InstallLocation' -Value $fakeRoot -PropertyType String -Force

    $state = Get-DeltaDockerDesktopInstallState -UninstallKeyPath @($uninstall) -ProgramRoot @($emptyRoot)
    Assert-That  -Description 'the registration alone proves it is installed' -Condition $state.Installed
    Assert-Equal -Description 'the version is read' -Expected '4.37.1' -Actual $state.Version
    Assert-Equal -Description 'the install location is read' -Expected $fakeRoot -Actual $state.InstallLocation
    Assert-That  -Description 'registry is named as a source' -Condition ($state.Sources -contains 'registry')
    Assert-That  -Description 'the evidence quotes the registration' -Condition ($state.Evidence -match 'registry:')

    # docker.exe under the location the registration named is found from it,
    # which is what lets Initialize-DeltaDockerPath repair a stale PATH.
    Set-Content -LiteralPath (Join-Path $fakeBin 'docker.exe') -Value 'MZ' -Encoding ascii
    $state = Get-DeltaDockerDesktopInstallState -UninstallKeyPath @($uninstall) -ProgramRoot @($emptyRoot)
    Assert-Equal -Description 'the bin directory is located from the registration' -Expected $fakeBin -Actual $state.BinDirectory
    Assert-Equal -Description 'docker.exe is located' -Expected (Join-Path $fakeBin 'docker.exe') -Actual $state.CliPath

    Start-TestCase 'A near-miss DisplayName is not Docker Desktop'

    $null = New-Item -Path "$uninstall\Other" -Force
    $null = New-ItemProperty -Path "$uninstall\Other" -Name 'DisplayName' -Value 'Docker Desktop Feedback Tool' -PropertyType String -Force
    Remove-Item -LiteralPath "$uninstall\Docker Desktop" -Recurse -Force
    $state = Get-DeltaDockerDesktopInstallState -UninstallKeyPath @($uninstall) -ProgramRoot @($emptyRoot)
    Assert-That -Description '"Docker Desktop Feedback Tool" is not read as Docker Desktop' -Condition (-not $state.Installed)

    Start-TestCase 'A damaged registration is still an installation if the files are there'

    $state = Get-DeltaDockerDesktopInstallState -UninstallKeyPath @("$Script:TestRegRoot\NoSuchKey") -ProgramRoot @($fakeRoot)
    Assert-That  -Description 'the filesystem alone proves it is installed' -Condition $state.Installed
    Assert-That  -Description 'filesystem is named as a source' -Condition ($state.Sources -contains 'filesystem')
    Assert-Equal -Description 'the bin directory is found' -Expected $fakeBin -Actual $state.BinDirectory

    Start-TestCase 'A host with neither is reported absent, with no false positive'

    $state = Get-DeltaDockerDesktopInstallState -UninstallKeyPath @("$Script:TestRegRoot\NoSuchKey") -ProgramRoot @($emptyRoot)
    Assert-That  -Description 'not installed' -Condition (-not $state.Installed)
    Assert-Equal -Description 'no version' -Expected $null -Actual $state.Version
    Assert-Equal -Description 'no bin directory' -Expected $null -Actual $state.BinDirectory
    Assert-That  -Description 'the evidence says so plainly' -Condition ($state.Evidence -match 'No Docker Desktop registration')

    Start-TestCase 'Initialize-DeltaDockerPath prefers a caller-supplied location'

    # Only meaningful when `docker` does not already resolve, so PATH is
    # emptied for the duration - which is also exactly the condition being
    # tested: an installed Docker that this process cannot see.
    $previousPath = $env:PATH
    try {
        $env:PATH = $emptyRoot
        Assert-That -Description 'the precondition holds: docker does not resolve' -Condition (
            -not (Get-Command -Name 'docker' -CommandType Application -ErrorAction SilentlyContinue))

        $resolved = Initialize-DeltaDockerPath -SearchPath @($fakeBin)
        Assert-That  -Description 'it resolved from the supplied directory' -Condition $resolved.Resolved
        Assert-That  -Description 'it reports having repaired the PATH' -Condition $resolved.Repaired
        Assert-Equal -Description 'it returns the docker.exe it found' -Expected (Join-Path $fakeBin 'docker.exe') -Actual $resolved.Path

        # And the whole point: a Docker Desktop this process cannot see is
        # still an installed Docker Desktop.
        $env:PATH = $emptyRoot
        $presence = Get-DeltaDockerPresence -InstallState (
            Get-DeltaDockerDesktopInstallState -UninstallKeyPath @("$Script:TestRegRoot\NoSuchKey") -ProgramRoot @($fakeRoot))
        Assert-That -Description 'presence reports it installed despite the empty PATH' -Condition $presence.Installed
        Assert-That -Description 'presence never calls it absent' -Condition ($presence.Condition -ne 'absent')
    }
    finally { $env:PATH = $previousPath }
}
finally {
    Remove-Item -LiteralPath $Script:TestRegRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===========================================================================
# The order, asserted against the source itself
#
# The scenarios above prove the behaviour on a simulated host. These prove the
# code cannot be reordered back into the shape that produced the fault, which
# is the thing a future edit is most likely to do by accident.
# ===========================================================================

Start-TestCase 'The source order cannot regress'

$libraryText = [System.IO.File]::ReadAllText((Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1'))

$detect     = $libraryText.IndexOf("Write-Step 'Detecting Docker'")
$backend    = $libraryText.IndexOf("Write-Step 'Preparing the Docker backend'")
$wslInstall = $libraryText.IndexOf('$wslInstall = Install-DeltaWsl')
$licensing  = $libraryText.IndexOf('if (-not (Confirm-DeltaDockerLicensing))')
$resolve    = $libraryText.IndexOf('$installer = Resolve-DeltaDockerInstaller')
$install    = $libraryText.IndexOf('$install = Install-DeltaDockerDesktop')

Assert-That -Description 'Docker is detected before the backend is prepared' -Condition ($detect -gt 0 -and $detect -lt $backend)
Assert-That -Description 'the backend prerequisite runs before the licensing prompt' -Condition ($backend -gt 0 -and $backend -lt $licensing)
Assert-That -Description 'the WSL install runs before the licensing prompt' -Condition ($wslInstall -gt 0 -and $wslInstall -lt $licensing)
Assert-That -Description 'the licensing prompt runs before the installer is acquired' -Condition ($licensing -gt 0 -and $licensing -lt $resolve)
Assert-That -Description 'the installer is acquired before it is run' -Condition ($resolve -gt 0 -and $resolve -lt $install)
Assert-That -Description 'Docker detection no longer keys off cli-absent alone' -Condition (
    $libraryText -notmatch "if \(\`$engine\.Status -eq 'cli-absent'\) \{\s*\r?\n\s*Write-Detail 'The docker CLI is not present")
Assert-That -Description 'the presence probe repairs PATH before judging the CLI absent' -Condition (
    $libraryText -match '(?s)function Get-DeltaDockerPresence.*?Initialize-DeltaDockerPath.*?Get-DeltaDockerEngineState')
Assert-That -Description 'an existing installation is never given the WSL platform' -Condition (
    $libraryText -match '(?s)function Get-DeltaDockerBackendPlan.*?if \(\$Presence\.Installed\).*?RequiresWslPlatform\s*=\s*\$false')
Assert-That -Description 'wsl --install is still called with --no-distribution' -Condition (
    $libraryText -match "'--install', '--no-distribution'")

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '==> Summary' -ForegroundColor Cyan
Write-Host "    Passed: $Script:Passed"
Write-Host "    Failed: $Script:Failed"

if ($Script:Failed -gt 0) {
    Write-Host ''
    Write-Host 'Runtime sequencing tests FAILED.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'All runtime sequencing tests passed.' -ForegroundColor Green
exit 0
