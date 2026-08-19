# =============================================================================
# Delta.Docker.ps1 - Windows prerequisites, caveat disclosure, Docker Desktop
#                    detection / installation / validation
#
# Dot-source Delta.Common.ps1 and Delta.Config.ps1 first.
#
# Assessment references: A§5 (Windows/Docker runtime), A§5.3 (WSL detection
# traps), A§5.4 (prerequisite table), A§5.5 (silent install), A§5.6 (caveats
# C1/C2), A§22 (failure and recovery), A§23 (what must NOT be carried over
# from the native installer).
#
# The boundary rule from A§4 applies to every function here: this file talks
# to Docker only through `docker`, `docker compose` and `docker desktop`, and
# to WSL only through `wsl.exe`. It never enters a Linux distribution, never
# creates one, never supervises dockerd, and never edits wsl.conf.
# =============================================================================

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Vendor-documented silent installer (A§5.5). Used only after the operator has
# confirmed the C2 licensing disclosure.
$Script:DeltaDockerInstallerUrl  = 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'
$Script:DeltaDockerInstallerName = 'Docker Desktop Installer.exe'

# Windows build floor. 19044 (Windows 10 21H2) is Docker Desktop's own WSL2
# minimum; below it the product does not run at all, so it is a stop.
$Script:DeltaMinimumWindowsBuild = 19044

# The builds DELTA is actually targeted at (A§4 diagram, A§26 U5): Server 2022
# (20348), Windows 11 (22000) and Server 2025 (26100). A supported-by-Docker
# but untested-by-DELTA host gets a notice, never a refusal - refusing a host
# Docker itself supports would be this installer inventing a restriction.
$Script:DeltaTestedServerBuild = 20348
$Script:DeltaTestedClientBuild = 22000

# Free-space thresholds, per volume. The floor covers Docker Desktop itself
# (~2.5 GB), the WSL2 VHDX, and the three images (~1 GB pulled). The warning
# threshold is about data growth - uploads and the database - which A§9.5 says
# to size against, not installation size.
$Script:DeltaDiskFloorGb   = 10
$Script:DeltaDiskWarningGb = 25

# A§5.4 / A§22: `docker desktop start --timeout 300`.
$Script:DeltaEngineStartTimeoutSeconds = 300

# ---------------------------------------------------------------------------
# Process seams
#
# Every external command this file runs goes through one of these three
# functions. That is deliberate: it keeps stdout/stderr/exit-code handling in
# one place, and it gives the validation scripts a seam - a test dot-sources
# the library and then defines its own Invoke-DeltaDockerCommand, which
# shadows this one, so the branches that need an absent Docker or a broken
# engine can be exercised without touching the host.
# ---------------------------------------------------------------------------

function ConvertTo-DeltaCommandLine {
    <#
      Joins arguments into a single command line, quoting any that contain a
      space or a quote.

      ProcessStartInfo.ArgumentList - which would do this correctly by itself
      - does not exist in .NET Framework, so it is not available to Windows
      PowerShell 5.1. The escaping here follows the Windows CommandLineToArgvW
      rules: backslashes immediately before a closing quote are doubled, and
      an embedded quote is escaped with a backslash.

      Shell metacharacters are quoted as well as whitespace. A plain .exe
      never sees a shell, but a .cmd/.bat shim on PATH is launched through
      cmd.exe, which would otherwise treat the '|' in a `--format` string as
      a pipe. Observed exactly that against a stub docker shim during Phase 2
      validation; quoting costs nothing for the real docker.exe.
    #>
    param([string[]]$Arguments = @())

    $parts = foreach ($argument in $Arguments) {
        if ($null -eq $argument) { continue }
        if ($argument -ne '' -and $argument -notmatch '[\s"&|<>^%()!]') {
            $argument
        }
        else {
            $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
            $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
            '"' + $escaped + '"'
        }
    }
    return ($parts -join ' ')
}

function Invoke-DeltaProcessCapture {
    <#
      Runs a process to completion and returns its exit code, stdout and
      stderr. Never throws for a non-zero exit - a failing command is data,
      not an exception, and every caller here classifies the failure itself.

      Both streams are read asynchronously before WaitForExit: reading one to
      the end while the other fills its 4 KB pipe buffer is the classic
      redirect deadlock, and `docker info` on a broken engine writes to both.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 120
    )

    $result = [PSCustomObject]@{
        FilePath  = $FilePath
        Arguments = $Arguments
        ExitCode  = -1
        StdOut    = ''
        StdErr    = ''
        TimedOut  = $false
        Started   = $false
        Error     = $null
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName               = $FilePath
    $startInfo.UseShellExecute        = $false
    $startInfo.CreateNoWindow         = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError  = $true
    $startInfo.Arguments              = ConvertTo-DeltaCommandLine -Arguments $Arguments

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        $null = $process.Start()
        $result.Started = $true
    }
    catch {
        $result.Error = $_.Exception.Message
        return $result
    }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $result.TimedOut = $true
            try { $process.Kill() } catch { }
        }

        $result.StdOut   = ($stdoutTask.Result).Trim()
        $result.StdErr   = ($stderrTask.Result).Trim()
        $result.ExitCode = if ($result.TimedOut) { -1 } else { $process.ExitCode }
    }
    finally {
        $process.Dispose()
    }

    Write-DeltaLogLine -Message ("run: {0} {1} -> exit {2}{3}" -f $FilePath, ($Arguments -join ' '), $result.ExitCode, $(if ($result.TimedOut) { ' (timed out)' } else { '' })) -Level 'DETAIL'
    if ($result.StdErr) {
        Write-DeltaLogLine -Message ("     stderr: " + $result.StdErr) -Level 'DETAIL'
    }
    return $result
}

function Invoke-DeltaDockerCommand {
    <#
      Runs the docker CLI. Resolved through Get-Command on every call rather
      than cached, because the Docker-absent branch installs it mid-run and
      the very next call has to find it.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 120
    )

    $docker = Get-Command -Name 'docker' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $docker) {
        return [PSCustomObject]@{
            FilePath = 'docker'; Arguments = $Arguments; ExitCode = -1
            StdOut = ''; StdErr = 'The docker CLI was not found on PATH.'
            TimedOut = $false; Started = $false; Error = 'not-found'
        }
    }

    return (Invoke-DeltaProcessCapture -FilePath $docker.Source -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds)
}

