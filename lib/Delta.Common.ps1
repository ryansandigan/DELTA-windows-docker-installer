# =============================================================================
# Delta.Common.ps1 - console output, redacting log, elevation, validation
#
# Dot-sourced by setup.ps1 (and by any tools\ script that needs the same
# primitives). Defines no top-level side effects other than its own script
# variables, so it is safe to load more than once.
#
# Assessment references: A§21 (logging), A§24 (secret redaction), A§9.5
# (install-root constraints).
#
# This file - like every .ps1 in this project - is stored as UTF-8 *with* a
# BOM. Windows PowerShell 5.1 decodes a BOM-less script as the system ANSI
# code page, which turns any non-ASCII character in it into mojibake at run
# time. The BOM is what keeps the source and the console output identical.
# (.env and the state file are the opposite case: no BOM, ever - see
# Delta.Config.ps1.)
# =============================================================================

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$Script:DeltaBannerWidth = 72

# Exit codes. setup.ps1 owns exactly one top-level try/catch and is the only
# place that calls exit; functions raise terminating errors via Stop-Setup.
$Script:DeltaExitSuccess            = 0
$Script:DeltaExitFailure            = 1
$Script:DeltaExitNotElevated        = 2
$Script:DeltaExitInvalidInstallRoot = 3
# Phase 2 outcomes. A blocked prerequisite and a required-but-declined
# disclosure are distinct from a crash, and "restart Windows and run this
# again" is not a failure at all - it is the documented next step, so it gets
# its own code rather than being flattened into 1.
$Script:DeltaExitPrerequisiteFailed = 4
$Script:DeltaExitRebootRequired     = 5
$Script:DeltaExitOperatorDeclined   = 6
# Phase 3 outcomes. Migration verification gets its own code because it is the
# highest-consequence stop in the product: it means the schema may be
# half-migrated, and the response is a restore, not a retry.
$Script:DeltaExitStackFailed        = 7
$Script:DeltaExitMigrationFailed    = 8
# The install stopped before publishing DELTA because the seeded administrator
# credential could not be replaced. Distinct from a generic stack failure: the
# stack is fine, the security bootstrap is not, and nothing is externally
# reachable.
$Script:DeltaExitSecurityBootstrapFailed = 9

# UTF-8 *without* a byte-order mark. Every file this installer writes that is
# later read by a Linux container (.env above all) must not carry a BOM -
# Compose passes the first key through with the BOM glued to its name.
$Script:DeltaUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------------------
# Secret redaction (A§24)
#
# Redaction is a property of the logger, not of the call sites: every console
# helper below routes its message through Protect-DeltaSecretText on the way
# to the log file. A call site cannot forget to redact, because a call site
# never redacts.
#
# The console is deliberately NOT redacted - the completion summary has to be
# able to show a generated credential to the operator exactly once (A§24) -
# so the split is: full text to the screen, redacted text to disk.
# ---------------------------------------------------------------------------

$Script:DeltaRedactionMarker = '<redacted>'

# DATABASE_URL is on this list because it embeds the database password and is
# the one that gets forgotten (A§24). DELTA_DB_PASSWORD is on it because
# A§7.4 defines it as a separate key from day one.
$Script:DeltaSecretKeyNames = @(
    'POSTGRES_PASSWORD'
    'DELTA_DB_PASSWORD'
    'SESSION_SECRET'
    'SMTP_PASS'
    'DATABASE_URL'
    'DELTA_ADMIN_NEW_PASSWORD'
    'PGPASSWORD'
)

# KEY=value, KEY: value, or KEY value - with or without quotes, and with the
# separator optional so that a bare mention of the key name is caught too. The
# whole match is replaced, key name included, for two reasons: a log line that
# still named the key would defeat the "no secret key names in a transcript"
# check the acceptance gate greps for, and a .env line malformed enough to
# lose its '=' (which the installer echoes back so the operator can fix it)
# still carries a real secret on the right-hand side.
$Script:DeltaSecretAssignmentPattern =
    '(?i)\b(' +
    (($Script:DeltaSecretKeyNames | ForEach-Object { [regex]::Escape($_) }) -join '|') +
    ')\b(\s*[:=]\s*|\s+)?("[^"]*"|''[^'']*''|\S*)'

# Any PostgreSQL connection URI, however it reached the text - a psql error,
# a compose warning, an operator-pasted value. It always carries credentials.
$Script:DeltaConnectionStringPattern = '(?i)\bpostgres(?:ql)?://\S*'

# Literal secret values registered at generation time, masked wherever they
# subsequently appear. This is what catches a secret that arrives inside
# output this installer did not format itself.
$Script:DeltaRegisteredSecrets = New-Object System.Collections.Generic.List[string]

function Register-DeltaSecretValue {
    <#
      Records a literal value that must never reach a transcript. Call this
      immediately after generating or reading a secret, before it is used
      anywhere else.

      Values shorter than 8 characters are ignored: masking a short literal
      would corrupt unrelated text (a 4-character value would blank out every
      accidental occurrence of those characters in every log line), and a
      secret this installer generates is never that short.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if (-not $Value -or $Value.Length -lt 8) {
        return
    }
    if (-not $Script:DeltaRegisteredSecrets.Contains($Value)) {
        $null = $Script:DeltaRegisteredSecrets.Add($Value)
    }
}

function Protect-DeltaSecretText {
    <#
      Returns $Text with every known secret shape replaced by the redaction
      marker: secret KEY=value assignments, PostgreSQL connection URIs, and
      any literal registered through Register-DeltaSecretValue.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $result = [regex]::Replace($Text, $Script:DeltaSecretAssignmentPattern, $Script:DeltaRedactionMarker)
    $result = [regex]::Replace($result, $Script:DeltaConnectionStringPattern, $Script:DeltaRedactionMarker)

    foreach ($secret in $Script:DeltaRegisteredSecrets) {
        $result = $result.Replace($secret, $Script:DeltaRedactionMarker)
    }

    return $result
}

