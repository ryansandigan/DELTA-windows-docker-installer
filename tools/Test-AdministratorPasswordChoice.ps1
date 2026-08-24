#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for the DELTA administrator password choice asked during
    a new installation.

.DESCRIPTION
    A new installation asks how the administrator credential should be set,
    as an explicit question with two answers:

        1. Enter a password
        2. Generate a strong password automatically

    It used to be a password prompt whose empty answer meant "generate", which
    is the behaviour these tests exist to keep from coming back. What has to
    hold:

      - The question is asked, in full, with option 2 as the default. Enter
        selects generation; nothing else does so implicitly.
      - An answer that is neither 1 nor 2 is rejected and asked again. At a
        question about which METHOD to use, an unrecognised answer must never
        be accepted as a password.
      - Option 1 asks twice, requires a match, and refuses to continue with a
        credential the operator did not confirm. A mismatch is reported and
        retried; the second attempt is what is used.
      - Option 2 uses the installer's own CSPRNG generator, at the length this
        credential has always been generated at, and reports itself as
        generated so the completion summary shows it exactly once.
      - Nothing typed reaches the terminal or the transcript in clear text.
      - An installation whose administrator has already been secured is never
        asked at all, so a rerun or an update keeps the credential somebody is
        already using.
      - No animation is running while any of the three questions is on screen.

    Dependency-free, matching the other suites here: no Pester, no modules, no
    network, and nothing on this host outside a temporary directory. Read-Host
    is replaced inside a wrapper function per case - a stand-in defined in the
    wrapper's scope is what the function under test resolves - and it replays a
    scripted list of answers, failing loudly if it is asked more times than the
    test scripted.

    Exits 0 if every test passes, 1 otherwise.

.EXAMPLE
    .\tools\Test-AdministratorPasswordChoice.ps1
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

# Everything a case records. Reset before each run so an assertion can never
# pass on a previous case's evidence.
$Script:Prompts    = $null
$Script:Answers    = $null
$Script:Result     = $null
$Script:Output     = $null
$Script:Generated  = $null
$Script:GeneratorCalls = $null

function Reset-Case {
    # Empty strings are answers here - pressing Enter is one of the cases under
    # test - so both the collection and its elements have to be allowed empty.
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Answers)
    $Script:Prompts = New-Object 'System.Collections.Generic.List[string]'
    $Script:Answers = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($a in $Answers) { $Script:Answers.Enqueue($a) }
    $Script:Result = $null
    $Script:Output = @()
    $Script:GeneratorCalls = New-Object 'System.Collections.Generic.List[int]'
}

function Get-NextAnswer {
    <#
      The scripted answer for one prompt. Running dry is an error rather than a
      default: a test whose reader ran out used to look like a pass for the
      wrong reason.
    #>
    param([string]$Prompt)
    $null = $Script:Prompts.Add([string]$Prompt)
    if ($Script:Answers.Count -eq 0) {
        throw "The installer asked more questions than the test scripted answers for. Last prompt: $Prompt"
    }
    return $Script:Answers.Dequeue()
}

function Invoke-PasswordChoice {
    <#
      Runs the real Read-DeltaAdministratorPassword against the scripted
      answers. Read-Host is defined here, in the scope the function under test
      is called from, which is what puts it in reach; -AsSecureString is
      honoured so the function's own SecureString handling is the code under
      test rather than something this stub short-circuits.
    #>
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        $answer = Get-NextAnswer -Prompt $Prompt
        if ($AsSecureString) {
            # ConvertTo-SecureString refuses an empty string, and an empty
            # answer is exactly what one of these cases is about.
            $secure = New-Object System.Security.SecureString
            foreach ($c in [char[]]$answer) { $secure.AppendChar($c) }
            $secure.MakeReadOnly()
            return $secure
        }
        return $answer
    }
    $Script:Result = Read-DeltaAdministratorPassword -GeneratedLength 20
}

