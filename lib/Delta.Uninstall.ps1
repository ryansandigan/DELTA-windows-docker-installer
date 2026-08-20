# =============================================================================
# Delta.Uninstall.ps1 - removing a DELTA Docker installation (Phase 12)
#
# The whole file is written around one asymmetry: putting DELTA back is always
# possible, and getting an operator's database back is not. So every decision
# here defaults to keeping things, every deletion is scoped to a resource this
# installation can prove it owns, and the one irreversible operation is behind
# a confirmation nobody can answer by reflex.
#
# Ownership is never inferred from a name. It comes from
# <InstallRoot>\.delta-install.json - the record of what a previous run
# actually did - with .env as a fallback for the two identifiers that also
# live there. A container called "delta-something" that this installation did
# not create is not ours and is never touched.
#
# Two things this file deliberately does not do:
#
#   - It never removes Docker Desktop, WSL, Hyper-V, a Windows feature, or any
#     other shared prerequisite. setup.ps1 being able to install Docker does
#     not make Docker DELTA's property; it is host infrastructure that other
#     things on the machine depend on.
#
#   - It never issues a global Docker operation. No `system prune`, no
#     `volume prune`, no `container prune`, no name-pattern sweep. Every
#     Docker call is scoped to this installation's Compose project or names a
#     single resource read from the state file.
# =============================================================================

# The flags that turn `docker compose down` from "remove the containers" into
# "remove the data". They are enumerated rather than avoided by convention,
# because Invoke-DeltaComposeDown below refuses to run if it ever sees one -
# a guard that fails loudly beats a rule somebody has to remember.
$Script:DeltaComposeVolumeFlags = @('-v', '--volumes', '--volume')

# Written into the state file after a preserve-data uninstall so a later run -
# of setup.ps1, of this script - can tell "never finished installing" from
# "deliberately uninstalled, data kept".
$Script:DeltaUninstallModePreserve = 'preserve-data'
$Script:DeltaUninstallModeComplete = 'complete'

# ---------------------------------------------------------------------------
# Identity: what is this installation, and what does it own?
# ---------------------------------------------------------------------------

