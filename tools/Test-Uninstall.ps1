#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for the DELTA uninstall transaction: backup, verify,
    destroy, and prove nothing is left.

.DESCRIPTION
    The uninstaller's whole design is one property -

        BACKUP FAILURE MAKES THE DELETION PATH UNREACHABLE

    - and one promise: "backup survives, DELTA installation does not". Until
    this suite existed neither was covered by a test, and three defects sat in
    the gap between them:

      1. An installation root the process was sitting in was never deleted.
         `Remove-Item -Recurse` will not delete a directory that is a running
         process's current directory, and measured on Windows Server 2025 it
         fails WHOLE - not one file is removed, because the root is checked
         before the walk descends. An operator who ran `cd C:\DELTA` first, or
         who extracted the installer inside the installation root, was told
         PARTIAL and found the installation apparently untouched.

      2. The HKCU RunOnce continuation setup.ps1 arms before a restart had no
         inverse anywhere. Everything else was removed and the one artefact
         that would start a setup.ps1 for a deleted installation at the next
         sign-in was left behind.

      3. -InstallRoot defaults to C:\DELTA, which the installer has never
         required. An operator who installed to D:\DELTA and ran a bare
         `.\uninstall.ps1` was told "No DELTA Docker installation was found" -
         true of C:\DELTA, read as true of the machine - and the run exited 0
         with the installation still there.

    So the invariants pinned here are:

      - no verified archive, no destruction: a failed database dump or a failed
        archive verification leaves the containers, the volume, the data and
        the installation root exactly as they were;
      - the resolved installation root is deleted wherever it is, and the root
        ITSELF is gone, not merely emptied - including when the uninstaller is
        run from inside it;
      - a path that must never be deleted is refused whatever a state file
        found inside it claims;
      - after a successful run, nothing labelled for this Compose project
        remains - no container, no volume, no network - and nothing belonging
        to any OTHER project has been touched;
      - residue makes the run PARTIAL. A success message over a surviving
        container is the one outcome that must be impossible.

    Docker, Task Scheduler, Windows Firewall and the registry are all replaced
    by in-memory stand-ins, so nothing here starts a container, removes a
    volume, registers a task, opens a firewall or writes to the operator's
    RunOnce key. The filesystem is real, because deleting a directory tree is
    exactly what is under test - but every path is created under this suite's
    own temporary work root and no installation anywhere else on the machine is
    read, written or removed.

    Exits 0 if every test passes, 1 otherwise.

.EXAMPLE
    .\tools\Test-Uninstall.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$Script:WorkRoot    = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("delta-uninstall-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Script:Passed = 0
$Script:Failed = 0

. (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Stack.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Network.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Manage.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Configure.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Uninstall.ps1')

# ---------------------------------------------------------------------------
# Assertion helpers (same shape as the other suites here)
# ---------------------------------------------------------------------------

function Write-TestLine {
    param([AllowEmptyString()][string]$Text, [string]$Colour = 'Gray')
    Microsoft.PowerShell.Utility\Write-Host $Text -ForegroundColor $Colour
}

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
    if ("$Expected" -ceq "$Actual") { Write-TestLine "    [PASS] $Description" 'Green'; $Script:Passed++ }
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

# ---------------------------------------------------------------------------
# The simulated machine
#
# One hashtable is the whole host: an in-memory Docker daemon, an in-memory
# Task Scheduler, an in-memory firewall and an in-memory RunOnce key. Every
# stand-in below reads and writes it, so a test asserts against the same model
# the code under test acted on.
# ---------------------------------------------------------------------------

$Script:Machine = $null

function Reset-Machine {
    $Script:Machine = @{
        Containers    = [System.Collections.Generic.List[object]]::new()
        Volumes       = [System.Collections.Generic.List[object]]::new()
        Networks      = [System.Collections.Generic.List[object]]::new()
        Tasks         = [System.Collections.Generic.List[object]]::new()
        FirewallRules = [System.Collections.Generic.List[object]]::new()
        RunOnce       = @{}
        ComposeCalls  = [System.Collections.Generic.List[string]]::new()
        DockerCalls   = [System.Collections.Generic.List[string]]::new()
        ComposeDownFails = $false
        VolumeRmFails    = $false
        DatabaseStartFails = $false
        DatabaseNeverReady = $false
        # Every service this run actually started, in order. The record that
        # answers "was NGINX started to take a database backup?" after the
        # containers themselves have been removed.
        ServicesStarted    = [System.Collections.Generic.List[string]]::new()
    }
}

function Add-MachineContainer {
    param([string]$Name, [string]$Project, [string]$State = 'running', [AllowNull()][string]$Service = $null)
    # The Compose service a container belongs to. Derived from the name when
    # the caller does not say, exactly as `<project>-<service>-<n>` implies -
    # which is what lets the stand-in answer `compose ps` with services rather
    # than only with container names.
    if (-not $Service -and $Name -match '^.*-(db|delta|nginx)-\d+$') { $Service = $Matches[1] }
    $null = $Script:Machine.Containers.Add([PSCustomObject]@{
        Name = $Name; Project = $Project; State = $State; Service = $Service
        Id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    })
}

function Add-MachineVolume {
    param([string]$Name, [AllowNull()][string]$Project = $null)
    $null = $Script:Machine.Volumes.Add([PSCustomObject]@{ Name = $Name; Project = $Project })
}

function Add-MachineNetwork {
    param([string]$Name, [AllowNull()][string]$Project = $null)
    $null = $Script:Machine.Networks.Add([PSCustomObject]@{ Name = $Name; Project = $Project })
}

function Add-MachineTask {
    param([string]$Name, [string]$Arguments)
    $null = $Script:Machine.Tasks.Add([PSCustomObject]@{ Name = $Name; Arguments = $Arguments })
}

function Get-MachineContainerName {
    param([string]$Project)
    return @($Script:Machine.Containers | Where-Object { $_.Project -eq $Project } | ForEach-Object { $_.Name })
}

# ---------------------------------------------------------------------------
# Stand-ins
#
# Defined at script scope AFTER the libraries are loaded, so every call the
# library code makes resolves to these instead. Nothing below touches the real
# docker CLI, the real scheduler, the real firewall or the real registry.
# ---------------------------------------------------------------------------

function New-DockerResult {
    param([int]$ExitCode = 0, [string]$StdOut = '', [string]$StdErr = '')
    return [PSCustomObject]@{
        FilePath = 'docker'; Arguments = @(); ExitCode = $ExitCode
        StdOut = $StdOut; StdErr = $StdErr; TimedOut = $false; Started = $true; Error = $null
    }
}

function Get-FilterProject {
    <#
      Pulls the project out of a --filter label=com.docker.compose.project=X
      argument vector. Returns $null when the caller filtered by something
      else, which is how a test proves a query was label-scoped rather than
      name-matched.
    #>
    param([string[]]$Arguments)
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -eq '--filter' -and ($i + 1) -lt $Arguments.Count) {
            if ($Arguments[$i + 1] -match '^label=com\.docker\.compose\.project=(.+)$') { return $Matches[1] }
        }
    }
    return $null
}

function Invoke-DeltaDockerCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 120,
        [AllowNull()][string]$StandardInput
    )

    $null = $Script:Machine.DockerCalls.Add(($Arguments -join ' '))
    $verb = $Arguments[0]

    # --- docker compose ... ---------------------------------------------
    if ($verb -eq 'compose') {
        $null = $Script:Machine.ComposeCalls.Add(($Arguments -join ' '))

        $project = $null
        for ($i = 0; $i -lt $Arguments.Count; $i++) {
            if ($Arguments[$i] -eq '--project-name' -and ($i + 1) -lt $Arguments.Count) { $project = $Arguments[$i + 1] }
        }

        # The services named on the command line, if any. `compose stop` with
        # no service means the whole project; `compose stop db` means one
        # container - and the difference is exactly what the "only the database
        # is started" tests are about.
        #
        # Read positionally through the library's own parser, because this
        # installation's PostgreSQL user and database are both called `delta`:
        # a stand-in that pattern-matched the word would decide that
        # `exec -T db pg_isready -U delta` acts on the DELTA application.
        $composeArguments = New-Object 'System.Collections.Generic.List[string]'
        $index = 1
        while ($index -lt $Arguments.Count) {
            # The scoping flags Get-DeltaComposeArguments prepends each take a
            # value, and that value is a bare token - skip both, or the project
            # name would be read as the subcommand.
            if ($Arguments[$index] -in @('--project-name', '--project-directory', '--file', '--env-file')) { $index += 2; continue }
            $null = $composeArguments.Add([string]$Arguments[$index]); $index++
        }
        $named = @((Get-DeltaComposeServiceOperand -Arguments $composeArguments.ToArray()).Services)

        if ($Arguments -contains 'down') {
            if ($Script:Machine.ComposeDownFails) { return (New-DockerResult -ExitCode 1 -StdErr 'simulated: the containers could not be removed') }
            # `down` removes this project's containers and its networks. It
            # does NOT remove named volumes - that is the whole reason the
            # volume is a separate explicit step - so volumes are untouched
            # here, exactly like the real thing.
            $doomed = @($Script:Machine.Containers | Where-Object { $_.Project -eq $project })
            foreach ($container in $doomed) { $null = $Script:Machine.Containers.Remove($container) }
            $doomedNets = @($Script:Machine.Networks | Where-Object { $_.Project -eq $project })
            foreach ($network in $doomedNets) { $null = $Script:Machine.Networks.Remove($network) }
            return (New-DockerResult -ExitCode 0 -StdOut "Removed $($doomed.Count) container(s)")
        }

        if ($Arguments -contains 'ps') {
            # One compact JSON object per line, the shape Compose emits and the
            # one Get-DeltaComposeServiceStatus parses.
            $rows = foreach ($container in @($Script:Machine.Containers | Where-Object { $_.Project -eq $project })) {
                $status = if ($container.State -eq 'running') { 'Up 2 minutes (healthy)' } else { 'Exited (0) 17 hours ago' }
                $health = if ($container.State -eq 'running') { 'healthy' } else { '' }
                ('{{"Service":"{0}","Name":"{1}","State":"{2}","Status":"{3}","Health":"{4}"}}' -f
                    $container.Service, $container.Name, $container.State, $status, $health)
            }
            return (New-DockerResult -ExitCode 0 -StdOut (($rows -join "`r`n")))
        }

        if ($Arguments -contains 'stop') {
            $affected = @($Script:Machine.Containers | Where-Object { $_.Project -eq $project })
            if ($named.Count -gt 0) { $affected = @($affected | Where-Object { $_.Service -in $named }) }
            foreach ($container in $affected) { $container.State = 'exited' }
            return (New-DockerResult -ExitCode 0)
        }

        if (($Arguments -contains 'start') -or ($Arguments -contains 'up')) {
            if ($Script:Machine.DatabaseStartFails) { return (New-DockerResult -ExitCode 1 -StdErr 'simulated: the database container could not be started') }
            $affected = @($Script:Machine.Containers | Where-Object { $_.Project -eq $project })
            if ($named.Count -gt 0) { $affected = @($affected | Where-Object { $_.Service -in $named }) }
            foreach ($container in $affected) {
                if ($container.State -ne 'running' -and $container.Service) { $null = $Script:Machine.ServicesStarted.Add($container.Service) }
                $container.State = 'running'
            }
            # `up` creates what is not there; `start` never does.
            if (($Arguments -contains 'up') -and $affected.Count -eq 0 -and $named.Count -gt 0) {
                foreach ($service in $named) {
                    Add-MachineContainer -Name "$project-$service-1" -Project $project -State 'running' -Service $service
                    $null = $Script:Machine.ServicesStarted.Add($service)
                }
            }
            return (New-DockerResult -ExitCode 0)
        }

        if ($Arguments -contains 'exec') {
            # pg_isready, which is how readiness is actually established.
            if ($Arguments -contains 'pg_isready') {
                if ($Script:Machine.DatabaseNeverReady) { return (New-DockerResult -ExitCode 1 -StdErr 'no response') }
                $db = @($Script:Machine.Containers | Where-Object { $_.Project -eq $project -and $_.Service -eq 'db' })
                if ($db.Count -eq 0 -or $db[0].State -ne 'running') { return (New-DockerResult -ExitCode 2 -StdErr 'no response') }
                return (New-DockerResult -ExitCode 0 -StdOut 'accepting connections')
            }
            return (New-DockerResult -ExitCode 0)
        }

        return (New-DockerResult -ExitCode 0)
    }

    # --- docker ps ------------------------------------------------------
    if ($verb -eq 'ps') {
        $project = Get-FilterProject -Arguments $Arguments
        if (-not $project) { return (New-DockerResult -ExitCode 0 -StdOut '') }
        $rows = foreach ($container in @($Script:Machine.Containers | Where-Object { $_.Project -eq $project })) {
            if ($Arguments -contains '{{.Names}}|{{.State}}|{{.ID}}') { "$($container.Name)|$($container.State)|$($container.Id)" }
            else { $container.Name }
        }
        return (New-DockerResult -ExitCode 0 -StdOut (($rows -join "`r`n")))
    }

    # --- docker volume ... ----------------------------------------------
    if ($verb -eq 'volume') {
        $action = $Arguments[1]
        if ($action -eq 'inspect') {
            $name = $Arguments[2]
            $found = @($Script:Machine.Volumes | Where-Object { $_.Name -eq $name })
            if ($found.Count -eq 0) { return (New-DockerResult -ExitCode 1 -StdErr "Error: No such volume: $name") }
            return (New-DockerResult -ExitCode 0 -StdOut "/var/lib/docker/volumes/$name/_data")
        }
        if ($action -eq 'ls') {
            $project = Get-FilterProject -Arguments $Arguments
            if (-not $project) { return (New-DockerResult -ExitCode 0 -StdOut '') }
            $rows = @($Script:Machine.Volumes | Where-Object { $_.Project -eq $project } | ForEach-Object { $_.Name })
            return (New-DockerResult -ExitCode 0 -StdOut (($rows -join "`r`n")))
        }
        if ($action -eq 'rm') {
            $name = $Arguments[2]
            if ($Script:Machine.VolumeRmFails) { return (New-DockerResult -ExitCode 1 -StdErr 'simulated: volume is in use') }
            $found = @($Script:Machine.Volumes | Where-Object { $_.Name -eq $name })
            if ($found.Count -eq 0) { return (New-DockerResult -ExitCode 1 -StdErr "Error: No such volume: $name") }
            # Docker refuses to remove a volume a container still uses. The
            # stand-in refuses too, so a test cannot accidentally prove
            # correct sequencing that the real engine would have rejected.
            $inUse = @($Script:Machine.Containers | Where-Object { $_.Project -and $found[0].Project -eq $_.Project })
            if ($inUse.Count -gt 0) { return (New-DockerResult -ExitCode 1 -StdErr "Error: volume is in use - [$($inUse[0].Id)]") }
            $null = $Script:Machine.Volumes.Remove($found[0])
            return (New-DockerResult -ExitCode 0 -StdOut $name)
        }
    }

    # --- docker network ... ----------------------------------------------
    if ($verb -eq 'network') {
        $action = $Arguments[1]
        if ($action -eq 'inspect') {
            $name = $Arguments[2]
            $found = @($Script:Machine.Networks | Where-Object { $_.Name -eq $name })
            if ($found.Count -eq 0) { return (New-DockerResult -ExitCode 1 -StdErr "Error: No such network: $name") }
            return (New-DockerResult -ExitCode 0 -StdOut $name)
        }
        if ($action -eq 'ls') {
            $project = Get-FilterProject -Arguments $Arguments
            if (-not $project) { return (New-DockerResult -ExitCode 0 -StdOut '') }
            $rows = @($Script:Machine.Networks | Where-Object { $_.Project -eq $project } | ForEach-Object { $_.Name })
            return (New-DockerResult -ExitCode 0 -StdOut (($rows -join "`r`n")))
        }
    }

    return (New-DockerResult -ExitCode 0)
}

