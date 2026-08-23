#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for interactive installation-root selection.

.DESCRIPTION
    setup.ps1 used to assume C:\DELTA silently on a new installation. It now
    offers it, and an operator who declines picks a directory from a folder
    dialog - never by typing a path at the prompt.

    That decision has more ways to go wrong than it has lines of code, and most
    of them are invisible until an installation has already gone somewhere
    nobody chose. The cases that matter, all covered below:

      - Enter accepts the default. So does Y, and yes.
      - Declining opens the dialog, and what the dialog returns is what gets
        installed into.
      - Cancelling the dialog returns to the question. It does NOT cancel the
        installation, and it does NOT silently fall through to C:\DELTA.
      - A directory the validator rejects returns to the question too, rather
        than being accepted and failing later.
      - An explicit -InstallRoot asks nothing and opens nothing.
      - -NonInteractive NEVER opens a window. A modal dialog on an unattended
        run hangs it until somebody walks to the machine.
      - An existing installation at the default root is not re-litigated.
      - A host that cannot show a dialog (Server Core, non-STA) does not ask a
        question whose second answer it could not accept.
      - The chosen root survives the prerequisite reboot, which is the whole
        point of resolving it before the continuation is registered.

    Every probe is injected: Resolve-DeltaInstallRoot takes the prompt, the
    folder dialog, the dialog-support test and the state classification as
    scriptblocks, so all of it runs offline on one machine and no dialog is
    ever really opened.

    Deliberately dependency-free, matching the other suites here: no Pester, no
    modules, no network, and nothing that changes this host - no installation
    root is created and the registry is never written to.

    Exits 0 if every test passes, 1 otherwise.

.EXAMPLE
    .\tools\Test-InstallRootSelection.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$Script:Passed = 0
$Script:Failed = 0

