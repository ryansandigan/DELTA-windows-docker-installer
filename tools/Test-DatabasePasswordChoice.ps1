#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for the PostgreSQL database password choice asked during
    a new installation.

.DESCRIPTION
    The database password used to be asked as a password prompt whose empty
    answer meant something:

        Database password [Enter = generate]:

    It is now the same explicit question the DELTA administrator credential is
    asked with:

        1. Enter a password
        2. Generate a strong password automatically

    That is the change these tests exist to keep. What has to hold:

      - The question is asked in full - heading, explanation, both options -
        with option 2 as the default. Enter selects generation; nothing else
        does so implicitly.
      - An answer that is neither 1 nor 2 is rejected and asked again, and is
        never accepted as a password. At a question standing where a password
        prompt used to be, the likeliest wrong answer is the password itself.
      - Option 1 asks twice, masked, requires a match, and refuses to continue
        with a credential the operator did not confirm.
      - Option 2 uses the installer's own CSPRNG generator at the length this
        credential has always been generated at (32).
      - Nothing typed or generated reaches the terminal or the transcript in
        clear text.
      - The surrounding behaviour is unchanged: a cluster that already has a
        password is never asked, and a non-interactive run asks nothing and
        invents nothing.
      - Asking the database password does not disturb the administrator
        question, which keeps its own wording and its own prompts.

    Dependency-free, matching the other suites here: no Pester, no modules, no
    network, and nothing on this host outside a temporary directory. Read-Host
    is replaced inside a wrapper function per case - a stand-in defined in the
    wrapper's scope is what the function under test resolves - and it replays a
    scripted list of answers, failing loudly if it is asked more times than the
    test scripted.

    Exits 0 if every test passes, 1 otherwise.

.EXAMPLE
    .\tools\Test-DatabasePasswordChoice.ps1
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

$Script:Prompts        = $null
$Script:Answers        = $null
$Script:Result         = $null
$Script:Output         = $null
$Script:Generated      = $null
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
      default: a test whose reader ran out would look like a pass for the wrong
      reason.
    #>
    param([string]$Prompt)
    $null = $Script:Prompts.Add([string]$Prompt)
    if ($Script:Answers.Count -eq 0) {
        throw "The installer asked more questions than the test scripted answers for. Last prompt: $Prompt"
    }
    return $Script:Answers.Dequeue()
}

function Invoke-DatabasePasswordChoice {
    <#
      Runs the real Read-DeltaPostgresPassword against the scripted answers.
      Read-Host is defined here, in the scope the function under test is called
      from, which is what puts it in reach; -AsSecureString is honoured so the
      function's own SecureString handling is the code under test rather than
      something this stub short-circuits.
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
    $Script:Result = Read-DeltaPostgresPassword -GeneratedLength 32
}

function Invoke-DatabasePasswordChoiceWithStubbedGenerator {
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
    $Script:Result = Read-DeltaPostgresPassword -GeneratedLength 32
}

function Get-PlainResult {
    <# The returned credential as plain text, for comparison only. #>
    if (-not $Script:Result) { return $null }
    return (ConvertTo-DeltaPlainText -SecureString $Script:Result.Password)
}

function Test-OutputContains {
    <#
      Plain substring, not -like: the strings asserted here include `[` and `]`
      - `[Enter = generate]` is the prompt this change retired - and -like would
      read those as a character class and quietly match the wrong thing.
    #>
    param([Parameter(Mandatory)][string]$Text)
    return [bool](@($Script:Output | Where-Object { $_.Contains($Text) }).Count -gt 0)
}

# The animation is turned off for the whole suite: these tests are about the
# question, and a redirected run would refuse to animate anyway.
Set-DeltaActivityMode -Mode 'off'

# --- the question itself ----------------------------------------------------

Start-TestCase 'A new installation asks how the database password should be set'

Reset-Case -Answers @('')
$Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-That 'the heading names the credential'   (Test-OutputContains -Text 'Database password')
Assert-That 'it says what the password protects' (Test-OutputContains -Text 'creates the PostgreSQL database for DELTA and protects it')
Assert-That 'and that the database is not exposed' (Test-OutputContains -Text 'The database is not published to the network.')
Assert-That 'the question is asked as a choice'  (Test-OutputContains -Text 'Choose how to set the password:')
Assert-That 'option 1 is entering a password'    (Test-OutputContains -Text '  1. Enter a password')
Assert-That 'option 2 is generating one'         (Test-OutputContains -Text '  2. Generate a strong password automatically')
Assert-Equal 'exactly one question was asked'    1 $Script:Prompts.Count
Assert-Equal 'and it shows 2 as the default'     'Choose 1 or 2 [2]' $Script:Prompts[0]

