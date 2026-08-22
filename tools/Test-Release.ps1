#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for release.ps1.

.DESCRIPTION
    Exercises release.ps1 against disposable Git repositories created under
    the user's TEMP directory - each with its own local bare 'origin', so
    every push, tag and commit the script makes lands in a throwaway
    repository and never touches this checkout or GitHub. Nothing here reads
    or writes the live installation.

    Deliberately dependency-free: no Pester, no modules, no network. This
    repository has no test infrastructure to hang a suite off, and the one
    thing worth testing here - a release script - is exactly the thing you
    want runnable from a bare checkout with nothing installed.

    Two classes of test:

    - End-to-end: release.ps1 is run as a child powershell.exe process
      inside a seeded repository, and the resulting commits, tags and file
      bytes are asserted. Running it out-of-process keeps each case honest
      about exit codes and shares no state between cases.

    - Version-file round-trip: Update-VersionFile is lifted out of
      release.ps1 by parsing the script's AST and evaluating just that
      function, so the assertions run against the real regex rather than a
      copy of it. This is the only way to test the same-version rewrite,
      since the release path now skips the rewrite entirely in that case.

    Exits 0 if every test passes, 1 otherwise.

.PARAMETER KeepArtifacts
    Leaves the temporary repositories on disk and prints their paths,
    instead of deleting them. For inspecting a failure.

.EXAMPLE
    .\tools\Test-Release.ps1
#>

[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot  = Split-Path -Parent $PSScriptRoot
$Script:ReleaseePath = Join-Path -Path $Script:ProjectRoot -ChildPath 'release.ps1'
$Script:VersionFile  = Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\Delta.Version.ps1'
$Script:WorkRoot     = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("delta-release-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Script:Passed = 0
$Script:Failed = 0
$Script:Current = ''

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
    $Script:Current = $Name
    Write-Host ''
    Write-Step $Name
}

# ---------------------------------------------------------------------------
# File helpers
#
# Every byte-level assertion goes through these: line-ending and
# trailing-newline preservation is the whole point of one of the fixes, and
# text comparison would hide exactly the regression being guarded against.
# ---------------------------------------------------------------------------

function Get-FileBytesHex {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return '' }
    return (($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join '')
}

function Test-HasBom {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function New-VersionFileContent {
    <#
      Builds a version-file fixture from the real lib\Delta.Version.ps1 -
      same comment block, same assignment shape - re-terminated with the
      requested line ending. Using the real file keeps the fixture honest;
      normalising the endings is what lets one test assert LF survives and
      another assert CRLF does.
    #>
    param(
        [Parameter(Mandatory)][string]$NewVersion,
        [ValidateSet('LF', 'CRLF')][string]$LineEnding = 'LF',
        [switch]$NoTrailingNewline
    )

    $raw = [System.IO.File]::ReadAllText($Script:VersionFile)
    $raw = $raw -replace "`r`n", "`n"
    $raw = [regex]::Replace($raw, "(?m)^(\`$Script:DeltaInstallerVersion\s*=\s*)'[^']*'", "`$1'$NewVersion'")
    $raw = $raw.TrimEnd("`n")
    if (-not $NoTrailingNewline) { $raw += "`n" }
    if ($LineEnding -eq 'CRLF') { $raw = $raw -replace "`n", "`r`n" }
    return $raw
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function New-ChangelogContent {
    <#
      Synthetic rather than a copy of the repository's CHANGELOG.md: these
      tests need populated sections for several versions at once, and must
      not start failing the day the real changelog gains or loses one.
    #>
    param([Parameter(Mandatory)][string[]]$Versions)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Changelog`n`n")
    foreach ($v in $Versions) {
        [void]$sb.Append("## [$v]`n`n### Added`n`n- Test release notes for $v.`n`n")
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [switch]$AllowFailure
    )

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $RepoPath @ArgumentList 2>&1
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "git $($ArgumentList -join ' ') failed in ${RepoPath}: $(($output | Out-String).Trim())"
    }

    return ($output | Out-String).Trim()
}

function New-TestRepo {
    <#
      Creates a disposable repository with a local bare 'origin' and the
      three files release.ps1 touches or reads: itself, lib\Delta.Version.ps1
      and CHANGELOG.md. core.autocrlf is forced off so the working tree keeps
      exactly the bytes written - otherwise Git's own line-ending conversion,
      not release.ps1, would decide what the round-trip tests observe.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [string[]]$ChangelogVersions = @('1.0.0', '1.0.1', '2.1.0'),
        [ValidateSet('LF', 'CRLF')][string]$LineEnding = 'LF'
    )

    $caseRoot = Join-Path -Path $Script:WorkRoot -ChildPath $Name
    $originPath = Join-Path -Path $caseRoot -ChildPath 'origin.git'
    $workPath = Join-Path -Path $caseRoot -ChildPath 'work'

    New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git init --bare --quiet $originPath 2>&1 | Out-Null
        & git clone --quiet $originPath $workPath 2>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    Invoke-Git -RepoPath $workPath -ArgumentList @('config', 'user.email', 'release-tests@example.invalid') | Out-Null
    Invoke-Git -RepoPath $workPath -ArgumentList @('config', 'user.name', 'Release Tests') | Out-Null
    Invoke-Git -RepoPath $workPath -ArgumentList @('config', 'core.autocrlf', 'false') | Out-Null

    New-Item -ItemType Directory -Path (Join-Path $workPath 'lib') -Force | Out-Null
    Copy-Item -LiteralPath $Script:ReleaseePath -Destination (Join-Path $workPath 'release.ps1') -Force
    Write-Utf8NoBom -Path (Join-Path $workPath 'lib\Delta.Version.ps1') -Content (New-VersionFileContent -NewVersion $CurrentVersion -LineEnding $LineEnding)
    Write-Utf8NoBom -Path (Join-Path $workPath 'CHANGELOG.md') -Content (New-ChangelogContent -Versions $ChangelogVersions)

    Invoke-Git -RepoPath $workPath -ArgumentList @('add', '-A') | Out-Null
    Invoke-Git -RepoPath $workPath -ArgumentList @('commit', '--quiet', '-m', 'test: seed repository') | Out-Null
    Invoke-Git -RepoPath $workPath -ArgumentList @('branch', '-M', 'main') | Out-Null
    Invoke-Git -RepoPath $workPath -ArgumentList @('push', '--quiet', '-u', 'origin', 'main') | Out-Null

    return [pscustomobject]@{
        Root        = $caseRoot
        Origin      = $originPath
        Work        = $workPath
        VersionFile = Join-Path $workPath 'lib\Delta.Version.ps1'
    }
}

function Invoke-Release {
    <#
      Runs release.ps1 out-of-process, with the test repository as the
      working directory, so its 'exit' codes are real process exit codes and
      no scope, strict-mode setting or $Script: variable leaks between cases.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$ReleaseArgs = @()
    )

    $scriptPath = Join-Path -Path $RepoPath -ChildPath 'release.ps1'
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $ReleaseArgs

    Push-Location $RepoPath
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe @psArgs 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEap
        Pop-Location
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output | Out-String)
    }
}

