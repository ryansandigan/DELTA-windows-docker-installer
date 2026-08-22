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

# A size floor for a downloaded installer, not a pin. Docker Desktop's
# installer is around 600 MB; Docker publishes no per-build checksum at a
# stable URL for the "latest" link, so an exact hash cannot be verified without
# breaking on every Docker release. What this catches is the failure that
# actually happens on a fresh machine: a captive portal, a proxy error page or
# a truncated transfer saved under the .exe name. Those are kilobytes. The real
# authenticity check is the Authenticode signature below - this only rejects
# what is obviously not an installer before bothering to check its signature.
$Script:DeltaDockerInstallerMinimumBytes = 100MB

# The publisher the downloaded installer must be signed by.
#
# Matched against the certificate's organisation (O=, falling back to CN=) and
# anchored at the start, NOT searched for anywhere in the subject. A substring
# search over the whole distinguished name accepts "CN=Definitely Not Docker
# Ltd" - a validly signed binary from someone who merely put the word in their
# company name - which is precisely the attack a signature check exists to
# stop.
#
# Anchored but not pinned to the full DN: Docker has shipped under more than
# one exact subject, and pinning the whole string would turn a routine
# certificate renewal into a failed installation on every fresh machine.
$Script:DeltaDockerInstallerSignerPattern = '^Docker\b'

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
        [int]$TimeoutSeconds = 120,
        [AllowNull()][string]$StandardInput
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
    if ($PSBoundParameters.ContainsKey('StandardInput')) {
        # Used to feed SQL to `psql -f -`, which is how a script containing a
        # \getenv meta-command reaches psql without being written to a file
        # anywhere or passed as an argument.
        $startInfo.RedirectStandardInput = $true
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    # .NET Framework builds the child's stdin writer from Console.InputEncoding,
    # and on this host that is a UTF-8 encoder WITH a byte-order mark. There is
    # no ProcessStartInfo.StandardInputEncoding on .NET Framework - it is .NET
    # Core only - and StreamWriter emits its preamble the first time the stream
    # is touched, including when .BaseStream is merely read. So writing raw
    # bytes is not enough on its own: the mark is already in the pipe ahead of
    # them.
    #
    # Measured with a short ASCII payload written through this function: it
    # arrived three bytes longer than it was sent, ef bb bf first, and the
    # program on the far side read the mark as part of the value. The psql
    # callers above survive it only because a BOM ahead of a statement is
    # whitespace to the parser; any consumer that reads its first bytes
    # literally would not.
    #
    # Setting the console encoding to a preamble-free UTF-8 for the length of
    # this call is the only lever 5.1 offers. It is restored in the finally
    # block below, and a host that refuses the change (stdin already redirected,
    # no console) is not a failure - the explicit byte write below still fixes
    # the payload's own encoding.
    $previousInputEncoding = $null
    if ($PSBoundParameters.ContainsKey('StandardInput')) {
        try {
            $previousInputEncoding = [Console]::InputEncoding
            if ($previousInputEncoding.GetPreamble().Length -gt 0) {
                [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
            }
            else { $previousInputEncoding = $null }
        }
        catch { $previousInputEncoding = $null }
    }

    try {
        $null = $process.Start()
        $result.Started = $true
    }
    catch {
        $result.Error = $_.Exception.Message
        if ($previousInputEncoding) { try { [Console]::InputEncoding = $previousInputEncoding } catch { } }
        return $result
    }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if ($PSBoundParameters.ContainsKey('StandardInput')) {
            # Written after the readers are attached and closed immediately, so
            # the child sees EOF rather than waiting for more input.
            #
            # Straight to BaseStream as explicit UTF-8 bytes, so the payload's
            # encoding is decided here rather than by whatever the console
            # happens to be set to. Combined with the preamble-free console
            # encoding set above, the child receives exactly these bytes and
            # nothing else.
            if ($StandardInput) {
                $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($StandardInput)
                $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
                $process.StandardInput.BaseStream.Flush()
            }
            $process.StandardInput.Close()
        }

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $result.TimedOut = $true
            try { $process.Kill() } catch { }
        }

        $result.StdOut   = ($stdoutTask.Result).Trim()
        $result.StdErr   = ($stderrTask.Result).Trim()
        $result.ExitCode = if ($result.TimedOut) { -1 } else { $process.ExitCode }
    }
    finally {
        if ($previousInputEncoding) { try { [Console]::InputEncoding = $previousInputEncoding } catch { } }
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
        [int]$TimeoutSeconds = 120,
        [AllowNull()][string]$StandardInput
    )

    $docker = Get-Command -Name 'docker' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $docker) {
        return [PSCustomObject]@{
            FilePath = 'docker'; Arguments = $Arguments; ExitCode = -1
            StdOut = ''; StdErr = 'The docker CLI was not found on PATH.'
            TimedOut = $false; Started = $false; Error = 'not-found'
        }
    }

    if ($PSBoundParameters.ContainsKey('StandardInput')) {
        return (Invoke-DeltaProcessCapture -FilePath $docker.Source -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds -StandardInput $StandardInput)
    }
    return (Invoke-DeltaProcessCapture -FilePath $docker.Source -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds)
}

