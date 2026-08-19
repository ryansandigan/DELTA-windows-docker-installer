#Requires -Version 5.1
<#
.SYNOPSIS
    DELTA Windows Docker Installer - single operator entry point.

.DESCRIPTION
    One entry point for both installation and management; the mode is chosen
    from the detected installation state, never from a switch (A§17.1).

    It verifies elevation, classifies the installation state from evidence on
    disk, and then proves the host can run Linux containers - disclosing the
    caveats it is obliged to disclose, installing Docker Desktop when it is
    absent, and validating that the engine and Compose are usable.

    Compose artefacts, image pulls, the stack itself and the management menu
    arrive in later phases and are not implemented here - the script says so
    rather than implying otherwise.

.PARAMETER InstallRoot
    Installation root to inspect. Defaults to C:\DELTA (A§9.1).

.PARAMETER LogDirectory
    Directory for the installer transcript. Defaults to logs\installer next to
    this script. A§21.1 places installer transcripts under the installation
    root; that becomes the default once the stage that owns C:\DELTA creates
    it, and until then this script writes nothing into an installation root it
    does not yet own.

.PARAMETER DockerInstallerPath
    Path to "Docker Desktop Installer.exe", for sites that stage the binary
    themselves. Used only when Docker is absent. Without it the installer
    looks in installers\ next to setup.ps1.

.PARAMETER AllowDockerDownload
    Permit downloading Docker Desktop from Docker's documented URL when it is
    absent and no local installer was found. The download still happens only
    after the licence disclosure is accepted.

.PARAMETER HttpPort
    Publish NGINX's HTTP port on this Windows port. Without it the installer
    uses the value already in .env, or 80, and resolves a conflict with the
    operator. Supplying it makes the choice non-interactive: a conflict is
    reported and refused rather than prompted.

.PARAMETER HttpsPort
    The same, for HTTPS. Defaults to 443.

.PARAMETER Hostname
    The hostname this installation is reached by. Becomes NGINX's server_name
    and the host part of PUBLIC_URL. Defaults to localhost.

.PARAMETER TlsMode
    none         plain HTTP only
    supplied     use -CertificatePath and -CertificateKeyPath
    self-signed  generate a certificate for -Hostname
    Without it the installer asks, or keeps what .env already records.

.PARAMETER CertificatePath
.PARAMETER CertificateKeyPath
    PEM certificate and private key for -TlsMode supplied. Both are validated -
    including that the key actually matches the certificate - before anything
    is written into the live configuration.

.NOTES
    Exit codes:
      0  success
      1  unhandled failure
      2  not elevated
      3  the installation root is not a usable path
      4  a prerequisite cannot be met, or Docker is unusable
      5  Windows must restart; run setup.ps1 again afterwards
      6  the operator declined a required disclosure
      7  the stack could not be generated or started
      8  the database initialisation could not be verified
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\DELTA',
    [string]$LogDirectory,
    [string]$DockerInstallerPath,
    [switch]$AllowDockerDownload,
    [int]$HttpPort,
    [int]$HttpsPort,
    [string]$Hostname,
    [ValidateSet('none', 'supplied', 'self-signed')][string]$TlsMode,
    [string]$CertificatePath,
    [string]$CertificateKeyPath,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Library loading
# ---------------------------------------------------------------------------

$Script:DeltaScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

foreach ($library in @('Delta.Common.ps1', 'Delta.Config.ps1', 'Delta.Docker.ps1', 'Delta.Stack.ps1', 'Delta.Network.ps1')) {
    $libraryPath = Join-Path -Path $Script:DeltaScriptRoot -ChildPath "lib\$library"
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        Write-Host "Required library not found: $libraryPath" -ForegroundColor Red
        Write-Host 'Run setup.ps1 from the directory it was distributed in, with its lib\ folder intact.'
        exit 1
    }
    . $libraryPath
}

