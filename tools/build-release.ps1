#Requires -Version 5.1
<#
.SYNOPSIS
    Builds an official DELTA Windows Docker Installer release package.

.DESCRIPTION
    Single source of truth for producing release packages - run both by
    developers locally and by GitHub Actions, which invokes this script
    rather than reimplementing any packaging logic of its own.
    .github\workflows\release.yml's "Build release package" step is a
    single call to it, passing the version derived from the pushed tag;
    the whitelist below is therefore the only place that decides what
    ships, and it is never restated in YAML. See README, "Cutting a
    release".

    Packaging only: copies a fixed whitelist of production files into
    release\DELTA-windows-installer-docker-<Version>\, zips that
    directory, and writes a SHA256 checksum for the zip. Nothing that the
    installer obtains at install time is bundled here - Docker Desktop is
    downloaded (or staged by the site into installers\), and the NGINX,
    DELTA and PostgreSQL/PostGIS images are pulled by the Docker engine.
    This script never downloads anything, never modifies setup.ps1, and
    never publishes a GitHub Release; those are separate concerns owned
    elsewhere - publication belongs to release.yml, which attaches the
    two artifacts named below to the release for the tag it was fired by.

    The whitelist (not an exclude-list) is deliberate: a file added to
    the repository root in the future is excluded from releases by
    default until someone explicitly adds it to $Script:RequiredFiles or
    $Script:OptionalFiles below, rather than leaking into a release
    package unnoticed.

.PARAMETER Version
    Release version, used to name the release directory, the ZIP, and
    the checksum file (e.g. "1.0.0"). Required.

.EXAMPLE
    .\tools\build-release.ps1 -Version 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Console output helpers
#
# Mirrors the Write-Step/Write-Detail/Write-Success/Stop-Setup vocabulary
# used by setup.ps1 / lib\Delta.Common.ps1, kept local to this script
# rather than dot-sourced from there - build-release.ps1 packages lib\, it
# does not depend on it. ASCII-only by convention, since this project
# deliberately avoids console symbols that mojibake once output is piped
# or redirected (e.g. GitHub Actions logs).
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

# $PSScriptRoot is tools\; the repository root is one level up. Every path
# below is resolved from here, never from the caller's current working
# directory - so this script behaves identically run from any location.
$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot

# $Version is used directly in path/file names below - reject anything
# that isn't valid in a Windows file name before it can produce a
# confusing New-Item/Compress-Archive failure further down.
$invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
if ($Version.IndexOfAny($invalidChars) -ge 0) {
    Stop-Release "Version '$Version' contains characters that are not valid in a file name."
}

$Script:PackageName  = "DELTA-windows-installer-docker-$Version"
$Script:ReleaseDir   = Join-Path -Path $Script:ProjectRoot -ChildPath 'release'
$Script:PackageDir   = Join-Path -Path $Script:ReleaseDir -ChildPath $Script:PackageName
$Script:ZipPath      = Join-Path -Path $Script:ReleaseDir -ChildPath "$Script:PackageName.zip"
$Script:ChecksumPath = "$Script:ZipPath.sha256"

# Whitelist of what goes into a release package. Required entries stop the
# build immediately if missing; optional entries are copied only if present
# (README.md / LICENSE / CHANGELOG.md "if present"). Anything not listed
# here - .claude\, doc\, .git\, .gitignore, logs\, installers\, tools\,
# release.ps1, release\ itself - is never copied, by construction.
#
# start-delta.ps1 and rotate-nginx-logs.ps1 are required, not optional:
# both are resolved at runtime as Join-Path <installer directory> <name>
# (Delta.Docker.ps1's $Script:DeltaStartupScriptName and
# Delta.Manage.ps1's $Script:DeltaNginxRotationScript) and registered as
# scheduled tasks pointing at that path. A package without them installs
# and then fails at boot, or silently at 03:30 - which is exactly the kind
# of omission a whitelist is supposed to make impossible.
$Script:RequiredFiles = @(
    'setup.ps1',
    'uninstall.ps1',
    'start-delta.ps1',
    'rotate-nginx-logs.ps1'
)

$Script:OptionalFiles = @(
    'README.md',
    'LICENSE',
    'CHANGELOG.md'
)

# lib\ carries Delta.Version.ps1 along with the libraries, so the
# installer's own version ships inside the package automatically with no
# packaging change required to keep it there. templates\ is copied whole,
# including templates\nginx\ - Delta.Stack.ps1 resolves every template as
# Join-Path <installer directory> "templates\<relative path>".
$Script:RequiredDirectories = @(
    'lib',
    'templates'
)

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