function Invoke-DeltaProcessBinaryStream {
    <#
      Runs a process whose stdout, stdin, or both carry BINARY data, and moves
      those bytes between the child and a Windows file without letting anything
      decode them.

      Invoke-DeltaProcessCapture is the right seam for everything else in this
      installer and the wrong one here: it reads stdout through .NET's
      StreamReader, which decodes bytes into a .NET string. That is lossless for
      text and destructive for a custom-format PostgreSQL dump - every byte that
      is not valid in the reader's encoding becomes U+FFFD, and .Trim() removes
      leading and trailing whitespace bytes that are dump content. So this
      function never touches StandardOutput.ReadToEnd(): it copies
      StandardOutput.BaseStream straight into a FileStream, which is the same
      byte-for-byte transport a shell redirect performs.

      The same applies in the other direction: StandardInput.BaseStream, fed
      from a FileStream, is how a dump file reaches `pg_restore` on stdin.

      Stderr is still read as text - it is a diagnostic message, not payload -
      and is read asynchronously, because a child that fills the 4 KB stderr
      pipe buffer while we are draining stdout is the classic redirect deadlock.

      Never throws for a non-zero exit; a failing command is data.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$OutputFile,
        [string]$InputFile,
        [int]$TimeoutSeconds = 1800
    )

    $result = [PSCustomObject]@{
        FilePath     = $FilePath
        Arguments    = $Arguments
        ExitCode     = -1
        StdOut       = ''
        StdErr       = ''
        BytesWritten = 0
        OutputFile   = $OutputFile
        TimedOut     = $false
        Started      = $false
        Error        = $null
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName               = $FilePath
    $startInfo.UseShellExecute        = $false
    $startInfo.CreateNoWindow         = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError  = $true
    $startInfo.Arguments              = ConvertTo-DeltaCommandLine -Arguments $Arguments
    if ($InputFile) { $startInfo.RedirectStandardInput = $true }

    $target = $null
    $source = $null
    try {
        if ($OutputFile) {
            # Opened before the child starts: if the destination cannot be
            # created there is no reason to run pg_dump at all, and no partial
            # file is produced.
            $target = New-Object System.IO.FileStream(
                $OutputFile,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
        }
        if ($InputFile) {
            $source = New-Object System.IO.FileStream(
                $InputFile,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read)
        }
    }
    catch {
        $result.Error = $_.Exception.Message
        if ($target) { $target.Dispose() }
        if ($source) { $source.Dispose() }
        return $result
    }

    # .NET Framework builds the StandardInput StreamWriter with
    # Console.InputEncoding and AutoFlush = true during Process.Start(), and
    # that first flush writes the encoding's preamble into the pipe before this
    # function has written a single byte. On a UTF-8 console that puts EF BB BF
    # in front of the payload: measured, a 332,405-byte dump reached the
    # container as 332,408 bytes and pg_restore rejected it as "not a valid
    # archive". Handing the process a preamble-free encoding of the SAME code
    # page is what makes stdin byte-exact; the console's code page is not
    # changed, only .NET's cached Encoding object for it, and it is put back
    # as soon as the child has started.
    $restoreInputEncoding = $null
    if ($InputFile) {
        try {
            $consoleEncoding = [Console]::InputEncoding
            if ($consoleEncoding -and $consoleEncoding.GetPreamble().Length -gt 0) {
                if ($consoleEncoding.CodePage -eq 65001) {
                    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
                    $restoreInputEncoding = $consoleEncoding
                }
                else {
                    # Fail closed rather than send bytes that are known to be
                    # wrong: a corrupted stream must never become a "verified"
                    # answer.
                    $result.Error = "This console's input encoding (code page $($consoleEncoding.CodePage)) prepends a byte-order mark to child stdin, which would corrupt the stream."
                    if ($target) { $target.Dispose() }
                    if ($source) { $source.Dispose() }
                    return $result
                }
            }
        }
        catch {
            $result.Error = "The console input encoding could not be made byte-exact for stdin: $($_.Exception.Message)"
            if ($target) { $target.Dispose() }
            if ($source) { $source.Dispose() }
            return $result
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        try {
            $null = $process.Start()
            $result.Started = $true
        }
        catch {
            $result.Error = $_.Exception.Message
            return $result
        }
        finally {
            if ($restoreInputEncoding) {
                try { [Console]::InputEncoding = $restoreInputEncoding } catch { }
            }
        }

        $stderrTask = $process.StandardError.ReadToEndAsync()

        $copyTask   = $null
        $stdoutTask = $null
        if ($target) {
            $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($target, 81920)
        }
        else {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        }

        if ($source) {
            # Written after the readers are attached, and the pipe closed
            # immediately afterwards so the child sees EOF instead of waiting
            # for more.
            #
            # The BaseStream is closed, NOT the StandardInput StreamWriter that
            # wraps it. Closing the writer flushes it, and flushing a
            # never-written UTF-8 StreamWriter emits its 3-byte preamble - which
            # lands after the payload and corrupts it. Measured: a 332,405-byte
            # dump arrived inside the container as 332,408 bytes and pg_restore
            # rejected it as "not a valid archive". Nothing else about the
            # transport was wrong, which is exactly why it is worth a comment.
            $stdin = $process.StandardInput.BaseStream
            $source.CopyTo($stdin, 81920)
            $stdin.Flush()
            $stdin.Close()
        }

        $timeoutMs = $TimeoutSeconds * 1000
        $timedOut = $false
        if ($copyTask -and -not $copyTask.Wait($timeoutMs)) { $timedOut = $true }
        if (-not $timedOut -and -not $process.WaitForExit($timeoutMs)) { $timedOut = $true }
        if ($timedOut) {
            try { $process.Kill() } catch { }
            # Killing the child closes the pipes, which lets the outstanding
            # reads finish so the streams can be disposed cleanly.
            if ($copyTask) { try { $null = $copyTask.Wait(5000) } catch { } }
            try { $null = $process.WaitForExit(5000) } catch { }
        }
        $result.TimedOut = $timedOut

        if ($target) {
            $target.Flush()
            $result.BytesWritten = $target.Length
        }
        if ($stdoutTask) {
            try { if ($stdoutTask.Wait(15000)) { $result.StdOut = ([string]$stdoutTask.Result).Trim() } } catch { }
        }
        try { if ($stderrTask.Wait(15000)) { $result.StdErr = ([string]$stderrTask.Result).Trim() } } catch { }

        if (-not $timedOut) {
            try { $result.ExitCode = $process.ExitCode } catch { $result.ExitCode = -1 }
        }
    }
    finally {
        if ($target) { $target.Dispose() }
        if ($source) { $source.Dispose() }
        # Guarded: disposing the Process disposes the StandardInput writer over
        # a pipe this function has already closed, which raises from Dispose.
        try { $process.Dispose() } catch { }
    }

    Write-DeltaLogLine -Message ("run: {0} {1} -> exit {2}{3}{4}" -f
        $FilePath,
        ($Arguments -join ' '),
        $result.ExitCode,
        $(if ($result.TimedOut) { ' (timed out)' } else { '' }),
        $(if ($OutputFile) { "; $($result.BytesWritten) bytes written" } else { '' })) -Level 'DETAIL'
    if ($result.StdErr) {
        Write-DeltaLogLine -Message ("     stderr: " + $result.StdErr) -Level 'DETAIL'
    }
    return $result
}

function Invoke-DeltaDockerBinaryStream {
    <#
      Invoke-DeltaDockerCommand's byte-exact counterpart: the docker CLI, with
      stdout and/or stdin bound to a file rather than to a decoded string.
      Resolved through Get-Command on every call, for the same reason.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$OutputFile,
        [string]$InputFile,
        [int]$TimeoutSeconds = 1800
    )

    $docker = Get-Command -Name 'docker' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $docker) {
        return [PSCustomObject]@{
            FilePath = 'docker'; Arguments = $Arguments; ExitCode = -1
            StdOut = ''; StdErr = 'The docker CLI was not found on PATH.'
            BytesWritten = 0; OutputFile = $OutputFile
            TimedOut = $false; Started = $false; Error = 'not-found'
        }
    }

    $splat = @{
        FilePath       = $docker.Source
        Arguments      = $Arguments
        TimeoutSeconds = $TimeoutSeconds
    }
    if ($OutputFile) { $splat['OutputFile'] = $OutputFile }
    if ($InputFile)  { $splat['InputFile']  = $InputFile }
    return (Invoke-DeltaProcessBinaryStream @splat)
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

# The Hyper-V Integration Services key. Its presence is the definitive marker
# that this Windows is a Hyper-V GUEST rather than a Hyper-V host, and it
# carries the guest's own VM name and its host's name - which is exactly what
# the operator needs to run Set-VMProcessor in the right place.
$Script:DeltaHyperVGuestKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'

# Manufacturer/model strings that identify a virtual machine. Matched against
# Win32_ComputerSystem, most specific first. 'unknown-vm' is a real answer:
# a platform not on this list still gets generic guidance rather than a
# confident claim about a hypervisor nobody identified.
$Script:DeltaVirtualPlatformSignatures = [ordered]@{
    'hyper-v'    = 'Microsoft Corporation.*Virtual Machine|Virtual Machine'
    'vmware'     = 'VMware'
    'virtualbox' = 'VirtualBox|innotek'
    'kvm'        = 'KVM|QEMU|Red Hat'
    'xen'        = 'Xen'
    'ec2'        = 'Amazon EC2'
    'gce'        = 'Google Compute Engine|Google'
    'parallels'  = 'Parallels'
}

function Get-DeltaVirtualPlatformInfo {
    <#
      Whether this Windows is running on physical hardware or inside a virtual
      machine, and on what.

      This distinction is the whole fix. `HypervisorPresent = True` means only
      "a hypervisor is running somewhere below this OS" and answers two
      completely different questions the same way:

        - a physical host with Hyper-V or VBS enabled, where Windows is the
          root partition. Virtualization genuinely works, and Win32_Processor
          reports its firmware flags as False because the hypervisor owns them.
          This is the case the old check was written against.
        - a guest VM. The hypervisor being reported is the HOST's, and it says
          nothing whatsoever about whether this guest has been given the
          virtualization extensions WSL2 needs.

      Treating the second as proof is what produced a green
      "[ ok ] Hardware virtualization" inside a Hyper-V guest that Docker then
      refused with "Virtualization support not detected".
    #>
    param(
        [object]$ComputerSystem,
        # Injectable so the classification can be exercised without a machine
        # that happens to be the platform under test.
        [string]$GuestKeyPath = $Script:DeltaHyperVGuestKey
    )

    if (-not $ComputerSystem) {
        $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    }

    $result = [PSCustomObject]@{
        IsVirtualMachine = $false
        Platform         = 'physical'
        Manufacturer     = [string]$ComputerSystem.Manufacturer
        Model            = [string]$ComputerSystem.Model
        VmName           = $null
        HostName         = $null
    }

    # The Hyper-V guest key is checked first and is definitive - a Hyper-V host
    # does not have it, a Hyper-V guest does.
    if ($GuestKeyPath -and (Test-Path -LiteralPath $GuestKeyPath)) {
        $result.IsVirtualMachine = $true
        $result.Platform = 'hyper-v'
        try {
            $parameters = Get-ItemProperty -LiteralPath $GuestKeyPath -ErrorAction Stop
            if ($parameters.PSObject.Properties.Name -contains 'VirtualMachineName') { $result.VmName = [string]$parameters.VirtualMachineName }
            if ($parameters.PSObject.Properties.Name -contains 'HostName') { $result.HostName = [string]$parameters.HostName }
        }
        catch { }
        if (-not $result.VmName) { $result.VmName = $env:COMPUTERNAME }
        return $result
    }

    $identity = "$($result.Manufacturer) $($result.Model)"
    foreach ($platform in $Script:DeltaVirtualPlatformSignatures.Keys) {
        if ($identity -match $Script:DeltaVirtualPlatformSignatures[$platform]) {
            $result.IsVirtualMachine = $true
            $result.Platform = $platform
            $result.VmName = $env:COMPUTERNAME
            return $result
        }
    }

    return $result
}

function Get-DeltaProcessorVirtualizationFlags {
    <#
      What the CPU reports about virtualization.

      VMMonitorModeExtensions is the one that matters inside a guest: it is
      VT-x/AMD-V being visible to THIS operating system, which is precisely
      what a hypervisor either does or does not expose to a nested guest. A
      Hyper-V guest without -ExposeVirtualizationExtensions reports it False;
      with it, True.

      On a root partition all of these read False regardless, because the
      running hypervisor owns the feature - which is why they are never read
      on their own, only alongside Get-DeltaVirtualPlatformInfo.
    #>
    param([object]$Processor)

    if (-not $Processor) {
        $Processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    return [PSCustomObject]@{
        Readable                  = [bool]$Processor
        VirtualizationFirmwareEnabled = [bool]$Processor.VirtualizationFirmwareEnabled
        VMMonitorModeExtensions       = [bool]$Processor.VMMonitorModeExtensions
        SecondLevelAddressTranslation = [bool]$Processor.SecondLevelAddressTranslationExtensions
    }
}

function Get-DeltaVirtualizationFeatureState {
    <#
      The two things about virtualization that CAN be fixed from inside this
      machine: the Virtual Machine Platform optional feature that WSL2 runs on,
      and the boot setting that decides whether the hypervisor starts at all.

      Both are read defensively. A host where DISM or bcdedit cannot be
      queried yields 'unknown' rather than a guess, and 'unknown' is never
      treated as a fault to be repaired.
    #>

    $result = [PSCustomObject]@{
        VirtualMachinePlatform = 'unknown'
        HypervisorLaunchType   = 'unknown'
    }

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -ErrorAction Stop
        if ($feature) { $result.VirtualMachinePlatform = [string]$feature.State }
    }
    catch { }

    try {
        $bcdedit = Get-Command -Name 'bcdedit.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $capture = Invoke-DeltaProcessCapture -FilePath $bcdedit.Source -Arguments @('/enum', '{current}') -TimeoutSeconds 30
        if ($capture.ExitCode -eq 0) {
            $match = [regex]::Match([string]$capture.StdOut, '(?im)^\s*hypervisorlaunchtype\s+(\S+)\s*$')
            if ($match.Success) { $result.HypervisorLaunchType = $match.Groups[1].Value }
        }
    }
    catch { }

    return $result
}

function Get-DeltaVirtualizationCapability {
    <#
      Whether WSL2 and Docker Desktop can actually use hardware virtualization
      on this host, and if not, whether anything can be done about it here.

      Verdict is one of:

        available    positive evidence the capability exists
        remediable   something this installer can turn on, then restart
        unavailable  the capability is absent and cannot be fixed from inside
                     this machine

      The rule the old check broke: a hypervisor being present is evidence only
      when this OS is the one running it. In a guest it is evidence of nothing,
      and the verdict must come from whether the CPU's virtualization
      extensions are visible to this guest.
    #>
    param(
        [object]$Platform,
        [object]$Flags,
        [object]$Features,
        [Nullable[bool]]$HypervisorPresent,
        # Injectable so the guest paths can be exercised without a hypervisor,
        # and so the runtime is probed at most once per run.
        [object]$Runtime
    )

    if (-not $Platform)  { $Platform = Get-DeltaVirtualPlatformInfo }
    if (-not $Flags)     { $Flags = Get-DeltaProcessorVirtualizationFlags }
    if (-not $Features)  { $Features = Get-DeltaVirtualizationFeatureState }
    if ($null -eq $HypervisorPresent) {
        $HypervisorPresent = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).HypervisorPresent
    }

    $result = [PSCustomObject]@{
        Verdict           = 'unavailable'
        Evidence          = $null
        Reason            = $null
        Remedy            = $null
        Platform          = $Platform
        Flags             = $Flags
        Features          = $Features
        HypervisorPresent = [bool]$HypervisorPresent
        RepairActions     = @()
        Runtime           = $null
    }

    $evidence = "HypervisorPresent=$($result.HypervisorPresent); " +
                "host=$(if ($Platform.IsVirtualMachine) { "virtual machine ($($Platform.Platform))" } else { 'physical' }); " +
                "VMMonitorModeExtensions=$($Flags.VMMonitorModeExtensions); " +
                "VirtualizationFirmwareEnabled=$($Flags.VirtualizationFirmwareEnabled); " +
                "SLAT=$($Flags.SecondLevelAddressTranslation); " +
                "VirtualMachinePlatform=$($Features.VirtualMachinePlatform); " +
                "hypervisorlaunchtype=$($Features.HypervisorLaunchType)"
    $result.Evidence = $evidence

    # Locally fixable gaps, collected first because they apply to physical
    # hosts and guests alike and are worth repairing before despairing.
    $repairs = New-Object System.Collections.ArrayList
    if ($Features.VirtualMachinePlatform -eq 'Disabled') { $null = $repairs.Add('virtual-machine-platform') }
    if ($Features.HypervisorLaunchType -eq 'Off')        { $null = $repairs.Add('hypervisor-launch-type') }
    $result.RepairActions = $repairs.ToArray()

    if (-not $Platform.IsVirtualMachine) {
        # --- physical hardware -------------------------------------------
        # A hypervisor running here IS this OS's own (root partition), so it is
        # genuine evidence - the case the previous check was right about.
        if ($result.HypervisorPresent -or $Flags.VirtualizationFirmwareEnabled -or $Flags.VMMonitorModeExtensions) {
            if ($repairs.Count -gt 0) {
                $result.Verdict = 'remediable'
                $result.Reason = 'Hardware virtualization is available, but the Windows features WSL2 needs are not all turned on.'
                return $result
            }
            $result.Verdict = 'available'
            return $result
        }

        $result.Reason = 'Hardware virtualization is not enabled in this machine''s firmware. Docker Desktop cannot run Linux containers without it.'
        $result.Remedy = 'Restart the machine, enter the firmware setup (BIOS/UEFI) and enable virtualization - usually called Intel VT-x or AMD-V, sometimes with a separate SLAT/VT-d entry. Then run this installer again.'
        return $result
    }

    # --- virtual machine --------------------------------------------------
    # HypervisorPresent is not consulted here: it is true in every guest and
    # proves nothing about nested virtualization.
    #
    # The processor flags are ONE-WAY evidence, and this is the correction that
    # matters. True means the extensions are visible and nested virtualization
    # is genuinely there. False means nothing at all.
    #
    # Measured on a Windows Server 2022 Hyper-V guest whose host had
    # ExposeVirtualizationExtensions = $true: VMMonitorModeExtensions,
    # VirtualizationFirmwareEnabled and SecondLevelAddressTranslationExtensions
    # ALL report False inside that guest, and systeminfo declines to show the
    # Hyper-V requirements at all because a hypervisor is already present.
    # Nested virtualization was working. Reading those False values as a
    # refusal blocks a host that would have installed perfectly, which is the
    # same mistake as the original bug wearing the opposite sign.
    if ($Flags.VMMonitorModeExtensions -or $Flags.VirtualizationFirmwareEnabled) {
        if ($repairs.Count -gt 0) {
            $result.Verdict = 'remediable'
            $result.Reason = 'Nested virtualization is exposed to this VM, but the Windows features WSL2 needs are not all turned on.'
            return $result
        }
        $result.Verdict = 'available'
        return $result
    }

    # Inconclusive so far. Fix what is locally fixable first - those features
    # are needed either way, and the runtime probe below is only meaningful
    # once they are in place and the machine has come back.
    if ($repairs.Count -gt 0) {
        $result.Verdict = 'remediable'
        $result.Reason = 'The Windows features WSL2 needs are not all turned on. Whether this VM has nested virtualization cannot be established from inside it until they are.'
        return $result
    }

    # Features are in place, so ask the strongest thing that can actually
    # answer: does the WSL2 runtime start? Only a definite refusal from it
    # counts as evidence of absence.
    $runtime = if ($Runtime) { $Runtime } else { Test-DeltaWsl2RuntimeCapability }
    $result.Runtime = $runtime
    $result.Evidence = "$evidence; wsl2Runtime=$($runtime.Verdict)"

    if ($runtime.Verdict -eq 'available') {
        $result.Verdict = 'available'
        return $result
    }

    if ($runtime.Verdict -eq 'unavailable') {
        # Reliable evidence: the runtime itself refused, naming virtualization.
        $result.Verdict = 'unavailable'
        $result.Reason = "WSL2 cannot start on this VM because hardware virtualization is not available to it. $($runtime.Reason)"
        $result.Remedy = Get-DeltaNestedVirtualizationRemedy -Platform $Platform
        return $result
    }

    # Genuinely unknown, and unknown is never a stop. The guest-side flags
    # cannot see nested virtualization, WSL2 has not refused, and the only
    # thing that can settle it is Docker actually starting - so the install
    # continues and the operator is told, in advance, what the failure would
    # look like and what to do about it.
    $result.Verdict = 'unknown'
    $result.Reason = 'This is a virtual machine, and whether its hypervisor exposes hardware virtualization cannot be determined from inside it - a guest reports these processor flags as False either way. Installation continues.'
    $result.Remedy = @"
If Docker Desktop later reports "Virtualization support not detected", nested
virtualization is genuinely missing and this is the fix:

$(Get-DeltaNestedVirtualizationRemedy -Platform $Platform)
"@
    return $result
}

