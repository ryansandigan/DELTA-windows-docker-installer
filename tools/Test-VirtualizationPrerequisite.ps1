#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for the hardware-virtualization prerequisite check.

.DESCRIPTION
    The check this covers used to accept `HypervisorPresent = True` as proof
    that WSL2 and Docker could virtualize. That is true in EVERY guest VM,
    including one whose hypervisor exposes no virtualization extensions at
    all - so a Hyper-V Server 2022 guest without nested virtualization got a
    green "[ ok ] Hardware virtualization", the installer went on to download
    and install Docker Desktop, and Docker then failed with "Virtualization
    support not detected".

    The first test case here is exactly that host. It must be reported as
    blocked, and the remedy must be the Set-VMProcessor command to run on the
    Hyper-V host - not a repair this installer pretends it can perform.

    Every probe is injected: Get-DeltaVirtualizationCapability takes the
    platform, the processor flags, the feature states and HypervisorPresent as
    parameters, so all of physical/guest x enabled/disabled is exercised
    offline on one machine, whatever that machine actually is.

    Deliberately dependency-free, matching the other suites here: no Pester,
    no modules, no network, and nothing that changes this host - no Windows
    feature is enabled and bcdedit is never written to.

    Exits 0 if every test passes, 1 otherwise.

.EXAMPLE
    .\tools\Test-VirtualizationPrerequisite.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$Script:Passed = 0
$Script:Failed = 0

. (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')

function Assert-That {
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)][AllowNull()]$Condition)
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

# --- fixture builders -------------------------------------------------------

function New-Platform {
    param(
        [bool]$IsVirtualMachine = $false,
        [string]$Platform = 'physical',
        [string]$VmName,
        [string]$HostName,
        [string]$Manufacturer = 'Contoso',
        [string]$Model = 'Server'
    )
    return [PSCustomObject]@{
        IsVirtualMachine = $IsVirtualMachine
        Platform         = $Platform
        Manufacturer     = $Manufacturer
        Model            = $Model
        VmName           = $VmName
        HostName         = $HostName
    }
}

function New-Flags {
    param(
        [bool]$VMMonitorModeExtensions = $false,
        [bool]$VirtualizationFirmwareEnabled = $false,
        [bool]$SecondLevelAddressTranslation = $false,
        [bool]$Readable = $true
    )
    return [PSCustomObject]@{
        Readable                      = $Readable
        VirtualizationFirmwareEnabled = $VirtualizationFirmwareEnabled
        VMMonitorModeExtensions       = $VMMonitorModeExtensions
        SecondLevelAddressTranslation = $SecondLevelAddressTranslation
    }
}

function New-Features {
    param([string]$VirtualMachinePlatform = 'Enabled', [string]$HypervisorLaunchType = 'Auto')
    return [PSCustomObject]@{
        VirtualMachinePlatform = $VirtualMachinePlatform
        HypervisorLaunchType   = $HypervisorLaunchType
    }
}

function New-Runtime {
    param([string]$Verdict = 'unknown', [string]$Reason = 'stubbed', [string]$Evidence = '', $ExitCode = 0)
    return [PSCustomObject]@{ Verdict = $Verdict; Reason = $Reason; Evidence = $Evidence; ExitCode = $ExitCode }
}

Write-Host ''
Write-Host '==> DELTA hardware-virtualization prerequisite tests' -ForegroundColor Cyan
Write-Host "    Library under test: $(Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')"

# ---------------------------------------------------------------------------

Start-TestCase 'MEASURED ON A REAL SERVER 2022 GUEST: nested virtualization IS enabled, every guest flag reads False'

