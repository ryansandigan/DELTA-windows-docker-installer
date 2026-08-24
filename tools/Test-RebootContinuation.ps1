#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for the post-restart continuation: how it is registered,
    what it runs, how it elevates, and what it tells the operator when it
    cannot.

.DESCRIPTION
    The failure these cover, as an operator reported it on Windows 11:

        run setup.ps1
        -> a prerequisite needs a restart, and the restart is accepted
        -> sign back in
        -> "DELTA setup is continuing after the restart."
        -> "could not be started automatically: This command cannot be run due
            to the error: The operation was canceled by the user."
        -> a dead end

    That message is Win32 ERROR_CANCELLED (1223) coming back from ShellExecute.
    Windows returns it both when the operator declines the elevation prompt and
    when it cancels the prompt itself because the logon desktop was not ready
    to host one - and RunOnce fires while the logon is still in progress, so
    the second is a real possibility on a machine that has just restarted.

    The old continuation slept five seconds, asked once, and printed manual
    instructions that were themselves incomplete: they said `.\setup.ps1` on a
    machine whose execution policy blocks .ps1 files, which is the other half
    of the report.

    So the invariants pinned here are:

      - the continuation waits for the desktop shell rather than a fixed sleep;
      - it elevates, because setup.ps1 refuses to run unelevated and never
        elevates itself - so there is exactly one elevation, in the launcher;
      - a session that is already elevated does not ask a second time;
      - a refused elevation is recoverable at the operator's request and never
        retried on its own, because Windows cannot tell the test which of the
        two cancellations it was;
      - nothing anywhere persists an execution-policy change;
      - a path with spaces survives every layer of quoting.

    The function under test is the real Register-DeltaLogonContinuation, read
    out of setup.ps1 by the PowerShell parser rather than copied here. The
    script it generates is then decoded and really executed, with the host
    cmdlets it calls replaced by recording stand-ins - the same shadowing
    technique Test-UnattendedStartup.ps1 and Test-RuntimeSequencing.ps1 use.

    Nothing here restarts anything, writes to the real RunOnce key, shows a UAC
    prompt or starts a real process.

    WHAT THIS SUITE CANNOT DO: it cannot prove the elevation succeeds after a
    real Windows 11 restart. No UAC prompt is ever shown here and no logon ever
    happens. See "Manual validation" in README.md - a green run of this file is
    not a validated reboot.

    Exits 0 if every test passes, 1 otherwise.

.EXAMPLE
    .\tools\Test-RebootContinuation.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$Script:SetupPath   = Join-Path $Script:ProjectRoot 'setup.ps1'

$Script:Passed = 0
$Script:Failed = 0

. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')

# ---------------------------------------------------------------------------
# Assertion helpers (same shape as the other suites here)
# ---------------------------------------------------------------------------

function Assert-That {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()]$Condition
    )
    if ($Condition) { Write-Host "    [PASS] $Description" -ForegroundColor Green; $Script:Passed++ }
    else            { Write-Host "    [FAIL] $Description" -ForegroundColor Red;   $Script:Failed++ }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()]$Expected,
        [Parameter(Mandatory)][AllowNull()]$Actual
    )
    if ($Expected -eq $Actual) { Write-Host "    [PASS] $Description" -ForegroundColor Green; $Script:Passed++ }
    else {
        Write-Host "    [FAIL] $Description" -ForegroundColor Red
        Write-Host "           expected: [$Expected]" -ForegroundColor Red
        Write-Host "           actual:   [$Actual]"   -ForegroundColor Red
        $Script:Failed++
    }
}