# Error signatures WSL2 produces when the platform it needs is not there.
# HCS_E_HYPERV_NOT_INSTALLED (0x80370102) is the specific one a guest without
# nested virtualization returns; 0x80370114 is its "required feature is not
# installed" sibling.
#
# The text signatures are deliberately narrow. A first attempt matched the bare
# phrase "not supported with your current machine configuration" and a lone
# "virtualization", and on a perfectly healthy host - Docker running, WSL2
# working - `wsl --status` prints:
#
#     Default Version: 2
#     WSL1 is not supported with your current machine configuration.
#
# That line is about WSL**1** being unavailable, which is normal and harmless.
# Matching it declared a working machine incapable, which on a guest would have
# been the exact false stop this whole correction exists to remove. WSL2 is
# named explicitly now, and a bare mention of virtualization is not enough.
$Script:DeltaWslVirtualizationErrorSignatures = @(
    '0x80370102'
    '0x80370114'
    'WSL2 is not supported with your current machine configuration'
    'enable the Virtual Machine Platform'
    'virtualization support'
    'Virtualization support not detected'
)

function Test-DeltaWsl2RuntimeCapability {
    <#
      Whether the WSL2 runtime can actually use virtualization on this host.

      This exists because the guest-side WMI flags cannot answer the question
      and a wrong answer in either direction is expensive. It is deliberately
      conservative in one direction only: it will say 'unavailable' just when
      WSL itself refuses AND names virtualization in the refusal, and 'unknown'
      for everything else - WSL not installed, WSL not yet version 2, a
      timeout, an error about something unrelated.

      'unknown' is the common answer before WSL is installed, and that is fine.
      It is a reason to continue and let Docker settle it, not a reason to stop:
      the whole point of the correction this function is part of is that an
      absence of evidence was being reported as evidence of absence.
    #>
    param([string]$WslPath)

    $result = [PSCustomObject]@{
        Verdict  = 'unknown'
        Reason   = $null
        Evidence = $null
        ExitCode = $null
    }

    if (-not $WslPath) {
        $command = Get-Command -Name 'wsl.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) {
            $result.Reason = 'wsl.exe is not present yet, so the WSL2 runtime could not be asked.'
            return $result
        }
        $WslPath = $command.Source
    }

    $previousUtf8 = $env:WSL_UTF8
    try {
        # Without this, wsl.exe emits UTF-16 that arrives as interleaved nulls
        # and no signature ever matches.
        $env:WSL_UTF8 = '1'
        $capture = Invoke-DeltaProcessCapture -FilePath $WslPath -Arguments @('--status') -TimeoutSeconds 60
    }
    catch {
        $result.Reason = "The WSL2 runtime could not be asked: $($_.Exception.Message)"
        return $result
    }
    finally {
        $env:WSL_UTF8 = $previousUtf8
    }

    $output = "$($capture.StdOut) $($capture.StdErr)".Trim()
    $result.ExitCode = $capture.ExitCode
    $result.Evidence = ($output -split "`r?`n" | Where-Object { $_ } | Select-Object -First 3) -join '; '

    # Success is checked BEFORE the signatures, and outranks them. wsl.exe
    # exiting 0 means WSL is working; anything it printed on the way is
    # commentary, not a refusal. Reading the text first is what let a note
    # about WSL1 condemn a healthy WSL2 host.
    if ($capture.ExitCode -eq 0) {
        # The strongest positive signal obtainable without a distribution to
        # boot - short of Docker itself, which comes later.
        $result.Verdict = 'available'
        $result.Reason = 'wsl.exe --status returned successfully and reported no virtualization problem.'
        return $result
    }

    foreach ($signature in $Script:DeltaWslVirtualizationErrorSignatures) {
        if ($output -match [regex]::Escape($signature)) {
            $result.Verdict = 'unavailable'
            $result.Reason = "wsl.exe reported: $($result.Evidence)"
            return $result
        }
    }

    $result.Reason = "wsl.exe --status exited with $($capture.ExitCode) for a reason unrelated to virtualization, so this proves nothing either way."
    return $result
}

