#Requires -Version 5.1
<#
.SYNOPSIS
    DELTA Windows Docker Uninstaller - archives everything, then removes DELTA.

.DESCRIPTION
    The counterpart to setup.ps1. It does one thing, in one order, and the
    order is the whole design:

        1. Prove this is a DELTA installation this installer created.
        2. Make the database reachable. An installation that is stopped is
           still installed, so a stopped database container is started - only
           the database container, never the DELTA application and never NGINX -
           and waited on until PostgreSQL accepts connections.
        3. Take a fresh database backup with the installer's own verified
           pg_dump implementation.
        4. Stop the containers so the files being archived are not changing.
        5. Archive the entire installation root, recursively and with no
           allow-list of known directories - including that fresh dump - to
           C:\DELTA-backups\DELTA-<timestamp>.zip.
        6. Verify that archive against the inventory the walk in step 5
           produced: every file it saw, at the size it saw, plus the entries
           that must exist, plus reading the database dump's first bytes back
           out of it.
        7. Only then remove the containers, the network, the database volume,
           the scheduled tasks, the armed logon continuation, the firewall
           rules and the installation directory.
        8. Ask the machine what is left, and report anything that is. A run
           that finds residue is PARTIAL, never "removed".

    If step 2, 3, 5 or 6 fails, the run stops and nothing is removed. That is
    not a policy this script checks - it is the shape of the code. The backup
    function throws rather than returning a status, and the removal function
    cannot be called without the [Delta.VerifiedArchive] object that only a
    successful backup produces. There is no "continue anyway", and no switch
    that skips the backup. A database that was started for step 2 and then
    could not be dumped is stopped again, so an aborted run leaves the
    installation exactly as it found it.

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
    The installation to remove. Defaults to C:\DELTA - and when that default
    is used and nothing is registered there, this script asks the scheduled
    tasks where DELTA actually is rather than reporting the default as a
    survey of the machine. A root supplied explicitly is never overridden.

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

      Note what this does NOT require: that DELTA is running. A stopped
      installation is uninstalled by this script in one invocation - it starts
      the database itself. Only the engine has to be up.

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

