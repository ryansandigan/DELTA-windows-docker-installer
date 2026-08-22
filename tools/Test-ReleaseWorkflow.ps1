#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for .github\workflows\release.yml.

.DESCRIPTION
    Runs the release workflow's own logic locally, against disposable
    fixtures, without pushing a tag or publishing anything.

    The scripts under test are not restated here: each step's `run:` block
    is extracted from release.yml itself, its ${{ ... }} expressions are
    substituted the way GitHub Actions would substitute them, and the
    result is executed in a sandbox checkout. A test therefore fails if the
    workflow's real text breaks - not merely if a copy of it does. The
    release step's `files:` list is read from the same file and checked
    against what tools\build-release.ps1 actually produced, which is what
    ties the published asset names to the packager.

    Dependency-free, like tools\Test-Release.ps1: the small amount of YAML
    understanding needed (locate a step, read a block scalar) is
    implemented here rather than requiring a YAML module on the machine.

    Two known and deliberate differences from a real run:

    - The workflow declares 'shell: pwsh' (PowerShell 7); these tests
      execute the extracted scripts under Windows PowerShell 5.1, the
      shell this repository targets everywhere else. Every construct the
      workflow uses behaves identically in both. The one exception is
      Set-Content -Encoding utf8, which writes a BOM in 5.1 and none in 7,
      so no assertion here depends on the release-notes file's BOM.

    - Steps that only GitHub can perform - checkout, and the
      softprops/action-gh-release publish - are not executed. What the
      publish step *would* upload is asserted instead, from the YAML.

    Exits 0 if every test passes, 1 otherwise.

.PARAMETER KeepArtifacts
    Leaves the sandbox checkouts on disk and prints their paths, instead
    of deleting them. For inspecting a failure.

.EXAMPLE
    .\tools\Test-ReleaseWorkflow.ps1
#>

[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot  = Split-Path -Parent $PSScriptRoot
$Script:WorkflowPath = Join-Path -Path $Script:ProjectRoot -ChildPath '.github\workflows\release.yml'
$Script:WorkRoot     = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("delta-workflow-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Script:Passed = 0
$Script:Failed = 0

# Step names, spelled once. A rename in release.yml surfaces here as a
# clear "step not found" failure rather than a silently skipped test.
$Script:StepVersion   = 'Derive release version from tag'
$Script:StepVerify    = 'Verify installer version matches Git tag'
$Script:StepNotes     = 'Extract release notes from changelog'
$Script:StepBuild     = 'Build release package'
$Script:StepArtifacts = 'Verify release artifacts exist'
$Script:StepPublish   = 'Create GitHub release'

# ---------------------------------------------------------------------------
# Output + assertion helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Detail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message"
}

function Assert-That {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()]$Condition
    )

    if ($Condition) {
        Write-Host "    [PASS] $Description" -ForegroundColor Green
        $Script:Passed++
    }
    else {
        Write-Host "    [FAIL] $Description" -ForegroundColor Red
        $Script:Failed++
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Expected,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Actual
    )

    if ($Expected -ceq $Actual) {
        Write-Host "    [PASS] $Description" -ForegroundColor Green
        $Script:Passed++
    }
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
    Write-Step $Name
}

# ---------------------------------------------------------------------------
# Minimal YAML reading
#
# Enough to locate a named step and read one of its scalars - inline
# (`run: cmd`) or literal block (`run: |`). Not a YAML parser, and not
# trying to be: it understands only the two shapes release.yml uses, and
# throws rather than guessing on anything else.
# ---------------------------------------------------------------------------

function Get-WorkflowLines {
    if (-not (Test-Path -LiteralPath $Script:WorkflowPath -PathType Leaf)) {
        throw "Workflow not found: $($Script:WorkflowPath)"
    }
    return @(Get-Content -LiteralPath $Script:WorkflowPath)
}

function Get-LineIndent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    if ($Line.Trim().Length -eq 0) { return [int]::MaxValue }
    return ($Line.Length - $Line.TrimStart(' ').Length)
}

function Get-StepLineRange {
    <#
      Returns the [start, end) line range of the step whose `- name:` value
      matches $StepName - from its own '- name:' line up to the next list
      item at the same indent, or end of file.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$StepName
    )

    $escaped = [regex]::Escape($StepName)
    $start = -1
    $indent = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^(?<pad>\s*)-\s+name:\s+$escaped\s*$") {
            $start = $i
            $indent = $Matches['pad'].Length
            break
        }
    }
    if ($start -lt 0) {
        throw "Step not found in release.yml: '$StepName'"
    }

    $end = $Lines.Count
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*-\s+name:\s' -and (Get-LineIndent -Line $Lines[$i]) -eq $indent) {
            $end = $i
            break
        }
    }

    return @($start, $end)
}

