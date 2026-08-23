#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for the generic terminal activity indicator.

.DESCRIPTION
    Invoke-DeltaActivity wraps an arbitrary operation in an animated
    "<message>." / ".." / "..." line. It is deliberately generic - it knows
    nothing about Docker, about installation, or about which operations exist -
    so what has to be proved here is not "Docker install animates" but the
    contract every present and future caller relies on:

      - The operation runs exactly once. A decorator that ran its payload
        twice would turn a database backup into two, and a container
        recreation into two.
      - Whatever the operation returns is what the caller receives, unchanged,
        for every shape a PowerShell operation can return - an object, a
        string, a collection, nothing at all.
      - An exception thrown by the operation propagates untouched. The
        indicator is presentation; it never becomes an error handler.
      - The animation is gone by the time the call returns, on the success
        path AND on the throwing path, with no leftover dots, no stray
        newline and no half-drawn text.
      - Nothing animates while a prompt is on screen. Every shared reader in
        Delta.Common.ps1 stops the indicator before it reads, and this
        asserts it from inside the read itself rather than around it.
      - A non-interactive or redirected run emits ONE static line and not a
        single control character. This is the property that keeps an
        operator's captured log readable.
      - The transcript records the operation once, never a frame.

    Deliberately dependency-free, matching the other suites here: no Pester,
    no modules, no network, and nothing that changes this host. The animation
    never touches the real console - Start-DeltaActivity takes a TextWriter,
    and every test here hands it a StringWriter and then reads back exactly
    the characters the worker emitted.

    No test asserts an exact frame count. Frame counts are a function of
    scheduler timing, and a suite that pinned them would fail on a loaded
    machine for no reason. Where an animation has to be shown to be running,
    the assertion is "at least one frame after three frame intervals".

    Exits 0 if every test passes, 1 otherwise.

.EXAMPLE
    .\tools\Test-ActivityIndicator.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$Script:Passed = 0
$Script:Failed = 0

. (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')

function Assert-That {
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)][AllowNull()]$Condition)
    if ($Condition) { Write-Host "    [PASS] $Description" -ForegroundColor Green; $Script:Passed++ }
    else            { Write-Host "    [FAIL] $Description" -ForegroundColor Red;   $Script:Failed++ }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Expected,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Actual
    )
    if ($Expected -ceq $Actual) { Write-Host "    [PASS] $Description" -ForegroundColor Green; $Script:Passed++ }
    else {
        Write-Host "    [FAIL] $Description" -ForegroundColor Red
        Write-Host "           expected: '$Expected'" -ForegroundColor Red
        Write-Host "           actual:   '$Actual'" -ForegroundColor Red
        $Script:Failed++
    }
}

function Start-TestCase {
    param([Parameter(Mandatory)][string]$Name)
    Write-Host ''
    Write-Host "==> $Name" -ForegroundColor Cyan
}

# --- fixtures ---------------------------------------------------------------

# Three frame intervals. Long enough that an animation which is running has
# certainly drawn, short enough that the suite stays quick. Nothing asserts on
# how many frames appear inside it.
$Script:SettleMs = 3 * 400

function New-ActivitySink {
    <#
      A StringWriter the animation worker can write to from its own runspace,
      plus the raw writer to read the emitted characters back from. Synchronized
      because two threads reach it: the worker draws frames, and the main thread
      erases the line on Suspend and on Stop.
    #>
    $raw = New-Object System.IO.StringWriter
    return [PSCustomObject]@{
        Raw    = $raw
        Writer = [System.IO.TextWriter]::Synchronized($raw)
    }
}

function Get-SinkText {
    param([Parameter(Mandatory)][object]$Sink)
    return $Sink.Raw.ToString()
}

function Test-LineWasCleared {
    <#
      Whether the emitted text ends with the erase this indicator promises:
      a carriage return, a run of blanks as wide as the last frame, and a
      carriage return back to column 0. That - and nothing after it - is what
      "no leftover dots and the next output starts on a clean line" means in
      characters.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ($Text -match "`r +`r$")
}

function Test-StayedOnOneLine {
    <#
      The animation must never advance the line. One newline anywhere in the
      emitted text means the terminal scrolled and the "same line" contract is
      broken.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ($Text -notmatch "`n")
}

function Get-FrameCount {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Message)
    return ([regex]::Matches($Text, [regex]::Escape($Message))).Count
}

# Every test starts from a known mode; a test that changes it puts it back.
Set-DeltaActivityMode -Mode 'auto'

# --- the operation runs, once, and its result is the caller's ---------------