. (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')

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

$Script:DefaultRoot = 'C:\DELTA'

# A directory that really exists, on a real fixed volume, and is really
# writable - so Test-DeltaInstallRootCandidate -TestWritable passes it for the
# reason it is supposed to rather than because the test avoided the probe.
$Script:CustomRoot = Join-Path $env:TEMP "delta-root-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$null = New-Item -ItemType Directory -Path $Script:CustomRoot -Force

# Rejected on its path alone, so nothing is reached over the network.
$Script:UncRoot = '\\fileserver\delta'

function New-Recorder {
    <#
      A scriptblock plus the record of how it was called. The "never opened a
      window" assertions are only worth anything if something is actually
      counting, and these count.
    #>
    param([Parameter(Mandatory)][scriptblock]$Behaviour)

    $state = [PSCustomObject]@{ Calls = [System.Collections.Generic.List[object]]::new(); Block = $null }
    $state.Block = {
        param($a, $b)
        $null = $state.Calls.Add(@($a, $b))
        return (& $Behaviour $a $b)
    }.GetNewClosure()
    return $state
}

function New-AnswerReader {
    <#
      Replays a fixed list of answers, one per prompt, and fails loudly if the
      resolver asks more times than the test scripted. A test whose reader ran
      dry used to loop until the attempt cap and then report the default, which
      looks exactly like a pass for the wrong reason.
    #>
    # An empty list is the point of several tests: it asserts that nothing was
    # asked by making any question at all throw.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Answers)

    $state = [PSCustomObject]@{
        Remaining = [System.Collections.Generic.Queue[string]]::new()
        Prompts   = [System.Collections.Generic.List[string]]::new()
        Block     = $null
    }
    foreach ($a in $Answers) { $state.Remaining.Enqueue($a) }

    $state.Block = {
        param($prompt)
        $null = $state.Prompts.Add([string]$prompt)
        if ($state.Remaining.Count -eq 0) { throw "The resolver asked more questions than the test scripted answers for. Last prompt: $prompt" }
        return $state.Remaining.Dequeue()
    }.GetNewClosure()
    return $state
}

$Script:SupportedDialog   = { $true }
$Script:UnsupportedDialog = { $false }
$Script:NoInstallation    = { param($path) 'none' }

# --- Read-DeltaDefaultYesAnswer ---------------------------------------------

Start-TestCase 'Read-DeltaDefaultYesAnswer maps the answers a [Y/n] prompt gets'

# Read-Host cannot be driven from here, so the mapping is exercised through the
# same branch table the function uses, by calling it with a stubbed Read-Host.
function Test-AnswerMapping {
    param([string]$Typed)
    $script:StubbedAnswer = $Typed
    # A local Read-Host shadows the cmdlet for the duration of this scope only.
    function Read-Host { param([string]$Prompt) return $script:StubbedAnswer }
    return (Read-DeltaDefaultYesAnswer -Prompt 'q' 6>$null)
}

Assert-Equal 'bare Enter means yes'          'yes'          (Test-AnswerMapping -Typed '')
Assert-Equal 'whitespace alone means yes'    'yes'          (Test-AnswerMapping -Typed '   ')
Assert-Equal 'Y means yes'                   'yes'          (Test-AnswerMapping -Typed 'Y')
Assert-Equal 'lowercase y means yes'         'yes'          (Test-AnswerMapping -Typed 'y')
Assert-Equal 'yes means yes'                 'yes'          (Test-AnswerMapping -Typed 'yes')
Assert-Equal 'N means no'                    'no'           (Test-AnswerMapping -Typed 'N')
Assert-Equal 'lowercase n means no'          'no'           (Test-AnswerMapping -Typed 'n')
Assert-Equal 'no means no'                   'no'           (Test-AnswerMapping -Typed 'no')
Assert-Equal 'garbage is not folded into yes or no' 'unrecognised' (Test-AnswerMapping -Typed 'maybe')

# --- default acceptance -----------------------------------------------------

Start-TestCase 'Enter accepts the default installation root'

$reader = New-AnswerReader -Answers @('yes')
$picker = New-Recorder -Behaviour { param($d, $i) throw 'The folder dialog must not open when the default is accepted.' }

$result = Resolve-DeltaInstallRoot -DefaultRoot $Script:DefaultRoot -AllowPrompt $true `
    -Reader $reader.Block -FolderPicker $picker.Block -DialogProbe $Script:SupportedDialog -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'the default root is used'  $Script:DefaultRoot $result.Path
Assert-Equal 'reported as the default'   'default'          $result.Source
Assert-That  'the operator was asked'    $result.Asked
Assert-Equal 'asked exactly once'        1                  $reader.Prompts.Count
Assert-Equal 'no dialog was opened'      0                  $picker.Calls.Count
Assert-That  'the prompt names the default root and offers [Y/n]' `
    ($reader.Prompts[0] -eq "Use $Script:DefaultRoot as the installation directory? [Y/n]")

# --- custom selection -------------------------------------------------------

Start-TestCase 'Declining the default opens a folder dialog and uses what it returns'

$reader = New-AnswerReader -Answers @('no')
$picker = New-Recorder -Behaviour { param($d, $i) return $Script:CustomRoot }

$result = Resolve-DeltaInstallRoot -DefaultRoot $Script:DefaultRoot -AllowPrompt $true `
    -Reader $reader.Block -FolderPicker $picker.Block -DialogProbe $Script:SupportedDialog -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'the selected directory is used' $Script:CustomRoot $result.Path
Assert-Equal 'reported as selected'           'selected'         $result.Source
Assert-Equal 'the dialog was opened once'     1                  $picker.Calls.Count
Assert-That  'the dialog was seeded with the default root' ($picker.Calls[0][1] -eq $Script:DefaultRoot)

# --- dialog cancellation returns to the question ----------------------------

Start-TestCase 'Cancelling the folder dialog returns to the question, and does not cancel the install'

$reader = New-AnswerReader -Answers @('no', 'yes')
$picker = New-Recorder -Behaviour { param($d, $i) return $null }   # cancelled

$result = Resolve-DeltaInstallRoot -DefaultRoot $Script:DefaultRoot -AllowPrompt $true `
    -Reader $reader.Block -FolderPicker $picker.Block -DialogProbe $Script:SupportedDialog -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'the question was asked again'        2                  $reader.Prompts.Count
Assert-Equal 'the second answer settled it'        $Script:DefaultRoot $result.Path
Assert-Equal 'reported as the default'             'default'          $result.Source
Assert-That  'nothing reported a cancelled install' ($null -ne $result.Path)

Start-TestCase 'Cancelling once, then choosing, still ends on the chosen directory'

$reader = New-AnswerReader -Answers @('no', 'no')
$Script:CancelThenChoose = 0
$picker = New-Recorder -Behaviour {
    param($d, $i)
    $Script:CancelThenChoose++
    if ($Script:CancelThenChoose -eq 1) { return $null }
    return $Script:CustomRoot
}

$result = Resolve-DeltaInstallRoot -DefaultRoot $Script:DefaultRoot -AllowPrompt $true `
    -Reader $reader.Block -FolderPicker $picker.Block -DialogProbe $Script:SupportedDialog -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'the dialog opened twice'      2                  $picker.Calls.Count
Assert-Equal 'the chosen directory is used' $Script:CustomRoot $result.Path
Assert-Equal 'reported as selected'         'selected'         $result.Source

# --- validation of the selected directory -----------------------------------

Start-TestCase 'A directory the validator rejects goes back to the question'

$reader = New-AnswerReader -Answers @('no', 'yes')
$picker = New-Recorder -Behaviour { param($d, $i) return $Script:UncRoot }

$result = Resolve-DeltaInstallRoot -DefaultRoot $Script:DefaultRoot -AllowPrompt $true `
    -Reader $reader.Block -FolderPicker $picker.Block -DialogProbe $Script:SupportedDialog -StateProbe $Script:NoInstallation 6>$null

Assert-That  'the UNC path is rejected by the validator' (-not (Test-DeltaInstallRootCandidate -Path $Script:UncRoot).IsValid)
Assert-Equal 'the rejected path was not accepted'        $Script:DefaultRoot $result.Path
Assert-Equal 'the question was asked again'              2                   $reader.Prompts.Count

Start-TestCase 'An unrecognised answer re-asks rather than guessing'

$reader = New-AnswerReader -Answers @('maybe', 'wat', 'yes')
$picker = New-Recorder -Behaviour { param($d, $i) throw 'No dialog should open for an unrecognised answer.' }

$result = Resolve-DeltaInstallRoot -DefaultRoot $Script:DefaultRoot -AllowPrompt $true `
    -Reader $reader.Block -FolderPicker $picker.Block -DialogProbe $Script:SupportedDialog -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'asked until it got an answer' 3                  $reader.Prompts.Count
Assert-Equal 'the default is used'          $Script:DefaultRoot $result.Path
Assert-Equal 'no dialog was opened'         0                  $picker.Calls.Count

# --- explicit -InstallRoot --------------------------------------------------

Start-TestCase 'An explicit -InstallRoot asks nothing and opens nothing'

$reader = New-AnswerReader -Answers @()
$picker = New-Recorder -Behaviour { param($d, $i) throw 'The folder dialog must not open when -InstallRoot was supplied.' }
$probe  = New-Recorder -Behaviour { param($d, $i) throw 'The dialog-support probe must not run when -InstallRoot was supplied.' }

$result = Resolve-DeltaInstallRoot -DefaultRoot 'D:\Applications\DELTA' -WasSupplied -AllowPrompt $true `
    -Reader $reader.Block -FolderPicker $picker.Block -DialogProbe $probe.Block -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'the supplied root is used'   'D:\Applications\DELTA' $result.Path
Assert-Equal 'reported as supplied'        'supplied'              $result.Source
Assert-That  'the operator was not asked'  (-not $result.Asked)
Assert-Equal 'no question was asked'       0                       $reader.Prompts.Count
Assert-Equal 'no dialog was opened'        0                       $picker.Calls.Count

# --- non-interactive --------------------------------------------------------

Start-TestCase '-NonInteractive never opens a GUI and keeps the previous behaviour'

$reader = New-AnswerReader -Answers @()
$picker = New-Recorder -Behaviour { param($d, $i) throw 'A non-interactive run must never open a window.' }
$probe  = New-Recorder -Behaviour { param($d, $i) throw 'A non-interactive run must not even probe for a dialog.' }

$result = Resolve-DeltaInstallRoot -DefaultRoot $Script:DefaultRoot -AllowPrompt $false `
    -Reader $reader.Block -FolderPicker $picker.Block -DialogProbe $probe.Block -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'the default root is used'   $Script:DefaultRoot $result.Path
Assert-Equal 'reported as non-interactive' 'non-interactive'  $result.Source
Assert-Equal 'no question was asked'      0                   $reader.Prompts.Count
Assert-Equal 'no dialog was opened'       0                   $picker.Calls.Count

Start-TestCase '-NonInteractive with a supplied root still uses the supplied root'

$result = Resolve-DeltaInstallRoot -DefaultRoot 'E:\DELTA' -WasSupplied -AllowPrompt $false `
    -Reader (New-AnswerReader -Answers @()).Block `
    -FolderPicker { param($d, $i) throw 'no' } -DialogProbe { throw 'no' } -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'the supplied root wins' 'E:\DELTA' $result.Path
Assert-Equal 'reported as supplied'   'supplied' $result.Source

# --- existing installations -------------------------------------------------

Start-TestCase 'An existing installation at the default root is not asked about again'

foreach ($state in @('installed', 'partial', 'installed-stopped', 'docker-unavailable')) {
    $reader = New-AnswerReader -Answers @()
    $picker = New-Recorder -Behaviour { param($d, $i) throw 'An existing installation must not be re-litigated with a dialog.' }

    $result = Resolve-DeltaInstallRoot -DefaultRoot $Script:DefaultRoot -AllowPrompt $true `
        -Reader $reader.Block -FolderPicker $picker.Block -DialogProbe $Script:SupportedDialog `
        -StateProbe { param($path) $state }.GetNewClosure() 6>$null

    Assert-Equal "state '$state' keeps the known root" $Script:DefaultRoot $result.Path
    Assert-Equal "state '$state' is reported as existing" 'existing'       $result.Source
    Assert-Equal "state '$state' asks nothing"            0                $reader.Prompts.Count
}

Start-TestCase "State 'none' is the only one that asks"

$reader = New-AnswerReader -Answers @('yes')
$result = Resolve-DeltaInstallRoot -DefaultRoot $Script:DefaultRoot -AllowPrompt $true `
    -Reader $reader.Block -FolderPicker { param($d, $i) $null } -DialogProbe $Script:SupportedDialog `
    -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'a fresh machine is asked' 1 $reader.Prompts.Count

# --- hosts with no dialog ---------------------------------------------------

Start-TestCase 'A host that cannot show a dialog does not ask an unanswerable question'

$reader = New-AnswerReader -Answers @()
$picker = New-Recorder -Behaviour { param($d, $i) throw 'No dialog can be opened on this host, so none must be attempted.' }

$result = Resolve-DeltaInstallRoot -DefaultRoot $Script:DefaultRoot -AllowPrompt $true `
    -Reader $reader.Block -FolderPicker $picker.Block -DialogProbe $Script:UnsupportedDialog -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'the default root is used' $Script:DefaultRoot $result.Path
Assert-Equal 'reported as no-dialog'    'no-dialog'         $result.Source
Assert-Equal 'no question was asked'    0                   $reader.Prompts.Count
Assert-Equal 'no dialog was opened'     0                   $picker.Calls.Count

# --- the chosen root survives the prerequisite reboot -----------------------

Start-TestCase 'The chosen root survives the prerequisite reboot'

$setupText = Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'setup.ps1') -Raw

