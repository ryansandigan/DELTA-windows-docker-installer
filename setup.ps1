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

.PARAMETER ComposeProject
.PARAMETER PgDataVolume
    Names for this installation's Compose project and PostgreSQL volume,
    used only when creating a new installation. They identify a live
    installation's containers and its data, so an existing .env always wins:
    a second installation on one machine needs its own names, and reusing
    another installation's would point this one at that one's stack.

.PARAMETER NonInteractive
    Never prompt. Ports and TLS must then be fully specified, and the
    administrator credential is generated rather than typed. On a registered
    installation this prints the management status once and exits instead of
    drawing a menu nobody can answer.

.PARAMETER Reconfigure
    Run the installation flow against a registered installation instead of
    opening the management utility.

    The mode is otherwise chosen automatically and there is no -Install /
    -Manage switch (A section 17.1): a complete installation opens the
    management utility, anything else installs. This switch exists for the one
    thing management mode deliberately does not do - re-resolving ports, TLS
    and the generated artefacts - and it is as non-destructive as any other
    rerun: existing secrets, data, certificates and image pins are preserved.

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
      9  the administrator credential could not be secured; DELTA was not published
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
    [string]$ComposeProject,
    [string]$PgDataVolume,
    [switch]$NonInteractive,
    [switch]$Reconfigure
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Library loading
# ---------------------------------------------------------------------------

$Script:DeltaScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

# Each library, and one function it must have defined once it is loaded. The
# check exists because a library that is missing, stale or half-loaded
# otherwise announces itself as a CommandNotFoundException in the middle of an
# installation - and the one that bit was the administrator reset, discovered
# after the database was already initialised. A missing entry point is now a
# refusal to start, before anything on the machine has been touched.
$Script:DeltaLibraries = [ordered]@{
    'Delta.Common.ps1'  = 'Write-Step'
    'Delta.Config.ps1'  = 'Read-DeltaEnvFile'
    'Delta.Docker.ps1'  = 'Invoke-DeltaRuntimeStage'
    'Delta.Stack.ps1'   = 'Invoke-DeltaStackStage'
    'Delta.Network.ps1' = 'Invoke-DeltaNetworkStage'
    'Delta.Manage.ps1'  = 'Invoke-DeltaManagementMode'
    # Configuration management (SMTP, administrator credential, certificate
    # replacement). Loaded after Delta.Manage.ps1 because it composes that
    # file's primitives rather than duplicating them.
    'Delta.Configure.ps1' = 'Invoke-DeltaSmtpConfiguration'
    # Domain Management. Loaded last because it composes the NGINX generator,
    # the nginx -t / reload primitives, the .env writer and the certificate
    # inspector rather than reimplementing any of them.
    'Delta.Domain.ps1'    = 'Invoke-DeltaDomainOperation'
    # Certificate Management. Loaded after Delta.Domain.ps1 because it consumes
    # the authoritative domain model to decide certificate coverage, and after
    # Delta.Configure.ps1 because it composes that file's certificate
    # primitives and its application-container recreation.
    'Delta.Tls.ps1'       = 'Invoke-DeltaCertificateOperation'
}

foreach ($library in $Script:DeltaLibraries.Keys) {
    $libraryPath = Join-Path -Path $Script:DeltaScriptRoot -ChildPath "lib\$library"
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        Write-Host "Required library not found: $libraryPath" -ForegroundColor Red
        Write-Host 'Run setup.ps1 from the directory it was distributed in, with its lib\ folder intact.'
        exit 1
    }
    . $libraryPath
}