# The old prompt is what this replaced. If it comes back, it comes back here.
Assert-That 'the old empty-means-generate prompt is gone' `
    (-not (Test-OutputContains -Text '[Enter = generate]'))
Assert-That 'and nothing invites an empty answer as the way to generate' `
    (-not (Test-OutputContains -Text 'Press Enter to have a strong one generated'))

Start-TestCase 'The layout is the one the operator was promised'

# Asserted as a block, in order, because the wording is the deliverable here -
# a question whose lines drifted apart is a different question.
$rendered = ($Script:Output -join "`n")
$expected = @(
    'Database password'
    ''
    '    The installer creates the PostgreSQL database for DELTA and protects it'
    '    with this password. The database is not published to the network.'
    ''
    'Choose how to set the password:'
    ''
    '  1. Enter a password'
    '  2. Generate a strong password automatically'
) -join "`n"

Assert-That 'the whole block renders exactly as specified' ($rendered -clike "*$expected*")

# --- Enter, and option 2 ----------------------------------------------------

Start-TestCase 'Enter at the choice generates, and says so'

Reset-Case -Answers @('')
$Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'a credential was decided'          $true ($null -ne $Script:Result)
Assert-Equal 'it is reported as generated'       $true $Script:Result.WasGenerated
Assert-Equal 'it is 32 characters long'          32 (Get-PlainResult).Length
Assert-That  'and the operator is told'          (Test-OutputContains -Text 'A strong database password will be generated.')
Assert-Equal 'nothing else was asked'            1 $Script:Prompts.Count

# The database password is never shown at the end, unlike the administrator
# credential, so this must not promise one.
Assert-That 'it does not promise to show the value later' `
    (-not (Test-OutputContains -Text 'shown once'))

Start-TestCase 'Option 2 generates the same way an explicit answer should'

Reset-Case -Answers @('2')
$Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'a credential was decided'    $true ($null -ne $Script:Result)
Assert-Equal 'it is reported as generated' $true $Script:Result.WasGenerated
Assert-Equal 'it is 32 characters long'    32 (Get-PlainResult).Length
Assert-Equal 'and no password was typed'   1 $Script:Prompts.Count

Start-TestCase 'Whitespace around the answer does not change it'

foreach ($answer in @('  ', ' 2 ')) {
    Reset-Case -Answers @($answer)
    $Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ })
    Assert-Equal "'$answer' still generates"   $true $Script:Result.WasGenerated
    Assert-Equal "'$answer' asks nothing more" 1     $Script:Prompts.Count
}

Start-TestCase 'Generation uses the installer CSPRNG at the documented length'

$Script:Generated = 'Stubbed-Database-Password-Value'
Reset-Case -Answers @('2')
$Script:Output = @(Invoke-DatabasePasswordChoiceWithStubbedGenerator 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'the installer generator was called once' 1 $Script:GeneratorCalls.Count
Assert-Equal 'at length 32'                            32 $Script:GeneratorCalls[0]
Assert-Equal 'and its value is what is returned'       $Script:Generated (Get-PlainResult)
Assert-Equal 'reported as generated'                   $true $Script:Result.WasGenerated

# --- option 1 ---------------------------------------------------------------

Start-TestCase 'Option 1 takes a password typed twice'

Reset-Case -Answers @('1', 'Chosen-Database-Password', 'Chosen-Database-Password')
$Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'the choice came first'          'Choose 1 or 2 [2]' $Script:Prompts[0]
Assert-Equal 'then the password'              'Database password' $Script:Prompts[1]
Assert-Equal 'then the confirmation'          'Confirm database password' $Script:Prompts[2]
Assert-Equal 'exactly three prompts'          3 $Script:Prompts.Count
Assert-Equal 'the typed value is what is used' 'Chosen-Database-Password' (Get-PlainResult)
Assert-Equal 'and it is not reported as generated' $false $Script:Result.WasGenerated
Assert-That  'nothing announces a generated password' `
    (-not (Test-OutputContains -Text 'A strong database password will be generated.'))

# Both entries are masked. Asserted by requiring the stub to have been called
# with -AsSecureString for both, which the wrapper below records.
Start-TestCase 'Both entries are masked'

