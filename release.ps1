#Requires -Version 5.1
<#
.SYNOPSIS
    Automates the DELTA Windows Docker Installer release process.

.DESCRIPTION
    Single source of truth for cutting a release: it turns a developer's
    "cut a release" intent into a version number, bumping
    lib\Delta.Version.ps1, committing it, and pushing an annotated vX.Y.Z
    tag. This script never builds or uploads anything; it only prepares
    and pushes the commit and tag.

    Note what does NOT yet exist in this repository, so the handoff is not
    mistaken for something it is: there is no .github\workflows\release.yml
    here. Packaging does exist - tools\build-release.ps1 turns a version
    number into a ZIP and a checksum - but nothing runs it automatically.
    In the native installer repository the tag push is what triggers
    packaging and publication; here the tag push currently triggers
    nothing, because nothing is listening for it yet, and a package is
    produced only by running tools\build-release.ps1 by hand. That is a
    deliberate boundary - this script is the release *trigger*, and the
    workflow that would join it to the packager is separate work.
    Everything below is written so that adding that workflow later
    requires no change here: the tag shape, the version-file contract and
    the CHANGELOG.md heading contract are all exactly the ones such a
    workflow would consume.

    With no -Version, the patch component of the current version (read
    from lib\Delta.Version.ps1) is incremented by one - major and minor
    are left untouched (1.0.4 -> 1.0.5, 1.0.9 -> 1.0.10, 2.14.99 ->
    2.14.100). Passing -Version completely overrides that auto-increment
    with the exact version supplied.

    Guardrails run before anything is changed: the current directory must
    be a Git repository, the current branch must be 'main', the working
    tree must have no uncommitted changes, the version file must parse,
    the target tag must not already exist, and CHANGELOG.md must contain
    a non-empty '## [X.Y.Z]' section for the target version (the curated
    release notes a release workflow would publish as the GitHub Release
    body). Any failure aborts before lib\Delta.Version.ps1 or Git state
    is touched. Because the release sequence itself is a handful of
    separate git invocations (add, commit, push, tag, push), a failure
    partway through (e.g. the tag push rejected after the commit push
    already succeeded) can leave the bump commit pushed without its
    tag - Stop-Release's error message always names which step failed
    so that state is easy to diagnose and finish by hand.

.PARAMETER Version
    Exact release version to use (e.g. "2.1.0"), overriding the default
    auto patch increment entirely. Optional.

.PARAMETER DryRun
    Prints the current version, the version that would be released, and
    every Git command that would run - without modifying the version
    file or touching Git state in any way.

.EXAMPLE
    .\release.ps1
    Bumps the patch version (e.g. 1.0.4 -> 1.0.5) and releases it.

.EXAMPLE
    .\release.ps1 -Version 2.1.0
    Releases exactly 2.1.0, ignoring the current version's patch number.

.EXAMPLE
    .\release.ps1 -DryRun
    Shows what a default patch-bump release would do, without doing it.
#>

[CmdletBinding()]
param(
    [string]$Version,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Console output helpers
#
# Same Write-Step/Write-Detail/Write-Success vocabulary as lib\Delta.Common.ps1,
# kept local to this script rather than dot-sourced from lib\ - this script
# operates on lib\, it does not depend on it, and it must stay runnable
# against a checkout whose libraries are mid-edit. ASCII-only by convention,
# since this project deliberately avoids console symbols that mojibake once
# output is piped or redirected (e.g. CI logs).
# ---------------------------------------------------------------------------

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Detail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message"
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Stop-Release {
    <#
      Raises a terminating error with a clear, human-readable message.
      The single top-level try/catch in the Orchestration section below
      turns this into a console error banner and a non-zero exit code -
      helper functions never call exit directly.
    #>
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# $PSScriptRoot is the repository root - release.ps1 lives there, alongside
# setup.ps1. Every path below is resolved from here, never from the caller's
# current working directory, so this script behaves identically run from any
# location.
$Script:ProjectRoot     = $PSScriptRoot
$Script:VersionFilePath = Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\Delta.Version.ps1'
$Script:ChangelogPath   = Join-Path -Path $Script:ProjectRoot -ChildPath 'CHANGELOG.md'
$Script:RequiredBranch  = 'main'

# Major.Minor.Patch only - matches lib\Delta.Version.ps1's own contract and
# the 'v*' tag shape a release workflow would compare against.
$Script:SemVerPattern = '^\d+\.\d+\.\d+$'

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

function Invoke-GitCommand {
    <#
      Runs a single git invocation with the same stderr-safe capture
      pattern this project uses for native commands elsewhere: 2>&1 merges
      git's stderr into the output stream, and $ErrorActionPreference is
      temporarily relaxed to 'Continue' around the call so that merge
      doesn't itself become a terminating error under this script's
      script-wide 'Stop' setting. Returns the combined output. Non-zero
      exit codes stop the release immediately via Stop-Release, with git's
      own output folded into the message, unless -AllowFailure is passed -
      used by validation checks (e.g. "does this tag already exist") where
      a non-zero exit is an expected, non-fatal answer the caller inspects
      itself via $LASTEXITCODE.
    #>
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [switch]$AllowFailure
    )

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git @ArgumentList 2>&1
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        Stop-Release "git $($ArgumentList -join ' ') failed: $(($output | Out-String).Trim())"
    }

    return $output
}