# Scheduled tasks.
function Get-DeltaStartupTaskState {
    param([Parameter(Mandatory)][string]$ProjectName)
    $name = Get-DeltaStartupTaskName -ProjectName $ProjectName
    $found = @($Script:Machine.Tasks | Where-Object { $_.Name -eq $name })
    return [PSCustomObject]@{ Name = $name; Exists = ($found.Count -gt 0); Healthy = ($found.Count -gt 0) }
}

function Get-DeltaLogRotationTaskState {
    param([Parameter(Mandatory)][string]$ProjectName)
    $name = Get-DeltaLogRotationTaskName -ProjectName $ProjectName
    $found = @($Script:Machine.Tasks | Where-Object { $_.Name -eq $name })
    return [PSCustomObject]@{ Name = $name; Exists = ($found.Count -gt 0) }
}

function Unregister-DeltaStartupTask {
    param([Parameter(Mandatory)][string]$ProjectName)
    $name = Get-DeltaStartupTaskName -ProjectName $ProjectName
    $found = @($Script:Machine.Tasks | Where-Object { $_.Name -eq $name })
    if ($found.Count -eq 0) { return [PSCustomObject]@{ Name = $name; Removed = $false; Reason = 'No such task.' } }
    $null = $Script:Machine.Tasks.Remove($found[0])
    return [PSCustomObject]@{ Name = $name; Removed = $true; Reason = $null }
}

function Unregister-DeltaLogRotationTask {
    param([Parameter(Mandatory)][string]$ProjectName)
    $name = Get-DeltaLogRotationTaskName -ProjectName $ProjectName
    $found = @($Script:Machine.Tasks | Where-Object { $_.Name -eq $name })
    if ($found.Count -eq 0) { return [PSCustomObject]@{ Name = $name; Removed = $false; Reason = 'No such task.' } }
    $null = $Script:Machine.Tasks.Remove($found[0])
    return [PSCustomObject]@{ Name = $name; Removed = $true; Reason = $null }
}

# Get-ScheduledTask, for the discovery path only. Returns the shape
# Get-DeltaInstalledRootCandidate reads: TaskName plus Actions[].Arguments.
function Get-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    return @($Script:Machine.Tasks | ForEach-Object {
        [PSCustomObject]@{
            TaskName = $_.Name
            Actions  = @([PSCustomObject]@{ Execute = 'powershell.exe'; Arguments = $_.Arguments })
        }
    })
}

# Windows Firewall.
function Get-DeltaOwnedFirewallRule {
    param([Parameter(Mandatory)][string]$DisplayName)
    return @($Script:Machine.FirewallRules | Where-Object { $_.Name -eq $DisplayName })
}

function Remove-DeltaFirewallRule {
    param([Parameter(Mandatory)][string]$DisplayName)
    $found = @($Script:Machine.FirewallRules | Where-Object { $_.Name -eq $DisplayName })
    if ($found.Count -eq 0) { return $false }
    $null = $Script:Machine.FirewallRules.Remove($found[0])
    return $true
}

# The registry, for the RunOnce continuation only. Filesystem probes go to the
# real Test-Path, because deleting real directories is what this suite does.
#
# [CmdletBinding()] on each, and no parameter of their own called
# ErrorAction: declaring one as an ordinary parameter makes PowerShell reject
# every advanced function that later calls it with "a parameter with the name
# 'ErrorAction' was defined multiple times". As common parameters they still
# arrive in $PSBoundParameters and still splat through to the real cmdlet.
function Test-Path {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Path,
        $LiteralPath, $PathType, [switch]$IsValid
    )
    $probe = if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } else { $Path }
    if ("$probe" -like 'HK*:*') { return $true }
    return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}

function Get-ItemProperty {
    [CmdletBinding()]
    param($LiteralPath, $Path, $Name)
    $key = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ("$key" -notlike 'HK*:*') { return Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters }
    if (-not $Script:Machine.RunOnce.ContainsKey($Name)) { return $null }
    return [PSCustomObject]@{ $Name = $Script:Machine.RunOnce[$Name] }
}

function Remove-ItemProperty {
    [CmdletBinding()]
    param($LiteralPath, $Path, $Name)
    $key = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ("$key" -notlike 'HK*:*') { return Microsoft.PowerShell.Management\Remove-ItemProperty @PSBoundParameters }
    $null = $Script:Machine.RunOnce.Remove($Name)
}

# Console. The library writes a running commentary; this suite prints its own
# results through the fully qualified cmdlet so it survives the shadow.
function Write-Host { param([Parameter(Position = 0)]$Object, $ForegroundColor, [switch]$NoNewline) }
function Write-Detail       { param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Message) }
function Write-Step         { param([Parameter(Position = 0)][AllowEmptyString()][string]$Message) }
function Write-Success      { param([Parameter(Position = 0)][AllowEmptyString()][string]$Message) }
function Write-DeltaWarning { param([Parameter(Position = 0)][AllowEmptyString()][string]$Message) }
function Write-DeltaFailure { param([Parameter(Position = 0)][AllowEmptyString()][string]$Message) }
function Write-DeltaLogLine { param($Message, $Level) }
function Show-Section       { param($Title, $Subtitle) }

# The activity indicator spins a runspace and draws to the console. Its
# contract - "the scriptblock's output is this function's output, unaltered,
# and an exception propagates untouched" - is what the code under test relies
# on, and that is reproduced exactly.
function Invoke-DeltaActivity {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$Message,
        [switch]$WhenIdle
    )
    return (& $ScriptBlock)
}

# ---------------------------------------------------------------------------
# Installation fixtures
# ---------------------------------------------------------------------------

$Script:DumpMagic = [byte[]]@(0x50, 0x47, 0x44, 0x4D, 0x50)   # 'PGDMP'

function New-TestInstallation {
    <#
      A complete, believable installation on disk, plus the Docker resources,
      tasks and firewall rules that belong to it - registered in the machine
      model so the survey finds them.

      -Project and -Volume are parameters rather than constants so a test can
      stand up a SECOND, unrelated installation and prove the first one's
      uninstall does not touch it.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Project = 'delta',
        [string]$Volume  = 'delta_pgdata',
        [switch]$NoStateFile,
        [switch]$WithDockerResources,
        # The installation an operator actually leaves behind: `docker compose
        # stop` run days ago, every container exited, nothing running.
        [switch]$Stopped,
        # And the harder shape: the containers were removed too, so only the
        # data volume and the files are left.
        [switch]$NoContainers
    )

    $null = New-Item -ItemType Directory -Path $Root -Force
    foreach ($relative in @('uploads', 'backups', 'certs', 'logs\delta', 'logs\nginx', 'logs\installer', 'nginx\conf.d')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $Root $relative) -Force
    }

    $envText = @"