function Invoke-PasswordChoiceWithStubbedGenerator {
    <#
      As above, with New-DeltaPassword recorded and replaced. Proves which
      generator the option-2 path calls and at what length, without asserting
      on the value of a random string.
    #>
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        return (Get-NextAnswer -Prompt $Prompt)
    }
    function New-DeltaPassword {
        param([int]$Length = 32)
        $null = $Script:GeneratorCalls.Add($Length)
        return $Script:Generated
    }
    $Script:Result = Read-DeltaAdministratorPassword -GeneratedLength 20
}

function Get-PlainResult {
    <# The returned credential as plain text, for comparison only. #>
    if (-not $Script:Result) { return $null }
    return (ConvertTo-DeltaPlainText -SecureString $Script:Result.Password)
}

function Test-OutputContains {
    param([Parameter(Mandatory)][string]$Text)
    return [bool](@($Script:Output | Where-Object { $_ -like "*$Text*" }).Count -gt 0)
}

# The animation is turned off for the whole suite: these tests are about the
# question, and a redirected run would refuse to animate anyway. The one test
# that is about the indicator turns it back on with an injected writer.
Set-DeltaActivityMode -Mode 'off'

# --- the question itself ----------------------------------------------------

Start-TestCase 'A new installation asks how the administrator password should be set'

Reset-Case -Answers @('')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-That 'the heading names the credential'      (Test-OutputContains -Text 'DELTA administrator password')
Assert-That 'it says which account this is for'     (Test-OutputContains -Text 'admin@admin.com')
Assert-That 'and why the installer replaces it'     (Test-OutputContains -Text 'publicly known default')
Assert-That 'the question is asked as a choice'     (Test-OutputContains -Text 'Choose how to set the password:')
Assert-That 'option 1 is entering a password'       (Test-OutputContains -Text '  1. Enter a password')
Assert-That 'option 2 is generating one'            (Test-OutputContains -Text '  2. Generate a strong password automatically')
Assert-Equal 'exactly one question was asked'       1 $Script:Prompts.Count
Assert-Equal 'and it shows 2 as the default'        'Choose 1 or 2 [2]' $Script:Prompts[0]

Start-TestCase 'Enter at the choice generates, and says so'

Reset-Case -Answers @('')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'a credential came back'                    $true ($null -ne $Script:Result)
Assert-Equal 'reported as generated'                     $true $Script:Result.WasGenerated
Assert-That  'and the operator was told so'              (Test-OutputContains -Text 'A strong administrator password will be generated')
Assert-That  'including when they will see it'           (Test-OutputContains -Text 'shown once')
Assert-Equal 'nothing else was asked'                    1 $Script:Prompts.Count

Start-TestCase 'Answering 2 generates'

Reset-Case -Answers @('2')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })
Assert-Equal 'reported as generated'    $true $Script:Result.WasGenerated
Assert-Equal 'after one question'       1 $Script:Prompts.Count

# Surrounding whitespace is an answer, not a typo to reject.
Reset-Case -Answers @('  2  ')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })
Assert-Equal 'a padded 2 is still 2'    $true $Script:Result.WasGenerated

# --- invalid answers --------------------------------------------------------

Start-TestCase 'An answer that is neither 1 nor 2 is refused and asked again'

# The last of these is the property that matters most: a password typed at the
# menu by mistake must be rejected as a choice, never accepted as a credential.
Reset-Case -Answers @('3', 'y', 'generate', 'hunter2SuperSecret', '2')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'every invalid answer was re-asked'          5 $Script:Prompts.Count
Assert-That  'the refusal says it is not a choice'        (Test-OutputContains -Text 'That is not one of the choices')
Assert-That  'and the valid answers explained'            (Test-OutputContains -Text 'Enter 1 to type a password')
Assert-Equal 'the run still ended in generation'          $true $Script:Result.WasGenerated
Assert-That  'and the typed text never became the password' ((Get-PlainResult) -cne 'hunter2SuperSecret')
Assert-Equal 'every prompt was the same question'         5 (@($Script:Prompts | Where-Object { $_ -eq 'Choose 1 or 2 [2]' }).Count)