function Get-StepScalar {
    <#
      Reads $Key's value from within a step. A '|' value is collected as a
      literal block: every following line indented deeper than the key,
      dedented by the smallest indent among the block's non-blank lines.
      Anything else is returned as the rest of the line.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$StepName,
        [Parameter(Mandatory)][string]$Key
    )

    $range = Get-StepLineRange -Lines $Lines -StepName $StepName
    $start = $range[0]
    $end = $range[1]

    $escaped = [regex]::Escape($Key)
    for ($i = $start; $i -lt $end; $i++) {
        if ($Lines[$i] -notmatch "^(?<pad>\s*)$escaped\s*:(?<rest>.*)$") { continue }

        $keyIndent = $Matches['pad'].Length
        $rest = $Matches['rest'].Trim()

        if ($rest -ne '|' -and $rest -ne '|-') {
            return $rest
        }

        $block = @()
        for ($j = $i + 1; $j -lt $end; $j++) {
            $lineIndent = Get-LineIndent -Line $Lines[$j]
            if ($lineIndent -le $keyIndent) { break }
            $block += $Lines[$j]
        }

        $nonBlank = @($block | Where-Object { $_.Trim().Length -gt 0 })
        if ($nonBlank.Count -eq 0) { return '' }
        $dedent = ($nonBlank | ForEach-Object { Get-LineIndent -Line $_ } | Measure-Object -Minimum).Minimum

        $out = @($block | ForEach-Object {
            if ($_.Length -ge $dedent) { $_.Substring($dedent) } else { $_.Trim() }
        })
        return ($out -join "`n")
    }

    throw "Key '$Key' not found in step '$StepName'."
}

function Expand-WorkflowExpression {
    <#
      Substitutes ${{ ... }} the way Actions would. Every expression must
      have a mapping supplied by the caller - an unmapped one throws rather
      than expanding to empty string, so a workflow that starts consuming a
      new context value fails these tests loudly instead of being silently
      tested with a blank.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Script,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $evaluator = {
        param($match)
        $expr = $match.Groups[1].Value.Trim()
        if (-not $Values.ContainsKey($expr)) {
            throw "release.yml uses an expression this test has no value for: `${{ $expr }}"
        }
        return $Values[$expr]
    }.GetNewClosure()

    return [regex]::Replace($Script, '\$\{\{\s*(.*?)\s*\}\}', $evaluator)
}

# ---------------------------------------------------------------------------
# Sandbox + step execution
# ---------------------------------------------------------------------------

function New-SandboxCheckout {
    <#
      A copy of the repository as a tag checkout would present it: exactly
      the inputs the workflow reads (lib\Delta.Version.ps1, CHANGELOG.md)
      and everything tools\build-release.ps1 needs to package. No .git, no
      workflow file - nothing here runs Git or GitHub.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version,
        [string[]]$ChangelogVersions = @('1.0.0')
    )

    $path = Join-Path -Path $Script:WorkRoot -ChildPath $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $path 'tools') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $path 'bin') -Force | Out-Null

    foreach ($file in @('setup.ps1', 'uninstall.ps1', 'bin\start-delta.ps1', 'bin\rotate-nginx-logs.ps1', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $Script:ProjectRoot $file) -Destination (Join-Path $path $file) -Force
    }
    foreach ($dir in @('lib', 'templates')) {
        Copy-Item -LiteralPath (Join-Path $Script:ProjectRoot $dir) -Destination (Join-Path $path $dir) -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $Script:ProjectRoot 'tools\build-release.ps1') -Destination (Join-Path $path 'tools\build-release.ps1') -Force

    Set-VersionFileVersion -Path (Join-Path $path 'lib\Delta.Version.ps1') -Version $Version
    Write-Utf8NoBom -Path (Join-Path $path 'CHANGELOG.md') -Content (New-ChangelogContent -Versions $ChangelogVersions)

    return $path
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Set-VersionFileVersion {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Version
    )
    $content = [System.IO.File]::ReadAllText($Path)
    $content = [regex]::Replace($content, "(?m)^(\`$Script:DeltaInstallerVersion\s*=\s*)'[^']*'", "`$1'$Version'")
    Write-Utf8NoBom -Path $Path -Content $content
}

function New-ChangelogContent {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Versions)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Changelog`n`n")
    foreach ($v in $Versions) {
        [void]$sb.Append("## [$v]`n`n### Added`n`n- Added thing one for $v.`n- Added thing two for $v.`n`n### Fixed`n`n- Fixed a thing in $v.`n`n")
    }
    return $sb.ToString()
}