foreach ($library in $Script:DeltaLibraries.Keys) {
    $required = $Script:DeltaLibraries[$library]
    if (-not (Get-Command -Name $required -CommandType Function -ErrorAction SilentlyContinue)) {
        Write-Host "Required library did not load correctly: lib\$library" -ForegroundColor Red
        Write-Host "It should define $required, and after loading it that function does not exist."
        Write-Host 'This usually means lib\ and setup.ps1 come from different versions of the installer.'
        Write-Host 'Nothing has been changed on this machine. Reinstall the installer files as a set.'
        exit 1
    }
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

function Show-DeltaRestartBehaviour {
    <#
      What actually happens after a Windows restart on THIS machine, stated at
      the level of confidence the evidence supports and no higher (A§16.3
      Layer 4).

      There are exactly three things this can say, and which one it says is
      decided by the state file, not by what was configured in the abstract:

        - a mechanism is configured AND a real unattended restart has been
          measured to bring DELTA back. Only then does this claim automatic
          recovery.
        - a mechanism is configured but no restart has confirmed it. It says
          so, in those words. "Configured" is not "works".
        - nothing is configured. It says DELTA stays down until somebody signs
          in, because that is what will happen.

      The wording matters more than it looks: an operator who reads "DELTA
      starts automatically" and does not test it will find out during an
      overnight patch reboot.
    #>
    param(
        [object]$Startup,
        [string]$ScriptRoot,
        [string]$InstallRoot
    )

    $startupScript = Join-Path -Path $ScriptRoot -ChildPath 'bin\start-delta.ps1'

    if (-not $Startup -or -not $Startup.Succeeded) {
        Write-Detail 'DELTA returns when Docker Desktop is running. Nothing on this machine starts Docker'
        Write-Detail 'before somebody signs in to Windows, and unattended startup could not be configured,'
        Write-Detail 'so after a restart that nobody signs in after, DELTA stays down.'
        if ($Startup -and $Startup.Reason) { Write-Detail "Reason: $($Startup.Reason)" }
        Write-Detail "To bring it back by hand:  .\bin\start-delta.ps1 -InstallRoot $InstallRoot"
        return
    }

    $mechanism = switch ($Startup.Mechanism) {
        'startup-task' { "a scheduled task at Windows startup ($(if ($Startup.Task) { $Startup.Task.Name } else { 'DELTA startup task' }))" }
        'vendor'       { "Docker's own startup mechanism on this host" }
        default        { $Startup.Mechanism }
    }

    if ($Startup.BootTested) {
        Write-Detail "DELTA starts automatically after a restart, with no sign-in, via $mechanism."
        Write-Detail "Measured on this machine by a real unattended restart on $($Startup.BootTest.at)."
        Write-Detail 'Recovery begins about a minute after boot and completes once Docker and the three'
        Write-Detail 'containers are healthy.'
    }
    else {
        Write-Detail "Unattended startup is CONFIGURED but NOT YET PROVEN on this machine."
        Write-Detail "Mechanism: $mechanism."
        Write-Detail 'It has not been demonstrated by a real restart here, so this installer will not tell'
        Write-Detail 'you that DELTA comes back on its own. Test it the only way that counts: restart'
        Write-Detail 'Windows, do NOT sign in, and request the URL above from another machine.'
    }

    Write-Detail ''
    Write-Detail "Startup log       $InstallRoot\logs\installer\startup.log"
    Write-Detail "Start by hand     .\bin\start-delta.ps1 -InstallRoot $InstallRoot"
    if (-not (Test-Path -LiteralPath $startupScript -PathType Leaf)) {
        Write-DeltaWarning "The startup script is missing from $startupScript."
    }
}

function Show-DeltaCompletionSummary {
    <#
      What the operator sees when an installation succeeds: where DELTA is,
      how to reach it, what was done to secure it, what to tell the antivirus,
      and - stated exactly as it is today - what happens after a restart.

      Every URL comes from Get-DeltaPublicUrl. The generated administrator
      credential is shown here and only here, once, and is never written to the
      transcript, .env or the state file.
    #>
    param([Parameter(Mandatory)][object]$Stack)

    $network = $Stack.Network
    $root = $Stack.Configuration.Path | Split-Path -Parent
    $scheme = if ($network.TlsEnabled) { 'https' } else { 'http' }
    $port = if ($network.TlsEnabled) { [int]$network.HttpsPort } else { [int]$network.HttpPort }
    $baseUrl = Get-DeltaPublicUrl -Scheme $scheme -HostName $network.HostName -Port $port

    Show-Section -Title 'DELTA is installed' -Subtitle $baseUrl

    Write-Host 'Access'
    Write-Detail "Application      $baseUrl"
    Write-Detail "Administrator    $baseUrl/en/admin/login"
    Write-Detail "Users            $baseUrl/en/user/login"
    Write-Detail ''

    Write-Host 'Configuration'
    Write-Detail "Installed at     $root"
    Write-Detail "Hostname         $($network.HostName)"
    if ($network.TlsEnabled) {
        Write-Detail "HTTPS            port $($network.HttpsPort) ($($network.TlsMode) certificate)"
        Write-Detail "HTTP             port $($network.HttpPort), redirects to HTTPS"
    }
    else {
        Write-Detail "HTTP             port $($network.HttpPort)"
        Write-Detail 'HTTPS            not configured'
    }
    Write-Detail ''

    Write-Host 'Security'
    if ($Stack.Bootstrap -and $Stack.Bootstrap.Succeeded) {
        Write-Detail "Administrator    $($Stack.Bootstrap.Email) - credential replaced and verified"
        Write-Detail 'The credential published in the DELTA image no longer works on this installation.'
    }
    else {
        Write-Detail 'Administrator    secured by an earlier run of this installer'
    }
    Write-Detail 'Session secret   generated for this installation only'
    Write-Detail 'Database         reachable only from inside the Compose network; no host port'

    if ($Stack.Firewall) {
        if ($Stack.Firewall.Succeeded) {
            $ports = ($Stack.Firewall.Applied | ForEach-Object { $_.Port }) -join ', '
            Write-Detail "Firewall         inbound TCP $ports allowed"
        }
        else {
            Write-Detail 'Firewall         see the warning above - other machines cannot reach DELTA yet'
        }
    }

    if ($network.TlsEnabled -and $network.TlsMode -eq 'self-signed') {
        Write-Detail ''
        Write-DeltaWarning 'The certificate is self-signed, so browsers will warn until it is trusted or replaced.'
    }
    if (-not $network.TlsEnabled) {
        Write-Detail ''
        Write-DeltaWarning 'Plain HTTP is suitable for localhost testing only. DELTA marks its session cookies'
        Write-DeltaWarning 'Secure, so users reaching this server by hostname will not stay signed in.'
    }

    # Shown once, here, and nowhere else - not in the transcript, not in .env,
    # not in the state file.
    if ($Stack.Bootstrap -and $Stack.Bootstrap.Succeeded -and $Stack.Bootstrap.WasGenerated) {
        $plain = ConvertTo-DeltaPlainText -SecureString $Stack.Bootstrap.Password
        Write-Host ''
        Write-Host ('-' * 72)
        Write-Host ''
        Write-Host '  ADMINISTRATOR CREDENTIAL - shown once, and not stored anywhere'
        Write-Host ''
        Write-Host "  Sign in at   $baseUrl/en/admin/login"
        Write-Host "  Email        $($Stack.Bootstrap.Email)"
        Write-Host "  Password     $plain" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Record it now. This installer does not keep a copy, and nothing on this'
        Write-Host '  machine can recover it - a lost credential is replaced, not retrieved.'
        Write-Host ''
        Write-Host ('-' * 72)
        $plain = $null
        Write-DeltaLogLine -Message 'The generated administrator credential was displayed to the operator (not logged).' -Level 'INFO'
    }

    Write-Host ''
    Write-Host 'After a Windows restart'
    Show-DeltaRestartBehaviour -Startup $Stack.Startup -ScriptRoot $Script:DeltaScriptRoot -InstallRoot $root

    Write-Host ''
    Write-Host 'Antivirus and backup software'
    Write-Detail 'The database lives in a Docker-managed volume, out of reach of Windows-side'
    Write-Detail 'scanners. What does sit on this disk, and what real-time scanning or a file-sync'
    Write-Detail 'client can interfere with, is:'
    Write-Detail "  $root\uploads"
    Write-Detail "  $root\logs"
    Write-Detail "  $root\backups"
    Write-Detail 'Exclude those from real-time scanning if this machine runs an endpoint product,'
    Write-Detail 'and keep the installation root out of any redirected or cloud-synced folder.'

    Write-Host ''
    return $Script:DeltaExitSuccess
}

function Show-DeltaStackOutcome {
    <#
      Reports what the stack stage did and returns the process exit code. A
      migration failure gets its own code and its own wording, because the
      response to it is a restore rather than a retry.
    #>
    param([Parameter(Mandatory)][object]$Stack)

    if ($Stack.Outcome -eq 'ready') {
        return (Show-DeltaCompletionSummary -Stack $Stack)
    }

    Write-Step 'Next steps'

    switch ($Stack.Outcome) {
        'bootstrap' {
            Write-DeltaFailure 'The installation stopped before publishing DELTA.'
            Write-Detail $Stack.Reason
            Write-Detail ''
            Write-Detail 'This is deliberate. The database is initialised but its seeded administrator'
            Write-Detail 'credential is published in the public DELTA image, so the application is not'
            Write-Detail 'started on a host port until that credential has been replaced.'
            Write-Detail ''
            Write-Detail 'Nothing was deleted. Fix the problem above and run this installer again - it'
            Write-Detail 'resumes from here and does not repeat what already succeeded.'
            return $Script:DeltaExitSecurityBootstrapFailed
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

            # Mode dispatch (A section 17.1). A registered, complete
            # installation opens the management utility; anything else installs.
            # The choice is made from the detected state and never from a
            # switch, and it is made here - before the runtime stage - so that
            # rerunning setup.ps1 on a working installation does not repeat the
            # prerequisite checks, the Docker setup, the port and TLS
            # resolution, the artefact generation or the fresh-install
            # orchestration. Management mode does its own read-only engine
            # probe; it does not need this stage to have run.
            if ($state.State -eq 'installed' -and -not $Reconfigure) {
                $exitCode = Invoke-DeltaManagementMode `
                    -InstallRoot $InstallRoot `
                    -ScriptRoot $Script:DeltaScriptRoot `
                    -AllowPrompt (-not $NonInteractive)
            }
            else {
                if ($state.State -eq 'installed') {
                    Write-Step 'Reconfiguring an existing installation'
                    Write-Detail '-Reconfigure was supplied, so the installation flow runs instead of the management'
                    Write-Detail 'utility. Existing secrets, data, certificates and image pins are preserved.'
                }

                $runtime = Invoke-DeltaRuntimeStage `
                    -InstallRoot $InstallRoot `
                    -ScriptRoot $Script:DeltaScriptRoot `
                    -DockerInstallerPath $DockerInstallerPath `
                    -AllowDownload:$AllowDockerDownload

                $exitCode = Show-DeltaRuntimeOutcome -Runtime $runtime -State $state -InstallRoot $InstallRoot

                if ($runtime.Outcome -eq 'ready') {
                    # Everything the administrator has to decide is asked here,
                    # before the image pull and the health gates - so a person
                    # who starts the installer and walks away comes back to a
                    # finished installation rather than to a waiting prompt.
                    # What is asked depends on what the installation already
                    # has, so a rerun and -Reconfigure stay quiet.
                    $settings = Read-DeltaFreshInstallSettings `
                        -InstallRoot $InstallRoot `
                        -AllowPrompt (-not $NonInteractive) `
                        -HostName $Hostname

                    $stack = Invoke-DeltaStackStage `
                        -InstallRoot $InstallRoot `
                        -ScriptRoot $Script:DeltaScriptRoot `
                        -PendingFacts $runtime.PendingFacts `
                        -Runtime $runtime `
                        -HttpPort $HttpPort `
                        -HttpsPort $HttpsPort `
                        -HostName $settings.HostName `
                        -TlsMode $TlsMode `
                        -CertificatePath $CertificatePath `
                        -CertificateKeyPath $CertificateKeyPath `
                        -ComposeProject $ComposeProject `
                        -PgDataVolume $PgDataVolume `
                        -PostgresPassword $settings.PostgresPassword `
                        -AdminPassword $settings.AdminPassword `
                        -AdminPasswordWasGenerated $settings.AdminPasswordWasGenerated `
                        -AllowPrompt (-not $NonInteractive)

                    $exitCode = Show-DeltaStackOutcome -Stack $stack
                }
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