COMPOSE_PROJECT_NAME=$Project
PGDATA_VOLUME=$Volume
HTTP_PORT=80
HTTPS_PORT=443
TLS_ENABLED=false
TLS_MODE=none
DELTA_HOSTNAME=localhost
PUBLIC_URL=http://localhost
POSTGRES_USER=delta
POSTGRES_DB=delta
POSTGRES_PASSWORD=not-a-real-password
SESSION_SECRET=not-a-real-secret
DELTA_IMAGE=ghcr.io/preventionweb/delta-country:prod-latest
DB_IMAGE=postgis/postgis:17-3.5
NGINX_IMAGE=nginx:1.29-alpine
"@
    [System.IO.File]::WriteAllText((Join-Path $Root '.env'), $envText, $Script:DeltaUtf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root 'docker-compose.yml'), "services:`n  db:`n    image: postgis`n", $Script:DeltaUtf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root 'nginx\conf.d\delta.conf'), "server { listen 80; }`n", $Script:DeltaUtf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root 'uploads\evidence.bin'), 'irreplaceable user data', $Script:DeltaUtf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root 'logs\delta\app.log'), 'log line', $Script:DeltaUtf8NoBom)

    if (-not $NoStateFile) {
        # The real shape, validated by the real Read-DeltaInstallState:
        # schemaVersion and state are both required, and 'state' must be one
        # of the recognised values.
        $state = @{
            schemaVersion  = $Script:DeltaInstallStateSchemaVersion
            state          = 'installed'
            composeProject = $Project
            pgDataVolume   = $Volume
            installRoot    = $Root
        } | ConvertTo-Json
        [System.IO.File]::WriteAllText((Join-Path $Root '.delta-install.json'), $state, $Script:DeltaUtf8NoBom)
    }

    if ($WithDockerResources) {
        $state = if ($Stopped) { 'exited' } else { 'running' }
        if (-not $NoContainers) {
            Add-MachineContainer -Name "$Project-db-1"    -Project $Project -State $state
            Add-MachineContainer -Name "$Project-delta-1" -Project $Project -State $state
            Add-MachineContainer -Name "$Project-nginx-1" -Project $Project -State $state
        }
        Add-MachineVolume  -Name $Volume            -Project $Project
        Add-MachineNetwork -Name "${Project}_default" -Project $Project

        $startupName  = Get-DeltaStartupTaskName -ProjectName $Project
        $rotationName = Get-DeltaLogRotationTaskName -ProjectName $Project
        Add-MachineTask -Name $startupName  -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Root\bin\start-delta.ps1`" -InstallRoot `"$Root`" -FromStartupTask"
        Add-MachineTask -Name $rotationName -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Root\bin\rotate-nginx-logs.ps1`" -InstallRoot `"$Root`""

        $null = $Script:Machine.FirewallRules.Add([PSCustomObject]@{ Name = (Get-DeltaFirewallRuleName -ProjectName $Project -Endpoint 'HTTP') })
    }

    return (Get-DeltaUninstallTarget -InstallRoot $Root)
}

# The database backup. The real one runs pg_dump inside a container; this
# writes a file that is byte-for-byte what the archive verifier demands - a
# real PGDMP header - so the verification under test is the real one.
#
# It reproduces the real function's precheck exactly, and that is the point
# rather than pedantry: the observed failure was that precheck refusing a
# stopped container, and a stand-in that dumps happily from a stopped database
# would let the stopped-installation tests below pass without the uninstaller
# ever having started anything.
$Script:BackupShouldFail = $false
$Script:BackupShouldWriteGarbage = $false

function New-DeltaDatabaseBackup {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [object]$Configuration,
        [switch]$SkipRetention,
        [int]$RetainCount = 0,
        [int]$RetainDays = 0,
        [int]$TimeoutSeconds = 0
    )

    $db = @($Script:Machine.Containers |
        Where-Object { $_.Project -eq $Configuration.ProjectName -and $_.Service -eq 'db' }) | Select-Object -First 1
    if (-not $db -or $db.State -ne 'running') {
        $observed = if ($db) { 'Exited (0) 17 hours ago' } else { 'no container exists for the db service' }
        return [PSCustomObject]@{
            Succeeded = $false; Path = $null; FileName = $null; SizeBytes = 0
            Stage = 'precheck'
            Reason = "The database container is not running ($observed). Start DELTA first, then take the backup."
            Deleted = $false
        }
    }

    if ($Script:BackupShouldFail) {
        return [PSCustomObject]@{
            Succeeded = $false; Path = $null; FileName = $null; SizeBytes = 0
            Stage = 'pg_dump'; Reason = 'simulated: pg_dump exited 1'; Deleted = $true
        }
    }

    $fileName = "delta-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,4)).dump"
    $path = Join-Path (Join-Path $InstallRoot 'backups') $fileName
    $bytes = if ($Script:BackupShouldWriteGarbage) {
        [System.Text.Encoding]::ASCII.GetBytes('NOTADUMP') + [byte[]]@(1, 2, 3)
    }
    else {
        $Script:DumpMagic + [System.Text.Encoding]::ASCII.GetBytes('...the rest of a custom-format dump...')
    }
    [System.IO.File]::WriteAllBytes($path, $bytes)

    return [PSCustomObject]@{
        Succeeded = $true; Path = $path; FileName = $fileName
        SizeBytes = $bytes.Length; Stage = 'verified'; Reason = $null; Deleted = $false
    }
}

function New-TestBackupRoot {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $Script:WorkRoot $Name
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
}