Start-TestCase 'A password typed at the choice by mistake is never echoed back'

# This question stands where a password prompt used to, so the likeliest wrong
# answer is the credential the operator meant to set. Quoting it back would put
# it on the screen and in the transcript.
$logDirectory = Join-Path $env:TEMP "delta-adminpw-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$logPath = Start-DeltaLog -Directory $logDirectory -Name 'adminpw'

$mistyped = 'MeantToBeMyPassword-77'
Reset-Case -Answers @($mistyped, '2')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })
Stop-DeltaLog -ExitCode 0
$logText = [System.IO.File]::ReadAllText($logPath)

Assert-That  'it was refused'                              (Test-OutputContains -Text 'That is not one of the choices')
Assert-That  'without appearing on the terminal'           (-not (Test-OutputContains -Text $mistyped))
Assert-That  'and without reaching the transcript'         ($logText -cnotmatch [regex]::Escape($mistyped))
Assert-Equal 'and it did not become the credential'        $true $Script:Result.WasGenerated

Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction SilentlyContinue

# --- option 1: entering a password ------------------------------------------

Start-TestCase 'Answering 1 asks for a password, twice, and uses it'

Reset-Case -Answers @('1', 'Chosen-Password-42', 'Chosen-Password-42')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'the credential was asked for'          'Administrator password' $Script:Prompts[1]
Assert-Equal 'and confirmed'                         'Confirm administrator password' $Script:Prompts[2]
Assert-Equal 'three questions in all'                3 $Script:Prompts.Count
Assert-Equal 'the typed password is the result'      'Chosen-Password-42' (Get-PlainResult)
Assert-Equal 'and it is NOT reported as generated'   $false $Script:Result.WasGenerated

Start-TestCase 'Two entries that do not match are refused, and retried'

Reset-Case -Answers @('1', 'First-Attempt-One', 'First-Attempt-Two', 'Second-Attempt-Ok', 'Second-Attempt-Ok')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-That  'the mismatch was reported'             (Test-OutputContains -Text 'The two entries did not match')
Assert-Equal 'and both were asked for again'         5 $Script:Prompts.Count
Assert-Equal 'the retried password is the result'    'Second-Attempt-Ok' (Get-PlainResult)
Assert-Equal 'still not reported as generated'       $false $Script:Result.WasGenerated

Start-TestCase 'A mismatch never continues with either value, or with a generated one'

# Scripted to run dry immediately after the mismatch: if the function had
# accepted one of the two, or quietly generated instead, it would return here
# and the reader would never be asked again.
Reset-Case -Answers @('1', 'Mismatch-Aaaa-1111', 'Mismatch-Bbbb-2222')
$threw = $false
try { $null = Invoke-PasswordChoice 6>$null }
catch { $threw = $true }

Assert-Equal 'it asked again rather than continuing'  $true $threw
Assert-Equal 'and returned nothing'                   $true ($null -eq $Script:Result)

Start-TestCase 'Existing validation still applies to a typed password'

Reset-Case -Answers @('1', 'short', 'Long-Enough-Password', 'Long-Enough-Password')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })
Assert-That  'a too-short password is refused'        (Test-OutputContains -Text 'Use at least 8 characters')
Assert-That  'without offering Enter as a way out'    (-not (Test-OutputContains -Text 'press Enter to have one generated'))
Assert-Equal 'and the valid one is used'              'Long-Enough-Password' (Get-PlainResult)

Reset-Case -Answers @('1', 'both"quotes''here', 'Quoteless-Password-1', 'Quoteless-Password-1')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })
Assert-That  'a password .env cannot hold is refused' (Test-OutputContains -Text 'cannot contain both single and double quotes')
Assert-Equal 'and the acceptable one is used'         'Quoteless-Password-1' (Get-PlainResult)

Start-TestCase 'Entering nothing puts the choice back rather than generating silently'

