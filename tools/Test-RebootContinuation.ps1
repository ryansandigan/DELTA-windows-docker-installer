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

      -Answers feeds Read-Host. -FailStarts makes the first N Start-Process
      calls throw the exact exception Windows raises when a UAC prompt is not
      approved, message and all.
    #>
    param(
        [Parameter(Mandatory)][string]$Inner,
        [bool]$Elevated = $false,
        [string[]]$Answers = @(),
        [int]$FailStarts = 0
    )

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Inner, [ref]$null, [ref]$null)
    $probe = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-DeltaContinuationElevated'
    }, $true))
    if ($probe.Count -ne 1) { throw "The generated script should define Test-DeltaContinuationElevated exactly once; found $($probe.Count)." }

    $extent = $probe[0].Extent
    $stub   = "function Test-DeltaContinuationElevated { return `$$($Elevated.ToString().ToLowerInvariant()) }"
    $patched = $Inner.Substring(0, $extent.StartOffset) + $stub + $Inner.Substring($extent.EndOffset)

    # A scriptblock's ToString() is its body, param block included, which is
    # exactly what AddScript wants.
    $harness = {
        param($ContinuationScript, $Answers, $FailStarts)

        # A hashtable, not plain variables: the stand-ins below mutate it from
        # a child scope, and a bare assignment there would make a local copy
        # and quietly record nothing.
        $log = @{
            Starts     = [System.Collections.Generic.List[object]]::new()
            Prompts    = [System.Collections.Generic.List[string]]::new()
            Output     = [System.Collections.Generic.List[string]]::new()
            Removals   = [System.Collections.Generic.List[string]]::new()
            ShellPolls = 0
            Failures   = [int]$FailStarts
        }
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($a in $Answers) { $queue.Enqueue([string]$a) }

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
            AddArgument($patched).AddArgument($Answers).AddArgument($FailStarts)
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