# ---------------------------------------------------------------------------
# Transcript log
#
# Deliberately not Start-Transcript: a PowerShell transcript captures raw
# console output verbatim, which is precisely what A§24 forbids for the lines
# that carry credentials. An own-format log is the only way redaction can be
# a property of the writer.
# ---------------------------------------------------------------------------

$Script:DeltaLogPath = $null
$Script:DeltaLogWriteFailureReported = $false

# Bounds for the appended startup log only. The per-run transcripts are one
# file per run and are the operator's to keep or delete.
$Script:DeltaAppendLogMaxBytes  = 1MB
$Script:DeltaAppendLogKeepBytes = 256KB

function Limit-DeltaLogFile {
    <#
      Trims an appended log to its most recent lines once it passes the size
      cap. Best effort: a log that cannot be trimmed is left exactly as it is
      rather than being lost.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
        $file = Get-Item -LiteralPath $Path
        if ($file.Length -le $Script:DeltaAppendLogMaxBytes) { return }

        $lines = [System.IO.File]::ReadAllLines($Path)
        $kept = New-Object 'System.Collections.Generic.List[string]'
        $bytes = 0
        for ($i = $lines.Length - 1; $i -ge 0; $i--) {
            $bytes += $lines[$i].Length + 2
            if ($bytes -gt $Script:DeltaAppendLogKeepBytes) { break }
            $kept.Insert(0, $lines[$i])
        }
        $kept.Insert(0, "--- earlier entries trimmed on $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) ---")
        [System.IO.File]::WriteAllLines($Path, $kept.ToArray(), $Script:DeltaUtf8NoBom)
    }
    catch { }
}

function Start-DeltaLog {
    <#
      Opens the installer transcript in $Directory and returns its full path.
      The directory is created if it does not exist; a failure to create it
      is reported once and then downgraded to "no log this run" - an
      installation must not be blocked by a logging problem.

      -Append opens one fixed file, "<Name>.log", and adds to it instead of
      creating a new timestamped file per run. That is what the unattended
      startup path needs: after a reboot the operator has to be able to read
      one file and see the history of boots, not hunt through a directory of
      per-boot transcripts. Because that file is written by something nobody
      watches, it is trimmed to the most recent $Script:DeltaAppendLogKeepBytes
      when it grows past $Script:DeltaAppendLogMaxBytes - the alternative is a
      log that grows without limit on a machine that reboots for patching.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$Name = 'setup',
        [switch]$Append
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            $null = New-Item -ItemType Directory -Path $Directory -Force
        }
        if ($Append) {
            $Script:DeltaLogPath = Join-Path -Path $Directory -ChildPath "$Name.log"
            Limit-DeltaLogFile -Path $Script:DeltaLogPath
            if (-not (Test-Path -LiteralPath $Script:DeltaLogPath -PathType Leaf)) {
                [System.IO.File]::WriteAllText($Script:DeltaLogPath, '', $Script:DeltaUtf8NoBom)
            }
            [System.IO.File]::AppendAllText($Script:DeltaLogPath, [Environment]::NewLine, $Script:DeltaUtf8NoBom)
        }
        else {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $Script:DeltaLogPath = Join-Path -Path $Directory -ChildPath "$Name-$stamp.log"
            [System.IO.File]::WriteAllText($Script:DeltaLogPath, '', $Script:DeltaUtf8NoBom)
        }
    }
    catch {
        $Script:DeltaLogPath = $null
        Write-Host "    Warning: could not open a log file in ${Directory}: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }

    Write-DeltaLogLine -Message "DELTA Windows Docker Installer - transcript started" -Level 'INFO'
    Write-DeltaLogLine -Message "PowerShell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.VersionString)" -Level 'INFO'
    Write-DeltaLogLine -Message "User $([Environment]::UserDomainName)\$([Environment]::UserName), elevated=$(Test-IsAdministrator)" -Level 'INFO'
    return $Script:DeltaLogPath
}