function Get-RepoState {
    param([Parameter(Mandatory)]$Repo)

    return [pscustomobject]@{
        Head        = Invoke-Git -RepoPath $Repo.Work -ArgumentList @('rev-parse', 'HEAD')
        CommitCount = [int](Invoke-Git -RepoPath $Repo.Work -ArgumentList @('rev-list', '--count', 'HEAD'))
        Tags        = Invoke-Git -RepoPath $Repo.Work -ArgumentList @('tag', '--list')
        Status      = Invoke-Git -RepoPath $Repo.Work -ArgumentList @('status', '--porcelain')
        VersionHex  = Get-FileBytesHex -Path $Repo.VersionFile
    }
}

function Get-DeclaredVersion {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $m = [regex]::Match($text, "(?m)^\`$Script:DeltaInstallerVersion\s*=\s*'([^']*)'")
    if (-not $m.Success) { return '<no assignment found>' }
    return $m.Groups[1].Value
}

# ---------------------------------------------------------------------------
# Test 1 - bootstrap: explicit version equal to current, no existing tag
# ---------------------------------------------------------------------------

function Test-BootstrapEqualVersionNoTag {
    Start-TestCase 'Explicit version equals current, no existing tag (first-release bootstrap)'

    $repo = New-TestRepo -Name 'bootstrap-no-tag' -CurrentVersion '1.0.0'
    $before = Get-RepoState -Repo $repo

    $result = Invoke-Release -RepoPath $repo.Work -ReleaseArgs @('-Version', '1.0.0')
    $after = Get-RepoState -Repo $repo

    Assert-Equal -Description 'exits 0' -Expected 0 -Actual $result.ExitCode
    Assert-Equal -Description 'creates no new commit' -Expected $before.CommitCount -Actual $after.CommitCount
    Assert-Equal -Description 'HEAD is unchanged' -Expected $before.Head -Actual $after.Head
    Assert-Equal -Description 'version file is byte-identical' -Expected $before.VersionHex -Actual $after.VersionHex
    Assert-Equal -Description 'tag v1.0.0 exists locally' -Expected 'v1.0.0' -Actual $after.Tags
    Assert-Equal -Description 'working tree is clean' -Expected '' -Actual $after.Status

    $tagTarget = Invoke-Git -RepoPath $repo.Work -ArgumentList @('rev-list', '-n', '1', 'v1.0.0')
    Assert-Equal -Description 'tag points at the pre-existing HEAD' -Expected $before.Head -Actual $tagTarget

    $tagType = Invoke-Git -RepoPath $repo.Work -ArgumentList @('cat-file', '-t', 'v1.0.0')
    Assert-Equal -Description 'tag is annotated' -Expected 'tag' -Actual $tagType

    $remoteTags = Invoke-Git -RepoPath $repo.Work -ArgumentList @('ls-remote', '--tags', 'origin')
    Assert-That -Description 'tag was pushed to origin' -Condition ($remoteTags -match 'refs/tags/v1\.0\.0')

    Assert-That -Description 'reports that no bump was required' -Condition ($result.Output -match 'already declares 1\.0\.0')
    Assert-That -Description 'does not claim a version bump was committed' -Condition ($result.Output -notmatch 'Committing version bump')
}