function Invoke-DeltaWslCommand {
    <#
      Runs wsl.exe with WSL_UTF8=1 set first (A§5.3, verified): without it
      wsl.exe emits UTF-16LE that PowerShell 5.1 turns into unparseable
      output. The variable is set for this process only and restored, so the
      operator's environment is not modified.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 300
    )

    $wsl = Get-Command -Name 'wsl.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $wsl) {
        return [PSCustomObject]@{
            FilePath = 'wsl.exe'; Arguments = $Arguments; ExitCode = -1
            StdOut = ''; StdErr = 'wsl.exe was not found.'
            TimedOut = $false; Started = $false; Error = 'not-found'
        }
    }

    $previous = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try {
        return (Invoke-DeltaProcessCapture -FilePath $wsl.Source -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds)
    }
    finally {
        if ($null -eq $previous) { Remove-Item Env:\WSL_UTF8 -ErrorAction SilentlyContinue }
        else { $env:WSL_UTF8 = $previous }
    }
}

# ---------------------------------------------------------------------------
# Windows prerequisites (A§5.4)
# ---------------------------------------------------------------------------

function New-DeltaCheckResult {
    <#
      One prerequisite outcome. Severity is 'ok', 'notice' (report and
      continue) or 'blocked' (report and stop) - the three responses A§22
      allows for a prerequisite. Detail carries the measured evidence so the
      transcript records what was actually seen, not just the verdict.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('ok', 'notice', 'blocked')][string]$Severity,
        [string]$Detail,
        [string]$Reason,
        [string]$Remedy
    )
    return [PSCustomObject]@{
        Name     = $Name
        Severity = $Severity
        Detail   = $Detail
        Reason   = $Reason
        Remedy   = $Remedy
    }
}

function Get-DeltaWindowsInfo {
    <#
      The host facts every A§5.4 check reads, gathered once. ProductType 1 is
      a workstation; 2 and 3 are domain controller and server, which is what
      the C1 disclosure keys off.
    #>
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop

    $build = 0
    $null = [int]::TryParse([string]$os.BuildNumber, [ref]$build)

    return [PSCustomObject]@{
        Caption           = [string]$os.Caption
        Version           = [string]$os.Version
        BuildNumber       = $build
        ProductType       = [int]$os.ProductType
        IsServerSku       = ([int]$os.ProductType -ne 1)
        OSArchitecture    = [string]$os.OSArchitecture
        Is64Bit           = ([string]$os.OSArchitecture -match '64')
        SystemDrive       = [string]$os.SystemDrive
        HypervisorPresent = [bool]$cs.HypervisorPresent
        TotalMemoryGb     = [math]::Round(([double]$cs.TotalPhysicalMemory) / 1GB, 1)
    }
}

function Test-DeltaWindowsPrerequisite {
    <#
      Edition, build and architecture (A§5.4 row 1). 32-bit or a build below
      Docker Desktop's own floor is a stop; a build Docker supports but DELTA
      has not been exercised on is a notice.
    #>
    param([Parameter(Mandatory)][object]$WindowsInfo)

    $detail = "$($WindowsInfo.Caption) build $($WindowsInfo.BuildNumber), $($WindowsInfo.OSArchitecture), ProductType $($WindowsInfo.ProductType)"

    if (-not $WindowsInfo.Is64Bit) {
        return (New-DeltaCheckResult -Name 'Windows edition and build' -Severity 'blocked' -Detail $detail `
            -Reason 'Docker Desktop requires 64-bit Windows. This host reports a 32-bit operating system.' `
            -Remedy 'Install DELTA on a 64-bit Windows host.')
    }

    if ($WindowsInfo.BuildNumber -lt $Script:DeltaMinimumWindowsBuild) {
        return (New-DeltaCheckResult -Name 'Windows edition and build' -Severity 'blocked' -Detail $detail `
            -Reason "Docker Desktop with the WSL2 backend requires Windows build $Script:DeltaMinimumWindowsBuild or later. This host is build $($WindowsInfo.BuildNumber)." `
            -Remedy 'Update Windows, or install DELTA on a newer host.')
    }

    $testedFloor = if ($WindowsInfo.IsServerSku) { $Script:DeltaTestedServerBuild } else { $Script:DeltaTestedClientBuild }
    if ($WindowsInfo.BuildNumber -lt $testedFloor) {
        return (New-DeltaCheckResult -Name 'Windows edition and build' -Severity 'notice' -Detail $detail `
            -Reason "This build is supported by Docker Desktop but is older than the versions DELTA has been exercised on (Server 2022 build $Script:DeltaTestedServerBuild, Windows 11 build $Script:DeltaTestedClientBuild, Server 2025 build 26100). Installation continues." `
            -Remedy $null)
    }

    return (New-DeltaCheckResult -Name 'Windows edition and build' -Severity 'ok' -Detail $detail)
}