Start-TestCase 'The wrapped operation executes exactly once'

$Script:Runs = 0
$sink = New-ActivitySink
$null = Invoke-DeltaActivity -Message 'Counting' -Writer $sink.Writer -ScriptBlock {
    $Script:Runs++
    Start-Sleep -Milliseconds 50
}
Assert-Equal 'the scriptblock ran once' 1 $Script:Runs

# Again with no animation at all, because "once" must not depend on whether
# the terminal supports drawing.
Set-DeltaActivityMode -Mode 'off'
$Script:Runs = 0
$null = Invoke-DeltaActivity -Message 'Counting' -ScriptBlock { $Script:Runs++ } 6>$null
Assert-Equal 'and once again with animation turned off' 1 $Script:Runs
Set-DeltaActivityMode -Mode 'auto'

Start-TestCase 'The operation result reaches the caller unchanged'

$sink = New-ActivitySink
$object = Invoke-DeltaActivity -Message 'Returning an object' -Writer $sink.Writer -ScriptBlock {
    [PSCustomObject]@{ Succeeded = $true; ExitCode = 3010; Reason = 'reboot required' }
}
Assert-That  'a PSCustomObject comes back as itself' ($object -is [PSCustomObject])
Assert-Equal 'with its properties intact'            3010 $object.ExitCode
Assert-Equal 'and its strings intact'                'reboot required' $object.Reason

$sink = New-ActivitySink
$text = Invoke-DeltaActivity -Message 'Returning a string' -Writer $sink.Writer -ScriptBlock { 'plain text' }
Assert-Equal 'a string comes back as itself' 'plain text' $text

$sink = New-ActivitySink
$many = @(Invoke-DeltaActivity -Message 'Returning a collection' -Writer $sink.Writer -ScriptBlock { 1; 2; 3 })
Assert-Equal 'a multi-object result keeps every object' 3 $many.Count
Assert-Equal 'in order'                                 '1,2,3' ($many -join ',')

$sink = New-ActivitySink
$nothing = Invoke-DeltaActivity -Message 'Returning nothing' -Writer $sink.Writer -ScriptBlock { $null = 1 + 1 }
Assert-That 'an operation that returns nothing returns nothing' ($null -eq $nothing)

Start-TestCase 'The wrapped operation still sees the scope it was written in'