function Assert-GitRepository {
    Write-Step 'Verifying Git repository...'

    $result = Invoke-GitCommand -ArgumentList @('rev-parse', '--is-inside-work-tree') -AllowFailure
    if ($LASTEXITCODE -ne 0 -or ($result | Select-Object -Last 1) -ne 'true') {
        Stop-Release 'Current directory is not inside a Git repository.'
    }

    Write-Detail 'Confirmed current directory is inside a Git repository.'
}

function Assert-GitBranch {
    param([Parameter(Mandatory)][string]$RequiredBranch)

    Write-Step 'Verifying current branch...'

    $branch = (Invoke-GitCommand -ArgumentList @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -Last 1).Trim()
    if ($branch -ne $RequiredBranch) {
        Stop-Release "Releases can only be built from '$RequiredBranch' (current branch: '$branch')."
    }

    Write-Detail "Current branch: $branch"
}

function Assert-GitClean {
    Write-Step 'Verifying working tree is clean...'

    $status = Invoke-GitCommand -ArgumentList @('status', '--porcelain')
    if ($status) {
        Stop-Release 'Working tree has uncommitted changes. Commit or stash them before releasing.'
    }

    Write-Detail 'Working tree is clean.'
}

function Assert-TagAvailable {
    param([Parameter(Mandatory)][string]$Tag)

    Write-Step "Verifying tag '$Tag' does not already exist..."

    $existing = Invoke-GitCommand -ArgumentList @('tag', '--list', $Tag)
    if ($existing) {
        Stop-Release "Tag '$Tag' already exists. Choose a different version or delete the existing tag first."
    }

    Write-Detail "Tag '$Tag' is available."
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------

function Get-CurrentVersion {
    <#
      Reads the installer's current version by dot-sourcing
      lib\Delta.Version.ps1 - reusing PowerShell's own parser to evaluate
      the assignment rather than regex-matching the file's text, so it
      can't be fooled by incidental formatting differences (quote style,
      spacing, a trailing comment). That file is deliberately standalone
      precisely so it can be dot-sourced on its own like this, with no
      other library loaded.
    #>
    Write-Step 'Reading current version...'

    if (-not (Test-Path -LiteralPath $Script:VersionFilePath -PathType Leaf)) {
        Stop-Release "Version file not found: $($Script:VersionFilePath)"
    }

    try {
        . $Script:VersionFilePath
    }
    catch {
        Stop-Release "Failed to read version file $($Script:VersionFilePath): $($_.Exception.Message)"
    }

    if (-not (Test-Path variable:Script:DeltaInstallerVersion) -or [string]::IsNullOrWhiteSpace($Script:DeltaInstallerVersion)) {
        Stop-Release "$($Script:VersionFilePath) did not define `$Script:DeltaInstallerVersion."
    }

    if ($Script:DeltaInstallerVersion -notmatch $Script:SemVerPattern) {
        Stop-Release "Current version '$($Script:DeltaInstallerVersion)' is not a valid semantic version (expected X.Y.Z)."
    }

    Write-Detail "Current version: $($Script:DeltaInstallerVersion)"
    return $Script:DeltaInstallerVersion
}