function Invoke-FullUninstall {
    <#
      The whole transaction as uninstall.ps1 runs it: back up, then remove.
      Returns the archive and the result, or the error that stopped it.
    #>
    param(
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    $outcome = [PSCustomObject]@{ Archive = $null; Result = $null; Error = $null }
    try {
        $outcome.Archive = Backup-DeltaInstallation -Target $Target -BackupRoot $BackupRoot
        $outcome.Result  = Remove-DeltaInstallation -Target $Target -VerifiedArchive $outcome.Archive -DockerAvailable $true
    }
    catch {
        $outcome.Error = $_.Exception.Message
    }
    return $outcome
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

$null = New-Item -ItemType Directory -Path $Script:WorkRoot -Force

Write-TestLine '' 'Gray'
Write-TestLine '==> DELTA uninstall transaction tests' 'Cyan'
Write-TestLine "    Work root: $Script:WorkRoot" 'DarkGray'
Write-TestLine '    Docker, Task Scheduler, the firewall and the registry are stand-ins.' 'DarkGray'
Write-TestLine '    No installation outside this work root is read, written or removed.' 'DarkGray'

try {

# ===========================================================================
Start-TestCase 'A custom installation root is resolved and deleted, not C:\DELTA'
# ===========================================================================

Reset-Machine
$Script:BackupShouldFail = $false
# Deliberately not under a "DELTA" name and not on the default path: nothing
# in the removal may work by recognising the string "C:\DELTA".
$custom = Join-Path $Script:WorkRoot ('DELTA-Uninstall-Test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$backupRoot = New-TestBackupRoot -Name 'backups-custom'
$target = New-TestInstallation -Root $custom -Project 'deltacustom' -Volume 'deltacustom_pgdata' -WithDockerResources

Assert-That  'the installation is recognised as registered'    $target.Registered
Assert-Equal 'the resolved root is the custom one'             $custom $target.InstallRoot
Assert-Equal 'the Compose project comes from the state file'   'deltacustom' $target.ProjectName
Assert-Equal 'the data volume comes from the state file'       'deltacustom_pgdata' $target.PgDataVolume

$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot

Assert-That  "the transaction completed without throwing ($($run.Error))" (-not $run.Error)
# Every assertion below reads $run.Result, which does not exist when the
# transaction aborted. Stopping here reports the real reason once instead of
# burying it under a property-not-found for each of the next six.
if ($run.Error) { throw "the happy path did not complete, so nothing below it can be judged: $($run.Error)" }
Assert-Equal 'the outcome is success'                          'success' $run.Result.Outcome
Assert-That  'the custom installation root is gone'            (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $custom))
Assert-That  'the archive is outside the deleted root'         (-not $backupRoot.StartsWith($custom, [System.StringComparison]::OrdinalIgnoreCase))
Assert-That  'the archive still exists'                        (Microsoft.PowerShell.Management\Test-Path -LiteralPath $run.Archive.Path -PathType Leaf)
Assert-That  'the archive is not empty'                        ((Get-Item -LiteralPath $run.Archive.Path).Length -gt 0)

# The point of the whole case: the code was never given C:\DELTA and never
# went looking for it.
$touchedDefault = @($Script:Machine.DockerCalls | Where-Object { $_ -match 'C:\\DELTA(\\|$|")' })
Assert-Equal 'no Docker call mentioned the default root'       0 $touchedDefault.Count

# ===========================================================================
Start-TestCase 'Docker residue: nothing of this project survives, neighbours untouched'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'residue-install'
$backupRoot = New-TestBackupRoot -Name 'backups-residue'
$target = New-TestInstallation -Root $root -Project 'delta9' -Volume 'delta9_pgdata' -WithDockerResources

# An unrelated Compose project, an unrelated volume whose name contains
# "delta", and an unrelated network. None of these may be touched.
Add-MachineContainer -Name 'neighbour-app-1'  -Project 'neighbour'
Add-MachineContainer -Name 'delta9-lookalike' -Project 'someoneelse'
Add-MachineVolume    -Name 'neighbour_pgdata' -Project 'neighbour'
Add-MachineVolume    -Name 'delta9_pgdata_old'
Add-MachineVolume    -Name 'delta_pgdata'
Add-MachineNetwork   -Name 'neighbour_default' -Project 'neighbour'
Add-MachineNetwork   -Name 'bridge'
Add-MachineTask      -Name 'Some other product - Startup' -Arguments '-File C:\other\run.ps1'

Assert-Equal 'three DELTA containers before'  3 (Get-MachineContainerName -Project 'delta9').Count

$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot

Assert-Equal 'the outcome is success'         'success' $run.Result.Outcome
Assert-Equal 'DELTA containers = 0'           0 @($Script:Machine.Containers | Where-Object { $_.Project -eq 'delta9' }).Count
Assert-Equal 'DELTA compose networks = 0'     0 @($Script:Machine.Networks   | Where-Object { $_.Project -eq 'delta9' }).Count
Assert-Equal 'DELTA persistent volumes = 0'   0 @($Script:Machine.Volumes    | Where-Object { $_.Project -eq 'delta9' }).Count
Assert-That  'the recorded pgdata volume is gone' (-not @($Script:Machine.Volumes | Where-Object { $_.Name -eq 'delta9_pgdata' }).Count)

Assert-That  "the neighbour's container survives"  (@($Script:Machine.Containers | Where-Object { $_.Name -eq 'neighbour-app-1' }).Count -eq 1)
Assert-That  'a lookalike container survives'      (@($Script:Machine.Containers | Where-Object { $_.Name -eq 'delta9-lookalike' }).Count -eq 1)
Assert-That  "the neighbour's volume survives"     (@($Script:Machine.Volumes | Where-Object { $_.Name -eq 'neighbour_pgdata' }).Count -eq 1)
Assert-That  'an unlabelled delta9_pgdata_old survives' (@($Script:Machine.Volumes | Where-Object { $_.Name -eq 'delta9_pgdata_old' }).Count -eq 1)
Assert-That  'an unrelated volume called delta_pgdata survives' (@($Script:Machine.Volumes | Where-Object { $_.Name -eq 'delta_pgdata' }).Count -eq 1)
Assert-That  "the neighbour's network survives"    (@($Script:Machine.Networks | Where-Object { $_.Name -eq 'neighbour_default' }).Count -eq 1)
Assert-That  'the default bridge network survives' (@($Script:Machine.Networks | Where-Object { $_.Name -eq 'bridge' }).Count -eq 1)
Assert-That  "another product's scheduled task survives" (@($Script:Machine.Tasks | Where-Object { $_.Name -eq 'Some other product - Startup' }).Count -eq 1)

# Identification is by Compose label, never by name matching.
$nameMatched = @($Script:Machine.DockerCalls | Where-Object { $_ -match '--filter\s+name=' })
Assert-Equal 'no Docker query filtered by name'    0 $nameMatched.Count
$labelled = @($Script:Machine.DockerCalls | Where-Object { $_ -match 'label=com\.docker\.compose\.project=delta9' })
Assert-That  'queries were scoped by the project label' ($labelled.Count -ge 3)

# And no global sweep, ever.
$broad = @($Script:Machine.DockerCalls | Where-Object { $_ -match '\b(system\s+prune|volume\s+prune|container\s+prune|network\s+prune|image\s+prune)\b' })
Assert-Equal 'no prune of any kind was issued'     0 $broad.Count

# ===========================================================================
Start-TestCase 'Compose down never removes volumes as a side effect'
# ===========================================================================

foreach ($flag in @('-v', '--volumes', '--volume')) {
    $refusal = Invoke-DeltaComposeDown -InstallRoot $Script:WorkRoot -ProjectName 'delta' -Arguments @('--remove-orphans', $flag)
    Assert-That "docker compose down $flag is refused" ($refusal.Refused -eq $true -and $refusal.ExitCode -ne 0)
}
$downCalls = @($Script:Machine.ComposeCalls | Where-Object { $_ -match '\bdown\b' })
Assert-That 'the real down carried --remove-orphans'     (@($downCalls | Where-Object { $_ -match '--remove-orphans' }).Count -eq $downCalls.Count)
Assert-Equal 'and never carried a volume flag'           0 @($downCalls | Where-Object { $_ -match '\s(-v|--volumes?)(\s|$)' }).Count

# ===========================================================================
Start-TestCase 'Backup failure aborts before anything is destroyed'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'backup-fails'
$backupRoot = New-TestBackupRoot -Name 'backups-fail'
$target = New-TestInstallation -Root $root -Project 'deltafail' -Volume 'deltafail_pgdata' -WithDockerResources

$Script:BackupShouldFail = $true
$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot
$Script:BackupShouldFail = $false

Assert-That  'the run stopped with an error'          ($null -ne $run.Error)
Assert-That  'the error names the failing stage'      ($run.Error -match 'pg_dump')
Assert-That  'the error says nothing was deleted'     ($run.Error -match '(?i)nothing was deleted')
Assert-That  'no removal result was produced'         ($null -eq $run.Result)
Assert-That  'the installation root remains'          (Microsoft.PowerShell.Management\Test-Path -LiteralPath $root -PathType Container)
Assert-That  'the user data remains'                  (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $root 'uploads\evidence.bin') -PathType Leaf)
Assert-Equal 'the containers remain'                  3 @($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltafail' }).Count
Assert-Equal 'the PostgreSQL volume remains'          1 @($Script:Machine.Volumes | Where-Object { $_.Name -eq 'deltafail_pgdata' }).Count
Assert-Equal 'the Compose network remains'            1 @($Script:Machine.Networks | Where-Object { $_.Project -eq 'deltafail' }).Count
Assert-Equal 'the scheduled tasks remain'             2 @($Script:Machine.Tasks).Count
Assert-Equal 'no compose down was issued at all'      0 @($Script:Machine.ComposeCalls | Where-Object { $_ -match '\bdown\b' }).Count

# ===========================================================================
Start-TestCase 'Archive verification failure aborts just as hard'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'verify-fails'
$backupRoot = New-TestBackupRoot -Name 'backups-verify'
$target = New-TestInstallation -Root $root -Project 'deltaverify' -Volume 'deltaverify_pgdata' -WithDockerResources

# A dump that is written, is non-zero, is archived - and is not a dump. Only
# reading the first bytes back out of the ZIP catches this.
$Script:BackupShouldWriteGarbage = $true
$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot
$Script:BackupShouldWriteGarbage = $false

Assert-That  'the run stopped with an error'          ($null -ne $run.Error)
Assert-That  'the archive did not verify'             ($run.Error -match '(?i)did not verify')
Assert-That  'the reason names the PGDMP check'       ($run.Error -match 'PGDMP')
Assert-That  'nothing was deleted'                    ($run.Error -match '(?i)nothing was deleted')
Assert-That  'the installation root remains'          (Microsoft.PowerShell.Management\Test-Path -LiteralPath $root -PathType Container)
Assert-Equal 'the containers remain'                  3 @($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltaverify' }).Count
Assert-Equal 'the PostgreSQL volume remains'          1 @($Script:Machine.Volumes | Where-Object { $_.Name -eq 'deltaverify_pgdata' }).Count

# The structural guarantee, not merely the observed behaviour: removal cannot
# be called without the token only a successful backup mints.
$removeCommand = Get-Command -Name 'Remove-DeltaInstallation' -CommandType Function
$archiveParameter = $removeCommand.Parameters['VerifiedArchive']
Assert-That 'the archive parameter is mandatory' (@($archiveParameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -ge 1)
Assert-That 'and is typed Delta.VerifiedArchive' (@($archiveParameter.Attributes | Where-Object { $_ -is [System.Management.Automation.PSTypeNameAttribute] -and $_.PSTypeName -eq 'Delta.VerifiedArchive' }).Count -eq 1)

$bound = $true
try { $null = Remove-DeltaInstallation -Target $target -VerifiedArchive $true -DockerAvailable $false }
catch { $bound = $false }
Assert-That 'passing $true instead of an archive is refused by PowerShell' (-not $bound)

$bound = $true
try { $null = Remove-DeltaInstallation -Target $target -VerifiedArchive ([PSCustomObject]@{ Verified = $true; Path = 'x' }) -DockerAvailable $false }
catch { $bound = $false }
Assert-That 'so is an ordinary object claiming to be verified' (-not $bound)

# ===========================================================================
Start-TestCase 'Self-deletion: uninstalling from inside the installation root'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'self-delete'
$backupRoot = New-TestBackupRoot -Name 'backups-self'
$target = New-TestInstallation -Root $root -Project 'deltaself' -Volume 'deltaself_pgdata' -WithDockerResources

# The realistic case: the installer sits inside the installation root and the
# operator ran it from there.
$null = New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force
Copy-Item -LiteralPath (Join-Path $Script:ProjectRoot 'uninstall.ps1') -Destination (Join-Path $root 'uninstall.ps1')

$restore = (Get-Location -PSProvider FileSystem).ProviderPath
Set-Location -LiteralPath (Join-Path $root 'logs')

$insideBefore = (Get-Location -PSProvider FileSystem).ProviderPath
Assert-That 'the process really is inside the tree' (Test-DeltaPathContains -Parent $root -Child $insideBefore)

$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot

Assert-Equal 'the outcome is success'                  'success' $run.Result.Outcome
Assert-That  'the installation root itself is gone'    (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $root))
Assert-That  'not merely emptied - the path does not resolve' (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $root -PathType Container))
Assert-That  'the process was moved out of the tree'   (-not (Test-DeltaPathContains -Parent $root -Child (Get-Location -PSProvider FileSystem).ProviderPath))
Assert-That  'the archive survives outside it'         (Microsoft.PowerShell.Management\Test-Path -LiteralPath $run.Archive.Path -PathType Leaf)

Set-Location -LiteralPath $restore

# The mechanism, asserted directly: a working directory outside the tree is
# left alone, one inside it is moved.
$outsideProbe = Exit-DeltaDirectoryForDeletion -Path (Join-Path $Script:WorkRoot 'not-where-we-are')
Assert-That 'a process outside the tree is not moved' (-not $outsideProbe.Moved)

# --- and the same thing in a separate process ---------------------------
#
# The case above proves the mechanism inside this runspace. This proves the
# shape an operator actually produces: a real second powershell.exe, started
# with its working directory inside the installation root, running library
# code dot-sourced from a lib\ that is itself inside the tree it deletes.
#
# It is the deletion that is under test, so the child runs the real
# Remove-DeltaInstallationTree and nothing else - no Docker, no scheduler, no
# backup. The archive gate is proven separately and completely above.
Reset-Machine
$childRoot = Join-Path $Script:WorkRoot 'self-delete-child'
$null = New-TestInstallation -Root $childRoot -Project 'deltachild' -Volume 'deltachild_pgdata'
$null = New-Item -ItemType Directory -Path (Join-Path $childRoot 'lib') -Force
Copy-Item -LiteralPath (Join-Path $Script:ProjectRoot 'uninstall.ps1') -Destination (Join-Path $childRoot 'uninstall.ps1')
foreach ($library in @('Delta.Common.ps1', 'Delta.Config.ps1', 'Delta.Docker.ps1', 'Delta.Stack.ps1', 'Delta.Network.ps1', 'Delta.Manage.ps1', 'Delta.Configure.ps1', 'Delta.Uninstall.ps1')) {
    Copy-Item -LiteralPath (Join-Path $Script:ProjectRoot "lib\$library") -Destination (Join-Path $childRoot "lib\$library")
}

$childScript = Join-Path $Script:WorkRoot 'delete-from-inside.ps1'
$childBody = @'
param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
# The operator's `cd C:\DELTA` - and the libraries come from inside the tree
# that is about to be deleted, exactly as they do from an installer extracted
# into its own installation root.
Set-Location -LiteralPath $Root
foreach ($library in @('Delta.Common.ps1','Delta.Config.ps1','Delta.Docker.ps1','Delta.Stack.ps1','Delta.Network.ps1','Delta.Manage.ps1','Delta.Configure.ps1','Delta.Uninstall.ps1')) {
    . (Join-Path $Root "lib\$library")
}
$target = Get-DeltaUninstallTarget -InstallRoot $Root
if (-not $target.Registered) { Write-Output "NOT-REGISTERED: $($target.Reason)"; exit 3 }
$step = Remove-DeltaInstallationTree -Target $target -BackupRoot 'C:\DELTA-backups'
Write-Output "OUTCOME=$($step.Outcome)"
Write-Output "DETAIL=$($step.Detail)"
exit 0
'@
[System.IO.File]::WriteAllText($childScript, $childBody, $Script:DeltaUtf8NoBom)

$childOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $childScript -Root $childRoot 2>&1 | Out-String

Assert-That  'the child process reported a removal'    ($childOutput -match 'OUTCOME=Removed')
Assert-That  'the installation root is gone'           (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $childRoot))
Assert-That  'the lib\ it was running from is gone too' (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $childRoot 'lib')))
Assert-That  'and so is the uninstall.ps1 inside it'   (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $childRoot 'uninstall.ps1')))

# ===========================================================================
Start-TestCase 'The logon continuation is disarmed'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'continuation'
$backupRoot = New-TestBackupRoot -Name 'backups-continuation'
$target = New-TestInstallation -Root $root -Project 'deltacont' -Volume 'deltacont_pgdata' -WithDockerResources