function Start-TestCase {
    param([Parameter(Mandatory)][string]$Name)
    Write-Host ''
    Write-Host "==> $Name" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Spaces in both, deliberately, and in the two places they can break
# independently: the directory the continuation runs from, and the value it
# carries across the reboot.
$Script:SpacedRoot    = Join-Path ([System.IO.Path]::GetTempPath()) ("DELTA Continuation Tests\" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Script:SpacedInstall = 'D:\Program Files\DELTA Data'
$Script:PlainInstall  = 'C:\DELTA'

$null = New-Item -ItemType Directory -Path $Script:SpacedRoot -Force
Set-Content -LiteralPath (Join-Path $Script:SpacedRoot 'setup.ps1') -Value '# stand-in' -Encoding UTF8

$Script:SetupText = Get-Content -LiteralPath $Script:SetupPath -Raw
$Script:SetupAst  = [System.Management.Automation.Language.Parser]::ParseFile($Script:SetupPath, [ref]$null, [ref]$null)

function Get-SetupFunctionText {
    <#
      Lifts one function definition out of setup.ps1 by its parse tree. The
      parser rather than a regex, because a brace inside a comment or a string
      in that function would defeat brace counting - and the whole point is to
      test the code that ships, not a copy of it that drifted.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $found = @($Script:SetupAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true))

    if ($found.Count -ne 1) { throw "setup.ps1 should define $Name exactly once; found $($found.Count)." }
    return $found[0].Extent.Text
}

. ([scriptblock]::Create((Get-SetupFunctionText -Name 'Compress-DeltaContinuationScript')))
. ([scriptblock]::Create((Get-SetupFunctionText -Name 'Register-DeltaLogonContinuation')))

function New-Continuation {
    <#
      Runs the real generator against a stand-in registry and hands back both
      the raw RunOnce command and the script it encodes.
    #>
    param(
        [string]$ScriptRoot  = $Script:SpacedRoot,
        [string]$InstallRoot = $Script:PlainInstall
    )

    $Script:DeltaRunOnceKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $Script:DeltaRunOnceName = 'DELTASetupContinue'

    $captured = [PSCustomObject]@{ Written = $null; Key = $null; Name = $null }

    # Shadowed for this scope only: the real key is never opened, created or
    # written. A test that armed the operator's actual logon would be worse
    # than no test.
    #
    # Only the registry half is faked. Filesystem probes go to the real
    # Test-Path, because "is setup.ps1 actually there" is one of the things
    # under test and a blanket $true would answer it for the generator.
    function Test-Path {
        param($LiteralPath, $PathType)
        if ($LiteralPath -like 'HK*:*') { return $true }
        return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
    }
    function New-Item        { param($Path, [switch]$Force, $ErrorAction) return $null }
    function New-ItemProperty {
        param($LiteralPath, $Name, $Value, $PropertyType, [switch]$Force, $ErrorAction)
        $captured.Written = $Value
        $captured.Key     = $LiteralPath
        $captured.Name    = $Name
        return $null
    }

    $result = Register-DeltaLogonContinuation -ScriptRoot $ScriptRoot -InstallRoot $InstallRoot

    $inner = $null
    if ($captured.Written -match '-EncodedCommand\s+(\S+)\s*$') {
        $inner = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
    }

    return [PSCustomObject]@{
        Result  = $result
        Command = $captured.Written
        Key     = $captured.Key
        Name    = $captured.Name
        Inner   = $inner
    }
}

function Invoke-ContinuationScript {
    <#
      Really runs the generated script, in its own runspace, with every host
      call it makes replaced by a recorder.

      -Elevated decides which branch runs by swapping out the script's own
      elevation probe - again by parse tree, so the swap cannot silently miss
      and leave the real probe (and the test host's real token) deciding.

      -DialogAnswers does the same for the Windows dialog: a scripted list of
      button results, one per dialog raised, recorded along with the text each
      one showed. 'none' stands for a machine that cannot show a dialog at all,
      which is what makes the console fallback testable on a machine that can.
      With no list supplied the dialog is unavailable, so every test written
      before dialogs existed still exercises the console path it was written
      for.

      -Answers feeds Read-Host. -FailStarts makes the first N Start-Process
      calls throw the exact exception Windows raises when a UAC prompt is not
      approved, message and all.
    #>
    param(
        [Parameter(Mandatory)][string]$Inner,
        [bool]$Elevated = $false,
        [string[]]$Answers = @(),
        [string[]]$DialogAnswers = @(),
        [int]$FailStarts = 0
    )

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Inner, [ref]$null, [ref]$null)

    # Both seams are replaced the same way, by parse-tree extent, so a rename
    # in setup.ps1 fails this loudly rather than leaving the real function in
    # place - which for the dialog would mean a message box on a test run.
    $stubs = @{
        'Test-DeltaContinuationElevated' =
            "function Test-DeltaContinuationElevated { return `$$($Elevated.ToString().ToLowerInvariant()) }"
        'Show-DeltaContinuationDialog' = @'
function Show-DeltaContinuationDialog {
    param([string]$Text, [string]$Caption, [string]$Buttons = 'OKCancel', [string]$Icon)
    $null = $log.Dialogs.Add([PSCustomObject]@{ Text = $Text; Caption = $Caption; Buttons = $Buttons })
    if ($dialogQueue.Count -eq 0) { throw "The continuation raised more dialogs than the test scripted answers for. Last: $Caption" }
    # A trailing 'none' is sticky: a machine with no dialog support does not
    # acquire it half way through, so every later call answers the same way.
    # Scripted button results are consumed one per dialog, so raising more
    # dialogs than the test allowed for still fails loudly.
    $answer = if ($dialogQueue.Count -eq 1 -and $dialogQueue.Peek() -eq 'none') { $dialogQueue.Peek() }
              else { $dialogQueue.Dequeue() }
    if ($answer -eq 'none') { return $null }
    return $answer
}
'@
    }

    $targets = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $stubs.ContainsKey($_.Name) })

    foreach ($name in $stubs.Keys) {
        $count = @($targets | Where-Object { $_.Name -eq $name }).Count
        if ($count -ne 1) { throw "The generated script should define $name exactly once; found $count." }
    }

    # Replaced in descending offset order, so the offsets of the extents not
    # yet replaced are still valid against the text being edited.
    $patched = $Inner
    foreach ($node in ($targets | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $patched = $patched.Substring(0, $node.Extent.StartOffset) +
                   $stubs[$node.Name] +
                   $patched.Substring($node.Extent.EndOffset)
    }

    # A scriptblock's ToString() is its body, param block included, which is
    # exactly what AddScript wants.
    $harness = {
        param($ContinuationScript, $Answers, $DialogAnswers, $FailStarts)

        # A hashtable, not plain variables: the stand-ins below mutate it from
        # a child scope, and a bare assignment there would make a local copy
        # and quietly record nothing.
        $log = @{
            Starts     = [System.Collections.Generic.List[object]]::new()
            Prompts    = [System.Collections.Generic.List[string]]::new()
            Dialogs    = [System.Collections.Generic.List[object]]::new()
            Output     = [System.Collections.Generic.List[string]]::new()
            Removals   = [System.Collections.Generic.List[string]]::new()
            ShellPolls = 0
            Failures   = [int]$FailStarts
        }
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($a in $Answers) { $queue.Enqueue([string]$a) }

        # Nothing scripted means no dialog is available at all - the console
        # fallback - which is what every test written before this existed
        # expects to be exercising.
        $dialogQueue = [System.Collections.Generic.Queue[string]]::new()
        if (@($DialogAnswers).Count -eq 0) { $dialogQueue.Enqueue('none') }
        else { foreach ($d in $DialogAnswers) { $dialogQueue.Enqueue([string]$d) } }

        function Write-Host {
            param([Parameter(Position = 0)]$Object, $ForegroundColor, [switch]$NoNewline)
            $null = $log.Output.Add([string]$Object)
        }
        function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
        function Remove-ItemProperty {
            param($LiteralPath, $Name, $ErrorAction)
            $null = $log.Removals.Add("$LiteralPath::$Name")
        }
        function Read-Host {
            param([Parameter(Position = 0)]$Prompt)
            $null = $log.Prompts.Add([string]$Prompt)
            if ($queue.Count -eq 0) { throw "The continuation asked more questions than the test scripted answers for. Last prompt: $Prompt" }
            return $queue.Dequeue()
        }
        function Get-Process {
            param($Name, $Id, $ErrorAction)
            if ($PSBoundParameters.ContainsKey('Id')) { return [PSCustomObject]@{ SessionId = 1 } }
            $log.ShellPolls = $log.ShellPolls + 1
            return [PSCustomObject]@{ Name = 'explorer'; SessionId = 1 }
        }
        function Start-Process {
            param($FilePath, $Verb, $WorkingDirectory, $ArgumentList, $ErrorAction,
                  [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow)
            $null = $log.Starts.Add([PSCustomObject]@{
                FilePath         = $FilePath
                Verb             = $Verb
                WorkingDirectory = $WorkingDirectory
                ArgumentList     = $ArgumentList
            })
            if ($log.Failures -gt 0) {
                $log.Failures = $log.Failures - 1
                # The exact shape Start-Process raises when ShellExecute comes
                # back with ERROR_CANCELLED (1223) - which is what Windows
                # returns both for a declined prompt and for one it cancelled
                # itself. Same message, so the code cannot tell them apart.
                throw [System.InvalidOperationException]::new(
                    'This command cannot be run due to the error: The operation was canceled by the user.')
            }
            return $null
        }

        & ([scriptblock]::Create($ContinuationScript))
        return $log
    }

    $ps = [powershell]::Create()
    try {
        $null = $ps.AddScript($harness.ToString()).
            AddArgument($patched).AddArgument($Answers).AddArgument($DialogAnswers).AddArgument($FailStarts)
        $out = $ps.Invoke()

        # Anything the continuation wrote to the error stream is a defect in
        # the generated script, not noise to be swallowed.
        if ($ps.Streams.Error.Count -gt 0) {
            throw "The generated continuation raised: $($ps.Streams.Error[0])"
        }
        return @($out)[-1]
    }
    finally { $ps.Dispose() }
}

# ===========================================================================
# 1. What gets registered
# ===========================================================================

Start-TestCase 'The continuation is registered as a self-deleting RunOnce entry'

$c = New-Continuation

Assert-That  'registration succeeds'                $c.Result.Succeeded
Assert-Equal 'under HKCU, not HKLM'                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' $c.Key
Assert-That  'as RunOnce, not Run'                  ($c.Key -match 'RunOnce$')
Assert-Equal 'with the documented value name'       'DELTASetupContinue' $c.Name
Assert-That  'the command is an encoded one-liner'  ($c.Command -match '^powershell\.exe .*-EncodedCommand \S+$')
Assert-That  'and it decodes to a script'           ($null -ne $c.Inner)

# Windows deletes a RunOnce value before running it, and the script deletes it
# again first thing. Either alone stops a logon loop; both is the point.
Assert-That 'the script removes its own RunOnce value before anything else' `
    ($c.Inner -match "(?s)^[^\r\n]*WindowTitle[^\r\n]*\r?\nRemove-ItemProperty[^\r\n]*DELTASetupContinue")
# \s*$ rather than $: the generated script inherits setup.ps1's line endings,
# and .NET's multiline $ does not step over the CR of a CRLF pair.
Assert-That 'and a host with no console window does not derail it over a caption' `
    ($c.Inner -match "(?m)^try \{[^\r\n]*WindowTitle[^\r\n]*\} catch \{ \}\s*$")

Start-TestCase 'A missing setup.ps1 is refused rather than registered'

$missing = New-Continuation -ScriptRoot (Join-Path $Script:SpacedRoot 'no such directory')
Assert-That 'registration fails'          (-not $missing.Result.Succeeded)
Assert-That 'and says why'                ($missing.Result.Reason -match 'setup\.ps1 is not at')
Assert-Equal 'and nothing was written'    $null $missing.Command

# ===========================================================================
# 2. Execution policy: bypassed for the process, never for the machine
# ===========================================================================

Start-TestCase 'Both layers get a process-scoped execution-policy bypass'

Assert-That 'the RunOnce command itself bypasses'      ($c.Command -match '(?i)-ExecutionPolicy\s+Bypass')
Assert-That 'and it runs with -NoProfile'              ($c.Command -match '(?i)-NoProfile')
Assert-That 'the relaunched setup.ps1 bypasses too'    ($c.Inner  -match '(?i)-ExecutionPolicy\s+Bypass\s+-File')
Assert-That 'and it too runs with -NoProfile'          ($c.Inner  -match '(?i)-NoProfile\s+-ExecutionPolicy')

# The whole concession is that it lives in a process. Anything that writes the
# policy down is a change to a machine this installer does not own.
foreach ($scope in @('LocalMachine', 'CurrentUser', 'MachinePolicy', 'UserPolicy')) {
    Assert-That "setup.ps1 never sets the $scope execution policy" `
        ($Script:SetupText -notmatch "(?i)Set-ExecutionPolicy[^\r\n]*$scope")
    Assert-That "and neither does the generated continuation ($scope)" `
        ($c.Inner -notmatch "(?i)Set-ExecutionPolicy[^\r\n]*$scope")
}
Assert-That 'the continuation never calls Set-ExecutionPolicy at all - it only prints it' `
    ($c.Inner -notmatch "(?i)^\s*Set-ExecutionPolicy")

# Proven rather than asserted: a child started this way reports Bypass, and the
# persistent scopes come back untouched afterwards.
$before = (Get-ExecutionPolicy -Scope CurrentUser).ToString() + '/' + (Get-ExecutionPolicy -Scope LocalMachine).ToString()
$probe  = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'Get-ExecutionPolicy; Get-ExecutionPolicy -Scope CurrentUser; Get-ExecutionPolicy -Scope LocalMachine'
$after  = (Get-ExecutionPolicy -Scope CurrentUser).ToString() + '/' + (Get-ExecutionPolicy -Scope LocalMachine).ToString()

Assert-Equal 'a -ExecutionPolicy Bypass child is effectively Bypass' 'Bypass' ([string]$probe[0]).Trim()
Assert-Equal 'and the persistent scopes are unchanged by it'         $before  $after

# ===========================================================================
# 3. Quoting: paths with spaces
# ===========================================================================

Start-TestCase 'Paths with spaces survive every layer'

$spaced = New-Continuation -ScriptRoot $Script:SpacedRoot -InstallRoot $Script:SpacedInstall

$expectedSetup = Join-Path $Script:SpacedRoot 'setup.ps1'
Assert-That 'the -File path is quoted'        ($spaced.Inner -match [regex]::Escape('-File "' + $expectedSetup + '"'))
Assert-That 'the -InstallRoot value is quoted' ($spaced.Inner -match [regex]::Escape('-InstallRoot "' + $Script:SpacedInstall + '"'))
Assert-That 'the working directory is the installer directory' `
    ($spaced.Inner -match [regex]::Escape("`$scriptRoot = '" + $Script:SpacedRoot + "'"))

# The generated script has to be a script. A quote landing in the wrong place
# is a parse error at logon, on a machine with nobody able to read the window.
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($spaced.Inner, [ref]$null, [ref]$parseErrors)
Assert-Equal 'and the generated script parses cleanly' 0 $parseErrors.Count

# A quote inside the path is the case that ends a single-quoted literal early.
$quoted = New-Continuation -InstallRoot "D:\it's here\DELTA"
$qErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($quoted.Inner, [ref]$null, [ref]$qErrors)
Assert-Equal 'an apostrophe in the installation root does not break the script' 0 $qErrors.Count

# RunOnce hands its value to CreateProcess, which stops at 32767 characters.
Assert-That "the RunOnce command stays well inside the command-line limit ($($spaced.Command.Length) chars)" `
    ($spaced.Command.Length -lt 30000)

# ===========================================================================
# 4. Elevation
# ===========================================================================

Start-TestCase 'setup.ps1 requires elevation and never elevates itself'

# This is why the launcher must elevate, and it is also why adding elevation to
# setup.ps1 would be wrong: two self-elevating layers is two UAC prompts.
Assert-That 'setup.ps1 checks for Administrator'   ($Script:SetupText -match 'Test-IsAdministrator')
Assert-That 'and exits when it is not elevated'    ($Script:SetupText -match 'DeltaExitNotElevated')
# One elevating Start-Process in the whole installer. A second one anywhere -
# a self-elevating setup.ps1, an extra launcher - is a second UAC prompt.
#
# Counted over code only. The comments in setup.ps1 discuss -Verb RunAs by
# name, and a test that counted those would be pinned to the prose.
$Script:SetupCode = -join ([System.Management.Automation.PSParser]::Tokenize($Script:SetupText, [ref]$null) |
    Where-Object { $_.Type -ne 'Comment' } | ForEach-Object { $_.Content + ' ' })

Assert-Equal 'exactly one elevating Start-Process exists in setup.ps1 code' 1 `
    (@([regex]::Matches($Script:SetupCode, '(?i)Start-Process\b(?:(?!Start-Process).)*?-Verb\s+RunAs')).Count)

Start-TestCase 'An unelevated logon session gets exactly one UAC prompt'

$run = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false

Assert-Equal 'setup.ps1 is started once'        1 $run.Starts.Count
Assert-Equal 'through powershell.exe'           'powershell.exe' $run.Starts[0].FilePath
Assert-Equal 'elevated, via the RunAs verb'     'RunAs' $run.Starts[0].Verb
Assert-Equal 'from the installer directory'     $Script:SpacedRoot $run.Starts[0].WorkingDirectory
Assert-That  'with the execution-policy bypass' ($run.Starts[0].ArgumentList -match '(?i)-ExecutionPolicy\s+Bypass')
Assert-That  'and the persisted installation root' ($run.Starts[0].ArgumentList -match '(?i)-InstallRoot')
Assert-Equal 'nothing was asked of the operator' 0 $run.Prompts.Count
Assert-That  'the RunOnce value was removed'    ($run.Removals.Count -ge 1)
Assert-That  'the operator was told to expect the prompt' `
    (@($run.Output | Where-Object { $_ -match 'Approve the elevation prompt' }).Count -eq 1)

Start-TestCase 'An already-elevated session is not asked to elevate again'

$already = Invoke-ContinuationScript -Inner $c.Inner -Elevated $true

Assert-Equal 'setup.ps1 is still started once'   1 $already.Starts.Count
Assert-Equal 'but with no RunAs verb'            $null $already.Starts[0].Verb
Assert-Equal 'and no prompt is advertised'       0 (@($already.Output | Where-Object { $_ -match 'Approve the elevation prompt' }).Count)
Assert-That  'the operator is told why'          (@($already.Output | Where-Object { $_ -match 'already elevated' }).Count -eq 1)

Start-TestCase 'The continuation waits for the desktop shell rather than guessing'

Assert-That 'it polls for the shell in this logon session' ($run.ShellPolls -ge 1)
Assert-That 'the wait is bounded, not indefinite'          ($c.Inner -match '(?i)AddSeconds\(\s*90\s*\)')
Assert-That 'and the old blind five-second sleep is gone'  ($c.Inner -notmatch "(?m)^Start-Sleep -Seconds 5\s*$")

# ===========================================================================
# 5. A refused elevation
# ===========================================================================

Start-TestCase 'A cancelled UAC prompt is offered again, once, at the operator asking'

$retry = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false -FailStarts 1 -Answers @('')

Assert-Equal 'the first attempt is made and fails'  2 $retry.Starts.Count
Assert-Equal 'the operator is asked whether to retry' 1 $retry.Prompts.Count
Assert-That  'and the question is a plain yes/no'   ($retry.Prompts[0] -match '(?i)again\?\s*\[Y/n\]')
Assert-Equal 'the retry elevates too'               'RunAs' $retry.Starts[1].Verb
Assert-That  'the reported error is the one Windows gave' `
    (@($retry.Output | Where-Object { $_ -match 'operation was canceled by the user' }).Count -eq 1)
Assert-That  'and the operator is told Windows may have cancelled it, not them' `
    (@($retry.Output | Where-Object { $_ -match 'cancelled it itself|cancelled itself' }).Count -ge 1)

Start-TestCase 'Declining the retry stops cleanly - it does not loop'

$declined = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false -FailStarts 99 -Answers @('n', '')

Assert-Equal 'exactly one elevation was attempted' 1 $declined.Starts.Count
Assert-Equal 'the retry was offered exactly once'  1 `
    (@($declined.Prompts | Where-Object { $_ -match '(?i)elevation again' }).Count)
Assert-That  'and the window waits to be read rather than vanishing' `
    ($declined.Output -contains '  Press Enter to close this window.')
Assert-Equal 'the close prompt is the only other thing asked' 2 $declined.Prompts.Count

# The N answer is what stops it. Without a scripted answer the harness throws,
# so an accidental loop shows up as a failure here rather than as a hang.
Start-TestCase 'The retry is never automatic'

$looped = $null
try {
    $looped = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false -FailStarts 99 -Answers @('', '', 'n', '')
    Assert-Equal 'each retry costs one deliberate answer' 3 $looped.Starts.Count
}
catch {
    Assert-That "the continuation retried without asking: $($_.Exception.Message)" $false
}

# ===========================================================================
# 5b. The Windows dialog
#
# The division the dialog exists to draw: the PowerShell window is where the
# installer's execution and technical output go, and the dialog is where a
# request for human action goes. Everything below is about that one request -
# nothing else in the installer gained a dialog.
# ===========================================================================

Start-TestCase 'OK on the dialog elevates and starts setup, with one dialog and no console question'

$ok = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false -DialogAnswers @('ok')

Assert-Equal 'exactly one dialog was raised'   1 $ok.Dialogs.Count
Assert-Equal 'it offers OK and Cancel'         'OKCancel' $ok.Dialogs[0].Buttons
Assert-Equal 'setup.ps1 was started once'      1 $ok.Starts.Count
Assert-Equal 'elevated, via the RunAs verb'    'RunAs' $ok.Starts[0].Verb
Assert-That  'with the persisted installation root' ($ok.Starts[0].ArgumentList -match '(?i)-InstallRoot')
Assert-Equal 'and nothing was asked at the console' 0 $ok.Prompts.Count

$okText = $ok.Dialogs[0].Text
Assert-That 'the dialog says setup is ready to continue' ($okText -match 'ready to continue after the restart')
Assert-That 'it says OK continues'                       ($okText -match 'Click OK to continue')
Assert-That 'it warns that Windows will ask for permission' ($okText -match '(?s)Windows will ask for\s+administrator permission \(UAC\)')
Assert-That 'it says setup continues in a PowerShell window' ($okText -match 'PowerShell window')
Assert-That 'and it asks the operator not to close it'   ($okText -match 'Do not close the PowerShell window')

Start-TestCase 'Cancel is safe: nothing elevates, nothing re-registers, recovery is offered'

$cancel = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false -DialogAnswers @('cancel', 'ok') -Answers @('')

Assert-Equal 'nothing was started'                 0 $cancel.Starts.Count
Assert-Equal 'so no elevation was ever requested'  0 (@($cancel.Starts | Where-Object { $_.Verb -eq 'RunAs' }).Count)
Assert-Equal 'a second, informational dialog is shown' 2 $cancel.Dialogs.Count
Assert-Equal 'with a single OK button'             'OK' $cancel.Dialogs[1].Buttons

$cancelText = $cancel.Dialogs[1].Text
Assert-That 'it says the installation is incomplete' ($cancelText -match 'DELTA installation is still incomplete')
Assert-That 'and how to continue later'             ($cancelText -match '(?s)running setup\.ps1 again\s+as Administrator')

# Cancelling is not a failure state. The RunOnce value was consumed before any
# of this, nothing re-registers it, and the console still carries the manual
# commands - so the operator is never left without a way back in.
Assert-That 'the RunOnce value was still consumed'  ($cancel.Removals.Count -ge 1)
$cancelConsole = ($cancel.Output -join "`n")
Assert-That 'the console says nothing was changed'  ($cancelConsole -match 'Nothing was changed on this machine')
Assert-That 'and still prints the manual commands'  ($cancelConsole -match [regex]::Escape('Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass'))
Assert-That 'including the real installer directory' ($cancelConsole -match [regex]::Escape('cd "' + $Script:SpacedRoot + '"'))

Start-TestCase 'An already-elevated session is told the truth and gets no second UAC'

$elevatedOk = Invoke-ContinuationScript -Inner $c.Inner -Elevated $true -DialogAnswers @('ok')

Assert-Equal 'setup.ps1 was started once' 1 $elevatedOk.Starts.Count
Assert-Equal 'with no RunAs verb'         $null $elevatedOk.Starts[0].Verb
Assert-Equal 'and one dialog only'        1 $elevatedOk.Dialogs.Count

# The wording must not promise a prompt that is never coming. This is the
# assertion that stops the two messages being merged into one later.
$elevatedText = $elevatedOk.Dialogs[0].Text
Assert-That 'it does not claim Windows will ask for permission' ($elevatedText -notmatch '(?i)UAC|administrator permission')
Assert-That 'it still says OK continues the installation'       ($elevatedText -match 'Click OK to continue the installation')
Assert-That 'and still asks for patience with the window'       ($elevatedText -match 'do not close it until setup finishes')

Start-TestCase 'Cancel from an already-elevated session is equally safe'

$elevatedCancel = Invoke-ContinuationScript -Inner $c.Inner -Elevated $true -DialogAnswers @('cancel', 'ok') -Answers @('')
Assert-Equal 'nothing was started' 0 $elevatedCancel.Starts.Count
Assert-That  'and the recovery dialog is the same one' `
    ($elevatedCancel.Dialogs[1].Text -match 'DELTA installation is still incomplete')

Start-TestCase 'A machine that cannot show a dialog falls back to the console, unchanged'

# 'none' is a machine where System.Windows.Forms will not load. The dialog is
# skipped entirely and the operator gets exactly the console flow that existed
# before dialogs did - which is the point: a GUI failure must never be what
# stops DELTA being resumed.
$noGui = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false

Assert-Equal 'setup.ps1 was still started'       1 $noGui.Starts.Count
Assert-Equal 'still elevated'                    'RunAs' $noGui.Starts[0].Verb
Assert-Equal 'nothing was asked at the console'  0 $noGui.Prompts.Count
Assert-That  'and the console still explains the prompt' `
    (@($noGui.Output | Where-Object { $_ -match 'Approve the elevation prompt' }).Count -eq 1)

# A dialog that fails half way through is the same story: still resumable.
Start-TestCase 'A dialog that stops working mid-flow still leaves a usable console path'

$halfGui = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false `
    -DialogAnswers @('ok', 'none') -FailStarts 99 -Answers @('n', '')

Assert-Equal 'the elevation was attempted once'   1 $halfGui.Starts.Count
Assert-That  'the console asked about retrying'   (@($halfGui.Prompts | Where-Object { $_ -match '(?i)elevation again' }).Count -eq 1)
Assert-That  'and the manual commands were printed' (($halfGui.Output -join "`n") -match [regex]::Escape('Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass'))

Start-TestCase 'A declined UAC offers one deliberate retry through the dialog, and never loops'

$retryGui = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false -DialogAnswers @('ok', 'yes') -FailStarts 1

Assert-Equal 'the first attempt failed and a second was made' 2 $retryGui.Starts.Count
Assert-Equal 'both were elevation requests'                   2 (@($retryGui.Starts | Where-Object { $_.Verb -eq 'RunAs' }).Count)
Assert-Equal 'the retry was asked for in a dialog'            2 $retryGui.Dialogs.Count
Assert-Equal 'as a yes/no question'                           'YesNo' $retryGui.Dialogs[1].Buttons
Assert-Equal 'and never at the console'                       0 $retryGui.Prompts.Count

$retryText = $retryGui.Dialogs[1].Text
Assert-That 'the retry dialog says setup did not start'  ($retryText -match 'DELTA setup did not start')
Assert-That 'and that Windows may have cancelled it'     ($retryText -match 'Windows cancels its')
Assert-That 'and asks before asking again'               ($retryText -match 'Ask Windows for administrator permission again')

Start-TestCase 'Declining the retry dialog stops - it does not ask again on its own'

$retryNo = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false `
    -DialogAnswers @('ok', 'no') -FailStarts 99 -Answers @('')

Assert-Equal 'exactly one elevation was attempted' 1 $retryNo.Starts.Count
Assert-Equal 'the retry was offered exactly once'  1 (@($retryNo.Dialogs | Where-Object { $_.Buttons -eq 'YesNo' }).Count)
Assert-That  'and the window waits to be read'     ($retryNo.Output -contains '  Press Enter to close this window.')

# The harness throws if more dialogs are raised than scripted, so an automatic
# re-prompt shows up here as a failure rather than as a hang.
Start-TestCase 'Repeated failures never produce an unattended UAC loop'

$loopGuard = $null
try {
    $loopGuard = Invoke-ContinuationScript -Inner $c.Inner -Elevated $false `
        -DialogAnswers @('ok', 'yes', 'yes', 'no') -FailStarts 99 -Answers @('')
    Assert-Equal 'each retry cost one deliberate Yes' 3 $loopGuard.Starts.Count
}
catch {
    Assert-That "the continuation re-prompted without being asked: $($_.Exception.Message)" $false
}