$Script:Masked = New-Object 'System.Collections.Generic.List[string]'
function Invoke-MaskRecordingChoice {
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        if ($AsSecureString) { $null = $Script:Masked.Add($Prompt) }
        $answer = Get-NextAnswer -Prompt $Prompt
        if ($AsSecureString) {
            $secure = New-Object System.Security.SecureString
            foreach ($c in [char[]]$answer) { $secure.AppendChar($c) }
            $secure.MakeReadOnly()
            return $secure
        }
        return $answer
    }
    $Script:Result = Read-DeltaPostgresPassword -GeneratedLength 32
}

Reset-Case -Answers @('1', 'Masked-Entry-Password', 'Masked-Entry-Password')
$null = Invoke-MaskRecordingChoice 6>&1

Assert-Equal 'two entries were masked'      2 $Script:Masked.Count
Assert-Equal 'the password entry'           'Database password' $Script:Masked[0]
Assert-Equal 'and the confirmation'         'Confirm database password' $Script:Masked[1]
Assert-That  'the choice itself was not masked' ($Script:Masked -notcontains 'Choose 1 or 2 [2]')

Start-TestCase 'A mismatch is refused and retried, and the retry is what counts'

Reset-Case -Answers @('1', 'First-Attempt-Password', 'Different-Password', 'Second-Attempt-Password', 'Second-Attempt-Password')
$Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-That  'the mismatch is reported'          (Test-OutputContains -Text 'The two entries did not match')
Assert-Equal 'the second attempt is what is used' 'Second-Attempt-Password' (Get-PlainResult)
Assert-Equal 'and it is not reported as generated' $false $Script:Result.WasGenerated
Assert-That  'neither rejected value is echoed'  (-not (Test-OutputContains -Text 'First-Attempt-Password'))
Assert-That  'nor the one it was compared with'  (-not (Test-OutputContains -Text 'Different-Password'))

Start-TestCase 'A mismatch never falls through to generating'

Reset-Case -Answers @('1', 'Mismatch-One', 'Mismatch-Two', '', '')
$threw = $null
try { $Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ }) }
catch { $threw = $_ }

# Whatever it did, it must not have generated silently after the mismatch: the
# next thing asked is the password again, not the choice.
Assert-Equal 'the password is asked again, not the choice' 'Database password' $Script:Prompts[3]

Start-TestCase 'An empty entry returns to the choice rather than generating'

Reset-Case -Answers @('1', '', '2')
$Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-That  'the operator is told nothing was set' (Test-OutputContains -Text 'Nothing was entered, so no password has been set.')
Assert-Equal 'the choice is put back on screen'     'Choose 1 or 2 [2]' $Script:Prompts[2]
Assert-Equal 'and generating stays something chosen' $true $Script:Result.WasGenerated

# --- answers that are neither 1 nor 2 ---------------------------------------

Start-TestCase 'An unrecognised answer is refused and never taken as a password'

