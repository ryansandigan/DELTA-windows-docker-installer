#Requires -Version 5.1
<#
.SYNOPSIS
    DELTA Windows Docker Uninstaller - archives everything, then removes DELTA.

.DESCRIPTION
    The counterpart to setup.ps1. It does one thing, in one order, and the
    order is the whole design:

        1. Prove this is a DELTA installation this installer created.
        2. Take a fresh database backup with the installer's own verified
           pg_dump implementation.
        3. Stop the containers so the files being archived are not changing.
        4. Archive the entire installation root - including that fresh dump -
           to C:\DELTA-backups\DELTA-<timestamp>.zip.
        5. Verify that archive by opening it and confirming what must be in it
           actually is, down to reading the database dump's first bytes back
           out of it.
        6. Only then remove the containers, the network, the database volume,
           the scheduled tasks, the firewall rules and the installation
           directory.

    If step 2, 4 or 5 fails, the run stops and nothing is removed. That is not
    a policy this script checks - it is the shape of the code. The backup
    function throws rather than returning a status, and the removal function
    cannot be called without the [Delta.VerifiedArchive] object that only a
    successful backup produces. There is no "continue anyway", and no switch
    that skips the backup.

    The final state after a successful run:

        C:\DELTA                       gone
        C:\DELTA-backups\DELTA-*.zip   present and verified

    The archive is how your data is preserved. Everything an operator would
    miss is in it: the database dump, uploads, certificates, .env,
    docker-compose.yml, the generated NGINX configuration, the installation
    record, every previous backup and every log.

    What this script never removes: Docker Desktop, WSL, Hyper-V, any Windows
    optional feature, Git, PowerShell, any other Compose project, or any
    container, volume, network, scheduled task or firewall rule that this
    installation did not create. setup.ps1 being able to install Docker
    Desktop does not make Docker Desktop DELTA's property.

    Ownership is read from <InstallRoot>\.delta-install.json, the record of
    what a previous run actually did. Nothing is removed because its name
    looks like DELTA's, and an installation root with no readable state file
    is refused rather than guessed at - which is what stops a mistyped
    -InstallRoot from becoming a recursive delete of somebody's documents.

.PARAMETER InstallRoot
    The installation to remove. Defaults to C:\DELTA.

.PARAMETER BackupRoot
    Where the archive is written. Defaults to C:\DELTA-backups, the same
    convention the native DELTA uninstaller uses. It must not be inside the
    installation root; that is refused rather than worked around.

.PARAMETER LogDirectory
    Directory for the transcript. Defaults to logs\installer next to this
    script - never inside the installation root, which this script deletes.

.PARAMETER ConfirmDataDeletion
    The non-interactive equivalent of typing DELETE. It exists for scripted
    teardown and is named so that nobody adds it to a command line by
    accident. It does not skip the backup - nothing does - and it does not
    bypass the ownership checks.

.PARAMETER NonInteractive
    Never prompt. Requires -ConfirmDataDeletion to do anything.

.NOTES
    Exit codes:
      0  DELTA was removed, or there was nothing installed to remove
      1  the run stopped before removing anything - including because the
         database backup or the archive verification failed. Nothing was
         removed and the installation is intact.
      2  not elevated
      3  the installation root is not a registered DELTA installation
      4  Docker is not usable, so the mandatory backup cannot be taken
      6  the operator cancelled
      7  PARTIAL - the backup succeeded and something could not be removed
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\DELTA',
    [string]$BackupRoot,
    [string]$LogDirectory,
    [switch]$ConfirmDataDeletion,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Library loading
#
# Identical in shape to setup.ps1's, and for the identical reason: a library
# that is missing or from a different version of the installer should be a
# refusal to start, not a CommandNotFoundException half-way through removing
# things.
# ---------------------------------------------------------------------------

$Script:DeltaScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

$Script:DeltaLibraries = [ordered]@{
    'Delta.Common.ps1'    = 'Write-Step'
    'Delta.Config.ps1'    = 'Read-DeltaInstallState'
    'Delta.Docker.ps1'    = 'Get-DeltaStartupTaskName'
    'Delta.Stack.ps1'     = 'Invoke-DeltaCompose'
    'Delta.Network.ps1'   = 'Get-DeltaFirewallRuleName'
    'Delta.Manage.ps1'    = 'New-DeltaDatabaseBackup'
    'Delta.Configure.ps1' = 'Invoke-DeltaSmtpConfiguration'
    'Delta.Uninstall.ps1' = 'Backup-DeltaInstallation'
}