function Write-DeltaLogLine {
    <#
      Appends one redacted, timestamped line to the transcript. A no-op when
      no log is open. Never throws - a logging failure is reported once and
      then tolerated.
    #>
    param(
        [AllowEmptyString()][string]$Message,
        [string]$Level = 'INFO'
    )

    if (-not $Script:DeltaLogPath) {
        return
    }

    $safe = Protect-DeltaSecretText -Text $Message
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = '{0} [{1}] {2}{3}' -f $timestamp, $Level.PadRight(7), $safe, [Environment]::NewLine

    try {
        [System.IO.File]::AppendAllText($Script:DeltaLogPath, $line, $Script:DeltaUtf8NoBom)
    }
    catch {
        if (-not $Script:DeltaLogWriteFailureReported) {
            $Script:DeltaLogWriteFailureReported = $true
            Write-Host "    Warning: writing to the transcript failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Stop-DeltaLog {
    <#
      Writes the closing line and releases the log path. Reports where the
      transcript was written so the operator can find it.
    #>
    param([int]$ExitCode = 0)

    # The backstop for the activity indicator. Every wrapped operation already
    # stops its own in a finally block; this is what catches an activity that
    # was started with Start-DeltaActivity directly and then abandoned, so a
    # run can never end with a worker still drawing dots over the exit banner.
    Stop-DeltaActivity

    if (-not $Script:DeltaLogPath) {
        return
    }
    Write-DeltaLogLine -Message "Transcript finished, exit code $ExitCode" -Level 'INFO'
    $Script:DeltaLogPath = $null
}

function Get-DeltaLogPath {
    return $Script:DeltaLogPath
}

# ---------------------------------------------------------------------------
# Activity indicator
#
# One animated line for any operation that has been STARTED and is being
# WAITED ON. It carries no knowledge of what is being waited for: the caller
# supplies a message and a scriptblock, and everything below - the animation,
# the same-line rendering, the cursor, the cleanup on success and on failure,
# and the decision about whether to animate at all - belongs to this section.
# Nothing else in this installer implements an animation loop.
#
# Three properties are worth stating because they are what make it safe to
# wrap an arbitrary operation:
#
#   It is an ACTIVITY indicator, not a progress bar. Three frames, no
#   percentage, no estimated completion. This installer cannot know how far
#   through a 600 MB download or a Docker Desktop install it is, and inventing
#   a number would be inventing a fact.
#
#   The frames never reach the transcript. Start-DeltaActivity writes ONE
#   line to the log - "<message>..." - and the animation after that is
#   presentation only, emitted through a TextWriter that the log has no
#   connection to. A transcript therefore reads the same whether the run was
#   animated or not.
#
#   The animated line is ERASED when the activity ends, not terminated with a
#   newline. What is left on screen after a wrapped operation is exactly what
#   was there before this section existed, which is why wrapping an operation
#   changes no output an operator or a test reads.
#
# The animation runs on its own runspace because the operation being decorated
# is a blocking call - a child process, a WaitForExit, an Invoke-WebRequest -
# and the main thread is inside it. That means two threads can reach the
# console, so every write goes through $state.Sync, and the main thread's own
# writes (Write-Detail and its siblings below, and every prompt) suspend or
# stop the animation first rather than racing it.
# ---------------------------------------------------------------------------

$Script:DeltaActivityFrames     = @('.', '..', '...')
$Script:DeltaActivityIntervalMs = 400
$Script:DeltaActivityIndent     = '    '

# 'auto' decides per activity from the console; 'off' never animates and
# prints the static line instead. setup.ps1 turns it off for -NonInteractive,
# and the test suites turn it off to assert that a redirected run stays clean.
$Script:DeltaActivityMode = 'auto'

# The one activity that can be running, or $null. Nesting is not supported and
# is not silently tolerated either: Start-DeltaActivity stops whatever was
# running first, so two animations can never share a line.
$Script:DeltaActivity = $null

# Runs in its own runspace, with $state supplied by Start-DeltaActivity. It
# knows nothing about this installer - none of the functions in this file
# exist in that runspace - so $state and the TextWriter on it are the whole of
# its world.
$Script:DeltaActivityWorker = {
    # Frame 0 was already drawn synchronously by Start-DeltaActivity, so this
    # picks up at frame 1 rather than repeating it.
    $index = 1
    while (-not $state.Stop.WaitOne(0)) {
        [System.Threading.Monitor]::Enter($state.Sync)
        try {
            if (-not $state.Paused) {
                $frame = $state.Frames[$index % $state.Frames.Count]
                # Padded to the widest frame rather than erased first: the line
                # is rewritten in one write, so there is no instant at which a
                # blanked line is on screen.
                $state.Writer.Write("`r" + ($state.Indent + $state.Message + $frame).PadRight($state.Width))
                $state.Writer.Flush()
                $state.Drawn = $state.Width
                $index++
            }
        }
        catch {
            # A console that cannot be written to ends the ANIMATION. It never
            # ends the operation the animation was decorating.
            $state.Failed = $true
            break
        }
        finally {
            [System.Threading.Monitor]::Exit($state.Sync)
        }

        # Waiting on the stop event rather than sleeping is what makes
        # Stop-DeltaActivity return immediately instead of up to one frame
        # later.
        if ($state.Stop.WaitOne($state.IntervalMs)) { break }
    }
}

function Set-DeltaActivityMode {
    <#
      'auto' (the default) or 'off'. 'off' is not a cosmetic preference: it is
      how a caller that knows more than the console probe does - an unattended
      run, a test - says that same-line updates are not wanted here.
    #>
    param([Parameter(Mandatory)][ValidateSet('auto', 'off')][string]$Mode)

    if ($Mode -eq 'off') { Stop-DeltaActivity }
    $Script:DeltaActivityMode = $Mode
}

function Get-DeltaActivityMode {
    return $Script:DeltaActivityMode
}

function Test-DeltaActivityRunning {
    <#
      Whether an animation is live right now. Exists so that the "no animation
      is ever running while a prompt is on screen" rule can be asserted rather
      than assumed.
    #>
    return ($null -ne $Script:DeltaActivity)
}

function Test-DeltaActivitySupported {
    <#
      Whether same-line animation is appropriate on this console for a line
      $Width characters wide. Answers only the question; starts nothing.

      Every branch here fails CLOSED - a host this cannot positively identify
      as an interactive console gets static output, because the cost of
      guessing wrong is a log file full of carriage returns.
    #>
    param([Parameter(Mandatory)][int]$Width)

    if ($Script:DeltaActivityMode -eq 'off') { return $false }

    try {
        # Redirected output is a file or a pipe. A carriage return is not a
        # cursor movement there, it is a byte, and every frame would become
        # another line of the operator's log.
        if ([Console]::IsOutputRedirected) { return $false }

        # A service, a scheduled task, a session with no window station.
        if (-not [Environment]::UserInteractive) { return $false }

        # ConsoleHost is the only host whose [Console] writes land in the same
        # place as its Write-Host writes. In the ISE, and in an editor-hosted
        # PowerShell, they are two different sinks - animating one while the
        # installer writes to the other is worse than not animating at all.
        if ($Host.Name -ne 'ConsoleHost') { return $false }

        # A line as wide as the window wraps, and a carriage return then
        # returns to the start of the wrapped remainder rather than to the
        # start of the line - which is how an animation ends up smeared across
        # two rows.
        if ([Console]::BufferWidth -le $Width) { return $false }
    }
    catch {
        return $false
    }

    return $true
}

function Clear-DeltaActivityLine {
    <#
      Blanks whatever the animation last drew and leaves the cursor at the
      start of that line, so the next write starts from column 0 on a line
      with nothing on it. Callers hold $State.Sync.
    #>
    param([Parameter(Mandatory)][object]$State)

    if ($State.Drawn -le 0) { return }
    try {
        $State.Writer.Write("`r" + (' ' * $State.Drawn) + "`r")
        $State.Writer.Flush()
    }
    catch { }
    $State.Drawn = 0
}

function Start-DeltaActivity {
    <#
      Begins animating "<message>." / ".." / "..." on one line, and returns
      immediately. The caller is then responsible for Stop-DeltaActivity -
      which is why almost every caller should use Invoke-DeltaActivity below
      instead, and let a finally block own that.

      Exactly one line reaches the transcript, here, whether or not anything
      is animated. Everything after it is presentation.

      -Writer is the test seam. Supplying one both redirects the animation
      away from the console and asserts that same-line updates are safe on it,
      so the console capability probe is skipped - but 'off' still wins, because
      'off' is a statement about what the caller wants, not about the terminal.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [System.IO.TextWriter]$Writer
    )

    # Never two at once. A second animation on the same line would corrupt
    # both, and an abandoned first one would never be stopped.
    Stop-DeltaActivity

    $line = $Script:DeltaActivityIndent + $Message
    $longest = 0
    foreach ($frame in $Script:DeltaActivityFrames) {
        if ($frame.Length -gt $longest) { $longest = $frame.Length }
    }
    $width = $line.Length + $longest

    Write-DeltaLogLine -Message "$Message..." -Level 'DETAIL'

    $animate = if ($PSBoundParameters.ContainsKey('Writer')) {
        ($Script:DeltaActivityMode -ne 'off')
    }
    else {
        Test-DeltaActivitySupported -Width $width
    }

    if (-not $animate) {
        # The documented fallback: the same sentence, once, with no control
        # characters in it at all.
        Write-Host "$line..."
        return
    }

    $state = [PSCustomObject]@{
        Message    = $Message
        Indent     = $Script:DeltaActivityIndent
        Frames     = $Script:DeltaActivityFrames
        IntervalMs = $Script:DeltaActivityIntervalMs
        Width      = $width
        Drawn      = 0
        Paused     = $false
        Failed     = $false
        Sync       = (New-Object object)
        Stop       = (New-Object System.Threading.ManualResetEvent($false))
        Writer     = $(if ($PSBoundParameters.ContainsKey('Writer')) { $Writer } else { [Console]::Out })
        Runspace   = $null
        Shell      = $null
        Handle     = $null
    }

    $runspace = $null
    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('state', $state)

        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        $null = $shell.AddScript($Script:DeltaActivityWorker.ToString())

        $state.Runspace = $runspace
        $state.Shell    = $shell
        $state.Handle   = $shell.BeginInvoke()
    }
    catch {
        # An animation that could not be started is not a failure of the
        # operation it was decorating. Say the same thing statically and carry
        # on, exactly as an unsupported console does.
        if ($runspace) { try { $runspace.Dispose() } catch { } }
        try { $state.Stop.Close() } catch { }
        Write-Host "$line..."
        return
    }

    $Script:DeltaActivity = $state

    # The first frame is drawn here, synchronously, rather than being left to
    # the worker's first pass. Opening a runspace takes long enough to be a
    # visible gap between an operation starting and anything appearing, and
    # drawing it here makes "an activity is running" and "something is on
    # screen" the same fact from the moment this function returns - which is
    # what lets Stop-DeltaActivity always have a line to erase.
    [System.Threading.Monitor]::Enter($state.Sync)
    try {
        try {
            $state.Writer.Write("`r" + ($state.Indent + $state.Message + $state.Frames[0]).PadRight($state.Width))
            $state.Writer.Flush()
            $state.Drawn = $state.Width
        }
        catch { }
    }
    finally {
        [System.Threading.Monitor]::Exit($state.Sync)
    }
}