function Invoke-WorkflowStep {
    <#
      Executes one step's extracted script in a child Windows PowerShell,
      with the runner environment the workflow depends on
      (GITHUB_OUTPUT, RUNNER_TEMP) and the sandbox as the working
      directory. Returns the exit code, the console output, and any
      step outputs the script wrote to GITHUB_OUTPUT.
    #>
    param(
        [Parameter(Mandatory)][string]$StepName,
        [Parameter(Mandatory)][string]$SandboxPath,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $lines = Get-WorkflowLines
    $raw = Get-StepScalar -Lines $lines -StepName $StepName -Key 'run'
    $script = Expand-WorkflowExpression -Script $raw -Values $Values

    $runnerTemp = Join-Path -Path $SandboxPath -ChildPath '_runner_temp'
    New-Item -ItemType Directory -Path $runnerTemp -Force | Out-Null
    $outputFile = Join-Path -Path $runnerTemp -ChildPath 'github_output.txt'
    if (-not (Test-Path -LiteralPath $outputFile)) { New-Item -ItemType File -Path $outputFile | Out-Null }

    # The Actions runner appends this to every PowerShell step before
    # executing it, which is how a native command's (or a called script's)
    # non-zero exit becomes a failed step - without it, a step whose last
    # statement merely *set* $LASTEXITCODE would exit 0 here and the test
    # would be measuring the harness rather than the workflow.
    $scriptFile = Join-Path -Path $runnerTemp -ChildPath ('step_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    $runnerEpilogue = "`nif ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit `$LASTEXITCODE }`n"
    Write-Utf8NoBom -Path $scriptFile -Content ($script + $runnerEpilogue)

    $previousOutput = $env:GITHUB_OUTPUT
    $previousTemp = $env:RUNNER_TEMP
    $env:GITHUB_OUTPUT = $outputFile
    $env:RUNNER_TEMP = $runnerTemp

    Push-Location $SandboxPath
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptFile 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEap
        Pop-Location
        $env:GITHUB_OUTPUT = $previousOutput
        $env:RUNNER_TEMP = $previousTemp
    }

    $outputs = @{}
    foreach ($line in @(Get-Content -LiteralPath $outputFile -ErrorAction SilentlyContinue)) {
        if ($line -match '^(?<k>[^=]+)=(?<v>.*)$') { $outputs[$Matches['k']] = $Matches['v'] }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output | Out-String)
        Outputs  = $outputs
        Script   = $script
    }
}

function New-WorkflowValues {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [string]$Version,
        [string]$NotesPath = ''
    )
    if (-not $PSBoundParameters.ContainsKey('Version')) { $Version = ($Tag -replace '^v', '') }
    return @{
        'github.ref_name'               = $Tag
        'steps.version.outputs.version' = $Version
        'steps.notes.outputs.path'      = $NotesPath
        'secrets.GITHUB_TOKEN'          = 'dummy-token'
    }
}

# ---------------------------------------------------------------------------
# Test: extracted scripts are valid PowerShell
# ---------------------------------------------------------------------------

function Test-StepScriptsParse {
    Start-TestCase 'Every run: block in release.yml is valid PowerShell'

    $lines = Get-WorkflowLines
    $values = New-WorkflowValues -Tag 'v1.0.0' -NotesPath 'C:\temp\RELEASE_NOTES.md'

    foreach ($step in @($Script:StepVersion, $Script:StepVerify, $Script:StepNotes, $Script:StepBuild, $Script:StepArtifacts)) {
        $raw = Get-StepScalar -Lines $lines -StepName $step -Key 'run'
        Assert-That -Description "'$step' has a non-empty run block" -Condition ($raw.Trim().Length -gt 0)

        $expanded = Expand-WorkflowExpression -Script $raw -Values $values
        Assert-That -Description "'$step' contains no unexpanded expressions" -Condition ($expanded -notmatch '\$\{\{')

        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($expanded, [ref]$null, [ref]$errors) | Out-Null
        Assert-Equal -Description "'$step' parses as PowerShell" -Expected 0 -Actual @($errors).Count
    }
}

# ---------------------------------------------------------------------------
# Test: trigger, permissions and publish wiring
# ---------------------------------------------------------------------------

function Test-WorkflowWiring {
    Start-TestCase 'Trigger, permissions and publish wiring'

    $text = (Get-WorkflowLines) -join "`n"

    Assert-That -Description "triggers on pushed tags matching 'v*'" -Condition ($text -match "(?m)^on:\s*$[\s\S]{0,200}?^\s+push:\s*$[\s\S]{0,200}?^\s+tags:\s*$[\s\S]{0,80}?^\s+-\s+'v\*'\s*$")
    Assert-That -Description 'does not trigger on branch pushes' -Condition ($text -notmatch '(?m)^\s+branches:')
    Assert-That -Description 'does not trigger on pull requests' -Condition ($text -notmatch '(?m)^\s*pull_request:')
    Assert-That -Description "grants contents: write" -Condition ($text -match '(?m)^permissions:\s*$\s*^\s+contents:\s+write\s*$')
    Assert-That -Description 'grants no other permission' -Condition (@([regex]::Matches($text, '(?m)^\s{2}\w[\w-]*:\s+(write|read)\s*$')).Count -eq 1)
    Assert-That -Description 'runs on windows-latest' -Condition ($text -match '(?m)^\s+runs-on:\s+windows-latest\s*$')

    $lines = Get-WorkflowLines
    $publishRange = Get-StepLineRange -Lines $lines -StepName $Script:StepPublish
    $publishText = ($lines[$publishRange[0]..($publishRange[1] - 1)]) -join "`n"

    Assert-That -Description 'publishes with softprops/action-gh-release@v2' -Condition ($publishText -match 'uses:\s+softprops/action-gh-release@v2')
    Assert-That -Description 'publishes against the pushed tag' -Condition ((Get-StepScalar -Lines $lines -StepName $Script:StepPublish -Key 'tag_name') -eq '${{ github.ref_name }}')
    Assert-That -Description 'uses the extracted changelog notes as the body' -Condition ((Get-StepScalar -Lines $lines -StepName $Script:StepPublish -Key 'body_path') -eq '${{ steps.notes.outputs.path }}')
    Assert-That -Description 'fails when an asset glob matches nothing' -Condition ((Get-StepScalar -Lines $lines -StepName $Script:StepPublish -Key 'fail_on_unmatched_files') -eq 'true')
    Assert-That -Description 'passes GITHUB_TOKEN' -Condition ($publishText -match 'GITHUB_TOKEN:\s+\$\{\{\s*secrets\.GITHUB_TOKEN\s*\}\}')
    Assert-That -Description 'does not enable auto-generated release notes' -Condition ($publishText -notmatch 'generate_release_notes')

    $buildRun = Get-StepScalar -Lines $lines -StepName $Script:StepBuild -Key 'run'
    Assert-That -Description 'build step calls tools\build-release.ps1' -Condition ($buildRun -match [regex]::Escape('.\tools\build-release.ps1 -Version'))
    Assert-That -Description 'build step passes the tag-derived version' -Condition ($buildRun -match [regex]::Escape('${{ steps.version.outputs.version }}'))
}

