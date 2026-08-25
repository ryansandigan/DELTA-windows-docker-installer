# =============================================================================
# Delta.Uninstall.ps1 - removing a DELTA Docker installation (Phase 12)
#
# The whole file is built around one property, taken directly from the
# reference installer's uninstall.ps1:
#
#     BACKUP FAILURE MAKES THE DELETION PATH UNREACHABLE.
#
# Not "unlikely", not "guarded by a flag somebody remembered to check" -
# unreachable. Backup-DeltaInstallation throws on every failure rather than
# returning a status, and Remove-DeltaInstallation cannot be called without a
# [Delta.VerifiedArchive] object that only Backup-DeltaInstallation produces.
# A caller cannot pass $true, cannot pass a hashtable, and cannot skip the
# parameter: PowerShell refuses the binding. The removal function then
# re-validates the object and the file it names before touching anything.
#
# The shape of the operation mirrors the reference installer:
#
#     fresh verified database dump
#         -> quiesce the runtime
#         -> archive the whole installation root to an external ZIP
#         -> verify the ZIP by opening it and looking for what must be in it
#         -> only then remove Docker resources and delete the installation
#
# There is one path and one outcome. The external ZIP under C:\DELTA-backups
# is the preservation mechanism, so there is no second "leave C:\DELTA where
# it is" mode - the data is preserved by being in the archive, not by being
# left behind.
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

# The one Compose service the uninstall is allowed to start.
#
# An uninstall must be able to uninstall a STOPPED installation, and the
# database backup that gates the deletion can only be taken from a running
# PostgreSQL. So the uninstaller starts the database when it has to - and only
# the database. Starting the DELTA application would run its schema migration,
# which is forward-only, on an installation that is about to be deleted;
# starting NGINX would republish port 80 on a host somebody has already moved
# on from. Neither is needed to run pg_dump, so neither is started, and the
# service name is a constant here so the start path cannot quietly grow a
# second entry.
$Script:DeltaDatabaseServiceName = 'db'

# How long PostgreSQL gets to become healthy after the uninstaller starts it.
# The container's own healthcheck allows a 60-second start_period and a cold
# start on a busy host genuinely takes most of it; this has to be longer than
# that or the uninstall would abort on a database that was about to be ready.
$Script:DeltaUninstallDatabaseReadySeconds = 300

# Where the external archive goes. The reference installer's convention,
# reused deliberately: an operator who has uninstalled the native DELTA knows
# to look in C:\DELTA-backups, and a second convention would only mean two
# places to search. A single named constant, so the confirmation preview and
# the code that actually writes the file can never drift into two paths.
#
# It is a default, not a hard-coded destination: an installation at D:\DELTA
# should be able to archive to the same volume, and -BackupRoot exists for
# that. What it may never be is a directory inside the installation root -
# see New-DeltaInstallationArchive, which refuses that outright rather than
# writing an archive into the tree it is archiving.
$Script:DeltaUninstallBackupRoot = 'C:\DELTA-backups'

# Directories that are never deleted, whatever a state file found inside them
# claims.
#
# The primary guard against a catastrophic -InstallRoot has always been the
# ownership check: a directory with no readable .delta-install.json naming a
# Compose project is refused outright, so `uninstall.ps1 -InstallRoot C:\Windows`
# already stopped at "not a registered DELTA installation". That guard is
# necessary and it is not sufficient, because it can be satisfied. An operator
# who installs to a system directory - the install-root validator permits any
# absolute path on a fixed volume, including C:\Windows - or who drops a state
# file somewhere by hand or by restoring an archive to the wrong place, arrives
# at a registered installation whose root must still never be handed to a
# recursive delete.
#
# So this list is a second, independent refusal that does not consult the state
# file at all. It is resolved at load time from the environment rather than
# hard-coded, because these paths are not C:\Windows and C:\Program Files on
# every host.
#
# Note what is NOT protected: a directory *inside* one of these. C:\Program
# Files\DELTA is a legitimate installation root and deleting it takes nothing
# else with it. Only the protected directory itself, and any directory that
# CONTAINS one, is refused - see Test-DeltaUninstallPathSafe.
#
# Built defensively, because this runs at load time in a library the
# uninstaller dot-sources under $ErrorActionPreference = 'Stop': an unset
# environment variable must produce a shorter list, never a throw that stops
# the uninstaller from starting at all.
$Script:DeltaProtectedUninstallPaths = @(
    & {
        $paths = New-Object 'System.Collections.Generic.List[string]'
        foreach ($value in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $env:PUBLIC)) {
            if ($value) { $null = $paths.Add($value) }
        }
        # The Users root, because deleting it would take every profile with it.
        if ($env:USERPROFILE) {
            try { $null = $paths.Add((Split-Path -Parent $env:USERPROFILE)) } catch { }
        }
        if ($env:SystemRoot) {
            try { $null = $paths.Add((Join-Path $env:SystemRoot 'System32')) } catch { }
        }
        foreach ($path in $paths) {
            if (-not $path) { continue }
            try { [System.IO.Path]::GetFullPath($path).TrimEnd('\') } catch { }
        }
    }
) | Where-Object { $_ } | Select-Object -Unique

# Directories excluded from the installation archive, expressed as paths
# relative to the installation root.
#
# It is empty, and that is a finding rather than an omission.
#
# The reference installer excludes node_modules, .next\cache, tmp, cache and
# service, because in that architecture the DELTA application itself lives in
# the installation directory: its source, its dependency tree, its build
# output and a downloaded service wrapper all sit alongside the operator's
# data, and all of them are reproducible from package.json / a pinned
# download.
#
# In the Docker architecture none of that is true. The application is in the
# image; it is re-obtained with `docker pull`, not from this directory. What
# the installation root actually contains was enumerated rather than assumed:
#
#     .env, .env.bak-*            configuration and secrets, and their history
#     .delta-install.json         the installation record
#     docker-compose.yml          generated, but from operator choices
#     nginx\conf.d\delta.conf     likewise
#     certs\                      certificate and private key
#     uploads\                    user-uploaded files
#     logs\delta, logs\nginx      application and access logs, incl. rotated
#     logs\installer              installer and startup transcripts
#     backups\*.dump              database dumps
#     backups\env-*.bak           .env snapshots taken before changes
#
# Every one of those is either irreplaceable or a record of what an operator
# did. There is no dependency tree, no build cache and no downloaded binary
# anywhere in it. So nothing is excluded - which is exactly the instruction
# "exclude only what is proven reproducible", applied to an architecture where
# the answer turns out to be nothing.
#
# Note in particular what is NOT excluded despite its name: uploads\<tenant>\
# temp is DELTA's own upload staging directory. It sits inside user data, its
# contents belong to the application rather than to a build, and excluding a
# directory because it is called "temp" would be guessing at DELTA's
# internals. The reference installer draws the same line - its exclusions are
# matched only at the top level and never inside uploads\ or logs\.
#
# The mechanism is kept, and the walk below prunes correctly at a directory
# boundary, so adding an exclusion later is a one-line change with tested
# semantics rather than a new traversal.
$Script:DeltaArchiveExclusionPatterns = @()

# The entries an archive of a DELTA installation must contain to be worth
# trusting. Checked by name, and each is checked for non-zero length as well.
# Relative to the archive's single top-level folder.
#
# This list is a floor, not the completeness check. Completeness is proven
# against the pre-backup recursive inventory - every file the walk saw must be
# in the archive at its recorded size - and that is what makes a directory
# nobody listed here impossible to lose silently. These four are named
# separately because their ABSENCE has a specific meaning worth saying out
# loud: an archive without .env cannot be restored from at all.
$Script:DeltaArchiveRequiredEntries = @(
    @{ Path = '.env';                    Description = 'configuration and secrets' }
    @{ Path = 'docker-compose.yml';      Description = 'the Compose stack definition' }
    @{ Path = '.delta-install.json';     Description = 'the installation record' }
    @{ Path = 'nginx/conf.d/delta.conf'; Description = 'the generated NGINX configuration' }
)

# Directories whose contents must be represented in the archive whenever the
# installation actually has any, reported by name so the operator sees the
# categories they care about confirmed individually rather than only as part
# of a file count. Each is "when present": demanding certs\ from a plain-HTTP
# installation would be inventing a requirement.
$Script:DeltaArchiveRepresentedDirectories = @(
    @{ Path = 'uploads'; Description = 'user-uploaded files' }
    @{ Path = 'logs';    Description = 'application, access and installer logs' }
    @{ Path = 'certs';   Description = 'certificate material' }
    @{ Path = 'backups'; Description = 'database dumps and .env snapshots' }
)

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

function Test-DeltaPathContains {
    <#
      Whether $Child is $Parent or sits underneath it, compared on resolved
      paths with a separator-aware prefix test.

      Never a bare StartsWith on the raw strings: 'C:\DELTA' StartsWith
      'C:\DELT' is true, and 'C:\DELTA-backups' StartsWith 'C:\DELTA' is true -
      which is the exact pair this function exists to keep apart, since the
      backup root lives next to the installation root and must never be judged
      to be inside it.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Parent,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Child
    )

    if ([string]::IsNullOrWhiteSpace($Parent) -or [string]::IsNullOrWhiteSpace($Child)) { return $false }

    $p = $null; $c = $null
    try {
        $p = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
        $c = [System.IO.Path]::GetFullPath($Child).TrimEnd('\')
    }
    catch { return $false }

    if ($c -ieq $p) { return $true }
    return $c.StartsWith("$p\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-DeltaUninstallPathSafe {
    <#
      The last question asked before a recursive delete: may this path be
      removed at all?

      Independent of ownership on purpose. Get-DeltaUninstallTarget answers
      "did DELTA create this", which is a question about a JSON file that can
      be wrong, moved, or restored into the wrong directory. This answers "is
      this a path anything may ever delete", which is a question about the
      machine, and the two failures it catches are the ones ownership cannot:
      a state file that ended up somewhere it should not be, and an
      installation root that legitimately IS somewhere it should not be.

      Four refusals:

        1. An empty or unrooted path. GetFullPath would resolve a relative
           string against the current directory, so 'DELTA' becomes whatever
           the process happened to be sitting in.
        2. A drive root. C:\ and D:\ are refused whatever they contain.
        3. A protected system directory, or any directory CONTAINING one -
           C:\Users is refused because the profile is inside it, not because
           of its name.
        4. A directory that contains the backup. Deleting the installation
           root must not delete the archive that makes deleting it safe, which
           is the same rule New-DeltaInstallationArchive enforces from the
           other end when it refuses to write inside the tree.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Path,
        [string]$BackupRoot,
        [string]$ArchivePath
    )

    $result = [PSCustomObject]@{ Path = $Path; Safe = $false; Reason = $null }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.Reason = 'No installation root was resolved, so there is nothing to delete. Refusing to act on an empty path.'
        return $result
    }
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $result.Reason = "'$Path' is not an absolute path. Refusing to delete a path that would be resolved against the current directory."
        return $result
    }

    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch {
        $result.Reason = "'$Path' could not be resolved to a full path: $($_.Exception.Message)"
        return $result
    }

    $root = $null
    try { $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\') } catch { }
    if ($root -and ($full -ieq $root)) {
        $result.Reason = "Refusing to delete the drive root '$full', whatever its state file says."
        return $result
    }

    foreach ($protected in $Script:DeltaProtectedUninstallPaths) {
        if ($full -ieq $protected) {
            $result.Reason = "Refusing to delete '$full': it is a protected Windows directory."
            return $result
        }
        if (Test-DeltaPathContains -Parent $full -Child $protected) {
            $result.Reason = "Refusing to delete '$full': the protected directory '$protected' is inside it."
            return $result
        }
    }

    foreach ($preserve in @($BackupRoot, $ArchivePath)) {
        if (-not $preserve) { continue }
        if (Test-DeltaPathContains -Parent $full -Child $preserve) {
            $result.Reason = "Refusing to delete '$full': the backup at '$preserve' is inside it, and the archive is the only copy of the data."
            return $result
        }
    }

    $result.Safe = $true
    return $result
}