function Get-DeltaUninstallTarget {
    <#
      Resolves an installation root into the set of named resources that
      belong to it. This is the ownership boundary, and everything downstream
      removes only what appears here.

      The state file is authoritative because it is the record of what a
      previous run did; .env is consulted only for the two identifiers that
      exist in both, and a disagreement between them is reported rather than
      silently resolved. An installation whose state file is missing or
      unreadable is `Registered = $false`: its files may still be removable by
      hand, but this script will not delete a directory tree on the strength
      of a guess.

      Nothing here touches Docker. It reads two files and derives names.
    #>
    param([Parameter(Mandatory)][string]$InstallRoot)

    $resolved = $InstallRoot
    try { $resolved = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') } catch { }

    $target = [PSCustomObject]@{
        InstallRoot      = $resolved
        Exists           = (Test-Path -LiteralPath $resolved -PathType Container)
        Registered       = $false
        Reason           = $null
        Disagreements    = @()
        ProjectName      = $null
        PgDataVolume     = $null
        NetworkName      = $null
        ComposeFile      = (Join-Path -Path $resolved -ChildPath 'docker-compose.yml')
        EnvPath          = (Join-Path -Path $resolved -ChildPath '.env')
        StatePath        = (Join-Path -Path $resolved -ChildPath '.delta-install.json')
        StartupTaskName  = $null
        RotationTaskName = $null
        HttpRuleName     = $null
        HttpsRuleName    = $null
        PreviousUninstall = $null
        StateFile        = $null
        Configuration    = $null
    }

    if (-not $target.Exists) {
        $target.Reason = "There is no directory at '$resolved'."
        return $target
    }

    $state = Read-DeltaInstallState -InstallRoot $resolved
    $target.StateFile = $state

    if (-not $state.Exists) {
        $target.Reason = "'$resolved' has no $Script:DeltaInstallStateFileName, so this installer cannot confirm it created it."
        return $target
    }
    if (-not $state.IsValid) {
        $target.Reason = "'$($state.Path)' could not be read as an installation record: $($state.Error)"
        return $target
    }

    $properties = @($state.Data.PSObject.Properties.Name)
    $stateProject = if ($properties -contains 'composeProject') { [string]$state.Data.composeProject } else { $null }
    $stateVolume  = if ($properties -contains 'pgDataVolume')   { [string]$state.Data.pgDataVolume }   else { $null }
    if ($properties -contains 'uninstall') { $target.PreviousUninstall = $state.Data.uninstall }

    # .env is read through the same accessor the rest of the product uses, so
    # a configuration that has drifted from the state file is visible instead
    # of being averaged into something that matches neither.
    $configuration = $null
    if (Test-Path -LiteralPath $target.EnvPath -PathType Leaf) {
        $configuration = Get-DeltaStackConfiguration -InstallRoot $resolved
    }
    $target.Configuration = $configuration

    $disagreements = New-Object 'System.Collections.Generic.List[string]'
    if ($configuration) {
        if ($stateProject -and $configuration.ProjectName -and $stateProject -ne $configuration.ProjectName) {
            $null = $disagreements.Add("the state file records Compose project '$stateProject' and .env records '$($configuration.ProjectName)'")
        }
        if ($stateVolume -and $configuration.PgDataVolume -and $stateVolume -ne $configuration.PgDataVolume) {
            $null = $disagreements.Add("the state file records data volume '$stateVolume' and .env records '$($configuration.PgDataVolume)'")
        }
    }
    $target.Disagreements = $disagreements.ToArray()

    $target.ProjectName = if ($stateProject) { $stateProject } elseif ($configuration) { $configuration.ProjectName } else { $null }
    $target.PgDataVolume = if ($stateVolume) { $stateVolume } elseif ($configuration) { $configuration.PgDataVolume } else { $null }

    if (-not $target.ProjectName) {
        $target.Reason = "'$($state.Path)' does not record a Compose project name, so this installation's containers cannot be identified."
        return $target
    }

    # Compose names the default network <project>_default. It is created and
    # destroyed with the project, so this name exists for reporting and for
    # the already-absent check - never for a standalone `network rm`.
    $target.NetworkName      = "$($target.ProjectName)_default"
    $target.StartupTaskName  = Get-DeltaStartupTaskName -ProjectName $target.ProjectName
    $target.RotationTaskName = Get-DeltaLogRotationTaskName -ProjectName $target.ProjectName
    $target.HttpRuleName     = Get-DeltaFirewallRuleName -ProjectName $target.ProjectName -Endpoint 'HTTP'
    $target.HttpsRuleName    = Get-DeltaFirewallRuleName -ProjectName $target.ProjectName -Endpoint 'HTTPS'

    $target.Registered = $true
    $target.Reason = "A DELTA Docker installation registered as Compose project '$($target.ProjectName)'."
    return $target
}

function Get-DeltaUninstallSurvey {
    <#
      What of the target actually exists right now.

      Separate from Get-DeltaUninstallTarget on purpose: that function answers
      "what would this installation own", which is a question about two files,
      and this one answers "what is still here", which is a question about the
      machine. Keeping them apart is what lets a rerun after a partial
      uninstall describe itself accurately rather than reporting resources it
      has already removed.

      -DockerAvailable false skips every Docker query and marks those rows
      Unknown rather than Absent. "I could not look" and "it is not there" are
      different answers and only one of them justifies saying cleanup is done.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [bool]$DockerAvailable = $true
    )

    $survey = [PSCustomObject]@{
        DockerAvailable = $DockerAvailable
        Containers      = @()
        NetworkPresent  = $null
        VolumePresent   = $null
        VolumeDetail    = $null
        StartupTask     = $false
        RotationTask    = $false
        HttpRule        = $false
        HttpsRule       = $false
        Directories     = @()
        Files           = @()
        DataBytes       = 0
    }

    if ($DockerAvailable -and $Target.ProjectName) {
        # Scoped by label to this Compose project, which is how Compose itself
        # identifies its containers. Not a name match: a container called
        # "delta12-db-1" created by something else carries no such label.
        $ps = Invoke-DeltaDockerCommand -Arguments @(
            'ps', '--all', '--filter', "label=com.docker.compose.project=$($Target.ProjectName)",
            '--format', '{{.Names}}|{{.State}}|{{.ID}}'
        ) -TimeoutSeconds 120
        if ($ps.ExitCode -eq 0 -and $ps.StdOut) {
            $containers = New-Object 'System.Collections.Generic.List[object]'
            foreach ($line in ($ps.StdOut -split "`r?`n")) {
                if (-not $line.Trim()) { continue }
                $parts = $line.Split('|')
                $null = $containers.Add([PSCustomObject]@{ Name = $parts[0]; State = $parts[1]; Id = $parts[2] })
            }
            $survey.Containers = $containers.ToArray()
        }

        $net = Invoke-DeltaDockerCommand -Arguments @('network', 'inspect', $Target.NetworkName, '--format', '{{.Name}}') -TimeoutSeconds 60
        $survey.NetworkPresent = ($net.ExitCode -eq 0)

        if ($Target.PgDataVolume) {
            $vol = Invoke-DeltaDockerCommand -Arguments @('volume', 'inspect', $Target.PgDataVolume, '--format', '{{.Mountpoint}}') -TimeoutSeconds 60
            $survey.VolumePresent = ($vol.ExitCode -eq 0)
            if ($vol.ExitCode -eq 0) { $survey.VolumeDetail = ($vol.StdOut -split "`r?`n" | Select-Object -First 1).Trim() }
        }
    }

    if ($Target.StartupTaskName) {
        $survey.StartupTask = (Get-DeltaStartupTaskState -ProjectName $Target.ProjectName).Exists
        $survey.RotationTask = (Get-DeltaLogRotationTaskState -ProjectName $Target.ProjectName).Exists
        $survey.HttpRule = (@(Get-DeltaOwnedFirewallRule -DisplayName $Target.HttpRuleName).Count -gt 0)
        $survey.HttpsRule = (@(Get-DeltaOwnedFirewallRule -DisplayName $Target.HttpsRuleName).Count -gt 0)
    }

    $directories = New-Object 'System.Collections.Generic.List[object]'
    foreach ($relative in @('uploads', 'backups', 'certs', 'logs', 'nginx')) {
        $path = Join-Path -Path $Target.InstallRoot -ChildPath $relative
        $entry = [PSCustomObject]@{ Name = $relative; Path = $path; Exists = (Test-Path -LiteralPath $path -PathType Container); Bytes = 0; Items = 0 }
        if ($entry.Exists) {
            $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue)
            $entry.Items = $files.Count
            $entry.Bytes = ($files | Measure-Object -Property Length -Sum).Sum
            if (-not $entry.Bytes) { $entry.Bytes = 0 }
        }
        $null = $directories.Add($entry)
    }
    $survey.Directories = $directories.ToArray()
    $survey.DataBytes = ($directories | Measure-Object -Property Bytes -Sum).Sum
    if (-not $survey.DataBytes) { $survey.DataBytes = 0 }

    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in @('.env', 'docker-compose.yml', $Script:DeltaInstallStateFileName)) {
        $path = Join-Path -Path $Target.InstallRoot -ChildPath $name
        $null = $files.Add([PSCustomObject]@{ Name = $name; Path = $path; Exists = (Test-Path -LiteralPath $path -PathType Leaf) })
    }
    $survey.Files = $files.ToArray()

    return $survey
}

# ---------------------------------------------------------------------------
# Removal primitives
#
# Each returns a step record: Resource, Kind, Outcome, Detail. The five
# outcomes are the whole vocabulary, and they are kept distinct on purpose -
# collapsing "already absent" and "removed" into "done" is how a partial
# uninstall gets reported as a complete one.
# ---------------------------------------------------------------------------