# ---------------------------------------------------------------------------
# Test: version derivation from the tag
# ---------------------------------------------------------------------------

function Test-VersionDerivation {
    Start-TestCase 'Version is derived from the tag, and non-release tags are refused'

    $sandbox = New-SandboxCheckout -Name 'version-derivation' -Version '1.0.0'

    foreach ($case in @(
        @{ Tag = 'v1.0.0';    Version = '1.0.0' }
        @{ Tag = 'v2.14.100'; Version = '2.14.100' }
    )) {
        $result = Invoke-WorkflowStep -StepName $Script:StepVersion -SandboxPath $sandbox -Values (New-WorkflowValues -Tag $case.Tag)
        Assert-Equal -Description "$($case.Tag) is accepted" -Expected 0 -Actual $result.ExitCode
        Assert-Equal -Description "$($case.Tag) yields version $($case.Version)" -Expected $case.Version -Actual $result.Outputs['version']
    }

    foreach ($tag in @('vlatest', 'v1.0', 'v1.0.0-rc1', 'release-1.0.0')) {
        $result = Invoke-WorkflowStep -StepName $Script:StepVersion -SandboxPath $sandbox -Values (New-WorkflowValues -Tag $tag -Version 'unused')
        Assert-Equal -Description "$tag is refused" -Expected 1 -Actual $result.ExitCode
        Assert-That -Description "$tag refusal names the expected tag shape" -Condition ($result.Output -match "must be 'vX\.Y\.Z'")
    }
}

# ---------------------------------------------------------------------------
# Test: tag / version-file agreement (failure mode 1)
# ---------------------------------------------------------------------------

function Test-VersionMismatch {
    Start-TestCase 'Tag that disagrees with lib\Delta.Version.ps1 fails the release'

    $sandbox = New-SandboxCheckout -Name 'version-mismatch' -Version '1.0.0'

    $match = Invoke-WorkflowStep -StepName $Script:StepVerify -SandboxPath $sandbox -Values (New-WorkflowValues -Tag 'v1.0.0')
    Assert-Equal -Description 'matching tag and version file passes' -Expected 0 -Actual $match.ExitCode
    Assert-That -Description 'reports the match' -Condition ($match.Output -match 'Installer version matches Git tag')

    $mismatch = Invoke-WorkflowStep -StepName $Script:StepVerify -SandboxPath $sandbox -Values (New-WorkflowValues -Tag 'v9.9.9')
    Assert-Equal -Description 'mismatched tag fails' -Expected 1 -Actual $mismatch.ExitCode
    Assert-That -Description 'names the mismatch' -Condition ($mismatch.Output -match 'Version mismatch detected')
    Assert-That -Description 'prints the offending tag' -Condition ($mismatch.Output -match 'v9\.9\.9')
    Assert-That -Description 'prints the version file value' -Condition ($mismatch.Output -match '1\.0\.0')
    Assert-That -Description 'says the release was aborted' -Condition ($mismatch.Output -match 'Release aborted')

    # The version file is the only version source: a CHANGELOG entry for the
    # tagged version must not be able to stand in for it.
    $sandbox2 = New-SandboxCheckout -Name 'version-mismatch-changelog' -Version '1.0.0' -ChangelogVersions @('9.9.9')
    $result2 = Invoke-WorkflowStep -StepName $Script:StepVerify -SandboxPath $sandbox2 -Values (New-WorkflowValues -Tag 'v9.9.9')
    Assert-Equal -Description 'a matching CHANGELOG section does not excuse a version mismatch' -Expected 1 -Actual $result2.ExitCode
}

# ---------------------------------------------------------------------------
# Test: changelog extraction (failure mode 2)
# ---------------------------------------------------------------------------