# The likeliest wrong answer at this question is the password itself, typed at
# a prompt that used to accept one. It must not become the credential, and it
# must not be echoed back.
Reset-Case -Answers @('MySecretDbPassw0rd!', '3', 'yes', 'y', '')
$Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-Equal 'every answer was the same question' 5 (@($Script:Prompts | Where-Object { $_ -ceq 'Choose 1 or 2 [2]' }).Count)
Assert-That  'the refusal names the valid answers' (Test-OutputContains -Text 'That is not one of the choices.')
Assert-That  'the rejected answer is never echoed' (-not (Test-OutputContains -Text 'MySecretDbPassw0rd!'))
Assert-Equal 'a password typed at the choice never becomes the credential' `
    $true ((Get-PlainResult) -cne 'MySecretDbPassw0rd!')
Assert-Equal 'the run ends on the generated default' $true $Script:Result.WasGenerated

# --- secrets stay out of the output and the transcript ----------------------

Start-TestCase 'A generated database password reaches neither the terminal nor the transcript'

$logDirectory = Join-Path $env:TEMP "delta-dbpw-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$logPath = Start-DeltaLog -Directory $logDirectory -Name 'dbpw'

Reset-Case -Answers @('2')
$Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ })
$generatedPlain = Get-PlainResult
Stop-DeltaLog -ExitCode 0

$logText = [System.IO.File]::ReadAllText($logPath)
Assert-That 'the generated value is not in the transcript' ($logText -cnotmatch [regex]::Escape($generatedPlain))
Assert-That 'nor on the terminal'                          (-not (Test-OutputContains -Text $generatedPlain))
Assert-That 'the transcript records the method only'       ($logText -match 'Database password: generated by the installer')

Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction SilentlyContinue

Start-TestCase 'A typed database password reaches neither the terminal nor the transcript'

$logDirectory = Join-Path $env:TEMP "delta-dbpw-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$logPath = Start-DeltaLog -Directory $logDirectory -Name 'dbpw'

Reset-Case -Answers @('1', 'Typed-Secret-Not-In-Logs', 'Typed-Secret-Not-In-Logs')
$Script:Output = @(Invoke-DatabasePasswordChoice 6>&1 | ForEach-Object { [string]$_ })
Stop-DeltaLog -ExitCode 0

$logText = [System.IO.File]::ReadAllText($logPath)
Assert-That 'the typed value is not in the transcript' ($logText -cnotmatch 'Typed-Secret-Not-In-Logs')
Assert-That 'nor on the terminal'                      (-not (Test-OutputContains -Text 'Typed-Secret-Not-In-Logs'))
Assert-That 'the transcript records the method only'   ($logText -match 'Database password: entered by the operator')

Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction SilentlyContinue

# --- where the question sits in the installation flow -----------------------

Start-TestCase 'A cluster that already has a password is never asked'

$configuredRoot = Join-Path $env:TEMP "delta-dbpw-root-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$null = New-Item -ItemType Directory -Path $configuredRoot -Force
Set-Content -LiteralPath (Join-Path $configuredRoot '.env') -Value @(
    'DELTA_HOSTNAME=delta.example.test'
    'POSTGRES_PASSWORD=AlreadyChosenLongAgo'
) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $configuredRoot '.delta-install.json') -Value (@{
    schemaVersion  = 1
    state          = 'installed'
    adminBootstrap = @{ completed = $true }
} | ConvertTo-Json) -Encoding UTF8

function Invoke-SettingsOnConfiguredInstall {
    param([Parameter(Mandatory)][string]$Root)
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        throw "A configured installation was asked: $Prompt"
    }
    return (Read-DeltaFreshInstallSettings -InstallRoot $Root -AllowPrompt $true -HostName 'delta.example.test')
}

$settings = $null
$threw = $null
try { $settings = Invoke-SettingsOnConfiguredInstall -Root $configuredRoot 6>$null }
catch { $threw = $_ }

Assert-That  'nothing was asked'                       ($null -eq $threw)
Assert-Equal 'the database password was not asked for' $false $settings.AskedPostgresPassword
Assert-Equal 'and no new one was decided'              $true ($null -eq $settings.PostgresPassword)

Start-TestCase 'A cluster with no password yet IS asked, through the new question'

foreach ($placeholder in @('', '__GENERATE__')) {
    $freshRoot = Join-Path $env:TEMP "delta-dbpw-fresh-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $null = New-Item -ItemType Directory -Path $freshRoot -Force
    Set-Content -LiteralPath (Join-Path $freshRoot '.env') -Value @(
        'DELTA_HOSTNAME=delta.example.test'
        "POSTGRES_PASSWORD=$placeholder"
    ) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $freshRoot '.delta-install.json') -Value (@{
        schemaVersion  = 1
        state          = 'installed'
        adminBootstrap = @{ completed = $true }
    } | ConvertTo-Json) -Encoding UTF8

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

    $label = if ($placeholder) { $placeholder } else { 'an empty value' }
    Reset-Case -Answers @('1', 'Fresh-Database-Password', 'Fresh-Database-Password')
    $freshSettings = Invoke-SettingsOnFreshInstall -Root $freshRoot 6>$null

    Assert-Equal "$label is asked about"      $true $freshSettings.AskedPostgresPassword
    Assert-Equal "$label asks the choice first" 'Choose 1 or 2 [2]' $Script:Prompts[0]
    Assert-Equal "$label then the password"   'Database password' $Script:Prompts[1]
    Assert-Equal "$label then the confirmation" 'Confirm database password' $Script:Prompts[2]
    Assert-Equal "$label carries the chosen value out" `
        'Fresh-Database-Password' (ConvertTo-DeltaPlainText -SecureString $freshSettings.PostgresPassword)
    Assert-Equal "$label leaves the administrator alone" $false $freshSettings.AskedAdminPassword

    Remove-Item -LiteralPath $freshRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Start-TestCase 'A non-interactive run asks nothing and invents nothing'

$quietRoot = Join-Path $env:TEMP "delta-dbpw-quiet-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$null = New-Item -ItemType Directory -Path $quietRoot -Force
Set-Content -LiteralPath (Join-Path $quietRoot '.env') -Value @(
    'DELTA_HOSTNAME=delta.example.test'
    'POSTGRES_PASSWORD=__GENERATE__'
) -Encoding UTF8

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
try { $quiet = Invoke-SettingsNonInteractive -Root $quietRoot 6>$null }
catch { $threw = $_ }