function Get-DeltaNestedVirtualizationRemedy {
    <#
      What to do about a guest with no virtualization extensions, in the words
      of the platform that hosts it.

      Every branch is an instruction to be carried out somewhere else - on the
      hypervisor host, with the VM shut down. None of it can be done from in
      here, and this function exists so the installer says that plainly instead
      of offering a repair it cannot perform.
    #>
    param([Parameter(Mandatory)][object]$Platform)

    $name = if ($Platform.VmName) { $Platform.VmName } else { '<VM name>' }

    switch ($Platform.Platform) {
        'hyper-v' {
            $host_ = if ($Platform.HostName) { " ($($Platform.HostName))" } else { '' }
            return @"
Nested virtualization must be enabled on the Hyper-V host$host_, not here:
  1. Shut this VM down completely (a saved state or a restart is not enough).
  2. On the Hyper-V host, in an elevated PowerShell:
       Set-VMProcessor -VMName "$name" -ExposeVirtualizationExtensions `$true
  3. Start the VM again and run this installer.
"@
        }
        'vmware' {
            return @"
Nested virtualization must be enabled on the VMware host, not here:
  1. Shut this VM down completely.
  2. In the VM's settings, under Processors, tick
     "Virtualize Intel VT-x/EPT or AMD-V/RVI".
  3. Start the VM again and run this installer.
"@
        }
        'virtualbox' {
            return @"
Nested virtualization must be enabled on the VirtualBox host, not here:
  1. Shut this VM down completely.
  2. On the host:  VBoxManage modifyvm "$name" --nested-hw-virt on
  3. Start the VM again and run this installer.
"@
        }
        'kvm' {
            return @"
Nested virtualization must be enabled on the KVM/QEMU host, not here:
  1. Shut this VM down completely.
  2. On the host, load the kvm_intel/kvm_amd module with nested=1 and give the
     guest a CPU mode that passes the virtualization flags through
     (for example host-passthrough).
  3. Start the VM again and run this installer.
"@
        }
        default {
            return @"
This machine is a virtual machine and its hypervisor is not exposing hardware
virtualization to it. That cannot be changed from inside the guest:
  1. Shut this VM down completely.
  2. On the hypervisor that hosts it, enable nested virtualization - the
     setting is usually called nested virtualization, VT-x/AMD-V passthrough,
     or exposing virtualization extensions.
  3. Start the VM again and run this installer.
Cloud VMs often cannot do this at all; there, use an instance type that
supports nested virtualization, or a physical host.
"@
        }
    }
}

function Repair-DeltaVirtualizationPrerequisite {
    <#
      Turns on the virtualization features that CAN be turned on from here:
      the Virtual Machine Platform optional feature, and the boot setting that
      lets the hypervisor start.

      Deliberately narrow. It never touches firmware, never claims to fix
      nested virtualization, and is only ever called for a 'remediable'
      verdict - which by construction means the capability itself is already
      present and only Windows configuration is in the way.

      Both changes need a restart to take effect, so this reports
      RestartRequired and the caller routes into the existing reboot flow
      rather than pretending the host is ready.
    #>
    param([Parameter(Mandatory)][object]$Capability)

    $result = [PSCustomObject]@{
        Attempted       = @()
        Succeeded       = $true
        RestartRequired = $false
        Failures        = @()
    }

    $attempted = New-Object System.Collections.ArrayList
    $failures = New-Object System.Collections.ArrayList

    foreach ($action in $Capability.RepairActions) {
        switch ($action) {
            'virtual-machine-platform' {
                $null = $attempted.Add('VirtualMachinePlatform')
                Write-Detail 'Enabling the Virtual Machine Platform Windows feature...'
                try {
                    $null = Enable-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -All -NoRestart -ErrorAction Stop
                    # Always a restart, regardless of what RestartNeeded says:
                    # the hypervisor platform is not usable until the machine
                    # comes back, and claiming otherwise is how a host ends up
                    # being told it is ready when it is not.
                    $result.RestartRequired = $true
                    Write-Detail '[ ok ]     VirtualMachinePlatform enabled (a restart is needed for it to take effect).'
                }
                catch {
                    $null = $failures.Add("VirtualMachinePlatform: $($_.Exception.Message)")
                }
            }
            'hypervisor-launch-type' {
                $null = $attempted.Add('hypervisorlaunchtype')
                Write-Detail 'Setting the boot configuration to start the hypervisor (hypervisorlaunchtype Auto)...'
                try {
                    $bcdedit = Get-Command -Name 'bcdedit.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1
                    $capture = Invoke-DeltaProcessCapture -FilePath $bcdedit.Source -Arguments @('/set', 'hypervisorlaunchtype', 'Auto') -TimeoutSeconds 60
                    if ($capture.ExitCode -ne 0) {
                        $null = $failures.Add("bcdedit /set hypervisorlaunchtype Auto exited with $($capture.ExitCode): $($capture.StdErr)")
                    }
                    else {
                        $result.RestartRequired = $true
                        Write-Detail '[ ok ]     hypervisorlaunchtype set to Auto (a restart is needed for it to take effect).'
                    }
                }
                catch {
                    $null = $failures.Add("hypervisorlaunchtype: $($_.Exception.Message)")
                }
            }
        }
    }

    $result.Attempted = $attempted.ToArray()
    $result.Failures = $failures.ToArray()
    $result.Succeeded = ($failures.Count -eq 0)
    return $result
}

function Test-DeltaVirtualizationPrerequisite {
    <#
      Hardware virtualization (A§5.4 row 3).

      The verdict comes from Get-DeltaVirtualizationCapability, which requires
      positive evidence that WSL2 and Docker can actually use virtualization
      on this host. `HypervisorPresent = True` is not that evidence on its own:
      it is true in every guest VM, including one whose hypervisor exposes no
      virtualization extensions at all. This check used to accept it and
      reported a green tick on exactly such a host, which Docker then refused
      to start on with "Virtualization support not detected".

      A 'remediable' verdict is reported as a notice, not an ok: the caller
      repairs it, restarts, and the capability is measured again on the way
      back. Nothing here reports ok on the strength of a repair that has not
      yet taken effect.

      The capability object is returned on the check as Capability, so the
      caller can repair and re-measure without probing the host twice.
    #>
    param(
        [Parameter(Mandatory)][object]$WindowsInfo,
        [object]$Capability
    )

    if (-not $Capability) {
        $Capability = Get-DeltaVirtualizationCapability -HypervisorPresent ([bool]$WindowsInfo.HypervisorPresent)
    }

    $check = switch ($Capability.Verdict) {
        'available' {
            New-DeltaCheckResult -Name 'Hardware virtualization' -Severity 'ok' -Detail $Capability.Evidence
        }
        'remediable' {
            New-DeltaCheckResult -Name 'Hardware virtualization' -Severity 'notice' -Detail $Capability.Evidence `
                -Reason $Capability.Reason `
                -Remedy 'This installer can turn those features on and restart Windows.'
        }
        'unknown' {
            # A notice, never a stop. Inconclusive evidence is not failure, and
            # a guest that cannot see its own virtualization flags is the
            # ordinary case, not a broken one.
            New-DeltaCheckResult -Name 'Hardware virtualization' -Severity 'notice' -Detail $Capability.Evidence `
                -Reason $Capability.Reason -Remedy $Capability.Remedy
        }
        default {
            New-DeltaCheckResult -Name 'Hardware virtualization' -Severity 'blocked' -Detail $Capability.Evidence `
                -Reason $Capability.Reason -Remedy $Capability.Remedy
        }
    }

    Add-Member -InputObject $check -MemberType NoteProperty -Name 'Capability' -Value $Capability
    return $check
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

function Initialize-DeltaDockerPath {
    <#
      Makes sure `docker` is resolvable in this process, and says whether it
      had to do anything.

      Every Docker call in this installer goes through Get-Command, which reads
      PATH. An interactive session always has Docker's bin directory on it. A
      process launched by Task Scheduler may not: the environment it builds is
      not always the one an interactive sign-in produces, and a PATH that was
      extended after the machine last read it is a common way for a scheduled
      task to fail with "not found" on a machine where the command plainly
      exists.

      So: if `docker` already resolves, nothing happens. If it does not, the
      two directories Docker Desktop actually installs into - per machine and
      per user - are probed, and the first one that holds docker.exe is
      prepended to this process's PATH only. The operator's environment is
      never modified.
    #>
    param()

    $result = [PSCustomObject]@{ Resolved = $false; Path = $null; Repaired = $false }

    $docker = Get-Command -Name 'docker' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($docker) {
        $result.Resolved = $true
        $result.Path = $docker.Source
        return $result
    }

    $candidates = @(
        (Join-Path -Path "$env:ProgramFiles"   -ChildPath 'Docker\Docker\resources\bin')
        (Join-Path -Path "$env:LOCALAPPDATA"   -ChildPath 'Programs\DockerDesktop\resources\bin')
        (Join-Path -Path "$env:ProgramData"    -ChildPath 'DockerDesktop\version-bin')
    )

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $exe = Join-Path -Path $candidate -ChildPath 'docker.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            $env:PATH = "$candidate;$env:PATH"
            $result.Resolved = $true
            $result.Repaired = $true
            $result.Path = $exe
            return $result
        }
    }

    return $result
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

    $ownership = Test-DeltaInstallRootOwned -InstallRoot $InstallRoot
    if (-not $ownership.IsOwned) {
        $result.Reason = $ownership.Reason
        return $result
    }

    $existing = Read-DeltaInstallState -InstallRoot $InstallRoot
    $isOurs = ($existing.Exists -and $existing.IsValid)

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

function Get-DeltaCertificateSubjectPart {
    <#
      One RDN out of a certificate subject - 'O' or 'CN' - so a publisher check
      can test the organisation rather than searching the whole distinguished
      name for a word.

      Handles the quoted form a DN uses when a value itself contains a comma.
      Returns $null when the key is absent, which the caller must treat as "not
      established" rather than as a pass.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Subject,
        [Parameter(Mandatory)][string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Subject)) { return $null }

    $match = [regex]::Match($Subject, "(?:^|,)\s*$Key=(?:`"(?<quoted>[^`"]*)`"|(?<plain>[^,]*))",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }

    $value = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['plain'].Value }
    $value = $value.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Test-DeltaDockerInstallerFile {
    <#
      Whether a file this installer just downloaded is safe to execute.

      Three checks, cheapest first, each rejecting a different real failure:

        1. Size. An error page, a captive-portal redirect or a transfer that
           died half-way is kilobytes, not hundreds of megabytes.
        2. The MZ header. A proxy that returns HTML with a 200 produces a file
           that is the right size band only by accident, and is not a PE image.
        3. Authenticode. The one that actually answers "is this Docker's
           installer": a valid signature chaining to a trusted root, with
           Docker named in the signer's subject.

      Anything short of all three is a refusal to execute. A downloaded binary
      that cannot be shown to be the vendor's is not run on the operator's
      machine on the grounds that it is probably fine.

      This is applied to what the installer downloaded, and not to a path the
      operator supplied or staged in installers\ themselves. Those are the
      operator's own choice of binary, made deliberately - an air-gapped site
      that repackages the installer is not doing anything wrong, and refusing
      to run a file somebody explicitly pointed at would be this installer
      overruling them about their own machine. What arrives over the network
      unasked-for is the case that needs proving.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $result = [PSCustomObject]@{
        IsValid           = $false
        Reason            = $null
        SizeBytes         = 0
        SignatureStatus   = $null
        Signer            = $null
        SignerOrganisation = $null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Reason = "Nothing was written to '$Path'."
        return $result
    }

    $result.SizeBytes = (Get-Item -LiteralPath $Path).Length
    if ($result.SizeBytes -lt $Script:DeltaDockerInstallerMinimumBytes) {
        $megabytes = [math]::Round($result.SizeBytes / 1MB, 1)
        $result.Reason = "The download is only $megabytes MB, far below the roughly 600 MB Docker Desktop installer. That is a truncated transfer or an error page saved under the installer's name, not the installer."
        return $result
    }

    try {
        $header = New-Object byte[] 2
        $stream = [System.IO.File]::OpenRead($Path)
        try { $null = $stream.Read($header, 0, 2) } finally { $stream.Dispose() }
    }
    catch {
        $result.Reason = "The download could not be read back: $($_.Exception.Message)"
        return $result
    }

    if ($header[0] -ne 0x4D -or $header[1] -ne 0x5A) {
        $result.Reason = 'The download is not a Windows executable (no MZ header). Something between this machine and Docker returned other content.'
        return $result
    }

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        $result.Reason = "The download's Authenticode signature could not be read: $($_.Exception.Message)"
        return $result
    }

    $result.SignatureStatus = [string]$signature.Status
    if ($signature.SignerCertificate) { $result.Signer = [string]$signature.SignerCertificate.Subject }

    if ($result.SignatureStatus -ne 'Valid') {
        $result.Reason = "The download's Authenticode signature is '$($result.SignatureStatus)', not 'Valid'. It was not run."
        return $result
    }

    # The organisation, not the whole subject: see the note on
    # $Script:DeltaDockerInstallerSignerPattern. CN is the fallback only
    # because a certificate without an O= is unusual, not because either will
    # do - whichever is used still has to start with Docker.
    $organisation = Get-DeltaCertificateSubjectPart -Subject $result.Signer -Key 'O'
    if (-not $organisation) { $organisation = Get-DeltaCertificateSubjectPart -Subject $result.Signer -Key 'CN' }
    $result.SignerOrganisation = $organisation

    if (-not $organisation) {
        $result.Reason = "The download is validly signed, but no publisher could be read from the certificate subject '$($result.Signer)'. It was not run."
        return $result
    }

    if ($organisation -notmatch $Script:DeltaDockerInstallerSignerPattern) {
        $result.Reason = "The download is validly signed, but its publisher is '$organisation' rather than Docker. It was not run. Full subject: $($result.Signer)"
        return $result
    }

    $result.IsValid = $true
    return $result
}

function Show-DeltaDockerInstallerFallback {
    <#
      How to supply the installer by hand. Printed whenever acquisition failed,
      for any reason - a refused download, an unverifiable one, or a supplied
      path that is not there - because in every one of those cases staging the
      binary is what the operator does next.
    #>
    param([string]$SearchRoot)

    Write-Detail ''
    Write-Detail 'To supply the installer yourself instead:'
    Write-Detail "  1. Download it from $Script:DeltaDockerInstallerUrl"
    if ($SearchRoot) {
        Write-Detail "  2. Put it at $(Join-Path -Path $SearchRoot -ChildPath "installers\$Script:DeltaDockerInstallerName")"
    }
    else {
        Write-Detail "  2. Put it in the installers\ folder next to setup.ps1, named '$Script:DeltaDockerInstallerName'"
    }
    Write-Detail '  3. Run setup.ps1 again.'
    Write-Detail 'Or pass the path directly:  .\setup.ps1 -DockerInstallerPath "D:\path\to\Docker Desktop Installer.exe"'
}

function Resolve-DeltaDockerInstaller {
    <#
      Finds the Docker Desktop installer, in this order:

        1. -DockerInstallerPath, if the operator supplied one.
        2. installers\ beside setup.ps1, so an air-gapped site can stage the
           binary itself.
        3. Docker's documented download URL.

      Step 3 is automatic. It used to be opt-in behind -AllowDownload, which
      meant the ordinary fresh machine - no Docker, nothing staged, nobody
      having read a switch list first - stopped at "No Docker Desktop installer
      was found" with a download link it was perfectly capable of fetching
      itself. Downloading is the documented way to obtain Docker Desktop, and
      by the time this runs the operator has already accepted Docker's
      licensing disclosure, which is the consent that matters.

      $AllowDownload remains so a caller can still forbid the network hop and
      get an immediate, clear refusal rather than a slow one; it defaults to
      allowing it.

      Nothing downloaded is executed before Test-DeltaDockerInstallerFile has
      passed it, and a download that fails or cannot be verified leaves no file
      behind to be mistaken for a good one later.
    #>
    param(
        [string]$InstallerPath,
        [string]$SearchRoot,
        [bool]$AllowDownload = $true
    )

    $result = [PSCustomObject]@{ Path = $null; Source = $null; Error = $null; Verification = $null }

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
        $result.Error = "No Docker Desktop installer was found, and downloading it was not permitted for this run. Place '$Script:DeltaDockerInstallerName' in the installers\ folder next to setup.ps1, or pass -DockerInstallerPath."
        return $result
    }

    $destination = Join-Path -Path $env:TEMP -ChildPath $Script:DeltaDockerInstallerName
    Write-Step 'Downloading Docker Desktop'
    Write-Detail "From: $Script:DeltaDockerInstallerUrl"
    Write-Detail "To:   $destination"
    Write-Detail 'This is roughly 600 MB and can take several minutes.'

    # A file left over from an earlier failed attempt must not be able to
    # masquerade as this one's result if the transfer dies early.
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    }

    $previousProgress = $ProgressPreference
    $downloaded = $false
    try {
        # Invoke-WebRequest's progress bar makes a large download several
        # times slower in PowerShell 5.1; suppressing it is a throughput fix,
        # not cosmetics.
        $ProgressPreference = 'SilentlyContinue'

        # Windows PowerShell 5.1 inherits .NET's default protocol selection,
        # which on an unpatched Windows image can still offer TLS 1.0/1.1.
        # desktop.docker.com refuses those, and the resulting error names a
        # connection failure rather than the protocol - a confusing way for a
        # fresh machine to fail. Enabling TLS 1.2 for this process removes it.
        try {
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
        catch { }

        Invoke-WebRequest -Uri $Script:DeltaDockerInstallerUrl -OutFile $destination -UseBasicParsing -ErrorAction Stop
        $downloaded = $true
    }
    catch {
        $result.Error = "Downloading Docker Desktop failed: $($_.Exception.Message)"
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    if (-not $downloaded) {
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        }
        return $result
    }

    Write-Step 'Verifying the downloaded installer'
    $verification = Test-DeltaDockerInstallerFile -Path $destination
    $result.Verification = $verification

    if (-not $verification.IsValid) {
        $result.Error = "The downloaded Docker Desktop installer could not be verified, so it was not run. $($verification.Reason)"
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        Write-Detail 'The unverified download has been deleted.'
        return $result
    }

    Write-Detail "[ ok ]     $([math]::Round($verification.SizeBytes / 1MB, 1)) MB, Authenticode $($verification.SignatureStatus)"
    Write-Detail "[ ok ]     signed by $($verification.Signer)"

    $result.Path = $destination
    $result.Source = 'downloaded'
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
        # Downloading Docker Desktop when nothing is staged is the default, not
        # an opt-in - see Resolve-DeltaDockerInstaller. This stays so a caller
        # can still forbid the network hop.
        [bool]$AllowDownload = $true
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

    $windowsCheck = Test-DeltaWindowsPrerequisite -WindowsInfo $windows
    $virtualization = Test-DeltaVirtualizationPrerequisite -WindowsInfo $windows

    # Everything this installer can fix about virtualization is fixed here,
    # before Docker is downloaded or installed - a host that cannot virtualise
    # must not be handed 600 MB and a silent install first, which is what the
    # reported failure did.
    if ($virtualization.Severity -eq 'notice' -and $virtualization.Capability -and
        $virtualization.Capability.Verdict -eq 'remediable') {

        Show-DeltaCheckResult -Check $virtualization
        Write-Step 'Enabling the Windows features WSL2 needs'
        Write-Detail $virtualization.Capability.Reason

        $repair = Repair-DeltaVirtualizationPrerequisite -Capability $virtualization.Capability

        if (-not $repair.Succeeded) {
            foreach ($failure in $repair.Failures) { Write-DeltaWarning $failure }
        }

        if ($repair.RestartRequired) {
            # Not "ok" - the features are set but not in effect, and the only
            # honest thing to report is that a restart is owed. The capability
            # is measured again on the next run, before anything else.
            $result.Outcome = 'reboot-required'
            $result.Reason = "$($repair.Attempted -join ' and ') enabled for WSL2. Windows must restart before the change takes effect."
            $result.Checks = @($windowsCheck, $virtualization)
            return $result
        }

        # Nothing was actually changed, so re-measure rather than assume.
        Write-Detail 'Re-checking hardware virtualization...'
        $virtualization = Test-DeltaVirtualizationPrerequisite -WindowsInfo $windows
    }

    $checks = @(
        $windowsCheck
        $virtualization
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

        $installer = Resolve-DeltaDockerInstaller -InstallerPath $DockerInstallerPath -SearchRoot $ScriptRoot -AllowDownload $AllowDownload
        if (-not $installer.Path) {
            Write-DeltaFailure ''
            Write-DeltaFailure 'Docker Desktop could not be installed.'
            Write-Detail $installer.Error
            Show-DeltaDockerInstallerFallback -SearchRoot $ScriptRoot
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

# ===========================================================================
# Unattended startup and reboot recovery (A§16, decision gate U1)
#
# The rule this whole section exists to obey: never print a recovery claim
# that has not been measured (A§16.3 Layer 4). Everything below either reads
# what the host actually has, or configures one specific mechanism and records
# which one - and the claim that DELTA returns after a restart is only ever
# made once a real unattended reboot has demonstrated it.
#
# Layer 1  configure every vendor mechanism that applies to this host
# Layer 2  measure whether anything on this host can start the Docker engine
#          before an interactive sign-in
# Layer 3  a scheduled task at Windows startup, ONLY where Layer 2 says the
#          vendor mechanisms cannot
# Layer 4  record what was configured, and report it truthfully
#
# What this section is explicitly not: a service, a service wrapper, a
# supervisor, or anything that watches containers. The task it may register
# runs one script once at boot and exits.
# ===========================================================================

# Docker Desktop's per-user settings file. AutoStart is the vendor's own
# "start Docker Desktop when you sign in" setting; there is no CLI for it, so
# the file is the only way to set it.
$Script:DeltaDockerSettingsRelativePath = 'Docker\settings-store.json'

# The Windows service Docker Desktop's installer registers when it is asked
# to. Its absence is a fact the assessment measured on this host and Phase 6
# has to re-measure rather than assume (A§16.1).
$Script:DeltaDockerServiceName = 'com.docker.service'

# Relative to the installer directory: the operational scripts live in bin\,
# beside neither setup.ps1 nor the libraries. Registered scheduled tasks store
# the resolved absolute path, so a task registered before the move is treated
# as stale and re-pointed by Invoke-DeltaStartupConfiguration below.
$Script:DeltaStartupScriptName = 'bin\start-delta.ps1'

# The trigger fires at boot, and then waits. The delay is not a guess about
# how long Docker takes - start-delta.ps1 waits for the engine itself - it is
# to keep the task out of the way of the storm of service starts that a
# Windows boot already is.
$Script:DeltaStartupTaskDelay = 'PT60S'

# A bound on the whole recovery, so a task that is stuck cannot sit in the
# scheduler forever. Generous: a cold start pulls nothing but does initialise
# containers and wait on three health gates.
#
# A TimeSpan, not the ISO 8601 duration the task XML stores: the trigger's
# Delay property is a raw CIM string and takes "PT60S", while
# New-ScheduledTaskSettingsSet -ExecutionTimeLimit is a typed parameter and
# refuses one. The two look interchangeable and are not.
$Script:DeltaStartupTaskTimeLimit = [System.TimeSpan]::FromMinutes(30)

function Get-DeltaDockerSettingsPath {
    <#
      Docker Desktop's settings-store.json for the user this installer is
      running as. Docker Desktop is installed per user on this class of host,
      so "the settings" means "this user's settings" - there is no
      machine-wide equivalent to read instead.
    #>
    param([string]$AppDataPath = $env:APPDATA)

    if (-not $AppDataPath) { return $null }
    return (Join-Path -Path $AppDataPath -ChildPath $Script:DeltaDockerSettingsRelativePath)
}

function Get-DeltaDockerAutoStartState {
    <#
      Reads Docker Desktop's AutoStart setting. Returns Supported (is there a
      settings file at all), Enabled, and the raw parsed document so a writer
      can put back everything it does not own.
    #>
    param([string]$SettingsPath)

    if (-not $PSBoundParameters.ContainsKey('SettingsPath')) {
        $SettingsPath = Get-DeltaDockerSettingsPath
    }

    $result = [PSCustomObject]@{
        Path      = $SettingsPath
        Supported = $false
        Enabled   = $null
        Settings  = $null
        Error     = $null
    }

    if (-not $SettingsPath -or -not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        $result.Error = 'Docker Desktop has no settings file for this user yet.'
        return $result
    }

    try {
        $raw = [System.IO.File]::ReadAllText($SettingsPath)
        $settings = $raw | ConvertFrom-Json
    }
    catch {
        $result.Error = "'$SettingsPath' could not be read as JSON: $($_.Exception.Message)"
        return $result
    }

    $result.Supported = $true
    $result.Settings = $settings
    if (@($settings.PSObject.Properties.Name) -contains 'AutoStart') {
        $result.Enabled = [bool]$settings.AutoStart
    }
    else {
        $result.Enabled = $false
    }
    return $result
}

function Set-DeltaDockerAutoStart {
    <#
      Turns Docker Desktop's AutoStart on or off by rewriting exactly that one
      key and leaving every other setting in the file untouched.

      Two honest limits, both reported rather than papered over:

        - Docker Desktop rewrites this file itself, and a running instance can
          overwrite the change when it exits. The result is re-read after
          writing, and what is returned is what the file says afterwards - not
          what was asked for.
        - AutoStart fires at interactive sign-in. It is a vendor mechanism
          worth configuring, and it is not on its own an answer to an
          unattended reboot. Nothing here pretends otherwise.
    #>
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [string]$SettingsPath
    )

    if (-not $PSBoundParameters.ContainsKey('SettingsPath')) {
        $SettingsPath = Get-DeltaDockerSettingsPath
    }

    $state = Get-DeltaDockerAutoStartState -SettingsPath $SettingsPath
    $result = [PSCustomObject]@{
        Path      = $SettingsPath
        Supported = $state.Supported
        Changed   = $false
        Enabled   = $state.Enabled
        Reason    = $state.Error
    }

    if (-not $state.Supported) { return $result }
    if ($state.Enabled -eq $Enabled) {
        $result.Reason = "AutoStart is already $(if ($Enabled) { 'enabled' } else { 'disabled' })."
        return $result
    }

    try {
        $settings = $state.Settings
        if (@($settings.PSObject.Properties.Name) -contains 'AutoStart') {
            $settings.AutoStart = $Enabled
        }
        else {
            Add-Member -InputObject $settings -MemberType NoteProperty -Name 'AutoStart' -Value $Enabled
        }
        # Not Write-DeltaFileAtomic: this is a vendor file, and replacing it by
        # rename would drop whatever ACL or ownership Docker Desktop put on it.
        [System.IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json -Depth 12), $Script:DeltaUtf8NoBom)
    }
    catch {
        $result.Reason = "Docker Desktop's settings file could not be written: $($_.Exception.Message)"
        return $result
    }

    $after = Get-DeltaDockerAutoStartState -SettingsPath $SettingsPath
    $result.Enabled = $after.Enabled
    $result.Changed = ($after.Enabled -eq $Enabled)
    $result.Reason = if ($result.Changed) {
        "AutoStart set to $Enabled."
    }
    else {
        "AutoStart was written as $Enabled but the file now reads $($after.Enabled). Docker Desktop may have rewritten it."
    }
    return $result
}

function Get-DeltaDockerServiceState {
    <#
      Whether com.docker.service exists on this host and how it starts.

      A§16.1 measured its complete absence on the assessment host, where
      Docker Desktop is installed per user. That is a property of how Docker
      was installed, not of Windows, so it is measured again here rather than
      assumed either way.
    #>
    param([string]$ServiceName = $Script:DeltaDockerServiceName)

    $result = [PSCustomObject]@{
        Name      = $ServiceName
        Exists    = $false
        Status    = $null
        StartType = $null
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) { return $result }

    $result.Exists = $true
    $result.Status = [string]$service.Status
    try {
        $result.StartType = [string](Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop).StartMode
    }
    catch {
        $result.StartType = [string]$service.StartType
    }
    return $result
}

# ---------------------------------------------------------------------------
# The startup task (Layer 3)
# ---------------------------------------------------------------------------

function Get-DeltaStartupTaskName {
    param([Parameter(Mandatory)][string]$ProjectName)
    return "DELTA (Docker) - $ProjectName - Startup"
}

function Get-DeltaStartupTaskState {
    <#
      The registered startup task for this installation, if there is one,
      described in the terms that matter: what it runs, as whom, and whether
      its trigger is one that fires without anybody signing in.
    #>
    param([Parameter(Mandatory)][string]$ProjectName)

    $result = [PSCustomObject]@{
        Name        = (Get-DeltaStartupTaskName -ProjectName $ProjectName)
        Exists      = $false
        Enabled     = $false
        UserId      = $null
        LogonType   = $null
        RunLevel    = $null
        AtStartup   = $false
        Execute     = $null
        Arguments   = $null
        LastRunTime = $null
        LastResult  = $null
        Task        = $null
    }

    # -TaskName is a wildcard filter, so the literal name is bracket-escaped -
    # the same trap the firewall rules hit in Phase 5, where "[project]" was
    # read as a character class.
    $escaped = [System.Management.Automation.WildcardPattern]::Escape($result.Name)
    $task = Get-ScheduledTask -TaskName $escaped -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $task) { return $result }

    $result.Exists = $true
    $result.Task = $task
    $result.Enabled = ($task.Settings.Enabled -ne $false)
    $result.UserId = $task.Principal.UserId
    $result.LogonType = [string]$task.Principal.LogonType
    $result.RunLevel = [string]$task.Principal.RunLevel
    $result.AtStartup = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }).Count -gt 0

    $action = @($task.Actions) | Select-Object -First 1
    if ($action) {
        $result.Execute = [string]$action.Execute
        $result.Arguments = [string]$action.Arguments
    }

    $info = Get-ScheduledTaskInfo -TaskName $escaped -ErrorAction SilentlyContinue
    if ($info) {
        $result.LastRunTime = $info.LastRunTime
        $result.LastResult = $info.LastTaskResult
    }
    return $result
}

function Register-DeltaStartupTask {
    <#
      Registers the one scheduled task this product owns: at Windows startup,
      run start-delta.ps1 once, as the account that installed DELTA.

      Why that account and not SYSTEM, which is what A§16.3 sketched. Measured
      on this host: Docker Desktop's WSL distribution is registered under the
      installing user's HKCU, with its virtual disk under that user's profile
      (C:\Users\<user>\AppData\Local\Docker\wsl). SYSTEM has no such
      registration, so a Docker started as SYSTEM would provision a second,
      empty engine - and DELTA's data volume lives in the first one. The
      installation would come back up on an empty database, which is exactly
      the A§9.4 outcome the whole design exists to prevent. SYSTEM also has no
      docker CLI plugins, so it has neither `docker compose` nor
      `docker desktop`. Running as the installing user is what makes the task
      see the same engine, the same volumes and the same CLI as the installer.

      The logon type is S4U: the task runs whether or not that user is signed
      in, and no password is stored anywhere. This is not autologon - no
      interactive session is created and no credential is saved - and it is not
      a service: the task runs one script, once, and exits.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$UserId
    )

    $result = [PSCustomObject]@{
        Name      = (Get-DeltaStartupTaskName -ProjectName $ProjectName)
        Succeeded = $false
        Action    = 'none'
        UserId    = $UserId
        Reason    = $null
    }

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        $result.Reason = "The startup script was not found at '$ScriptPath'. The task was not registered, because a task that points at a missing script is worse than no task."
        return $result
    }

    if (-not $UserId) {
        $UserId = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).Name
        $result.UserId = $UserId
    }

    $arguments = ConvertTo-DeltaCommandLine -Arguments @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass'
        '-File', $ScriptPath
        '-InstallRoot', $InstallRoot
    )

    $existing = Get-DeltaStartupTaskState -ProjectName $ProjectName

    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = $Script:DeltaStartupTaskDelay
        $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType S4U -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit $Script:DeltaStartupTaskTimeLimit `
            -MultipleInstances IgnoreNew

        $null = Register-ScheduledTask -TaskName $result.Name -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings `
            -Description "Starts Docker and the DELTA Compose project '$ProjectName' after a Windows restart. Registered by the DELTA installer; it runs one script once at boot and exits." `
            -Force -ErrorAction Stop
    }
    catch {
        $result.Reason = "The startup task could not be registered: $($_.Exception.Message)"
        return $result
    }

    $after = Get-DeltaStartupTaskState -ProjectName $ProjectName
    if (-not $after.Exists) {
        $result.Reason = 'The startup task was registered without error but cannot be read back.'
        return $result
    }
    if (-not $after.AtStartup) {
        $result.Reason = 'The startup task exists but has no at-startup trigger, so it would not run after a restart.'
        return $result
    }

    $result.Succeeded = $true
    $result.Action = if ($existing.Exists) { 'replaced' } else { 'created' }
    $result.UserId = $after.UserId
    return $result
}