function Test-ChangelogExtraction {
    Start-TestCase 'Release notes come from the tag''s CHANGELOG section'

    $sandbox = New-SandboxCheckout -Name 'changelog-ok' -Version '1.0.1' -ChangelogVersions @('1.0.1', '1.0.0')
    $result = Invoke-WorkflowStep -StepName $Script:StepNotes -SandboxPath $sandbox -Values (New-WorkflowValues -Tag 'v1.0.1')

    Assert-Equal -Description 'extraction succeeds' -Expected 0 -Actual $result.ExitCode
    Assert-That -Description 'writes a notes file path output' -Condition ($result.Outputs.ContainsKey('path'))

    $notes = [System.IO.File]::ReadAllText($result.Outputs['path'])
    Assert-That -Description 'body contains the tagged version notes' -Condition ($notes -match 'Added thing one for 1\.0\.1')
    Assert-That -Description 'body stops at the next release heading' -Condition ($notes -notmatch '1\.0\.0')
    Assert-That -Description 'body omits the version heading itself' -Condition ($notes -notmatch '(?m)^##\s+\[')
    Assert-That -Description 'body keeps category headings' -Condition ($notes -match '(?m)^### Added\s*$')
    Assert-That -Description 'body has no leading blank line' -Condition ($notes -notmatch '^\s*\r?\n')
    Assert-That -Description 'body has no trailing blank line' -Condition ($notes.TrimEnd("`r", "`n") -eq $notes -or $notes -notmatch '\r?\n\s*\r?\n$')

    # Last section in the file: must run to EOF rather than losing content.
    $sandboxLast = New-SandboxCheckout -Name 'changelog-last' -Version '1.0.0' -ChangelogVersions @('1.0.1', '1.0.0')
    $resultLast = Invoke-WorkflowStep -StepName $Script:StepNotes -SandboxPath $sandboxLast -Values (New-WorkflowValues -Tag 'v1.0.0')
    Assert-Equal -Description 'final changelog section extracts to EOF' -Expected 0 -Actual $resultLast.ExitCode
    $notesLast = [System.IO.File]::ReadAllText($resultLast.Outputs['path'])
    Assert-That -Description 'final section keeps its last line' -Condition ($notesLast -match 'Fixed a thing in 1\.0\.0')

    # Missing section.
    $sandboxMissing = New-SandboxCheckout -Name 'changelog-missing' -Version '1.0.2' -ChangelogVersions @('1.0.0')
    $resultMissing = Invoke-WorkflowStep -StepName $Script:StepNotes -SandboxPath $sandboxMissing -Values (New-WorkflowValues -Tag 'v1.0.2')
    Assert-That -Description 'missing section fails the job' -Condition ($resultMissing.ExitCode -ne 0)
    Assert-That -Description 'missing section names the heading it wanted' -Condition ($resultMissing.Output -match "no '## \[1\.0\.2\]' section")

    # Present but empty section - headings only, no content.
    $sandboxEmpty = New-SandboxCheckout -Name 'changelog-empty' -Version '1.0.3' -ChangelogVersions @()
    Write-Utf8NoBom -Path (Join-Path $sandboxEmpty 'CHANGELOG.md') -Content "# Changelog`n`n## [1.0.3]`n`n### Added`n`n### Fixed`n`n"
    $resultEmpty = Invoke-WorkflowStep -StepName $Script:StepNotes -SandboxPath $sandboxEmpty -Values (New-WorkflowValues -Tag 'v1.0.3')
    Assert-That -Description 'empty section fails the job' -Condition ($resultEmpty.ExitCode -ne 0)
    Assert-That -Description 'empty section says it has no content' -Condition ($resultEmpty.Output -match 'no release-note content')

    # No CHANGELOG.md at all in the tagged commit.
    $sandboxNone = New-SandboxCheckout -Name 'changelog-absent' -Version '1.0.0'
    Remove-Item -LiteralPath (Join-Path $sandboxNone 'CHANGELOG.md') -Force
    $resultNone = Invoke-WorkflowStep -StepName $Script:StepNotes -SandboxPath $sandboxNone -Values (New-WorkflowValues -Tag 'v1.0.0')
    Assert-That -Description 'absent CHANGELOG.md fails the job' -Condition ($resultNone.ExitCode -ne 0)
    Assert-That -Description 'absent CHANGELOG.md is reported clearly' -Condition ($resultNone.Output -match 'CHANGELOG\.md not found')
}

# ---------------------------------------------------------------------------
# Test: packaging + artifact verification (failure modes 3, 4, 5, and the
# happy path 6)
# ---------------------------------------------------------------------------