function Get-DeltaInstalledRootCandidate {
    <#
      Where DELTA is actually installed on this host, read from the scheduled
      tasks a previous install registered.

      This exists because -InstallRoot defaults to C:\DELTA and the installer
      does not require that root. An operator who installed to D:\DELTA and
      then runs a bare `.\uninstall.ps1` gets "No DELTA Docker installation was
      found" - which is true of C:\DELTA, and is read as true of the machine.
      The uninstaller then exits 0 having done nothing, and the installation it
      was pointed away from is still there.

      A scheduled task is the right place to look because it is the only record
      DELTA writes outside the installation root that names the installation
      root: both tasks run

          powershell.exe ... -File <installer dir>\bin\<script>.ps1 -InstallRoot <root>

      and both are registered under a name built from the Compose project. So
      the task name gives the project and the action gives the root, which is
      the whole identity - and it is authoritative in the sense that matters
      here: it is what this machine will actually run at the next boot.

      This never deletes and never decides. It reports candidates; the caller
      chooses, and a candidate is still put through Get-DeltaUninstallTarget's
      ownership check before anything happens to it.
    #>
    param([string]$TaskNamePattern = 'DELTA (Docker) - *')

    $candidates = New-Object 'System.Collections.Generic.List[object]'

    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -like $TaskNamePattern })
    }
    catch { return @() }

    foreach ($task in $tasks) {
        # 'DELTA (Docker) - <project> - Startup' / '... - NGINX log rotation'.
        # The project may itself contain ' - ', so the suffix is trimmed from
        # the right rather than the name being split on the separator.
        $project = $null
        foreach ($suffix in @(' - Startup', ' - NGINX log rotation')) {
            if ($task.TaskName.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $project = $task.TaskName.Substring(0, $task.TaskName.Length - $suffix.Length)
                $project = $project -replace '^DELTA \(Docker\) - ', ''
                break
            }
        }
        if (-not $project) { continue }

        foreach ($action in @($task.Actions)) {
            $arguments = [string]$action.Arguments
            if (-not $arguments) { continue }
            if ($arguments -notmatch '-InstallRoot\s+(?:"([^"]+)"|(\S+))') { continue }

            $root = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            try { $root = [System.IO.Path]::GetFullPath($root).TrimEnd('\') } catch { continue }

            $null = $candidates.Add([PSCustomObject]@{
                InstallRoot = $root
                ProjectName = $project
                TaskName    = $task.TaskName
                Exists      = (Test-Path -LiteralPath $root -PathType Container)
            })
        }
    }

    # One installation registers two tasks, so the same root arrives twice.
    return @($candidates | Group-Object -Property InstallRoot | ForEach-Object { $_.Group[0] })
}

function Get-DeltaContainingInstallation {
    <#
      The registered DELTA installation that $Path is inside, if any - $Path
      itself, or the nearest ancestor of it that is one.

      This answers "which installation is this run happening in", and it exists
      because of a near-miss found by real destructive integration testing.
      `.\uninstall.ps1` run from inside one installation, with no -InstallRoot,
      took the parameter default: it surveyed C:\DELTA, listed C:\DELTA's
      containers, offered to delete C:\DELTA's data volume and asked for the
      typed DELETE - while the operator was standing in, and had just launched
      the uninstaller of, a completely different installation. Nothing was
      destroyed only because the other installation's database container
      happened to be stopped, so the mandatory backup could not be taken and
      the run aborted. With it running, DELETE would have destroyed the wrong
      installation, and the archive would have been of the wrong installation
      too.

      A parameter default is a guess about which installation is meant. The
      directory the uninstaller was launched from is evidence: an operator who
      runs <root>\uninstall.ps1 is uninstalling <root>, and no default should
      outrank that.

      The walk goes upwards so that running it from <root>\bin or <root>\logs
      resolves to <root> - the operator is still standing in that installation.
      It stops at the drive root and never crosses to a parent that is not a
      registered installation, so a directory that merely sits above several
      installations resolves to none of them.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $current = $null
    try { $current = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $null }

    $guard = 0
    while ($current -and $guard -lt 64) {
        $guard++

        $root = $null
        try { $root = [System.IO.Path]::GetPathRoot($current).TrimEnd('\') } catch { }
        # A drive root is never an installation root, and is where the walk ends.
        if ($root -and ($current -ieq $root)) { return $null }

        if (Test-Path -LiteralPath $current -PathType Container) {
            $candidate = Get-DeltaUninstallTarget -InstallRoot $current
            if ($candidate.Registered) { return $candidate }
        }

        $parent = $null
        try { $parent = Split-Path -Path $current -Parent } catch { }
        if (-not $parent -or $parent -ieq $current) { return $null }
        $current = $parent.TrimEnd('\')
    }
    return $null
}

function Get-DeltaUninstallSurvey {
    <#
      What of the target actually exists right now.

      Separate from Get-DeltaUninstallTarget on purpose: that function answers
      "what would this installation own", which is a question about two files,
      and this one answers "what is still here", which is a question about the
      machine. Keeping them apart is what lets a rerun after an interrupted
      uninstall describe itself accurately rather than reporting resources it
      has already removed.

      -DockerAvailable false skips every Docker query and marks those rows
      Unknown rather than Absent. "I could not look" and "it is not there" are
      different answers and only one of them justifies saying cleanup is done.

      The filesystem half is a single recursive walk of the WHOLE installation
      root - the same walk the archive itself uses - rather than a list of
      directory names this file knows about. That is deliberate and it is the
      fix for a real hazard: a survey built from @('uploads','backups','certs',
      'logs','nginx') describes an installation that grew a sixth directory as
      though the sixth directory were not there, and the operator confirms a
      deletion against a plan that under-reports what is about to go. Walking
      the root means a directory nobody has thought of yet is counted, shown,
      archived and verified without anyone remembering to add it here.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [bool]$DockerAvailable = $true
    )

    # Four Docker queries and a recursive walk of the installation root, which
    # on a real installation is where the gigabytes are. -WhenIdle: the
    # uninstall announces its own steps, and this runs inside them.
    return (Invoke-DeltaActivity -Message 'Surveying what is still installed' -WhenIdle -ScriptBlock {

    $survey = [PSCustomObject]@{
        DockerAvailable = $DockerAvailable
        Containers      = @()
        DatabaseState   = $null
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
        TotalFiles      = 0
        TotalBytes      = 0
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

        # The db service specifically, because the uninstall has to back it up
        # and the interesting case is that it is stopped. Reported, never acted
        # on here - the survey is what the operator confirms against.
        if (Test-Path -LiteralPath $Target.ComposeFile -PathType Leaf) {
            $dbService = @(Get-DeltaComposeServiceStatus -InstallRoot $Target.InstallRoot -ProjectName $Target.ProjectName) |
                Where-Object { $_.Service -eq $Script:DeltaDatabaseServiceName } | Select-Object -First 1
            $survey.DatabaseState = if ($dbService) { $dbService.State } else { 'absent' }
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

    # One walk of the whole root, grouped by its top-level entries. Every
    # directory under the root is reported whether or not this file has ever
    # heard of it, including one created by a future version of the installer.
    if (Test-Path -LiteralPath $Target.InstallRoot -PathType Container) {
        $inventory = Get-DeltaArchiveFileList -RootPath $Target.InstallRoot
        $survey.TotalFiles = @($inventory.Files).Count
        $survey.TotalBytes = $inventory.TotalBytes

        $byTop = @{}
        $topFiles = New-Object 'System.Collections.Generic.List[object]'
        foreach ($file in $inventory.Files) {
            $separator = $file.RelativePath.IndexOf('\')
            if ($separator -lt 0) {
                $null = $topFiles.Add([PSCustomObject]@{
                    Name = $file.RelativePath; Path = $file.FullName; Exists = $true; Bytes = $file.Length
                })
                continue
            }
            $top = $file.RelativePath.Substring(0, $separator)
            if (-not $byTop.ContainsKey($top)) {
                $byTop[$top] = [PSCustomObject]@{
                    Name = $top; Path = (Join-Path -Path $Target.InstallRoot -ChildPath $top)
                    Exists = $true; Bytes = [long]0; Items = 0
                }
            }
            $byTop[$top].Items++
            $byTop[$top].Bytes += $file.Length
        }

        # A directory holding no files at all still exists and is still deleted,
        # so it is still shown - the walk above only sees directories through
        # their contents.
        foreach ($directory in @(Get-ChildItem -LiteralPath $Target.InstallRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($byTop.ContainsKey($directory.Name)) { continue }
            $byTop[$directory.Name] = [PSCustomObject]@{
                Name = $directory.Name; Path = $directory.FullName; Exists = $true; Bytes = [long]0; Items = 0
            }
        }

        $survey.Directories = @($byTop.Values | Sort-Object -Property Name)
        $survey.Files       = @($topFiles | Sort-Object -Property Name)
        $survey.DataBytes   = if ($survey.Directories.Count -gt 0) { [long](($survey.Directories | Measure-Object -Property Bytes -Sum).Sum) } else { [long]0 }
    }

    return $survey

    })
}

# ---------------------------------------------------------------------------
# The archive
#
# Adapted from the reference installer's New-DeltaApplicationBackupArchive and
# Get-DeltaApplicationBackupFileList, with the same two structural decisions:
# a direct ZipArchive rather than Compress-Archive, and an explicit walk that
# prunes at a directory boundary rather than filtering a full recursive
# listing afterwards.
# ---------------------------------------------------------------------------

function Test-DeltaArchivePathExcluded {
    <#
      Whether a path relative to the installation root falls under one of the
      exclusion patterns - an exact match, or a prefix followed by a path
      separator so a nested path is caught. Never a bare substring match,
      which would also exclude an unrelated sibling like "backups2" or match
      "logs" against something merely containing the word. Case-insensitive,
      matching Windows' own filesystem semantics.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RelativePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExclusionPatterns
    )

    foreach ($pattern in $ExclusionPatterns) {
        if ($RelativePath -ieq $pattern) { return $true }
        if ($RelativePath.StartsWith("$pattern\", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DeltaArchiveFileList {
    <#
      Walks the installation root with an explicit stack rather than
      Get-ChildItem -Recurse, so an excluded directory is never enumerated at
      all instead of being enumerated and then filtered out. With the current
      empty exclusion set that costs nothing; it matters the moment a
      directory ever does need excluding, and it is the traversal the
      reference installer settled on for the same reason.

      The root is resolved through Get-Item, not by trimming the string,
      because the two can disagree - a short 8.3-form path resolves to its
      long form once the filesystem provider touches it - and every
      descendant's FullName comes from that same provider. A length mismatch
      would silently corrupt every relative path computed by Substring below.

      Returns Files (FullName + backslash-separated RelativePath),
      ExcludedDirectories, TotalBytes.
    #>
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [AllowEmptyCollection()][string[]]$ExclusionPatterns = $Script:DeltaArchiveExclusionPatterns
    )

    $normalizedRoot = (Get-Item -LiteralPath $RootPath).FullName.TrimEnd('\')
    $files = New-Object 'System.Collections.Generic.List[object]'
    $excluded = New-Object 'System.Collections.Generic.List[string]'
    $totalBytes = [long]0

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($normalizedRoot)

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue)) {
            $relative = $item.FullName.Substring($normalizedRoot.Length + 1)

            if ($item.PSIsContainer) {
                if (Test-DeltaArchivePathExcluded -RelativePath $relative -ExclusionPatterns $ExclusionPatterns) {
                    $null = $excluded.Add($relative)
                    continue
                }
                $pending.Push($item.FullName)
                continue
            }

            if (Test-DeltaArchivePathExcluded -RelativePath $relative -ExclusionPatterns $ExclusionPatterns) {
                continue
            }
            $totalBytes += $item.Length
            $null = $files.Add([PSCustomObject]@{ FullName = $item.FullName; RelativePath = $relative; Length = $item.Length })
        }
    }

    return [PSCustomObject]@{
        Files               = $files.ToArray()
        ExcludedDirectories = $excluded.ToArray()
        TotalBytes          = $totalBytes
    }
}

function New-DeltaInstallationArchive {
    <#
      Writes every file under the installation root into one ZIP, under a
      single top-level folder named after the installation directory - the
      same wrapping shape `Compress-Archive -Path <directory>` produces, and
      what an operator expects when they open the file.

      Not Compress-Archive, for two measured reasons: Windows PowerShell 5.1's
      version has no exclude parameter and no way to build an archive from a
      filtered file list, and it fails on archives past 2 GB - which an
      installation with real uploads will reach. ZipFile/ZipArchive has
      neither limit and streams each file in with CreateEntryFromFile, so no
      staging copy of the tree is ever made on disk.

      It refuses to write into the directory it is archiving. That is not
      hypothetical tidiness: an archive being written inside its own source
      tree is a file that grows as it is read, and the walk would either
      include a partial copy of the archive in itself or fail part-way.

      Every file that cannot be added is collected and returned rather than
      swallowed. The caller treats any failure as fatal, because a backup
      missing a file it did not mention is worse than no backup at all.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

    $normalizedSource = (Get-Item -LiteralPath $SourceDirectory).FullName.TrimEnd('\')
    $rootFolderName   = Split-Path -Path $normalizedSource -Leaf

    $destinationFull = [System.IO.Path]::GetFullPath($DestinationPath)
    if ($destinationFull.StartsWith($normalizedSource + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-Setup "Refusing to write the backup archive to '$destinationFull': it is inside the installation root being archived. Choose a destination outside '$normalizedSource'."
    }

    $list = Get-DeltaArchiveFileList -RootPath $normalizedSource
    if ($list.ExcludedDirectories.Count -gt 0) {
        Write-Detail "Excluded (reproducible): $($list.ExcludedDirectories -join ', ')"
    }
    if ($list.Files.Count -eq 0) {
        Stop-Setup "There are no files under '$normalizedSource' to archive. Nothing was deleted."
    }

    $parent = Split-Path -Path $destinationFull -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    if (Test-Path -LiteralPath $destinationFull -PathType Leaf) {
        # A name collision means two uninstalls in the same second, which
        # should not happen - and overwriting somebody's only archive to
        # resolve it would be the wrong way round.
        Stop-Setup "A backup archive already exists at '$destinationFull'. Nothing was overwritten and nothing was deleted."
    }

    $failures = New-Object 'System.Collections.Generic.List[string]'
    $added = 0
    $zip = [System.IO.Compression.ZipFile]::Open($destinationFull, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $list.Files) {
            $entryName = "$rootFolderName/$($file.RelativePath -replace '\\', '/')"
            try {
                $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $added++
            }
            catch {
                $null = $failures.Add("$($file.RelativePath): $($_.Exception.Message)")
            }
        }
    }
    finally {
        $zip.Dispose()
    }

    return [PSCustomObject]@{
        Path           = $destinationFull
        RootFolderName = $rootFolderName
        FileCount      = $list.Files.Count
        AddedCount     = $added
        SourceBytes    = $list.TotalBytes
        Failures       = $failures.ToArray()
        # The inventory this archive was built from, carried out so the
        # verification can be a comparison against what was actually on disk
        # rather than against a list of names somebody wrote down. It is the
        # difference between "the archive contains the four files I remembered
        # to check for" and "the archive contains the installation".
        Inventory      = $list.Files
    }
}

function Test-DeltaInstallationArchive {
    <#
      Proves the archive is worth deleting an installation for.

      The reference installer opens the ZIP and checks the entry count is
      greater than zero. That catches a truncated or corrupt file, which is
      most of the value, but it cannot distinguish a good archive from one
      that opened cleanly and happens to contain nothing that matters. So this
      does five more things:

        1. Every file the pre-backup walk saw must be present as an entry, at
           the size the walk recorded. Not a count comparison - the actual
           inventory, path by path. A count can match while the contents do
           not, and this is the check that makes "the entire InstallRoot is in
           the archive" a verified statement rather than an intention. It is
           also what makes a directory this file has never heard of impossible
           to lose silently: it was walked, so it is checked.
        2. The entries that must exist, must exist - .env, the Compose file,
           the installation record, the generated NGINX configuration - and
           each must have non-zero length.
        3. uploads\, logs\, certs\ and backups\ must each be represented
           whenever the source had files in them, with at least as many entries
           as the source had files. Redundant against check 1 by construction,
           and kept because it names the categories an operator asks about, so
           a failure says "the uploads are missing" rather than only "142 files
           are missing".
        4. Certificate material specifically, for an installation with TLS
           enabled, whose certs\ must not be empty.
        5. The fresh database dump must be present, its compressed entry must
           report the same uncompressed length as the file on disk, and the
           first five bytes read back out of the archive must be PGDMP.

      That last one is the difference between "a file with the right name is
      in the ZIP" and "the database is in the ZIP". It costs one stream read.
    #>
    param(
        [Parameter(Mandatory)][object]$Archive,
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$DatabaseBackup
    )

    $result = [PSCustomObject]@{
        Verified       = $false
        EntryCount     = 0
        SizeBytes      = 0
        Missing        = @()
        Reason         = $null
        DumpEntry      = $null
        UploadCount    = 0
        InventoryCount = 0
        Represented    = @()
    }

    if (-not (Test-Path -LiteralPath $Archive.Path -PathType Leaf)) {
        $result.Reason = "No archive was created at '$($Archive.Path)'."
        return $result
    }
    $result.SizeBytes = (Get-Item -LiteralPath $Archive.Path).Length

    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

    $missing = New-Object 'System.Collections.Generic.List[string]'
    $prefix = "$($Archive.RootFolderName)/"

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive.Path)
    }
    catch {
        $result.Reason = "The archive at '$($Archive.Path)' could not be opened: $($_.Exception.Message)"
        return $result
    }

    try {
        $entries = @{}
        foreach ($entry in $zip.Entries) { $entries[$entry.FullName] = $entry }
        $result.EntryCount = $zip.Entries.Count

        if ($result.EntryCount -eq 0) {
            $result.Reason = "The archive at '$($Archive.Path)' is empty."
            return $result
        }
        if ($result.EntryCount -ne $Archive.FileCount) {
            $result.Reason = "The archive holds $($result.EntryCount) entries but $($Archive.FileCount) files were walked. Something was not written."
            return $result
        }

        # 1. The completeness check: the actual pre-backup inventory, path by
        #    path and size by size. Reported truncated because an archive that
        #    dropped ten thousand files is not made clearer by naming all of
        #    them, and the count is what matters for the decision.
        $inventoryMissing = New-Object 'System.Collections.Generic.List[string]'
        foreach ($file in @($Archive.Inventory)) {
            $result.InventoryCount++
            $name = "$prefix$($file.RelativePath -replace '\\', '/')"
            if (-not $entries.ContainsKey($name)) {
                if ($inventoryMissing.Count -lt 10) { $null = $inventoryMissing.Add($file.RelativePath) }
                continue
            }
            if ($entries[$name].Length -ne $file.Length) {
                if ($inventoryMissing.Count -lt 10) {
                    $null = $inventoryMissing.Add("$($file.RelativePath) (archived at $($entries[$name].Length) bytes, $($file.Length) on disk)")
                }
            }
        }
        if ($inventoryMissing.Count -gt 0) {
            $null = $missing.Add("$($inventoryMissing.Count) file(s) walked under '$($Target.InstallRoot)' are not in the archive as walked: $($inventoryMissing -join ', ')")
        }

        foreach ($required in $Script:DeltaArchiveRequiredEntries) {
            $name = "$prefix$($required.Path)"
            if (-not $entries.ContainsKey($name)) {
                $null = $missing.Add("$($required.Path) ($($required.Description))")
                continue
            }
            if ($entries[$name].Length -le 0) {
                $null = $missing.Add("$($required.Path) is present but empty")
            }
        }

        # Certificate material, but only when this installation actually has
        # TLS enabled - demanding delta.crt from a plain-HTTP installation
        # would be inventing a requirement.
        if ($Target.Configuration -and $Target.Configuration.TlsEnabled) {
            foreach ($certFile in @('certs/delta.crt', 'certs/delta.key')) {
                $name = "$prefix$certFile"
                if (-not $entries.ContainsKey($name) -or $entries[$name].Length -le 0) {
                    $null = $missing.Add("$certFile (certificate material for an HTTPS installation)")
                }
            }
        }

        # Uploads, logs, certificates and previous backups - each when the
        # source had any, each counted from the same inventory the archive was
        # built from rather than by walking the disk a second time.
        $represented = New-Object 'System.Collections.Generic.List[object]'
        foreach ($directory in $Script:DeltaArchiveRepresentedDirectories) {
            $sourceCount = @($Archive.Inventory | Where-Object {
                $_.RelativePath.StartsWith("$($directory.Path)\", [System.StringComparison]::OrdinalIgnoreCase)
            }).Count
            $archivedCount = @($zip.Entries | Where-Object {
                $_.FullName.StartsWith("$prefix$($directory.Path)/", [System.StringComparison]::OrdinalIgnoreCase)
            }).Count

            $null = $represented.Add([PSCustomObject]@{
                Path = $directory.Path; Description = $directory.Description
                SourceCount = $sourceCount; ArchivedCount = $archivedCount
            })
            if ($sourceCount -gt 0 -and $archivedCount -lt $sourceCount) {
                $null = $missing.Add("$($directory.Path) ($($directory.Description)): $sourceCount file(s) on disk but $archivedCount in the archive")
            }
            if ($directory.Path -eq 'uploads') { $result.UploadCount = $archivedCount }
        }
        $result.Represented = $represented.ToArray()

        # The fresh dump: present, same size, and actually a dump.
        $dumpName = "${prefix}backups/$($DatabaseBackup.FileName)"
        $result.DumpEntry = $dumpName
        if (-not $entries.ContainsKey($dumpName)) {
            $null = $missing.Add("backups/$($DatabaseBackup.FileName) (the database backup taken for this uninstall)")
        }
        else {
            $dumpEntry = $entries[$dumpName]
            if ($dumpEntry.Length -ne $DatabaseBackup.SizeBytes) {
                $null = $missing.Add("the database backup is $($dumpEntry.Length) bytes in the archive but $($DatabaseBackup.SizeBytes) on disk")
            }
            else {
                $magic = New-Object byte[] 5
                $read = 0
                $stream = $null
                try {
                    $stream = $dumpEntry.Open()
                    $read = $stream.Read($magic, 0, 5)
                }
                catch {
                    $null = $missing.Add("the database backup could not be read back out of the archive: $($_.Exception.Message)")
                }
                finally {
                    if ($stream) { $stream.Dispose() }
                }
                if ($read -eq 5) {
                    $text = [System.Text.Encoding]::ASCII.GetString($magic)
                    if ($text -cne 'PGDMP') {
                        $null = $missing.Add("the database backup in the archive does not begin with PGDMP (found '$text')")
                    }
                }
                elseif ($read -ne 0) {
                    $null = $missing.Add('the database backup in the archive is too short to be a dump')
                }
            }
        }
    }
    finally {
        if ($zip) { $zip.Dispose() }
    }

    $result.Missing = $missing.ToArray()
    if ($result.Missing.Count -gt 0) {
        $result.Reason = "The archive is missing or cannot confirm: $($result.Missing -join '; ')"
        return $result
    }

    $result.Verified = $true
    return $result
}

# ---------------------------------------------------------------------------
# The safety gate
#
# Everything above is a tool. This is the rule.
# ---------------------------------------------------------------------------

function Get-DeltaComposeServiceOperand {
    <#
      The service names a Compose argument vector actually acts on.

      Not "which arguments look like service names" - that question has a wrong
      answer that this product produces routinely, because this installation's
      PostgreSQL user and database are both called `delta`. A vector reading

          exec -T db pg_isready -U delta -d delta

      contains the word `delta` twice and acts on exactly one service. So the
      vector is read the way Compose reads it: the first bare token is the
      subcommand, flags are skipped, and the bare tokens after the subcommand
      are the service operands - except for `exec` and `run`, where the FIRST
      bare token is the service and everything after it is the command line
      inside the container and is not a service name at all.

      An empty Services list means "every service in the project", which is
      what `stop` with no operand does.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)

    $subcommand = $null
    $operands = New-Object 'System.Collections.Generic.List[string]'

    foreach ($token in $Arguments) {
        $value = ([string]$token).Trim()
        if (-not $value) { continue }
        if ($value.StartsWith('-')) { continue }
        if (-not $subcommand) { $subcommand = $value.ToLowerInvariant(); continue }
        $null = $operands.Add($value)
        if ($subcommand -in @('exec', 'run')) { break }
    }

    return [PSCustomObject]@{ Subcommand = $subcommand; Services = $operands.ToArray() }
}

function Invoke-DeltaDatabaseOnlyCompose {
    <#
      Runs one Compose command that may only ever act on the database service.

      The uninstall is allowed to start PostgreSQL - it has to, or a stopped
      installation could never be backed up and therefore could never be
      uninstalled. It is not allowed to start the DELTA application, whose
      start IS a forward-only schema migration, or NGINX, which would republish
      a port on a host the operator is clearing. That rule is enforced here on
      the argument vector rather than trusted to the call sites, for the same
      reason Invoke-DeltaComposeDown inspects its own arguments for -v: a guard
      that refuses is a test that runs, and a comment is neither.

      It is a whitelist, not a blacklist: the operand has to BE the database
      service. A vector naming no service at all is refused too, because in
      Compose that means "all of them" - `stop` with no operand stops the whole
      project, which is a legitimate thing for the uninstall to do and not a
      legitimate thing for it to do through this channel.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 300
    )

    $parsed = Get-DeltaComposeServiceOperand -Arguments $Arguments
    $refusal = $null
    if (@($parsed.Services).Count -eq 0) {
        $refusal = "it names no service, which in Compose means every service in the project"
    }
    else {
        $foreign = @($parsed.Services | Where-Object { $_.ToLowerInvariant() -ne $Script:DeltaDatabaseServiceName })
        if ($foreign.Count -gt 0) {
            $refusal = "it acts on $($foreign -join ', ')"
        }
    }

    if ($refusal) {
        return [PSCustomObject]@{
            ExitCode = -1
            StdOut   = ''
            StdErr   = "Refusing to run 'docker compose $($Arguments -join ' ')': $refusal, and the uninstall may act on the database service and nothing else. Nothing but PostgreSQL is needed to take a database backup."
            Refused  = $true
        }
    }

    $capture = Invoke-DeltaCompose -InstallRoot $Target.InstallRoot -ProjectName $Target.ProjectName `
        -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    return ([PSCustomObject]@{ ExitCode = $capture.ExitCode; StdOut = $capture.StdOut; StdErr = $capture.StdErr; Refused = $false })
}

function Test-DeltaDatabaseAcceptingConnections {
    <#
      Whether PostgreSQL will accept the connection pg_dump is about to make.

      pg_isready inside the db container, with this installation's own user and
      database - the identical probe the container's healthcheck runs, asked
      directly. Asked directly rather than read off the healthcheck because the
      healthcheck is a property of the generated compose file: an installation
      created before it existed, or one whose file was hand-edited, reports no
      health at all and would otherwise be waited on until the timeout while
      being perfectly ready.
    #>
    param([Parameter(Mandatory)][object]$Target)

    if (-not $Target.Configuration) { return $false }

    $capture = Invoke-DeltaDatabaseOnlyCompose -Target $Target -TimeoutSeconds 60 -Arguments @(
        'exec', '-T', $Script:DeltaDatabaseServiceName,
        'pg_isready', '-U', $Target.Configuration.PostgresUser, '-d', $Target.Configuration.PostgresDb
    )
    return ($capture.ExitCode -eq 0)
}

function Wait-DeltaDatabaseReadyForBackup {
    <#
      Waits for the db service to be running AND accepting connections, or
      reports why it did not.

      A container that has exited is reported at once rather than waited on:
      PostgreSQL that fails to start fails within seconds, and spending five
      minutes proving it would only delay the abort.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [int]$TimeoutSeconds = $Script:DeltaUninstallDatabaseReadySeconds
    )

    return (Invoke-DeltaActivity -Message 'Waiting for PostgreSQL' -WhenIdle -ScriptBlock {
        $started    = Get-Date
        $deadline   = $started.AddSeconds($TimeoutSeconds)
        $lastReport = $started
        $observed   = 'the db container was never seen'

        while ((Get-Date) -lt $deadline) {
            $service = @(Get-DeltaComposeServiceStatus -InstallRoot $Target.InstallRoot -ProjectName $Target.ProjectName) |
                Where-Object { $_.Service -eq $Script:DeltaDatabaseServiceName } | Select-Object -First 1

            if ($service) {
                $observed = if ($service.Status) { $service.Status } else { $service.State }
                if ($service.State -in @('exited', 'dead')) {
                    return [PSCustomObject]@{ Ready = $false; Observed = $observed; ElapsedSeconds = [int]((Get-Date) - $started).TotalSeconds }
                }
                if ($service.State -eq 'running' -and (Test-DeltaDatabaseAcceptingConnections -Target $Target)) {
                    $elapsed = [int]((Get-Date) - $started).TotalSeconds
                    Write-Detail "    PostgreSQL is accepting connections after $elapsed s."
                    return [PSCustomObject]@{ Ready = $true; Observed = $observed; ElapsedSeconds = $elapsed }
                }
            }

            if (((Get-Date) - $lastReport).TotalSeconds -ge 15) {
                $lastReport = Get-Date
                Write-Detail "    Waiting for PostgreSQL ($([int]((Get-Date) - $started).TotalSeconds) s; $observed)"
            }
            Start-Sleep -Seconds 3
        }

        return [PSCustomObject]@{ Ready = $false; Observed = $observed; ElapsedSeconds = [int]((Get-Date) - $started).TotalSeconds }
    })
}

function Start-DeltaDatabaseForBackup {
    <#
      Makes the database backup possible on an installation that is not
      running, and reports what it had to do.

      This is the fix for the behaviour that made a stopped installation
      un-uninstallable:

          The database backup failed at stage 'precheck':
          The database container is not running (Exited (0) 17 hours ago).
          Start DELTA first, then take the backup.

          Nothing was deleted.

      That message is correct advice for the backup MENU - "back up the
      database" is not a licence to start the stack somebody deliberately
      stopped - and it is the wrong answer for an uninstall. An uninstaller
      that cannot uninstall a stopped application has not implemented
      uninstall; and telling the operator to start the whole of an installation
      they are about to delete, so that a machine can read one file out of it,
      is work asked of a person that the script can do correctly itself.

      So the uninstall starts the database first, on its own:

        - the container exists and is stopped -> `compose start db`, which
          starts exactly that container and creates nothing;
        - no container exists at all         -> `compose up -d --no-deps db`,
          which creates one against the recorded volume. --no-deps is what
          keeps it to the database: db declares no dependencies, but a future
          compose file that gave it one would otherwise pull the rest of the
          stack up behind it.

      Neither ever names the application or NGINX, and
      Invoke-DeltaDatabaseOnlyCompose refuses the vector if one ever does.

      Returns Ready/Started/WasRunning. Started is what the caller uses to put
      the machine back as it found it if the backup then fails.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [int]$TimeoutSeconds = $Script:DeltaUninstallDatabaseReadySeconds
    )

    $result = [PSCustomObject]@{
        Ready      = $false
        Started    = $false
        WasRunning = $false
        Service    = $Script:DeltaDatabaseServiceName
        Observed   = $null
        Reason     = $null
    }

    if (-not (Test-Path -LiteralPath $Target.ComposeFile -PathType Leaf)) {
        $result.Reason = "'$($Target.ComposeFile)' is missing, so the database service cannot be started and the database cannot be backed up."
        return $result
    }

    $service = @(Get-DeltaComposeServiceStatus -InstallRoot $Target.InstallRoot -ProjectName $Target.ProjectName) |
        Where-Object { $_.Service -eq $Script:DeltaDatabaseServiceName } | Select-Object -First 1
    $result.Observed = if ($service) { $service.Status } else { 'no container exists for the db service' }

    if ($service -and $service.State -eq 'running') {
        $result.WasRunning = $true
        Write-Detail 'The database container is already running.'
    }
    else {
        if ($service) {
            Write-Detail "The database container is stopped ($($result.Observed))."
            $arguments = @('start', $Script:DeltaDatabaseServiceName)
        }
        else {
            Write-Detail 'There is no database container for this installation.'
            $arguments = @('up', '-d', '--no-deps', $Script:DeltaDatabaseServiceName)
        }
        Write-Detail 'Starting the database temporarily for the uninstall backup - nothing else in the stack is started.'

        $capture = Invoke-DeltaActivity -Message 'Starting the database' -ScriptBlock {
            Invoke-DeltaDatabaseOnlyCompose -Target $Target -Arguments $arguments -TimeoutSeconds 600
        }
        if ($capture.ExitCode -ne 0) {
            $result.Reason = "The database service could not be started: $((($capture.StdErr + ' ' + $capture.StdOut)).Trim())"
            return $result
        }
        $result.Started = $true
    }

    $wait = Wait-DeltaDatabaseReadyForBackup -Target $Target -TimeoutSeconds $TimeoutSeconds
    if (-not $wait.Ready) {
        $result.Reason = "PostgreSQL did not become ready within $TimeoutSeconds seconds (last seen: $($wait.Observed))."
        return $result
    }

    $result.Ready = $true
    return $result
}

function Stop-DeltaDatabaseStartedForBackup {
    <#
      Puts the database back the way this run found it, after a backup that
      started it and then failed.

      The uninstall aborts with "nothing was deleted, DELTA is exactly as it
      was", and a database left running that was stopped before the run began
      would make the second half of that sentence untrue. Best-effort by
      design: a container that will not stop is worth a warning, never worth
      turning an already-failed uninstall into a second failure.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$StartRecord
    )

    if (-not $StartRecord.Started) { return }

    $capture = Invoke-DeltaDatabaseOnlyCompose -Target $Target -TimeoutSeconds 300 `
        -Arguments @('stop', $Script:DeltaDatabaseServiceName)
    if ($capture.ExitCode -eq 0) {
        Write-Detail 'The database was stopped again, so this installation is as it was before this run.'
    }
    else {
        Write-DeltaWarning "The database was started for the backup and could not be stopped again: $((($capture.StdErr + ' ' + $capture.StdOut)).Trim())"
    }
}

function Stop-DeltaRuntimeForBackup {
    <#
      Quiesces the stack between the database dump and the archive.

      Ordering: the dump needs the db container running, and the archive needs
      nothing writing into uploads\ or logs\ while it is read. So the dump
      happens first, against a live database - pg_dump takes a transactionally
      consistent snapshot, so a running application is not a problem for it -
      and only then is the stack stopped, so the files being archived are
      still.

      `stop`, not `down`: this must not remove anything. If the backup fails
      after this point the installation is stopped but completely intact, and
      `setup.ps1` or menu option 3 brings it straight back.
    #>
    param([Parameter(Mandatory)][object]$Target)

    Write-Step 'Stopping DELTA so the files being archived are not changing'

    if (-not (Test-Path -LiteralPath $Target.ComposeFile -PathType Leaf)) {
        Write-Detail 'No docker-compose.yml, so there is nothing running to stop.'
        return
    }

    $stop = Invoke-DeltaActivity -Message 'Stopping the containers' -ScriptBlock {
        Invoke-DeltaCompose -InstallRoot $Target.InstallRoot -ProjectName $Target.ProjectName -Arguments @('stop') -TimeoutSeconds 300
    }
    if ($stop.ExitCode -ne 0) {
        Stop-Setup "The DELTA containers could not be stopped: $((($stop.StdErr + ' ' + $stop.StdOut)).Trim())`nNothing was archived and nothing was deleted."
    }
    Write-Detail 'Containers stopped. They are not removed - nothing has been deleted yet.'
}

function Backup-DeltaInstallation {
    <#
      The safety gate. Produces a verified external archive of the whole
      installation, or throws.

      This function never returns a failure. Every unrecoverable condition
      goes through Stop-Setup, which the entry point's single top-level catch
      turns into an abort - so a caller cannot ignore a status it forgot to
      check, and Remove-DeltaInstallation's code is not reached at all. That
      is the reference installer's strongest property and it is reproduced
      here deliberately: the requirement is not "should not delete without a
      backup", it is "cannot".

      The steps, each a hard prerequisite for the next:

        1. The target must be a registered DELTA installation. Ownership is
           proven before anything else happens.
        2. The database service is made ready. An installation that is merely
           stopped is still installed, so a stopped db container is started -
           only the db container - and waited for. This is not a lifecycle
           courtesy: without it the deletion gate can never be satisfied, and
           a stopped installation could never be uninstalled at all.
        3. A fresh database backup, produced by Phase 8's own
           New-DeltaDatabaseBackup - pg_dump -Fc inside the db container, the
           byte-exact stream transport, and pg_restore --list verification.
           There is no second database-backup implementation in this product
           and this function does not add one. Retention is skipped: this dump
           exists to be archived, not to participate in rotation.
        4. The runtime is stopped, so the archive is taken of files that are
           not being written - including the db container this run may have
           started, which leaves the installation stopped exactly as it found
           it if anything below fails.
        5. The whole installation root, recursively and with no allow-list, is
           archived to <BackupRoot>\DELTA-<timestamp>.zip, which is outside it.
           The dump from step 3 is inside the installation root by then, so it
           is swept into the same pass with nothing to reconcile afterwards.
        6. The archive is verified against the inventory the walk in step 5
           actually produced - every file it saw, at the size it saw - plus the
           entries that must exist and the dump's first bytes read back out of
           the ZIP.

      Returns a [Delta.VerifiedArchive]. That type name is the token
      Remove-DeltaInstallation demands.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [string]$BackupRoot = $Script:DeltaUninstallBackupRoot
    )

    # 1. Ownership, restated here rather than assumed from the caller. This
    #    function is the last place that can refuse cheaply.
    if (-not $Target.Registered) {
        Stop-Setup "'$($Target.InstallRoot)' is not a registered DELTA installation. $($Target.Reason) Nothing was backed up and nothing was deleted."
    }
    if (-not $Target.Configuration) {
        Stop-Setup "'$($Target.EnvPath)' could not be read, so the database cannot be reached to back it up. Nothing was deleted."
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    # 2. The database has to be up before it can be dumped, and an installation
    #    that is merely stopped is still installed. See
    #    Start-DeltaDatabaseForBackup - only the db service is started, and if
    #    it cannot be started the run aborts here with everything intact.
    Write-Step 'Preparing the database for the uninstall backup'
    $databaseStart = Start-DeltaDatabaseForBackup -Target $Target
    if (-not $databaseStart.Ready) {
        Stop-Setup "The database could not be made ready for the uninstall backup: $($databaseStart.Reason)`nNothing was deleted. DELTA is exactly as it was, including its data volume '$($Target.PgDataVolume)'.`nThe uninstall requires a verified database backup, so it stops here rather than removing an installation it could not archive."
    }

    # 3. The database, through Phase 8's implementation.
    Write-Step 'Backing up the DELTA database'
    Write-Detail 'pg_dump -Fc inside the db container, verified with pg_restore --list.'
    $database = New-DeltaDatabaseBackup -InstallRoot $Target.InstallRoot -Configuration $Target.Configuration -SkipRetention
    if (-not $database.Succeeded) {
        # Put back what this run changed before aborting, so "DELTA is exactly
        # as it was" is a statement about the machine and not a form of words.
        Stop-DeltaDatabaseStartedForBackup -Target $Target -StartRecord $databaseStart
        Stop-Setup "The database backup failed at stage '$($database.Stage)': $($database.Reason)`nNothing was deleted. DELTA is exactly as it was."
    }
    Write-Success "    Database backed up and verified: $($database.FileName) ($(Format-DeltaByteSize $database.SizeBytes))"

    # 4. Quiesce. This also stops the db container started above, so an
    #    installation that was stopped when this run began is stopped again by
    #    the time anything can fail below.
    Stop-DeltaRuntimeForBackup -Target $Target

    # 5. The archive: the entire installation root, recursively.
    $archivePath = Join-Path -Path $BackupRoot -ChildPath "DELTA-$timestamp.zip"
    Write-Step 'Archiving the installation'
    Write-Detail "From  $($Target.InstallRoot)"
    Write-Detail "To    $archivePath"

    $archive = $null
    try {
        # An installation with real uploads is gigabytes, and the compression
        # loop says nothing until it is finished. Stop-Setup raised from inside
        # it still unwinds exactly as before - Invoke-DeltaActivity stops the
        # indicator on its way past and re-throws untouched.
        $archive = Invoke-DeltaActivity -Message 'Archiving the installation' -ScriptBlock {
            New-DeltaInstallationArchive -SourceDirectory $Target.InstallRoot -DestinationPath $archivePath
        }
    }
    catch {
        Stop-Setup "The backup archive could not be created: $($_.Exception.Message)`nNothing was deleted. DELTA is exactly as it was."
    }
    if ($archive.Failures.Count -gt 0) {
        Stop-Setup "$($archive.Failures.Count) file(s) could not be added to the archive: $($archive.Failures -join '; ')`nNothing was deleted. A backup that is missing files it did not mention is worse than no backup."
    }
    Write-Detail "$($archive.AddedCount) file(s), $(Format-DeltaByteSize $archive.SourceBytes) on disk"

    # 6. Verification, against the inventory the walk above produced.
    Write-Step 'Verifying the backup archive'
    $verification = Invoke-DeltaActivity -Message 'Verifying the backup archive' -ScriptBlock {
        Test-DeltaInstallationArchive -Archive $archive -Target $Target -DatabaseBackup $database
    }
    if (-not $verification.Verified) {
        Stop-Setup "The backup archive did not verify: $($verification.Reason)`nNothing was deleted. DELTA is exactly as it was, and the unverified archive was left at '$($archive.Path)' for inspection."
    }

    Write-Success "    Archive verified: $($archive.Path)"
    Write-Detail "$($verification.EntryCount) entries, $(Format-DeltaByteSize $verification.SizeBytes) compressed"
    Write-Detail "All $($verification.InventoryCount) file(s) under $($Target.InstallRoot) are in it, at the size they were on disk."
    foreach ($category in $verification.Represented) {
        if ($category.SourceCount -le 0) { continue }
        Write-Detail ("  {0,-10} {1} file(s)" -f $category.Path, $category.ArchivedCount)
    }
    Write-Detail "Plus .env, docker-compose.yml, the installation record, the NGINX configuration"
    Write-Detail "and the verified database dump $($database.FileName)."

    return [PSCustomObject]@{
        PSTypeName     = 'Delta.VerifiedArchive'
        Path           = $archive.Path
        Verified       = $true
        EntryCount     = $verification.EntryCount
        SizeBytes      = $verification.SizeBytes
        SourceBytes    = $archive.SourceBytes
        FileCount      = $archive.AddedCount
        UploadCount    = $verification.UploadCount
        InventoryCount = $verification.InventoryCount
        Represented    = $verification.Represented
        DatabaseDump   = $database.FileName
        DumpEntry      = $verification.DumpEntry
        DatabaseStart  = $databaseStart
        InstallRoot    = $Target.InstallRoot
        CreatedAt      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
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
        [Parameter(Mandatory)][ValidateSet('container', 'network', 'volume', 'task', 'firewall', 'file', 'archive')][string]$Kind,
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
      only -v would delete it), which is why the volume is removed explicitly
      and separately below - a deletion this size should be its own decision
      in the code as well as in the UI.

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
                StdErr   = "Refusing to run 'docker compose down $normalised': that removes this installation's database volume as a side effect of removing containers. Volume removal is its own explicit step."
                Refused  = $true
            }
        }
    }

    # Every container's shutdown, then the network. Minutes on a busy host, and
    # silent throughout. -WhenIdle so a caller that has already announced a
    # larger removal keeps its own message.
    $capture = Invoke-DeltaActivity -Message 'Removing the containers and the project network' -WhenIdle -ScriptBlock {
        Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName `
            -Arguments (@('down') + $Arguments) -TimeoutSeconds $TimeoutSeconds
    }
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

    $had = @($Survey.Containers).Count
    if ($had -eq 0 -and $Survey.NetworkPresent -ne $true) {
        $null = $steps.Add((New-DeltaUninstallStep -Resource "Compose project '$($Target.ProjectName)'" -Kind 'container' -Outcome 'Already absent' `
            -Detail 'No containers and no network for this project.'))
        return $steps.ToArray()
    }

    if (-not (Test-Path -LiteralPath $Target.ComposeFile -PathType Leaf)) {
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
      Removes the PostgreSQL volume. The database is not lost with it: the
      verified dump inside the archive is the copy that survives, and this
      function is unreachable unless that archive verified.

      Three things must hold: the caller must name the volume this
      installation registered, the name must be non-empty, and the containers
      must already be gone - Docker refuses to remove a volume in use, and
      relying on that refusal rather than sequencing correctly would turn a
      design guarantee into a race. Docker's own refusal is still respected if
      it comes: a volume still attached to something is reported, not forced.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Survey
    )

    if (-not $Target.PgDataVolume) {
        return (New-DeltaUninstallStep -Resource 'PostgreSQL data volume' -Kind 'volume' -Outcome 'Could not verify' `
            -Detail 'This installation does not record a data volume name, so no volume was removed.')
    }
    if ($Survey.VolumePresent -ne $true) {
        return (New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome 'Already absent' -Detail $null)
    }

    # Deleting a data directory the size of the database. Docker returns when
    # the files are gone, not before.
    $remove = Invoke-DeltaActivity -Message "Removing the $($Target.PgDataVolume) volume" -WhenIdle -ScriptBlock {
        Invoke-DeltaDockerCommand -Arguments @('volume', 'rm', $Target.PgDataVolume) -TimeoutSeconds 120
    }
    if ($remove.ExitCode -ne 0) {
        return (New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome 'Failed' `
            -Detail (($remove.StdErr + ' ' + $remove.StdOut)).Trim())
    }

    $check = Invoke-DeltaDockerCommand -Arguments @('volume', 'inspect', $Target.PgDataVolume) -TimeoutSeconds 60
    if ($check.ExitCode -eq 0) {
        return (New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome 'Failed' `
            -Detail 'docker volume rm reported success but the volume is still present.')
    }

    return (New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome 'Removed' -Detail 'The live PostgreSQL data directory. The dump in the archive is the copy that survives.')
}

function Remove-DeltaLogonContinuation {
    <#
      The inverse of setup.ps1's Register-DeltaLogonContinuation, and the one
      piece of DELTA state that lives outside the installation root.

      setup.ps1 writes HKCU\...\RunOnce\DELTASetupContinue when it needs a
      restart part-way through an installation. Windows deletes a RunOnce value
      before running it, so in the normal case the entry is spent by the time
      anyone uninstalls - but "normally spent" is not "never there". An
      installation whose restart was registered and then never taken (the
      operator cancelled the reboot, the machine was shut down instead, setup
      failed after arming it) leaves a live value that fires at the next logon
      and starts a setup.ps1 for an installation root that no longer exists.

      Nothing else removed that. The uninstaller took the containers, the
      volume, the tasks, the firewall rules and the directory, and left behind
      the one thing that would try to bring the installation back.

      Removing a value that is not there is success, not an error: the
      end state asked for is "no continuation armed", and that is already true.
    #>

    $result = [PSCustomObject]@{
        Key     = $Script:DeltaRunOnceKey
        Name    = $Script:DeltaRunOnceName
        Present = $false
        Removed = $false
        Reason  = $null
    }

    try {
        if (-not (Test-Path -LiteralPath $Script:DeltaRunOnceKey)) {
            $result.Reason = 'There is no RunOnce key for this account.'
            return $result
        }

        $existing = Get-ItemProperty -LiteralPath $Script:DeltaRunOnceKey `
            -Name $Script:DeltaRunOnceName -ErrorAction SilentlyContinue
        if (-not $existing) {
            $result.Reason = 'No continuation is armed.'
            return $result
        }

        $result.Present = $true
        Remove-ItemProperty -LiteralPath $Script:DeltaRunOnceKey -Name $Script:DeltaRunOnceName -ErrorAction Stop

        # Verified rather than assumed, the same way every other removal here
        # is: read it back and confirm it has gone.
        $after = Get-ItemProperty -LiteralPath $Script:DeltaRunOnceKey `
            -Name $Script:DeltaRunOnceName -ErrorAction SilentlyContinue
        if ($after) {
            $result.Reason = 'The RunOnce value was removed but is still readable.'
            return $result
        }
        $result.Removed = $true
        return $result
    }
    catch {
        $result.Reason = $_.Exception.Message
        return $result
    }
}

function Exit-DeltaDirectoryForDeletion {
    <#
      Moves this process out of the tree that is about to be deleted, and
      reports whether it had to.

      This is the fix for the leftover an operator actually sees: an
      installation directory that is still there after a run that reported
      success on everything else.

      Windows will not delete a directory that a process has open, and a
      process's current directory IS an open handle to it. PowerShell's
      location is that handle. So `cd C:\DELTA` - or `cd C:\DELTA\logs`, or
      running an uninstall.ps1 that was extracted inside the installation root -
      makes the final Remove-Item fail with "because it is in use", and
      measured on Windows Server 2025 it fails whole: not one file is removed,
      because Remove-Item -Recurse checks the root before it descends. The
      operator is told PARTIAL and finds the installation apparently untouched.

      Measured, on the same host, so the mechanism here is the one the failure
      needs rather than the one it is easy to assume:

        - the current location inside the tree      -> deletion fails
        - the location moved out                    -> deletion succeeds
        - a .ps1 inside the tree already dot-sourced -> deletion succeeds

      That last line is why this function is all that is needed, and why there
      is no temporary self-deleting helper process here. PowerShell reads a
      script into memory and closes it; the libraries this uninstaller loaded
      from inside the tree do not hold it open. The directory handle was the
      only thing that did.

      Set-Location, not [Environment]::CurrentDirectory: the second does not
      release the first, and it was the PowerShell location that held the
      handle. Both are moved anyway, because a .NET API called later in the
      process resolves relative paths against the second.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $result = [PSCustomObject]@{ Moved = $false; From = $null; To = $null; Reason = $null }

    $current = $null
    try { $current = (Get-Location -PSProvider FileSystem).ProviderPath } catch { }
    if (-not $current) { return $result }

    if (-not (Test-DeltaPathContains -Parent $Path -Child $current)) { return $result }

    # Somewhere that certainly exists and is certainly not inside a DELTA
    # installation root: the protected-path guard refuses any root that
    # contains the Windows directory, so this can never be a step back inside.
    $destination = $env:SystemRoot
    try {
        Set-Location -LiteralPath $destination -ErrorAction Stop
        try { [System.Environment]::CurrentDirectory = $destination } catch { }
        $result.Moved = $true
        $result.From = $current
        $result.To = $destination
    }
    catch {
        $result.Reason = "The working directory could not be moved out of '$Path': $($_.Exception.Message)"
    }
    return $result
}

function Remove-DeltaInstallationTree {
    <#
      Deletes the installation root, and verifies it is gone.

      Three refusals stand in front of the recursive delete, and they are
      independent on purpose:

        1. The target must be Registered - a state file that exists, parses,
           and names a Compose project. That is what makes
           `uninstall.ps1 -InstallRoot C:\Windows` a refusal rather than a
           catastrophe, and it is checked here as well as at the entry point
           because this function is the one holding the delete.
        2. Test-DeltaUninstallPathSafe, which does not consult the state file
           at all - so a state file in the wrong place cannot authorise a
           deletion that the path itself forbids.
        3. The archive must not be inside the tree, which is the same rule
           from the other end: what survives must not be in what goes.

      Then the working directory is moved out, because that handle is the
      documented cause of an installation directory surviving an otherwise
      complete uninstall. See Exit-DeltaDirectoryForDeletion.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [string]$BackupRoot,
        [string]$ArchivePath
    )

    if (-not $Target.Registered) {
        return (New-DeltaUninstallStep -Resource $Target.InstallRoot -Kind 'file' -Outcome 'Preserved' `
            -Detail "Not a registered DELTA installation, so nothing was deleted. $($Target.Reason)")
    }

    $path = $Target.InstallRoot

    $safety = Test-DeltaUninstallPathSafe -Path $path -BackupRoot $BackupRoot -ArchivePath $ArchivePath
    if (-not $safety.Safe) {
        return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Preserved' -Detail $safety.Reason)
    }

    $moved = Exit-DeltaDirectoryForDeletion -Path $path
    if ($moved.Moved) {
        Write-Detail "Moved out of $($moved.From) before deleting - Windows will not delete a directory this process is sitting in."
    }
    elseif ($moved.Reason) {
        return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Failed' -Detail $moved.Reason)
    }

    try {
        # An installation with real uploads is a recursive delete of gigabytes.
        Invoke-DeltaActivity -Message 'Deleting the installation directory' -WhenIdle -ScriptBlock {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        }
    }
    catch {
        return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Failed' -Detail $_.Exception.Message)
    }

    # The explicit post-condition: Test-Path must be false.
    if (Test-Path -LiteralPath $path) {
        return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Failed' `
            -Detail 'The directory still exists after deletion. A file in it is probably held open by another process.')
    }
    return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Removed' -Detail 'The installation root and everything under it. Verified gone.')
}