function Get-NextVersion {
    <#
      Computes the version to release. An explicit -Version completely
      overrides auto-increment (per requirement, not merely takes
      precedence for a missing component). Otherwise, only the patch
      component of $CurrentVersion is incremented - major and minor are
      left untouched (1.0.4 -> 1.0.5, 1.0.9 -> 1.0.10, 2.14.99 ->
      2.14.100).
    #>
    param(
        [Parameter(Mandatory)][string]$CurrentVersion,
        [string]$ExplicitVersion
    )

    if ($ExplicitVersion) {
        if ($ExplicitVersion -notmatch $Script:SemVerPattern) {
            Stop-Release "Version '$ExplicitVersion' is not a valid semantic version (expected X.Y.Z)."
        }
        Write-Detail "Explicit version requested: $ExplicitVersion"
        return $ExplicitVersion
    }

    $parts = $CurrentVersion -split '\.'
    $nextPatch   = [int]$parts[2] + 1
    $nextVersion = '{0}.{1}.{2}' -f $parts[0], $parts[1], $nextPatch

    Write-Detail "Auto patch increment: $CurrentVersion -> $nextVersion"
    return $nextVersion
}

function Update-VersionFile {
    <#
      Rewrites the $Script:DeltaInstallerVersion literal in
      lib\Delta.Version.ps1 in place. This is a text replacement, not the
      "regex the file" that reading the version deliberately avoids -
      that concern is about *reading* the current value (done via
      dot-sourcing in Get-CurrentVersion above); there is no structured
      way to rewrite a single assignment inside a .ps1 file other than
      matching it by text, so the pattern is anchored to the variable
      name itself (not the old value) to stay resilient to exactly which
      version was there before. Written back with a BOM-less UTF8
      encoding, matching every other .ps1 file in this repository.
    #>
    param([Parameter(Mandatory)][string]$NewVersion)

    Write-Step 'Updating version file...'

    $content = Get-Content -LiteralPath $Script:VersionFilePath -Raw
    $assignmentPattern = "(?m)^\`$Script:DeltaInstallerVersion\s*=\s*'[^']*'\s*$"

    if ($content -notmatch $assignmentPattern) {
        Stop-Release "Could not locate the `$Script:DeltaInstallerVersion assignment in $($Script:VersionFilePath)."
    }

    $newContent = [regex]::Replace($content, $assignmentPattern, "`$Script:DeltaInstallerVersion = '$NewVersion'")

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Script:VersionFilePath, $newContent, $utf8NoBom)

    Write-Detail "Set `$Script:DeltaInstallerVersion = '$NewVersion' in $($Script:VersionFilePath)"
}

# ---------------------------------------------------------------------------
# Changelog validation
# ---------------------------------------------------------------------------

function Assert-ChangelogEntry {
    <#
      Verifies CHANGELOG.md contains a release section for the version
      about to be released: a "## [X.Y.Z]" heading, whose section runs
      until the next "## [" release heading (or end of file) and holds
      at least one meaningful content line - blank lines and bare "###"
      category headings alone don't count. Runs with the other
      guardrails, before -DryRun exits and before Update-VersionFile,
      so a missing or empty entry aborts with the version file and Git
      state completely untouched.

      The "## [X.Y.Z]" heading is the contract a release workflow slices
      a GitHub Release body out of once the tag is pushed. No such
      workflow exists in this repository yet, so today this guardrail
      protects the changelog rather than a publication step - but it is
      enforced now, in the shape that workflow will expect, so that no
      tag ever reaches it without notes.

      CHANGELOG.md is the curated source of truth: nothing in this
      script generates, rewrites, or reorders entries - the operator
      writes the section by hand, this only refuses to release without
      it.
    #>
    param([Parameter(Mandatory)][string]$TargetVersion)

    Write-Step "Verifying CHANGELOG.md has release notes for $TargetVersion..."

    if (-not (Test-Path -LiteralPath $Script:ChangelogPath -PathType Leaf)) {
        Stop-Release "CHANGELOG.md not found at $($Script:ChangelogPath). Add a '## [$TargetVersion]' section describing this release, then re-run."
    }

    $changelogLines = @(Get-Content -LiteralPath $Script:ChangelogPath)
    $headingPattern = "^##\s+\[$([regex]::Escape($TargetVersion))\]"

    $startIndex = -1
    for ($i = 0; $i -lt $changelogLines.Count; $i++) {
        if ($changelogLines[$i] -match $headingPattern) {
            $startIndex = $i
            break
        }
    }
    if ($startIndex -lt 0) {
        Stop-Release "CHANGELOG.md has no '## [$TargetVersion]' section. Add the release notes for $TargetVersion to CHANGELOG.md and commit them, then re-run."
    }

    $endIndex = $changelogLines.Count
    for ($i = $startIndex + 1; $i -lt $changelogLines.Count; $i++) {
        if ($changelogLines[$i] -match '^##\s+\[') {
            $endIndex = $i
            break
        }
    }

    $sectionLines = @()
    if ($startIndex + 1 -lt $endIndex) {
        $sectionLines = @($changelogLines[($startIndex + 1)..($endIndex - 1)])
    }
    $contentLines = @($sectionLines | Where-Object { $_.Trim() -and $_ -notmatch '^###\s' })
    if ($contentLines.Count -eq 0) {
        Stop-Release "CHANGELOG.md's '## [$TargetVersion]' section contains no release-note content. Describe the release under that heading, then re-run."
    }

    Write-Detail "Found '## [$TargetVersion]' with $($contentLines.Count) release-note line(s)."
}

