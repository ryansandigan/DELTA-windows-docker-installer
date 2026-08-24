#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for automatic DELTA startup after a Windows restart, and
    for the management status row that reports it.

.DESCRIPTION
    The failure these cover, as it was observed on a real Windows Server host
    with Docker Desktop on the WSL2 backend:

        install DELTA
        -> the management screen shows "Restart  Configured"
        -> restart Windows
        -> Docker Desktop is not running, com.docker.backend is not running,
           `docker info` cannot reach dockerDesktopLinuxEngine
        -> DELTA is down
        -> Get-ScheduledTask shows only the NGINX log-rotation task; there is
           no DELTA startup task at all

    Three separate faults produced that, and each has its own tests here.

      1. com.docker.service was classified as a boot-time mechanism that
         *might* start the engine. It cannot: it is Docker's privileged helper
         for a signed-in user, and it starts neither Docker Desktop nor the
         WSL2 VM nor the Linux engine. Finding it was enough to make the
         measurement return "something covers this host", so the installer
         registered no task of its own.

      2. The one task that was registered elsewhere had a boot trigger only.
         Docker Desktop's WSL2 engine is started by a per-user desktop
         application, so a trigger that fires before any session exists cannot
         be the only trigger.

      3. The management screen read "configured" out of .delta-install.json and
         printed it. The record says what an installer did once; it cannot say
         what is registered on the host today.

    So the invariants pinned here are:

      - no mechanism that cannot start the engine may satisfy the measurement,
        and finding one never suppresses registering DELTA's own task;
      - the registered task carries BOTH an at-startup and an at-logon trigger,
        runs as the installing account, and runs non-interactively;
      - the status row is derived from the scheduler, not from the record, so a
        task that has gone can never be reported as Configured;
      - Configured and Verified are different claims, and only a real
        unattended recovery may produce the second.

    Task Scheduler is replaced by an in-memory stand-in - the same shadowing
    technique Test-RuntimeSequencing.ps1 uses - so nothing here registers,
    replaces or removes a scheduled task on the machine it runs on. The trigger,
    principal and settings objects are built by the REAL ScheduledTasks cmdlets,
    because how those triggers come out is exactly what is under test.

    Nothing here touches Docker, the NGINX rotation task, or any installation
    outside its own temporary directory.

    Exits 0 if every test passes, 1 otherwise.

.EXAMPLE
    .\tools\Test-UnattendedStartup.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$Script:WorkRoot    = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("delta-startup-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Script:Passed = 0
$Script:Failed = 0

. (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Network.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Stack.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Manage.ps1')

# ---------------------------------------------------------------------------
# Assertion helpers (same shape as the other suites here)
# ---------------------------------------------------------------------------

function Assert-That {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()]$Condition
    )
    if ($Condition) { Write-TestLine "    [PASS] $Description" 'Green'; $Script:Passed++ }
    else            { Write-TestLine "    [FAIL] $Description" 'Red';   $Script:Failed++ }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Expected,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Actual
    )
    if ($Expected -ceq $Actual) { Write-TestLine "    [PASS] $Description" 'Green'; $Script:Passed++ }
    else {
        Write-TestLine "    [FAIL] $Description" 'Red'
        Write-TestLine "           expected: '$Expected'" 'Red'
        Write-TestLine "           actual:   '$Actual'" 'Red'
        $Script:Failed++
    }
}

function Start-TestCase {
    param([Parameter(Mandatory)][string]$Name)
    Write-TestLine '' 'Gray'
    Write-TestLine "==> $Name" 'Cyan'
}

# The suite's own output has to survive Write-Host being shadowed below, so it
# goes through the real cmdlet by its fully qualified name.
function Write-TestLine {
    param([AllowEmptyString()][string]$Text, [string]$Colour = 'Gray')
    Microsoft.PowerShell.Utility\Write-Host $Text -ForegroundColor $Colour
}

# ---------------------------------------------------------------------------
# The simulated machine
#
# One hashtable describes the host under test, plus an in-memory Task Scheduler.
# ---------------------------------------------------------------------------