# setup.ps1 armed a restart that was never taken.
$Script:Machine.RunOnce[$Script:DeltaRunOnceName] = "powershell.exe -File `"$root\setup.ps1`""
Assert-That 'a continuation is armed before the uninstall' $Script:Machine.RunOnce.ContainsKey($Script:DeltaRunOnceName)

$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot

Assert-Equal 'the outcome is success'                  'success' $run.Result.Outcome
Assert-That  'the RunOnce continuation is gone'        (-not $Script:Machine.RunOnce.ContainsKey($Script:DeltaRunOnceName))
$continuationStep = @($run.Result.Steps | Where-Object { $_.Resource -like "*$($Script:DeltaRunOnceName)" })
Assert-Equal 'and it is reported as a removal'         'Removed' $continuationStep[0].Outcome

# Absent is success, not an error.
Reset-Machine
$root2 = Join-Path $Script:WorkRoot 'continuation-absent'
$backupRoot2 = New-TestBackupRoot -Name 'backups-continuation-absent'
$target2 = New-TestInstallation -Root $root2 -Project 'deltacont2' -Volume 'deltacont2_pgdata' -WithDockerResources
$run2 = Invoke-FullUninstall -Target $target2 -BackupRoot $backupRoot2
$step2 = @($run2.Result.Steps | Where-Object { $_.Resource -like "*$($Script:DeltaRunOnceName)" })
Assert-Equal 'a continuation that was never armed is "Already absent"' 'Already absent' $step2[0].Outcome
Assert-Equal 'and the run is still a success'          'success' $run2.Result.Outcome

# One definition of the key, not two. This is the drift guard: setup.ps1 arms
# it and the uninstaller disarms it, so a second copy of the path in either
# file would be free to diverge from the one the other reads.
$setupText  = Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'setup.ps1') -Raw
$commonText = Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1') -Raw
Assert-That 'lib\Delta.Common.ps1 defines the RunOnce key'  ($commonText -match "(?m)^\`$Script:DeltaRunOnceKey\s*=")
Assert-That 'lib\Delta.Common.ps1 defines the value name'   ($commonText -match "(?m)^\`$Script:DeltaRunOnceName\s*=")
Assert-That 'setup.ps1 does not define its own copy'        ($setupText -notmatch "(?m)^\`$Script:DeltaRunOnceKey\s*=")
Assert-Equal 'the key is the HKCU RunOnce key'              'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' $Script:DeltaRunOnceKey
Assert-Equal 'the value name is the documented one'         'DELTASetupContinue' $Script:DeltaRunOnceName

# ===========================================================================
Start-TestCase 'Residue is reported, never reported as success'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'residue-survivor'
$backupRoot = New-TestBackupRoot -Name 'backups-survivor'
$target = New-TestInstallation -Root $root -Project 'deltastuck' -Volume 'deltastuck_pgdata' -WithDockerResources

# A container that `down` cannot remove: the failure mode the verification
# pass exists to catch, since every individual step can still report success.
$Script:Machine.ComposeDownFails = $true
$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot
$Script:Machine.ComposeDownFails = $false

Assert-That  'the backup still succeeded'          ($null -ne $run.Archive)
Assert-That  'the run is NOT reported as success'  ($run.Result.Outcome -ne 'success')
Assert-Equal 'it is reported as partial'           'partial' $run.Result.Outcome
Assert-That  'the reason counts the unresolved resources' ($run.Result.Reason -match 'resource')
# Not $failed: at script scope that is the suite's own failure counter.
$failedSteps = @($run.Result.Steps | Where-Object { $_.Outcome -eq 'Failed' })
Assert-That  'at least one step is marked Failed'  ($failedSteps.Count -ge 1)
Assert-That  'the surviving containers are named'  (@($failedSteps | Where-Object { $_.Kind -eq 'container' }).Count -ge 1)
Assert-That  'the verification ran and found residue' ($null -ne $run.Result.Verification -and -not $run.Result.Verification.Clean)
Assert-That  'the archive is preserved either way'  (Microsoft.PowerShell.Management\Test-Path -LiteralPath $run.Archive.Path -PathType Leaf)

# A residue the steps never touched must also surface: re-arm the continuation
# behind the removal's back and prove the closing check catches it.
Reset-Machine
$root = Join-Path $Script:WorkRoot 'residue-runonce'
$backupRoot = New-TestBackupRoot -Name 'backups-runonce'
$target = New-TestInstallation -Root $root -Project 'deltarearm' -Volume 'deltarearm_pgdata' -WithDockerResources
$archive = Backup-DeltaInstallation -Target $target -BackupRoot $backupRoot
$Script:Machine.RunOnce[$Script:DeltaRunOnceName] = 'armed after removal started'
$verification = Test-DeltaUninstallResidue -Target $target -DockerAvailable $true -ArchivePath $archive.Path
Assert-That 'the closing check sees the re-armed continuation' (@($verification.Residue | Where-Object { $_.Resource -like "*$($Script:DeltaRunOnceName)" }).Count -eq 1)
Assert-That 'and therefore does not report clean'              (-not $verification.Clean)

# ===========================================================================
Start-TestCase 'Protected paths are refused whatever a state file says'
# ===========================================================================

$refusals = @(
    @{ Path = '';                              Label = 'an empty path' }
    @{ Path = '   ';                           Label = 'a whitespace path' }
    @{ Path = 'DELTA';                         Label = 'a relative path' }
    @{ Path = 'relative\DELTA';                Label = 'a nested relative path' }
    @{ Path = $env:SystemDrive + '\';          Label = 'the system drive root' }
    @{ Path = $env:SystemRoot;                 Label = 'the Windows directory' }
    @{ Path = (Join-Path $env:SystemRoot 'System32'); Label = 'System32' }
    @{ Path = $env:ProgramFiles;               Label = 'Program Files' }
    @{ Path = $env:ProgramData;                Label = 'ProgramData' }
    @{ Path = $env:USERPROFILE;                Label = 'the user profile root' }
    @{ Path = (Split-Path -Parent $env:USERPROFILE); Label = 'the Users root (it contains the profile)' }
)
foreach ($case in $refusals) {
    $verdict = Test-DeltaUninstallPathSafe -Path $case.Path
    Assert-That "refuses $($case.Label)" (-not $verdict.Safe)
    Assert-That "  and says why for $($case.Label)" ([string]::IsNullOrWhiteSpace($verdict.Reason) -eq $false)
}

# A path that CONTAINS a protected directory is refused; a path INSIDE one is
# a legitimate installation root and is allowed.
$containsWindows = Test-DeltaUninstallPathSafe -Path (Split-Path -Parent $env:SystemRoot)
Assert-That 'refuses a directory that contains the Windows directory' (-not $containsWindows.Safe)
$insideProgramFiles = Test-DeltaUninstallPathSafe -Path (Join-Path $env:ProgramFiles 'DELTA')
Assert-That 'allows an installation root inside Program Files'        $insideProgramFiles.Safe
$ordinary = Test-DeltaUninstallPathSafe -Path 'D:\DELTA'
Assert-That 'allows an ordinary custom root on another drive'         $ordinary.Safe

# The backup must never be inside what is being deleted.
$holdsBackup = Test-DeltaUninstallPathSafe -Path 'D:\DELTA' -BackupRoot 'D:\DELTA\backups' -ArchivePath 'D:\DELTA\backups\DELTA-1.zip'
Assert-That 'refuses a root that contains the backup archive' (-not $holdsBackup.Safe)
Assert-That 'and says the archive is the only copy'           ($holdsBackup.Reason -match '(?i)only copy')
$besideBackup = Test-DeltaUninstallPathSafe -Path 'C:\DELTA' -BackupRoot 'C:\DELTA-backups' -ArchivePath 'C:\DELTA-backups\DELTA-1.zip'
Assert-That 'C:\DELTA-backups is NOT judged to be inside C:\DELTA' $besideBackup.Safe

# And the guard actually stops the delete, not merely answers a question.
Reset-Machine
$protectedRoot = Join-Path $Script:WorkRoot 'protected-probe'
$null = New-Item -ItemType Directory -Path $protectedRoot -Force
[System.IO.File]::WriteAllText((Join-Path $protectedRoot 'keep.txt'), 'kept', $Script:DeltaUtf8NoBom)
$fakeTarget = [PSCustomObject]@{
    InstallRoot = $protectedRoot; Registered = $true; Reason = 'test'
    ProjectName = 'deltaprotect'; PgDataVolume = 'x'; NetworkName = 'x_default'
}
$blocked = Remove-DeltaInstallationTree -Target $fakeTarget -BackupRoot $protectedRoot -ArchivePath (Join-Path $protectedRoot 'DELTA-1.zip')
Assert-Equal 'a root holding its own archive is preserved'  'Preserved' $blocked.Outcome
Assert-That  'and the directory is still there'             (Microsoft.PowerShell.Management\Test-Path -LiteralPath $protectedRoot -PathType Container)

# Ownership is still required, independently of the path guard.
$unregistered = [PSCustomObject]@{ InstallRoot = $protectedRoot; Registered = $false; Reason = 'no state file' }
$refused = Remove-DeltaInstallationTree -Target $unregistered
Assert-Equal 'an unregistered root is preserved'            'Preserved' $refused.Outcome
Assert-That  'and the directory is still there'             (Microsoft.PowerShell.Management\Test-Path -LiteralPath $protectedRoot -PathType Container)

# ===========================================================================
Start-TestCase 'A directory with no installation record is never deleted'
# ===========================================================================

Reset-Machine
$notOurs = Join-Path $Script:WorkRoot 'somebody-elses-documents'
$null = New-Item -ItemType Directory -Path $notOurs -Force
[System.IO.File]::WriteAllText((Join-Path $notOurs 'thesis.txt'), 'years of work', $Script:DeltaUtf8NoBom)

$strangerTarget = Get-DeltaUninstallTarget -InstallRoot $notOurs
Assert-That  'it is not registered'                   (-not $strangerTarget.Registered)
Assert-That  'the reason names the missing record'    ($strangerTarget.Reason -match '\.delta-install\.json')
Assert-That  'the directory is untouched'             (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $notOurs 'thesis.txt') -PathType Leaf)

$stopped = $false
try { $null = Backup-DeltaInstallation -Target $strangerTarget -BackupRoot (New-TestBackupRoot -Name 'backups-stranger') }
catch { $stopped = $true }
Assert-That  'the backup refuses to start'            $stopped
Assert-That  'and the files are still there'          (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $notOurs 'thesis.txt') -PathType Leaf)

# ===========================================================================
Start-TestCase 'Idempotency: a second uninstall is safe'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'idempotent'
$backupRoot = New-TestBackupRoot -Name 'backups-idempotent'
$target = New-TestInstallation -Root $root -Project 'deltaidem' -Volume 'deltaidem_pgdata' -WithDockerResources
$first = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot
Assert-Equal 'the first run succeeds'                 'success' $first.Result.Outcome

# Everything is now gone. Ask again about the same root.
$second = Get-DeltaUninstallTarget -InstallRoot $root
Assert-That  'the second look finds nothing registered' (-not $second.Registered)
Assert-That  'and says the directory is not there'      ($second.Reason -match '(?i)no directory')

# Each removal primitive, run again against the gone installation, reconciles
# rather than failing.
$survey = Get-DeltaUninstallSurvey -Target $target -DockerAvailable $true
$composeSteps = @(Remove-DeltaComposeRuntime -Target $target -Survey $survey)
Assert-That  'a missing container is "Already absent"'  (@($composeSteps | Where-Object { $_.Outcome -eq 'Already absent' }).Count -ge 1)
Assert-Equal 'and nothing is Failed'                    0 @($composeSteps | Where-Object { $_.Outcome -eq 'Failed' }).Count

$volumeStep = Remove-DeltaDataVolume -Target $target -Survey $survey
Assert-Equal 'a missing volume is "Already absent"'     'Already absent' $volumeStep.Outcome

$taskSteps = @(Remove-DeltaScheduledIntegration -Target $target)
Assert-Equal 'missing tasks are "Already absent"'       2 @($taskSteps | Where-Object { $_.Outcome -eq 'Already absent' }).Count

$continuation = Remove-DeltaLogonContinuation
Assert-That  'removing an absent continuation is not an error' ($continuation.Removed -eq $false -and $continuation.Present -eq $false)

$treeStep = Remove-DeltaInstallationTree -Target $second
Assert-Equal 'a missing install root is preserved, not failed' 'Preserved' $treeStep.Outcome

Assert-That  'the archive from the first run is still there'   (Microsoft.PowerShell.Management\Test-Path -LiteralPath $first.Archive.Path -PathType Leaf)

# ===========================================================================
Start-TestCase 'Discovery: the machine is asked where DELTA actually is'
# ===========================================================================

Reset-Machine
Add-MachineTask -Name (Get-DeltaStartupTaskName -ProjectName 'delta') `
    -Arguments '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "D:\Installers\DELTA\bin\start-delta.ps1" -InstallRoot "D:\DELTA Data" -FromStartupTask'