function Resolve-DeltaUninstallRoot {
    <#
      Decides which installation this run is about, and says how it decided.

      -InstallRoot defaults to C:\DELTA, and the installer has never required
      that root. Two separate failures came out of treating that default as an
      answer, and this function exists to stop both.

      The first: an operator who installed to D:\DELTA and ran a bare
      `.\uninstall.ps1` was told "No DELTA Docker installation was found",
      which is true of C:\DELTA and reads as true of the machine - and the run
      exited 0 having done nothing, with the installation still there.

      The second, found by real destructive integration testing and much worse:
      when C:\DELTA *does* exist, a bare `.\uninstall.ps1` run from inside a
      DIFFERENT installation targeted C:\DELTA. It surveyed the wrong
      installation, listed the wrong containers, and asked for the typed DELETE
      over the wrong data volume, while the operator was standing in - and had
      just launched the uninstaller of - the installation they meant. It was
      one running database away from destroying the wrong installation.

      So the order below is precedence, most specific evidence first, and a
      parameter default is the weakest evidence there is:

        1. An explicitly supplied -InstallRoot. Somebody who named a directory
           gets an answer about that directory, and it is never overridden.
        2. The installation this run is happening INSIDE - the uninstaller's
           own directory first, then the working directory. Running
           <root>\uninstall.ps1, or running it while standing in <root>, is a
           statement about which installation is meant, and no default outranks
           it. In the normal distribution shape - an installer directory in
           Downloads, an installation root in C:\DELTA - neither is inside an
           installation and this rule simply does not fire.
        3. The default, if something is registered there.
        4. The scheduled tasks, which are the one record DELTA writes outside
           the installation root that names the installation root. Exactly one
           candidate is adopted and announced; more than one is reported and
           none chosen, because picking one installation out of several to
           delete is not a decision an uninstaller may make on somebody's
           behalf.

      Nothing here is trusted any further than a typed root: every candidate
      goes through the same Get-DeltaUninstallTarget ownership check and the
      same typed DELETE confirmation as any other.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][bool]$WasSupplied,
        [string]$ScriptRoot,
        [string]$WorkingDirectory
    )

    $result = [PSCustomObject]@{
        InstallRoot = $InstallRoot
        Target      = (Get-DeltaUninstallTarget -InstallRoot $InstallRoot)
        Discovered  = $false
        Candidates  = @()
        Source      = $(if ($WasSupplied) { 'supplied' } else { 'default' })
    }

    # Rule 2. Only when the root was not named: an operator who passed
    # -InstallRoot has already answered this question.
    if (-not $WasSupplied) {
        foreach ($context in @(
            @{ Path = $ScriptRoot;       Label = 'the uninstaller you ran is part of this installation' }
            @{ Path = $WorkingDirectory; Label = 'you are running this from inside this installation' }
        )) {
            if (-not $context.Path) { continue }
            $containing = Get-DeltaContainingInstallation -Path $context.Path
            if (-not $containing) { continue }
            if ($containing.InstallRoot -ieq $result.Target.InstallRoot) { break }

            Write-Host ''
            Write-Detail "Uninstalling  $($containing.InstallRoot)"
            Write-Detail "because $($context.Label)."
            if ($result.Target.Registered) {
                # The near-miss, said out loud: there IS an installation at the
                # default, and it is not the one being removed.
                Write-Detail "The installation at '$($result.Target.InstallRoot)' is a different one and is not touched."
            }
            Write-Detail 'Pass -InstallRoot to name a different one.'

            $result.InstallRoot = $containing.InstallRoot
            $result.Target      = $containing
            $result.Source      = 'context'
            return $result
        }
    }

    if ($result.Target.Registered) { return $result }

    $candidates = @(Get-DeltaInstalledRootCandidate | Where-Object {
        $_.Exists -and -not (Test-DeltaPathContains -Parent $InstallRoot -Child $_.InstallRoot)
    })
    $result.Candidates = $candidates

    if ($candidates.Count -eq 0) { return $result }

    Write-Host ''
    if ($WasSupplied) {
        Write-DeltaWarning "There is no registered DELTA installation at '$InstallRoot', but this machine has one registered elsewhere:"
        foreach ($candidate in $candidates) {
            Write-Detail "    $($candidate.InstallRoot)   (Compose project '$($candidate.ProjectName)', from the task '$($candidate.TaskName)')"
        }
        Write-Detail 'Nothing was changed. Re-run with -InstallRoot naming the one you mean.'
        return $result
    }

    if ($candidates.Count -gt 1) {
        Write-DeltaWarning "This machine has more than one registered DELTA installation, and none is at the default '$InstallRoot':"
        foreach ($candidate in $candidates) {
            Write-Detail "    $($candidate.InstallRoot)   (Compose project '$($candidate.ProjectName)')"
        }
        Write-Detail 'Nothing was changed. Re-run with -InstallRoot naming the one to remove.'
        return $result
    }

    $found = $candidates[0]
    Write-Detail "There is no DELTA installation at the default '$InstallRoot'."
    Write-Detail "This machine's scheduled task '$($found.TaskName)' points at:"
    Write-Detail "    $($found.InstallRoot)"
    Write-Detail 'Using that. Pass -InstallRoot to name a different one.'

    $discoveredTarget = Get-DeltaUninstallTarget -InstallRoot $found.InstallRoot
    if (-not $discoveredTarget.Registered) {
        Write-DeltaWarning "It is not a registered DELTA installation either: $($discoveredTarget.Reason)"
        return $result
    }

    $result.InstallRoot = $found.InstallRoot
    $result.Target      = $discoveredTarget
    $result.Discovered  = $true
    return $result
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

    # No subtitle: at this point the root is only the parameter default, and a
    # banner that announces an installation this run may not be about is how an
    # operator confirms the wrong one. The resolved root is printed by
    # Resolve-DeltaUninstallRoot below, and again in the plan.
    Show-Section -Title 'DELTA Docker Uninstaller'
    if ($logPath) { Write-Detail "Transcript: $logPath" }

    if (-not (Test-DeltaUninstallElevation)) {
        $exitCode = $Script:DeltaExitNotElevated
    }
    else {
        $workingDirectory = $null
        try { $workingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath } catch { }

        $resolution = Resolve-DeltaUninstallRoot -InstallRoot $InstallRoot `
            -WasSupplied ($PSBoundParameters.ContainsKey('InstallRoot')) `
            -ScriptRoot $Script:DeltaScriptRoot `
            -WorkingDirectory $workingDirectory
        $target = $resolution.Target
        $InstallRoot = $resolution.InstallRoot

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