function Suspend-DeltaActivity {
    <#
      Erases the animated line and holds the animation until
      Resume-DeltaActivity, so the caller can write to the console without the
      worker drawing into the middle of it. A no-op when nothing is animating,
      which is the usual case for the output helpers that call it.
    #>
    $state = $Script:DeltaActivity
    if (-not $state) { return }

    [System.Threading.Monitor]::Enter($state.Sync)
    try {
        $state.Paused = $true
        Clear-DeltaActivityLine -State $state
    }
    finally {
        [System.Threading.Monitor]::Exit($state.Sync)
    }
}

function Resume-DeltaActivity {
    <#
      Lets the animation draw again. The worker redraws the whole line from
      column 0 on its next frame, so nothing has to be restored here.
    #>
    $state = $Script:DeltaActivity
    if (-not $state) { return }
    $state.Paused = $false
}

function Stop-DeltaActivity {
    <#
      Ends the animation and leaves the cursor on an empty line at column 0.
      Idempotent, and safe to call when nothing was ever started - which is
      what lets every caller put it in a finally block without first asking
      whether there is anything to stop.

      Order matters. The worker is signalled and joined BEFORE the line is
      erased, so there is no frame in flight that could redraw over the blank.
    #>
    $state = $Script:DeltaActivity
    if (-not $state) { return }

    # Released first, so that a failure anywhere below cannot leave a second
    # Stop looking at an activity this one already owns.
    $Script:DeltaActivity = $null

    try { $null = $state.Stop.Set() } catch { }

    if ($state.Handle) {
        # The worker waits on the stop event instead of sleeping, so this
        # normally returns at once. It is bounded anyway: a stuck animation
        # must never be able to hold up the installer.
        try { $null = $state.Handle.AsyncWaitHandle.WaitOne(2000) } catch { }
    }
    if ($state.Shell) {
        try { if ($state.Handle -and -not $state.Handle.IsCompleted) { $state.Shell.Stop() } } catch { }
        try { $state.Shell.Dispose() } catch { }
    }
    if ($state.Runspace) {
        try { $state.Runspace.Dispose() } catch { }
    }

    [System.Threading.Monitor]::Enter($state.Sync)
    try { Clear-DeltaActivityLine -State $state }
    finally { [System.Threading.Monitor]::Exit($state.Sync) }

    try { $state.Stop.Close() } catch { }
}