if (-not $LogDirectory) {
    $LogDirectory = Join-Path -Path $Script:DeltaScriptRoot -ChildPath 'logs\installer'
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------

function Test-DeltaElevationRequirement {
    <#
      Elevation is checked once, up front, and reported here; main turns the
      result into the process exit code. Every later stage - creating the
      installation root, hardening .env, writing firewall rules, installing
      Docker Desktop - requires it, so discovering it late would mean failing
      half-way through instead of before anything happened.
    #>
    Write-Step 'Checking privileges'

    if (Test-IsAdministrator) {
        Write-Detail 'Running elevated.'
        return $true
    }

    Write-DeltaFailure ''
    Write-DeltaFailure 'This installer must run as Administrator.'
    Write-Detail ''
    Write-Detail 'Close this window, then start Windows PowerShell with "Run as administrator"'
    Write-Detail "and run:  cd `"$Script:DeltaScriptRoot`"  then  .\setup.ps1"
    Write-Detail ''

    return $false
}

function Confirm-DeltaInstallRoot {
    <#
      Validates the installation-root path against the A§9.5 constraints and
      reports, without creating anything: creating the directory tree belongs
      to the stage that owns it.
    #>
    param([Parameter(Mandatory)][string]$Path)

    Write-Step 'Checking the installation root'

    $candidate = Test-DeltaInstallRootCandidate -Path $Path -TestWritable
    if (-not $candidate.IsValid) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'The installation root cannot be used.'
        Write-Detail $candidate.Reason
        Write-Detail ''
        Write-Detail 'Re-run with a different root, for example:  .\setup.ps1 -InstallRoot D:\DELTA'
        return $candidate
    }

    if ($candidate.Exists) {
        Write-Detail "$Path exists and is writable."
    }
    else {
        Write-Detail "$Path does not exist yet. It will be created when installation is implemented."
    }

    return $candidate
}

function Show-DeltaInstallationState {
    <#
      Prints the evidence the classification was drawn from, then the
      classification itself. The evidence is shown first deliberately: an
      operator looking at a "partial" verdict needs to see what led to it
      before being told what it means.
    #>
    param([Parameter(Mandatory)][string]$Path)

    Write-Step 'Detecting the installation state'

    $state = Get-DeltaInstallationState -InstallRoot $Path

    foreach ($item in $state.Evidence) {
        $marker = if ($item.Present) { '[present]' } else { '[absent] ' }
        Write-Detail ("{0} {1,-24} {2}" -f $marker, $item.Item, $item.Detail)
    }

    if ($state.EnvFile -and $state.EnvFile.Malformed.Count -gt 0) {
        Write-Detail ''
        Write-DeltaWarning "$($state.EnvFile.Path) has lines this installer could not parse. They were left untouched:"
        foreach ($bad in $state.EnvFile.Malformed) {
            # The offending text is echoed so the operator can act on it, but
            # it is redacted first: this is the one place the installer prints
            # back the contents of the file that holds every secret, and a
            # console can be shared as easily as a transcript.
            $safeLine = Protect-DeltaSecretText -Text $bad.Line
            Write-DeltaWarning "  line $($bad.LineNumber): $($bad.Reason)"
            Write-DeltaWarning "    $safeLine"
        }
    }

    Write-Detail ''
    Write-Success "state = $($state.State)"
    Write-Detail $state.Reason

    return $state
}

function Show-DeltaRuntimeOutcome {
    <#
      Turns the runtime stage's outcome into what the operator sees and the
      code the process exits with. "Restart Windows and run this again" is
      reported as the next step it is, not as a failure.

      When the engine is unusable over an otherwise-registered installation,
      the classification is re-reported with that evidence supplied - the
      `docker-unavailable` state of A§28, which Phase 1 built the seam for and
      this phase is the first that can actually fill in.
    #>
    param(
        [Parameter(Mandatory)][object]$Runtime,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    if ($Runtime.Outcome -ne 'ready' -and $State.State -eq 'installed') {
        $refined = Get-DeltaInstallationState -InstallRoot $InstallRoot -DockerStatus 'unavailable'
        Write-Detail ''
        Write-Success "state = $($refined.State)"
        Write-Detail $refined.Reason
    }

    switch ($Runtime.Outcome) {
        'ready' {
            Write-Detail ''
            Write-Success 'This host can run DELTA.'
            Write-Detail $Runtime.Reason
            return $Script:DeltaExitSuccess
        }
    }

    Write-Step 'Next steps'

    switch ($Runtime.Outcome) {
        'reboot-required' {
            Write-DeltaWarning 'Windows must restart before installation can continue.'
            Write-Detail $Runtime.Reason
            Write-Detail ''
            Write-Detail 'Restart this machine, sign in, then run this installer again:'
            Write-Detail "  cd `"$Script:DeltaScriptRoot`"  then  .\setup.ps1"
            Write-Detail 'Nothing else needs to be repeated - the installer picks up where it left off.'
            return $Script:DeltaExitRebootRequired
        }
        'declined' {
            Write-Detail $Runtime.Reason
            Write-Detail 'Nothing was installed or changed. Run this installer again if you change your mind.'
            return $Script:DeltaExitOperatorDeclined
        }
        default {
            Write-Detail 'Installation cannot continue until the problem reported above is resolved.'
            Write-Detail 'Nothing was installed or changed.'
            return $Script:DeltaExitPrerequisiteFailed
        }
    }
}