function Reset-Machine {
    param([hashtable]$Overrides = @{})

    $Script:Machine = @{
        # com.docker.service: $null for absent, or its start mode.
        DockerServiceStartMode = $null
        DockerServiceStatus    = 'Running'

        AutoStartSupported     = $true
        AutoStartEnabled       = $true

        DesktopStatus          = 'running'

        # A Docker Desktop entry under HKCU Run, as a real host has.
        HkcuRunEntry           = $true

        RegisterFails          = $false
    }
    foreach ($key in $Overrides.Keys) { $Script:Machine[$key] = $Overrides[$key] }

    $Script:Tasks = @{}
    $Script:Calls = @{ Registered = 0; Unregistered = 0 }
    $Script:HostLines = New-Object System.Collections.ArrayList
}

# ---------------------------------------------------------------------------
# Scripted stand-ins
#
# Defined AFTER the libraries are dot-sourced, so they shadow them.
# Get-DeltaStartupTaskState, Register-DeltaStartupTask,
# Measure-DeltaUnattendedStartCapability, Invoke-DeltaStartupConfiguration and
# Test-DeltaStartupMechanism are deliberately NOT shadowed: they are the code
# under test.
# ---------------------------------------------------------------------------

function Write-Host {
    param(
        [Parameter(ValueFromPipeline, Position = 0)][AllowEmptyString()][AllowNull()]$Object,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline
    )
    $null = $Script:HostLines.Add([string]$Object)
}

function Get-DeltaDockerServiceState {
    param([string]$ServiceName = 'com.docker.service')

    return [PSCustomObject]@{
        Name      = $ServiceName
        Exists    = [bool]$Script:Machine.DockerServiceStartMode
        Status    = $(if ($Script:Machine.DockerServiceStartMode) { $Script:Machine.DockerServiceStatus } else { $null })
        StartType = $Script:Machine.DockerServiceStartMode
    }
}

function Get-DeltaDockerAutoStartState {
    param([string]$SettingsPath)

    return [PSCustomObject]@{
        Path      = 'C:\simulated\settings-store.json'
        Supported = $Script:Machine.AutoStartSupported
        Enabled   = $Script:Machine.AutoStartEnabled
        Settings  = $null
        Error     = $(if ($Script:Machine.AutoStartSupported) { $null } else { 'Docker Desktop has no settings file for this user yet.' })
    }
}

function Set-DeltaDockerAutoStart {
    param([Parameter(Mandatory)][bool]$Enabled, [string]$SettingsPath)

    if ($Script:Machine.AutoStartSupported) { $Script:Machine.AutoStartEnabled = $Enabled }
    return [PSCustomObject]@{
        Path      = 'C:\simulated\settings-store.json'
        Supported = $Script:Machine.AutoStartSupported
        Changed   = $false
        Enabled   = $Script:Machine.AutoStartEnabled
        Reason    = 'simulated'
    }
}

function Get-DeltaDockerDesktopStatus {
    return [PSCustomObject]@{ Supported = $true; Status = $Script:Machine.DesktopStatus; Detail = 'simulated' }
}

function Get-ItemProperty {
    param(
        [Parameter(Position = 0)][string[]]$Path,
        [string[]]$Name,
        [switch]$ErrorAction
    )

    if ($Path -and $Path[0] -match '(?i)CurrentVersion\\Run$') {
        $entry = [PSCustomObject]@{ }
        if ($Path[0] -match '(?i)^HKCU:' -and $Script:Machine.HkcuRunEntry) {
            Add-Member -InputObject $entry -MemberType NoteProperty -Name 'Docker Desktop' -Value 'C:\Program Files\Docker\Docker\Docker Desktop.exe -Autostart'
        }
        return $entry
    }
    return (Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters)
}

# --- the in-memory Task Scheduler -----------------------------------------

function Resolve-TaskName {
    <#
      The readers pass a bracket-escaped name because -TaskName is a wildcard
      filter on the real cmdlet. The stand-in has to accept exactly what they
      pass, so it un-escapes rather than requiring callers to know it is fake -
      if the escaping were ever dropped, that bug would surface here too.
    #>
    param([string]$TaskName)
    return ($TaskName -replace '`(.)', '$1' -replace '\[(.)\]', '$1')
}