$resolveAt = $setupText.IndexOf('$rootChoice = Resolve-DeltaInstallRoot')
$assignAt  = $setupText.IndexOf('$InstallRoot = $rootChoice.Path')
$restartAt = $setupText.IndexOf('Request-DeltaWindowsRestart `')
$stateAt   = $setupText.IndexOf('Show-DeltaInstallationState -Path $InstallRoot')

Assert-That 'setup.ps1 resolves the installation root'            ($resolveAt -ge 0)
Assert-That 'the resolved root is assigned back to $InstallRoot'  ($assignAt -gt $resolveAt)
Assert-That 'resolution happens before the state detection that picks the mode' ($stateAt -gt $assignAt)
Assert-That 'resolution happens before the restart is offered'    ($restartAt -gt $assignAt)

# Register-DeltaLogonContinuation is handed that same $InstallRoot, and puts it
# on the command line the continuation re-runs. Both halves are asserted: the
# continuation carries the switch, and the value survives quoting intact.
Assert-That 'the continuation is registered with -InstallRoot' `
    ($setupText -match "Register-DeltaLogonContinuation[^\r\n]*-InstallRoot")
Assert-That 'the relaunch command line carries -InstallRoot' `
    ($setupText -match "'-InstallRoot',\s*\`$InstallRoot")