function Show-DeltaStackOutcome {
    <#
      Reports what the stack stage did and returns the process exit code. A
      migration failure gets its own code and its own wording, because the
      response to it is a restore rather than a retry.
    #>
    param([Parameter(Mandatory)][object]$Stack)

    Write-Step 'Next steps'

    switch ($Stack.Outcome) {
        'ready' {
            Write-Success 'DELTA is running.'
            Write-Detail $Stack.Reason
            Write-Detail ''
            Write-Detail "Application      $($Stack.Configuration.PublicUrl)"
            Write-Detail "Administrator    $($Stack.Configuration.PublicUrl)/en/admin/login"
            Write-Detail "Installation     $($Stack.Configuration.Path | Split-Path -Parent)"
            Write-Detail ''
            if ($Stack.Network -and $Stack.Network.TlsEnabled) {
                Write-Detail "HTTPS is enabled on port $($Stack.Network.HttpsPort); HTTP on $($Stack.Network.HttpPort) redirects to it."
                if ($Stack.Network.TlsMode -eq 'self-signed') {
                    Write-DeltaWarning 'The certificate is self-signed, so browsers will warn until it is trusted or replaced.'
                }
            }
            else {
                Write-DeltaWarning 'Plain HTTP is suitable for localhost testing only. Session cookies are marked Secure,'
                Write-DeltaWarning 'so users reaching this server by hostname over plain HTTP will not stay signed in.'
            }
            Write-Detail ''
            Write-Detail 'Still to come: the administrator credential reset that closes the published'
            Write-Detail 'default, firewall rules, unattended restart and the management menu. The default'
            Write-Detail 'administrator has NOT been reset yet - do not expose this installation beyond'
            Write-Detail 'this machine until it has.'
            return $Script:DeltaExitSuccess
        }
        'migration' {
            Write-DeltaFailure 'The installation stopped after the database initialisation could not be verified.'
            Write-Detail $Stack.Reason
            Write-Detail ''
            Write-Detail 'The stack was not published. Inspect the errors above before running this again -'
            Write-Detail 'a failed migration is recovered by restoring the database, not by retrying.'
            return $Script:DeltaExitMigrationFailed
        }
        default {
            Write-Detail $Stack.Reason
            Write-Detail 'Nothing was deleted. Resolve the problem above and run this installer again.'
            return $Script:DeltaExitStackFailed
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$exitCode = $Script:DeltaExitSuccess

try {
    $logPath = Start-DeltaLog -Directory $LogDirectory

    Show-Section -Title 'DELTA Windows Docker Installer' -Subtitle "Installation root: $InstallRoot"

    if ($logPath) {
        Write-Detail "Transcript: $logPath"
        Write-Detail ''
    }

    if (-not (Test-DeltaElevationRequirement)) {
        $exitCode = $Script:DeltaExitNotElevated
    }
    else {
        $candidate = Confirm-DeltaInstallRoot -Path $InstallRoot
        if (-not $candidate.IsValid) {
            $exitCode = $Script:DeltaExitInvalidInstallRoot
        }
        else {
            $state = Show-DeltaInstallationState -Path $InstallRoot

            $runtime = Invoke-DeltaRuntimeStage `
                -InstallRoot $InstallRoot `
                -ScriptRoot $Script:DeltaScriptRoot `
                -DockerInstallerPath $DockerInstallerPath `
                -AllowDownload:$AllowDockerDownload

            $exitCode = Show-DeltaRuntimeOutcome -Runtime $runtime -State $state -InstallRoot $InstallRoot

            if ($runtime.Outcome -eq 'ready') {
                $stack = Invoke-DeltaStackStage `
                    -InstallRoot $InstallRoot `
                    -ScriptRoot $Script:DeltaScriptRoot `
                    -PendingFacts $runtime.PendingFacts `
                    -Runtime $runtime `
                    -HttpPort $HttpPort `
                    -HttpsPort $HttpsPort `
                    -HostName $Hostname `
                    -TlsMode $TlsMode `
                    -CertificatePath $CertificatePath `
                    -CertificateKeyPath $CertificateKeyPath `
                    -AllowPrompt (-not $NonInteractive)

                $exitCode = Show-DeltaStackOutcome -Stack $stack
            }
        }
    }

    Write-Host ''
}
catch {
    $exitCode = $Script:DeltaExitFailure
    Write-DeltaFailure ''
    Write-DeltaFailure 'The installer stopped with an error.'
    Write-Detail $_.Exception.Message
    if ($_.ScriptStackTrace) {
        Write-DeltaLogLine -Message $_.ScriptStackTrace -Level 'ERROR'
    }
    Write-Host ''
}
finally {
    Stop-DeltaLog -ExitCode $exitCode
}

exit $exitCode