function Get-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath, [switch]$ErrorAction)

    $name = Resolve-TaskName -TaskName $TaskName
    if ($Script:Tasks.ContainsKey($name)) { return $Script:Tasks[$name] }
    return $null
}

function Get-ScheduledTaskInfo {
    param([string]$TaskName, [switch]$ErrorAction)

    $name = Resolve-TaskName -TaskName $TaskName
    if (-not $Script:Tasks.ContainsKey($name)) { return $null }
    return [PSCustomObject]@{ LastRunTime = $null; LastTaskResult = 0 }
}

function Register-ScheduledTask {
    param(
        [string]$TaskName,
        $Action,
        $Trigger,
        $Principal,
        $Settings,
        [string]$Description,
        [switch]$Force,
        [switch]$ErrorAction
    )

    $Script:Calls.Registered++
    if ($Script:Machine.RegisterFails) { throw 'Access is denied. (simulated)' }

    $Script:Tasks[$TaskName] = [PSCustomObject]@{
        TaskName    = $TaskName
        Description = $Description
        Actions     = @($Action)
        Triggers    = @($Trigger)
        Principal   = $Principal
        Settings    = $Settings
    }
    return $Script:Tasks[$TaskName]
}

function Unregister-ScheduledTask {
    param([string]$TaskName, [switch]$Confirm, [switch]$ErrorAction)

    $Script:Calls.Unregistered++
    $Script:Tasks.Remove((Resolve-TaskName -TaskName $TaskName))
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

$Script:ProjectName = 'delta'
$Script:TaskName    = "DELTA (Docker) - $Script:ProjectName - Startup"

function New-TestInstallation {
    <#
      A temporary installation root with a state file and a real bin\ holding a
      real start-delta.ps1, so "the script the task points at exists" is a fact
      about the filesystem rather than another stand-in.
    #>
    param([hashtable]$UnattendedStartup)

    $root = Join-Path -Path $Script:WorkRoot -ChildPath ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $root -Force
    $scriptRoot = Join-Path -Path $root -ChildPath 'installer'
    $null = New-Item -ItemType Directory -Path (Join-Path $scriptRoot 'bin') -Force
    Copy-Item -LiteralPath (Join-Path $Script:ProjectRoot 'bin\start-delta.ps1') `
        -Destination (Join-Path $scriptRoot 'bin\start-delta.ps1') -Force

    $properties = [ordered]@{
        state          = 'installed'
        installRoot    = $root
        composeProject = $Script:ProjectName
    }
    if ($UnattendedStartup) { $properties['unattendedStartup'] = [PSCustomObject]$UnattendedStartup }
    $null = Write-DeltaInstallState -InstallRoot $root -Properties $properties

    return [PSCustomObject]@{
        InstallRoot = $root
        ScriptRoot  = $scriptRoot
        ScriptPath  = (Join-Path $scriptRoot 'bin\start-delta.ps1')
    }
}

function Register-TestStartupTask {
    param(
        [Parameter(Mandatory)][object]$Installation,
        [string]$UserId = 'TESTHOST\installer'
    )
    return (Register-DeltaStartupTask -ProjectName $Script:ProjectName -InstallRoot $Installation.InstallRoot `
        -ScriptPath $Installation.ScriptPath -UserId $UserId)
}

function Get-RecordedStartup {
    param([Parameter(Mandatory)][string]$InstallRoot)

    $state = Read-DeltaInstallState -InstallRoot $InstallRoot
    if (-not ($state.Exists -and $state.IsValid)) { return $null }
    if (-not (@($state.Data.PSObject.Properties.Name) -contains 'unattendedStartup')) { return $null }
    return $state.Data.unattendedStartup
}

function Get-StatusRowText {
    <#
      The Restart row exactly as an operator sees it, produced by the real
      Write-DeltaStatusRow so the column widths are the product's and not the
      test's.
    #>
    param([Parameter(Mandatory)][object]$Health)

    $Script:HostLines.Clear()
    Write-DeltaStatusRow -Label 'Restart' -State $Health.State -Detail $Health.Detail
    return [string]$Script:HostLines[0]
}

