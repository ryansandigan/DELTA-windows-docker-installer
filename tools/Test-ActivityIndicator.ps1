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

Start-TestCase 'Two activities never share a line'

$first  = New-ActivitySink
$second = New-ActivitySink
Start-DeltaActivity -Message 'First operation' -Writer $first.Writer
Start-Sleep -Milliseconds $Script:SettleMs

# Read the first sink at the moment it is superseded, then again well after,
# so "the replaced worker really stopped" is a measurement rather than a hope.
Start-DeltaActivity -Message 'Second operation' -Writer $second.Writer
$firstAtHandover = Get-SinkText -Sink $first
Start-Sleep -Milliseconds $Script:SettleMs
Stop-DeltaActivity

$firstText  = Get-SinkText -Sink $first
$secondText = Get-SinkText -Sink $second
Assert-That  'starting a second activity cleared the first' (Test-LineWasCleared -Text $firstAtHandover)
Assert-That  'the first animated while it owned the line'   ((Get-FrameCount -Text $firstAtHandover -Message 'First operation') -ge 1)
Assert-Equal 'and drew nothing more after being replaced'   $firstAtHandover.Length $firstText.Length
Assert-That  'the second animated'                          ((Get-FrameCount -Text $secondText -Message 'Second operation') -ge 1)
Assert-That  'and the second was cleared on stop'           (Test-LineWasCleared -Text $secondText)
Assert-That  'nothing is running at the end'                (-not (Test-DeltaActivityRunning))

Start-TestCase 'Stop-DeltaLog is a backstop for an abandoned activity'

$sink = New-ActivitySink
Start-DeltaActivity -Message 'Abandoned' -Writer $sink.Writer
Stop-DeltaLog -ExitCode 0
Assert-That 'closing the transcript stops a stray animation' (-not (Test-DeltaActivityRunning))
Assert-That 'and clears its line'                            (Test-LineWasCleared -Text (Get-SinkText -Sink $sink))

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
}
$emitted = Get-SinkText -Sink $sink
Assert-That 'the animation resumed after the interruption' ((Get-FrameCount -Text $emitted -Message 'Working') -ge 2)
Assert-That 'the animated line never wrote a newline'      (Test-StayedOnOneLine -Text $emitted)
Assert-That 'and finished cleared'                         (Test-LineWasCleared -Text $emitted)

# --- prompts ----------------------------------------------------------------

Start-TestCase 'No animation is ever running while a prompt waits for input'

# Read-Host cannot be driven from here, so each reader is called from a wrapper
# that defines its own Read-Host - the same technique the install-root suite
# uses - and that stand-in records the one thing this test is about: whether an
# animation was still live at the instant the prompt was displayed.
#
# There is a wrapper per reader rather than one that takes the reader as a
# scriptblock, because a scriptblock invoked with & runs against the scope it
# was WRITTEN in, which would put the stand-in out of reach and quietly test
# nothing at all.
$Script:RunningAtPrompt = $null
$Script:PromptCount = 0

function Start-PromptFixture {
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
        $Script:RunningAtPrompt = Test-DeltaActivityRunning
        return 'n'
    }
    try { $null = Read-DeltaInlineConfirmation -Prompt 'Restart Windows now? [y/N]' }
    finally { Stop-DeltaActivity }
}

function Invoke-DefaultYesAnswerWithLiveActivity {
    param([Parameter(Mandatory)][object]$Sink)
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        $Script:PromptCount++
        $Script:RunningAtPrompt = Test-DeltaActivityRunning
        return 'n'
    }
    try { $null = Read-DeltaDefaultYesAnswer -Prompt 'Use C:\DELTA? [Y/n]' }
    finally { Stop-DeltaActivity }
}

function Invoke-YesNoConfirmationWithLiveActivity {
    param([Parameter(Mandatory)][object]$Sink)
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        $Script:PromptCount++
        $Script:RunningAtPrompt = Test-DeltaActivityRunning
        return 'n'
    }
    try { $null = Read-DeltaYesNoConfirmation -Body { Write-Host 'Accept the licence?' } 6>$null }
    finally { Stop-DeltaActivity }
}

$sink = Start-PromptFixture
Invoke-InlineConfirmationWithLiveActivity -Sink $sink
Assert-Equal 'Read-DeltaInlineConfirmation reached its prompt' 1 $Script:PromptCount
Assert-Equal 'with no animation running'                       $false $Script:RunningAtPrompt
Assert-That  'and the animated line already erased'            (Test-LineWasCleared -Text (Get-SinkText -Sink $sink))

$sink = Start-PromptFixture
Invoke-DefaultYesAnswerWithLiveActivity -Sink $sink
Assert-Equal 'Read-DeltaDefaultYesAnswer reached its prompt'   1 $Script:PromptCount
Assert-Equal 'with no animation running'                       $false $Script:RunningAtPrompt
Assert-That  'and the animated line already erased'            (Test-LineWasCleared -Text (Get-SinkText -Sink $sink))

$sink = Start-PromptFixture
Invoke-YesNoConfirmationWithLiveActivity -Sink $sink
Assert-Equal 'Read-DeltaYesNoConfirmation reached its prompt'  1 $Script:PromptCount
Assert-Equal 'with no animation running'                       $false $Script:RunningAtPrompt
Assert-That  'and the animated line already erased'            (Test-LineWasCleared -Text (Get-SinkText -Sink $sink))

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