function Test-DeltaVirtualizationPrerequisite {
    <#
      Hardware virtualization (A§5.4 row 3).

      Order matters, and this host is the reason. `HypervisorPresent = True`
      is checked first and is conclusive: when a hypervisor is already
      running, Windows itself is a guest and Win32_Processor reports
      VirtualizationFirmwareEnabled and SecondLevelAddressTranslationExtensions
      as False even though virtualization is plainly working - measured
      directly on the assessment host, which runs Docker happily. Reading
      those processor flags first would fail a host that is already
      virtualizing.

      Only when no hypervisor is running do the firmware flags mean anything,
      and then `systeminfo` is the documented cross-check (A§5.4).
    #>
    param([Parameter(Mandatory)][object]$WindowsInfo)

    if ($WindowsInfo.HypervisorPresent) {
        return (New-DeltaCheckResult -Name 'Hardware virtualization' -Severity 'ok' `
            -Detail 'HypervisorPresent = True (a hypervisor is running, so virtualization is enabled).')
    }

    $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $firmwareEnabled = $false
    $slat = $false
    if ($processor) {
        $firmwareEnabled = [bool]$processor.VirtualizationFirmwareEnabled
        $slat = [bool]$processor.SecondLevelAddressTranslationExtensions
    }

    if ($firmwareEnabled) {
        return (New-DeltaCheckResult -Name 'Hardware virtualization' -Severity 'ok' `
            -Detail "HypervisorPresent = False, VirtualizationFirmwareEnabled = True (SLAT = $slat). Virtualization is enabled in firmware; no hypervisor is running yet.")
    }

    $systemInfoLine = $null
    $systemInfo = Get-Command -Name 'systeminfo.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($systemInfo) {
        $capture = Invoke-DeltaProcessCapture -FilePath $systemInfo.Source -Arguments @('/FO', 'LIST') -TimeoutSeconds 90
        if ($capture.ExitCode -eq 0 -and $capture.StdOut) {
            $systemInfoLine = ($capture.StdOut -split "`r?`n" | Where-Object { $_ -match 'Virtualization|Hyper-V' } | Select-Object -First 4) -join '; '
        }
    }

    return (New-DeltaCheckResult -Name 'Hardware virtualization' -Severity 'blocked' `
        -Detail "HypervisorPresent = False, VirtualizationFirmwareEnabled = False, SLAT = $slat. $systemInfoLine" `
        -Reason 'Hardware virtualization is not available. Docker Desktop cannot run Linux containers without it.' `
        -Remedy 'Restart the machine, enter the firmware setup (BIOS/UEFI) and enable virtualization - it is usually called Intel VT-x / AMD-V, sometimes with a separate SLAT / VT-d entry. On a virtual machine, enable nested virtualization on the hypervisor that hosts it. Then run this installer again.')
}

function Test-DeltaDiskSpacePrerequisite {
    <#
      Free space (A§5.4 row 9), checked on every volume the installation
      touches: the installation root's volume and the system volume, which is
      where Docker Desktop and the WSL2 VHDX live even when DELTA is
      installed elsewhere.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$WindowsInfo
    )

    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @($InstallRoot, $WindowsInfo.SystemDrive)) {
        if (-not $candidate) { continue }
        $qualifier = $null
        try { $qualifier = [System.IO.Path]::GetPathRoot($candidate) } catch { continue }
        if (-not $qualifier) { continue }
        # Normalise before de-duplicating: GetPathRoot returns 'C:\' for a
        # path but 'C:' for the bare SystemDrive, which would otherwise
        # measure and report the same volume twice.
        $qualifier = $qualifier.TrimEnd('\') + '\'
        $qualifier = $qualifier.ToUpperInvariant()
        if (-not $roots.Contains($qualifier)) { $null = $roots.Add($qualifier) }
    }

    $details = @()
    $blocked = @()
    $low = @()

    foreach ($root in $roots) {
        try {
            $drive = New-Object System.IO.DriveInfo($root)
            if (-not $drive.IsReady) { continue }
            $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
            $details += "$root $freeGb GB free"
            if ($freeGb -lt $Script:DeltaDiskFloorGb) { $blocked += "$root ($freeGb GB)" }
            elseif ($freeGb -lt $Script:DeltaDiskWarningGb) { $low += "$root ($freeGb GB)" }
        }
        catch {
            $details += "$root could not be measured: $($_.Exception.Message)"
        }
    }

    $detail = $details -join ', '

    if ($blocked.Count -gt 0) {
        return (New-DeltaCheckResult -Name 'Disk space' -Severity 'blocked' -Detail $detail `
            -Reason "Less than $Script:DeltaDiskFloorGb GB free on: $($blocked -join ', '). Docker Desktop, the WSL2 virtual disk and the three DELTA images will not fit." `
            -Remedy 'Free space on the volume, or choose an installation root on a volume that has space.')
    }
    if ($low.Count -gt 0) {
        return (New-DeltaCheckResult -Name 'Disk space' -Severity 'notice' -Detail $detail `
            -Reason "Less than $Script:DeltaDiskWarningGb GB free on: $($low -join ', '). That is enough to install, but uploads and the database grow over time - size the volume against expected data growth, not installation size." )
    }
    return (New-DeltaCheckResult -Name 'Disk space' -Severity 'ok' -Detail $detail)
}

function Test-DeltaPendingReboot {
    <#
      Whether Windows is already waiting for a restart. Used after installing
      WSL or Docker Desktop, and reported before an install so the operator
      is not sent into one on a host that is mid-servicing.
    #>
    $signals = New-Object 'System.Collections.Generic.List[string]'

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $null = $signals.Add('Component Based Servicing: RebootPending')
    }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $null = $signals.Add('Windows Update: RebootRequired')
    }
    $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($sessionManager -and $sessionManager.PendingFileRenameOperations) {
        $null = $signals.Add('Session Manager: PendingFileRenameOperations')
    }

    return [PSCustomObject]@{
        IsPending = ($signals.Count -gt 0)
        Signals   = $signals.ToArray()
    }
}

# ---------------------------------------------------------------------------
# WSL (A§5.2, A§5.3)
#
# WSL2 is infrastructure for Docker's own engine. This installer never creates
# a Linux distribution and never manages one - `wsl --install` is always
# called with --no-distribution.
# ---------------------------------------------------------------------------

function Get-DeltaWslState {
    <#
      WSL readiness, detected with wsl.exe only.

      Never Get-WindowsOptionalFeature: on this host and on the assessment
      host it reports Microsoft-Windows-Subsystem-Linux as *Disabled* while
      WSL is installed and healthy, because modern WSL ships as a store/MSIX
      package (A§5.3, verified twice).

      Status is one of:
        ready    - the store version of WSL is installed; it is WSL2 by
                   construction
        outdated - wsl.exe answers but has no --version, i.e. the old inbox
                   component; `wsl --update` is the non-destructive fix
        absent   - wsl.exe is missing or reports WSL is not installed
        unknown  - wsl.exe answered in a way this parser does not recognise;
                   reported, never acted on

      The "Default Version" line from --status is parsed permissively and only
      for display: it is localised, and gating on a localised string is how a
      German-language host gets told its healthy WSL is broken.
    #>
    $result = [PSCustomObject]@{
        Status         = 'unknown'
        Version        = $null
        KernelVersion  = $null
        DefaultVersion = $null
        Detail         = $null
    }

    $version = Invoke-DeltaWslCommand -Arguments @('--version') -TimeoutSeconds 60

    if ($version.Error -eq 'not-found') {
        $result.Status = 'absent'
        $result.Detail = 'wsl.exe is not present on this host.'
        return $result
    }

    if ($version.ExitCode -eq 0 -and $version.StdOut -match '(?im)^\s*[^:]*:\s*(\d+)\.(\d+)\.(\d+)') {
        $result.Status  = 'ready'
        $result.Version = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
        if ($version.StdOut -match '(?im)^[^:\r\n]*[Kk]ernel[^:\r\n]*:\s*(\S+)') {
            $result.KernelVersion = $Matches[1]
        }
    }
    else {
        $combined = (($version.StdOut + ' ' + $version.StdErr)).Trim()
        if ($combined -match '(?i)no installed distributions|not installed|is not recognized|kein|WSL_E_') {
            $result.Status = 'absent'
        }
        elseif ($version.ExitCode -ne 0) {
            # wsl.exe exists but does not understand --version: the pre-store
            # inbox component, which Docker's WSL2 backend cannot use as-is.
            $result.Status = 'outdated'
        }
        $result.Detail = $combined
    }

    $status = Invoke-DeltaWslCommand -Arguments @('--status') -TimeoutSeconds 60
    if ($status.ExitCode -eq 0 -and $status.StdOut) {
        if ($status.StdOut -match '(?im)^[^:\r\n]*:\s*([12])\s*$') {
            $result.DefaultVersion = $Matches[1]
        }
        if ($result.Status -eq 'unknown') {
            $result.Status = 'ready'
        }
        if (-not $result.Detail) {
            $result.Detail = ($status.StdOut -split "`r?`n" | Select-Object -First 2) -join '; '
        }
    }
    elseif ($result.Status -eq 'unknown') {
        $result.Detail = (($status.StdOut + ' ' + $status.StdErr)).Trim()
    }

    return $result
}