# ---------------------------------------------------------------------------
# 1. The root cause: a mechanism that cannot start the engine
# ---------------------------------------------------------------------------

function Test-DockerServiceDoesNotCount {
    Start-TestCase 'com.docker.service present at boot does not count as a startup mechanism'

    Reset-Machine -Overrides @{ DockerServiceStartMode = 'Auto' }
    $installation = New-TestInstallation

    $measurement = Measure-DeltaUnattendedStartCapability -ProjectName $Script:ProjectName
    $service = @($measurement.Mechanisms | Where-Object { $_.Name -eq 'com.docker.service' })[0]

    Assert-That 'the service is still reported as present, because it is' $service.Present
    Assert-Equal 'it is classified as not starting the engine' 'no' $service.StartsEngine
    Assert-Equal 'with no task registered the verdict is none, not unproven' 'none' $measurement.Verdict

    Start-TestCase 'and the installer registers its own task anyway'

    $result = Invoke-DeltaStartupConfiguration -InstallRoot $installation.InstallRoot `
        -ScriptRoot $installation.ScriptRoot -ProjectName $Script:ProjectName -RestartPolicy $null

    Assert-That 'the startup stage succeeded' $result.Succeeded
    Assert-Equal 'the mechanism is DELTA''s own task, never "vendor"' 'startup-task' $result.Mechanism
    Assert-That 'a task was actually registered' ($Script:Tasks.ContainsKey($Script:TaskName))

    $recorded = Get-RecordedStartup -InstallRoot $installation.InstallRoot
    Assert-Equal 'and the state file records that mechanism' 'startup-task' ([string]$recorded.mechanism)
    Assert-That 'configured is true only because a task exists' ([bool]$recorded.configured)
}

function Test-VendorMechanismNeverSuppressesRegistration {
    Start-TestCase 'no third-party boot mechanism suppresses DELTA''s own task'

    # A host where something unrecognised does run at boot: the measurement may
    # say so, but the installer must still own a mechanism it can verify.
    Reset-Machine -Overrides @{ DockerServiceStartMode = 'Auto' }
    $installation = New-TestInstallation

    $result = Invoke-DeltaStartupConfiguration -InstallRoot $installation.InstallRoot `
        -ScriptRoot $installation.ScriptRoot -ProjectName $Script:ProjectName -RestartPolicy $null

    Assert-Equal 'exactly one task was registered' 1 $Script:Calls.Registered
    Assert-Equal 'and the reported mechanism is that task' 'startup-task' $result.Mechanism

    $health = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-That 'which the live check confirms is present' $health.Present
}

# ---------------------------------------------------------------------------
# 2. The trigger and account context
# ---------------------------------------------------------------------------

function Test-TaskTriggersAndPrincipal {
    Start-TestCase 'the registered task has both triggers and the right account'

    Reset-Machine
    $installation = New-TestInstallation
    $registration = Register-TestStartupTask -Installation $installation

    Assert-That 'registration succeeded' $registration.Succeeded
    Assert-Equal 'it was created' 'created' $registration.Action

    $state = Get-DeltaStartupTaskState -ProjectName $Script:ProjectName
    Assert-That 'the task exists' $state.Exists
    Assert-That 'it runs at Windows startup' $state.AtStartup
    Assert-That 'it also runs at logon of the installing account' $state.AtLogon
    Assert-Equal 'as the installing account' 'TESTHOST\installer' $state.UserId
    Assert-Equal 'with logon type S4U, so no password is stored' 'S4U' $state.LogonType
    Assert-Equal 'and elevated' 'Highest' $state.RunLevel
    Assert-That 'and it is healthy' $state.Healthy

    $logon = @($Script:Tasks[$Script:TaskName].Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })[0]
    Assert-Equal 'the logon trigger is scoped to that one account' 'TESTHOST\installer' ([string]$logon.UserId)
}

