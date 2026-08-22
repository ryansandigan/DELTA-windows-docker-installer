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

Write-Host ''
Write-Host '==> DELTA hardware-virtualization prerequisite tests' -ForegroundColor Cyan
Write-Host "    Library under test: $(Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')"

# ---------------------------------------------------------------------------

Start-TestCase 'THE REPORTED BUG: Hyper-V guest, HypervisorPresent=True, no nested virtualization'

$capability = Get-DeltaVirtualizationCapability `
    -HypervisorPresent $true `
    -Platform (New-Platform -IsVirtualMachine $true -Platform 'hyper-v' -VmName 'DELTA-APP-01' -HostName 'HV-HOST-A') `
    -Flags    (New-Flags -VMMonitorModeExtensions $false) `
    -Features (New-Features)

Assert-Equal -Description 'verdict is unavailable, NOT available' -Expected 'unavailable' -Actual $capability.Verdict
Assert-That  -Description 'the reason names nested virtualization' -Condition ($capability.Reason -match 'nested virtualization')
Assert-That  -Description 'the reason names the flag that decided it' -Condition ($capability.Reason -match 'VMMonitorModeExtensions')
Assert-That  -Description 'the remedy is Set-VMProcessor on the host' -Condition ($capability.Remedy -match 'Set-VMProcessor -VMName "DELTA-APP-01" -ExposeVirtualizationExtensions')
Assert-That  -Description 'the remedy names the Hyper-V host' -Condition ($capability.Remedy -match 'HV-HOST-A')
Assert-That  -Description 'the remedy says to shut the VM down' -Condition ($capability.Remedy -match 'Shut this VM down')
Assert-That  -Description 'no local repair is offered' -Condition ($capability.RepairActions.Count -eq 0)
Assert-That  -Description 'the evidence records HypervisorPresent=True' -Condition ($capability.Evidence -match 'HypervisorPresent=True')
Assert-That  -Description 'the evidence records that this is a VM' -Condition ($capability.Evidence -match 'virtual machine \(hyper-v\)')

$check = Test-DeltaVirtualizationPrerequisite -WindowsInfo ([PSCustomObject]@{ HypervisorPresent = $true }) -Capability $capability
Assert-Equal -Description 'the prerequisite check is blocked' -Expected 'blocked' -Actual $check.Severity
Assert-Equal -Description 'it is still named Hardware virtualization' -Expected 'Hardware virtualization' -Actual $check.Name
Assert-That  -Description 'the check carries the capability for the caller' -Condition ($null -ne $check.Capability)

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

Start-TestCase 'A guest with no extensions is NOT made remediable by a fixable feature gap'

# The important asymmetry: turning Windows features on cannot conjure CPU
# extensions the hypervisor is not exposing, so this stays unavailable even
# though VirtualMachinePlatform is disabled and would otherwise be repaired.
$capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true `
    -Platform (New-Platform -IsVirtualMachine $true -Platform 'hyper-v' -VmName 'VM1') `
    -Flags    (New-Flags -VMMonitorModeExtensions $false) `
    -Features (New-Features -VirtualMachinePlatform 'Disabled')
Assert-Equal -Description 'verdict is unavailable, not remediable' -Expected 'unavailable' -Actual $capability.Verdict
Assert-That  -Description 'the remedy still points at the hypervisor host' -Condition ($capability.Remedy -match 'Set-VMProcessor')

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
        -Flags (New-Flags) -Features (New-Features)
    Assert-Equal -Description "$($case.Platform): unavailable" -Expected 'unavailable' -Actual $capability.Verdict
    Assert-That  -Description "$($case.Platform): platform-specific remedy" -Condition ($capability.Remedy -match $case.Match)
    Assert-That  -Description "$($case.Platform): does not tell them to run Set-VMProcessor" -Condition ($capability.Remedy -notmatch 'Set-VMProcessor')
}

Start-TestCase 'An unidentified hypervisor gets generic guidance, not a guess'

$capability = Get-DeltaVirtualizationCapability -HypervisorPresent $true `
    -Platform (New-Platform -IsVirtualMachine $true -Platform 'unknown-vm') -Flags (New-Flags) -Features (New-Features)
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