function New-DeltaUninstallStep {
    param(
        [Parameter(Mandatory)][string]$Resource,
        [Parameter(Mandatory)][ValidateSet('container', 'network', 'volume', 'task', 'firewall', 'file', 'state', 'backup')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('Removed', 'Already absent', 'Preserved', 'Failed', 'Could not verify')][string]$Outcome,
        [string]$Detail
    )
    return [PSCustomObject]@{ Resource = $Resource; Kind = $Kind; Outcome = $Outcome; Detail = $Detail }
}

function Invoke-DeltaComposeDown {
    <#
      The single place in this product that runs `docker compose down`, and
      the only reason it is a function of its own.

      `down` without -v removes the project's containers and its default
      network. It does not remove the named volume (`delta_pgdata` is declared
      with an explicit name: in the compose file, so Compose manages it, and
      only -v would delete it) and it does not touch a bind mount, because a
      bind mount is a directory on the host that Docker never owned. That is
      exactly the preservation boundary this phase needs, which is why `down`
      is used rather than a stop/rm/network-rm sequence.

      -v is one keystroke from correct, so the argument vector is inspected
      before the call and a volume-removal flag is a refusal, not a warning.
      The guard is here rather than in a comment because the comment would not
      have failed a test.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [string[]]$Arguments = @('--remove-orphans'),
        [int]$TimeoutSeconds = 600
    )

    foreach ($argument in $Arguments) {
        $normalised = ([string]$argument).Trim().ToLowerInvariant()
        if ($Script:DeltaComposeVolumeFlags -contains $normalised) {
            return [PSCustomObject]@{
                ExitCode = -1
                StdOut   = ''
                StdErr   = "Refusing to run 'docker compose down $normalised': that removes this installation's database volume. Volume removal is a separate, explicitly confirmed operation."
                Refused  = $true
            }
        }
    }

    $capture = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName `
        -Arguments (@('down') + $Arguments) -TimeoutSeconds $TimeoutSeconds
    return ([PSCustomObject]@{ ExitCode = $capture.ExitCode; StdOut = $capture.StdOut; StdErr = $capture.StdErr; Refused = $false })
}

function Remove-DeltaComposeRuntime {
    <#
      Containers and the project network, in one project-scoped operation,
      then verified by looking again. The verification is the point: `down`
      exiting 0 on a project with no containers and `down` exiting 0 after
      removing three of them are the same exit code, and the operator needs to
      know which happened.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Survey
    )

    $steps = New-Object 'System.Collections.Generic.List[object]'

    if (-not $Survey.DockerAvailable) {
        $null = $steps.Add((New-DeltaUninstallStep -Resource "Compose project '$($Target.ProjectName)'" -Kind 'container' -Outcome 'Could not verify' `
            -Detail 'The Docker engine is not reachable, so this installation''s containers and network were not removed and could not be inspected.'))
        return $steps.ToArray()
    }

    $had = @($Survey.Containers).Count
    if ($had -eq 0 -and $Survey.NetworkPresent -ne $true) {
        $null = $steps.Add((New-DeltaUninstallStep -Resource "Compose project '$($Target.ProjectName)'" -Kind 'container' -Outcome 'Already absent' `
            -Detail 'No containers and no network for this project.'))
        return $steps.ToArray()
    }

    if (-not (Test-Path -LiteralPath $Target.ComposeFile -PathType Leaf)) {
        # Compose needs the file to know what the project is. Without it the
        # containers are still identifiable by label, but removing them is a
        # different operation from the one this function promises, so it says
        # so instead of improvising.
        $null = $steps.Add((New-DeltaUninstallStep -Resource "Compose project '$($Target.ProjectName)'" -Kind 'container' -Outcome 'Could not verify' `
            -Detail "docker-compose.yml is missing from $($Target.InstallRoot), so the project could not be brought down. $had container(s) remain."))
        return $steps.ToArray()
    }

    $down = Invoke-DeltaComposeDown -InstallRoot $Target.InstallRoot -ProjectName $Target.ProjectName
    if ($down.ExitCode -ne 0) {
        $null = $steps.Add((New-DeltaUninstallStep -Resource "Compose project '$($Target.ProjectName)'" -Kind 'container' -Outcome 'Failed' `
            -Detail (($down.StdErr + ' ' + $down.StdOut)).Trim()))
        return $steps.ToArray()
    }

    $after = Get-DeltaUninstallSurvey -Target $Target -DockerAvailable $true
    $remaining = @($after.Containers).Count

    if ($remaining -gt 0) {
        $null = $steps.Add((New-DeltaUninstallStep -Resource 'DELTA containers' -Kind 'container' -Outcome 'Failed' `
            -Detail "$remaining container(s) still belong to project '$($Target.ProjectName)': $((@($after.Containers) | ForEach-Object { $_.Name }) -join ', ')"))
    }
    elseif ($had -gt 0) {
        $null = $steps.Add((New-DeltaUninstallStep -Resource 'DELTA containers' -Kind 'container' -Outcome 'Removed' `
            -Detail "$had container(s): $((@($Survey.Containers) | ForEach-Object { $_.Name }) -join ', ')"))
    }
    else {
        $null = $steps.Add((New-DeltaUninstallStep -Resource 'DELTA containers' -Kind 'container' -Outcome 'Already absent' -Detail 'No containers belonged to this project.'))
    }

    if ($after.NetworkPresent) {
        $null = $steps.Add((New-DeltaUninstallStep -Resource $Target.NetworkName -Kind 'network' -Outcome 'Failed' `
            -Detail 'The Compose network still exists. Something outside this installation may still be attached to it; it was not forced.'))
    }
    elseif ($Survey.NetworkPresent) {
        $null = $steps.Add((New-DeltaUninstallStep -Resource $Target.NetworkName -Kind 'network' -Outcome 'Removed' -Detail 'The Compose project network.'))
    }
    else {
        $null = $steps.Add((New-DeltaUninstallStep -Resource $Target.NetworkName -Kind 'network' -Outcome 'Already absent' -Detail $null))
    }

    return $steps.ToArray()
}

