#Requires -Version 5.1
<#
.SYNOPSIS
    DELTA Windows Docker Uninstaller - removes the DELTA runtime, and preserves
    your data unless you explicitly ask for it to be deleted.

.DESCRIPTION
    The counterpart to setup.ps1, and deliberately not its mirror image.
    setup.ps1 builds a running installation out of nothing; this script takes
    the running part away and, by default, leaves everything that would be
    painful to lose exactly where it is.

    Two modes, chosen from a menu:

      1. Uninstall and preserve data (the default, and what almost everybody
         wants). Removes the three containers, the Compose network, the
         scheduled task that starts DELTA at boot, the scheduled task that
         rotates the NGINX logs, and this installation's firewall rules. Keeps
         the PostgreSQL data volume, uploads, backups, certificates, logs,
         .env and docker-compose.yml. setup.ps1 run afterwards against the same
         installation root rebuilds the runtime over the preserved data.

      2. Complete removal. Everything above, plus the database volume and the
         whole installation root. Enumerates exactly what will be destroyed,
         offers a final verified backup written outside the installation root,
         and then requires the word DELETE to be typed in full. Nothing else -
         not y, not yes, not Enter - authorises it.

    What this script never removes, in either mode: Docker Desktop, WSL, Hyper-V,
    any Windows optional feature, Git, PowerShell, any other Compose project, or
    any container, volume, network, scheduled task or firewall rule that this
    installation did not create. setup.ps1 being able to install Docker Desktop
    does not make Docker Desktop DELTA's property - it is shared infrastructure
    that other things on this machine may depend on.

    Ownership is read from <InstallRoot>\.delta-install.json, the record of what
    a previous run actually did, with .env as a secondary source for the two
    identifiers that appear in both. Nothing is removed because its name looks
    like DELTA's. An installation root with no readable state file is refused
    rather than guessed at, which is what stops a mistyped -InstallRoot from
    becoming a recursive delete of somebody's documents.

    There is no -Force. A switch that skips the confirmation would exist purely
    to make the irreversible operation easy to automate, and that is the one
    thing it should not be.

.PARAMETER InstallRoot
    The installation to remove. Defaults to C:\DELTA.

.PARAMETER LogDirectory
    Directory for the transcript. Defaults to logs\installer next to this
    script - not inside the installation root, which complete removal deletes.

.PARAMETER Mode
    preserve-data | complete. Supplied non-interactively, it selects the mode
    without showing the menu. `complete` still requires the typed confirmation
    unless -ConfirmDataDeletion is also given.

.PARAMETER ConfirmDataDeletion
    The non-interactive equivalent of typing DELETE. It exists for scripted
    teardown of test installations and is named so that nobody adds it to a
    command line by accident. It has no effect in preserve-data mode, and it
    does not bypass the ownership checks: an unregistered installation root is
    still refused.

.PARAMETER FinalBackupPath
    Where a final backup is written on the complete-removal path. Must be
    outside the installation root. Without it, and interactively, the script
    asks.

.PARAMETER SkipFinalBackup
    Do not offer or take a final backup before complete removal.

.NOTES
    Exit codes:
      0  the uninstall completed, or there was nothing installed to remove
      1  unhandled failure
      2  not elevated
      3  the installation root is not a registered DELTA installation
      6  the operator cancelled
      7  PARTIAL - something could not be removed or could not be checked
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\DELTA',
    [string]$LogDirectory,
    [ValidateSet('preserve-data', 'complete')][string]$Mode,
    [switch]$ConfirmDataDeletion,
    [string]$FinalBackupPath,
    [switch]$SkipFinalBackup,
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
    'Delta.Manage.ps1'    = 'Unregister-DeltaLogRotationTask'
    'Delta.Configure.ps1' = 'Invoke-DeltaSmtpConfiguration'
    'Delta.Uninstall.ps1' = 'Invoke-DeltaUninstall'
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

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