function Initialize-ReleaseDirectory {
    <#
      Removes any previous release\ output and recreates an empty
      release\<PackageName>\ tree for this run, so the build is
      deterministic - a repeat run for the same version never mixes
      leftover content from a prior run into the new package.
    #>
    Write-Step 'Creating release directory...'

    if (Test-Path -LiteralPath $Script:ReleaseDir) {
        Write-Detail "Removing existing $($Script:ReleaseDir)"
        Remove-Item -LiteralPath $Script:ReleaseDir -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Script:PackageDir -Force | Out-Null
    Write-Detail "Created $($Script:PackageDir)"
}

function Copy-ReleaseFiles {
    <#
      Whitelist copy: every file/directory copied into the package is
      named explicitly in the Configuration section above, rather than
      copying the repository wholesale and excluding development files
      afterward. A required file/directory that is missing stops the
      build immediately; an optional file that is absent is skipped.
    #>
    Write-Step 'Copying files...'

    foreach ($file in $Script:RequiredFiles) {
        $source = Join-Path -Path $Script:ProjectRoot -ChildPath $file
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            Stop-Release "Required file not found: $file"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path -Path $Script:PackageDir -ChildPath $file)
        Write-Detail "Copied $file"
    }

    foreach ($file in $Script:OptionalFiles) {
        $source = Join-Path -Path $Script:ProjectRoot -ChildPath $file
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path -Path $Script:PackageDir -ChildPath $file)
            Write-Detail "Copied $file"
        }
        else {
            Write-Detail "Skipped $file (not present)"
        }
    }

    foreach ($dir in $Script:RequiredDirectories) {
        $source = Join-Path -Path $Script:ProjectRoot -ChildPath $dir
        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            Stop-Release "Required directory not found: $dir"
        }
        $destination = Join-Path -Path $Script:PackageDir -ChildPath $dir
        Copy-Item -LiteralPath $source -Destination $destination -Recurse
        Write-Detail "Copied $dir\ (directory structure preserved)"
    }
}

function New-ReleaseZip {
    <#
      Zips release\<PackageName>\ into release\<PackageName>.zip. Passing
      the package directory itself (not its contents) to Compress-Archive
      makes <PackageName>\ the ZIP's own top-level entry, so extracting
      it reproduces the same folder name.
    #>
    Write-Step 'Creating ZIP...'

    if (Test-Path -LiteralPath $Script:ZipPath) {
        Remove-Item -LiteralPath $Script:ZipPath -Force
    }

    Compress-Archive -Path $Script:PackageDir -DestinationPath $Script:ZipPath -CompressionLevel Optimal

    if (-not (Test-Path -LiteralPath $Script:ZipPath -PathType Leaf)) {
        Stop-Release "ZIP creation failed: $($Script:ZipPath) was not created."
    }
    Write-Detail "Created $($Script:ZipPath)"
}

function New-ReleaseChecksum {
    <#
      Writes <zip>.sha256 as a single "<hash>  <filename>" line (two
      spaces, text mode) - the layout `sha256sum -c` expects when run
      from inside release\ against the ZIP sitting next to it.
    #>
    Write-Step 'Generating SHA256...'

    $hash = Get-FileHash -LiteralPath $Script:ZipPath -Algorithm SHA256
    if (-not $hash -or -not $hash.Hash) {
        Stop-Release 'SHA256 checksum generation failed.'
    }

    $zipFileName  = Split-Path -Leaf $Script:ZipPath
    $checksumLine = "$($hash.Hash.ToLowerInvariant())  $zipFileName"
    Set-Content -LiteralPath $Script:ChecksumPath -Value $checksumLine -Encoding ascii

    if (-not (Test-Path -LiteralPath $Script:ChecksumPath -PathType Leaf)) {
        Stop-Release "Checksum file was not created: $($Script:ChecksumPath)"
    }
    Write-Detail "Created $($Script:ChecksumPath)"
}

# ---------------------------------------------------------------------------
# Orchestration
#
# Each step is a single top-level function call, in dependency order.
# Future release assets - Authenticode signing, release notes generation,
# SBOM generation, additional release assets - are new steps inserted
# here (signing would slot in after Copy-ReleaseFiles and before
# New-ReleaseZip; release notes/SBOM alongside New-ReleaseChecksum) -
# nothing above this point needs to change to support them.
# ---------------------------------------------------------------------------

try {
    Initialize-ReleaseDirectory
    Copy-ReleaseFiles
    New-ReleaseZip
    New-ReleaseChecksum

    Write-Host ''
    Write-Success 'Release completed successfully.'
    Write-Detail "Package:  $($Script:PackageDir)"
    Write-Detail "ZIP:      $($Script:ZipPath)"
    Write-Detail "Checksum: $($Script:ChecksumPath)"

    exit 0
}
catch {
    Write-Host ''
    Write-Host 'Release build failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