function Test-TaskRunsNonInteractively {
    Start-TestCase 'the task runs the startup script non-interactively'

    Reset-Machine
    $installation = New-TestInstallation
    $null = Register-TestStartupTask -Installation $installation

    $state = Get-DeltaStartupTaskState -ProjectName $Script:ProjectName
    Assert-Equal 'it runs powershell.exe' 'powershell.exe' $state.Execute
    Assert-That 'with -NonInteractive'  ($state.Arguments -match '(?i)\-NonInteractive')
    Assert-That 'with -NoProfile'       ($state.Arguments -match '(?i)\-NoProfile')
    Assert-That 'with -ExecutionPolicy Bypass' ($state.Arguments -match '(?i)\-ExecutionPolicy\s+Bypass')
    Assert-That 'and it passes -FromStartupTask' ($state.Arguments -match '(?i)\-FromStartupTask')
    Assert-Equal 'the -File path is the startup script' $installation.ScriptPath $state.ScriptPath
    Assert-That 'which is on disk' $state.ScriptFound

    # The command line is only non-interactive if start-delta.ps1 will actually
    # accept it. A switch the script does not declare would make every
    # unattended run fail at parameter binding, at boot, with nobody watching.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($installation.ScriptPath, [ref]$null, [ref]$null)
    $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    Assert-That 'and start-delta.ps1 declares -FromStartupTask' ($parameters -contains 'FromStartupTask')
    Assert-That 'and -InstallRoot' ($parameters -contains 'InstallRoot')
}

function Test-BootOnlyTaskIsRepaired {
    Start-TestCase 'a legacy boot-trigger-only task is not accepted'

    Reset-Machine
    $installation = New-TestInstallation

    # Exactly what the previous version of the installer registered: one boot
    # trigger, no logon trigger. On a WSL2 host that cannot be relied on to
    # start a per-user desktop application, so it must not pass as healthy.
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument (Get-DeltaStartupTaskArguments -ScriptPath $installation.ScriptPath -InstallRoot $installation.InstallRoot)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'TESTHOST\installer' -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet
    $null = Register-ScheduledTask -TaskName $Script:TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'legacy' -Force

    $state = Get-DeltaStartupTaskState -ProjectName $Script:ProjectName
    Assert-That 'the legacy task exists' $state.Exists
    Assert-That 'but it is not healthy' (-not $state.Healthy)
    Assert-That 'and the problem names the missing logon trigger' ($state.Problem -match '(?i)logon trigger')

    $measurement = Measure-DeltaUnattendedStartCapability -ProjectName $Script:ProjectName
    Assert-Equal 'so the measurement does not report it as covering the host' 'none' $measurement.Verdict

    $result = Invoke-DeltaStartupConfiguration -InstallRoot $installation.InstallRoot `
        -ScriptRoot $installation.ScriptRoot -ProjectName $Script:ProjectName -RestartPolicy $null
    Assert-That 'and it is replaced' $result.Succeeded

    $after = Get-DeltaStartupTaskState -ProjectName $Script:ProjectName
    Assert-That 'with one that has both triggers' ($after.AtStartup -and $after.AtLogon)
}

function Test-MovedInstallerIsRepaired {
    Start-TestCase 'a task pointing at a script that has moved is replaced'

    Reset-Machine
    $installation = New-TestInstallation
    $null = Register-TestStartupTask -Installation $installation

    Remove-Item -LiteralPath $installation.ScriptPath -Force

    $state = Get-DeltaStartupTaskState -ProjectName $Script:ProjectName
    Assert-That 'the task is no longer healthy' (-not $state.Healthy)
    Assert-That 'and says the script is not there' ($state.Problem -match '(?i)which is not there')

    $health = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-Equal 'the status row does not say Configured' 'Not set up' $health.State
}

function Test-RegistrationIsIdempotent {
    Start-TestCase 'registering twice does not churn a working task'

    Reset-Machine
    $installation = New-TestInstallation

    $first = Register-TestStartupTask -Installation $installation
    $second = Register-TestStartupTask -Installation $installation

    Assert-Equal 'the first call created it' 'created' $first.Action
    Assert-Equal 'the second left it alone' 'unchanged' $second.Action
    Assert-Equal 'so Task Scheduler was written to exactly once' 1 $Script:Calls.Registered
}

function Test-RegistrationFailureIsNotConfigured {
    Start-TestCase 'a registration that fails is never reported as configured'

    Reset-Machine -Overrides @{ RegisterFails = $true }
    $installation = New-TestInstallation

    $result = Invoke-DeltaStartupConfiguration -InstallRoot $installation.InstallRoot `
        -ScriptRoot $installation.ScriptRoot -ProjectName $Script:ProjectName -RestartPolicy $null

    Assert-That 'the stage did not succeed' (-not $result.Succeeded)
    Assert-Equal 'and claims no mechanism' 'none' $result.Mechanism

    $recorded = Get-RecordedStartup -InstallRoot $installation.InstallRoot
    Assert-That 'the state file says not configured' (-not [bool]$recorded.configured)

    $health = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-Equal 'and the status row says so too' 'Not set up' $health.State
}