function Remove-DeltaScheduledIntegration {
    <#
      The two scheduled tasks this installation registered, each matched by
      the exact name built from its own Compose project - the same names the
      installer used to create them. A task that is not there is reconciled,
      not an error: an operator who removed it by hand did nothing wrong.
    #>
    param([Parameter(Mandatory)][object]$Target)

    $steps = New-Object 'System.Collections.Generic.List[object]'

    $startup = Unregister-DeltaStartupTask -ProjectName $Target.ProjectName
    if ($startup.Removed) {
        $null = $steps.Add((New-DeltaUninstallStep -Resource $startup.Name -Kind 'task' -Outcome 'Removed' -Detail 'Unattended startup task.'))
    }
    elseif ($startup.Reason -eq 'No such task.') {
        $null = $steps.Add((New-DeltaUninstallStep -Resource $startup.Name -Kind 'task' -Outcome 'Already absent' -Detail $null))
    }
    else {
        $null = $steps.Add((New-DeltaUninstallStep -Resource $startup.Name -Kind 'task' -Outcome 'Failed' -Detail $startup.Reason))
    }

    $rotation = Unregister-DeltaLogRotationTask -ProjectName $Target.ProjectName
    if ($rotation.Removed) {
        $null = $steps.Add((New-DeltaUninstallStep -Resource $rotation.Name -Kind 'task' -Outcome 'Removed' -Detail 'NGINX log rotation task.'))
    }
    elseif ($rotation.Reason -eq 'No such task.') {
        $null = $steps.Add((New-DeltaUninstallStep -Resource $rotation.Name -Kind 'task' -Outcome 'Already absent' -Detail $null))
    }
    else {
        $null = $steps.Add((New-DeltaUninstallStep -Resource $rotation.Name -Kind 'task' -Outcome 'Failed' -Detail $rotation.Reason))
    }

    return $steps.ToArray()
}