function Test-DeltaUninstallElevation {
    <#
      Checked before anything is inspected. Scheduled tasks, firewall rules and
      an ACL-restricted .env all require it, and discovering that half-way
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

function Get-DeltaUninstallDockerAvailability {
    <#
      Whether Docker can be talked to at all.

      This is not a prerequisite check. An uninstall that cannot reach Docker
      can still remove the scheduled tasks, the firewall rules and the files -
      all of which are Windows-side and all of which would otherwise outlive
      the installation. What it must not do is claim the containers are gone
      because it could not look, so the answer is threaded through the whole
      run and turns those rows into "could not verify" instead of "absent".
    #>
    Write-Step 'Checking Docker'

    $engine = Get-DeltaDockerEngineState
    if ($engine.Status -eq 'ready') {
        Write-Detail "Docker engine $($engine.ServerVersion) is running."
        return $true
    }

    Write-DeltaWarning "The Docker engine is not usable ($($engine.Status)): $($engine.Detail)"
    Write-Detail 'Containers, the Compose network and the database volume cannot be removed'
    Write-Detail 'or inspected in this run. Everything on the Windows side still can be, and'
    Write-Detail 'what remains will be named at the end.'
    return $false
}

function Show-DeltaUninstallNotInstalled {
    <#
      The "already gone" report, which is a success and is worded like one.

      An uninstaller that fails with a stack trace because the thing is already
      uninstalled has misunderstood its job: the operator asked for a machine
      with no DELTA runtime on it, and that is what they have.
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

function Show-DeltaAlreadyUninstalled {
    <#
      A second run after a preserve-data uninstall. The runtime is already
      gone; what is left is the data the operator chose to keep, and the two
      things they can do with it. Saying that is more useful than reporting
      "nothing to do" over 200 MB of preserved database.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Survey
    )

    Write-Host ''
    Write-Success 'The DELTA runtime is already uninstalled. Nothing was changed.'
    Write-Host ''
    Write-Detail "Uninstalled   $($Target.PreviousUninstall.at) ($($Target.PreviousUninstall.mode))"
    Write-Detail ''
    Write-Detail 'Preserved data is still here:'
    if ($Survey.VolumePresent) { Write-Detail "  the database    volume $($Target.PgDataVolume)" }
    foreach ($directory in $Survey.Directories) {
        if (-not $directory.Exists -or $directory.Items -eq 0) { continue }
        Write-Detail ("  {0,-14} {1}, {2} file(s)" -f $directory.Name, (Format-DeltaByteSize $directory.Bytes), $directory.Items)
    }
    Write-Detail ''
    Write-Detail 'To bring DELTA back with this data:'
    Write-Detail "    .\setup.ps1 -InstallRoot `"$($Target.InstallRoot)`""
    Write-Detail ''
    Write-Detail 'To delete the preserved data as well, run this script again and choose'
    Write-Detail 'complete removal.'
}

function Test-DeltaUninstallReconciled {
    <#
      Whether there is anything left for this script to do.

      Deliberately a question about the machine and not about the state file: a
      previous run that recorded a preserve-data uninstall may still have left
      a firewall rule behind, and this must return false in that case so the
      rerun finishes the job. "Already uninstalled" means every removable
      resource is actually absent - not that something once said so.
    #>
    param([Parameter(Mandatory)][object]$Survey)

    if ($Survey.DockerAvailable) {
        if (@($Survey.Containers).Count -gt 0) { return $false }
        if ($Survey.NetworkPresent) { return $false }
    }
    if ($Survey.StartupTask -or $Survey.RotationTask) { return $false }
    if ($Survey.HttpRule -or $Survey.HttpsRule) { return $false }
    return $true
}

# ---------------------------------------------------------------------------
# main
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
        else {
            $dockerAvailable = Get-DeltaUninstallDockerAvailability
            $survey = Get-DeltaUninstallSurvey -Target $target -DockerAvailable $dockerAvailable

            $reconciled = Test-DeltaUninstallReconciled -Survey $survey
            $previouslyUninstalled = ($null -ne $target.PreviousUninstall)

            if ($reconciled -and $previouslyUninstalled -and -not $Mode) {
                # Already reconciled, and the state file says why. Interactively
                # this is the end of the run; a caller that explicitly asked for
                # complete removal still gets to ask for it below.
                Show-DeltaAlreadyUninstalled -Target $target -Survey $survey
            }
            else {
                Show-DeltaUninstallPlan -Target $target -Survey $survey

                $chosen = $Mode
                if (-not $chosen) {
                    if ($NonInteractive) {
                        Write-Host ''
                        Write-DeltaFailure 'No mode was chosen.'
                        Write-Detail '-NonInteractive was supplied without -Mode, and this script will not pick'
                        Write-Detail 'between preserving and destroying data on the operator''s behalf.'
                        $chosen = $null
                    }
                    else {
                        $chosen = Read-DeltaUninstallMode -Target $target
                    }
                }

                if (-not $chosen) {
                    Write-Host ''
                    Write-Detail 'Cancelled. Nothing was changed.'
                    $exitCode = $Script:DeltaExitOperatorDeclined
                }
                else {
                    $proceed = $true
                    $backupDestination = $null

                    if ($chosen -eq 'complete') {
                        # Order matters: the backup is offered before the
                        # confirmation, so the operator decides about the
                        # safety net while they still have one, and the
                        # confirmation is the last thing between them and the
                        # deletion.
                        if (-not $SkipFinalBackup) {
                            if ($FinalBackupPath) {
                                $backupDestination = $FinalBackupPath
                            }
                            elseif (-not $NonInteractive) {
                                $choice = Read-DeltaFinalBackupChoice -Target $target -Survey $survey
                                if ($choice.Wanted) { $backupDestination = $choice.Destination }
                                if ($choice.Reason) { Write-Host ''; Write-Detail $choice.Reason }
                            }
                        }

                        if ($ConfirmDataDeletion) {
                            Write-Host ''
                            Write-DeltaWarning '-ConfirmDataDeletion was supplied, so the typed confirmation is not shown.'
                            Write-DeltaWarning "The database volume $($target.PgDataVolume) and $($target.InstallRoot) will be deleted."
                        }
                        elseif ($NonInteractive) {
                            Write-Host ''
                            Write-DeltaFailure 'Complete removal was requested non-interactively without -ConfirmDataDeletion.'
                            Write-Detail 'Nothing was deleted.'
                            $proceed = $false
                        }
                        else {
                            $proceed = Read-DeltaDestructiveConfirmation -Target $target -Survey $survey
                            if (-not $proceed) {
                                Write-Host ''
                                Write-Detail 'Cancelled. Nothing was deleted - the installation is exactly as it was.'
                            }
                        }
                    }

                    if (-not $proceed) {
                        $exitCode = $Script:DeltaExitOperatorDeclined
                    }
                    else {
                        Write-Host ''
                        $result = Invoke-DeltaUninstall -Target $target -Mode $chosen `
                            -DockerAvailable $dockerAvailable -FinalBackupDestination $backupDestination

                        Show-DeltaUninstallOutcome -Result $result -Target $target
                        if ($result.Outcome -ne 'success') {
                            $exitCode = $Script:DeltaExitStackFailed
                        }
                    }
                }
            }
        }
    }

    Write-Host ''
}
catch {
    $exitCode = $Script:DeltaExitFailure
    Write-DeltaFailure ''
    Write-DeltaFailure 'The uninstaller stopped with an error.'
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