# ---------------------------------------------------------------------------
# 3. The management status row
# ---------------------------------------------------------------------------

function Test-ConfiguredRow {
    Start-TestCase 'a registered, unverified mechanism reads Configured'

    Reset-Machine
    $installation = New-TestInstallation
    $null = Register-TestStartupTask -Installation $installation
    $null = Write-DeltaInstallState -InstallRoot $installation.InstallRoot -Properties @{
        unattendedStartup = [PSCustomObject]@{ configured = $true; mechanism = 'startup-task'; rebootTested = $false; bootTest = $null }
    }

    $health = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-Equal 'state' 'Configured' $health.State
    Assert-Equal 'detail' 'automatic startup enabled' $health.Detail
    Assert-That 'present' $health.Present
    Assert-That 'not verified' (-not $health.Verified)
    Assert-Equal 'and the row reads as specified' `
        '  Restart        Configured    automatic startup enabled' (Get-StatusRowText -Health $health)
}

function Test-VerifiedRow {
    Start-TestCase 'a mechanism that has recovered a real restart reads Verified'

    Reset-Machine
    $installation = New-TestInstallation
    $null = Register-TestStartupTask -Installation $installation
    $null = Write-DeltaRebootTestResult -InstallRoot $installation.InstallRoot -Result 'reachable' `
        -Detail 'Recovered unattended in 61s.' -Mechanism 'startup-task' -Trigger 'boot' -BootedAt (Get-Date).AddMinutes(-2)

    $health = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-Equal 'state' 'Verified' $health.State
    Assert-Equal 'detail' 'automatic startup verified' $health.Detail
    Assert-That 'verified' $health.Verified
    Assert-Equal 'and the row reads as specified' `
        '  Restart        Verified      automatic startup verified' (Get-StatusRowText -Health $health)

    $recorded = Get-RecordedStartup -InstallRoot $installation.InstallRoot
    Assert-That 'the record says which trigger did it' ([string]$recorded.bootTest.trigger -eq 'boot')
}

function Test-MissingTaskIsNeverConfigured {
    Start-TestCase 'the record alone can never produce Configured'

    Reset-Machine
    # Exactly the reported state: the installer recorded a configured
    # mechanism, and Get-ScheduledTask shows no DELTA startup task.
    $installation = New-TestInstallation -UnattendedStartup @{
        configured   = $true
        mechanism    = 'startup-task'
        taskName     = $Script:TaskName
        rebootTested = $false
        bootTest     = $null
    }

    $health = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-Equal 'the row does not say Configured' 'Not set up' $health.State
    Assert-That 'and it says the record disagrees with the host' ($health.Detail -match '(?i)recorded as configured, but not registered')
    Assert-That 'present is false' (-not $health.Present)
    Assert-That 'verified is false' (-not $health.Verified)
}

function Test-MissingTaskIsNeverVerified {
    Start-TestCase 'a stale rebootTested cannot survive the task going away'

    Reset-Machine
    $installation = New-TestInstallation -UnattendedStartup @{
        configured   = $true
        mechanism    = 'startup-task'
        rebootTested = $true
        bootTest     = [PSCustomObject]@{ at = '2026-01-01T00:00:00Z'; result = 'reachable'; trigger = 'boot' }
    }

    $health = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-Equal 'a host with no task is Not set up whatever the record claims' 'Not set up' $health.State
    Assert-That 'and is not verified' (-not $health.Verified)
}

function Test-FailedUnattendedStartClearsVerification {
    Start-TestCase 'an unattended start that fails withdraws the verification'

    Reset-Machine
    $installation = New-TestInstallation
    $null = Register-TestStartupTask -Installation $installation
    $null = Write-DeltaRebootTestResult -InstallRoot $installation.InstallRoot -Result 'reachable' -Mechanism 'startup-task' -Trigger 'boot'

    $before = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-Equal 'verified to begin with' 'Verified' $before.State

    $null = Write-DeltaRebootTestResult -InstallRoot $installation.InstallRoot -Result 'unreachable' `
        -Detail 'Stage engine: the Docker engine did not become available.' -Mechanism 'startup-task' -Trigger 'boot'

    $after = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-Equal 'and Configured afterwards, not Verified' 'Configured' $after.State
    Assert-That 'the mechanism is still registered' $after.Present
}