Add-MachineTask -Name (Get-DeltaLogRotationTaskName -ProjectName 'delta') `
    -Arguments '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "D:\Installers\DELTA\bin\rotate-nginx-logs.ps1" -InstallRoot "D:\DELTA Data"'
Add-MachineTask -Name 'Some other product - Startup' -Arguments '-File C:\other\run.ps1 -InstallRoot C:\other'

$candidates = @(Get-DeltaInstalledRootCandidate)
Assert-Equal 'one installation is discovered'          1 $candidates.Count
Assert-Equal 'the root is read from the task action'   'D:\DELTA Data' $candidates[0].InstallRoot
Assert-Equal 'the project comes from the task name'    'delta' $candidates[0].ProjectName
Assert-That  'a non-DELTA task is ignored'             (@($candidates | Where-Object { $_.InstallRoot -eq 'C:\other' }).Count -eq 0)

# Two installations are both found, and the two tasks of one are not counted
# twice.
Add-MachineTask -Name (Get-DeltaStartupTaskName -ProjectName 'delta2') `
    -Arguments '-File "C:\Installers\bin\start-delta.ps1" -InstallRoot C:\Apps\DELTA -FromStartupTask'
$candidates = @(Get-DeltaInstalledRootCandidate)
Assert-Equal 'two installations are discovered'        2 $candidates.Count
Assert-That  'the unquoted root parses too'            (@($candidates | Where-Object { $_.InstallRoot -eq 'C:\Apps\DELTA' }).Count -eq 1)

# A project name containing the separator does not break the parse.
Reset-Machine
Add-MachineTask -Name (Get-DeltaStartupTaskName -ProjectName 'delta - test') `
    -Arguments '-File "C:\i\bin\start-delta.ps1" -InstallRoot "C:\Odd Root" -FromStartupTask'
$odd = @(Get-DeltaInstalledRootCandidate)
Assert-Equal 'a project name with a separator survives' 'delta - test' $odd[0].ProjectName
Assert-Equal 'and its root is still read'               'C:\Odd Root' $odd[0].InstallRoot

# Discovery never deletes anything on its own.
Assert-Equal 'discovery issued no Docker call'          0 $Script:Machine.DockerCalls.Count

# ===========================================================================
Start-TestCase 'The installation you are standing in outranks the C:\DELTA default'
# ===========================================================================
#
# The near-miss this pins was found by real destructive integration testing.
# `.\uninstall.ps1` with no -InstallRoot, run from inside one installation,
# took the parameter default: it surveyed the OTHER installation, listed its
# containers and asked for the typed DELETE over its data volume. Nothing was
# destroyed only because that other installation's database container happened
# to be stopped, so the mandatory backup could not be taken. With it running,
# DELETE would have destroyed the wrong installation - and archived the wrong
# installation too.

# Resolve-DeltaUninstallRoot lives in uninstall.ps1, not in a library. It is
# lifted out by the parser rather than retyped here, so this tests the code
# that ships instead of a copy of it that drifted.
$Script:UninstallScriptPath = Join-Path $Script:ProjectRoot 'uninstall.ps1'
$Script:UninstallAst = [System.Management.Automation.Language.Parser]::ParseFile($Script:UninstallScriptPath, [ref]$null, [ref]$null)
$lifted = @($Script:UninstallAst.FindAll({
    param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-DeltaUninstallRoot'
}, $true))
Assert-Equal 'uninstall.ps1 defines Resolve-DeltaUninstallRoot exactly once' 1 $lifted.Count
. ([scriptblock]::Create($lifted[0].Extent.Text))

Reset-Machine
$defaultRoot = Join-Path $Script:WorkRoot 'pretend-default-DELTA'
$contextRoot = Join-Path $Script:WorkRoot 'the-one-i-am-standing-in'
$null = New-TestInstallation -Root $defaultRoot -Project 'deltadefault' -Volume 'deltadefault_pgdata' -WithDockerResources
$null = New-TestInstallation -Root $contextRoot -Project 'deltacontext' -Volume 'deltacontext_pgdata' -WithDockerResources

# The uninstaller is inside the context installation, as it is when the
# installer was extracted into its own installation root.
$resolved = Resolve-DeltaUninstallRoot -InstallRoot $defaultRoot -WasSupplied $false `
    -ScriptRoot $contextRoot -WorkingDirectory $contextRoot
Assert-Equal 'the root is the one the uninstaller is part of' $contextRoot $resolved.InstallRoot
Assert-Equal 'and it is not the default'                      'deltacontext' $resolved.Target.ProjectName
Assert-Equal 'the decision is recorded as context'            'context' $resolved.Source

# A subdirectory counts: an operator standing in <root>\logs is still standing
# in that installation.
$resolved = Resolve-DeltaUninstallRoot -InstallRoot $defaultRoot -WasSupplied $false `
    -ScriptRoot (Join-Path $contextRoot 'logs\installer') -WorkingDirectory (Join-Path $contextRoot 'uploads')
Assert-Equal 'a subdirectory resolves to its installation root' $contextRoot $resolved.InstallRoot

# The working directory alone is enough, with the uninstaller somewhere else.
$elsewhere = Join-Path $Script:WorkRoot 'downloads-installer-dir'
$null = New-Item -ItemType Directory -Path $elsewhere -Force
$resolved = Resolve-DeltaUninstallRoot -InstallRoot $defaultRoot -WasSupplied $false `
    -ScriptRoot $elsewhere -WorkingDirectory $contextRoot
Assert-Equal 'the working directory alone retargets it' $contextRoot $resolved.InstallRoot

# An explicitly named root is never overridden, however deep inside another
# installation the run is happening.
$resolved = Resolve-DeltaUninstallRoot -InstallRoot $defaultRoot -WasSupplied $true `
    -ScriptRoot $contextRoot -WorkingDirectory $contextRoot
Assert-Equal 'a supplied -InstallRoot wins over the context' $defaultRoot $resolved.InstallRoot
Assert-Equal 'and is recorded as supplied'                   'supplied' $resolved.Source

# The normal distribution shape must be unchanged: an installer directory that
# is not inside any installation, and a registered default.
$resolved = Resolve-DeltaUninstallRoot -InstallRoot $defaultRoot -WasSupplied $false `
    -ScriptRoot $elsewhere -WorkingDirectory $elsewhere
Assert-Equal 'an installer outside any installation still uses the default' $defaultRoot $resolved.InstallRoot
Assert-Equal 'and that is recorded as the default'                          'default' $resolved.Source