function Install-DeltaWsl {
    <#
      Installs the WSL platform - and nothing else.

      --no-distribution is not optional here. A bare `wsl --install` also
      installs Ubuntu and leaves the operator owning a Linux distribution,
      which A§5.2 states this product never does: Docker Desktop brings its
      own private docker-desktop distribution and that is the only Linux the
      operator ever has to think about.

      A restart is always required afterwards.
    #>
    Write-Step 'Installing the Windows Subsystem for Linux'
    Write-Detail 'Running: wsl --install --no-distribution'
    Write-Detail 'No Linux distribution is created. Docker Desktop supplies its own.'

    $capture = Invoke-DeltaWslCommand -Arguments @('--install', '--no-distribution') -TimeoutSeconds 900

    if ($capture.ExitCode -ne 0) {
        $detail = (($capture.StdOut + "`n" + $capture.StdErr)).Trim()
        return [PSCustomObject]@{
            Succeeded = $false
            ExitCode  = $capture.ExitCode
            Detail    = $detail
        }
    }

    if ($capture.StdOut) {
        foreach ($line in ($capture.StdOut -split "`r?`n" | Where-Object { $_.Trim() })) {
            Write-Detail $line.Trim()
        }
    }

    return [PSCustomObject]@{
        Succeeded = $true
        ExitCode  = 0
        Detail    = $capture.StdOut
    }
}

# ---------------------------------------------------------------------------
# Docker detection and validation (A§5.4, A§22)
# ---------------------------------------------------------------------------

function Get-DeltaDockerCliState {
    param()

    $docker = Get-Command -Name 'docker' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $docker) {
        return [PSCustomObject]@{ Present = $false; Path = $null; ClientVersion = $null }
    }

    $version = Invoke-DeltaDockerCommand -Arguments @('version', '--format', '{{.Client.Version}}') -TimeoutSeconds 60
    $clientVersion = $null
    if ($version.ExitCode -eq 0 -and $version.StdOut) {
        $clientVersion = ($version.StdOut -split "`r?`n" | Select-Object -First 1).Trim()
    }

    return [PSCustomObject]@{
        Present       = $true
        Path          = $docker.Source
        ClientVersion = $clientVersion
    }
}

function Get-DeltaDockerEngineState {
    <#
      Distinguishes the three Docker conditions A§22 gives different,
      non-destructive recoveries for, plus the absent case:

        cli-absent  - no docker CLI            -> install branch
        engine-down - CLI answers, daemon does not  -> docker desktop start
        wrong-mode  - daemon answers, OSType is windows -> engine use linux
        ready       - daemon answers, OSType is linux
        error       - anything else; reported verbatim, never guessed at

      One `docker info` call carries every fact the later stages need, so this
      does not poll the engine four times for four properties.
    #>
    param()

    $cli = Get-DeltaDockerCliState
    if (-not $cli.Present) {
        return [PSCustomObject]@{
            Status = 'cli-absent'; OSType = $null; ServerVersion = $null; KernelVersion = $null
            OperatingSystem = $null; Backend = $null; ClientVersion = $null; Path = $null
            Detail = 'The docker CLI was not found on PATH.'; RawError = $null
        }
    }

    $format = '{{.OSType}}|{{.ServerVersion}}|{{.KernelVersion}}|{{.OperatingSystem}}'
    $info = Invoke-DeltaDockerCommand -Arguments @('info', '--format', $format) -TimeoutSeconds 120

    if ($info.ExitCode -ne 0 -or -not $info.StdOut) {
        $raw = (($info.StdErr + "`n" + $info.StdOut)).Trim()
        $status = 'error'
        if ($info.TimedOut) {
            $status = 'engine-down'
        }
        elseif ($raw -match '(?i)error during connect|cannot connect to the docker daemon|the system cannot find the file specified|open //./pipe|docker_engine|is the docker daemon running') {
            $status = 'engine-down'
        }
        return [PSCustomObject]@{
            Status = $status; OSType = $null; ServerVersion = $null; KernelVersion = $null
            OperatingSystem = $null; Backend = $null
            ClientVersion = $cli.ClientVersion; Path = $cli.Path
            Detail = 'The Docker engine did not answer.'; RawError = $raw
        }
    }

    $fields = ($info.StdOut -split "`r?`n" | Select-Object -First 1).Split('|')
    $osType          = if ($fields.Count -gt 0) { $fields[0].Trim() } else { '' }
    $serverVersion   = if ($fields.Count -gt 1) { $fields[1].Trim() } else { '' }
    $kernelVersion   = if ($fields.Count -gt 2) { $fields[2].Trim() } else { '' }
    $operatingSystem = if ($fields.Count -gt 3) { $fields[3].Trim() } else { '' }

    # Backend, for the record A§5/A§16 asks to keep: Docker Desktop's WSL2 VM
    # reports a kernel with the -microsoft-standard-WSL2 suffix, which is the
    # cheapest reliable signal and needs no settings file to be readable.
    $backend = 'unknown'
    if ($kernelVersion -match '(?i)WSL2') { $backend = 'wsl-2' }
    elseif ($operatingSystem -match '(?i)Docker Desktop') { $backend = 'hyper-v' }

    $status = if ($osType -eq 'linux') { 'ready' } elseif ($osType) { 'wrong-mode' } else { 'error' }

    return [PSCustomObject]@{
        Status          = $status
        OSType          = $osType
        ServerVersion   = $serverVersion
        KernelVersion   = $kernelVersion
        OperatingSystem = $operatingSystem
        Backend         = $backend
        ClientVersion   = $cli.ClientVersion
        Path            = $cli.Path
        Detail          = "OSType $osType, engine $serverVersion, kernel $kernelVersion, backend $backend"
        RawError        = $null
    }
}

function Get-DeltaDockerDesktopStatus {
    <#
      `docker desktop status` returns structured, parseable output (A§2.3,
      verified). Used to tell "Docker Desktop is not running" apart from
      "Docker Desktop is running but the engine is broken" before deciding
      what to do about an engine that will not answer.
    #>
    param()

    $capture = Invoke-DeltaDockerCommand -Arguments @('desktop', 'status') -TimeoutSeconds 60
    $result = [PSCustomObject]@{
        Supported = $true
        Status    = $null
        Detail    = (($capture.StdOut + ' ' + $capture.StdErr)).Trim()
    }

    if ($capture.ExitCode -ne 0 -and $result.Detail -match "(?i)is not a docker command|unknown command|unknown flag") {
        $result.Supported = $false
        return $result
    }
    if ($capture.StdOut -match '(?im)^\s*Status\s+(\S+)') {
        $result.Status = $Matches[1]
    }
    return $result
}