# ---------------------------------------------------------------------------
# 4. Self-repair from the management screen
# ---------------------------------------------------------------------------

function Test-ManagementRepairsMissingMechanism {
    Start-TestCase 'the management screen repairs an installation that has no task'

    Reset-Machine -Overrides @{ DockerServiceStartMode = 'Auto' }
    # An installation left behind by the version that reported "vendor": the
    # record claims it is configured, and nothing is registered.
    $installation = New-TestInstallation -UnattendedStartup @{
        configured             = $true
        mechanism              = 'vendor'
        dockerDesktopAutoStart = $true
        composeRestartPolicy   = 'unless-stopped'
        rebootTested           = $false
        bootTest               = $null
    }
    $configuration = [PSCustomObject]@{ ProjectName = $Script:ProjectName }

    $repair = Initialize-DeltaStartupMechanism -InstallRoot $installation.InstallRoot `
        -ScriptRoot $installation.ScriptRoot -Configuration $configuration

    Assert-That 'the repair succeeded' $repair.Succeeded
    Assert-Equal 'and created the task' 'created' $repair.Action

    $health = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-Equal 'the row now reads Configured' 'Configured' $health.State

    $recorded = Get-RecordedStartup -InstallRoot $installation.InstallRoot
    Assert-Equal 'the recorded mechanism is corrected' 'startup-task' ([string]$recorded.mechanism)
    Assert-Equal 'and unrelated recorded facts are preserved' 'unless-stopped' ([string]$recorded.composeRestartPolicy)

    Start-TestCase 'and does nothing at all on a healthy installation'

    $again = Initialize-DeltaStartupMechanism -InstallRoot $installation.InstallRoot `
        -ScriptRoot $installation.ScriptRoot -Configuration $configuration
    Assert-Equal 'the second pass is a no-op' 'unchanged' $again.Action
    Assert-Equal 'and Task Scheduler was written to once in total' 1 $Script:Calls.Registered
}