# The containing-installation walk itself.
$containing = Get-DeltaContainingInstallation -Path (Join-Path $contextRoot 'logs\nginx')
Assert-Equal 'walks up from a nested directory'  $contextRoot $containing.InstallRoot
$containing = Get-DeltaContainingInstallation -Path $contextRoot
Assert-Equal 'and matches the root itself'       $contextRoot $containing.InstallRoot
Assert-That  'an unrelated directory resolves to nothing' ($null -eq (Get-DeltaContainingInstallation -Path $elsewhere))
Assert-That  'a drive root resolves to nothing'           ($null -eq (Get-DeltaContainingInstallation -Path ($env:SystemDrive + '\')))
Assert-That  'an empty path resolves to nothing'          ($null -eq (Get-DeltaContainingInstallation -Path ''))
Assert-That  'a directory merely ABOVE installations resolves to nothing' ($null -eq (Get-DeltaContainingInstallation -Path $Script:WorkRoot))

# Nothing about resolving a root may touch Docker or delete anything.
Assert-Equal 'resolution issued no Docker call'  0 $Script:Machine.DockerCalls.Count
Assert-That  'the default installation is untouched on disk' (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $defaultRoot '.delta-install.json') -PathType Leaf)
Assert-That  'and so is the context installation'            (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $contextRoot '.delta-install.json') -PathType Leaf)

# ===========================================================================
Start-TestCase 'The archive is the promise: it holds what the operator would miss'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'archive-contents'
$backupRoot = New-TestBackupRoot -Name 'backups-contents'
$target = New-TestInstallation -Root $root -Project 'deltaarchive' -Volume 'deltaarchive_pgdata' -WithDockerResources
[System.IO.File]::WriteAllText((Join-Path $root 'uploads\second.bin'), 'more user data', $Script:DeltaUtf8NoBom)

$archive = Backup-DeltaInstallation -Target $target -BackupRoot $backupRoot
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$zip = [System.IO.Compression.ZipFile]::OpenRead($archive.Path)
try { $entries = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }

$leaf = Split-Path -Leaf $root
foreach ($required in @('.env', 'docker-compose.yml', '.delta-install.json', 'nginx/conf.d/delta.conf', 'uploads/evidence.bin', 'uploads/second.bin', 'logs/delta/app.log')) {
    Assert-That "the archive contains $required" ($entries -contains "$leaf/$required")
}
Assert-That 'the archive contains the fresh database dump' (@($entries | Where-Object { $_ -like "$leaf/backups/*.dump" }).Count -eq 1)
Assert-Equal 'the archive reports both upload files'       2 $archive.UploadCount
Assert-That  'the archive is outside the installation root' (-not (Test-DeltaPathContains -Parent $root -Child $archive.Path))

# The stack was quiesced before the files were read, and stopped rather than
# removed - a backup that fails after this point must leave a startable
# installation behind.
Assert-That  'the containers were stopped before archiving' (@($Script:Machine.ComposeCalls | Where-Object { $_ -match '\bstop\b' }).Count -eq 1)
Assert-Equal 'and no down was issued during the backup'     0 @($Script:Machine.ComposeCalls | Where-Object { $_ -match '\bdown\b' }).Count
Assert-Equal 'the containers still exist after the backup'  3 @($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltaarchive' }).Count

# An archive that would be written inside the tree is refused outright.
$inside = $false
try { $null = New-DeltaInstallationArchive -SourceDirectory $root -DestinationPath (Join-Path $root 'backups\self.zip') }
catch { $inside = $true }
Assert-That 'writing the archive inside the tree is refused' $inside

# ===========================================================================
Start-TestCase 'A RUNNING installation is archived and then completely removed'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'running-install'
$backupRoot = New-TestBackupRoot -Name 'backups-running'
$target = New-TestInstallation -Root $root -Project 'deltarun' -Volume 'deltarun_pgdata' -WithDockerResources
$Script:Machine.RunOnce[$Script:DeltaRunOnceName] = "powershell.exe -File `"$root\setup.ps1`""

Assert-Equal 'the database is running before the uninstall' 'running' `
    (@($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltarun' -and $_.Service -eq 'db' })[0].State)

$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot
if ($run.Error) { throw "the running-installation uninstall did not complete: $($run.Error)" }

Assert-Equal 'the outcome is success'                'success' $run.Result.Outcome
Assert-That  'the archive is retained'               (Microsoft.PowerShell.Management\Test-Path -LiteralPath $run.Archive.Path -PathType Leaf)
Assert-Equal 'target DELTA containers = 0'           0 @($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltarun' }).Count
Assert-Equal 'target DELTA networks = 0'             0 @($Script:Machine.Networks   | Where-Object { $_.Project -eq 'deltarun' }).Count
Assert-That  'the PostgreSQL volume is absent'       (-not @($Script:Machine.Volumes | Where-Object { $_.Name -eq 'deltarun_pgdata' }).Count)
Assert-That  'the InstallRoot itself is absent'      (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $root))
Assert-Equal 'the scheduled tasks are absent'        0 @($Script:Machine.Tasks).Count
Assert-Equal 'the firewall rules are absent'         0 @($Script:Machine.FirewallRules).Count
Assert-That  'the RunOnce continuation is absent'    (-not $Script:Machine.RunOnce.ContainsKey($Script:DeltaRunOnceName))
Assert-That  'the closing verification found nothing left' $run.Result.Verification.Clean
# Nothing had to be started: it was already running.
Assert-Equal 'no service was started for a running installation' 0 $Script:Machine.ServicesStarted.Count

# ===========================================================================
Start-TestCase 'A STOPPED installation starts only PostgreSQL, then is removed'
# ===========================================================================
#
# The observed failure this suite exists to close:
#
#     The database backup failed at stage 'precheck':
#     The database container is not running (Exited (0) 17 hours ago).
#     Start DELTA first, then take the backup.
#
#     Nothing was deleted.
#
# An uninstaller that cannot uninstall a stopped application has not
# implemented uninstall. The stand-in New-DeltaDatabaseBackup above reproduces
# that precheck exactly, so this case can only pass if the uninstaller really
# does start the database itself.

Reset-Machine
$root = Join-Path $Script:WorkRoot 'stopped-install'
$backupRoot = New-TestBackupRoot -Name 'backups-stopped'
$target = New-TestInstallation -Root $root -Project 'deltastopped' -Volume 'deltastopped_pgdata' -WithDockerResources -Stopped
$Script:Machine.RunOnce[$Script:DeltaRunOnceName] = "powershell.exe -File `"$root\setup.ps1`""

foreach ($service in @('db', 'delta', 'nginx')) {
    Assert-Equal "the $service container is stopped before the uninstall" 'exited' `
        (@($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltastopped' -and $_.Service -eq $service })[0].State)
}
$survey = Get-DeltaUninstallSurvey -Target $target -DockerAvailable $true
Assert-Equal 'the survey reports the database as stopped' 'exited' $survey.DatabaseState

$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot

Assert-That  "the uninstall completed without asking the operator to start DELTA ($($run.Error))" (-not $run.Error)
if ($run.Error) { throw "a stopped installation could not be uninstalled: $($run.Error)" }

# It started the database, and ONLY the database.
Assert-That  'the database was started for the backup'  ($Script:Machine.ServicesStarted -contains 'db')
Assert-Equal 'exactly one service was started'          1 $Script:Machine.ServicesStarted.Count
Assert-That  'the DELTA application was never started'  (-not ($Script:Machine.ServicesStarted -contains 'delta'))
Assert-That  'NGINX was never started'                  (-not ($Script:Machine.ServicesStarted -contains 'nginx'))
$startCalls = @($Script:Machine.ComposeCalls | Where-Object { $_ -match '\b(start|up)\b' })
Assert-That  'a start was issued at all'                ($startCalls.Count -ge 1)
Assert-Equal 'and no start named delta or nginx'        0 @($startCalls | Where-Object { $_ -match '\s(delta|nginx)(\s|$)' }).Count
Assert-That  'readiness was established with pg_isready' (@($Script:Machine.ComposeCalls | Where-Object { $_ -match 'pg_isready' }).Count -ge 1)

# And then it uninstalled, completely.
Assert-Equal 'the outcome is success'                'success' $run.Result.Outcome
Assert-That  'the archive is retained'               (Microsoft.PowerShell.Management\Test-Path -LiteralPath $run.Archive.Path -PathType Leaf)
Assert-That  'the archive is outside the InstallRoot' (-not (Test-DeltaPathContains -Parent $root -Child $run.Archive.Path))
Assert-That  'it holds the fresh database dump'      ($run.Archive.DatabaseDump -like '*.dump')
Assert-Equal 'target DELTA containers = 0'           0 @($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltastopped' }).Count
Assert-Equal 'target DELTA networks = 0'             0 @($Script:Machine.Networks   | Where-Object { $_.Project -eq 'deltastopped' }).Count
Assert-That  'the PostgreSQL volume is absent'       (-not @($Script:Machine.Volumes | Where-Object { $_.Name -eq 'deltastopped_pgdata' }).Count)
Assert-That  'the InstallRoot itself is absent'      (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $root))
Assert-Equal 'the scheduled tasks are absent'        0 @($Script:Machine.Tasks).Count
Assert-Equal 'the firewall rules are absent'         0 @($Script:Machine.FirewallRules).Count
Assert-That  'the RunOnce continuation is absent'    (-not $Script:Machine.RunOnce.ContainsKey($Script:DeltaRunOnceName))
Assert-That  'the closing verification found nothing left' $run.Result.Verification.Clean

# An installation whose containers were removed as well - only the volume and
# the files remain - is still uninstallable in one invocation.
Reset-Machine
$root = Join-Path $Script:WorkRoot 'no-containers-install'
$backupRoot = New-TestBackupRoot -Name 'backups-nocontainers'
$target = New-TestInstallation -Root $root -Project 'deltanoc' -Volume 'deltanoc_pgdata' -WithDockerResources -NoContainers
Assert-Equal 'no container exists before the uninstall' 0 @($Script:Machine.Containers).Count

$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot
Assert-That  "it still completes ($($run.Error))"     (-not $run.Error)
if (-not $run.Error) {
    Assert-Equal 'the outcome is success'             'success' $run.Result.Outcome
    Assert-That  'the database container was created for the backup' ($Script:Machine.ServicesStarted -contains 'db')
    Assert-Equal 'and still nothing else was started' 1 $Script:Machine.ServicesStarted.Count
    Assert-That  'the volume is gone afterwards'      (-not @($Script:Machine.Volumes | Where-Object { $_.Name -eq 'deltanoc_pgdata' }).Count)
    Assert-That  'and so is the InstallRoot'          (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $root))
}

# ===========================================================================
Start-TestCase 'The uninstall may start the database and nothing else'
# ===========================================================================

Reset-Machine
$guardRoot = Join-Path $Script:WorkRoot 'start-guard'
$guardTarget = New-TestInstallation -Root $guardRoot -Project 'deltaguard' -Volume 'deltaguard_pgdata' -WithDockerResources -Stopped

foreach ($service in @('delta', 'nginx')) {
    $refusal = Invoke-DeltaDatabaseOnlyCompose -Target $guardTarget -Arguments @('start', $service)
    Assert-That "starting '$service' from the uninstall is refused" ($refusal.Refused -eq $true -and $refusal.ExitCode -ne 0)
    Assert-That "  and the refusal says why"                        ($refusal.StdErr -match '(?i)database service and nothing else')
}
$wholeProject = Invoke-DeltaDatabaseOnlyCompose -Target $guardTarget -Arguments @('start')
Assert-That 'a vector naming no service at all is refused too' ($wholeProject.Refused -eq $true)

$allowed = Invoke-DeltaDatabaseOnlyCompose -Target $guardTarget -Arguments @('start', 'db')
Assert-That 'starting the database is allowed' ($allowed.Refused -eq $false -and $allowed.ExitCode -eq 0)
Assert-That 'and the delta container is still stopped' `
    (@($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltaguard' -and $_.Service -eq 'delta' })[0].State -eq 'exited')

# The operand parser itself, on the vector that made a word-matching guard
# wrong: POSTGRES_USER and POSTGRES_DB are both `delta` in this product.
$probe = Get-DeltaComposeServiceOperand -Arguments @('exec', '-T', 'db', 'pg_isready', '-U', 'delta', '-d', 'delta')
Assert-Equal 'the exec subcommand is read'              'exec' $probe.Subcommand
Assert-Equal 'and only db is treated as a service'      'db'   ($probe.Services -join ',')
$upProbe = Get-DeltaComposeServiceOperand -Arguments @('up', '-d', '--no-deps', 'db')
Assert-Equal 'up -d --no-deps db acts on db alone'      'db'   ($upProbe.Services -join ',')
$bareStop = Get-DeltaComposeServiceOperand -Arguments @('stop')
Assert-Equal 'a bare stop names no service'             0      @($bareStop.Services).Count
$pgIsReady = Invoke-DeltaDatabaseOnlyCompose -Target $guardTarget -Arguments @('exec', '-T', 'db', 'pg_isready', '-U', 'delta', '-d', 'delta')
Assert-That  'and the readiness probe is therefore allowed' ($pgIsReady.Refused -eq $false)

# ===========================================================================
Start-TestCase 'A database that cannot be started aborts with nothing removed'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'db-wont-start'
$backupRoot = New-TestBackupRoot -Name 'backups-wont-start'
$target = New-TestInstallation -Root $root -Project 'deltadead' -Volume 'deltadead_pgdata' -WithDockerResources -Stopped
$Script:Machine.DatabaseStartFails = $true
$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot
$Script:Machine.DatabaseStartFails = $false

Assert-That  'the run stopped with an error'         ($null -ne $run.Error)
Assert-That  'the error explains the database could not be made ready' ($run.Error -match '(?i)could not be made ready')
Assert-That  'and says nothing was deleted'          ($run.Error -match '(?i)nothing was deleted')
Assert-That  'no removal result was produced'        ($null -eq $run.Result)
Assert-That  'the InstallRoot remains'               (Microsoft.PowerShell.Management\Test-Path -LiteralPath $root -PathType Container)
Assert-Equal 'the containers remain'                 3 @($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltadead' }).Count
Assert-Equal 'the database volume remains'           1 @($Script:Machine.Volumes | Where-Object { $_.Name -eq 'deltadead_pgdata' }).Count
Assert-Equal 'no compose down was issued'            0 @($Script:Machine.ComposeCalls | Where-Object { $_ -match '\bdown\b' }).Count
Assert-Equal 'no volume rm was issued'               0 @($Script:Machine.DockerCalls  | Where-Object { $_ -match '\bvolume\s+rm\b' }).Count

# A database that starts but never becomes ready is the same refusal. Called
# directly with a one-second budget, because the real budget is five minutes.
Reset-Machine
$notReadyRoot = Join-Path $Script:WorkRoot 'db-never-ready'
$notReadyTarget = New-TestInstallation -Root $notReadyRoot -Project 'deltaslow' -Volume 'deltaslow_pgdata' -WithDockerResources -Stopped
$Script:Machine.DatabaseNeverReady = $true
$readiness = Start-DeltaDatabaseForBackup -Target $notReadyTarget -TimeoutSeconds 1
$Script:Machine.DatabaseNeverReady = $false
Assert-That 'a database that never accepts connections is not Ready' (-not $readiness.Ready)
Assert-That 'and the reason says so'                                 ($readiness.Reason -match '(?i)did not become ready')

# ===========================================================================
Start-TestCase 'A backup that fails after the start leaves the database stopped'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'restore-stopped-state'
$backupRoot = New-TestBackupRoot -Name 'backups-restore-state'
$target = New-TestInstallation -Root $root -Project 'deltaundo' -Volume 'deltaundo_pgdata' -WithDockerResources -Stopped

$Script:BackupShouldFail = $true
$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot
$Script:BackupShouldFail = $false

Assert-That  'the run stopped with an error'          ($null -ne $run.Error)
Assert-That  'nothing was deleted'                    ($run.Error -match '(?i)nothing was deleted')
Assert-Equal 'the containers remain'                  3 @($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltaundo' }).Count
Assert-Equal 'the database was stopped again'         'exited' `
    (@($Script:Machine.Containers | Where-Object { $_.Project -eq 'deltaundo' -and $_.Service -eq 'db' })[0].State)
Assert-That  'the stop was scoped to the db service'  (@($Script:Machine.ComposeCalls | Where-Object { $_ -match '\bstop\s+db$' }).Count -ge 1)
Assert-That  'the InstallRoot remains'                (Microsoft.PowerShell.Management\Test-Path -LiteralPath $root -PathType Container)

# ===========================================================================
Start-TestCase 'The archive is the ENTIRE InstallRoot, recursively'
# ===========================================================================
#
# Not "the directories this file knows about". The walk is compared against an
# independent Get-ChildItem -Recurse taken by this test, so an allow-list
# creeping back into the archive code fails here rather than in production.

Reset-Machine
$root = Join-Path $Script:WorkRoot 'whole-tree'
$backupRoot = New-TestBackupRoot -Name 'backups-whole-tree'
$target = New-TestInstallation -Root $root -Project 'deltawhole' -Volume 'deltawhole_pgdata' -WithDockerResources

# A directory no version of this installer has ever heard of, nested, with a
# dotted name and a file with no extension - the shape of a future feature.
foreach ($relative in @(
    'future-feature\deep\nested'
    '.cache\generated'
    'templates'
    'uploads\tenant\temp'
)) {
    $null = New-Item -ItemType Directory -Path (Join-Path $root $relative) -Force
}
[System.IO.File]::WriteAllText((Join-Path $root 'future-feature\deep\nested\payload'),  'a file nobody listed', $Script:DeltaUtf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root '.cache\generated\thing.json'),         '{"generated":true}',  $Script:DeltaUtf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root 'templates\note.txt'),                  'installer runtime file', $Script:DeltaUtf8NoBom)
# Certificates, logs, uploads and previous backups, all present.
[System.IO.File]::WriteAllText((Join-Path $root 'certs\delta.crt'),        '-----BEGIN CERTIFICATE-----', $Script:DeltaUtf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root 'certs\delta.key'),        '-----BEGIN PRIVATE KEY-----', $Script:DeltaUtf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root 'logs\nginx\access.log'),  'GET / 200', $Script:DeltaUtf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root 'logs\installer\setup.log'), 'transcript', $Script:DeltaUtf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root 'uploads\tenant\temp\part.bin'), 'staged upload', $Script:DeltaUtf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root 'backups\delta-old.dump'), 'an older dump', $Script:DeltaUtf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $root '.env.bak-20250101'),      'a previous .env', $Script:DeltaUtf8NoBom)

