#Requires -Version 5.1
<#
.SYNOPSIS
    Brings an installed DELTA back up. Run at Windows startup by the scheduled
    task the installer registers, and usable by hand at any time.

.DESCRIPTION
    Its whole job is one recovery, once:

      1. start Docker if it is not running, and wait for the Linux engine
      2. check the persistent data is still there
      3. bring the registered Compose project up, health-gated, in order
      4. confirm DELTA answers over HTTP
      5. write what happened to <InstallRoot>\logs\installer\startup.log

    Then it exits. It is deliberately NOT a daemon, a service, or a
    supervisor: it does not watch containers, does not restart anything that
    later fails, and holds no lifecycle. Docker's own restart policy
    (unless-stopped on all three services) is what keeps the stack up once the
    engine is running; this script exists only because nothing on a per-user
    Docker Desktop host starts the engine before somebody signs in.

    It changes no configuration. It does not generate .env or
    docker-compose.yml, does not pull or repin images, does not touch
    credentials, does not back anything up, and cannot create the persistent
    data it checks for - if the database volume has gone, it stops and says so
    rather than letting an empty cluster be initialised over a registered
    installation.

.PARAMETER InstallRoot
    The installation to start. Defaults to C:\DELTA.

.PARAMETER EngineTimeoutSeconds
    How long to wait for the Docker engine. Defaults to 300, as A§5.4.

.PARAMETER SkipEngineStart
    Do not try to start Docker; only use it if it is already running. For
    diagnosing the stack half of a recovery on its own.

.PARAMETER FromStartupTask
    Set by the registered scheduled task, and by nothing else. It means "this
    run was started by the automatic startup mechanism, not by a person", and
    it is what allows the outcome to be recorded in .delta-install.json as
    evidence that automatic startup does or does not work on this host. A hand
    run proves nothing about what happens at boot, so a hand run must not be
    able to write that record.

.NOTES
    Exit codes:
      0  DELTA is running and answered over HTTP
      1  an unhandled failure
      2  not elevated
     10  the installation could not be read
     11  the Docker engine did not become available
     12  the persistent data check stopped the start
     13  the stack did not come up, or did not answer
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\DELTA',
    [int]$EngineTimeoutSeconds = 300,
    [switch]$SkipEngineStart,
    [switch]$FromStartupTask
)

$ErrorActionPreference = 'Stop'

# This script lives in bin\, so the installer root - the directory holding
# setup.ps1, lib\ and templates\ - is one level up from it. Everything below
# resolves from there, never from the caller's working directory.
$Script:DeltaScriptRoot = Split-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Path -Parent) -Parent

# The same library set and the same integrity check setup.ps1 makes: a
# half-loaded library must be a refusal to start, not a CommandNotFoundException
# discovered part-way through. That matters more here than anywhere else,
# because nobody is watching this run.
$Script:DeltaStartupLibraries = [ordered]@{
    'Delta.Common.ps1'  = 'Write-Step'
    'Delta.Config.ps1'  = 'Read-DeltaEnvFile'
    'Delta.Docker.ps1'  = 'Get-DeltaDockerEngineState'
    'Delta.Network.ps1' = 'Get-DeltaPublicUrl'
    'Delta.Stack.ps1'   = 'Start-DeltaStack'
    'Delta.Manage.ps1'  = 'Start-DeltaInstallation'
}

foreach ($library in $Script:DeltaStartupLibraries.Keys) {
    $libraryPath = Join-Path -Path $Script:DeltaScriptRoot -ChildPath "lib\$library"
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        Write-Host "Required library not found: $libraryPath" -ForegroundColor Red
        exit 1
    }
    . $libraryPath
}
foreach ($library in $Script:DeltaStartupLibraries.Keys) {
    $required = $Script:DeltaStartupLibraries[$library]
    if (-not (Get-Command -Name $required -CommandType Function -ErrorAction SilentlyContinue)) {
        Write-Host "Required library did not load correctly: lib\$library (it should define $required)" -ForegroundColor Red
        Write-Host 'Nothing has been changed on this machine.'
        exit 1
    }
}

# Exit codes, named where they are used.
$Script:DeltaStartupExitOk           = 0
$Script:DeltaStartupExitFailure      = 1
$Script:DeltaStartupExitNotElevated  = 2
$Script:DeltaStartupExitNoInstall    = 10
$Script:DeltaStartupExitNoEngine     = 11
$Script:DeltaStartupExitDataMissing  = 12
$Script:DeltaStartupExitStackFailed  = 13

$exitCode = $Script:DeltaStartupExitOk
$logDirectory = Join-Path -Path $InstallRoot -ChildPath 'logs\installer'

# No terminal animation from here, ever. This script's normal caller is a
# scheduled task at boot with nobody watching it, and its output is the
# appended startup.log an operator reads afterwards - the one file where a
# stream of animation frames would be worst. The console probe would refuse
# most of these sessions on its own; saying it outright means it does not
# depend on how the task happens to have been registered.
Set-DeltaActivityMode -Mode 'off'

