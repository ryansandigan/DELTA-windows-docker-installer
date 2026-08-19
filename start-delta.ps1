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
    [switch]$SkipEngineStart
)

$ErrorActionPreference = 'Stop'

$Script:DeltaScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

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

try {
    # One appended file, not one per boot: after a restart the operator needs
    # to read a history, not to work out which of forty transcripts was this
    # morning's.
    $null = Start-DeltaLog -Directory $logDirectory -Name 'startup' -Append

    $boot = $null
    try { $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }

    Show-Section -Title 'DELTA startup' -Subtitle "Installation root: $InstallRoot"
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