# The Hyper-V host has ExposeVirtualizationExtensions = $true and the guest
# runs Docker. Inside that guest, VMMonitorModeExtensions,
# VirtualizationFirmwareEnabled and SecondLevelAddressTranslationExtensions all
# report False, and systeminfo declines to show the Hyper-V requirements
# because a hypervisor is present. Reading those Falses as a refusal is a false
# negative, and blocking on it is as wrong as the original false positive was.
$capability = Get-DeltaVirtualizationCapability `
    -HypervisorPresent $true `
    -Platform (New-Platform -IsVirtualMachine $true -Platform 'hyper-v' -VmName 'DELTA-APP-01' -HostName 'HV-HOST-A') `
    -Flags    (New-Flags) `
    -Features (New-Features) `
    -Runtime  (New-Runtime -Verdict 'unknown')

Assert-Equal -Description 'verdict is unknown, NOT unavailable' -Expected 'unknown' -Actual $capability.Verdict
Assert-That  -Description 'it says the question cannot be settled from inside the guest' -Condition ($capability.Reason -match 'cannot be determined from inside')
Assert-That  -Description 'it says installation continues' -Condition ($capability.Reason -match 'Installation continues')

$check = Test-DeltaVirtualizationPrerequisite -WindowsInfo ([PSCustomObject]@{ HypervisorPresent = $true }) -Capability $capability
Assert-Equal -Description 'the prerequisite check is a NOTICE, not blocked' -Expected 'notice' -Actual $check.Severity
Assert-Equal -Description 'it is still named Hardware virtualization' -Expected 'Hardware virtualization' -Actual $check.Name
Assert-That  -Description 'the check carries the capability for the caller' -Condition ($null -ne $check.Capability)

# The actionable host-side fix is preserved - as forward-looking guidance for
# the failure that may never come, not as an accusation.
Assert-That -Description 'the Set-VMProcessor remedy is still offered' -Condition ($capability.Remedy -match 'Set-VMProcessor -VMName "DELTA-APP-01" -ExposeVirtualizationExtensions')
Assert-That -Description 'it names the Hyper-V host' -Condition ($capability.Remedy -match 'HV-HOST-A')
Assert-That -Description 'it is framed conditionally on Docker failing later' -Condition ($capability.Remedy -match 'If Docker Desktop later reports')

Start-TestCase 'Inconclusive evidence never becomes a hard failure, on any platform'

foreach ($platform in @('hyper-v', 'vmware', 'virtualbox', 'kvm', 'xen', 'ec2', 'unknown-vm')) {
    $capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true `
        -Platform (New-Platform -IsVirtualMachine $true -Platform $platform -VmName 'VM1') `
        -Flags (New-Flags) -Features (New-Features) -Runtime (New-Runtime -Verdict 'unknown')
    $check = Test-DeltaVirtualizationPrerequisite -WindowsInfo ([PSCustomObject]@{ HypervisorPresent = $true }) -Capability $capability
    Assert-That -Description "$platform : unknown does not block" -Condition ($check.Severity -ne 'blocked')
}

Start-TestCase 'A guest that reports VirtualizationFirmwareEnabled is positive evidence too'

# One-way evidence: True means yes. Either flag being True is enough.
foreach ($case in @(
    @{ Flags = (New-Flags -VMMonitorModeExtensions $true);       Label = 'VMMonitorModeExtensions' }
    @{ Flags = (New-Flags -VirtualizationFirmwareEnabled $true); Label = 'VirtualizationFirmwareEnabled' }
)) {
    $capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true `
        -Platform (New-Platform -IsVirtualMachine $true -Platform 'hyper-v' -VmName 'VM1') `
        -Flags $case.Flags -Features (New-Features)
    Assert-Equal -Description "$($case.Label)=True -> available" -Expected 'available' -Actual $capability.Verdict
    Assert-That  -Description "$($case.Label)=True needs no runtime probe" -Condition ($null -eq $capability.Runtime)
}

Start-TestCase 'The same guest, once nested virtualization IS exposed'

$capability = Get-DeltaVirtualizationCapability `
    -HypervisorPresent $true `
    -Platform (New-Platform -IsVirtualMachine $true -Platform 'hyper-v' -VmName 'DELTA-APP-01') `
    -Flags    (New-Flags -VMMonitorModeExtensions $true -SecondLevelAddressTranslation $true) `
    -Features (New-Features)

Assert-Equal -Description 'verdict is available' -Expected 'available' -Actual $capability.Verdict
$check = Test-DeltaVirtualizationPrerequisite -WindowsInfo ([PSCustomObject]@{ HypervisorPresent = $true }) -Capability $capability
Assert-Equal -Description 'the prerequisite check is ok' -Expected 'ok' -Actual $check.Severity

# ---------------------------------------------------------------------------

Start-TestCase 'Physical host running Hyper-V/VBS is still ok (the case the old check was right about)'

# Root partition: a hypervisor is present and the processor flags all read
# False because the hypervisor owns them. This must NOT regress to blocked.
$capability = Get-DeltaVirtualizationCapability `
    -HypervisorPresent $true `
    -Platform (New-Platform) `
    -Flags    (New-Flags) `
    -Features (New-Features)

Assert-Equal -Description 'verdict is available' -Expected 'available' -Actual $capability.Verdict
Assert-That  -Description 'the evidence records that this is physical' -Condition ($capability.Evidence -match 'host=physical')

Start-TestCase 'Physical host, no hypervisor, VT-x enabled in firmware'

$capability = Get-DeltaVirtualizationCapability -HypervisorPresent $false `
    -Platform (New-Platform) -Flags (New-Flags -VirtualizationFirmwareEnabled $true) -Features (New-Features)