Start-TestCase 'The dialog is raised only after the desktop is ready'

# The whole reason the wait exists: a consent prompt - and now a dialog -
# raised before the shell is up is one nobody sees.
$order = $c.Inner.IndexOf('Get-Process -Name ''explorer''')
$dialogAt = $c.Inner.IndexOf('Show-DeltaContinuationDialog -Text')
Assert-That 'the shell wait comes first'  (($order -ge 0) -and ($dialogAt -gt $order))

Assert-That 'the dialog is raised on a TopMost owner so it cannot open behind Explorer' `
    ($c.Inner -match '(?s)Show-DeltaContinuationDialog.*?TopMost\s*=\s*\$true')

# The title is the function's default rather than something each caller
# repeats, so it is pinned where it actually lives.
Assert-That 'the documented title is the dialog default' `
    ($c.Inner -match [regex]::Escape("`$Caption = 'DELTA Setup - Continue Installation'"))
Assert-That 'and any dialog failure returns $null rather than throwing' `
    ($c.Inner -match '(?s)function Show-DeltaContinuationDialog.*?catch \{\s*return \$null\s*\}')

# The two conditions under which a message box does not fail but HANGS, so a
# catch around it would never fire. Both are refused before anything is shown.
Assert-That 'a non-STA thread is refused before any dialog is attempted' `
    ($c.Inner -match "GetApartmentState\(\) -ne 'STA'\) \{ return \`$null \}")