function Invoke-DeltaActivity {
    <#
      The one API a caller needs: run $ScriptBlock while "<message>..."
      animates, and guarantee the animation is gone by the time this returns,
      however it returns.

        $capture = Invoke-DeltaActivity -Message 'Installing Docker Desktop' -ScriptBlock {
            Invoke-DeltaProcessCapture -FilePath $installer -Arguments $arguments
        }

      The scriptblock's output is this function's output, unaltered and
      unbuffered - it is invoked with & so it can still read the locals of the
      scope it was written in, exactly like Read-DeltaYesNoConfirmation's body.
      An exception thrown inside it propagates untouched; this adds no catch,
      because swallowing an operation's error to keep an animation tidy would
      be the worst possible trade.

      Cleanup is a finally block, so it also runs when the operation returns
      early, when a called process fails, and when PowerShell unwinds the
      pipeline after Ctrl+C.

      What this deliberately does NOT do is print the caller's step heading or
      its result. Those already exist at the call sites, and an activity that
      restated them would change what a run looks like on screen for no reason.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [System.IO.TextWriter]$Writer
    )

    if ($PSBoundParameters.ContainsKey('Writer')) {
        Start-DeltaActivity -Message $Message -Writer $Writer
    }
    else {
        Start-DeltaActivity -Message $Message
    }

    try {
        & $ScriptBlock
    }
    finally {
        Stop-DeltaActivity
    }
}

# ---------------------------------------------------------------------------
# Console output vocabulary (reused from the reference installer, A§23)
#
# Every one of these suspends a running activity before it writes and lets it
# resume afterwards. That is what keeps the animation from interleaving with a
# log line, a warning, an error or a command's output: the animated line is
# always the last line on screen, and it is erased before anything else is
# written under it.
# ---------------------------------------------------------------------------

function Show-Section {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle
    )
    Suspend-DeltaActivity
    $rule = '=' * $Script:DeltaBannerWidth
    Write-Host ''
    Write-Host $rule
    Write-Host $Title
    if ($Subtitle) {
        Write-Host $Subtitle
    }
    Write-Host $rule
    Write-Host ''
    Resume-DeltaActivity

    Write-DeltaLogLine -Message "== $Title$(if ($Subtitle) { " - $Subtitle" })" -Level 'SECTION'
}

function Write-Step {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Suspend-DeltaActivity
    Write-Host "==> $Message" -ForegroundColor Cyan
    Resume-DeltaActivity
    Write-DeltaLogLine -Message $Message -Level 'STEP'
}

function Write-Detail {
    param([AllowEmptyString()][string]$Message)
    Suspend-DeltaActivity
    Write-Host "    $Message"
    Resume-DeltaActivity
    Write-DeltaLogLine -Message $Message -Level 'DETAIL'
}

function Write-Success {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Suspend-DeltaActivity
    Write-Host $Message -ForegroundColor Green
    Resume-DeltaActivity
    Write-DeltaLogLine -Message $Message -Level 'SUCCESS'
}

function Write-DeltaWarning {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Suspend-DeltaActivity
    Write-Host "    $Message" -ForegroundColor Yellow
    Resume-DeltaActivity
    Write-DeltaLogLine -Message $Message -Level 'WARNING'
}

function Write-DeltaFailure {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Suspend-DeltaActivity
    Write-Host $Message -ForegroundColor Red
    Resume-DeltaActivity
    Write-DeltaLogLine -Message $Message -Level 'ERROR'
}

function Read-DeltaYesNoConfirmation {
    <#
      The shared shape behind every Y/N confirmation in this installer,
      adapted from the reference installer's function of the same name: a
      rule, the caller-supplied body, a '[y/N]' prompt, a closing rule.

      Bare Enter - or anything other than Y/y - always means No. Every
      confirmation in this project follows that "blank means the safe choice"
      convention, which is what makes a disclosure the operator did not read
      fail closed rather than open.

      $Body is a scriptblock that writes the question-specific text. It is
      invoked with & so it can still read the local variables of the scope it
      was written in.
    #>
    param([Parameter(Mandatory)][scriptblock]$Body)

    # Stopped, not suspended. An activity indicator animating over a question
    # claims that something is still in progress while the installer is in fact
    # doing nothing but waiting for this operator - and there is no correct
    # moment to resume it afterwards, because the answer decides what happens
    # next. Every prompt in this installer goes through one of the three
    # readers here or through a dialog below, so this is the whole of the rule.
    Stop-DeltaActivity

    $rule = '-' * $Script:DeltaBannerWidth
    Write-Host ''
    Write-Host $rule
    Write-Host ''
    & $Body
    Write-Host ''
    $choice = Read-Host -Prompt '[y/N]'
    Write-Host ''
    Write-Host $rule

    $confirmed = ($choice -and $choice.Trim() -in @('Y', 'y'))
    Write-DeltaLogLine -Message "Confirmation prompt answered: $(if ($confirmed) { 'yes' } else { 'no' })" -Level 'DETAIL'
    return $confirmed
}

function Read-DeltaInlineConfirmation {
    <#
      A Y/N answer on one line, with the question in the prompt itself.

      The lighter of this project's two confirmations. Read-DeltaYesNoConfirmation
      above frames its question in banner rules, which is right for a
      consequential decision an operator must not skim past; this is for the
      offers either answer to which is perfectly safe - "configure SMTP now?",
      "restart Windows now?" - where a banner would overstate the moment.

      The convention that matters is identical in both: bare Enter, and anything
      that is not Y, means no. A prompt an operator hurried past never takes the
      action.

      $Prompt is the question without its trailing colon - Read-Host adds that.
    #>
    param([Parameter(Mandatory)][string]$Prompt)

    Stop-DeltaActivity
    $choice = ([string](Read-Host -Prompt $Prompt)).Trim()
    $confirmed = ($choice -in @('Y', 'y'))
    Write-DeltaLogLine -Message "$Prompt -> $(if ($confirmed) { 'yes' } else { 'no' })" -Level 'DETAIL'
    return $confirmed
}