Assert-Equal -Description 'verdict is available' -Expected 'available' -Actual $capability.Verdict

Start-TestCase 'Physical host with virtualization disabled in firmware is blocked, with firmware guidance'

$capability = Get-DeltaVirtualizationCapability -HypervisorPresent $false `
    -Platform (New-Platform) -Flags (New-Flags) -Features (New-Features)
Assert-Equal -Description 'verdict is unavailable' -Expected 'unavailable' -Actual $capability.Verdict
Assert-That  -Description 'the remedy names the firmware' -Condition ($capability.Remedy -match 'BIOS/UEFI')
Assert-That  -Description 'the remedy names VT-x/AMD-V' -Condition ($capability.Remedy -match 'VT-x')
Assert-That  -Description 'it does not offer a local repair' -Condition ($capability.RepairActions.Count -eq 0)

# ---------------------------------------------------------------------------

Start-TestCase 'A locally fixable gap is remediable, not ok and not blocked'

foreach ($case in @(
    @{ Features = (New-Features -VirtualMachinePlatform 'Disabled'); Action = 'virtual-machine-platform'; Label = 'VirtualMachinePlatform disabled' }
    @{ Features = (New-Features -HypervisorLaunchType 'Off');        Action = 'hypervisor-launch-type';   Label = 'hypervisorlaunchtype Off' }
)) {
    $capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true `
        -Platform (New-Platform) -Flags (New-Flags) -Features $case.Features
    Assert-Equal -Description "$($case.Label): verdict is remediable" -Expected 'remediable' -Actual $capability.Verdict
    Assert-That  -Description "$($case.Label): the repair is named" -Condition ($capability.RepairActions -contains $case.Action)

    $check = Test-DeltaVirtualizationPrerequisite -WindowsInfo ([PSCustomObject]@{ HypervisorPresent = $true }) -Capability $capability
    Assert-Equal -Description "$($case.Label): reported as a notice, never ok" -Expected 'notice' -Actual $check.Severity
}

Start-TestCase 'Both local gaps at once are both repaired'

$capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true -Platform (New-Platform) -Flags (New-Flags) `
    -Features (New-Features -VirtualMachinePlatform 'Disabled' -HypervisorLaunchType 'Off')
Assert-Equal -Description 'verdict is remediable' -Expected 'remediable' -Actual $capability.Verdict
Assert-Equal -Description 'two repairs are queued' -Expected 2 -Actual $capability.RepairActions.Count

Start-TestCase 'A guest with a fixable feature gap is repaired FIRST, before anything is concluded'

# Locally fixable prerequisites are needed either way, and the runtime probe
# is only meaningful once they are in place - so this is remediable, and the
# question of nested virtualization is deferred rather than answered wrongly.
$capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true `
    -Platform (New-Platform -IsVirtualMachine $true -Platform 'hyper-v' -VmName 'VM1') `
    -Flags    (New-Flags) `
    -Features (New-Features -VirtualMachinePlatform 'Disabled')
Assert-Equal -Description 'verdict is remediable, not unavailable' -Expected 'remediable' -Actual $capability.Verdict
Assert-That  -Description 'the repair is queued' -Condition ($capability.RepairActions -contains 'virtual-machine-platform')
Assert-That  -Description 'it says the question cannot be settled until they are on' -Condition ($capability.Reason -match 'cannot be established from inside')
Assert-That  -Description 'no runtime probe was run before the features are in place' -Condition ($null -eq $capability.Runtime)

Start-TestCase 'A guest is blocked ONLY when the WSL2 runtime refuses, naming virtualization'

$capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true `
    -Platform (New-Platform -IsVirtualMachine $true -Platform 'hyper-v' -VmName 'DELTA-APP-01' -HostName 'HV-HOST-A') `
    -Flags    (New-Flags) -Features (New-Features) `
    -Runtime  (New-Runtime -Verdict 'unavailable' -Reason 'wsl.exe reported: 0x80370102 Please enable the Virtual Machine Platform Windows feature')
Assert-Equal -Description 'verdict is unavailable' -Expected 'unavailable' -Actual $capability.Verdict
Assert-That  -Description 'the reason quotes what WSL2 actually said' -Condition ($capability.Reason -match '0x80370102')
Assert-That  -Description 'the remedy is the Set-VMProcessor command' -Condition ($capability.Remedy -match 'Set-VMProcessor -VMName "DELTA-APP-01" -ExposeVirtualizationExtensions')
Assert-That  -Description 'the remedy names the Hyper-V host' -Condition ($capability.Remedy -match 'HV-HOST-A')
Assert-That  -Description 'the remedy says to shut the VM down' -Condition ($capability.Remedy -match 'Shut this VM down')

$check = Test-DeltaVirtualizationPrerequisite -WindowsInfo ([PSCustomObject]@{ HypervisorPresent = $true }) -Capability $capability
Assert-Equal -Description 'and only then is the check blocked' -Expected 'blocked' -Actual $check.Severity

Start-TestCase 'A guest where the WSL2 runtime is happy is available'

$capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true `
    -Platform (New-Platform -IsVirtualMachine $true -Platform 'hyper-v' -VmName 'VM1') `
    -Flags (New-Flags) -Features (New-Features) -Runtime (New-Runtime -Verdict 'available')
Assert-Equal -Description 'verdict is available' -Expected 'available' -Actual $capability.Verdict
$check = Test-DeltaVirtualizationPrerequisite -WindowsInfo ([PSCustomObject]@{ HypervisorPresent = $true }) -Capability $capability
Assert-Equal -Description 'the check is ok' -Expected 'ok' -Actual $check.Severity

Start-TestCase 'The WSL2 runtime probe classifies its own output correctly'

$fake = Join-Path $env:TEMP 'delta-fake-wsl.cmd'
try {
    foreach ($case in @(
        @{ Body = '@echo 0x80370102 Please enable the Virtual Machine Platform Windows feature'; Code = 1; Expect = 'unavailable'; Label = 'HCS_E_HYPERV_NOT_INSTALLED' }
        @{ Body = '@echo WSL2 is not supported with your current machine configuration';         Code = 1; Expect = 'unavailable'; Label = 'WSL2 unsupported machine configuration' }
        @{ Body = '@echo Default Version: 2';                                                    Code = 0; Expect = 'available';   Label = 'healthy WSL2' }
        @{ Body = '@echo The network name cannot be found';                                      Code = 5; Expect = 'unknown';     Label = 'unrelated failure' }

        # Verbatim from a healthy host: Docker running, WSL2 working. The last
        # line is about WSL**1** and is normal. An earlier signature list
        # matched it and declared the machine incapable - on a guest that would
        # have been a false stop, so it is pinned here.
        @{ Body = "@echo Default Distribution: Ubuntu-24.04&@echo Default Version: 2&@echo WSL1 is not supported with your current machine configuration."
           Code = 0; Expect = 'available'; Label = 'REAL healthy host mentioning WSL1' }

        # Same text, but WSL actually failed. Now it counts.
        @{ Body = '@echo WSL1 is not supported with your current machine configuration.'
           Code = 1; Expect = 'unknown'; Label = 'WSL1 note on a failure is still not a WSL2 verdict' }
    )) {
        Set-Content -LiteralPath $fake -Value "$($case.Body)`r`n@exit /b $($case.Code)" -Encoding ascii
        $runtime = Test-DeltaWsl2RuntimeCapability -WslPath $fake
        Assert-Equal -Description "$($case.Label) -> $($case.Expect)" -Expected $case.Expect -Actual $runtime.Verdict
    }
}
finally { Remove-Item -LiteralPath $fake -Force -ErrorAction SilentlyContinue }

$runtime = Test-DeltaWsl2RuntimeCapability -WslPath (Join-Path $env:TEMP 'delta-no-such-wsl.exe')
Assert-Equal -Description 'an unreachable wsl.exe is unknown, never unavailable' -Expected 'unknown' -Actual $runtime.Verdict

Start-TestCase 'Unknown feature states are never treated as faults'

$capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true -Platform (New-Platform) -Flags (New-Flags) `
    -Features (New-Features -VirtualMachinePlatform 'unknown' -HypervisorLaunchType 'unknown')