function Wait-DeltaDockerEngine {
    <#
      Polls `docker info` until the engine answers or the budget runs out.
      Reports elapsed time rather than a spinner, because the interesting
      question when this takes a while is how long it has taken (A§22,
      health-check timeout row).
    #>
    param([int]$TimeoutSeconds = 300)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastReport = Get-Date
    $state = $null

    while ((Get-Date) -lt $deadline) {
        $state = Get-DeltaDockerEngineState
        if ($state.Status -eq 'ready' -or $state.Status -eq 'wrong-mode') {
            return $state
        }
        if (((Get-Date) - $lastReport).TotalSeconds -ge 15) {
            $lastReport = Get-Date
            $elapsed = [int]($TimeoutSeconds - ($deadline - (Get-Date)).TotalSeconds)
            Write-Detail "Still waiting for the Docker engine ($elapsed s elapsed)..."
        }
        Start-Sleep -Seconds 5
    }

    return $state
}

function Start-DeltaDockerEngine {
    <#
      Brings a stopped engine up with the vendor's own command (A§5.4, A§22):
      `docker desktop start --timeout 300`. It starts nothing else, kills
      nothing, and touches no container.
    #>
    param([int]$TimeoutSeconds = $Script:DeltaEngineStartTimeoutSeconds)

    Write-Step 'Starting Docker Desktop'

    $desktop = Get-DeltaDockerDesktopStatus
    if ($desktop.Status) {
        Write-Detail "docker desktop status: $($desktop.Status)"
    }

    if (-not $desktop.Supported) {
        Write-DeltaWarning 'This docker CLI has no "docker desktop" subcommand, so the engine cannot be started from here.'
        Write-Detail 'Start Docker Desktop from the Start menu, wait until it reports Running, then run this installer again.'
        return (Get-DeltaDockerEngineState)
    }

    Write-Detail "Running: docker desktop start --timeout $TimeoutSeconds"
    # The CLI's own timeout plus a small margin for it to return.
    $capture = Invoke-DeltaDockerCommand -Arguments @('desktop', 'start', '--timeout', "$TimeoutSeconds") -TimeoutSeconds ($TimeoutSeconds + 30)

    if ($capture.ExitCode -ne 0) {
        $detail = (($capture.StdOut + "`n" + $capture.StdErr)).Trim()
        if ($detail) { Write-Detail $detail }
    }

    return (Wait-DeltaDockerEngine -TimeoutSeconds 120)
}

function Set-DeltaDockerLinuxEngine {
    <#
      Switches Docker Desktop from Windows containers to Linux containers
      (A§22: "yes, with consent"). It is asked for, not assumed: the host may
      be running Windows containers for something else, and switching modes
      stops those containers.
    #>
    param()

    Write-Step 'Docker is in Windows-container mode'
    Write-Detail 'The DELTA image is linux/amd64 only, so Docker must be switched to Linux containers.'

    $confirmed = Read-DeltaYesNoConfirmation -Body {
        Write-Host 'Docker Desktop is currently running Windows containers.'
        Write-Host ''
        Write-Host 'DELTA needs Linux containers. Switching engines will stop any'
        Write-Host 'Windows containers that are running on this host.'
        Write-Host ''
        Write-Host 'Switch Docker Desktop to Linux containers now?'
    }

    if (-not $confirmed) {
        Write-Detail 'Left in Windows-container mode at your request.'
        return $null
    }

    Write-Detail 'Running: docker desktop engine use linux'
    $capture = Invoke-DeltaDockerCommand -Arguments @('desktop', 'engine', 'use', 'linux') -TimeoutSeconds 300
    if ($capture.ExitCode -ne 0) {
        $detail = (($capture.StdOut + "`n" + $capture.StdErr)).Trim()
        if ($detail) { Write-Detail $detail }
    }

    return (Wait-DeltaDockerEngine -TimeoutSeconds 180)
}

function Get-DeltaComposeState {
    <#
      Compose v2+ as a docker CLI plugin (A§5.4 row 8). `docker compose
      version --short` returns a bare version; the major must be at least 2 -
      the v1 `docker-compose.exe` script is a different product with different
      behaviour and is not supported by this installer.
    #>
    param()

    $capture = Invoke-DeltaDockerCommand -Arguments @('compose', 'version', '--short') -TimeoutSeconds 60
    $result = [PSCustomObject]@{
        Available   = $false
        Version     = $null
        Major       = 0
        IsSupported = $false
        Detail      = (($capture.StdOut + ' ' + $capture.StdErr)).Trim()
    }

    if ($capture.ExitCode -ne 0 -or -not $capture.StdOut) {
        return $result
    }

    $version = ($capture.StdOut -split "`r?`n" | Select-Object -First 1).Trim().TrimStart('v')
    $result.Available = $true
    $result.Version = $version
    if ($version -match '^(\d+)') {
        $result.Major = [int]$Matches[1]
        $result.IsSupported = ($result.Major -ge 2)
    }
    return $result
}

# ---------------------------------------------------------------------------
# Caveat disclosure (A§5.6)
# ---------------------------------------------------------------------------

function Show-DeltaServerSkuCaveat {
    <#
      C1. Docker documents that Docker Desktop is not supported on Windows
      Server; it nonetheless installs and runs correctly there (A§2.3,
      verified on Server 2025). This is a disclosure obligation, never a
      refusal - the decision belongs to the operator.

      -RequireConfirmation is passed only on the path that is about to
      install Docker, matching A§5.6's "print an explicit notice before
      installing Docker". On a host where Docker is already present the
      obligation already exists and belongs to the operator, so the notice is
      displayed and recorded without interrupting a rerun - the same
      treatment A§5.6 prescribes explicitly for C2.
    #>
    param(
        [Parameter(Mandatory)][object]$WindowsInfo,
        [switch]$RequireConfirmation
    )

    if (-not $WindowsInfo.IsServerSku) {
        return $true
    }

    Write-Step 'Vendor support notice (server edition)'

    if (-not $RequireConfirmation) {
        Write-Detail "This host is $($WindowsInfo.Caption)."
        Write-Detail 'Docker documents that Docker Desktop is not supported on Windows Server editions.'
        Write-Detail 'It installs and runs correctly there, and DELTA was validated on Server 2025, but'
        Write-Detail 'support for Docker Desktop itself would come from this project, not from Docker.'
        Write-Detail 'Docker Desktop is already installed here, so this is recorded, not asked.'
        return $true
    }

    return (Read-DeltaYesNoConfirmation -Body {
        Write-Host "This host is $($WindowsInfo.Caption)."
        Write-Host ''
        Write-Host 'Docker documents that Docker Desktop is NOT SUPPORTED on Windows Server'
        Write-Host 'editions. In testing it installs and runs correctly on Windows Server 2025,'
        Write-Host 'and DELTA was validated there - but if Docker Desktop itself misbehaves on'
        Write-Host 'this host, Docker will not support it.'
        Write-Host ''
        Write-Host 'This is a disclosure, not a refusal. The decision is yours.'
        Write-Host ''
        Write-Host 'Continue and install Docker Desktop on this server?'
    })
}