# ---------------------------------------------------------------------------
# Test 2 - bootstrap must not become a re-release door
# ---------------------------------------------------------------------------

function Test-BootstrapEqualVersionExistingTag {
    Start-TestCase 'Explicit version equals current, tag already exists (must refuse)'

    $repo = New-TestRepo -Name 'bootstrap-existing-tag' -CurrentVersion '1.0.0'
    Invoke-Git -RepoPath $repo.Work -ArgumentList @('tag', '-a', 'v1.0.0', '-m', 'pre-existing tag') | Out-Null
    $before = Get-RepoState -Repo $repo

    $result = Invoke-Release -RepoPath $repo.Work -ReleaseArgs @('-Version', '1.0.0')
    $after = Get-RepoState -Repo $repo

    Assert-Equal -Description 'exits 1' -Expected 1 -Actual $result.ExitCode
    Assert-That -Description 'existing-tag guardrail is what refused it' -Condition ($result.Output -match "Tag 'v1\.0\.0' already exists")
    Assert-Equal -Description 'creates no new commit' -Expected $before.CommitCount -Actual $after.CommitCount
    Assert-Equal -Description 'HEAD is unchanged' -Expected $before.Head -Actual $after.Head
    Assert-Equal -Description 'version file is byte-identical' -Expected $before.VersionHex -Actual $after.VersionHex
    Assert-Equal -Description 'working tree is clean' -Expected '' -Actual $after.Status
    Assert-That -Description 'aborted before the changelog check ran' -Condition ($result.Output -notmatch 'release-note line')

    $remoteTags = Invoke-Git -RepoPath $repo.Work -ArgumentList @('ls-remote', '--tags', 'origin')
    Assert-Equal -Description 'nothing was pushed to origin' -Expected '' -Actual $remoteTags
}

# ---------------------------------------------------------------------------
# Test 3 - automatic patch bump
# ---------------------------------------------------------------------------