Assert-That 'and a non-interactive session is refused too' `
    ($c.Inner -match '(?s)UserInteractive\) \{ return \$null \}')

Start-TestCase 'The real dialog function returns rather than hanging when it cannot be shown'

# Behavioural, against the REAL Show-DeltaContinuationDialog rather than the
# stub: run it on an MTA thread, where MessageBox blocks indefinitely instead
# of throwing. It must come back, with $null, so the console path can run.
$innerAst = [System.Management.Automation.Language.Parser]::ParseInput($c.Inner, [ref]$null, [ref]$null)
$dialogSource = @($innerAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Show-DeltaContinuationDialog'
}, $true))[0].Extent.Text

$mta = [powershell]::Create()
$null = $mta.AddScript(@"
$dialogSource
return (Show-DeltaContinuationDialog -Text 'DELTA test - this window must never appear' -Buttons 'OKCancel')
"@)
$mta.Runspace = [runspacefactory]::CreateRunspace()
$mta.Runspace.ApartmentState = 'MTA'
$mta.Runspace.Open()

try {
    $async = $mta.BeginInvoke()
    if ($async.AsyncWaitHandle.WaitOne(20000)) {
        $mtaResult = @($mta.EndInvoke($async))
        Assert-That 'it returns instead of blocking the resume' $true
        # $null is the "no dialog here" contract; the console path reads it as
        # "the operator was never asked" and runs exactly as it always did.
        Assert-That 'and reports no dialog, so the console takes over' `
            (($mtaResult.Count -eq 0) -or ($null -eq $mtaResult[0]))
    }
    else {
        $mta.Stop()
        Assert-That 'it returns instead of blocking the resume' $false
    }
}
finally {
    try { $mta.Runspace.Close() } catch { }
    try { $mta.Dispose() } catch { }
}