function Test-PackagingAndArtifacts {
    Start-TestCase 'Packaging produces the exact expected artifacts'

    $sandbox = New-SandboxCheckout -Name 'package-ok' -Version '1.0.0'
    $values = New-WorkflowValues -Tag 'v1.0.0'

    $build = Invoke-WorkflowStep -StepName $Script:StepBuild -SandboxPath $sandbox -Values $values
    Assert-Equal -Description 'build step succeeds' -Expected 0 -Actual $build.ExitCode

    $zip = Join-Path $sandbox 'release\DELTA-windows-installer-docker-1.0.0.zip'
    $sha = "$zip.sha256"
    Assert-That -Description 'ZIP is named DELTA-windows-installer-docker-1.0.0.zip' -Condition (Test-Path -LiteralPath $zip -PathType Leaf)
    Assert-That -Description 'checksum is named DELTA-windows-installer-docker-1.0.0.zip.sha256' -Condition (Test-Path -LiteralPath $sha -PathType Leaf)

    $verify = Invoke-WorkflowStep -StepName $Script:StepArtifacts -SandboxPath $sandbox -Values $values
    Assert-Equal -Description 'artifact verification passes' -Expected 0 -Actual $verify.ExitCode

    # The paths the publish step would upload must be the paths just built.
    $lines = Get-WorkflowLines
    $filesBlock = Expand-WorkflowExpression -Script (Get-StepScalar -Lines $lines -StepName $Script:StepPublish -Key 'files') -Values $values
    $assetPaths = @($filesBlock -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Assert-Equal -Description 'publish step uploads exactly two assets' -Expected 2 -Actual $assetPaths.Count
    foreach ($asset in $assetPaths) {
        Assert-That -Description "publish asset exists after build: $asset" -Condition (Test-Path -LiteralPath (Join-Path $sandbox $asset) -PathType Leaf)
    }

    # Checksum content is the real hash of the real ZIP, in sha256sum layout.
    $checksumLine = (Get-Content -LiteralPath $sha -Raw).Trim()
    $actualHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal -Description 'checksum matches the ZIP and names it' -Expected "$actualHash  DELTA-windows-installer-docker-1.0.0.zip" -Actual $checksumLine

    # The packaged installer carries the version that was released.
    $extract = Join-Path $sandbox '_extract'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)
    $packagedVersionFile = Join-Path $extract 'DELTA-windows-installer-docker-1.0.0\lib\Delta.Version.ps1'
    Assert-That -Description 'package contains lib\Delta.Version.ps1' -Condition (Test-Path -LiteralPath $packagedVersionFile -PathType Leaf)
    if (Test-Path -LiteralPath $packagedVersionFile -PathType Leaf) {
        $packaged = [regex]::Match([System.IO.File]::ReadAllText($packagedVersionFile), "(?m)^\`$Script:DeltaInstallerVersion\s*=\s*'([^']*)'").Groups[1].Value
        Assert-Equal -Description 'packaged installer declares the released version' -Expected '1.0.0' -Actual $packaged
    }

    # The operational scripts ship under bin\ and are not duplicated at the
    # package root: the scheduled tasks the installer registers point at
    # <install root>\bin\, so a package that put them anywhere else would
    # install and then fail at boot, or silently at 03:30.
    $packageRoot = Join-Path $extract 'DELTA-windows-installer-docker-1.0.0'
    foreach ($script in @('start-delta.ps1', 'rotate-nginx-logs.ps1')) {
        Assert-That -Description "package contains bin\$script" -Condition (Test-Path -LiteralPath (Join-Path $packageRoot "bin\$script") -PathType Leaf)
        Assert-That -Description "package does not contain $script at its root" -Condition (-not (Test-Path -LiteralPath (Join-Path $packageRoot $script) -PathType Leaf))
    }

    Start-TestCase 'Missing artifacts fail before publication'

    # ZIP missing.
    $noZip = New-SandboxCheckout -Name 'artifact-no-zip' -Version '1.0.0'
    Invoke-WorkflowStep -StepName $Script:StepBuild -SandboxPath $noZip -Values $values | Out-Null
    Remove-Item -LiteralPath (Join-Path $noZip 'release\DELTA-windows-installer-docker-1.0.0.zip') -Force
    $resultNoZip = Invoke-WorkflowStep -StepName $Script:StepArtifacts -SandboxPath $noZip -Values $values
    Assert-That -Description 'missing ZIP fails the job' -Condition ($resultNoZip.ExitCode -ne 0)
    Assert-That -Description 'missing ZIP is named in the error' -Condition ($resultNoZip.Output -match 'DELTA-windows-installer-docker-1\.0\.0\.zip')

    # Checksum missing.
    $noSha = New-SandboxCheckout -Name 'artifact-no-sha' -Version '1.0.0'
    Invoke-WorkflowStep -StepName $Script:StepBuild -SandboxPath $noSha -Values $values | Out-Null
    Remove-Item -LiteralPath (Join-Path $noSha 'release\DELTA-windows-installer-docker-1.0.0.zip.sha256') -Force
    $resultNoSha = Invoke-WorkflowStep -StepName $Script:StepArtifacts -SandboxPath $noSha -Values $values
    Assert-That -Description 'missing checksum fails the job' -Condition ($resultNoSha.ExitCode -ne 0)
    Assert-That -Description 'missing checksum is named in the error' -Condition ($resultNoSha.Output -match '\.sha256')

    # Build itself fails - a required file is absent from the tagged commit.
    $badBuild = New-SandboxCheckout -Name 'package-fails' -Version '1.0.0'
    Remove-Item -LiteralPath (Join-Path $badBuild 'bin\start-delta.ps1') -Force
    $resultBad = Invoke-WorkflowStep -StepName $Script:StepBuild -SandboxPath $badBuild -Values $values
    Assert-That -Description 'failed packaging fails the job' -Condition ($resultBad.ExitCode -ne 0)
    Assert-That -Description 'failed packaging names the missing file' -Condition ($resultBad.Output -match 'start-delta\.ps1')
    Assert-That -Description 'no ZIP is left behind by a failed build' -Condition (-not (Test-Path -LiteralPath (Join-Path $badBuild 'release\DELTA-windows-installer-docker-1.0.0.zip')))

    # Defence in depth: even if a failed build were somehow to report
    # success, the artifact check standing between it and publication
    # refuses on its own.
    $resultBadArtifacts = Invoke-WorkflowStep -StepName $Script:StepArtifacts -SandboxPath $badBuild -Values $values
    Assert-That -Description 'artifact check independently refuses after a failed build' -Condition ($resultBadArtifacts.ExitCode -ne 0)
}