function Test-AutomaticPatchBump {
    Start-TestCase 'Automatic patch bump (no -Version)'

    $repo = New-TestRepo -Name 'auto-patch-bump' -CurrentVersion '1.0.0'
    $before = Get-RepoState -Repo $repo
    $beforeText = [System.IO.File]::ReadAllText($repo.VersionFile)

    $result = Invoke-Release -RepoPath $repo.Work
    $after = Get-RepoState -Repo $repo
    $afterText = [System.IO.File]::ReadAllText($repo.VersionFile)

    Assert-Equal -Description 'exits 0' -Expected 0 -Actual $result.ExitCode
    Assert-Equal -Description 'creates exactly one new commit' -Expected ($before.CommitCount + 1) -Actual $after.CommitCount
    Assert-Equal -Description 'declares version 1.0.1' -Expected '1.0.1' -Actual (Get-DeclaredVersion -Path $repo.VersionFile)
    Assert-Equal -Description 'only the version literal changed' -Expected ($beforeText -replace "'1\.0\.0'", "'1.0.1'") -Actual $afterText
    Assert-That -Description 'trailing newline is preserved' -Condition ($afterText.EndsWith("`n"))
    Assert-That -Description 'no BOM was introduced' -Condition (-not (Test-HasBom -Path $repo.VersionFile))
    Assert-Equal -Description 'tag v1.0.1 exists' -Expected 'v1.0.1' -Actual $after.Tags
    Assert-Equal -Description 'working tree is clean' -Expected '' -Actual $after.Status

    $subject = Invoke-Git -RepoPath $repo.Work -ArgumentList @('log', '-1', '--format=%s')
    Assert-Equal -Description 'commit subject names the new version' -Expected 'build: bump installer version to 1.0.1' -Actual $subject

    $changed = Invoke-Git -RepoPath $repo.Work -ArgumentList @('show', '--name-only', '--format=', 'HEAD')
    Assert-Equal -Description 'commit touches only the version file' -Expected 'lib/Delta.Version.ps1' -Actual $changed

    $diffStat = Invoke-Git -RepoPath $repo.Work -ArgumentList @('show', '--shortstat', '--format=', 'HEAD')
    Assert-That -Description 'commit is a one-line change, not a newline strip' -Condition ($diffStat -match '1 insertion\(\+\), 1 deletion\(-\)')
    Assert-That -Description 'commit does not remove the end-of-file newline' -Condition ((Invoke-Git -RepoPath $repo.Work -ArgumentList @('show', 'HEAD')) -notmatch 'No newline at end of file')
}

# ---------------------------------------------------------------------------
# Test 4 - explicit higher version
# ---------------------------------------------------------------------------

function Test-ExplicitHigherVersion {
    Start-TestCase 'Explicit higher version (-Version 2.1.0)'

    $repo = New-TestRepo -Name 'explicit-higher' -CurrentVersion '1.0.0'
    $before = Get-RepoState -Repo $repo
    $beforeText = [System.IO.File]::ReadAllText($repo.VersionFile)

    $result = Invoke-Release -RepoPath $repo.Work -ReleaseArgs @('-Version', '2.1.0')
    $after = Get-RepoState -Repo $repo
    $afterText = [System.IO.File]::ReadAllText($repo.VersionFile)

    Assert-Equal -Description 'exits 0' -Expected 0 -Actual $result.ExitCode
    Assert-Equal -Description 'creates exactly one new commit' -Expected ($before.CommitCount + 1) -Actual $after.CommitCount
    Assert-Equal -Description 'declares version 2.1.0' -Expected '2.1.0' -Actual (Get-DeclaredVersion -Path $repo.VersionFile)
    Assert-Equal -Description 'only the version literal changed' -Expected ($beforeText -replace "'1\.0\.0'", "'2.1.0'") -Actual $afterText
    Assert-That -Description 'trailing newline is preserved' -Condition ($afterText.EndsWith("`n"))
    Assert-Equal -Description 'tag v2.1.0 exists' -Expected 'v2.1.0' -Actual $after.Tags
    Assert-That -Description 'ran the bump path' -Condition ($result.Output -match 'Committing version bump')

    $remoteTags = Invoke-Git -RepoPath $repo.Work -ArgumentList @('ls-remote', '--tags', 'origin')
    Assert-That -Description 'tag was pushed to origin' -Condition ($remoteTags -match 'refs/tags/v2\.1\.0')

    $remoteHead = Invoke-Git -RepoPath $repo.Work -ArgumentList @('rev-parse', 'origin/main')
    Assert-Equal -Description 'bump commit was pushed to origin/main' -Expected $after.Head -Actual $remoteHead
}

# ---------------------------------------------------------------------------
# Test 5 - DryRun for the equal-version bootstrap case
# ---------------------------------------------------------------------------