function Remove-DeltaFirewallIntegration {
    <#
      This installation's two rules, and only those: Remove-DeltaFirewallRule
      matches an exact display name *and* requires this installer's own
      firewall group, so a rule somebody else created with a similar name is
      not a candidate.

      A rule that was never created - the HTTPS one on a plain-HTTP
      installation - is absent, which is the correct end state.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Survey
    )

    $steps = New-Object 'System.Collections.Generic.List[object]'

    foreach ($pair in @(
        @{ Name = $Target.HttpRuleName;  Present = $Survey.HttpRule;  Label = 'Inbound HTTP' },
        @{ Name = $Target.HttpsRuleName; Present = $Survey.HttpsRule; Label = 'Inbound HTTPS' }
    )) {
        if (-not $pair.Present) {
            $null = $steps.Add((New-DeltaUninstallStep -Resource $pair.Name -Kind 'firewall' -Outcome 'Already absent' -Detail $null))
            continue
        }
        if (Remove-DeltaFirewallRule -DisplayName $pair.Name) {
            $null = $steps.Add((New-DeltaUninstallStep -Resource $pair.Name -Kind 'firewall' -Outcome 'Removed' -Detail $pair.Label))
        }
        else {
            $null = $steps.Add((New-DeltaUninstallStep -Resource $pair.Name -Kind 'firewall' -Outcome 'Failed' `
                -Detail 'The rule exists and could not be removed. Windows Firewall policy may be managed centrally on this host.'))
        }
    }

    return $steps.ToArray()
}

function Remove-DeltaDataVolume {
    <#
      The one operation in this file that destroys an operator's database.

      Three things must hold before `docker volume rm` runs: the caller must
      name the volume this installation registered (not a volume it merely
      found), the name must be non-empty, and the containers must already be
      gone - Docker refuses to remove a volume in use, and relying on that
      refusal rather than checking would turn a design guarantee into a race.

      Docker's own refusal is still respected if it comes: a volume that is
      still attached to something is reported, not forced.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Survey
    )

    if (-not $Target.PgDataVolume) {
        return (New-DeltaUninstallStep -Resource 'PostgreSQL data volume' -Kind 'volume' -Outcome 'Could not verify' `
            -Detail 'This installation does not record a data volume name, so no volume was removed.')
    }
    if (-not $Survey.DockerAvailable) {
        return (New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome 'Could not verify' `
            -Detail 'The Docker engine is not reachable, so the data volume was not removed. The database is intact.')
    }
    if ($Survey.VolumePresent -ne $true) {
        return (New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome 'Already absent' -Detail $null)
    }

    $remove = Invoke-DeltaDockerCommand -Arguments @('volume', 'rm', $Target.PgDataVolume) -TimeoutSeconds 120
    if ($remove.ExitCode -ne 0) {
        return (New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome 'Failed' `
            -Detail (($remove.StdErr + ' ' + $remove.StdOut)).Trim())
    }

    $check = Invoke-DeltaDockerCommand -Arguments @('volume', 'inspect', $Target.PgDataVolume) -TimeoutSeconds 60
    if ($check.ExitCode -eq 0) {
        return (New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome 'Failed' `
            -Detail 'docker volume rm reported success but the volume is still present.')
    }

    return (New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome 'Removed' -Detail 'The PostgreSQL data directory and every DELTA record in it.')
}

function Export-DeltaFinalBackup {
    <#
      A verified dump taken immediately before the database is destroyed, and
      then moved somewhere the destruction will not reach.

      The dump itself is Phase 8's, unchanged - New-DeltaDatabaseBackup, with
      its pg_dump in the db container, its byte-exact transport and its
      pg_restore --list verification. Duplicating any of that here would mean
      two implementations of the one operation whose output has to be
      trustworthy.

      The move is the part this function adds, and it is not optional: the
      dump lands in <InstallRoot>\backups, and complete removal deletes
      <InstallRoot>. A "safety backup" inside the directory about to be
      deleted is theatre. So the file is copied out first, the copy is
      verified in its new location by the same archive check, and only the
      surviving path is reported. Retention is skipped - this backup exists to
      outlive the installation, not to participate in its rotation.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][string]$Destination
    )

    $result = [PSCustomObject]@{
        Succeeded = $false
        Path      = $null
        SizeBytes = 0
        Reason    = $null
    }

    if (-not $Target.Configuration) {
        $result.Reason = 'This installation has no readable .env, so the database could not be reached to back it up.'
        return $result
    }

    $backup = New-DeltaDatabaseBackup -InstallRoot $Target.InstallRoot -Configuration $Target.Configuration -SkipRetention
    if (-not $backup.Succeeded) {
        $result.Reason = $backup.Reason
        return $result
    }

    try {
        if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $Destination -Force
        }
        $exported = Join-Path -Path $Destination -ChildPath $backup.FileName
        if (Test-Path -LiteralPath $exported -PathType Leaf) {
            # Never overwrite: the file already there may be the only copy of
            # something. Phase 8 made the same call for the same reason.
            $result.Reason = "A file named '$($backup.FileName)' already exists in '$Destination'. The backup inside the installation was left in place and nothing was overwritten."
            return $result
        }
        Copy-Item -LiteralPath $backup.Path -Destination $exported -ErrorAction Stop
    }
    catch {
        $result.Reason = "The backup was taken but could not be copied to '$Destination': $($_.Exception.Message)"
        return $result
    }

    $verify = Test-DeltaBackupArchive -InstallRoot $Target.InstallRoot -ProjectName $Target.ProjectName -Path $exported
    if (-not $verify.Verified) {
        $result.Reason = "The exported copy at '$exported' did not verify: $($verify.Reason)"
        return $result
    }

    $result.Succeeded = $true
    $result.Path = $exported
    $result.SizeBytes = $verify.SizeBytes
    return $result
}

function Remove-DeltaInstallationTree {
    <#
      Deletes the installation root - the last thing complete removal does,
      and the one place a mistake would be measured in directories rather than
      in containers.

      It refuses unless the target is Registered: a state file that exists,
      parses, and names a Compose project. That is what makes
      `uninstall.ps1 -InstallRoot C:\Windows` a refusal rather than a
      catastrophe, and it is checked here as well as at the entry point
      because this function is the one holding the recursive delete.

      A drive root is refused outright regardless of what it contains.
    #>
    param([Parameter(Mandatory)][object]$Target)

    if (-not $Target.Registered) {
        return (New-DeltaUninstallStep -Resource $Target.InstallRoot -Kind 'file' -Outcome 'Preserved' `
            -Detail "Not a registered DELTA installation, so nothing was deleted. $($Target.Reason)")
    }

    $path = $Target.InstallRoot
    $root = $null
    try { $root = [System.IO.Path]::GetPathRoot($path).TrimEnd('\') } catch { }
    if ($root -and ($path.TrimEnd('\') -eq $root)) {
        return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Preserved' `
            -Detail 'Refusing to delete a drive root, whatever its state file says.')
    }

    try {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    }
    catch {
        return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Failed' -Detail $_.Exception.Message)
    }

    if (Test-Path -LiteralPath $path) {
        return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Failed' `
            -Detail 'The directory still exists. A file in it is probably held open by another process.')
    }
    return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Removed' -Detail 'The installation root and everything under it.')
}

function Set-DeltaUninstalledState {
    <#
      Records what just happened, in the state file, without inventing a new
      state vocabulary to do it.

      `state` moves from 'installed' to 'partial'. That is not a fudge:
      'partial' already means "evidence exists but the installation is not
      registered as complete", which after a preserve-data uninstall is
      exactly the truth - the data is there and the runtime is not. It also
      produces the behaviour the operator wants from setup.ps1, which opens
      the management menu for 'installed' and runs the installation flow for
      anything else. A menu offering to restart containers that no longer
      exist would be worse than useless.

      Everything else in the file is left alone, deliberately. pgDataVolume is
      what a later run needs to find the preserved database; composeProject is
      what a later uninstall needs to identify Docker resources. Clearing them
      would make the preserved data harder to recover, which is the opposite
      of the point.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][object[]]$Steps,
        [string[]]$Preserved = @(),
        [string]$BackupPath
    )

    $removed = @($Steps | Where-Object { $_.Outcome -eq 'Removed' } | ForEach-Object { $_.Resource })
    $unresolved = @($Steps | Where-Object { $_.Outcome -in @('Failed', 'Could not verify') } | ForEach-Object { $_.Resource })

    $record = [ordered]@{
        at         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        mode       = $Mode
        removed    = $removed
        preserved  = $Preserved
        unresolved = $unresolved
    }
    if ($BackupPath) { $record['finalBackup'] = $BackupPath }

    try {
        $path = Write-DeltaInstallState -InstallRoot $Target.InstallRoot -Properties ([ordered]@{
            'state'     = 'partial'
            'uninstall' = $record
        })
        return (New-DeltaUninstallStep -Resource $path -Kind 'state' -Outcome 'Preserved' `
            -Detail "Kept, and marked uninstalled (state = partial). It identifies the preserved data and lets setup.ps1 rebuild the runtime.")
    }
    catch {
        return (New-DeltaUninstallStep -Resource $Target.StatePath -Kind 'state' -Outcome 'Failed' -Detail $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Invoke-DeltaUninstall {
    <#
      Runs one uninstall, in one mode, and returns what happened rather than
      printing a verdict.

      Ordering is not arbitrary, and one step of it is easy to get wrong.

      The final backup runs FIRST, before anything is removed. It is produced
      by pg_dump inside the db container, so it needs that container running -
      taking it after `compose down`, which is where it naturally wants to sit
      in a list of destructive steps, would mean every complete removal
      reported "the database container is not running, so no backup was
      taken". Measured during Phase 12 development, before the ordering was
      corrected.

      Then the runtime, because a container holding the volume open blocks its
      removal and a container with restart: unless-stopped would otherwise
      resurrect itself mid-uninstall. Then the scheduled tasks, because a
      startup task that survived would bring the stack back at the next boot.
      Then the volume, then the installation root.

      The state file is written last in preserve mode, and in complete mode it
      is not written at all - the directory holding it is gone.

      Nothing here prompts. Every decision was already made by the caller;
      this function performs them and records the outcome, which is what makes
      it testable without a person at the keyboard.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][ValidateSet('preserve-data', 'complete')][string]$Mode,
        [bool]$DockerAvailable = $true,
        [string]$FinalBackupDestination
    )

    $result = [PSCustomObject]@{
        Mode       = $Mode
        Outcome    = 'partial'
        Steps      = @()
        Preserved  = @()
        BackupPath = $null
        BackupReason = $null
        Reason     = $null
    }

    $steps = New-Object 'System.Collections.Generic.List[object]'
    $survey = Get-DeltaUninstallSurvey -Target $Target -DockerAvailable $DockerAvailable

    # 1. The final backup, while the database container is still running.
    if ($Mode -eq $Script:DeltaUninstallModeComplete -and $FinalBackupDestination) {
        Write-Step 'Taking a final verified backup'
        $backup = Export-DeltaFinalBackup -Target $Target -Destination $FinalBackupDestination
        if ($backup.Succeeded) {
            $result.BackupPath = $backup.Path
            $step = New-DeltaUninstallStep -Resource $backup.Path -Kind 'backup' -Outcome 'Preserved' `
                -Detail "Verified, $(Format-DeltaByteSize $backup.SizeBytes), outside the installation root."
        }
        else {
            $result.BackupReason = $backup.Reason
            $step = New-DeltaUninstallStep -Resource 'Final backup' -Kind 'backup' -Outcome 'Failed' -Detail $backup.Reason
        }
        $null = $steps.Add($step)
        Write-DeltaUninstallStepLine -Step $step
    }

    # 2. The runtime: containers and the project network.
    Write-Step 'Removing the DELTA containers'
    foreach ($step in (Remove-DeltaComposeRuntime -Target $Target -Survey $survey)) {
        $null = $steps.Add($step)
        Write-DeltaUninstallStepLine -Step $step
    }

    # 3. Windows integration that would otherwise outlive the installation.
    Write-Step 'Removing the Windows integration'
    foreach ($step in (Remove-DeltaScheduledIntegration -Target $Target)) {
        $null = $steps.Add($step)
        Write-DeltaUninstallStepLine -Step $step
    }
    foreach ($step in (Remove-DeltaFirewallIntegration -Target $Target -Survey $survey)) {
        $null = $steps.Add($step)
        Write-DeltaUninstallStepLine -Step $step
    }

    if ($Mode -eq $Script:DeltaUninstallModePreserve) {
        $preserved = New-Object 'System.Collections.Generic.List[string]'
        if ($Target.PgDataVolume) {
            $present = if ($survey.VolumePresent -eq $true) { 'Preserved' } elseif ($survey.DockerAvailable) { 'Already absent' } else { 'Could not verify' }
            $detail = switch ($present) {
                'Preserved'      { 'The PostgreSQL database, untouched.' }
                'Already absent' { 'This installation records a data volume, but it does not exist on this host.' }
                default          { 'The Docker engine is not reachable, so the data volume could not be inspected. Nothing was removed.' }
            }
            $null = $steps.Add((New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome $present -Detail $detail))
            if ($present -eq 'Preserved') { $null = $preserved.Add("Database volume $($Target.PgDataVolume)") }
        }
        foreach ($directory in $survey.Directories) {
            if (-not $directory.Exists) { continue }
            $null = $steps.Add((New-DeltaUninstallStep -Resource $directory.Path -Kind 'file' -Outcome 'Preserved' `
                -Detail "$($directory.Items) file(s), $(Format-DeltaByteSize $directory.Bytes)"))
            $null = $preserved.Add($directory.Path)
        }
        foreach ($file in $survey.Files) {
            if (-not $file.Exists -or $file.Name -eq $Script:DeltaInstallStateFileName) { continue }
            $null = $steps.Add((New-DeltaUninstallStep -Resource $file.Path -Kind 'file' -Outcome 'Preserved' `
                -Detail $(if ($file.Name -eq '.env') { 'Configuration and secrets. Its restrictive ACL is untouched.' } else { 'Generated configuration.' })))
            $null = $preserved.Add($file.Path)
        }
        $result.Preserved = $preserved.ToArray()

        $null = $steps.Add((Set-DeltaUninstalledState -Target $Target -Mode $Mode -Steps $steps.ToArray() -Preserved $result.Preserved))
    }
    else {
        # 4. The data volume, then the installation root.
        Write-Step 'Removing the database volume'
        $volumeStep = Remove-DeltaDataVolume -Target $Target -Survey $survey
        $null = $steps.Add($volumeStep)
        Write-DeltaUninstallStepLine -Step $volumeStep

        Write-Step 'Removing the installation directory'
        $treeStep = Remove-DeltaInstallationTree -Target $Target
        $null = $steps.Add($treeStep)
        Write-DeltaUninstallStepLine -Step $treeStep
    }

    $result.Steps = $steps.ToArray()

    $unresolved = @($result.Steps | Where-Object { $_.Outcome -in @('Failed', 'Could not verify') })
    if ($unresolved.Count -eq 0) {
        $result.Outcome = 'success'
    }
    else {
        $result.Outcome = 'partial'
        $result.Reason = "$($unresolved.Count) resource(s) were not removed or could not be checked."
    }

    return $result
}

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

function Write-DeltaUninstallStepLine {
    param([Parameter(Mandatory)][object]$Step)

    $marker = switch ($Step.Outcome) {
        'Removed'          { '[removed]  ' }
        'Already absent'   { '[absent]   ' }
        'Preserved'        { '[preserved]' }
        'Failed'           { '[FAILED]   ' }
        'Could not verify' { '[unknown]  ' }
    }
    $line = "$marker $($Step.Resource)"
    if ($Step.Detail) { $line = "$line - $($Step.Detail)" }

    switch ($Step.Outcome) {
        'Failed'           { Write-DeltaWarning $line }
        'Could not verify' { Write-DeltaWarning $line }
        default            { Write-Detail $line }
    }
}

function Show-DeltaUninstallPlan {
    <#
      What the operator sees before choosing: the installation that was found,
      what it is doing right now, and - stated as two lists rather than as
      prose - what a normal uninstall removes and what it keeps.

      The preserved list carries sizes. "Backups" is an abstraction; "backups,
      47 files, 14.6 MB" is a thing somebody can decide about.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Survey
    )

    Write-Host ''
    Write-Host 'Installation'
    Write-Detail $Target.InstallRoot
    Write-Detail "Compose project    $($Target.ProjectName)"
    if ($Target.Configuration) {
        Write-Detail "Address            $($Target.Configuration.PublicUrl)"
    }

    if ($Target.Disagreements.Count -gt 0) {
        Write-Host ''
        Write-DeltaWarning 'The installation record and .env do not agree:'
        foreach ($disagreement in $Target.Disagreements) {
            Write-DeltaWarning "  $disagreement"
        }
        Write-DeltaWarning 'The installation record is used, because it is what previous runs acted on.'
    }

    Write-Host ''
    Write-Host 'Current state'
    if (-not $Survey.DockerAvailable) {
        Write-DeltaWarning '    Docker is not reachable. Containers, the network and the database volume'
        Write-DeltaWarning '    cannot be inspected or removed in this run.'
    }
    else {
        $containers = @($Survey.Containers)
        if ($containers.Count -eq 0) {
            Write-Detail 'Containers         none'
        }
        else {
            foreach ($container in $containers) {
                Write-Detail ("Container          {0,-24} {1}" -f $container.Name, $container.State)
            }
        }
        Write-Detail "Database volume    $($Target.PgDataVolume) $(if ($Survey.VolumePresent) { 'present' } else { 'absent' })"
    }
    Write-Detail "Startup task       $(if ($Survey.StartupTask) { 'registered' } else { 'absent' })"
    Write-Detail "Log rotation task  $(if ($Survey.RotationTask) { 'registered' } else { 'absent' })"
    Write-Detail "Firewall rules     $((@(if ($Survey.HttpRule) { 'HTTP' }) + @(if ($Survey.HttpsRule) { 'HTTPS' }) | Where-Object { $_ }) -join ', ')$(if (-not ($Survey.HttpRule -or $Survey.HttpsRule)) { 'none' })"

    Write-Host ''
    Write-Host 'A normal uninstall removes'
    Write-Detail 'The DELTA, database and NGINX containers'
    Write-Detail 'The Docker network they share'
    Write-Detail 'The scheduled task that starts DELTA at boot'
    Write-Detail 'The scheduled task that rotates the NGINX logs'
    Write-Detail 'The Windows Firewall rules for this installation'

    Write-Host ''
    Write-Host 'and preserves'
    Write-Detail "The database                 volume $($Target.PgDataVolume)"
    foreach ($directory in $Survey.Directories) {
        if (-not $directory.Exists) { continue }
        Write-Detail ("{0,-28} {1}, {2} file(s)" -f $directory.Name, (Format-DeltaByteSize $directory.Bytes), $directory.Items)
    }
    Write-Detail 'Configuration                .env, docker-compose.yml'

    Write-Host ''
    Write-Detail 'Docker Desktop, WSL and every other program on this machine are left alone.'
}

