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
# trusting. Checked by name, and the ones marked Critical are checked for
# non-zero length as well. Relative to the archive's single top-level folder.
$Script:DeltaArchiveRequiredEntries = @(
    @{ Path = '.env';                    Description = 'configuration and secrets' }
    @{ Path = 'docker-compose.yml';      Description = 'the Compose stack definition' }
    @{ Path = '.delta-install.json';     Description = 'the installation record' }
    @{ Path = 'nginx/conf.d/delta.conf'; Description = 'the generated NGINX configuration' }
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
    }
}

function Test-DeltaInstallationArchive {
    <#
      Proves the archive is worth deleting an installation for.

      The reference installer opens the ZIP and checks the entry count is
      greater than zero. That catches a truncated or corrupt file, which is
      most of the value, but it cannot distinguish a good archive from one
      that opened cleanly and happens to contain nothing that matters. So this
      does four more things:

        1. Every file that was walked must be present as an entry. A count
           mismatch means something was dropped between the walk and the
           write.
        2. The entries that must exist, must exist - .env, the Compose file,
           the installation record, the generated NGINX configuration - and
           each must have non-zero length.
        3. uploads\ must be represented whenever the source had files in it,
           with at least as many entries as the source had files. This is the
           check that would catch "the archive is fine, it just has no user
           data in it".
        4. The fresh database dump must be present, its compressed entry must
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
        Verified     = $false
        EntryCount   = 0
        SizeBytes    = 0
        Missing      = @()
        Reason       = $null
        DumpEntry    = $null
        UploadCount  = 0
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

        # Uploads, when the source had any.
        $uploadsPath = Join-Path -Path $Target.InstallRoot -ChildPath 'uploads'
        $sourceUploads = 0
        if (Test-Path -LiteralPath $uploadsPath -PathType Container) {
            $sourceUploads = @(Get-ChildItem -LiteralPath $uploadsPath -Recurse -File -Force -ErrorAction SilentlyContinue).Count
        }
        $result.UploadCount = @($zip.Entries | Where-Object { $_.FullName.StartsWith("${prefix}uploads/", [System.StringComparison]::OrdinalIgnoreCase) }).Count
        if ($sourceUploads -gt 0 -and $result.UploadCount -lt $sourceUploads) {
            $null = $missing.Add("uploads: $sourceUploads file(s) on disk but $($result.UploadCount) in the archive")
        }

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

    $stop = Invoke-DeltaCompose -InstallRoot $Target.InstallRoot -ProjectName $Target.ProjectName -Arguments @('stop') -TimeoutSeconds 300
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
        2. A fresh database backup, produced by Phase 8's own
           New-DeltaDatabaseBackup - pg_dump -Fc inside the db container, the
           byte-exact stream transport, and pg_restore --list verification.
           There is no second database-backup implementation in this product
           and this function does not add one. Retention is skipped: this dump
           exists to be archived, not to participate in rotation.
        3. The runtime is stopped, so the archive is taken of files that are
           not being written.
        4. The whole installation root is archived to
           <BackupRoot>\DELTA-<timestamp>.zip, which is outside it. The dump
           from step 2 is inside the installation root by then, so it is swept
           into the same pass with nothing to reconcile afterwards.
        5. The archive is verified by opening it and looking for what must be
           there - including reading the dump's first bytes back out of it.

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

    # 2. The database, through Phase 8's implementation.
    Write-Step 'Backing up the DELTA database'
    Write-Detail 'pg_dump -Fc inside the db container, verified with pg_restore --list.'
    $database = New-DeltaDatabaseBackup -InstallRoot $Target.InstallRoot -Configuration $Target.Configuration -SkipRetention
    if (-not $database.Succeeded) {
        Stop-Setup "The database backup failed at stage '$($database.Stage)': $($database.Reason)`nNothing was deleted. DELTA is exactly as it was."
    }
    Write-Success "    Database backed up and verified: $($database.FileName) ($(Format-DeltaByteSize $database.SizeBytes))"

    # 3. Quiesce.
    Stop-DeltaRuntimeForBackup -Target $Target

    # 4. The archive.
    $archivePath = Join-Path -Path $BackupRoot -ChildPath "DELTA-$timestamp.zip"
    Write-Step 'Archiving the installation'
    Write-Detail "From  $($Target.InstallRoot)"
    Write-Detail "To    $archivePath"

    $archive = $null
    try {
        $archive = New-DeltaInstallationArchive -SourceDirectory $Target.InstallRoot -DestinationPath $archivePath
    }
    catch {
        Stop-Setup "The backup archive could not be created: $($_.Exception.Message)`nNothing was deleted. DELTA is exactly as it was."
    }
    if ($archive.Failures.Count -gt 0) {
        Stop-Setup "$($archive.Failures.Count) file(s) could not be added to the archive: $($archive.Failures -join '; ')`nNothing was deleted. A backup that is missing files it did not mention is worse than no backup."
    }
    Write-Detail "$($archive.AddedCount) file(s), $(Format-DeltaByteSize $archive.SourceBytes) on disk"

    # 5. Verification.
    Write-Step 'Verifying the backup archive'
    $verification = Test-DeltaInstallationArchive -Archive $archive -Target $Target -DatabaseBackup $database
    if (-not $verification.Verified) {
        Stop-Setup "The backup archive did not verify: $($verification.Reason)`nNothing was deleted. DELTA is exactly as it was, and the unverified archive was left at '$($archive.Path)' for inspection."
    }

    Write-Success "    Archive verified: $($archive.Path)"
    Write-Detail "$($verification.EntryCount) entries, $(Format-DeltaByteSize $verification.SizeBytes) compressed"
    Write-Detail "Contains .env, docker-compose.yml, the installation record, the NGINX configuration,"
    Write-Detail "$($verification.UploadCount) upload file(s), and the verified database dump."

    return [PSCustomObject]@{
        PSTypeName     = 'Delta.VerifiedArchive'
        Path           = $archive.Path
        Verified       = $true
        EntryCount     = $verification.EntryCount
        SizeBytes      = $verification.SizeBytes
        SourceBytes    = $archive.SourceBytes
        FileCount      = $archive.AddedCount
        UploadCount    = $verification.UploadCount
        DatabaseDump   = $database.FileName
        DumpEntry      = $verification.DumpEntry
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

    return (New-DeltaUninstallStep -Resource $Target.PgDataVolume -Kind 'volume' -Outcome 'Removed' -Detail 'The live PostgreSQL data directory. The dump in the archive is the copy that survives.')
}

function Remove-DeltaInstallationTree {
    <#
      Deletes the installation root, and verifies it is gone.

      It refuses unless the target is Registered: a state file that exists,
      parses, and names a Compose project. That is what makes
      `uninstall.ps1 -InstallRoot C:\Windows` a refusal rather than a
      catastrophe, and it is checked here as well as at the entry point
      because this function is the one holding the recursive delete. A drive
      root is refused outright regardless of what it contains.
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

    # The explicit post-condition: Test-Path must be false.
    if (Test-Path -LiteralPath $path) {
        return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Failed' `
            -Detail 'The directory still exists after deletion. A file in it is probably held open by another process.')
    }
    return (New-DeltaUninstallStep -Resource $path -Kind 'file' -Outcome 'Removed' -Detail 'The installation root and everything under it. Verified gone.')
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
      holding the volume open blocks its removal. Then the scheduled tasks,
      because a startup task that survived would bring the stack back at the
      next boot. Then the volume. Then the directory.
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
        Outcome     = 'partial'
        Steps       = @()
        ArchivePath = $VerifiedArchive.Path
        Reason      = $null
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

    Write-Step 'Removing the database volume'
    $volumeStep = Remove-DeltaDataVolume -Target $Target -Survey $survey
    $null = $steps.Add($volumeStep); Write-DeltaUninstallStepLine -Step $volumeStep

    Write-Step 'Removing the installation directory'
    $treeStep = Remove-DeltaInstallationTree -Target $Target
    $null = $steps.Add($treeStep); Write-DeltaUninstallStepLine -Step $treeStep

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

    Write-Host ''
    Write-Host 'Everything is backed up first, to one archive outside this installation:'
    Write-Detail "$BackupRoot\DELTA-<timestamp>.zip"
    Write-Host ''
    Write-Detail 'It contains a fresh, verified database dump taken for this uninstall, plus:'
    foreach ($directory in $Survey.Directories) {
        if (-not $directory.Exists) { continue }
        Write-Detail ("  {0,-10} {1,10}  {2} file(s)" -f $directory.Name, (Format-DeltaByteSize $directory.Bytes), $directory.Items)
    }
    Write-Detail '  .env, docker-compose.yml and the installation record'
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
        if (-not $directory.Exists -or $directory.Items -eq 0) { continue }
        Write-Detail "$($directory.Path) - $($directory.Items) file(s), $(Format-DeltaByteSize $directory.Bytes)"
    }
    Write-Detail "$($Target.InstallRoot) - the installation root itself"
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
        Write-Detail 'The containers, the network, the database volume, the scheduled tasks and'
        Write-Detail 'the firewall rules are gone.'
    }

    Write-Host ''
    Write-Host 'Your data is here:'
    Write-Detail $Archive.Path
    Write-Detail "$($Archive.EntryCount) entries, $(Format-DeltaByteSize $Archive.SizeBytes)"
    Write-Detail "Database dump   $($Archive.DatabaseDump) (verified)"
    Write-Detail "Uploads         $($Archive.UploadCount) file(s)"
    Write-Detail 'Also .env, docker-compose.yml, certificates, logs and previous backups.'
    Write-Host ''
    Write-Detail 'To bring DELTA back: install it again with setup.ps1, then restore the dump'
    Write-Detail 'from inside that archive - the restore procedure is in README.md.'

    Write-Host ''
    Write-Detail 'Docker Desktop, WSL and the other software on this machine were not changed.'
}