# The whole point of invoking with & rather than in a fresh scope: a call site
# passes a scriptblock full of its own locals, exactly as every migrated caller
# in the installer does.
function Invoke-ScopedOperation {
    $installerPath = 'C:\somewhere\Docker Desktop Installer.exe'
    $arguments     = @('install', '--quiet')
    $sink = New-ActivitySink
    return (Invoke-DeltaActivity -Message 'Scoped' -Writer $sink.Writer -ScriptBlock {
        "$installerPath :: $($arguments -join ' ')"
    })
}
Assert-Equal 'the scriptblock reads its caller''s locals' `
    'C:\somewhere\Docker Desktop Installer.exe :: install --quiet' (Invoke-ScopedOperation)

# --- exceptions -------------------------------------------------------------

Start-TestCase 'An exception from the operation propagates untouched'

$sink = New-ActivitySink
$caught = $null
try {
    $null = Invoke-DeltaActivity -Message 'Failing' -Writer $sink.Writer -ScriptBlock {
        Start-Sleep -Milliseconds 50
        throw 'the installer could not be verified'
    }
    Assert-That 'the exception was not swallowed' $false
}
catch {
    $caught = $_
}
Assert-That  'the exception reached the caller' ($null -ne $caught)
Assert-Equal 'with its message unaltered' 'the installer could not be verified' $caught.Exception.Message

Start-TestCase 'A terminating error from a called command propagates too'

$sink = New-ActivitySink
$caught = $null
try {
    $null = Invoke-DeltaActivity -Message 'Failing' -Writer $sink.Writer -ScriptBlock {
        Get-Item -LiteralPath 'C:\this\path\does\not\exist\at\all.txt' -ErrorAction Stop
    }
    Assert-That 'the terminating error was not swallowed' $false
}
catch {
    $caught = $_
}
Assert-That 'a cmdlet''s terminating error reaches the caller' ($null -ne $caught)

# --- cleanup ----------------------------------------------------------------

Start-TestCase 'The animation is cleaned up after the operation succeeds'

$sink = New-ActivitySink
$null = Invoke-DeltaActivity -Message 'Starting DELTA' -Writer $sink.Writer -ScriptBlock {
    Start-Sleep -Milliseconds $Script:SettleMs
}
$emitted = Get-SinkText -Sink $sink

Assert-That 'the animation actually ran'                ((Get-FrameCount -Text $emitted -Message 'Starting DELTA') -ge 1)
Assert-That 'no activity is running afterwards'         (-not (Test-DeltaActivityRunning))
Assert-That 'the line was erased, leaving no dots'      (Test-LineWasCleared -Text $emitted)
Assert-That 'and it never left the line it started on'  (Test-StayedOnOneLine -Text $emitted)

Start-TestCase 'The animation is cleaned up after the operation throws'

$sink = New-ActivitySink
try {
    $null = Invoke-DeltaActivity -Message 'Starting DELTA' -Writer $sink.Writer -ScriptBlock {
        Start-Sleep -Milliseconds $Script:SettleMs
        throw 'boom'
    }
}
catch { }
$emitted = Get-SinkText -Sink $sink

Assert-That 'the animation ran before the failure'      ((Get-FrameCount -Text $emitted -Message 'Starting DELTA') -ge 1)
Assert-That 'no activity is running afterwards'         (-not (Test-DeltaActivityRunning))
Assert-That 'the line was erased on the failing path too' (Test-LineWasCleared -Text $emitted)
Assert-That 'and it never left the line it started on'  (Test-StayedOnOneLine -Text $emitted)

Start-TestCase 'The animation is cleaned up when the operation returns early'

function Invoke-EarlyReturn {
    param([object]$Sink)
    return (Invoke-DeltaActivity -Message 'Returning early' -Writer $Sink.Writer -ScriptBlock {
        Start-Sleep -Milliseconds 100
        return 'left early'
        # unreachable on purpose
        'never'
    })
}
$sink = New-ActivitySink
Assert-Equal 'an early return is still the caller''s result' 'left early' (Invoke-EarlyReturn -Sink $sink)
Assert-That  'and stops the animation'                       (-not (Test-DeltaActivityRunning))
Assert-That  'leaving a cleared line'                        (Test-LineWasCleared -Text (Get-SinkText -Sink $sink))

Start-TestCase 'Stop-DeltaActivity is idempotent and safe with nothing running'

Stop-DeltaActivity
Stop-DeltaActivity
Assert-That 'stopping nothing twice does nothing and throws nothing' (-not (Test-DeltaActivityRunning))

$sink = New-ActivitySink
Start-DeltaActivity -Message 'Manually started' -Writer $sink.Writer
Assert-That 'a directly started activity is running' (Test-DeltaActivityRunning)

# Settled first, so there is genuinely something drawn for the stop to erase.
# Without the wait this would assert that stopping an activity which never
# drew a frame writes nothing - true, but not the property under test.
Start-Sleep -Milliseconds $Script:SettleMs
Stop-DeltaActivity
$afterFirstStop = Get-SinkText -Sink $sink
Stop-DeltaActivity
Assert-That  'and a second stop is harmless'            (-not (Test-DeltaActivityRunning))
Assert-That  'with the line cleared by the first stop'  (Test-LineWasCleared -Text $afterFirstStop)
Assert-Equal 'and the second writing nothing at all'    $afterFirstStop.Length (Get-SinkText -Sink $sink).Length

Start-TestCase 'Two activities never share a line, and the outer one comes back'

# Nesting, which is what an inner operation inside an outer one is. Only one
# line is ever drawn: the inner one takes it over and hands it back.
$outer = New-ActivitySink
$inner = New-ActivitySink
Start-DeltaActivity -Message 'Outer operation' -Writer $outer.Writer
Start-Sleep -Milliseconds $Script:SettleMs

# Read the outer sink at the moment the inner takes over, then again well
# after, so "the outer worker really stopped drawing" is a measurement.
Start-DeltaActivity -Message 'Inner operation' -Writer $inner.Writer
$outerAtHandover = Get-SinkText -Sink $outer
Assert-That  'starting an inner activity cleared the outer line' (Test-LineWasCleared -Text $outerAtHandover)
Assert-That  'the outer animated while it owned the line'        ((Get-FrameCount -Text $outerAtHandover -Message 'Outer operation') -ge 1)

Start-Sleep -Milliseconds $Script:SettleMs
$outerWhileInner = Get-SinkText -Sink $outer
Assert-Equal 'and drew nothing at all while the inner ran'       $outerAtHandover.Length $outerWhileInner.Length
Assert-That  'while the inner animated'                          ((Get-FrameCount -Text (Get-SinkText -Sink $inner) -Message 'Inner operation') -ge 1)
Assert-Equal 'with both activities in progress'                  2 (Get-DeltaActivityDepth)

# The property the whole correction is about: finishing the inner operation
# must not leave the outer one - which is still in progress - looking idle.
Stop-DeltaActivity
$innerText = Get-SinkText -Sink $inner
$outerAtHandback = Get-SinkText -Sink $outer
Assert-That  'the inner line was cleared when it ended'          (Test-LineWasCleared -Text $innerText)
Assert-Equal 'the outer operation is in progress again'          1 (Get-DeltaActivityDepth)
Assert-That  'and it is animating again'                         (Test-DeltaActivityAnimating)
Assert-That  'having redrawn immediately, not on the next tick'  ($outerAtHandback.Length -gt $outerWhileInner.Length)

Start-Sleep -Milliseconds $Script:SettleMs
$outerAfter = Get-SinkText -Sink $outer
Assert-That  'and it keeps animating afterwards'                 ($outerAfter.Length -gt $outerAtHandback.Length)

Stop-DeltaActivity
Assert-That  'stopping the outer ends everything'                (-not (Test-DeltaActivityRunning))
Assert-That  'the outer line was cleared'                        (Test-LineWasCleared -Text (Get-SinkText -Sink $outer))
Assert-That  'the outer never left its line'                     (Test-StayedOnOneLine -Text (Get-SinkText -Sink $outer))
Assert-That  'and neither did the inner'                         (Test-StayedOnOneLine -Text $innerText)

Start-TestCase 'A nested activity is cleaned up at every depth when the inner one throws'

$outer = New-ActivitySink
$inner = New-ActivitySink
$caught = $null
try {
    $null = Invoke-DeltaActivity -Message 'Outer operation' -Writer $outer.Writer -ScriptBlock {
        Start-Sleep -Milliseconds 100
        $null = Invoke-DeltaActivity -Message 'Inner operation' -Writer $inner.Writer -ScriptBlock {
            Start-Sleep -Milliseconds 100
            throw 'the inner operation failed'
        }
    }
}
catch { $caught = $_ }

Assert-That  'the exception propagated through both levels' ($null -ne $caught)
Assert-Equal 'unaltered'                                    'the inner operation failed' $caught.Exception.Message
Assert-Equal 'and no activity survives at any depth'        0 (Get-DeltaActivityDepth)
Assert-That  'the inner line was cleared'                   (Test-LineWasCleared -Text (Get-SinkText -Sink $inner))
Assert-That  'and so was the outer'                         (Test-LineWasCleared -Text (Get-SinkText -Sink $outer))

Start-TestCase 'Stop-DeltaLog is a backstop for abandoned activities at every depth'

$sink = New-ActivitySink
Start-DeltaActivity -Message 'Abandoned outer' -Writer $sink.Writer
Start-DeltaActivity -Message 'Abandoned inner' -Writer $sink.Writer
Assert-Equal 'two activities were abandoned' 2 (Get-DeltaActivityDepth)
Stop-DeltaLog -ExitCode 0
Assert-That 'closing the transcript stops every stray animation' (-not (Test-DeltaActivityRunning))
Assert-That 'and clears the line'                                (Test-LineWasCleared -Text (Get-SinkText -Sink $sink))

# --- concurrent output ------------------------------------------------------

Start-TestCase 'Console output suspends the animation rather than racing it'

$sink = New-ActivitySink
Start-DeltaActivity -Message 'Working' -Writer $sink.Writer
Start-Sleep -Milliseconds $Script:SettleMs

# What every output helper in Delta.Common.ps1 does before it writes.
Suspend-DeltaActivity
$atSuspend = Get-SinkText -Sink $sink
Assert-That 'suspending erases the animated line first' (Test-LineWasCleared -Text $atSuspend)

Start-Sleep -Milliseconds $Script:SettleMs
$afterQuiet = Get-SinkText -Sink $sink
Assert-Equal 'and nothing is drawn while it stays suspended' $atSuspend.Length $afterQuiet.Length

Resume-DeltaActivity
Start-Sleep -Milliseconds $Script:SettleMs
$afterResume = Get-SinkText -Sink $sink
Assert-That 'resuming redraws the line' ($afterResume.Length -gt $afterQuiet.Length)

Stop-DeltaActivity
Assert-That 'and the whole exchange stayed on one line' (Test-StayedOnOneLine -Text (Get-SinkText -Sink $sink))

Start-TestCase 'Write-Detail inside an activity does not corrupt the line'

$sink = New-ActivitySink
$null = Invoke-DeltaActivity -Message 'Working' -Writer $sink.Writer -ScriptBlock {
    Start-Sleep -Milliseconds $Script:SettleMs
    Write-Detail 'something happened half-way through'
    Write-DeltaWarning 'and something else did too'
    Start-Sleep -Milliseconds $Script:SettleMs
} 6>$null
$emitted = Get-SinkText -Sink $sink
Assert-That 'the animation resumed after the interruption' ((Get-FrameCount -Text $emitted -Message 'Working') -ge 2)
Assert-That 'the animated line never wrote a newline'      (Test-StayedOnOneLine -Text $emitted)
Assert-That 'and finished cleared'                         (Test-LineWasCleared -Text $emitted)

# --- the lifetime of a whole logical operation ------------------------------

Start-TestCase 'A polling operation stays animated between its observations'

# The shape of every wait in this installer, and the defect this suite exists
# to prevent coming back: a loop that observes, prints occasionally, and SLEEPS.
# The sleeps are the interval that used to look like a stopped terminal.
$sink = New-ActivitySink
$Script:Polls = 0
$marks = New-Object 'System.Collections.Generic.List[int]'

$outcome = Invoke-DeltaActivity -Message 'Waiting for delta to become healthy' -Writer $sink.Writer -ScriptBlock {
    while ($Script:Polls -lt 4) {
        $Script:Polls++
        # What the loop has learnt so far, printed as a real status line.
        if ($Script:Polls -eq 2) { Write-Detail "Waiting for delta (6 s; state running, health starting)" }
        Start-Sleep -Milliseconds $Script:SettleMs
        $null = $marks.Add((Get-SinkText -Sink $sink).Length)
    }
    return [PSCustomObject]@{ Succeeded = $true; ElapsedSeconds = 12 }
} 6>$null

$emitted = Get-SinkText -Sink $sink
Assert-Equal 'the loop ran to completion'                    4 $Script:Polls
Assert-That  'and its result reached the caller'             ($outcome.Succeeded -and $outcome.ElapsedSeconds -eq 12)
Assert-That  'the line was still drawing after every sleep'  (($marks[0] -lt $marks[1]) -and ($marks[1] -lt $marks[2]) -and ($marks[2] -lt $marks[3]))
Assert-That  'including the sleep after the status line'     ($marks[1] -lt $marks[2])
Assert-That  'it never left its line'                        (Test-StayedOnOneLine -Text $emitted)
Assert-That  'and finished cleared'                          (Test-LineWasCleared -Text $emitted)
Assert-That  'with nothing left in progress'                 (-not (Test-DeltaActivityRunning))

Start-TestCase 'An intermediate status line suspends the animation and never ends it'

$sink = New-ActivitySink
$Script:AnimatingDuringWrite = $null
$null = Invoke-DeltaActivity -Message 'Working' -Writer $sink.Writer -ScriptBlock {
    Start-Sleep -Milliseconds 100
    # Write-Host is stubbed for the length of this call so the check runs at
    # the instant the status text would be reaching the terminal - which is the
    # instant at which a frame must not be able to interleave with it.
    function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Rest, $ForegroundColor)
        $Script:AnimatingDuringWrite = Test-DeltaActivityAnimating
    }
    Write-Detail 'a status line'
} 6>$null

Assert-Equal 'nothing is animating while the status is written' $false $Script:AnimatingDuringWrite
Assert-That  'and the activity was still in progress after it'  ((Get-FrameCount -Text (Get-SinkText -Sink $sink) -Message 'Working') -ge 1)

# --- operations that are part of something larger ---------------------------

Start-TestCase '-WhenIdle announces an operation reached on its own'

$sink = New-ActivitySink
$null = Invoke-DeltaActivity -Message 'Waiting for the Docker engine' -WhenIdle -Writer $sink.Writer -ScriptBlock {
    Start-Sleep -Milliseconds $Script:SettleMs
}
Assert-That 'it animated, because nothing else was'    ((Get-FrameCount -Text (Get-SinkText -Sink $sink) -Message 'Waiting for the Docker engine') -ge 1)
Assert-That 'and cleaned up after itself'              (Test-LineWasCleared -Text (Get-SinkText -Sink $sink))

Start-TestCase '-WhenIdle runs under the operation that is already in progress'

$outerSink = New-ActivitySink
$innerSink = New-ActivitySink
$Script:InnerRan = 0

$result = Invoke-DeltaActivity -Message 'Starting DELTA' -Writer $outerSink.Writer -ScriptBlock {
    Start-Sleep -Milliseconds $Script:SettleMs
    $depthOutside = Get-DeltaActivityDepth
    $inner = Invoke-DeltaActivity -Message 'Waiting for delta to become healthy' -WhenIdle -Writer $innerSink.Writer -ScriptBlock {
        $Script:InnerRan++
        Start-Sleep -Milliseconds $Script:SettleMs
        return "depth $((Get-DeltaActivityDepth)) inside"
    }
    return "$inner, $depthOutside outside"
}

$outerText = Get-SinkText -Sink $outerSink
Assert-Equal 'the inner operation ran exactly once'              1 $Script:InnerRan
Assert-Equal 'its result reached the caller'                     'depth 1 inside, 1 outside' $result
Assert-Equal 'it started no activity of its own'                 0 (Get-SinkText -Sink $innerSink).Length
Assert-That  'the outer message never left the screen'           ((Get-FrameCount -Text $outerText -Message 'Starting DELTA') -ge 2)
Assert-That  'and the outer kept drawing throughout'             ((Get-FrameCount -Text $outerText -Message 'Starting DELTA') -ge 4)
Assert-That  'on one line'                                       (Test-StayedOnOneLine -Text $outerText)
Assert-That  'cleared at the end'                                (Test-LineWasCleared -Text $outerText)

Start-TestCase 'The Start/try/finally form covers a sequence with early returns'

# The form the stack call sites use: one activity across `compose up` AND the
# health wait, where the failure branches return from the calling function.
function Invoke-SequenceThatReturnsEarly {
    param([Parameter(Mandatory)][object]$Sink, [Parameter(Mandatory)][bool]$Fail)

    $up = $null
    $health = $null
    Start-DeltaActivity -Message 'Starting DELTA' -Writer $Sink.Writer
    try {
        Start-Sleep -Milliseconds 100
        $up = [PSCustomObject]@{ ExitCode = $(if ($Fail) { 1 } else { 0 }) }
        if ($up.ExitCode -eq 0) {
            Start-Sleep -Milliseconds $Script:SettleMs
            $health = [PSCustomObject]@{ Succeeded = $true }
        }
    }
    finally { Stop-DeltaActivity }

    if ($up.ExitCode -ne 0) { return 'compose failed' }
    if (-not $health.Succeeded) { return 'unhealthy' }
    return 'started'
}

$sink = New-ActivitySink
Assert-Equal 'the whole sequence ran under one activity' 'started' (Invoke-SequenceThatReturnsEarly -Sink $sink -Fail $false)
Assert-That  'which animated across both halves'         ((Get-FrameCount -Text (Get-SinkText -Sink $sink) -Message 'Starting DELTA') -ge 2)
Assert-That  'and was cleaned up'                        (-not (Test-DeltaActivityRunning))
Assert-That  'leaving a cleared line'                    (Test-LineWasCleared -Text (Get-SinkText -Sink $sink))

$sink = New-ActivitySink
Assert-Equal 'an early return still leaves the function' 'compose failed' (Invoke-SequenceThatReturnsEarly -Sink $sink -Fail $true)
Assert-That  'with no activity left running'             (-not (Test-DeltaActivityRunning))
Assert-That  'and a cleared line'                        (Test-LineWasCleared -Text (Get-SinkText -Sink $sink))

# --- prompts ----------------------------------------------------------------

Start-TestCase 'No animation is ever drawing while a prompt waits for input'

# Read-Host cannot be driven from here, so each reader is called from a wrapper
# that defines its own Read-Host - the same technique the install-root suite
# uses - and that stand-in records the one thing this test is about: whether an
# animation was still live at the instant the prompt was displayed.
#
# There is a wrapper per reader rather than one that takes the reader as a
# scriptblock, because a scriptblock invoked with & runs against the scope it
# was WRITTEN in, which would put the stand-in out of reach and quietly test
# nothing at all.
#
# Two different questions are recorded at the prompt, and the difference is the
# point. Nothing may be DRAWING - that is the rule. But the operation the
# question was asked from is still in progress, and stays in progress, so that
# it can carry on animating once the answer is in.
$Script:AnimatingAtPrompt = $null
$Script:RunningAtPrompt = $null
$Script:PromptCount = 0

function Start-PromptFixture {
    $Script:AnimatingAtPrompt = $null
    $Script:RunningAtPrompt = $null
    $Script:PromptCount = 0
    $sink = New-ActivitySink
    Start-DeltaActivity -Message 'Something in progress' -Writer $sink.Writer
    Start-Sleep -Milliseconds 100
    return $sink
}

function Invoke-InlineConfirmationWithLiveActivity {
    param([Parameter(Mandatory)][object]$Sink)
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        $Script:PromptCount++
        $Script:AnimatingAtPrompt = Test-DeltaActivityAnimating
        $Script:RunningAtPrompt = Test-DeltaActivityRunning
        # Read at the instant the question is on screen, not afterwards: by the
        # time the reader returns the activity has legitimately resumed.
        $Script:SinkAtPrompt = Get-SinkText -Sink $Sink
        return 'n'
    }
    $null = Read-DeltaInlineConfirmation -Prompt 'Restart Windows now? [y/N]'
}

function Invoke-DefaultYesAnswerWithLiveActivity {
    param([Parameter(Mandatory)][object]$Sink)
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        $Script:PromptCount++
        $Script:AnimatingAtPrompt = Test-DeltaActivityAnimating
        $Script:RunningAtPrompt = Test-DeltaActivityRunning
        # Read at the instant the question is on screen, not afterwards: by the
        # time the reader returns the activity has legitimately resumed.
        $Script:SinkAtPrompt = Get-SinkText -Sink $Sink
        return 'n'
    }
    $null = Read-DeltaDefaultYesAnswer -Prompt 'Use C:\DELTA? [Y/n]'
}

function Invoke-YesNoConfirmationWithLiveActivity {
    param([Parameter(Mandatory)][object]$Sink)
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        $Script:PromptCount++
        $Script:AnimatingAtPrompt = Test-DeltaActivityAnimating
        $Script:RunningAtPrompt = Test-DeltaActivityRunning
        # Read at the instant the question is on screen, not afterwards: by the
        # time the reader returns the activity has legitimately resumed.
        $Script:SinkAtPrompt = Get-SinkText -Sink $Sink
        return 'n'
    }
    # A body that writes through the output helpers, because those suspend and
    # resume - and if suspension did not count, the resume inside the body
    # would restart the animation with the question still on screen.
    $null = Read-DeltaYesNoConfirmation -Body {
        Write-Detail 'A detail line inside the question.'
        Write-Host 'Accept the licence?'
    } 6>$null
}

foreach ($case in @(
    @{ Name = 'Read-DeltaInlineConfirmation'; Invoke = 'Invoke-InlineConfirmationWithLiveActivity' }
    @{ Name = 'Read-DeltaDefaultYesAnswer';   Invoke = 'Invoke-DefaultYesAnswerWithLiveActivity'   }
    @{ Name = 'Read-DeltaYesNoConfirmation';  Invoke = 'Invoke-YesNoConfirmationWithLiveActivity'  }
)) {
    $sink = Start-PromptFixture
    & $case.Invoke -Sink $sink

    Assert-Equal "$($case.Name) reached its prompt"      1 $Script:PromptCount
    Assert-Equal 'with nothing animating'                $false $Script:AnimatingAtPrompt
    Assert-Equal 'the operation still in progress'       $true $Script:RunningAtPrompt
    Assert-That  'and the animated line already erased'  (Test-LineWasCleared -Text $Script:SinkAtPrompt)

    # And the other half of the rule: the answer is in, the operation is still
    # running, so it says so again.
    Assert-That 'the activity resumes once the answer is in' (Test-DeltaActivityAnimating)
    Start-Sleep -Milliseconds $Script:SettleMs
    Assert-That 'and draws again'                            ((Get-SinkText -Sink $sink).Length -gt $Script:SinkAtPrompt.Length)

    Stop-DeltaActivity
    Assert-That 'the whole exchange stayed on one line'      (Test-StayedOnOneLine -Text (Get-SinkText -Sink $sink))
}

# --- non-interactive / redirected -------------------------------------------

Start-TestCase 'Animation turned off emits one static line and no control characters'

Set-DeltaActivityMode -Mode 'off'
Assert-Equal 'the mode is off' 'off' (Get-DeltaActivityMode)

# A writer is supplied AND ignored: 'off' is a statement about what the caller
# wants, not about the terminal, so it outranks the injected sink.
$sink = New-ActivitySink
$emittedHost = @(Invoke-DeltaActivity -Message 'Installing Docker Desktop' -Writer $sink.Writer -ScriptBlock {
    Start-Sleep -Milliseconds $Script:SettleMs
} 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'nothing at all was drawn to the terminal writer' 0 (Get-SinkText -Sink $sink).Length
Assert-Equal 'exactly one line was written'                    1 $emittedHost.Count
Assert-Equal 'and it is the documented static form'            '    Installing Docker Desktop...' $emittedHost[0]
Assert-That  'with no carriage return in it'                   ($emittedHost[0] -notmatch "`r")
Assert-That  'no backspace in it'                              ($emittedHost[0] -notmatch "`b")
Assert-That  'and no escape sequence in it'                    ($emittedHost[0] -notmatch "$([char]27)")
Assert-That  'no activity is left running'                     (-not (Test-DeltaActivityRunning))