Assert-Equal -Description 'verdict is available' -Expected 'available' -Actual $capability.Verdict
Assert-Equal -Description 'nothing is queued for repair' -Expected 0 -Actual $capability.RepairActions.Count

# ---------------------------------------------------------------------------

Start-TestCase 'Non-Hyper-V platforms get their own guidance'

foreach ($case in @(
    @{ Platform = 'vmware';     Match = 'Virtualize Intel VT-x/EPT' }
    @{ Platform = 'virtualbox'; Match = 'VBoxManage modifyvm' }
    @{ Platform = 'kvm';        Match = 'kvm_intel/kvm_amd' }
)) {
    $capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true `
        -Platform (New-Platform -IsVirtualMachine $true -Platform $case.Platform -VmName 'VM1') `
        -Flags (New-Flags) -Features (New-Features) `
        -Runtime (New-Runtime -Verdict 'unavailable' -Reason 'wsl.exe reported: 0x80370102')
    Assert-Equal -Description "$($case.Platform): unavailable" -Expected 'unavailable' -Actual $capability.Verdict
    Assert-That  -Description "$($case.Platform): platform-specific remedy" -Condition ($capability.Remedy -match $case.Match)
    Assert-That  -Description "$($case.Platform): does not tell them to run Set-VMProcessor" -Condition ($capability.Remedy -notmatch 'Set-VMProcessor')
}

Start-TestCase 'An unidentified hypervisor gets generic guidance, not a guess'

$capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true `
    -Platform (New-Platform -IsVirtualMachine $true -Platform 'unknown-vm') -Flags (New-Flags) -Features (New-Features) `
    -Runtime (New-Runtime -Verdict 'unavailable' -Reason 'wsl.exe reported: 0x80370102')
Assert-Equal -Description 'unavailable' -Expected 'unavailable' -Actual $capability.Verdict
Assert-That  -Description 'says nested virtualization must be enabled on the hypervisor' -Condition ($capability.Remedy -match 'nested virtualization')
Assert-That  -Description 'names no specific product' -Condition ($capability.Remedy -notmatch 'Hyper-V|VMware|VirtualBox')
Assert-That  -Description 'mentions the cloud case honestly' -Condition ($capability.Remedy -match 'Cloud VMs')

# ---------------------------------------------------------------------------

Start-TestCase 'Platform identification'

$guestKey = 'HKCU:\Software\DELTA-vm-tests\Guest\Parameters'
try {
    $null = New-Item -Path $guestKey -Force -ErrorAction Stop
    $null = New-ItemProperty -Path $guestKey -Name 'VirtualMachineName' -Value 'GUEST-42' -PropertyType String -Force
    $null = New-ItemProperty -Path $guestKey -Name 'HostName' -Value 'HYPERV-01' -PropertyType String -Force

    $platform = Get-DeltaVirtualPlatformInfo -GuestKeyPath $guestKey -ComputerSystem ([PSCustomObject]@{ Manufacturer = 'Microsoft Corporation'; Model = 'Virtual Machine' })
    Assert-That  -Description 'the Hyper-V guest key marks it a VM' -Condition $platform.IsVirtualMachine
    Assert-Equal -Description 'platform is hyper-v' -Expected 'hyper-v' -Actual $platform.Platform
    Assert-Equal -Description 'the VM name is read from the guest key' -Expected 'GUEST-42' -Actual $platform.VmName
    Assert-Equal -Description 'the host name is read from the guest key' -Expected 'HYPERV-01' -Actual $platform.HostName
}
finally {
    Remove-Item -LiteralPath 'HKCU:\Software\DELTA-vm-tests' -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($case in @(
    @{ Manufacturer = 'VMware, Inc.';         Model = 'VMware20,1';       Expect = 'vmware' }
    @{ Manufacturer = 'innotek GmbH';         Model = 'VirtualBox';       Expect = 'virtualbox' }
    @{ Manufacturer = 'QEMU';                 Model = 'Standard PC';      Expect = 'kvm' }
    @{ Manufacturer = 'Xen';                  Model = 'HVM domU';         Expect = 'xen' }
    @{ Manufacturer = 'Amazon EC2';           Model = 'm5.large';         Expect = 'ec2' }
    @{ Manufacturer = 'Parallels Software';   Model = 'Parallels Virtual'; Expect = 'parallels' }
)) {
    # A guest key path that does not exist, so classification falls to the strings.
    $platform = Get-DeltaVirtualPlatformInfo -GuestKeyPath 'HKCU:\Software\DELTA-absent-key' `
        -ComputerSystem ([PSCustomObject]@{ Manufacturer = $case.Manufacturer; Model = $case.Model })
    Assert-Equal -Description "$($case.Manufacturer) -> $($case.Expect)" -Expected $case.Expect -Actual $platform.Platform
    Assert-That  -Description "$($case.Expect) is recognised as a VM" -Condition $platform.IsVirtualMachine
}