function Read-DeltaDefaultYesAnswer {
    <#
      A [Y/n] answer, where bare Enter means YES, returned as one of 'yes',
      'no' or 'unrecognised'.

      The exception to this project's "blank means no" rule, and it is worth
      saying why the rule does not apply. Everywhere else a confirmation guards
      an ACTION - restart Windows, accept a disclosure - and a blank answer must
      not perform it. This prompt guards no action: it asks which of two
      directories to install into, and both answers install. What blank means
      here is "the default you just showed me", which is what a [Y/n] prompt
      universally means and what an operator pressing Enter is asking for.

      Anything that is neither yes nor no comes back as 'unrecognised' rather
      than being folded into one of them, so the caller can ask again instead of
      acting on an answer the operator did not give.
    #>
    param([Parameter(Mandatory)][string]$Prompt)

    Stop-DeltaActivity
    $choice = ([string](Read-Host -Prompt $Prompt)).Trim()

    $answer = 'unrecognised'
    if ($choice -eq '')                    { $answer = 'yes' }
    elseif ($choice -in @('Y', 'y', 'yes', 'Yes', 'YES')) { $answer = 'yes' }
    elseif ($choice -in @('N', 'n', 'no', 'No', 'NO'))    { $answer = 'no'  }

    Write-DeltaLogLine -Message "$Prompt -> $answer" -Level 'DETAIL'
    return $answer
}

# ---------------------------------------------------------------------------
# File selection
#
# Adapted from the reference installer's Select-DeltaSslFile, which lives in
# its own lib\DeltaInstaller.Common.ps1 for the same reason it lives here: it
# carries no certificate-specific knowledge at all - the caller supplies the
# title and the filter - so it belongs with the shared console helpers rather
# than with the one feature that currently uses it.
# ---------------------------------------------------------------------------

function Test-DeltaFileDialogSupported {
    <#
      Whether an OpenFileDialog can actually be shown from this session.

      Two things have to hold. System.Windows.Forms must load - it is absent on
      a Server Core installation. And the calling thread must be STA, which is
      WinForms' own hard requirement: powershell.exe defaults to STA, but a
      script invoked with -MTA or hosted inside a runspace that is not gets a
      thread on which ShowDialog throws.

      This exists so a caller can decide BEFORE it starts a flow, rather than
      discovering it half-way through and having to abandon one. Answers only
      the question; opens nothing.
    #>

    try {
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
            return $false
        }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Select-DeltaSslFile {
    <#
      Opens a standard Windows file selection dialog and returns the selected
      file's full path, or $null if the operator closed or cancelled it without
      choosing one. Adapted from the reference installer's function of the same
      name, with its parameters, its filter convention and its CheckFileExists
      /Multiselect settings unchanged.

      Two deliberate differences from the reference.

      It refuses a non-STA thread itself rather than documenting STA as an
      assumption. Measured: on an MTA thread ShowDialog does not throw, it
      HANGS - no window, no error, no return. A helper whose failure mode is an
      unkillable prompt is not one a menu loop can call safely, so the check is
      here and not only in Test-DeltaFileDialogSupported, and a caller that
      never probed still cannot hang on it.

      And where the reference calls Stop-Setup because
      System.Windows.Forms would not load - right for a linear installer run -
      this returns $null and says why. The caller here is a menu loop inside
      Management Mode, and tearing the whole utility down because a dialog
      could not be opened would be worse than the problem it is reporting.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Filter
    )

    # A modal dialog is a prompt with a window around it, and gets the same
    # treatment as the typed ones: nothing animates while this waits.
    Stop-DeltaActivity

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        Write-DeltaWarning 'A file selection window cannot be opened from this session: PowerShell is not running on an STA thread.'
        return $null
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    }
    catch {
        Write-DeltaWarning "A file selection window could not be opened - System.Windows.Forms could not be loaded: $($_.Exception.Message)"
        return $null
    }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title           = $Title
    $dialog.Filter          = $Filter
    $dialog.CheckFileExists = $true
    $dialog.Multiselect     = $false

    # The chosen path is read BEFORE the dialog is disposed, and returned from
    # the local: reading FileName off a disposed dialog is not something to
    # rely on.
    $selected = $null
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $selected = $dialog.FileName
        }
    }
    catch {
        Write-DeltaWarning "A file selection window could not be opened: $($_.Exception.Message)"
        return $null
    }
    finally {
        $dialog.Dispose()
    }

    return $selected
}

function Get-DeltaFileDialogFilter {
    <#
      A dialog filter string built from an extension list, so the extensions a
      dialog offers and the extensions the validator accepts are the same list
      and cannot drift apart. "All files" is kept as the second entry, exactly
      as the reference installer's filters do, because a correctly-named file
      in an unusual location is still a file the operator has to be able to
      reach.
    #>
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Extensions
    )

    $patterns = (($Extensions | ForEach-Object { "*$_" }) -join ';')
    return "$Description ($patterns)|$patterns|All files (*.*)|*.*"
}

function Select-DeltaFolder {
    <#
      Opens a standard Windows folder selection dialog and returns the selected
      directory's full path, or $null if the operator closed or cancelled it
      without choosing one.

      The folder-picking sibling of Select-DeltaSslFile, and deliberately the
      same shape: the same STA refusal, the same Add-Type failure handling, the
      same read-before-Dispose, the same "$null means the operator chose
      nothing" contract. The two dialogs have identical hosting requirements -
      WinForms, an STA thread - so they get identical guards, and
      Test-DeltaFileDialogSupported answers for both.

      Cancelling is a legitimate answer here, not a failure. The caller decides
      what a cancellation means; this reports it and nothing else.
    #>
    param(
        [Parameter(Mandatory)][string]$Description,
        [string]$InitialPath
    )

    Stop-DeltaActivity

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        Write-DeltaWarning 'A folder selection window cannot be opened from this session: PowerShell is not running on an STA thread.'
        return $null
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    }
    catch {
        Write-DeltaWarning "A folder selection window could not be opened - System.Windows.Forms could not be loaded: $($_.Exception.Message)"
        return $null
    }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description

    # The new-folder button stays on: an operator installing to D:\Apps\DELTA
    # should not have to leave the installer to create the directory first.
    $dialog.ShowNewFolderButton = $true

    # Seeded only with a directory that actually exists. FolderBrowserDialog
    # silently ignores a SelectedPath that does not, and the resulting dialog
    # opens at the desktop root with no explanation.
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $dialog.SelectedPath = $InitialPath
    }

    # Read before Dispose, and return from the local, for the same reason
    # Select-DeltaSslFile does.
    $selected = $null
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $selected = $dialog.SelectedPath
        }
    }
    catch {
        Write-DeltaWarning "A folder selection window could not be opened: $($_.Exception.Message)"
        return $null
    }
    finally {
        $dialog.Dispose()
    }

    return $selected
}