# ===========================================================================
# 6. The manual fallback
# ===========================================================================

Start-TestCase 'The fallback instructions are complete enough to work'

$text = ($declined.Output -join "`n")

Assert-That 'it says to open PowerShell as Administrator' ($text -match '(?i)Run as administrator')
Assert-That 'it gives the real installer directory'       ($text -match [regex]::Escape('cd "' + $Script:SpacedRoot + '"'))
Assert-That 'it includes the process-scoped bypass'       ($text -match [regex]::Escape('Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass'))
Assert-That 'then it runs setup.ps1'                      ($text -match '(?m)^\s+\.\\setup\.ps1')
Assert-That 'and it explains that -Scope Process is temporary' ($text -match '(?i)that one PowerShell window only')
Assert-That 'and names the error it prevents'             ($text -match '(?i)running scripts is disabled on this system')

# The order matters: cd, then the bypass, then the script. Bypassing after the
# failed run is instructions that do not work when followed top to bottom.
$cdAt     = $text.IndexOf('cd "')
$policyAt = $text.IndexOf('Set-ExecutionPolicy -Scope Process')
$runAt    = $text.IndexOf('.\setup.ps1')
Assert-That 'the three lines are in a runnable order' (($cdAt -lt $policyAt) -and ($policyAt -lt $runAt))