Reset-Case -Answers @('1', '', '1', 'Meant-To-Type-This-1', 'Meant-To-Type-This-1')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-That  'the operator is told nothing was set'   (Test-OutputContains -Text 'Nothing was entered')
Assert-Equal 'the choice was asked again'             'Choose 1 or 2 [2]' $Script:Prompts[2]
Assert-Equal 'and the password they meant is used'    'Meant-To-Type-This-1' (Get-PlainResult)
Assert-Equal 'reported as chosen, not generated'      $false $Script:Result.WasGenerated

# An empty entry must not become a generated credential by itself - only the
# explicit choice does that.
Reset-Case -Answers @('1', '')
$threw = $false
try { $null = Invoke-PasswordChoice 6>$null }
catch { $threw = $true }
Assert-Equal 'an empty entry alone decides nothing'   $true $threw
Assert-Equal 'and returns no credential'              $true ($null -eq $Script:Result)

# --- option 2: the generator ------------------------------------------------

Start-TestCase 'Generating uses the installer''s own generator, at the usual length'

Reset-Case -Answers @('2')
$Script:Generated = 'StubbedGeneratedPassword'
$Script:Output = @(Invoke-PasswordChoiceWithStubbedGenerator 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'New-DeltaPassword was called once'      1 $Script:GeneratorCalls.Count
Assert-Equal 'at the administrator length'            20 $Script:GeneratorCalls[0]
Assert-Equal 'and its output is what comes back'      'StubbedGeneratedPassword' (Get-PlainResult)
Assert-Equal 'reported as generated'                  $true $Script:Result.WasGenerated

Start-TestCase 'The real generator still produces a strong password'

Reset-Case -Answers @('2')
$null = Invoke-PasswordChoice 6>$null
$firstPlain = Get-PlainResult
Reset-Case -Answers @('2')
$null = Invoke-PasswordChoice 6>$null
$secondPlain = Get-PlainResult

Assert-Equal 'twenty characters'                      20 $firstPlain.Length
Assert-That  'from the documented alphabet'           ($firstPlain -cmatch '^[A-Za-z0-9]{20}$')
Assert-That  'and two runs do not repeat'             ($firstPlain -cne $secondPlain)

# --- secrecy ----------------------------------------------------------------

Start-TestCase 'A typed password reaches neither the terminal nor the transcript'

$logDirectory = Join-Path $env:TEMP "delta-adminpw-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$logPath = Start-DeltaLog -Directory $logDirectory -Name 'adminpw'
Assert-That 'a transcript was opened' ($null -ne $logPath)

$secret = 'Nowhere-Should-This-Appear-9'
Reset-Case -Answers @('1', $secret, $secret)
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })

# Written through the logger AFTER the password was registered as a secret, so
# this also proves the redaction that protects output the installer did not
# format itself.
Write-DeltaLogLine -Message "A line that happens to contain $secret" -Level 'DETAIL'
Stop-DeltaLog -ExitCode 0

$logText = [System.IO.File]::ReadAllText($logPath)
Assert-Equal 'the password was used'                      $secret (Get-PlainResult)
Assert-That  'but never echoed to the terminal'           (-not (Test-OutputContains -Text $secret))
Assert-That  'and never written to the transcript'        ($logText -cnotmatch [regex]::Escape($secret))
Assert-That  'a line carrying it is redacted instead'     ($logText -match [regex]::Escape($Script:DeltaRedactionMarker))
Assert-That  'the transcript records that one was chosen' ($logText -match 'Administrator password: entered by the operator')

Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction SilentlyContinue

Start-TestCase 'A generated password is not written to the transcript either'

$logDirectory = Join-Path $env:TEMP "delta-adminpw-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$logPath = Start-DeltaLog -Directory $logDirectory -Name 'adminpw'

Reset-Case -Answers @('2')
$Script:Output = @(Invoke-PasswordChoice 6>&1 | ForEach-Object { [string]$_ })
$generatedPlain = Get-PlainResult
Stop-DeltaLog -ExitCode 0