# ---------------------------------------------------------------------------
# Orchestration
#
# Each step is a single top-level function call, in dependency order:
# validate repository/branch/cleanliness, resolve the version to
# release, validate its tag is free and its CHANGELOG.md section exists,
# then (unless -DryRun) mutate the version file and run the fixed
# add/commit/push/tag/push sequence that publishes the tag.
# ---------------------------------------------------------------------------

try {
    Assert-GitRepository
    Assert-GitBranch -RequiredBranch $Script:RequiredBranch
    Assert-GitClean

    $currentVersion = Get-CurrentVersion
    $nextVersion    = Get-NextVersion -CurrentVersion $currentVersion -ExplicitVersion $Version
    $tagName        = "v$nextVersion"

    Assert-TagAvailable -Tag $tagName
    Assert-ChangelogEntry -TargetVersion $nextVersion

    if ($DryRun) {
        Write-Host ''
        Write-Step 'Dry run - no changes will be made.'
        Write-Detail "Current Version: $currentVersion"
        Write-Detail "Next Version:    $nextVersion"
        Write-Detail "Release Notes:   CHANGELOG.md '## [$nextVersion]' section found"
        Write-Host ''
        Write-Step 'The following Git commands would be executed:'
        Write-Detail 'git add lib/Delta.Version.ps1'
        Write-Detail "git commit -m ""build: bump installer version to $nextVersion"""
        Write-Detail 'git push'
        Write-Detail "git tag -a $tagName -m ""DELTA Windows Docker Installer $tagName"""
        Write-Detail "git push origin $tagName"
        Write-Host ''
        Write-Success 'Dry run completed. No changes were made.'
        exit 0
    }

    Update-VersionFile -NewVersion $nextVersion

    Write-Step 'Committing version bump...'
    Invoke-GitCommand -ArgumentList @('add', 'lib/Delta.Version.ps1') | Out-Null
    Invoke-GitCommand -ArgumentList @('commit', '-m', "build: bump installer version to $nextVersion") | Out-Null
    Write-Detail 'Committed lib/Delta.Version.ps1'

    Write-Step 'Pushing commit...'
    Invoke-GitCommand -ArgumentList @('push') | Out-Null
    Write-Detail 'Pushed to origin.'

    Write-Step 'Creating tag...'
    Invoke-GitCommand -ArgumentList @('tag', '-a', $tagName, '-m', "DELTA Windows Docker Installer $tagName") | Out-Null
    Write-Detail "Created tag $tagName"

    Write-Step 'Pushing tag...'
    Invoke-GitCommand -ArgumentList @('push', 'origin', $tagName) | Out-Null
    Write-Detail "Pushed tag $tagName"

    Write-Host ''
    Write-Success 'Release completed successfully.'
    Write-Detail "Version: $nextVersion"
    Write-Detail "Tag:     $tagName"
    Write-Detail 'The tag has been pushed. No release workflow exists in this'
    Write-Detail 'repository yet, so nothing will build or publish it automatically.'
    Write-Detail "To produce the package: .\tools\build-release.ps1 -Version $nextVersion"

    exit 0
}
catch {
    Write-Host ''
    Write-Host 'Release failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