function Unregister-DeltaStartupTask {
    <#
      Removes this installation's startup task, and only that one - matched by
      the exact name built from its Compose project.
    #>
    param([Parameter(Mandatory)][string]$ProjectName)

    $name = Get-DeltaStartupTaskName -ProjectName $ProjectName
    $state = Get-DeltaStartupTaskState -ProjectName $ProjectName
    if (-not $state.Exists) {
        return [PSCustomObject]@{ Name = $name; Removed = $false; Reason = 'No such task.' }
    }

    try {
        Unregister-ScheduledTask -TaskName ([System.Management.Automation.WildcardPattern]::Escape($name)) -Confirm:$false -ErrorAction Stop
        return [PSCustomObject]@{ Name = $name; Removed = $true; Reason = $null }
    }
    catch {
        return [PSCustomObject]@{ Name = $name; Removed = $false; Reason = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# The measurement (Layer 2)
# ---------------------------------------------------------------------------

function Measure-DeltaUnattendedStartCapability {
    <#
      Enumerates every mechanism on this host that could start the Docker
      engine, and classifies each by *when* it fires. That distinction is the
      whole question: Windows runs services and at-startup scheduled tasks
      before anybody signs in, and runs HKCU Run entries, the Startup folder
      and Docker Desktop's own AutoStart only at interactive sign-in.

      Verdict:
        none      nothing on this host runs before an interactive sign-in, so
                  Docker cannot start unattended. Layer 1 is insufficient here
                  and Layer 3 is warranted.
        task      this installation's startup task is registered and would run
                  at boot.
        unproven  something else runs at boot, but whether it brings the Linux
                  engine up is not something this function can know - only a
                  real reboot can answer that.

      Nothing here claims that a mechanism works. It reports what exists and
      when it fires; the reboot test is what turns that into evidence.
    #>
    param([Parameter(Mandatory)][string]$ProjectName)

    $mechanisms = New-Object 'System.Collections.Generic.List[object]'
    $add = {
        param($Name, $When, $Present, $StartsEngine, $Detail)
        $null = $mechanisms.Add([PSCustomObject]@{
            Name = $Name; When = $When; Present = $Present; StartsEngine = $StartsEngine; Detail = $Detail
        })
    }

    $service = Get-DeltaDockerServiceState
    if ($service.Exists) {
        $automatic = ($service.StartType -match '(?i)^auto')
        & $add $Script:DeltaDockerServiceName $(if ($automatic) { 'boot' } else { 'manual' }) $true 'unknown' `
            "Windows service present, start type $($service.StartType), currently $($service.Status). Docker documents this service as the privileged helper that lets users switch engines without an elevation prompt; whether it also brings the Linux engine up at boot on this build is not something the installer can determine without a restart."
    }
    else {
        & $add $Script:DeltaDockerServiceName 'never' $false 'no' `
            'No such Windows service. Docker Desktop is installed per user on this host, so nothing Docker owns runs as a service at boot.'
    }

    $task = Get-DeltaStartupTaskState -ProjectName $ProjectName
    if ($task.Exists -and $task.AtStartup -and $task.Enabled) {
        & $add $task.Name 'boot' $true 'unknown' `
            "Scheduled task, at Windows startup, running as $($task.UserId) ($($task.LogonType)), whether or not that user is signed in."
    }

    $autoStart = Get-DeltaDockerAutoStartState
    & $add 'Docker Desktop AutoStart' 'sign-in' ([bool]$autoStart.Enabled) 'yes' $(
        if (-not $autoStart.Supported) { 'No Docker Desktop settings file for this user.' }
        elseif ($autoStart.Enabled) { 'Enabled. Docker Desktop starts when this user signs in to Windows.' }
        else { 'Disabled.' }
    )

    $runEntry = $null
    try {
        $run = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop
        $runEntry = @($run.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value -match '(?i)docker desktop' }) | Select-Object -First 1
    }
    catch { }
    & $add 'HKCU Run entry' 'sign-in' ([bool]$runEntry) 'yes' $(
        if ($runEntry) { "$($runEntry.Name) -> $($runEntry.Value). Fires at interactive sign-in only." }
        else { 'No Docker Desktop entry under HKCU Run.' }
    )

    $machineRun = $null
    try {
        $run = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop
        $machineRun = @($run.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value -match '(?i)docker' }) | Select-Object -First 1
    }
    catch { }
    if ($machineRun) {
        & $add 'HKLM Run entry' 'sign-in' $true 'yes' "$($machineRun.Name) -> $($machineRun.Value). Fires at the first interactive sign-in, not at boot."
    }

    $bootCapable = @($mechanisms | Where-Object { $_.When -eq 'boot' -and $_.Present -and $_.StartsEngine -ne 'no' })

    $verdict = 'none'
    if ($task.Exists -and $task.AtStartup -and $task.Enabled) { $verdict = 'task' }
    elseif ($bootCapable.Count -gt 0) { $verdict = 'unproven' }

    $reason = switch ($verdict) {
        'task'     { "This installation's startup task runs at Windows startup, before any sign-in." }
        'unproven' { "Something on this host runs at boot ($(($bootCapable | ForEach-Object { $_.Name }) -join ', ')), but whether it starts the Linux engine can only be established by a real restart." }
        default    { 'Nothing on this host starts Docker before an interactive sign-in: there is no Docker Windows service, and the only mechanisms present fire at sign-in.' }
    }

    return [PSCustomObject]@{
        Verdict     = $verdict
        Reason      = $reason
        Mechanisms  = $mechanisms.ToArray()
        Service     = $service
        Task        = $task
        AutoStart   = $autoStart
    }
}

# ---------------------------------------------------------------------------
# The stage (Layers 1 to 4)
# ---------------------------------------------------------------------------

function Invoke-DeltaStartupConfiguration {
    <#
      Configures unattended startup for this installation and records what was
      actually configured.

      Layer 1: every vendor mechanism that applies here. The Compose restart
      policy is verified rather than set - the templates own it, and a policy
      this stage "fixed" by editing the generated file would be lost on the
      next run. Docker Desktop's AutoStart is set. --always-run-service is an
      install-time flag of Docker Desktop's own installer, so on a host where
      Docker is already installed there is nothing to apply; that is reported,
      not silently skipped.

      Layer 2: measure. Layer 3: register the startup task only where the
      measurement says nothing runs before sign-in. Layer 4: write the facts
      into .delta-install.json, including - always - whether a real reboot has
      confirmed any of it.

      A failure here never fails the installation. DELTA is running; what is
      at stake is what happens after the next restart, and the honest response
      to being unable to configure that is to say so.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [object]$RestartPolicy
    )

    $result = [PSCustomObject]@{
        Succeeded    = $false
        Mechanism    = 'none'
        Reason       = $null
        RestartPolicy = $RestartPolicy
        AutoStart    = $null
        Service      = $null
        AlwaysRunService = $null
        Measurement  = $null
        Task         = $null
        BootTested   = $false
        BootTest     = $null
    }

    Show-Section -Title 'Unattended startup'

    # --- Layer 1 ----------------------------------------------------------
    Write-Step 'Configuring the vendor startup mechanisms'

    if ($RestartPolicy) {
        if ($RestartPolicy.Succeeded) {
            Write-Detail "[ ok ]     restart policy               all services: $($RestartPolicy.Policy)"
        }
        else {
            Write-DeltaWarning "The Compose restart policy is not what it should be: $($RestartPolicy.Reason)"
        }
    }

    $service = Get-DeltaDockerServiceState
    $result.Service = $service
    if ($service.Exists) {
        Write-Detail "[ ok ]     $($Script:DeltaDockerServiceName)           present, start type $($service.StartType), $($service.Status)"
        $result.AlwaysRunService = 'present'
    }
    else {
        Write-Detail "[note]     $($Script:DeltaDockerServiceName)           not installed on this host"
        # --always-run-service is an argument to "Docker Desktop Installer.exe
        # install". With Docker already installed there is nothing to pass it
        # to, and re-running a vendor product's installer to add a flag is not
        # something this phase does to a working machine.
        $result.AlwaysRunService = 'not-applicable'
        Write-Detail '           --always-run-service is an install-time flag of Docker Desktop Installer.exe, so it'
        Write-Detail '           does not apply to an installation that is already in place. Docker documents it as'
        Write-Detail '           the flag that keeps the privileged helper running so users are not prompted for'
        Write-Detail '           elevation when switching engines - not as a way to start the engine at boot.'
    }

    $autoStart = Set-DeltaDockerAutoStart -Enabled $true
    $result.AutoStart = $autoStart
    if ($autoStart.Supported -and $autoStart.Enabled) {
        Write-Detail "[ ok ]     Docker Desktop AutoStart     enabled ($($autoStart.Reason))"
    }
    elseif ($autoStart.Supported) {
        Write-DeltaWarning "Docker Desktop's AutoStart setting could not be enabled: $($autoStart.Reason)"
    }
    else {
        Write-Detail "[note]     Docker Desktop AutoStart     $($autoStart.Reason)"
    }

    # Measured on this host: Docker Desktop keeps its settings in memory while
    # it runs and writes them out when it exits, so a change made to the file
    # underneath a running Docker Desktop is silently reverted the next time it
    # shuts down. The setting is written anyway - it is correct on the next
    # cold start - but the operator is told, because a fact that quietly
    # reverses itself is exactly the kind of thing this phase must not report
    # as settled.
    if ($autoStart.Changed) {
        $desktop = Get-DeltaDockerDesktopStatus
        if ($desktop.Status -eq 'running') {
            Write-DeltaWarning 'Docker Desktop is running, and it rewrites this settings file when it exits, so it may revert AutoStart the next time it shuts down. Measured on this host. Nothing DELTA depends on is affected: the startup mechanism below does not rely on AutoStart.'
        }
    }
    Write-Detail '           AutoStart fires at interactive sign-in, so on its own it does not cover a restart'
    Write-Detail '           that nobody signs in after.'

    # --- Layer 2 ----------------------------------------------------------
    Write-Step 'Measuring what starts Docker at boot'

    $measurement = Measure-DeltaUnattendedStartCapability -ProjectName $ProjectName
    $result.Measurement = $measurement
    foreach ($mechanism in $measurement.Mechanisms) {
        $marker = if ($mechanism.Present) { '[found]  ' } else { '[absent] ' }
        Write-Detail ("{0} {1,-30} {2,-8} {3}" -f $marker, $mechanism.Name, $mechanism.When, $mechanism.Detail)
    }
    Write-Detail ''
    Write-Detail $measurement.Reason

    # --- Layer 3 ----------------------------------------------------------
    $scriptPath = Join-Path -Path $ScriptRoot -ChildPath $Script:DeltaStartupScriptName

    # A task that already exists is not automatically a task that is still
    # right: the installer directory it points at can be moved or renamed, and
    # a startup task aimed at a script that is no longer there fails silently
    # at boot, which is the worst possible way for this to break. So an
    # existing task is reconciled against what it should be, the same way the
    # firewall rules are.
    $stale = $false
    if ($measurement.Verdict -eq 'task' -and $measurement.Task) {
        $arguments = [string]$measurement.Task.Arguments
        $stale = ($arguments -notlike "*$scriptPath*") -or ($arguments -notlike "*$InstallRoot*")
    }

    if ($measurement.Verdict -eq 'none' -or $stale) {
        Write-Step 'Registering the DELTA startup task'
        if ($stale) {
            Write-Detail 'The registered startup task no longer matches this installer or this installation'
            Write-Detail 'root, so it is being replaced. A task pointing at a script that has moved would'
            Write-Detail 'fail at boot with nobody there to see it.'
        }
        else {
            Write-Detail 'Because nothing on this host starts Docker before a sign-in, DELTA registers one'
            Write-Detail 'scheduled task that runs at Windows startup. It starts Docker, waits for the engine,'
            Write-Detail 'checks that the database volume is still there, and brings the stack up. It supervises'
            Write-Detail 'nothing and exits when it is done.'
        }

        $registration = Register-DeltaStartupTask -ProjectName $ProjectName -InstallRoot $InstallRoot -ScriptPath $scriptPath
        $result.Task = $registration

        if (-not $registration.Succeeded) {
            Write-DeltaWarning "The startup task could not be registered: $($registration.Reason)"
            Write-Detail 'DELTA is running and unaffected. After the next restart it will stay down until'
            Write-Detail 'somebody signs in to this machine and Docker Desktop starts.'
            $result.Mechanism = 'none'
            $result.Reason = $registration.Reason
        }
        else {
            Write-Detail "[ ok ]     task $($registration.Action): $($registration.Name)"
            Write-Detail "[ ok ]     runs as $($registration.UserId), at Windows startup, whether or not that user is signed in"
            Write-Detail "[ ok ]     runs $scriptPath -InstallRoot $InstallRoot"
            $result.Mechanism = 'startup-task'
            $result.Succeeded = $true
        }
    }
    else {
        $result.Mechanism = if ($measurement.Verdict -eq 'task') { 'startup-task' } else { 'vendor' }
        $result.Succeeded = $true
        $result.Task = $measurement.Task
    }

    # --- Layer 4 ----------------------------------------------------------
    # Whatever a previous run measured about a real reboot is preserved: this
    # stage configures a mechanism, it never observes a restart, so it is in no
    # position to claim or to clear that evidence.
    $existing = Read-DeltaInstallState -InstallRoot $InstallRoot
    $previousBootTest = $null
    if ($existing.Exists -and $existing.IsValid -and (@($existing.Data.PSObject.Properties.Name) -contains 'unattendedStartup')) {
        $previous = $existing.Data.unattendedStartup
        if (@($previous.PSObject.Properties.Name) -contains 'bootTest') { $previousBootTest = $previous.bootTest }
    }
    $result.BootTest = $previousBootTest
    $result.BootTested = [bool]($previousBootTest -and $previousBootTest.result -eq 'reachable')

    $facts = [ordered]@{
        configured           = $result.Succeeded
        mechanism            = $result.Mechanism
        configuredAt         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        composeRestartPolicy = $(if ($RestartPolicy -and $RestartPolicy.Succeeded) { $RestartPolicy.Policy } else { 'unverified' })
        dockerDesktopAutoStart = [bool]$autoStart.Enabled
        dockerService        = $(if ($service.Exists) { "$($service.StartType)" } else { 'absent' })
        alwaysRunService     = $result.AlwaysRunService
        taskName             = $(if ($result.Task -and $result.Task.Name) { $result.Task.Name } else { $null })
        taskUserId           = $(if ($result.Task -and $result.Task.UserId) { $result.Task.UserId } else { $null })
        startupScript        = $(if ($result.Mechanism -eq 'startup-task') { (Join-Path -Path $ScriptRoot -ChildPath $Script:DeltaStartupScriptName) } else { $null })
        rebootTested         = $result.BootTested
        bootTest             = $previousBootTest
    }
    $null = Write-DeltaInstallState -InstallRoot $InstallRoot -Properties @{ unattendedStartup = [PSCustomObject]$facts }

    Write-Detail ''
    if ($result.BootTested) {
        Write-Success "Unattended startup: $($result.Mechanism), confirmed by a real restart on $($previousBootTest.at)."
    }
    elseif ($result.Succeeded) {
        Write-Success "Unattended startup: $($result.Mechanism) configured - NOT yet confirmed by a real restart."
    }
    else {
        Write-DeltaWarning 'Unattended startup is not configured on this host.'
    }

    return $result
}

function Write-DeltaRebootTestResult {
    <#
      Records the outcome of a real unattended restart in the state file. The
      only thing that may ever set rebootTested to true.

      It is deliberately a separate function from the one that configures the
      mechanism: configuring something and observing that it worked are
      different claims, made at different times, on different evidence.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][ValidateSet('reachable', 'unreachable')][string]$Result,
        [string]$Detail,
        [string]$Mechanism,
        [datetime]$At = (Get-Date)
    )

    $state = Read-DeltaInstallState -InstallRoot $InstallRoot
    $startup = $null
    if ($state.Exists -and $state.IsValid -and (@($state.Data.PSObject.Properties.Name) -contains 'unattendedStartup')) {
        $startup = $state.Data.unattendedStartup
    }
    if (-not $startup) {
        $startup = [PSCustomObject]@{ configured = $false; mechanism = 'none' }
    }

    $bootTest = [PSCustomObject]@{
        at        = $At.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        result    = $Result
        mechanism = $(if ($Mechanism) { $Mechanism } else { [string]$startup.mechanism })
        detail    = $Detail
    }

    $properties = [ordered]@{}
    foreach ($property in $startup.PSObject.Properties) {
        if ($property.Name -in @('bootTest', 'rebootTested')) { continue }
        $properties[$property.Name] = $property.Value
    }
    $properties['rebootTested'] = ($Result -eq 'reachable')
    $properties['bootTest'] = $bootTest

    return (Write-DeltaInstallState -InstallRoot $InstallRoot -Properties @{ unattendedStartup = [PSCustomObject]$properties })
}