foreach ($library in $Script:DeltaLibraries.Keys) {
    $libraryPath = Join-Path -Path $Script:DeltaScriptRoot -ChildPath "lib\$library"
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        Write-Host "Required library not found: $libraryPath" -ForegroundColor Red
        Write-Host 'Run uninstall.ps1 from the directory it was distributed in, with its lib\ folder intact.'
        exit 1
    }
    . $libraryPath
}

foreach ($library in $Script:DeltaLibraries.Keys) {
    $required = $Script:DeltaLibraries[$library]
    if (-not (Get-Command -Name $required -CommandType Function -ErrorAction SilentlyContinue)) {
        Write-Host "Required library did not load correctly: lib\$library" -ForegroundColor Red
        Write-Host "It should define $required, and after loading it that function does not exist."
        Write-Host 'Nothing has been changed on this machine. Reinstall the installer files as a set.'
        exit 1
    }
}

if (-not $LogDirectory) {
    $LogDirectory = Join-Path -Path $Script:DeltaScriptRoot -ChildPath 'logs\installer'
}
if (-not $BackupRoot) {
    $BackupRoot = $Script:DeltaUninstallBackupRoot
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

function Test-DeltaUninstallElevation {
    <#
      Checked before anything is inspected. Scheduled tasks, firewall rules
      and an ACL-restricted .env all require it, and discovering it half-way
      through would leave an installation in a state neither this script nor
      setup.ps1 designed for.
    #>
    Write-Step 'Checking privileges'
    if (Test-IsAdministrator) {
        Write-Detail 'Running elevated.'
        return $true
    }

    Write-DeltaFailure ''
    Write-DeltaFailure 'This uninstaller must run as Administrator.'
    Write-Detail ''
    Write-Detail 'Close this window, then start Windows PowerShell with "Run as administrator"'
    Write-Detail "and run:  cd `"$Script:DeltaScriptRoot`"  then  .\uninstall.ps1"
    Write-Detail ''
    return $false
}

function Test-DeltaUninstallDockerReady {
    <#
      Docker is a hard prerequisite for this script, and that follows from the
      backup rule rather than from anything about removal.

      The database lives in a Docker volume. Backing it up means running
      pg_dump inside the db container. If the engine is unreachable there is
      no way to produce the verified dump the archive must contain - so there
      is no way to reach a state where deletion is permitted. Reporting that
      plainly is better than removing the scheduled tasks and firewall rules
      of an installation that then cannot be finished.

      Nothing is changed on this path.
    #>
    Write-Step 'Checking Docker'

    $engine = Get-DeltaDockerEngineState
    if ($engine.Status -eq 'ready') {
        Write-Detail "Docker engine $($engine.ServerVersion) is running."
        return $true
    }

    Write-DeltaFailure ''
    Write-DeltaFailure "The Docker engine is not usable ($($engine.Status))."
    Write-Detail $engine.Detail
    Write-Detail ''
    Write-Detail 'DELTA cannot be uninstalled without it, because the database backup that has'
    Write-Detail 'to succeed first runs inside the database container. Start Docker Desktop and'
    Write-Detail 'run this again.'
    Write-Detail ''
    Write-Detail 'Nothing was changed. DELTA is exactly as it was.'
    return $false
}

function Show-DeltaUninstallNotInstalled {
    <#
      The "already gone" report, which is a success and is worded like one.

      An uninstaller that fails with a stack trace because the thing is
      already uninstalled has misunderstood its job: the operator asked for a
      machine with no DELTA on it, and that is what they have.
    #>
    param([Parameter(Mandatory)][object]$Target)

    Write-Host ''
    Write-Success 'No DELTA Docker installation was found. Nothing was changed.'
    Write-Host ''
    Write-Detail $Target.Reason
    Write-Detail ''
    Write-Detail "Looked in:  $($Target.InstallRoot)"
    Write-Detail 'If DELTA is installed somewhere else, name it:'
    Write-Detail '    .\uninstall.ps1 -InstallRoot D:\DELTA'
}

# ---------------------------------------------------------------------------
# main
#
# The gate is expressed here as well as in the library: $archive only exists
# if Backup-DeltaInstallation returned, and Remove-DeltaInstallation will not
# bind anything else to -VerifiedArchive.
# ---------------------------------------------------------------------------

$exitCode = $Script:DeltaExitSuccess

try {
    $logPath = Start-DeltaLog -Directory $LogDirectory -Name 'uninstall'

    Show-Section -Title 'DELTA Docker Uninstaller' -Subtitle $InstallRoot
    if ($logPath) { Write-Detail "Transcript: $logPath" }

    if (-not (Test-DeltaUninstallElevation)) {
        $exitCode = $Script:DeltaExitNotElevated
    }
    else {
        $target = Get-DeltaUninstallTarget -InstallRoot $InstallRoot

        if (-not $target.Registered) {
            # Both "there is nothing here" and "there is something here that
            # this installer did not create" land in the same place, and
            # neither deletes anything. The difference is in the reason, which
            # is printed verbatim.
            Show-DeltaUninstallNotInstalled -Target $target
            $exitCode = if ($target.Exists -and $target.StateFile -and $target.StateFile.Exists) {
                $Script:DeltaExitInvalidInstallRoot
            }
            else {
                $Script:DeltaExitSuccess
            }
        }
        elseif (-not (Test-DeltaUninstallDockerReady)) {
            $exitCode = $Script:DeltaExitPrerequisiteFailed
        }
        else {
            $survey = Get-DeltaUninstallSurvey -Target $target -DockerAvailable $true
            Show-DeltaUninstallPlan -Target $target -Survey $survey -BackupRoot $BackupRoot

            $confirmed = $false
            if ($ConfirmDataDeletion) {
                Write-Host ''
                Write-DeltaWarning '-ConfirmDataDeletion was supplied, so the typed confirmation is not shown.'
                Write-DeltaWarning "$($target.InstallRoot) and the volume $($target.PgDataVolume) will be removed once the archive verifies."
                $confirmed = $true
            }
            elseif ($NonInteractive) {
                Write-Host ''
                Write-DeltaFailure 'Uninstall was requested non-interactively without -ConfirmDataDeletion.'
                Write-Detail 'Nothing was changed.'
            }
            else {
                $confirmed = Read-DeltaUninstallConfirmation -Target $target -Survey $survey -BackupRoot $BackupRoot
                if (-not $confirmed) {
                    Write-Host ''
                    Write-Detail 'Cancelled. Nothing was changed - the installation is exactly as it was.'
                }
            }

            if (-not $confirmed) {
                $exitCode = $Script:DeltaExitOperatorDeclined
            }
            else {
                # ---------------------------------------------------------------
                # The safety gate.
                #
                # Backup-DeltaInstallation either returns a verified archive or
                # throws. There is no third outcome and no status to inspect, so
                # the lines below this one are simply not reached unless the
                # backup and its verification both succeeded.
                # ---------------------------------------------------------------
                Write-Host ''
                $archive = Backup-DeltaInstallation -Target $target -BackupRoot $BackupRoot

                Write-Host ''
                $result = Remove-DeltaInstallation -Target $target -VerifiedArchive $archive -DockerAvailable $true

                Show-DeltaUninstallOutcome -Result $result -Target $target -Archive $archive
                if ($result.Outcome -ne 'success') {
                    $exitCode = $Script:DeltaExitStackFailed
                }
            }
        }
    }

    Write-Host ''
}
catch {
    # Every failure inside Backup-DeltaInstallation arrives here, which is
    # exactly why that function throws instead of returning: this is the
    # abort, and it happens with the installation untouched.
    $exitCode = $Script:DeltaExitFailure
    Write-DeltaFailure ''
    Write-DeltaFailure 'The uninstall stopped. Nothing was removed.'
    Write-Detail $_.Exception.Message
    if ($_.ScriptStackTrace) {
        Write-DeltaLogLine -Message $_.ScriptStackTrace -Level 'ERROR'
    }
    Write-Host ''
}
finally {
    Stop-DeltaLog -ExitCode $exitCode
}

exit $exitCode