$spaced = 'D:\Program Files\DELTA'
$commandLine = ConvertTo-DeltaCommandLine -Arguments @('-File', 'C:\x\setup.ps1', '-InstallRoot', $spaced)
Assert-That 'a custom root with spaces survives the continuation command line' `
    ($commandLine -match '-InstallRoot\s+"D:\\Program Files\\DELTA"')

# And on the way back in, that supplied root bypasses the question entirely -
# which is what stops a resumed installation asking a second time.
$reader = New-AnswerReader -Answers @()
$resumed = Resolve-DeltaInstallRoot -DefaultRoot $spaced -WasSupplied -AllowPrompt $true `
    -Reader $reader.Block -FolderPicker { param($d, $i) throw 'A resumed run must not open a dialog.' } `
    -DialogProbe { throw 'A resumed run must not probe.' } -StateProbe $Script:NoInstallation 6>$null

Assert-Equal 'the resumed run keeps the custom root' $spaced     $resumed.Path
Assert-Equal 'the resumed run asks nothing'          'supplied'  $resumed.Source
Assert-Equal 'no question on resume'                 0           $reader.Prompts.Count

# --- the picker reuses the existing dialog infrastructure -------------------

Start-TestCase 'Folder selection reuses the existing picker conventions'

Assert-That 'Select-DeltaFolder exists'            ($null -ne (Get-Command Select-DeltaFolder -ErrorAction SilentlyContinue))
Assert-That 'the existing file picker still exists' ($null -ne (Get-Command Select-DeltaSslFile -ErrorAction SilentlyContinue))
Assert-That 'both dialogs share one support probe'  ($null -ne (Get-Command Test-DeltaFileDialogSupported -ErrorAction SilentlyContinue))

# The STA refusal is the guard that stops a dialog hanging an installer, and it
# is asserted the only way that means anything: by calling it on an MTA thread
# and requiring it to come back rather than block.
$mta = [powershell]::Create()
$null = $mta.AddScript({
    param($libPath)
    . $libPath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Select-DeltaFolder -Description 'DELTA test - this window must never appear' 6>$null
    return [PSCustomObject]@{ Returned = $true; Selected = $r; ElapsedMs = $sw.ElapsedMilliseconds }
}).AddArgument((Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1'))
$mta.Runspace = [runspacefactory]::CreateRunspace()
$mta.Runspace.ApartmentState = 'MTA'
$mta.Runspace.Open()

try {
    $async = $mta.BeginInvoke()
    if ($async.AsyncWaitHandle.WaitOne(15000)) {
        $out = $mta.EndInvoke($async)
        Assert-That 'Select-DeltaFolder returns on an MTA thread instead of hanging' ($out[0].Returned)
        Assert-That 'and selects nothing there'                                      ($null -eq $out[0].Selected)
    }
    else {
        Assert-That 'Select-DeltaFolder returns on an MTA thread instead of hanging' $false
    }
}
finally {
    $mta.Runspace.Close()
    $mta.Dispose()
}

# --- the default (uninjected) wiring ----------------------------------------

Start-TestCase 'The real folder picker is wired up, not just the injected one'

# Every test above injects the picker, so none of them would notice if
# Resolve-DeltaInstallRoot's default scriptblock called Select-DeltaFolder with
# the wrong parameter names - a break that would surface only on the machine of
# the first operator who ever answered N. This runs the real default picker,
# on an MTA thread so its STA guard returns instead of opening a window, and
# requires the decline-then-reask path to complete through it.
$wiring = [powershell]::Create()
$null = $wiring.AddScript({
    param($commonPath, $configPath)
    . $commonPath
    . $configPath
    $script:asked = 0
    $r = Resolve-DeltaInstallRoot -DefaultRoot 'C:\DELTA-not-present' -AllowPrompt $true `
        -Reader { param($p) $script:asked++; if ($script:asked -eq 1) { 'no' } else { 'yes' } } `
        -DialogProbe { $true } `
        -StateProbe { param($x) 'none' }
    return [PSCustomObject]@{ Path = $r.Path; Source = $r.Source; Asked = $script:asked }
}).AddArgument((Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')).AddArgument((Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1'))
$wiring.Runspace = [runspacefactory]::CreateRunspace()
$wiring.Runspace.ApartmentState = 'MTA'
$wiring.Runspace.Open()

try {
    $async = $wiring.BeginInvoke()
    if ($async.AsyncWaitHandle.WaitOne(20000)) {
        $out = $wiring.EndInvoke($async)
        Assert-Equal 'the real picker was reached and returned nothing' 2 $out[0].Asked
        Assert-Equal 'and the question was re-asked, not abandoned' 'default' $out[0].Source
        Assert-Equal 'ending on the default root' 'C:\DELTA-not-present' $out[0].Path
    }
    else {
        Assert-That 'the real picker returns instead of hanging the resolver' $false
    }
}
finally {
    $wiring.Runspace.Close()
    $wiring.Dispose()
}

# --- teardown ---------------------------------------------------------------

Remove-Item -LiteralPath $Script:CustomRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('-' * 60)
Write-Host "  passed: $Script:Passed"
Write-Host "  failed: $Script:Failed"
Write-Host ('-' * 60)
Write-Host ''

if ($Script:Failed -gt 0) { exit 1 }
exit 0