# ---------------------------------------------------------------------------
# The closing proof
# ---------------------------------------------------------------------------

function Test-DeltaUninstallResidue {
    <#
      Asks the machine what is left, after everything has been removed.

      Every removal above already verifies its own step, and that is not the
      same thing as this. A per-step check answers "did the command I just ran
      do what it said"; this answers "is DELTA gone from this host", and the
      difference is every resource no step happened to touch - a second volume
      Compose labelled for this project, a network that is not the default one,
      a task that was re-registered while the uninstall was running, the
      RunOnce value nothing used to remove.

      It reports; it never deletes. A residue found here is named in the
      outcome and makes the run PARTIAL, which is the honest end state: the
      alternative is a broader delete based on a label sweep, and this file
      does not delete anything it did not create.

      The Docker queries are scoped by Compose's own project label rather than
      by name. A volume called delta_pgdata that this installation did not
      create carries no such label and is invisible here, which is the point:
      the wrong answer to "is anything left" is deleting somebody else's data
      to make the answer no.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [bool]$DockerAvailable = $true,
        [string]$ArchivePath
    )

    $residue = New-Object 'System.Collections.Generic.List[object]'
    $checked = New-Object 'System.Collections.Generic.List[string]'

    # --- Filesystem -------------------------------------------------------
    $null = $checked.Add('installation root')
    if (Test-Path -LiteralPath $Target.InstallRoot) {
        $remaining = @(Get-ChildItem -LiteralPath $Target.InstallRoot -Recurse -Force -ErrorAction SilentlyContinue).Count
        $null = $residue.Add([PSCustomObject]@{
            Kind = 'file'; Resource = $Target.InstallRoot
            Detail = "The installation root still exists with $remaining item(s) in it."
        })
    }

    # --- Docker -----------------------------------------------------------
    if ($DockerAvailable -and $Target.ProjectName) {
        $label = "label=com.docker.compose.project=$($Target.ProjectName)"

        $null = $checked.Add('containers')
        $ps = Invoke-DeltaDockerCommand -Arguments @('ps', '--all', '--filter', $label, '--format', '{{.Names}}') -TimeoutSeconds 120
        if ($ps.ExitCode -eq 0) {
            foreach ($name in @(($ps.StdOut -split "`r?`n") | Where-Object { $_.Trim() })) {
                $null = $residue.Add([PSCustomObject]@{
                    Kind = 'container'; Resource = $name.Trim()
                    Detail = "Still labelled for Compose project '$($Target.ProjectName)'."
                })
            }
        }
        else {
            $null = $residue.Add([PSCustomObject]@{
                Kind = 'container'; Resource = "Compose project '$($Target.ProjectName)'"
                Detail = 'Docker could not be asked whether any containers remain.'
            })
        }

        $null = $checked.Add('volumes')
        $volumes = Invoke-DeltaDockerCommand -Arguments @('volume', 'ls', '--filter', $label, '--format', '{{.Name}}') -TimeoutSeconds 120
        if ($volumes.ExitCode -eq 0) {
            foreach ($name in @(($volumes.StdOut -split "`r?`n") | Where-Object { $_.Trim() })) {
                $null = $residue.Add([PSCustomObject]@{
                    Kind = 'volume'; Resource = $name.Trim()
                    Detail = "A persistent volume still labelled for Compose project '$($Target.ProjectName)'."
                })
            }
        }

        # The recorded data volume by name as well, because a volume that was
        # created before Compose started labelling them, or adopted from an
        # earlier installation, would pass the label sweep above while still
        # holding the database.
        if ($Target.PgDataVolume) {
            $inspect = Invoke-DeltaDockerCommand -Arguments @('volume', 'inspect', $Target.PgDataVolume) -TimeoutSeconds 60
            if ($inspect.ExitCode -eq 0 -and -not (@($residue | Where-Object { $_.Kind -eq 'volume' -and $_.Resource -eq $Target.PgDataVolume }).Count)) {
                $null = $residue.Add([PSCustomObject]@{
                    Kind = 'volume'; Resource = $Target.PgDataVolume
                    Detail = 'The recorded PostgreSQL data volume still exists.'
                })
            }
        }

        $null = $checked.Add('networks')
        $networks = Invoke-DeltaDockerCommand -Arguments @('network', 'ls', '--filter', $label, '--format', '{{.Name}}') -TimeoutSeconds 120
        if ($networks.ExitCode -eq 0) {
            foreach ($name in @(($networks.StdOut -split "`r?`n") | Where-Object { $_.Trim() })) {
                $null = $residue.Add([PSCustomObject]@{
                    Kind = 'network'; Resource = $name.Trim()
                    Detail = "A network still labelled for Compose project '$($Target.ProjectName)'."
                })
            }
        }
    }

    # --- Windows integration ---------------------------------------------
    if ($Target.ProjectName) {
        $null = $checked.Add('scheduled tasks')
        foreach ($task in @(
            @{ State = (Get-DeltaStartupTaskState -ProjectName $Target.ProjectName);     Label = 'startup task' }
            @{ State = (Get-DeltaLogRotationTaskState -ProjectName $Target.ProjectName); Label = 'log rotation task' }
        )) {
            if ($task.State.Exists) {
                $null = $residue.Add([PSCustomObject]@{
                    Kind = 'task'; Resource = $task.State.Name
                    Detail = "The $($task.Label) is still registered and would run after the next restart."
                })
            }
        }
    }

    $null = $checked.Add('logon continuation')
    try {
        if (Test-Path -LiteralPath $Script:DeltaRunOnceKey) {
            $armed = Get-ItemProperty -LiteralPath $Script:DeltaRunOnceKey -Name $Script:DeltaRunOnceName -ErrorAction SilentlyContinue
            if ($armed) {
                $null = $residue.Add([PSCustomObject]@{
                    Kind = 'task'; Resource = "$($Script:DeltaRunOnceKey)\$($Script:DeltaRunOnceName)"
                    Detail = 'A one-time logon continuation is still armed and would start setup.ps1 at the next sign-in.'
                })
            }
        }
    }
    catch { }

    # --- The thing that must still be there -------------------------------
    $null = $checked.Add('backup archive')
    if ($ArchivePath) {
        if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
            $null = $residue.Add([PSCustomObject]@{
                Kind = 'archive'; Resource = $ArchivePath
                Detail = 'The verified backup archive is no longer on disk. This is the opposite of residue and it is worse: the data has gone with the installation.'
            })
        }
        elseif ((Get-Item -LiteralPath $ArchivePath).Length -le 0) {
            $null = $residue.Add([PSCustomObject]@{
                Kind = 'archive'; Resource = $ArchivePath
                Detail = 'The backup archive is zero bytes.'
            })
        }
    }

    return [PSCustomObject]@{
        Clean   = ($residue.Count -eq 0)
        Residue = $residue.ToArray()
        Checked = $checked.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Removal, which cannot be entered without a verified archive
# ---------------------------------------------------------------------------

function Remove-DeltaInstallation {
    <#
      Removes the DELTA runtime and the installation directory.

      -VerifiedArchive is mandatory and is typed [Delta.VerifiedArchive],
      which only Backup-DeltaInstallation produces. PowerShell refuses to bind
      anything else - $true, a hashtable, a path string, an ordinary
      PSCustomObject all fail at the parameter, before a single line of this
      function runs. That is the structural difference between this and a
      boolean a caller could ignore: there is no way to express "delete
      anyway" at the call site.

      The object is then re-validated, because a token that was verified ten
      minutes ago and names a file that no longer exists is not evidence of
      anything.

      Order: containers and network first, because a container with
      restart: unless-stopped would otherwise resurrect itself and because one
      holding the volume open blocks its removal. Then the scheduled tasks and
      the armed logon continuation, because either one surviving would bring
      the stack - or a setup.ps1 for an installation that no longer exists -
      back at the next boot or sign-in. Then the volume. Then the directory.
      Then, last, a verification pass that asks the machine what is left
      rather than trusting the steps that just ran.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][PSTypeName('Delta.VerifiedArchive')]$VerifiedArchive,
        [bool]$DockerAvailable = $true
    )

    if ($VerifiedArchive.Verified -ne $true) {
        Stop-Setup 'Refusing to remove DELTA: the supplied archive record is not marked verified. Nothing was deleted.'
    }
    if (-not (Test-Path -LiteralPath $VerifiedArchive.Path -PathType Leaf)) {
        Stop-Setup "Refusing to remove DELTA: the verified archive '$($VerifiedArchive.Path)' is no longer on disk. Nothing was deleted."
    }
    if ($VerifiedArchive.InstallRoot -ne $Target.InstallRoot) {
        Stop-Setup "Refusing to remove DELTA: the archive was taken from '$($VerifiedArchive.InstallRoot)' but removal was asked for '$($Target.InstallRoot)'. Nothing was deleted."
    }

    $result = [PSCustomObject]@{
        Outcome      = 'partial'
        Steps        = @()
        ArchivePath  = $VerifiedArchive.Path
        Reason       = $null
        Verification = $null
    }

    $steps = New-Object 'System.Collections.Generic.List[object]'
    $survey = Get-DeltaUninstallSurvey -Target $Target -DockerAvailable $DockerAvailable

    $null = $steps.Add((New-DeltaUninstallStep -Resource $VerifiedArchive.Path -Kind 'archive' -Outcome 'Preserved' `
        -Detail "$($VerifiedArchive.EntryCount) entries, $(Format-DeltaByteSize $VerifiedArchive.SizeBytes), including the verified database dump."))

    Write-Step 'Removing the DELTA containers'
    foreach ($step in (Remove-DeltaComposeRuntime -Target $Target -Survey $survey)) {
        $null = $steps.Add($step); Write-DeltaUninstallStepLine -Step $step
    }

    Write-Step 'Removing the Windows integration'
    foreach ($step in (Remove-DeltaScheduledIntegration -Target $Target)) {
        $null = $steps.Add($step); Write-DeltaUninstallStepLine -Step $step
    }
    foreach ($step in (Remove-DeltaFirewallIntegration -Target $Target -Survey $survey)) {
        $null = $steps.Add($step); Write-DeltaUninstallStepLine -Step $step
    }

    $continuation = Remove-DeltaLogonContinuation
    $continuationStep = if ($continuation.Removed) {
        New-DeltaUninstallStep -Resource "$($continuation.Key)\$($continuation.Name)" -Kind 'task' -Outcome 'Removed' `
            -Detail 'The one-time logon continuation setup.ps1 arms before a restart.'
    }
    elseif (-not $continuation.Present) {
        New-DeltaUninstallStep -Resource "$($continuation.Key)\$($continuation.Name)" -Kind 'task' -Outcome 'Already absent' -Detail $null
    }
    else {
        New-DeltaUninstallStep -Resource "$($continuation.Key)\$($continuation.Name)" -Kind 'task' -Outcome 'Failed' -Detail $continuation.Reason
    }
    $null = $steps.Add($continuationStep); Write-DeltaUninstallStepLine -Step $continuationStep

    Write-Step 'Removing the database volume'
    $volumeStep = Remove-DeltaDataVolume -Target $Target -Survey $survey
    $null = $steps.Add($volumeStep); Write-DeltaUninstallStepLine -Step $volumeStep

    Write-Step 'Removing the installation directory'
    $treeStep = Remove-DeltaInstallationTree -Target $Target `
        -BackupRoot (Split-Path -Parent $VerifiedArchive.Path) -ArchivePath $VerifiedArchive.Path
    $null = $steps.Add($treeStep); Write-DeltaUninstallStepLine -Step $treeStep

    # The closing proof. Every step above verified itself; this asks the
    # machine the question the operator is actually asking, and it is the
    # reason the success message below can be trusted rather than assumed.
    Write-Step 'Verifying that nothing is left'
    $verification = Test-DeltaUninstallResidue -Target $Target -DockerAvailable $DockerAvailable -ArchivePath $VerifiedArchive.Path
    $result.Verification = $verification

    if ($verification.Clean) {
        Write-Detail "Checked: $($verification.Checked -join ', '). Nothing belonging to this installation remains."
    }
    else {
        foreach ($item in $verification.Residue) {
            # Residue that no step reported is a new finding and has to appear
            # as its own failed step - otherwise a resource nothing tried to
            # remove would leave every step 'Removed' and the run 'success'.
            $residueStep = New-DeltaUninstallStep -Resource $item.Resource -Kind $item.Kind -Outcome 'Failed' -Detail $item.Detail
            $null = $steps.Add($residueStep); Write-DeltaUninstallStepLine -Step $residueStep
        }
    }

    $result.Steps = $steps.ToArray()

    $unresolved = @($result.Steps | Where-Object { $_.Outcome -in @('Failed', 'Could not verify') })
    if ($unresolved.Count -eq 0) {
        $result.Outcome = 'success'
    }
    else {
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
      What the operator sees before deciding: the installation that was found,
      what is running, what will be archived, and what will then be removed.

      The archive is described first and in the most detail, because it is the
      answer to the question the operator is actually asking - "am I going to
      lose this?" - and because the size and file count are what make it
      credible rather than reassuring.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Survey,
        [Parameter(Mandatory)][string]$BackupRoot
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
        foreach ($disagreement in $Target.Disagreements) { Write-DeltaWarning "  $disagreement" }
        Write-DeltaWarning 'The installation record is used, because it is what previous runs acted on.'
    }

    Write-Host ''
    Write-Host 'Current state'
    if (-not $Survey.DockerAvailable) {
        Write-DeltaWarning '    Docker is not reachable.'
    }
    else {
        $containers = @($Survey.Containers)
        if ($containers.Count -eq 0) { Write-Detail 'Containers         none' }
        else {
            foreach ($container in $containers) {
                Write-Detail ("Container          {0,-24} {1}" -f $container.Name, $container.State)
            }
        }
        Write-Detail "Database volume    $($Target.PgDataVolume) $(if ($Survey.VolumePresent) { 'present' } else { 'absent' })"
    }
    Write-Detail "Startup task       $(if ($Survey.StartupTask) { 'registered' } else { 'absent' })"
    Write-Detail "Log rotation task  $(if ($Survey.RotationTask) { 'registered' } else { 'absent' })"

    # A stopped installation is still installed, and is uninstalled by this
    # script without the operator starting anything. Said here, in the plan,
    # because the alternative is a start they did not expect part-way through a
    # run they have already confirmed.
    if ($Survey.DockerAvailable -and $Survey.DatabaseState -and $Survey.DatabaseState -ne 'running') {
        Write-Host ''
        Write-Detail "The database is not running ($($Survey.DatabaseState))."
        Write-Detail 'It is started - on its own, without the DELTA application or NGINX - for long'
        Write-Detail 'enough to take the backup below, then stopped again and removed with the rest.'
    }

    Write-Host ''
    Write-Host 'Everything is backed up first, to one archive outside this installation:'
    Write-Detail "$BackupRoot\DELTA-<timestamp>.zip"
    Write-Host ''
    Write-Detail "It contains every one of the $($Survey.TotalFiles) file(s) under $($Target.InstallRoot)"
    Write-Detail 'and a fresh, verified database dump taken for this uninstall:'
    foreach ($directory in $Survey.Directories) {
        Write-Detail ("  {0,-14} {1,10}  {2} file(s)" -f $directory.Name, (Format-DeltaByteSize $directory.Bytes), $directory.Items)
    }
    foreach ($file in $Survey.Files) {
        Write-Detail ("  {0,-14} {1,10}" -f $file.Name, (Format-DeltaByteSize $file.Bytes))
    }
    Write-Host ''
    Write-Detail 'The uninstall does not start unless that archive is created and verified.'

    Write-Host ''
    Write-Host 'Then this is removed:'
    Write-Detail 'The DELTA, database and NGINX containers'
    Write-Detail 'The Docker network they share'
    Write-Detail "The database volume $($Target.PgDataVolume)"
    Write-Detail 'The scheduled tasks for startup and log rotation'
    Write-Detail 'The Windows Firewall rules for this installation'
    Write-Detail "$($Target.InstallRoot), entirely"

    Write-Host ''
    Write-Detail 'Docker Desktop, WSL and every other program on this machine are left alone.'
}

function Read-DeltaUninstallConfirmation {
    <#
      The gate in front of the only irreversible thing this product does.

      It is a typed word, not [y/N], and that is the entire design. The rest of
      this installer uses [y/N] with blank meaning no, which is right for a
      question somebody might answer wrongly and recover from. An operator who
      has already pressed y to four prompts will press it to a fifth. Typing
      DELETE cannot be done by momentum.

      Everything that will be destroyed is enumerated immediately above the
      prompt, with sizes, and so is the archive that will exist afterwards -
      the decision is between two concrete states, not between a word and a
      feeling.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Survey,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    $rule = '-' * $Script:DeltaBannerWidth
    Write-Host ''
    Write-Host $rule
    Write-Host ''
    Write-Host 'After this, DELTA will be gone from this machine:' -ForegroundColor Yellow
    Write-Host ''
    if ($Survey.VolumePresent) {
        Write-Detail "Docker volume $($Target.PgDataVolume) - the live database"
    }
    foreach ($directory in $Survey.Directories) {
        if ($directory.Items -eq 0) { continue }
        Write-Detail "$($directory.Path) - $($directory.Items) file(s), $(Format-DeltaByteSize $directory.Bytes)"
    }
    Write-Detail "$($Target.InstallRoot) - the installation root itself, and everything else in it"
    Write-Host ''
    Write-Host 'What will remain is the archive:' -ForegroundColor Yellow
    Write-Detail "$BackupRoot\DELTA-<timestamp>.zip"
    Write-Detail 'It is written and verified before anything is removed. If it cannot be'
    Write-Detail 'created or verified, the uninstall stops and nothing is deleted.'
    Write-Host ''
    Write-Host 'Type DELETE to confirm, or anything else to cancel.'
    Write-Host ''

    $answer = Read-Host -Prompt 'Confirm'
    Write-Host ''
    Write-Host $rule

    # Case-sensitive and exact. "delete" is what somebody types while thinking
    # about something else.
    $confirmed = ([string]$answer).Trim() -ceq 'DELETE'
    Write-DeltaLogLine -Message "Uninstall confirmation: $(if ($confirmed) { 'confirmed' } else { 'declined' })" -Level 'DETAIL'
    return $confirmed
}

function Show-DeltaUninstallOutcome {
    <#
      The closing report. Two rules govern it, both learned the hard way
      elsewhere in this project.

      Never report success over an unresolved step. A container that could not
      be removed makes the run PARTIAL, and the remaining resources are named
      so finishing by hand is possible.

      Never leave the operator wondering where their data went. The archive
      path is the last thing on the screen either way, because it is the only
      thing left.
    #>
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][object]$Archive
    )

    $unresolved = @($Result.Steps | Where-Object { $_.Outcome -in @('Failed', 'Could not verify') })

    Write-Host ''
    if ($unresolved.Count -gt 0) {
        Write-DeltaWarning 'PARTIAL - DELTA was not completely removed.'
        Write-Host ''
        Write-Detail 'These were not removed, or could not be checked:'
        foreach ($step in $unresolved) { Write-Detail "  $($step.Resource) - $($step.Detail)" }
        Write-Host ''
        Write-Detail 'Re-run this script once the cause is resolved; it continues from wherever'
        Write-Detail 'the installation actually is, and takes a fresh archive when it does.'
    }
    else {
        Write-Success 'DELTA has been removed from this machine.'
        Write-Host ''
        Write-Detail "$($Target.InstallRoot) no longer exists."
        Write-Detail 'The containers, the network, the database volume, the scheduled tasks, the'
        Write-Detail 'logon continuation and the firewall rules are gone.'
        if ($Result.Verification) {
            # Said explicitly, because "removed" and "checked afterwards and
            # found absent" are different claims and only the second is this
            # one. The list is the verification's own, so it cannot claim a
            # check that was not made.
            Write-Detail "Verified after removal: $($Result.Verification.Checked -join ', ')."
        }
    }

    Write-Host ''
    Write-Host 'Your data is here:'
    Write-Detail $Archive.Path
    Write-Detail "$($Archive.EntryCount) entries, $(Format-DeltaByteSize $Archive.SizeBytes)"
    Write-Detail "Database dump   $($Archive.DatabaseDump) (verified)"
    Write-Detail "Installation    all $($Archive.InventoryCount) file(s) from $($Archive.InstallRoot)"
    foreach ($category in $Archive.Represented) {
        if ($category.SourceCount -le 0) { continue }
        Write-Detail ("  {0,-14} {1} file(s)" -f $category.Path, $category.ArchivedCount)
    }
    Write-Detail 'Also .env, docker-compose.yml and the installation record.'
    Write-Host ''
    Write-Detail 'To bring DELTA back: install it again with setup.ps1, then restore the dump'
    Write-Detail 'from inside that archive - the restore procedure is in README.md.'

    Write-Host ''
    Write-Detail 'Docker Desktop, WSL and the other software on this machine were not changed.'
}