function ConvertTo-DeltaPlainText {
    <#
      SecureString to plain text, at the point it is genuinely needed. Uses
      NetworkCredential rather than manual Marshal calls - the standard,
      PowerShell 5.1-compatible idiom, adapted from the reference installer.

      Lives here, in the file every entry point loads first, because callers
      exist at every layer - the administrator reset, the .env generator, the
      completion summary. Defining it in a late-loading file once made an
      earlier-loading caller resolve it to nothing and silently substitute an
      empty string, which is the kind of failure a credential helper must not
      be able to have.
    #>
    param([Parameter(Mandatory)][SecureString]$SecureString)
    return [System.Net.NetworkCredential]::new('', $SecureString).Password
}

function Stop-Setup {
    <#
      Raises a terminating error with an operator-readable message. setup.ps1's
      single top-level catch turns this into the error banner and the process
      exit code, so functions never call exit themselves.
    #>
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

function Test-DeltaIntegerInRange {
    <#
      Strict integer validation for operator input: the whole string must
      parse as an integer in the invariant culture (so "8080 " is accepted
      after trimming but "8080x", "0x50" and "" are not) and fall inside
      [$Minimum, $Maximum]. Returns $true/$false; never throws.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][int]$Minimum,
        [Parameter(Mandatory)][int]$Maximum
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $parsed = 0
    $styles = [System.Globalization.NumberStyles]::None
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [int]::TryParse($Value.Trim(), $styles, $culture, [ref]$parsed)) {
        return $false
    }

    return ($parsed -ge $Minimum -and $parsed -le $Maximum)
}