$logText = [System.IO.File]::ReadAllText($logPath)
Assert-That 'the generated value is not in the transcript' ($logText -cnotmatch [regex]::Escape($generatedPlain))
Assert-That 'nor on the terminal at this point'            (-not (Test-OutputContains -Text $generatedPlain))
Assert-That 'the transcript records the method only'       ($logText -match 'Administrator password: generated by the installer')

Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction SilentlyContinue

# --- an installation that already has an administrator ----------------------

Start-TestCase 'An installation whose administrator is already secured is not asked'

$installRoot = Join-Path $env:TEMP "delta-adminpw-root-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$null = New-Item -ItemType Directory -Path $installRoot -Force

# A .env with a real database password and a state file recording a completed
# bootstrap: the two facts that make a rerun quiet.
Set-Content -LiteralPath (Join-Path $installRoot '.env') -Value @(
    'DELTA_HOSTNAME=delta.example.test'
    'POSTGRES_PASSWORD=AlreadyChosenLongAgo'
) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $installRoot '.delta-install.json') -Value (@{
    schemaVersion  = 1
    state          = 'installed'
    adminBootstrap = @{ completed = $true }
} | ConvertTo-Json) -Encoding UTF8

function Invoke-SettingsOnConfiguredInstall {
    <#
      Any prompt at all throws here. That is the assertion: a rerun, an update
      or a restart must not ask a configured installation for a new
      administrator credential.
    #>
    param([Parameter(Mandatory)][string]$Root)
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        throw "A configured installation was asked: $Prompt"
    }
    return (Read-DeltaFreshInstallSettings -InstallRoot $Root -AllowPrompt $true -HostName 'delta.example.test')
}

$settings = $null
$threw = $null
try { $settings = Invoke-SettingsOnConfiguredInstall -Root $installRoot 6>$null }
catch { $threw = $_ }

Assert-That  'nothing was asked'                          ($null -eq $threw)
Assert-Equal 'the administrator was not asked about'      $false $settings.AskedAdminPassword
Assert-Equal 'no new administrator credential was made'   $true ($null -eq $settings.AdminPassword)
Assert-Equal 'and none is reported as generated'          $false $settings.AdminPasswordWasGenerated
Assert-Equal 'the database password was left alone too'   $false $settings.AskedPostgresPassword

Start-TestCase 'A fresh installation IS asked, through the new question'

$freshRoot = Join-Path $env:TEMP "delta-adminpw-fresh-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$null = New-Item -ItemType Directory -Path $freshRoot -Force
Set-Content -LiteralPath (Join-Path $freshRoot '.env') -Value @(
    'DELTA_HOSTNAME=delta.example.test'
    'POSTGRES_PASSWORD=AlreadyChosenLongAgo'
) -Encoding UTF8

function Invoke-SettingsOnFreshInstall {
    param([Parameter(Mandatory)][string]$Root)
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        $answer = Get-NextAnswer -Prompt $Prompt
        if ($AsSecureString) {
            $secure = New-Object System.Security.SecureString
            foreach ($c in [char[]]$answer) { $secure.AppendChar($c) }
            $secure.MakeReadOnly()
            return $secure
        }
        return $answer
    }
    return (Read-DeltaFreshInstallSettings -InstallRoot $Root -AllowPrompt $true -HostName 'delta.example.test')
}

Reset-Case -Answers @('1', 'Fresh-Install-Password', 'Fresh-Install-Password')
$freshSettings = Invoke-SettingsOnFreshInstall -Root $freshRoot 6>$null

Assert-Equal 'the administrator question was asked'       $true $freshSettings.AskedAdminPassword
Assert-Equal 'as the choice, first'                       'Choose 1 or 2 [2]' $Script:Prompts[0]
Assert-Equal 'then the password'                          'Administrator password' $Script:Prompts[1]
Assert-Equal 'then the confirmation'                      'Confirm administrator password' $Script:Prompts[2]
Assert-Equal 'the chosen credential is carried out'       'Fresh-Install-Password' (ConvertTo-DeltaPlainText -SecureString $freshSettings.AdminPassword)
Assert-Equal 'and is not reported as generated'           $false $freshSettings.AdminPasswordWasGenerated
Assert-Equal 'the database password was not re-asked'     $false $freshSettings.AskedPostgresPassword