function Confirm-DeltaDockerLicensing {
    <#
      C2. Docker Desktop requires a paid subscription for organisations at or
      above 250 employees or $10M annual revenue. `--accept-license` is
      passed to the installer only after this returns $true - accepting a
      licence on the operator's behalf without asking is not this installer's
      to do.
    #>
    param()

    Write-Step 'Docker Desktop licensing'

    return (Read-DeltaYesNoConfirmation -Body {
        Write-Host 'Docker Desktop is commercial software.'
        Write-Host ''
        Write-Host 'It is free for personal use, education, non-commercial open source and'
        Write-Host 'small businesses. Organisations with more than 250 employees OR more than'
        Write-Host '$10 million in annual revenue require a paid Docker subscription.'
        Write-Host ''
        Write-Host 'Full terms: https://docs.docker.com/subscription/desktop-license/'
        Write-Host ''
        Write-Host 'Continuing installs Docker Desktop and accepts the Docker Subscription'
        Write-Host 'Service Agreement on behalf of this organisation.'
        Write-Host ''
        Write-Host 'Do you accept these terms and want to install Docker Desktop?'
    })
}

function Save-DeltaRuntimeFacts {
    <#
      Records the caveat acknowledgements and the selected Docker backend in
      .delta-install.json (A§5.6, and the Phase 2 documentation note).

      Two constraints meet here. The state file is the right home for these
      facts, but creating C:\DELTA belongs to the stage that owns the
      directory tree, which runs later - A§13 has caveat disclosure before
      "create root" for the same reason. So this writes only when the
      installation root already exists AND is demonstrably safe to write to:
      either it already holds a valid installer state file, or it is empty.

      A populated root with no state file is left alone deliberately. On the
      assessment host C:\DELTA holds an unrelated *native* DELTA
      installation, and dropping an installer state file into someone else's
      directory is exactly the kind of thing an installer must not do.

      When the write is deferred the facts are returned to the caller, which
      keeps them for the stage that does create the root.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Facts
    )

    $result = [PSCustomObject]@{ Persisted = $false; Path = $null; Reason = $null }

    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
        $result.Reason = "'$InstallRoot' does not exist yet; these facts will be written when the installation root is created."
        return $result
    }

    $existing = Read-DeltaInstallState -InstallRoot $InstallRoot
    $isOurs = ($existing.Exists -and $existing.IsValid)
    $isEmpty = (@(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue).Count -eq 0)

    if ($existing.Exists -and -not $existing.IsValid) {
        $result.Reason = "'$($existing.Path)' exists but could not be read ($($existing.Error)); it was not overwritten."
        return $result
    }

    if (-not $isOurs -and -not $isEmpty) {
        $result.Reason = "'$InstallRoot' already contains files that this installer did not create, so no state file was written into it."
        return $result
    }

    $properties = [ordered]@{}
    if (-not $isOurs) {
        # A first write has to carry a state value; the installation is by
        # definition incomplete at this point.
        $properties['state'] = 'partial'
        $properties['installRoot'] = $InstallRoot
    }
    foreach ($key in $Facts.Keys) {
        $properties[[string]$key] = $Facts[$key]
    }

    try {
        $result.Path = Write-DeltaInstallState -InstallRoot $InstallRoot -Properties $properties
        $result.Persisted = $true
    }
    catch {
        $result.Reason = $_.Exception.Message
    }
    return $result
}

# ---------------------------------------------------------------------------
# Docker Desktop installation (A§5.5)
# ---------------------------------------------------------------------------

function Get-DeltaDockerInstallLogPaths {
    <#
      Where Docker's own installer writes its log. Reported verbatim on a
      failed install (A§22: report the code *and* Docker's log path, do not
      retry blindly).
    #>
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Docker\install-log.txt')
        (Join-Path $env:LOCALAPPDATA 'Docker\log.txt')
        (Join-Path $env:TEMP 'Docker Desktop Installer.log')
    )
    return ($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
}

function Resolve-DeltaDockerInstaller {
    <#
      Finds the Docker Desktop installer, in order: an explicit path, an
      `installers\` folder beside setup.ps1 (so an air-gapped site can stage
      the binary itself), then Docker's documented download URL.

      The download happens only on the install path, which is already behind
      the C2 confirmation.
    #>
    param(
        [string]$InstallerPath,
        [string]$SearchRoot,
        [switch]$AllowDownload
    )

    $result = [PSCustomObject]@{ Path = $null; Source = $null; Error = $null }

    if ($InstallerPath) {
        if (Test-Path -LiteralPath $InstallerPath -PathType Leaf) {
            $result.Path = (Resolve-Path -LiteralPath $InstallerPath).Path
            $result.Source = 'supplied'
            return $result
        }
        $result.Error = "The installer path '$InstallerPath' does not exist."
        return $result
    }

    if ($SearchRoot) {
        $staged = Join-Path -Path $SearchRoot -ChildPath "installers\$Script:DeltaDockerInstallerName"
        if (Test-Path -LiteralPath $staged -PathType Leaf) {
            $result.Path = $staged
            $result.Source = 'staged'
            return $result
        }
    }

    if (-not $AllowDownload) {
        $result.Error = "No Docker Desktop installer was found. Place '$Script:DeltaDockerInstallerName' in the installers\ folder next to setup.ps1, or pass -DockerInstallerPath."
        return $result
    }

    $destination = Join-Path -Path $env:TEMP -ChildPath $Script:DeltaDockerInstallerName
    Write-Step 'Downloading Docker Desktop'
    Write-Detail "From: $Script:DeltaDockerInstallerUrl"
    Write-Detail "To:   $destination"
    Write-Detail 'This is roughly 600 MB and can take several minutes.'

    $previousProgress = $ProgressPreference
    try {
        # Invoke-WebRequest's progress bar makes a large download several
        # times slower in PowerShell 5.1; suppressing it is a throughput fix,
        # not cosmetics.
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Script:DeltaDockerInstallerUrl -OutFile $destination -UseBasicParsing -ErrorAction Stop
        $result.Path = $destination
        $result.Source = 'downloaded'
    }
    catch {
        $result.Error = "Downloading Docker Desktop failed: $($_.Exception.Message)"
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    return $result
}

function Install-DeltaDockerDesktop {
    <#
      The vendor-documented silent install (A§5.5):

        "Docker Desktop Installer.exe" install --quiet --accept-license
                                       --backend=wsl-2 --always-run-service

      --accept-license is included only when -AcceptLicense is passed, which
      happens only after the C2 confirmation returned true.

      --always-run-service asks the installer to register com.docker.service.
      Whether that actually delivers unattended startup is measured in Phase
      6; passing the flag here is simply the documented install, not a
      startup guarantee.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [switch]$AcceptLicense
    )

    $arguments = @('install', '--quiet')
    if ($AcceptLicense) { $arguments += '--accept-license' }
    $arguments += @('--backend=wsl-2', '--always-run-service')

    Write-Step 'Installing Docker Desktop'
    Write-Detail "Running: `"$InstallerPath`" $($arguments -join ' ')"
    Write-Detail 'This usually takes several minutes and produces no output until it finishes.'

    $capture = Invoke-DeltaProcessCapture -FilePath $InstallerPath -Arguments $arguments -TimeoutSeconds 3600

    $result = [PSCustomObject]@{
        Succeeded      = $false
        ExitCode       = $capture.ExitCode
        RebootRequired = $false
        LogPaths       = @(Get-DeltaDockerInstallLogPaths)
        Detail         = (($capture.StdOut + "`n" + $capture.StdErr)).Trim()
    }

    if ($capture.TimedOut) {
        $result.Detail = 'The Docker Desktop installer did not finish within an hour and was stopped.'
        return $result
    }

    # 3010 is ERROR_SUCCESS_REBOOT_REQUIRED: the install worked and Windows
    # needs a restart.
    if ($capture.ExitCode -eq 0 -or $capture.ExitCode -eq 3010) {
        $result.Succeeded = $true
        $result.RebootRequired = ($capture.ExitCode -eq 3010) -or (Test-DeltaPendingReboot).IsPending
    }

    return $result
}