function Test-DryRunEqualVersion {
    Start-TestCase 'DryRun with explicit version equal to current'

    $repo = New-TestRepo -Name 'dryrun-equal' -CurrentVersion '1.0.0'
    $before = Get-RepoState -Repo $repo

    $result = Invoke-Release -RepoPath $repo.Work -ReleaseArgs @('-Version', '1.0.0', '-DryRun')
    $after = Get-RepoState -Repo $repo

    $lines = @($result.Output -split "`r?`n" | ForEach-Object { $_.Trim() })

    Assert-Equal -Description 'exits 0' -Expected 0 -Actual $result.ExitCode
    Assert-That -Description 'reports that no version bump is required' -Condition ($result.Output -match 'Version Bump:\s+not required')
    Assert-That -Description 'does not list git add' -Condition ($lines -notcontains 'git add lib/Delta.Version.ps1')
    Assert-That -Description 'does not list the bump commit' -Condition (-not ($lines | Where-Object { $_ -like 'git commit*' }))
    Assert-That -Description 'does not list the bare commit push' -Condition ($lines -notcontains 'git push')
    Assert-That -Description 'lists the annotated tag command' -Condition ($lines -contains 'git tag -a v1.0.0 -m "DELTA Windows Docker Installer v1.0.0"')
    Assert-That -Description 'lists the tag push' -Condition ($lines -contains 'git push origin v1.0.0')

    Assert-Equal -Description 'HEAD is unchanged' -Expected $before.Head -Actual $after.Head
    Assert-Equal -Description 'creates no commit' -Expected $before.CommitCount -Actual $after.CommitCount
    Assert-Equal -Description 'creates no tag' -Expected '' -Actual $after.Tags
    Assert-Equal -Description 'version file is byte-identical' -Expected $before.VersionHex -Actual $after.VersionHex
    Assert-Equal -Description 'working tree is clean' -Expected '' -Actual $after.Status

    $remoteTags = Invoke-Git -RepoPath $repo.Work -ArgumentList @('ls-remote', '--tags', 'origin')
    Assert-Equal -Description 'nothing was pushed to origin' -Expected '' -Actual $remoteTags
}

# ---------------------------------------------------------------------------
# Test 5b - DryRun for a normal bump keeps the full five-command sequence
# ---------------------------------------------------------------------------

function Test-DryRunNormalBump {
    Start-TestCase 'DryRun for a normal bump lists all five Git commands'

    $repo = New-TestRepo -Name 'dryrun-bump' -CurrentVersion '1.0.0'
    $before = Get-RepoState -Repo $repo

    $result = Invoke-Release -RepoPath $repo.Work -ReleaseArgs @('-DryRun')
    $after = Get-RepoState -Repo $repo

    $lines = @($result.Output -split "`r?`n" | ForEach-Object { $_.Trim() })

    Assert-Equal -Description 'exits 0' -Expected 0 -Actual $result.ExitCode
    Assert-That -Description 'lists git add' -Condition ($lines -contains 'git add lib/Delta.Version.ps1')
    Assert-That -Description 'lists the bump commit' -Condition ($lines -contains 'git commit -m "build: bump installer version to 1.0.1"')
    Assert-That -Description 'lists the commit push' -Condition ($lines -contains 'git push')
    Assert-That -Description 'lists the annotated tag command' -Condition ($lines -contains 'git tag -a v1.0.1 -m "DELTA Windows Docker Installer v1.0.1"')
    Assert-That -Description 'lists the tag push' -Condition ($lines -contains 'git push origin v1.0.1')
    Assert-That -Description 'reports the bump direction' -Condition ($result.Output -match 'Version Bump:\s+1\.0\.0 -> 1\.0\.1')
    Assert-Equal -Description 'HEAD is unchanged' -Expected $before.Head -Actual $after.Head
    Assert-Equal -Description 'version file is byte-identical' -Expected $before.VersionHex -Actual $after.VersionHex
}

# ---------------------------------------------------------------------------
# Test 6 - version-file round-trip
#
# Lifts Update-VersionFile out of release.ps1 via the PowerShell parser and
# runs it directly, so these assertions exercise the shipping regex rather
# than a restatement of it. Stubs stand in for the console helpers and the
# one script-scoped path the function reads.
# ---------------------------------------------------------------------------