Assert-That  'nothing was asked'                      ($null -eq $threw)
Assert-Equal 'the database question was not reached'  $false $quiet.AskedPostgresPassword
Assert-Equal 'and no password was decided here'       $true ($null -eq $quiet.PostgresPassword)

# __GENERATE__ is left in place for the stack stage to resolve, exactly as
# before. This UX change must not have moved that decision earlier.
Assert-Equal 'the .env placeholder is untouched' '__GENERATE__' `
    (Get-DeltaEnvValue -Path (Join-Path $quietRoot '.env') -Key 'POSTGRES_PASSWORD')

Remove-Item -LiteralPath $quietRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $configuredRoot -Recurse -Force -ErrorAction SilentlyContinue

# --- the administrator credential is not disturbed --------------------------

Start-TestCase 'The administrator question keeps its own wording'

# Both credentials now share one implementation. The risk that creates is one
# credential's wording leaking into the other, so the two are asked here in the
# same process and required to differ where they must.
function Invoke-AdminChoice {
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
    $Script:Result = Read-DeltaAdministratorPassword -GeneratedLength 20
}

Reset-Case -Answers @('1', 'Administrator-Own-Password', 'Administrator-Own-Password')
$Script:Output = @(Invoke-AdminChoice 6>&1 | ForEach-Object { [string]$_ })

Assert-That  'it still names the administrator credential' (Test-OutputContains -Text 'DELTA administrator password')
Assert-That  'and the account it is for'                   (Test-OutputContains -Text 'admin@admin.com')
Assert-Equal 'its entry prompt is unchanged'               'Administrator password' $Script:Prompts[1]
Assert-Equal 'its confirmation prompt is unchanged'        'Confirm administrator password' $Script:Prompts[2]
Assert-That  'no database wording leaked in'               (-not (Test-OutputContains -Text 'PostgreSQL'))
Assert-Equal 'and the typed credential is carried out'     'Administrator-Own-Password' (Get-PlainResult)

Reset-Case -Answers @('')
$Script:Output = @(Invoke-AdminChoice 6>&1 | ForEach-Object { [string]$_ })
Assert-That  'a generated administrator password is still announced as shown once' `
    (Test-OutputContains -Text 'It is shown once when')
Assert-Equal 'and it is still generated at length 20' 20 (Get-PlainResult).Length

# --- shared implementation, not duplicated logic ----------------------------

Start-TestCase 'Both credentials go through one implementation'

$configText = Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1') -Raw

Assert-That 'there is one question implementation'  ($configText -match 'function Read-DeltaPasswordChoice')
Assert-That 'and one masked-entry implementation'   ($configText -match 'function Read-DeltaTypedPasswordEntry')
Assert-That 'the administrator wrapper delegates'   ($configText -match '(?s)function Read-DeltaAdministratorPassword\b.*?Read-DeltaPasswordChoice')
Assert-That 'the database wrapper delegates'        ($configText -match '(?s)function Read-DeltaPostgresPassword\b.*?Read-DeltaPasswordChoice')

# The generator and the masked read are each written once. A second copy is how
# the two credentials drift apart again.
Assert-Equal 'New-DeltaPassword is called from one place in the choice flow' 1 `
    (@([regex]::Matches($configText, '(?s)function Read-DeltaPasswordChoice.*?(?=\nfunction )')[0].Value |
        ForEach-Object { [regex]::Matches($_, 'New-DeltaPassword -Length') }).Count)
# Code only. The comments explain what `[Enter = generate]` was and why it went,
# and an assertion that counted those would be pinned to the prose.
$Script:ConfigCode = -join ([System.Management.Automation.PSParser]::Tokenize($configText, [ref]$null) |
    Where-Object { $_.Type -ne 'Comment' } | ForEach-Object { $_.Content + ' ' })

Assert-That 'the retired empty-means-generate prompt is gone from the code' `
    ($Script:ConfigCode -notmatch '\[Enter = generate\]')
Assert-That 'and Read-DeltaInstallPassword no longer exists' `
    ($configText -notmatch 'function Read-DeltaInstallPassword')

Write-Host ''
Write-Host ('-' * 60)
Write-Host "  passed: $Script:Passed"
Write-Host "  failed: $Script:Failed"
Write-Host ('-' * 60)
Write-Host ''

if ($Script:Failed -gt 0) { exit 1 }
exit 0