function Read-DeltaUninstallMode {
    <#
      The mode menu. Preservation is 1 because it is the answer almost
      everybody wants; complete removal is 2 and is labelled with what it
      actually does rather than with the word "full", which reads like a
      thoroughness setting rather than a data-destruction one.

      Anything that is not 1 or 2 - including a bare Enter - cancels.
    #>
    param([Parameter(Mandatory)][object]$Target)

    Write-Host ''
    Write-Host 'Choose:'
    Write-Host ''
    Write-Host '  1. Uninstall DELTA and preserve data'
    Write-Host '     Removes the containers and the Windows integration. The database,'
    Write-Host '     uploads, backups, certificates and configuration are kept, and'
    Write-Host '     setup.ps1 can rebuild the installation over them.'
    Write-Host ''
    Write-Host '  2. Completely remove DELTA and its data' -ForegroundColor Yellow
    Write-Host "     Everything above, and then deletes the database volume" -ForegroundColor Yellow
    Write-Host "     $($Target.PgDataVolume) and the whole of $($Target.InstallRoot)." -ForegroundColor Yellow
    Write-Host '     This cannot be undone.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  0. Cancel'
    Write-Host ''

    $choice = Read-Host -Prompt 'Selection'
    switch (([string]$choice).Trim()) {
        '1' { return $Script:DeltaUninstallModePreserve }
        '2' { return $Script:DeltaUninstallModeComplete }
        default { return $null }
    }
}