Start-TestCase 'Nested operations stay static and clean with animation turned off'

$sink = New-ActivitySink
$emittedHost = @(Invoke-DeltaActivity -Message 'Starting DELTA' -Writer $sink.Writer -ScriptBlock {
    $null = Invoke-DeltaActivity -Message 'An inner operation' -Writer $sink.Writer -ScriptBlock {
        Start-Sleep -Milliseconds 50
    }
    # And an operation that is part of the one already in progress says nothing
    # extra in a log, exactly as it draws nothing extra on a console.
    $null = Invoke-DeltaActivity -Message 'Waiting for delta to become healthy' -WhenIdle -Writer $sink.Writer -ScriptBlock {
        Start-Sleep -Milliseconds 50
    }
} 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'nothing at all was drawn to the terminal writer'  0 (Get-SinkText -Sink $sink).Length
Assert-Equal 'one static line per announced operation'          2 $emittedHost.Count
Assert-Equal 'the outer one first'                              '    Starting DELTA...' $emittedHost[0]
Assert-Equal 'then the inner one'                               '    An inner operation...' $emittedHost[1]
Assert-That  'with no control characters anywhere'              (-not ($emittedHost | Where-Object { $_ -match "[`r`b$([char]27)]" }))
Assert-That  'and nothing left in progress'                     (-not (Test-DeltaActivityRunning))

Set-DeltaActivityMode -Mode 'auto'

Start-TestCase 'Terminal capability detection fails closed'

Set-DeltaActivityMode -Mode 'off'
Assert-Equal 'a console is never probed while the mode is off' $false (Test-DeltaActivitySupported -Width 4)
Set-DeltaActivityMode -Mode 'auto'

# Wider than any console window, so the line would wrap and a carriage return
# would no longer return to the start of it.
Assert-Equal 'a line too wide for the window is refused' $false (Test-DeltaActivitySupported -Width 100000)

# A redirected host must never animate. When this suite runs with its output
# captured - which is how CI runs it - that is exactly the case under test;
# on a real console the probe is allowed to say yes, so the assertion is on
# the redirected fact rather than on the answer.
if ([Console]::IsOutputRedirected) {
    Assert-Equal 'redirected output is refused' $false (Test-DeltaActivitySupported -Width 4)
}
else {
    Assert-That 'output is not redirected, so the width probe above is the live one' $true
}

# --- transcript -------------------------------------------------------------

Start-TestCase 'The transcript records the operation once and never a frame'

$logDirectory = Join-Path $env:TEMP "delta-activity-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$logPath = Start-DeltaLog -Directory $logDirectory -Name 'activity'
Assert-That 'a transcript was opened' ($null -ne $logPath)

$sink = New-ActivitySink
$null = Invoke-DeltaActivity -Message 'Pulling container images' -Writer $sink.Writer -ScriptBlock {
    Start-Sleep -Milliseconds ($Script:SettleMs * 2)
}
Stop-DeltaLog -ExitCode 0

$logLines = @(Get-Content -LiteralPath $logPath)
$mentions = @($logLines | Where-Object { $_ -match 'Pulling container images' })

Assert-Equal 'the operation appears in the transcript exactly once' 1 $mentions.Count
Assert-Equal 'as the whole sentence, with its ellipsis'             $true ($mentions[0] -match 'Pulling container images\.\.\.$')
Assert-That  'no transcript line carries a carriage return'         (-not ($logLines | Where-Object { $_ -match "`r" }))
Assert-That  'and the animation drew many more frames than that'    ((Get-FrameCount -Text (Get-SinkText -Sink $sink) -Message 'Pulling container images') -gt $mentions.Count)

Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction SilentlyContinue

# --- teardown ---------------------------------------------------------------

Stop-DeltaActivity
Set-DeltaActivityMode -Mode 'auto'

Write-Host ''
Write-Host ('-' * 60)
Write-Host "  passed: $Script:Passed"
Write-Host "  failed: $Script:Failed"
Write-Host ('-' * 60)
Write-Host ''

if ($Script:Failed -gt 0) { exit 1 }
exit 0