Assert-That 'and the fallback never suggests a persistent scope' `
    ($text -notmatch '(?i)-Scope\s+(LocalMachine|CurrentUser)')

Start-TestCase 'A non-default installation root is carried into the fallback too'

$spacedRun = Invoke-ContinuationScript -Inner $spaced.Inner -Elevated $false -FailStarts 99 -Answers @('n', '')
$spacedText = ($spacedRun.Output -join "`n")

Assert-That 'the manual command keeps -InstallRoot' `
    ($spacedText -match [regex]::Escape('.\setup.ps1 -InstallRoot "' + $Script:SpacedInstall + '"'))

# ...and the default root does not get a redundant switch bolted on.
Assert-That 'the default root is left implicit' ($text -notmatch '(?i)setup\.ps1 -InstallRoot')

# ===========================================================================
# 7. setup.ps1's own instructions say the same thing
# ===========================================================================

Start-TestCase 'Every "run it by hand" instruction comes from one place'

Assert-That 'setup.ps1 defines the shared helper' `
    ($Script:SetupText -match 'function Write-DeltaManualRerunCommands')
Assert-That 'the elevation refusal uses it' `
    ($Script:SetupText -match '(?s)This installer must run as Administrator.*?Write-DeltaManualRerunCommands')
Assert-That 'the helper prints the process-scoped bypass' `
    ($Script:SetupText -match "(?s)function Write-DeltaManualRerunCommands.*?Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass")