function Read-DeltaDestructiveConfirmation {
    <#
      The gate in front of the only irreversible thing this product does.

      It is a typed word, not [y/N], and that is the entire design. The rest of
      this installer uses [y/N] with blank meaning no, which is right for a
      question somebody might answer wrongly and recover from. This question
      has no recovery, and an operator who has already pressed y to four
      prompts will press it to a fifth. Typing DELETE cannot be done by
      momentum.

      Everything that will be destroyed is enumerated immediately above the
      prompt, with sizes, so the decision is made against facts rather than
      against the word "completely".
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Survey
    )

    $rule = '-' * $Script:DeltaBannerWidth
    Write-Host ''
    Write-Host $rule
    Write-Host ''
    Write-Host 'This will permanently delete:' -ForegroundColor Yellow
    Write-Host ''
    if ($Survey.VolumePresent) {
        Write-Detail "Docker volume $($Target.PgDataVolume)"
        Write-Detail '  the entire DELTA database - every record, user and upload reference'
    }
    foreach ($directory in $Survey.Directories) {
        if (-not $directory.Exists -or $directory.Items -eq 0) { continue }
        Write-Detail "$($directory.Path)"
        Write-Detail "  $($directory.Items) file(s), $(Format-DeltaByteSize $directory.Bytes)"
    }
    Write-Detail "$($Target.InstallRoot)"
    Write-Detail '  the installation root itself, including .env and docker-compose.yml'
    Write-Host ''
    Write-Host 'There is no undo. A backup taken now is the only way to get any of it back.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Type DELETE to confirm, or anything else to cancel.'
    Write-Host ''

    $answer = Read-Host -Prompt 'Confirm'
    Write-Host ''
    Write-Host $rule

    # Case-sensitive and exact. "delete" is what somebody types while thinking
    # about something else.
    $confirmed = ([string]$answer).Trim() -ceq 'DELETE'
    Write-DeltaLogLine -Message "Destructive uninstall confirmation: $(if ($confirmed) { 'confirmed' } else { 'declined' })" -Level 'DETAIL'
    return $confirmed
}