$platform = Get-DeltaVirtualPlatformInfo -GuestKeyPath 'HKCU:\Software\DELTA-absent-key' `
    -ComputerSystem ([PSCustomObject]@{ Manufacturer = 'Dell Inc.'; Model = 'PowerEdge R750' })
Assert-That  -Description 'real hardware is not mistaken for a VM' -Condition (-not $platform.IsVirtualMachine)
Assert-Equal -Description 'platform is physical' -Expected 'physical' -Actual $platform.Platform

# ---------------------------------------------------------------------------

Start-TestCase 'The blocked verdict stops the run before Docker is acquired'

$libraryText = [System.IO.File]::ReadAllText((Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1'))
$blockedGate  = $libraryText.IndexOf('$blocked = @($checks | Where-Object { $_.Severity -eq ''blocked'' })')
$dockerDetect = $libraryText.IndexOf("Write-Step 'Detecting Docker'")
$resolveCall  = $libraryText.IndexOf('$installer = Resolve-DeltaDockerInstaller')

Assert-That -Description 'the blocked gate exists' -Condition ($blockedGate -gt 0)
Assert-That -Description 'it runs before Docker is detected' -Condition ($blockedGate -lt $dockerDetect)
Assert-That -Description 'it runs before the installer is acquired' -Condition ($blockedGate -lt $resolveCall)
Assert-That -Description 'remediation is attempted before the blocked gate' -Condition (
    $libraryText.IndexOf('Repair-DeltaVirtualizationPrerequisite -Capability') -lt $blockedGate)
Assert-That -Description 'a repair that needs a restart returns reboot-required' -Condition (
    $libraryText -match "(?s)if \(\`$repair\.RestartRequired\) \{.*?\`$result\.Outcome = 'reboot-required'")
Assert-That -Description 'HypervisorPresent alone no longer produces an ok result' -Condition (
    $libraryText -notmatch "a hypervisor is running, so virtualization is enabled")
Assert-That -Description 'guest processor flags being False is not a blocking condition on its own' -Condition (
    $libraryText -notmatch "the CPU does not expose it to this guest")
Assert-That -Description 'the unknown verdict is mapped to a notice, not blocked' -Condition (
    $libraryText -match "(?s)'unknown' \{.*?-Severity 'notice'")

# ---------------------------------------------------------------------------

Start-TestCase 'The live host reads without error (whatever it is)'

$platform = Get-DeltaVirtualPlatformInfo
Assert-That -Description 'platform info is returned' -Condition ($null -ne $platform)
Assert-That -Description 'platform is one of the known answers' -Condition (
    $platform.Platform -in @('physical', 'hyper-v', 'vmware', 'virtualbox', 'kvm', 'xen', 'ec2', 'gce', 'parallels', 'unknown-vm'))
$flags = Get-DeltaProcessorVirtualizationFlags
Assert-That -Description 'processor flags are returned' -Condition ($null -ne $flags)
$features = Get-DeltaVirtualizationFeatureState
Assert-That -Description 'feature state is returned' -Condition ($null -ne $features)
Write-Host "    (this host: platform=$($platform.Platform), VMMonitorModeExtensions=$($flags.VMMonitorModeExtensions), VMP=$($features.VirtualMachinePlatform), launchtype=$($features.HypervisorLaunchType))"

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '==> Summary' -ForegroundColor Cyan
Write-Host "    Passed: $Script:Passed"
Write-Host "    Failed: $Script:Failed"

if ($Script:Failed -gt 0) {
    Write-Host ''
    Write-Host 'Virtualization prerequisite tests FAILED.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'All virtualization prerequisite tests passed.' -ForegroundColor Green
exit 0