# Behavioural, not textual: run the helper and read what it printed.
. ([scriptblock]::Create((Get-SetupFunctionText -Name 'Write-DeltaManualRerunCommands')))
$lines = [System.Collections.Generic.List[string]]::new()
function Write-Detail { param([Parameter(Position = 0)]$Message) $null = $lines.Add([string]$Message) }

Write-DeltaManualRerunCommands -ScriptRoot $Script:SpacedRoot -InstallRoot $Script:PlainInstall
$helperText = ($lines -join "`n")

Assert-That 'the helper cds to the installer directory' ($helperText -match [regex]::Escape('cd "' + $Script:SpacedRoot + '"'))
Assert-That 'sets the process-scoped policy'            ($helperText -match [regex]::Escape('Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass'))
Assert-That 'runs setup.ps1'                            ($helperText -match '(?m)\.\\setup\.ps1\s*$')
Assert-That 'and says the change is not persistent' `
    ($helperText -match '(?i)does not change the execution policy for your account or for this machine')

$lines.Clear()
Write-DeltaManualRerunCommands -ScriptRoot $Script:SpacedRoot -InstallRoot $Script:SpacedInstall
Assert-That 'a custom root is echoed back, quoted' `
    ((($lines -join "`n")) -match [regex]::Escape('.\setup.ps1 -InstallRoot "' + $Script:SpacedInstall + '"'))