function Read-DeltaFinalBackupChoice {
    <#
      Offered only on the destructive path, and only when there is a running
      database to dump. Declining is a legitimate answer - somebody
      decommissioning a test installation does not need a dump of it - so the
      consequence is stated once, plainly, instead of being argued.

      The destination defaults outside the installation root, because a
      backup inside a directory that is about to be deleted is not a backup.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Survey
    )

    $result = [PSCustomObject]@{ Wanted = $false; Destination = $null; Reason = $null }

    $db = @($Survey.Containers) | Where-Object { $_.Name -match '-db-\d+$' -and $_.State -eq 'running' }
    if (-not $Survey.DockerAvailable) {
        $result.Reason = 'Docker is not reachable, so no final backup can be taken.'
        return $result
    }
    if (-not $db) {
        $result.Reason = 'The database container is not running, so no final backup can be taken. Any existing dumps in the backups directory will be deleted with the installation root - copy them out first if you want them.'
        return $result
    }

    $default = Join-Path -Path (Split-Path -Path $Target.InstallRoot -Parent) -ChildPath "$(Split-Path -Path $Target.InstallRoot -Leaf)-final-backup"

    $wanted = Read-DeltaYesNoConfirmation -Body {
        Write-Host 'Take a final verified backup of the database before deleting it?'
        Write-Host ''
        Write-Detail 'It is written outside the installation root, so it survives the removal.'
        Write-Detail "Default location:  $default"
        Write-Host ''
        Write-Detail 'Answering no means the database is deleted with no copy kept.'
    }
    if (-not $wanted) {
        $result.Reason = 'Declined. The database will be deleted with no backup.'
        return $result
    }

    Write-Host ''
    $answer = Read-Host -Prompt "Backup directory [$default]"
    $destination = ([string]$answer).Trim()
    if (-not $destination) { $destination = $default }

    $full = $destination
    try { $full = [System.IO.Path]::GetFullPath($destination).TrimEnd('\') } catch { }
    if ($full.ToLowerInvariant() -eq $Target.InstallRoot.ToLowerInvariant() -or
        $full.ToLowerInvariant().StartsWith($Target.InstallRoot.ToLowerInvariant() + '\')) {
        $result.Reason = "'$full' is inside the installation root, which is about to be deleted. Using $default instead."
        $full = $default
    }

    $result.Wanted = $true
    $result.Destination = $full
    return $result
}

function Show-DeltaUninstallOutcome {
    <#
      The closing report. Two rules govern it, both learned the hard way
      elsewhere in this project:

      Never say "completely removed" while something remains. A preserve-data
      uninstall says what it kept and where, because an operator who believes
      DELTA is gone and later finds 14 MB of backups has been told something
      untrue.

      Never report success over an unresolved step. A container that could not
      be removed, or a Docker engine that could not be reached, makes the run
      PARTIAL - and the remaining resources are named, so finishing the job by
      hand is possible.
    #>
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][object]$Target
    )

    $unresolved = @($Result.Steps | Where-Object { $_.Outcome -in @('Failed', 'Could not verify') })

    Write-Host ''
    if ($unresolved.Count -gt 0) {
        Write-DeltaWarning 'PARTIAL - DELTA was not completely uninstalled.'
        Write-Host ''
        Write-Detail 'These were not removed, or could not be checked:'
        foreach ($step in $unresolved) {
            Write-Detail "  $($step.Resource) - $($step.Detail)"
        }
        Write-Host ''
        Write-Detail 'Nothing else was changed. Re-run this script once the cause is resolved;'
        Write-Detail 'it continues from wherever the installation actually is.'
    }
    elseif ($Result.Mode -eq $Script:DeltaUninstallModeComplete) {
        Write-Success 'DELTA has been completely removed.'
        Write-Host ''
        Write-Detail "The containers, network, database volume and $($Target.InstallRoot) are gone."
        if ($Result.BackupPath) {
            Write-Detail "A verified final backup was kept at:"
            Write-Detail "  $($Result.BackupPath)"
        }
        else {
            Write-Detail 'No backup was kept. This installation cannot be recovered.'
        }
    }
    else {
        Write-Success 'The DELTA runtime has been removed. Your data was preserved.'
        Write-Host ''
        Write-Detail 'Preserved:'
        Write-Detail "  the database        volume $($Target.PgDataVolume)"
        foreach ($step in @($Result.Steps | Where-Object { $_.Kind -eq 'file' -and $_.Outcome -eq 'Preserved' })) {
            Write-Detail "  $($step.Resource)"
        }
        Write-Host ''
        Write-Detail 'To bring DELTA back with this data, run setup.ps1 again against the same'
        Write-Detail 'installation root:'
        Write-Detail ''
        Write-Detail "    .\setup.ps1 -InstallRoot `"$($Target.InstallRoot)`""
        Write-Detail ''
        Write-Detail 'To delete the preserved data as well, run this script again and choose'
        Write-Detail 'complete removal.'
    }

    Write-Host ''
    Write-Detail 'Docker Desktop, WSL and the other software on this machine were not changed.'
}