# ---------------------------------------------------------------------------
# Stage orchestration
# ---------------------------------------------------------------------------

function Show-DeltaCheckResult {
    param([Parameter(Mandatory)][object]$Check)

    switch ($Check.Severity) {
        'ok' {
            Write-Detail ("[ ok ]     {0,-28} {1}" -f $Check.Name, $Check.Detail)
        }
        'notice' {
            Write-Detail ("[note]     {0,-28} {1}" -f $Check.Name, $Check.Detail)
            if ($Check.Reason) { Write-DeltaWarning $Check.Reason }
        }
        'blocked' {
            Write-Detail ("[STOP]     {0,-28} {1}" -f $Check.Name, $Check.Detail)
        }
    }
}

function Invoke-DeltaRuntimeStage {
    <#
      The Phase 2 stage: prove the host can run Linux containers, disclose
      what has to be disclosed, install Docker Desktop if it is absent, and
      validate that the engine and Compose are usable.

      Returns an outcome the caller maps to an exit code:

        ready            - engine reachable, Linux mode, Compose v2+
        reboot-required  - something was installed; Windows must restart and
                           the operator must run setup.ps1 again
        blocked          - a prerequisite cannot be met from here
        declined         - the operator declined a required disclosure

      It creates no directories, generates no artefacts, pulls no images and
      starts no containers. The only host changes it can make are the ones
      its specification calls for: installing WSL (no distribution) and
      installing or starting Docker Desktop, each behind its own disclosure.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$ScriptRoot,
        [string]$DockerInstallerPath,
        [switch]$AllowDownload
    )

    $result = [PSCustomObject]@{
        Outcome      = 'blocked'
        Reason       = $null
        Windows      = $null
        Checks       = @()
        Wsl          = $null
        Docker       = $null
        Compose      = $null
        Caveats      = [ordered]@{}
        StateWrite   = $null
        PendingFacts = [ordered]@{}
    }

    # --- Windows prerequisites -------------------------------------------
    Write-Step 'Checking Windows prerequisites'

    $windows = Get-DeltaWindowsInfo
    $result.Windows = $windows

    $checks = @(
        (Test-DeltaWindowsPrerequisite -WindowsInfo $windows)
        (Test-DeltaVirtualizationPrerequisite -WindowsInfo $windows)
        (Test-DeltaDiskSpacePrerequisite -InstallRoot $InstallRoot -WindowsInfo $windows)
    )
    $result.Checks = $checks

    foreach ($check in $checks) {
        Show-DeltaCheckResult -Check $check
    }

    $blocked = @($checks | Where-Object { $_.Severity -eq 'blocked' })
    if ($blocked.Count -gt 0) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'This host cannot run DELTA in its current state.'
        foreach ($check in $blocked) {
            Write-Detail ''
            Write-Detail "$($check.Name): $($check.Reason)"
            if ($check.Remedy) { Write-Detail $check.Remedy }
        }
        $result.Reason = ($blocked | ForEach-Object { $_.Reason }) -join ' '
        return $result
    }

    $pending = Test-DeltaPendingReboot
    if ($pending.IsPending) {
        Write-DeltaWarning "Windows is already waiting for a restart ($($pending.Signals -join '; ')). Installing over a pending restart can fail in confusing ways."
    }

    # --- Docker present? --------------------------------------------------
    Write-Step 'Detecting Docker'

    $engine = Get-DeltaDockerEngineState
    $result.Docker = $engine

    if ($engine.Status -eq 'cli-absent') {
        Write-Detail 'The docker CLI is not present on this host.'

        # C1 before installing (A§5.6), then C2 before --accept-license.
        if (-not (Show-DeltaServerSkuCaveat -WindowsInfo $windows -RequireConfirmation)) {
            $result.Outcome = 'declined'
            $result.Reason = 'The server-edition support notice was not accepted, so Docker Desktop was not installed.'
            Write-Detail $result.Reason
            return $result
        }
        if ($windows.IsServerSku) {
            $result.Caveats['serverSku'] = $true
        }

        if (-not (Confirm-DeltaDockerLicensing)) {
            $result.Outcome = 'declined'
            $result.Reason = 'The Docker Desktop licence terms were not accepted, so Docker Desktop was not installed.'
            Write-Detail $result.Reason
            return $result
        }
        $result.Caveats['licensing'] = $true
        $result.PendingFacts['caveatsAcknowledged'] = $result.Caveats
        $null = Save-DeltaRuntimeFacts -InstallRoot $InstallRoot -Facts $result.PendingFacts

        # WSL2 must be in place before Docker Desktop's WSL2 backend.
        Write-Step 'Checking WSL2'
        $wsl = Get-DeltaWslState
        $result.Wsl = $wsl
        Write-Detail "WSL status: $($wsl.Status)$(if ($wsl.Version) { " (version $($wsl.Version))" })"

        if ($wsl.Status -eq 'absent' -or $wsl.Status -eq 'outdated') {
            $install = Install-DeltaWsl
            if (-not $install.Succeeded) {
                Write-DeltaFailure ''
                Write-DeltaFailure 'Installing the Windows Subsystem for Linux failed.'
                Write-Detail "wsl.exe exited with $($install.ExitCode)."
                if ($install.Detail) { Write-Detail $install.Detail }
                $result.Reason = 'WSL could not be installed.'
                return $result
            }
            $result.Outcome = 'reboot-required'
            $result.Reason = 'The Windows Subsystem for Linux was installed. Windows must restart before Docker Desktop can be installed.'
            return $result
        }

        $installer = Resolve-DeltaDockerInstaller -InstallerPath $DockerInstallerPath -SearchRoot $ScriptRoot -AllowDownload:$AllowDownload
        if (-not $installer.Path) {
            Write-DeltaFailure ''
            Write-DeltaFailure 'Docker Desktop could not be installed.'
            Write-Detail $installer.Error
            $result.Reason = $installer.Error
            return $result
        }
        Write-Detail "Installer: $($installer.Path) ($($installer.Source))"

        $install = Install-DeltaDockerDesktop -InstallerPath $installer.Path -AcceptLicense
        if (-not $install.Succeeded) {
            Write-DeltaFailure ''
            Write-DeltaFailure "The Docker Desktop installer failed with exit code $($install.ExitCode)."
            if ($install.Detail) { Write-Detail $install.Detail }
            if ($install.LogPaths.Count -gt 0) {
                Write-Detail 'Docker wrote its own installation log to:'
                foreach ($path in $install.LogPaths) { Write-Detail "  $path" }
            }
            else {
                Write-Detail "Docker's installation log is normally at $(Join-Path $env:LOCALAPPDATA 'Docker\install-log.txt')."
            }
            Write-Detail 'Read that log before running the installer again - repeating a failed install without reading it rarely helps.'
            $result.Reason = "The Docker Desktop installer exited with $($install.ExitCode)."
            return $result
        }

        Write-Success 'Docker Desktop installed.'
        $result.Outcome = 'reboot-required'
        $result.Reason = 'Docker Desktop was installed. Restart Windows, sign in, and run setup.ps1 again to continue.'
        return $result
    }

    # --- Docker present: disclose, then validate --------------------------
    Write-Detail "docker CLI: $($engine.Path)$(if ($engine.ClientVersion) { " (client $($engine.ClientVersion))" })"

    $null = Show-DeltaServerSkuCaveat -WindowsInfo $windows
    if ($windows.IsServerSku) {
        $result.Caveats['serverSku'] = $true
    }
    Write-Step 'Docker Desktop licensing'
    Write-Detail 'Docker Desktop is already installed, so its licence terms are already in force.'
    Write-Detail 'Organisations above 250 employees or $10M annual revenue require a paid subscription.'

    Write-Step 'Validating the Docker engine'

    if ($engine.Status -eq 'engine-down') {
        Write-Detail 'The docker CLI is installed but the engine is not answering.'
        if ($engine.RawError) { Write-Detail $engine.RawError }
        $engine = Start-DeltaDockerEngine
        $result.Docker = $engine
    }

    if ($engine.Status -eq 'wrong-mode') {
        $switched = Set-DeltaDockerLinuxEngine
        if ($switched) {
            $engine = $switched
            $result.Docker = $engine
        }
    }

    if ($engine.Status -ne 'ready') {
        Write-DeltaFailure ''
        Write-DeltaFailure 'The Docker engine is not usable.'
        switch ($engine.Status) {
            'engine-down' {
                Write-Detail 'The engine did not answer after Docker Desktop was asked to start.'
                Write-Detail 'docker info reported:'
                if ($engine.RawError) { Write-Detail $engine.RawError }
                Write-Detail 'Start Docker Desktop manually, wait until it reports Running, then run this installer again.'
            }
            'wrong-mode' {
                Write-Detail "Docker is running $($engine.OSType) containers. DELTA's image is linux/amd64 only."
                Write-Detail 'Switch Docker Desktop to Linux containers, then run this installer again.'
            }
            default {
                Write-Detail 'docker info reported:'
                if ($engine.RawError) { Write-Detail $engine.RawError }
                elseif ($engine.Detail) { Write-Detail $engine.Detail }
            }
        }
        $result.Reason = "The Docker engine is not usable (status: $($engine.Status))."
        return $result
    }

    Write-Detail "[ ok ]     Engine                       $($engine.ServerVersion), OSType $($engine.OSType)"
    Write-Detail "[ ok ]     Backend                      $($engine.Backend) (kernel $($engine.KernelVersion))"

    # --- Compose ----------------------------------------------------------
    $compose = Get-DeltaComposeState
    $result.Compose = $compose

    if (-not $compose.IsSupported) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'Docker Compose v2 or later is required.'
        if ($compose.Available) {
            Write-Detail "This host reports Compose $($compose.Version)."
        }
        else {
            Write-Detail '"docker compose version" did not answer:'
            if ($compose.Detail) { Write-Detail $compose.Detail }
            Write-Detail 'Compose v2 ships as a plugin with current Docker Desktop. Update Docker Desktop, then run this installer again.'
        }
        $result.Reason = 'Docker Compose v2 is not available.'
        return $result
    }
    Write-Detail "[ ok ]     Compose                      v$($compose.Version)"

    # --- WSL, for the record ---------------------------------------------
    # Informational on this path: a Linux engine that answers has already
    # proved its backend works, so a WSL parsing quirk must not fail a
    # working host.
    $wsl = Get-DeltaWslState
    $result.Wsl = $wsl
    Write-Detail "[ ok ]     WSL                          $($wsl.Status)$(if ($wsl.Version) { " $($wsl.Version)" })$(if ($wsl.DefaultVersion) { ", default version $($wsl.DefaultVersion)" })"

    # --- Record what was selected ----------------------------------------
    $facts = [ordered]@{}
    if ($result.Caveats.Count -gt 0) { $facts['caveatsAcknowledged'] = $result.Caveats }
    $facts['dockerBackend'] = $engine.Backend
    $result.PendingFacts = $facts
    $result.StateWrite = Save-DeltaRuntimeFacts -InstallRoot $InstallRoot -Facts $facts

    if ($result.StateWrite.Persisted) {
        Write-Detail "Recorded backend and caveat acknowledgements in $($result.StateWrite.Path)"
    }
    else {
        Write-Detail "Backend and caveat acknowledgements not written yet: $($result.StateWrite.Reason)"
    }

    $result.Outcome = 'ready'
    $result.Reason = "Docker engine $($engine.ServerVersion) is reachable in Linux-container mode with Compose v$($compose.Version)."
    return $result
}