# The survey must see the whole tree, not five known directories.
$survey = Get-DeltaUninstallSurvey -Target $target -DockerAvailable $true
Assert-That 'the survey lists the unknown directory' (@($survey.Directories | Where-Object { $_.Name -eq 'future-feature' }).Count -eq 1)
Assert-That 'and the dotted one'                     (@($survey.Directories | Where-Object { $_.Name -eq '.cache' }).Count -eq 1)
Assert-That 'and counts every file under the root'   ($survey.TotalFiles -eq @(Get-ChildItem -LiteralPath $root -Recurse -File -Force).Count)

# The inventory this test takes itself, before the backup runs.
$before = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
    ForEach-Object { $_.FullName.Substring($root.Length + 1) })

$archive = Backup-DeltaInstallation -Target $target -BackupRoot $backupRoot
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$zip = [System.IO.Compression.ZipFile]::OpenRead($archive.Path)
try { $entries = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }

$leaf = Split-Path -Leaf $root
$absent = @($before | Where-Object { $entries -notcontains "$leaf/$($_ -replace '\\', '/')" })
Assert-Equal "every pre-backup file is in the archive (missing: $($absent -join ', '))" 0 $absent.Count
Assert-That  'including the previously unknown directory' ($entries -contains "$leaf/future-feature/deep/nested/payload")
Assert-That  'including the dotted generated directory'   ($entries -contains "$leaf/.cache/generated/thing.json")
Assert-That  'including the certificates'                 ($entries -contains "$leaf/certs/delta.crt" -and $entries -contains "$leaf/certs/delta.key")
Assert-That  'including the DELTA application log'        ($entries -contains "$leaf/logs/delta/app.log")
Assert-That  'including the NGINX access log'             ($entries -contains "$leaf/logs/nginx/access.log")
Assert-That  'including the installer transcript'         ($entries -contains "$leaf/logs/installer/setup.log")
Assert-That  'including uploads, nested and staged'       ($entries -contains "$leaf/uploads/tenant/temp/part.bin")
Assert-That  'including a previous .env snapshot'         ($entries -contains "$leaf/.env.bak-20250101")
Assert-That  'including an older database dump'           ($entries -contains "$leaf/backups/delta-old.dump")
Assert-That  'and the fresh verified dump'                (@($entries | Where-Object { $_ -like "$leaf/backups/delta-2*.dump" }).Count -eq 1)
Assert-Equal 'the verification counted the whole inventory' $before.Count ($archive.InventoryCount - 1)  # the fresh dump is new

$represented = @{}
foreach ($category in $archive.Represented) { $represented[$category.Path] = $category }
foreach ($category in @('uploads', 'logs', 'certs', 'backups')) {
    Assert-That "$category is reported as represented" ($represented[$category].SourceCount -gt 0 -and $represented[$category].ArchivedCount -ge $represented[$category].SourceCount)
}

# The completeness check is against the inventory, not a count: an archive
# whose entry count matches but whose contents do not must not verify.
$tampered = [PSCustomObject]@{
    Path = $archive.Path; RootFolderName = $leaf; FileCount = $archive.EntryCount
    AddedCount = $archive.EntryCount; SourceBytes = 0; Failures = @()
    Inventory = @([PSCustomObject]@{ RelativePath = 'uploads\never-archived.bin'; FullName = 'x'; Length = 10 })
}
$tamperCheck = Test-DeltaInstallationArchive -Archive $tampered -Target $target `
    -DatabaseBackup ([PSCustomObject]@{ FileName = $archive.DatabaseDump; SizeBytes = 0 })
Assert-That 'a file the walk saw but the archive lacks fails verification' (-not $tamperCheck.Verified)
Assert-That 'and the reason names the missing file'                        ($tamperCheck.Reason -match 'never-archived\.bin')

# ===========================================================================
Start-TestCase 'Docker itself, and everything unrelated to DELTA, survives'
# ===========================================================================

Reset-Machine
$root = Join-Path $Script:WorkRoot 'infrastructure'
$backupRoot = New-TestBackupRoot -Name 'backups-infrastructure'
$target = New-TestInstallation -Root $root -Project 'deltainfra' -Volume 'deltainfra_pgdata' -WithDockerResources -Stopped

Add-MachineContainer -Name 'someone-elses-db-1' -Project 'other'
Add-MachineVolume    -Name 'other_data'         -Project 'other'
Add-MachineNetwork   -Name 'other_default'      -Project 'other'
Add-MachineNetwork   -Name 'bridge'
Add-MachineTask      -Name 'Unrelated backup job' -Arguments '-File C:\jobs\backup.ps1'
$null = $Script:Machine.FirewallRules.Add([PSCustomObject]@{ Name = 'Some other product - HTTP' })

$run = Invoke-FullUninstall -Target $target -BackupRoot $backupRoot
Assert-Equal 'the outcome is success' 'success' $run.Result.Outcome

Assert-Equal "the neighbour's container survives" 1 @($Script:Machine.Containers | Where-Object { $_.Name -eq 'someone-elses-db-1' }).Count
Assert-Equal "the neighbour's volume survives"    1 @($Script:Machine.Volumes    | Where-Object { $_.Name -eq 'other_data' }).Count
Assert-Equal "the neighbour's network survives"   1 @($Script:Machine.Networks   | Where-Object { $_.Name -eq 'other_default' }).Count
Assert-Equal 'the default bridge network survives' 1 @($Script:Machine.Networks  | Where-Object { $_.Name -eq 'bridge' }).Count
Assert-Equal 'an unrelated scheduled task survives' 1 @($Script:Machine.Tasks    | Where-Object { $_.Name -eq 'Unrelated backup job' }).Count
Assert-Equal 'an unrelated firewall rule survives'  1 @($Script:Machine.FirewallRules | Where-Object { $_.Name -eq 'Some other product - HTTP' }).Count

# Docker Desktop, the engine, the CLI and Compose are infrastructure, not
# DELTA. Nothing in the run may touch them, and no prune of any kind is ever
# issued - not even a scoped one.
$forbidden = @($Script:Machine.DockerCalls | Where-Object {
    $_ -match '\b(system\s+prune|container\s+prune|volume\s+prune|network\s+prune|image\s+prune)\b' -or
    $_ -match '\bimage\s+rm\b' -or $_ -match '\brmi\b'
})
Assert-Equal 'no prune and no image removal was issued' 0 $forbidden.Count

# The stronger form: the shipped code contains no way to express it.
$uninstallSources = @(
    (Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'uninstall.ps1') -Raw)
    (Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'lib\Delta.Uninstall.ps1') -Raw)
) -join "`n"
foreach ($pattern in @(
    @{ Regex = 'system\s+prune';               Label = 'docker system prune' }
    @{ Regex = 'volume\s+prune';               Label = 'docker volume prune' }
    @{ Regex = 'container\s+prune';            Label = 'docker container prune' }
    @{ Regex = 'network\s+prune';              Label = 'docker network prune' }
    @{ Regex = 'Uninstall-DeltaDockerDesktop'; Label = 'a Docker Desktop uninstall' }
    @{ Regex = 'wsl(\.exe)?[^\n]*--unregister'; Label = 'a WSL distribution removal' }
    @{ Regex = 'Disable-WindowsOptionalFeature'; Label = 'a Windows feature being disabled' }
    @{ Regex = 'Set-DeltaDockerAutoStart';     Label = "a change to Docker Desktop's AutoStart" }
)) {
    # Prose in the comments explains why these are absent, so the match has to
    # exclude commented lines to mean anything.
    $code = ($uninstallSources -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Assert-Equal "the uninstaller cannot issue $($pattern.Label)" 0 @([regex]::Matches($code, $pattern.Regex)).Count
}

}
finally {
    # The suite's own cleanup. Never inside a real installation: everything it
    # created is under one temporary work root.
    Set-Location -LiteralPath $Script:ProjectRoot -ErrorAction SilentlyContinue
    if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $Script:WorkRoot) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-TestLine '' 'Gray'
Write-TestLine '------------------------------------------------------------' 'Gray'
Write-TestLine "  passed: $Script:Passed" 'Green'
Write-TestLine "  failed: $Script:Failed" $(if ($Script:Failed -gt 0) { 'Red' } else { 'Gray' })
Write-TestLine '------------------------------------------------------------' 'Gray'
Write-TestLine '  Docker, Task Scheduler, the firewall and the registry were' 'DarkGray'
Write-TestLine '  stand-ins. The filesystem was real, under one temporary root.' 'DarkGray'

if ($Script:Failed -gt 0) { exit 1 }
exit 0