# ---------------------------------------------------------------------------
# Test: the full happy path, in workflow order
# ---------------------------------------------------------------------------

function Test-EndToEndHappyPath {
    Start-TestCase 'Full workflow sequence for a valid tag'

    $sandbox = New-SandboxCheckout -Name 'end-to-end' -Version '1.0.0'
    $tag = 'v1.0.0'

    $version = Invoke-WorkflowStep -StepName $Script:StepVersion -SandboxPath $sandbox -Values (New-WorkflowValues -Tag $tag -Version 'unused')
    Assert-Equal -Description '1. version derived' -Expected 0 -Actual $version.ExitCode
    $resolved = $version.Outputs['version']
    Assert-Equal -Description '   version is 1.0.0' -Expected '1.0.0' -Actual $resolved

    $values = New-WorkflowValues -Tag $tag -Version $resolved

    $verify = Invoke-WorkflowStep -StepName $Script:StepVerify -SandboxPath $sandbox -Values $values
    Assert-Equal -Description '2. tag matches version file' -Expected 0 -Actual $verify.ExitCode

    $notes = Invoke-WorkflowStep -StepName $Script:StepNotes -SandboxPath $sandbox -Values $values
    Assert-Equal -Description '3. release notes extracted' -Expected 0 -Actual $notes.ExitCode

    $values['steps.notes.outputs.path'] = $notes.Outputs['path']

    $build = Invoke-WorkflowStep -StepName $Script:StepBuild -SandboxPath $sandbox -Values $values
    Assert-Equal -Description '4. package built' -Expected 0 -Actual $build.ExitCode

    $artifacts = Invoke-WorkflowStep -StepName $Script:StepArtifacts -SandboxPath $sandbox -Values $values
    Assert-Equal -Description '5. artifacts verified' -Expected 0 -Actual $artifacts.ExitCode

    # Everything the publish step needs is now present and non-empty.
    $lines = Get-WorkflowLines
    $bodyPath = Expand-WorkflowExpression -Script (Get-StepScalar -Lines $lines -StepName $Script:StepPublish -Key 'body_path') -Values $values
    $tagName = Expand-WorkflowExpression -Script (Get-StepScalar -Lines $lines -StepName $Script:StepPublish -Key 'tag_name') -Values $values
    Assert-Equal -Description '6. release would be published for v1.0.0' -Expected 'v1.0.0' -Actual $tagName
    Assert-That -Description '   release body file exists' -Condition (Test-Path -LiteralPath $bodyPath -PathType Leaf)
    Assert-That -Description '   release body is not empty' -Condition ((Get-Content -LiteralPath $bodyPath -Raw).Trim().Length -gt 0)

    $filesBlock = Expand-WorkflowExpression -Script (Get-StepScalar -Lines $lines -StepName $Script:StepPublish -Key 'files') -Values $values
    $assets = @($filesBlock -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Assert-Equal -Description '   asset 1 is the versioned ZIP' -Expected 'release/DELTA-windows-installer-docker-1.0.0.zip' -Actual $assets[0]
    Assert-Equal -Description '   asset 2 is its .sha256' -Expected 'release/DELTA-windows-installer-docker-1.0.0.zip.sha256' -Actual $assets[1]
}

# ---------------------------------------------------------------------------
# Test: the two halves agree on one contract
#
# release.ps1 and release.yml each enforce the tag, version and CHANGELOG
# rules independently - that redundancy is the point, since the local half
# catches mistakes before a tag is public. It is only useful while the two
# agree, so the shared literals are compared here directly. A change to one
# side alone fails this test rather than surfacing as a release that passes
# locally and then fails in Actions.
# ---------------------------------------------------------------------------

function Test-ContractConsistency {
    Start-TestCase 'release.ps1, release.yml and build-release.ps1 share one contract'

    $release  = [System.IO.File]::ReadAllText((Join-Path $Script:ProjectRoot 'release.ps1'))
    $workflow = [System.IO.File]::ReadAllText($Script:WorkflowPath)
    $builder  = [System.IO.File]::ReadAllText((Join-Path $Script:ProjectRoot 'tools\build-release.ps1'))
    $readme   = [System.IO.File]::ReadAllText((Join-Path $Script:ProjectRoot 'README.md'))

    # Version shape.
    $semver = "'^\d+\.\d+\.\d+$'"
    Assert-That -Description 'release.ps1 defines the X.Y.Z version shape' -Condition ($release.Contains($semver))
    Assert-That -Description 'release.yml enforces the same version shape' -Condition ($workflow.Contains($semver))

    # CHANGELOG heading contract, in all three of its parts.
    foreach ($fragment in @(
        '"^##\s+\[$([regex]::Escape(',
        "'^##\s+\['",
        "`$_ -notmatch '^###\s'"
    )) {
        Assert-That -Description "release.ps1 uses changelog rule: $fragment" -Condition ($release.Contains($fragment))
        Assert-That -Description "release.yml uses changelog rule: $fragment" -Condition ($workflow.Contains($fragment))
    }

    # Tag shape: release.ps1 mints it, release.yml consumes it.
    Assert-That -Description 'release.ps1 mints vX.Y.Z tags' -Condition ($release -match '\$tagName\s*=\s*"v\$nextVersion"')
    Assert-That -Description 'release.yml triggers on v* tags' -Condition ($workflow -match "(?m)^\s+-\s+'v\*'\s*$")
    Assert-That -Description 'release.yml strips only the leading v' -Condition ($workflow -match "\`$tag\s+-replace\s+'\^v',\s*''")

    # Package naming: build-release.ps1 owns it; everyone else must match.
    $packagePrefix = 'DELTA-windows-installer-docker-'
    Assert-That -Description 'build-release.ps1 defines the package name' -Condition ($builder -match ([regex]::Escape("`$Script:PackageName  = `"$packagePrefix`$Version`"")))
    Assert-That -Description 'release.yml verifies that ZIP name' -Condition ($workflow.Contains("release/$packagePrefix`$version.zip"))
    Assert-That -Description 'release.yml uploads that ZIP name' -Condition ($workflow.Contains("release/$packagePrefix`${{ steps.version.outputs.version }}.zip"))
    Assert-That -Description 'release.yml uploads that checksum name' -Condition ($workflow.Contains("release/$packagePrefix`${{ steps.version.outputs.version }}.zip.sha256"))
    Assert-That -Description 'release.ps1 previews that ZIP name' -Condition ($release.Contains("$packagePrefix`$nextVersion.zip"))
    Assert-That -Description 'release.ps1 previews that checksum name' -Condition ($release.Contains("$packagePrefix`$nextVersion.zip.sha256"))
    Assert-That -Description 'README documents that ZIP name' -Condition ($readme.Contains("${packagePrefix}X.Y.Z.zip"))
    Assert-That -Description 'README documents that checksum name' -Condition ($readme.Contains("${packagePrefix}X.Y.Z.zip.sha256"))

    # Checksum is always the ZIP name plus .sha256 - never an independent name.
    Assert-That -Description 'build-release.ps1 derives the checksum from the ZIP path' -Condition ($builder -match ([regex]::Escape('$Script:ChecksumPath = "$Script:ZipPath.sha256"')))
    Assert-That -Description 'release.yml derives the checksum from the ZIP path' -Condition ($workflow -match ([regex]::Escape('$checksum = "$zip.sha256"')))

    # Version source: exactly one, read the same way on both sides.
    Assert-That -Description 'release.ps1 reads lib\Delta.Version.ps1' -Condition ($release -match [regex]::Escape("'lib\Delta.Version.ps1'"))
    Assert-That -Description 'release.yml reads lib\Delta.Version.ps1' -Condition ($workflow -match [regex]::Escape('. .\lib\Delta.Version.ps1'))
    Assert-That -Description 'both read $Script:DeltaInstallerVersion' -Condition ($release.Contains('$Script:DeltaInstallerVersion') -and $workflow.Contains('$Script:DeltaInstallerVersion'))
    Assert-That -Description 'release.yml derives no version from CHANGELOG.md' -Condition ($workflow -notmatch '(?m)^\s*\$version\s*=.*CHANGELOG')

    # The operator-facing documentation must not send anyone back to the packager.
    Assert-That -Description 'README does not present build-release.ps1 as a release step' -Condition ($readme -match 'Building the package by hand \(development only\)')
    Assert-That -Description 'README no longer claims the tag publishes nothing' -Condition ($readme -notmatch 'does not publish anything yet')
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

$overallExit = 1
try {
    Write-Step 'DELTA release.yml regression tests'
    Write-Detail "Workflow under test: $($Script:WorkflowPath)"
    Write-Detail "Sandbox checkouts:   $($Script:WorkRoot)"
    New-Item -ItemType Directory -Path $Script:WorkRoot -Force | Out-Null

    Test-StepScriptsParse
    Test-WorkflowWiring
    Test-VersionDerivation
    Test-VersionMismatch
    Test-ChangelogExtraction
    Test-PackagingAndArtifacts
    Test-EndToEndHappyPath
    Test-ContractConsistency

    Write-Host ''
    Write-Step 'Summary'
    Write-Detail "Passed: $($Script:Passed)"
    Write-Detail "Failed: $($Script:Failed)"

    if ($Script:Failed -eq 0) {
        Write-Host ''
        Write-Host 'All release.yml regression tests passed.' -ForegroundColor Green
        $overallExit = 0
    }
    else {
        Write-Host ''
        Write-Host "$($Script:Failed) release.yml regression test assertion(s) failed." -ForegroundColor Red
        $overallExit = 1
    }
}
catch {
    Write-Host ''
    Write-Host 'Test run failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    $overallExit = 1
}
finally {
    if ($KeepArtifacts) {
        Write-Detail "Artifacts kept at: $($Script:WorkRoot)"
    }
    elseif (Test-Path -LiteralPath $Script:WorkRoot) {
        Remove-Item -LiteralPath $Script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $overallExit