# ===========================================================================
# 8. The existing state-recovery contract still holds
# ===========================================================================

Start-TestCase 'The resumed run still finds the state it left behind'

# There is deliberately no step-specific resume file. The continuation reruns
# the same script against the same root, and the installer's own detection
# decides - so this asserts the two things that carry, and the absence of a
# third mechanism that would need keeping in step with them.
Assert-That 'the same setup.ps1 is what gets rerun' `
    ($spaced.Inner -match [regex]::Escape('-File "' + $expectedSetup + '"'))
Assert-That 'the resolved installation root travels with it' `
    ($spaced.Inner -match [regex]::Escape('-InstallRoot "' + $Script:SpacedInstall + '"'))
Assert-That 'the root is resolved before the continuation is registered' `
    ($Script:SetupText.IndexOf('$InstallRoot = $rootChoice.Path') -lt $Script:SetupText.IndexOf('Request-DeltaWindowsRestart `'))
Assert-That 'the continuation is registered only after an explicit restart confirmation' `
    ($Script:SetupText -match '(?s)Read-DeltaInlineConfirmation -Prompt ''Restart Windows now.*?Register-DeltaLogonContinuation')
Assert-That 'and a restart that does not happen removes it again' `
    ($Script:SetupText -match '(?s)catch\s*\{[^}]*Unregister-DeltaLogonContinuation')

Assert-That 'the relaunch keeps the window open so a failure can be read' `
    ($c.Inner -match '(?i)-NoExit')

# --- teardown ---------------------------------------------------------------

Remove-Item -LiteralPath (Split-Path -Parent $Script:SpacedRoot) -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('-' * 60)
Write-Host "  passed: $Script:Passed"
Write-Host "  failed: $Script:Failed"
Write-Host ('-' * 60)
Write-Host ''
Write-Host '  Not covered here, and not coverable here: a real Windows restart,'
Write-Host '  a real logon, and a real UAC prompt. See the manual validation'
Write-Host '  procedure in README.md before calling a reboot fix verified.'
Write-Host ''

if ($Script:Failed -gt 0) { exit 1 }
exit 0