Start-TestCase 'A non-interactive run asks nothing at all'

Reset-Case -Answers @()
function Invoke-SettingsNonInteractive {
    param([Parameter(Mandatory)][string]$Root)
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        throw "A non-interactive run asked: $Prompt"
    }
    return (Read-DeltaFreshInstallSettings -InstallRoot $Root -AllowPrompt $false)
}

$quiet = $null
$threw = $null
try { $quiet = Invoke-SettingsNonInteractive -Root $freshRoot 6>$null }
catch { $threw = $_ }

Assert-That  'nothing was asked'                        ($null -eq $threw)
Assert-Equal 'no administrator credential was decided'  $true ($null -eq $quiet.AdminPassword)
Assert-Equal 'and none was announced as generated'      $false $quiet.AdminPasswordWasGenerated

Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $freshRoot -Recurse -Force -ErrorAction SilentlyContinue

# --- the activity indicator -------------------------------------------------

Start-TestCase 'Nothing animates while any of the three questions is on screen'

# The indicator is turned back on with an injected writer, and an activity is
# started before the question - the case an operator meets when a question is
# reached from inside an operation that is already in progress.
Set-DeltaActivityMode -Mode 'auto'

$Script:AnimatingAt = New-Object 'System.Collections.Generic.List[object]'
$sinkRaw = New-Object System.IO.StringWriter
$sink = [System.IO.TextWriter]::Synchronized($sinkRaw)

function Invoke-PasswordChoiceWithLiveActivity {
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        $null = $Script:AnimatingAt.Add([PSCustomObject]@{
            Prompt    = [string]$Prompt
            Animating = (Test-DeltaActivityAnimating)
            Running   = (Test-DeltaActivityRunning)
        })
        $answer = Get-NextAnswer -Prompt $Prompt
        if ($AsSecureString) {
            $secure = New-Object System.Security.SecureString
            foreach ($c in [char[]]$answer) { $secure.AppendChar($c) }
            $secure.MakeReadOnly()
            return $secure
        }
        return $answer
    }
    $Script:Result = Read-DeltaAdministratorPassword -GeneratedLength 20
}

Reset-Case -Answers @('1', 'Live-Activity-Password', 'Live-Activity-Password')
Start-DeltaActivity -Message 'Something in progress' -Writer $sink
Start-Sleep -Milliseconds 400
$null = Invoke-PasswordChoiceWithLiveActivity 6>$null

Assert-Equal 'all three questions were reached'       3 $Script:AnimatingAt.Count
Assert-Equal 'nothing animated at the choice'         $false $Script:AnimatingAt[0].Animating
Assert-Equal 'nor at the password prompt'             $false $Script:AnimatingAt[1].Animating
Assert-Equal 'nor at the confirmation'                $false $Script:AnimatingAt[2].Animating
Assert-Equal 'the operation stayed in progress'       $true $Script:AnimatingAt[2].Running
Assert-That  'and animates again once the answer is in' (Test-DeltaActivityAnimating)
Assert-That  'the line was erased before the question' ($sinkRaw.ToString() -match "`r +`r")
Assert-That  'and never left its line'                 ($sinkRaw.ToString() -notmatch "`n")

Stop-DeltaActivity
Set-DeltaActivityMode -Mode 'off'
Assert-That 'nothing is left running' (-not (Test-DeltaActivityRunning))

# --- teardown ---------------------------------------------------------------

Set-DeltaActivityMode -Mode 'auto'

Write-Host ''
Write-Host ('-' * 60)
Write-Host "  passed: $Script:Passed"
Write-Host "  failed: $Script:Failed"
Write-Host ('-' * 60)
Write-Host ''

if ($Script:Failed -gt 0) { exit 1 }
exit 0