function Test-VersionFileRoundTrip {
    Start-TestCase 'Version-file round-trip (Update-VersionFile)'

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script:ReleaseePath, [ref]$null, [ref]$null)
    $fn = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-VersionFile' },
        $true) | Select-Object -First 1

    if (-not $fn) {
        Assert-That -Description 'Update-VersionFile was found in release.ps1' -Condition $false
        return
    }

    function Write-Step { param([string]$Message) }
    function Write-Detail { param([string]$Message) }
    function Stop-Release { param([string]$Message) throw $Message }

    . ([scriptblock]::Create($fn.Extent.Text))

    $caseRoot = Join-Path -Path $Script:WorkRoot -ChildPath 'round-trip'
    New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

    $cases = @(
        @{ Name = 'LF, trailing newline';           Ending = 'LF';   NoTrailing = $false }
        @{ Name = 'CRLF, trailing newline';         Ending = 'CRLF'; NoTrailing = $false }
        @{ Name = 'LF, no trailing newline';        Ending = 'LF';   NoTrailing = $true }
        @{ Name = 'CRLF, no trailing newline';      Ending = 'CRLF'; NoTrailing = $true }
    )

    foreach ($case in $cases) {
        $path = Join-Path -Path $caseRoot -ChildPath ("Delta.Version.$($case.Ending)$(if ($case.NoTrailing) { '.nonl' }).ps1")
        $original = New-VersionFileContent -NewVersion '1.0.0' -LineEnding $case.Ending -NoTrailingNewline:$case.NoTrailing
        Write-Utf8NoBom -Path $path -Content $original
        $originalHex = Get-FileBytesHex -Path $path

        $Script:VersionFilePath = $path

        # Same version in, same bytes out - the property the release path's
        # "is a bump required" decision depends on.
        Update-VersionFile -NewVersion '1.0.0'
        Assert-Equal -Description "$($case.Name): same-version rewrite is byte-identical" -Expected $originalHex -Actual (Get-FileBytesHex -Path $path)

        # A real bump changes the literal and nothing else.
        Update-VersionFile -NewVersion '9.8.7'
        $bumped = [System.IO.File]::ReadAllText($path)
        Assert-Equal -Description "$($case.Name): bump changes only the version literal" -Expected ($original -replace "'1\.0\.0'", "'9.8.7'") -Actual $bumped

        $expectedEnding = if ($case.Ending -eq 'CRLF') { "`r`n" } else { "`n" }
        $endingCount = ([regex]::Matches($bumped, [regex]::Escape($expectedEnding))).Count
        $originalEndingCount = ([regex]::Matches($original, [regex]::Escape($expectedEnding))).Count
        Assert-Equal -Description "$($case.Name): line endings preserved" -Expected $originalEndingCount -Actual $endingCount

        if ($case.NoTrailing) {
            Assert-That -Description "$($case.Name): still has no trailing newline" -Condition (-not $bumped.EndsWith("`n"))
        }
        else {
            Assert-That -Description "$($case.Name): trailing newline preserved" -Condition ($bumped.EndsWith($expectedEnding))
        }

        if ($case.Ending -eq 'CRLF') {
            Assert-That -Description "$($case.Name): no bare LF introduced" -Condition (-not ([regex]::IsMatch($bumped, "(?<!`r)`n")))
        }

        Assert-That -Description "$($case.Name): no BOM introduced" -Condition (-not (Test-HasBom -Path $path))
    }
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

$overallExit = 1
try {
    Write-Step 'DELTA release.ps1 regression tests'
    Write-Detail "Script under test: $($Script:ReleaseePath)"
    Write-Detail "Temporary repositories: $($Script:WorkRoot)"
    New-Item -ItemType Directory -Path $Script:WorkRoot -Force | Out-Null

    Test-BootstrapEqualVersionNoTag
    Test-BootstrapEqualVersionExistingTag
    Test-AutomaticPatchBump
    Test-ExplicitHigherVersion
    Test-DryRunEqualVersion
    Test-DryRunNormalBump
    Test-VersionFileRoundTrip

    Write-Host ''
    Write-Step 'Summary'
    Write-Detail "Passed: $($Script:Passed)"
    Write-Detail "Failed: $($Script:Failed)"

    if ($Script:Failed -eq 0) {
        Write-Host ''
        Write-Host 'All release.ps1 regression tests passed.' -ForegroundColor Green
        $overallExit = 0
    }
    else {
        Write-Host ''
        Write-Host "$($Script:Failed) release.ps1 regression test assertion(s) failed." -ForegroundColor Red
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