try {
    # One appended file, not one per boot: after a restart the operator needs
    # to read a history, not to work out which of forty transcripts was this
    # morning's.
    $null = Start-DeltaLog -Directory $logDirectory -Name 'startup' -Append

    $boot = $null
    try { $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }

    Show-Section -Title 'DELTA startup' -Subtitle "Installation root: $InstallRoot"
    Write-Detail "Started by $(if ($FromStartupTask) { 'the registered DELTA startup task' } else { 'hand' })"
    Write-Detail "Running as $([Environment]::UserDomainName)\$([Environment]::UserName), session $((Get-Process -Id $PID).SessionId), elevated=$(Test-IsAdministrator)"
    if ($boot) {
        Write-Detail "Windows last booted $($boot.ToString('yyyy-MM-dd HH:mm:ss')) ($([int]((Get-Date) - $boot).TotalSeconds)s ago)"
    }

    if (-not (Test-IsAdministrator)) {
        # Not fatal to Docker as such, but the installer's own operations
        # assume elevation, and a task registered by the installer always has
        # it. Being here without it means something re-registered the task.
        Write-DeltaWarning 'This process is not elevated. Startup may fail on operations that require it.'
    }

    $cli = Initialize-DeltaDockerPath
    if ($cli.Repaired) {
        Write-Detail "The docker CLI was not on PATH for this process; using $($cli.Path)"
    }
    elseif (-not $cli.Resolved) {
        Write-DeltaWarning 'The docker CLI could not be found. DELTA cannot be started from here.'
    }

    $start = Start-DeltaInstallation -InstallRoot $InstallRoot `
        -EngineTimeoutSeconds $EngineTimeoutSeconds -SkipEngineStart:$SkipEngineStart

    if ($start.Succeeded) {
        Write-Detail "Recovery complete in $($start.Elapsed)s."
        $exitCode = $Script:DeltaStartupExitOk
    }
    else {
        Write-DeltaFailure "DELTA did not start: $($start.Reason)"
        Write-Detail "Stage reached: $($start.Stage)"
        Write-Detail 'Nothing was deleted, reconfigured or regenerated.'
        $exitCode = switch ($start.Stage) {
            'configuration' { $Script:DeltaStartupExitNoInstall }
            'engine'        { $Script:DeltaStartupExitNoEngine }
            'precheck'      { $Script:DeltaStartupExitDataMissing }
            default         { $Script:DeltaStartupExitStackFailed }
        }
    }

    # Record what the automatic mechanism achieved, but only when the automatic
    # mechanism is what ran this. This is the only place anything writes that
    # record, and its whole value is that it describes an unattended recovery
    # that actually happened rather than one that was configured.
    #
    # A failure is recorded as faithfully as a success: an unattended start
    # that did not work clears any previous claim that it did, because whatever
    # was true of an earlier boot is no longer true of this host.
    if ($FromStartupTask) {
        # Which trigger fired is inferred from how long the machine has been
        # up, because Task Scheduler does not tell the action which of its
        # triggers started it. The boot trigger runs a minute after boot, so a
        # run this close to one came from it; anything later came from the
        # logon trigger. It is a label on the evidence, not the evidence.
        $trigger = 'unknown'
        if ($boot) {
            $sinceBoot = ((Get-Date) - $boot).TotalMinutes
            $trigger = if ($sinceBoot -le 15) { 'boot' } else { 'logon' }
        }

        # A success may be recorded as verification ONLY if this run actually
        # brought the engine up. That is the whole difference between "the
        # startup mechanism works" and "the startup mechanism ran on a machine
        # where there was nothing to do". A Windows restart always stops Docker
        # Desktop, so a genuine post-restart run finds the engine down and
        # starts it; a task somebody kicked off by hand on a healthy host finds
        # it already running and has demonstrated nothing. Without this,
        # Start-ScheduledTask would be enough to make the screen say Verified,
        # and this whole change is about not making claims like that.
        #
        # A failure is recorded either way. Under-claiming is safe; the failure
        # is real and the operator needs to see it.
        if ($start.Succeeded -and -not $start.EngineStarted) {
            Write-Detail 'The Docker engine was already running, so this run recovered nothing and is not recorded as evidence that automatic startup works.'
        }
        else {
            $detail = if ($start.Succeeded) {
                "Recovered unattended in $($start.Elapsed)s: started the Docker engine and DELTA answered at $($start.Url)."
            }
            else {
                "Stage $($start.Stage): $($start.Reason)"
            }

            $record = @{
                InstallRoot = $InstallRoot
                Result      = $(if ($start.Succeeded) { 'reachable' } else { 'unreachable' })
                Detail      = $detail
                Mechanism   = 'startup-task'
                Trigger     = $trigger
            }
            if ($boot) { $record['BootedAt'] = $boot }

            $null = Write-DeltaRebootTestResult @record
            if ($start.Succeeded) {
                Write-Detail "Automatic startup verified: the $trigger trigger started Docker and brought DELTA back. Recorded in the installation state."
            }
            else {
                Write-Detail 'This unattended start failed and has been recorded as such; automatic startup is no longer reported as verified.'
            }
        }
    }
}
catch {
    $exitCode = $Script:DeltaStartupExitFailure
    Write-DeltaFailure "The startup script stopped with an error: $($_.Exception.Message)"
    Write-DeltaLogLine -Message $_.ScriptStackTrace -Level 'ERROR'
}
finally {
    Stop-DeltaLog -ExitCode $exitCode
}

exit $exitCode
