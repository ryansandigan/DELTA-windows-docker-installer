#Requires -Version 5.1
<#
.SYNOPSIS
    Rotates the NGINX access log of an installed DELTA. Run daily by the
    scheduled task the management utility registers, and usable by hand.

.DESCRIPTION
    One small job, once:

      1. rename <InstallRoot>\logs\nginx\access.log to access.log.<timestamp>
      2. signal NGINX to reopen its log, so it writes to a fresh file at the
         path its configuration names
      3. delete rotations older than the newest seven

    NGINX rotates only when it is told to, and the bind-mounted access log
    would otherwise grow without limit until it filled the system volume -
    which would take the database down with it. This is the small scheduled
    trim the assessment recommends (A section 26, U4), and nothing more: it
    knows one file, in one directory, belonging to one installation.

    It touches no other file, stops and restarts nothing, changes no
    configuration, and never removes a container, a network or a volume. An
    absent or empty access log is "nothing to do", not a failure, so a daily
    run on a quiet installation is a no-op.

.PARAMETER InstallRoot
    The installation whose access log is rotated. Defaults to C:\DELTA.

.PARAMETER Retain
    How many rotated files to keep. Defaults to 7.

.NOTES
    Exit codes:
      0  rotated, or there was nothing to rotate
      1  an unhandled failure
     10  the installation could not be read
     11  the log could not be rotated
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\DELTA',
    [int]$Retain = 7
)

$ErrorActionPreference = 'Stop'

# This script lives in bin\, so the installer root - the directory holding
# setup.ps1, lib\ and templates\ - is one level up from it. Everything below
# resolves from there, never from the caller's working directory.
$Script:DeltaScriptRoot = Split-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Path -Parent) -Parent

# The same library set and the same integrity check setup.ps1 makes: a
# half-loaded library must be a refusal to start rather than a
# CommandNotFoundException part-way through. Nobody is watching this run.
$Script:DeltaRotationLibraries = [ordered]@{
    'Delta.Common.ps1'  = 'Write-Step'
    'Delta.Config.ps1'  = 'Read-DeltaEnvFile'
    'Delta.Docker.ps1'  = 'Invoke-DeltaDockerCommand'
    'Delta.Network.ps1' = 'Get-DeltaPublicUrl'
    'Delta.Stack.ps1'   = 'Get-DeltaStackConfiguration'
    'Delta.Manage.ps1'  = 'Invoke-DeltaNginxLogRotation'
}

foreach ($library in $Script:DeltaRotationLibraries.Keys) {
    $libraryPath = Join-Path -Path $Script:DeltaScriptRoot -ChildPath "lib\$library"
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        Write-Host "Required library not found: $libraryPath" -ForegroundColor Red
        exit 1
    }
    . $libraryPath
}
foreach ($library in $Script:DeltaRotationLibraries.Keys) {
    $required = $Script:DeltaRotationLibraries[$library]
    if (-not (Get-Command -Name $required -CommandType Function -ErrorAction SilentlyContinue)) {
        Write-Host "Required library did not load correctly: lib\$library (it should define $required)" -ForegroundColor Red
        Write-Host 'Nothing has been changed on this machine.'
        exit 1
    }
}

$Script:DeltaRotateExitOk        = 0
$Script:DeltaRotateExitFailure   = 1
$Script:DeltaRotateExitNoInstall = 10
$Script:DeltaRotateExitNotDone   = 11

$exitCode = $Script:DeltaRotateExitOk
$logDirectory = Join-Path -Path $InstallRoot -ChildPath 'logs\installer'

try {
    # Appended to the same file the startup task writes, for the same reason:
    # an operator looking into what a scheduled job did needs a history, not a
    # directory of one-line transcripts.
    $null = Start-DeltaLog -Directory $logDirectory -Name 'startup' -Append

    Show-Section -Title 'DELTA NGINX access-log rotation' -Subtitle "Installation root: $InstallRoot"

    $null = Initialize-DeltaDockerPath

    $configuration = Get-DeltaStackConfiguration -InstallRoot $InstallRoot
    if (-not $configuration) {
        Write-DeltaFailure "There is no .env at '$InstallRoot', so there is no installation to rotate logs for."
        $exitCode = $Script:DeltaRotateExitNoInstall
    }
    else {
        $rotation = Invoke-DeltaNginxLogRotation -InstallRoot $InstallRoot -Configuration $configuration -Retain $Retain

        if ($rotation.Succeeded) {
            if ($rotation.Rotated) {
                Write-Success "Rotated $($rotation.LogPath)"
                Write-Detail "Rotated to      $($rotation.RotatedTo)"
                Write-Detail "NGINX reopened  $($rotation.Reopened)"
                Write-Detail "Retained        $($rotation.Retained.Count) file(s): $($rotation.Retained -join ', ')"
                if ($rotation.Removed.Count -gt 0) {
                    Write-Detail "Deleted         $($rotation.Removed -join ', ')"
                }
            }
            else {
                Write-Detail $rotation.Reason
            }
        }
        else {
            Write-DeltaFailure 'The access log was not rotated.'
            Write-Detail $rotation.Reason
            Write-Detail 'The stack was not touched; NGINX is still serving.'
            $exitCode = $Script:DeltaRotateExitNotDone
        }
    }
}
catch {
    $exitCode = $Script:DeltaRotateExitFailure
    Write-DeltaFailure "The rotation script stopped with an error: $($_.Exception.Message)"
    Write-DeltaLogLine -Message $_.ScriptStackTrace -Level 'ERROR'
}
finally {
    Stop-DeltaLog -ExitCode $exitCode
}

exit $exitCode