function Test-DeltaInstallRootCandidate {
    <#
      Validates a candidate installation root against the A§9.5 constraints:
      a rooted local path on a fixed volume, no UNC path, no mapped or
      removable drive, and short enough to leave room for the deepest file
      the installation creates under it.

      Returns an object with IsValid and, when it is not, a Reason naming the
      path and the specific constraint it failed. Never throws - the caller
      decides whether an invalid path is fatal or a re-prompt.

      -TestWritable additionally probes an existing directory by creating and
      deleting a temporary file, which is the only reliable writability test
      on Windows (an ACL read cannot account for share, EFS or policy
      restrictions). It is a no-op when the directory does not exist yet.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [switch]$TestWritable
    )

    $result = [PSCustomObject]@{
        Path    = $Path
        IsValid = $false
        Reason  = $null
        Exists  = $false
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.Reason = 'No installation root was supplied.'
        return $result
    }

    $invalidChars = [System.IO.Path]::GetInvalidPathChars()
    if ($Path.IndexOfAny($invalidChars) -ge 0) {
        $result.Reason = "The path '$Path' contains characters that are not valid in a Windows path."
        return $result
    }

    if ($Path.StartsWith('\\')) {
        $result.Reason = "The path '$Path' is a UNC path. The installation root must be a local fixed volume - uploads, logs, certificates and backups live under it."
        return $result
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $result.Reason = "The path '$Path' is not absolute. Supply a full path such as C:\DELTA."
        return $result
    }

    if ($Path.Length -gt 120) {
        $result.Reason = "The path '$Path' is $($Path.Length) characters long. Use a short root such as C:\DELTA so container bind-mount paths stay well inside the Windows path limit."
        return $result
    }

    $qualifier = $null
    try {
        $qualifier = [System.IO.Path]::GetPathRoot($Path)
    }
    catch {
        $result.Reason = "The path '$Path' could not be parsed: $($_.Exception.Message)"
        return $result
    }

    try {
        $drive = New-Object System.IO.DriveInfo($qualifier)
        if (-not $drive.IsReady) {
            $result.Reason = "The volume $qualifier is not ready."
            return $result
        }
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
            $result.Reason = "The volume $qualifier is a $($drive.DriveType) drive. The installation root must be on a local fixed volume - a mapped or removable drive is not available to the Docker bind mounts at every point the stack needs it."
            return $result
        }
    }
    catch {
        $result.Reason = "The volume $qualifier could not be inspected: $($_.Exception.Message)"
        return $result
    }

    $result.Exists = Test-Path -LiteralPath $Path -PathType Container

    if ($TestWritable -and $result.Exists) {
        $probe = Join-Path -Path $Path -ChildPath ".delta-write-probe-$([guid]::NewGuid().ToString('N'))"
        try {
            [System.IO.File]::WriteAllText($probe, '', $Script:DeltaUtf8NoBom)
        }
        catch {
            $result.Reason = "The directory '$Path' is not writable by this account: $($_.Exception.Message)"
            return $result
        }
        finally {
            if (Test-Path -LiteralPath $probe -PathType Leaf) {
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $result.IsValid = $true
    return $result
}

function Resolve-DeltaInstallRoot {
    <#
      Decides which directory this run installs into, and reports both the
      decision and how it was reached.

      The installer used to assume C:\DELTA silently on a new installation. It
      is still the default and still the recommendation - but an operator whose
      C: is a small system volume found out where DELTA had gone only after it
      was there, so the default is now offered rather than taken.

      Five ways this answers, and the first that applies wins:

        supplied         -InstallRoot was passed explicitly. Asking somebody
                         who already stated the answer is not a confirmation,
                         it is a second chance to get it wrong - and this is
                         also the path the post-restart continuation comes back
                         on, which must not stop for a prompt.
        non-interactive  -NonInteractive. Never opens a window: an unattended
                         run has nobody to close a modal dialog, and one that
                         appeared would hang the run until somebody found the
                         machine. Keeps the supplied-or-default behaviour
                         exactly as it was before this function existed.
        existing         There is already an installation - complete or partial
                         - at the default root. That root is a fact about this
                         machine, not a choice left to make, and installing a
                         second copy elsewhere while the first sits there is
                         never what was meant.
        no-dialog        A folder dialog cannot be shown here (Server Core,
                         a non-STA host). The question is not asked at all
                         rather than asked and then unanswerable: this
                         installer does not ask an operator to type a path, so
                         with no dialog there is no second option to offer.
                         Says how to choose one anyway - with -InstallRoot.
        asked            The operator is asked, and answers.

      The asked path loops until it has an answer it can use. Declining the
      default opens the folder dialog; cancelling the dialog returns to the
      question rather than cancelling the installation, because a cancelled
      dialog means "not that one", not "stop". A directory the validator
      rejects goes back to the question too, with the reason, so the operator
      is never left holding an unusable choice.

      Every probe is injectable - the prompt, the dialog, the dialog-support
      test, the state classification - so the whole decision table is
      exercisable offline on one machine, in the style of the other suites here.
      Nothing on disk is created or changed: this chooses a path and validates
      it, and the stage that owns the installation root still creates it.
    #>
    param(
        [Parameter(Mandatory)][string]$DefaultRoot,
        [switch]$WasSupplied,
        [bool]$AllowPrompt = $true,
        [scriptblock]$Reader,
        [scriptblock]$FolderPicker,
        [scriptblock]$DialogProbe,
        [scriptblock]$StateProbe
    )

    $result = [PSCustomObject]@{
        Path     = $DefaultRoot
        Source   = 'default'
        Asked    = $false
        Reason   = $null
    }

    if ($WasSupplied) {
        $result.Source = 'supplied'
        $result.Reason = '-InstallRoot was supplied on the command line.'
        return $result
    }

    if (-not $AllowPrompt) {
        $result.Source = 'non-interactive'
        $result.Reason = 'This run is non-interactive, so the default installation root is used.'
        return $result
    }

    if (-not $Reader)       { $Reader       = { param($prompt) Read-DeltaDefaultYesAnswer -Prompt $prompt } }
    if (-not $FolderPicker) { $FolderPicker = { param($description, $initial) Select-DeltaFolder -Description $description -InitialPath $initial } }
    if (-not $DialogProbe)  { $DialogProbe  = { Test-DeltaFileDialogSupported } }
    if (-not $StateProbe)   { $StateProbe   = { param($path) (Get-DeltaInstallationState -InstallRoot $path).State } }

    $existingState = & $StateProbe $DefaultRoot
    if ($existingState -and $existingState -ne 'none') {
        $result.Source = 'existing'
        $result.Reason = "An installation is already registered at $DefaultRoot (state = $existingState)."
        return $result
    }

    if (-not (& $DialogProbe)) {
        $result.Source = 'no-dialog'
        $result.Reason = 'A folder selection window cannot be opened from this session, so the default installation root is used.'
        return $result
    }

    # A cap, not a policy. The loop's real exit is the operator answering it;
    # this only stops a session whose input has been redirected from something
    # that answers nothing usable forever from spinning silently.
    $maxAttempts = 25
    $attempt = 0

    while ($attempt -lt $maxAttempts) {
        $attempt++
        $answer = & $Reader "Use $DefaultRoot as the installation directory? [Y/n]"

        if ($answer -eq 'yes') {
            $result.Source = 'default'
            $result.Asked  = $true
            $result.Reason = "The operator accepted the default installation root."
            return $result
        }

        if ($answer -ne 'no') {
            Write-DeltaWarning "Answer Y to use $DefaultRoot, or N to choose a different directory."
            continue
        }

        $picked = & $FolderPicker 'Select the directory to install DELTA into' $DefaultRoot

        if (-not $picked) {
            # Back to the question, deliberately. A cancelled dialog is the
            # operator changing their mind about choosing, not about installing.
            Write-Detail 'No directory was selected.'
            continue
        }

        $candidate = Test-DeltaInstallRootCandidate -Path $picked -TestWritable
        if (-not $candidate.IsValid) {
            Write-DeltaWarning "$picked cannot be used as the installation root."
            Write-Detail $candidate.Reason
            continue
        }

        $result.Path   = $picked
        $result.Source = 'selected'
        $result.Asked  = $true
        $result.Reason = 'The operator chose this directory.'
        return $result
    }

    $result.Path   = $DefaultRoot
    $result.Source = 'default'
    $result.Asked  = $true
    $result.Reason = "No usable answer after $maxAttempts attempts, so the default installation root is used."
    Write-DeltaWarning $result.Reason
    return $result
}

function Show-DeltaInstallRootChoice {
    <#
      States the installation root this run will use, and - when it was not
      simply the default - why it is that one. Printed for every path through
      Resolve-DeltaInstallRoot, including the ones that asked nothing, so the
      chosen root is always on screen and in the transcript before anything is
      created under it.
    #>
    param([Parameter(Mandatory)][object]$Choice)

    Write-Step 'Installation directory'

    switch ($Choice.Source) {
        'supplied'        { Write-Detail '-InstallRoot was supplied, so this run was not asked to choose.' }
        'non-interactive' { Write-Detail 'This run is non-interactive, so the default was used without asking.' }
        'existing'        { Write-Detail $Choice.Reason }
        'no-dialog'       {
            Write-DeltaWarning 'A folder selection window cannot be opened from this session.'
            Write-Detail 'The default installation root is used. To install somewhere else, re-run with'
            Write-Detail '  .\setup.ps1 -InstallRoot D:\DELTA'
        }
    }

    Write-Success "Installation root: $($Choice.Path)"
}