function Test-StartupScriptRecordsItsOwnFailure {
    <#
      The one test that runs the real bin\start-delta.ps1, as a real child
      process, on the exact command line the task registers.

      It is pointed at a registered installation with no .env, so the recovery
      stops at the configuration stage and nothing is started, no Docker is
      touched and no container exists to act on. What is being checked is the
      wiring either side of that: that the task's command line binds to the
      script's parameters at all, that the run completes without stopping on a
      prompt, and that an unattended start which failed withdraws a previous
      claim that automatic startup works.
    #>
    Start-TestCase 'the real startup script records a failed unattended start'

    Reset-Machine
    $installation = New-TestInstallation -UnattendedStartup @{
        configured   = $true
        mechanism    = 'startup-task'
        rebootTested = $true
        bootTest     = [PSCustomObject]@{ at = '2026-01-01T00:00:00Z'; result = 'reachable'; trigger = 'boot' }
    }

    # The repository's own copy, not the fixture's: the script resolves its
    # libraries as one level up from bin\, so it has to run from a tree that
    # has them.
    $scriptPath = Join-Path -Path $Script:ProjectRoot -ChildPath 'bin\start-delta.ps1'
    $arguments = Get-DeltaStartupTaskArguments -ScriptPath $scriptPath -InstallRoot $installation.InstallRoot
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $installation.InstallRoot 'out.txt') `
        -RedirectStandardError (Join-Path $installation.InstallRoot 'err.txt')

    # 10 is "the installation could not be read", which is what a root with no
    # .env is. Anything else - a binding error, a prompt, a crash - is not.
    Assert-Equal 'it exits with the no-installation code, so the command line bound' 10 $process.ExitCode

    $recorded = Get-RecordedStartup -InstallRoot $installation.InstallRoot
    Assert-Equal 'the failure is recorded' 'unreachable' ([string]$recorded.bootTest.result)
    Assert-That 'and the previous verification is withdrawn' (-not [bool]$recorded.rebootTested)
    Assert-That 'the recorded detail names the stage it stopped at' ([string]$recorded.bootTest.detail -match '(?i)configuration')

    # And with the mechanism registered, the screen falls back to Configured -
    # the task is there, it just has not demonstrated anything.
    $null = Register-TestStartupTask -Installation $installation
    $health = Test-DeltaStartupMechanism -ProjectName $Script:ProjectName -InstallRoot $installation.InstallRoot
    Assert-Equal 'so the row reads Configured, not Verified' 'Configured' $health.State
}

function Test-RotationTaskIsUntouched {
    Start-TestCase 'nothing here touches the NGINX log-rotation task'

    Reset-Machine
    $installation = New-TestInstallation
    $rotationName = "DELTA (Docker) - $Script:ProjectName - NGINX log rotation"
    $Script:Tasks[$rotationName] = [PSCustomObject]@{ TaskName = $rotationName }

    $null = Invoke-DeltaStartupConfiguration -InstallRoot $installation.InstallRoot `
        -ScriptRoot $installation.ScriptRoot -ProjectName $Script:ProjectName -RestartPolicy $null
    $null = Initialize-DeltaStartupMechanism -InstallRoot $installation.InstallRoot `
        -ScriptRoot $installation.ScriptRoot -Configuration ([PSCustomObject]@{ ProjectName = $Script:ProjectName })

    Assert-That 'the rotation task is still registered' ($Script:Tasks.ContainsKey($rotationName))
    Assert-Equal 'and nothing was unregistered' 0 $Script:Calls.Unregistered
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

$null = New-Item -ItemType Directory -Path $Script:WorkRoot -Force
Write-TestLine ''
Write-TestLine 'DELTA unattended startup tests' 'White'
Write-TestLine "Work root: $Script:WorkRoot" 'DarkGray'

try {
    Test-DockerServiceDoesNotCount
    Test-VendorMechanismNeverSuppressesRegistration
    Test-TaskTriggersAndPrincipal
    Test-TaskRunsNonInteractively
    Test-BootOnlyTaskIsRepaired
    Test-MovedInstallerIsRepaired
    Test-RegistrationIsIdempotent
    Test-RegistrationFailureIsNotConfigured
    Test-ConfiguredRow
    Test-VerifiedRow
    Test-MissingTaskIsNeverConfigured
    Test-MissingTaskIsNeverVerified
    Test-FailedUnattendedStartClearsVerification
    Test-ManagementRepairsMissingMechanism
    Test-StartupScriptRecordsItsOwnFailure
    Test-RotationTaskIsUntouched
}
finally {
    if (Test-Path -LiteralPath $Script:WorkRoot) {
        Remove-Item -LiteralPath $Script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-TestLine ''
Write-TestLine "Passed: $Script:Passed" 'Green'
if ($Script:Failed -gt 0) {
    Write-TestLine "Failed: $Script:Failed" 'Red'
    exit 1
}
Write-TestLine 'Failed: 0' 'Green'
exit 0
