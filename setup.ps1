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

    Supplying it settles the matter: the installer uses it and asks nothing.
    Without it, a new interactive installation offers C:\DELTA and, if the
    operator declines, opens a folder selection window to choose another - no
    path is ever typed at the prompt. A run that is non-interactive, that
    already has an installation at the default root, or that cannot open a
    dialog uses the default exactly as before.

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
    Retained for compatibility and no longer required: when Docker Desktop is
    absent and no local installer was found, the installer downloads it from
    Docker's documented URL automatically. The download still happens only
    after the licence disclosure is accepted, and the downloaded file is
    verified (size, PE header, Authenticode signature) before it is run.
    Pass -NoDockerDownload to forbid the download instead.

.PARAMETER NoDockerDownload
    Never download Docker Desktop. For hosts with no outbound access, where a
    slow failed transfer is worse than an immediate refusal: acquisition then
    stops at -DockerInstallerPath and installers\, and says so at once.

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
    [switch]$NoDockerDownload,
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

function Write-DeltaManualRerunCommands {
    <#
      The one place that says how to start this installer by hand, so every
      caller says it the same way and none of them can drift.

      Set-ExecutionPolicy is part of the instruction because Windows blocks
      .ps1 files by default and an operator who is told only "run .\setup.ps1"
      meets "running scripts is disabled on this system" instead. -Scope
      Process is the whole of the concession: it lives in that one PowerShell
      window and dies with it. LocalMachine and CurrentUser are persistent
      changes to a machine this installer does not own, and are never used or
      suggested here.

      -InstallRoot is echoed only when it is not the default, because a manual
      rerun that quietly reverted to C:\DELTA would resume against a different
      installation than the one in progress.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [string]$InstallRoot
    )

    $rerun = if ($InstallRoot -and $InstallRoot -ne 'C:\DELTA') { ".\setup.ps1 -InstallRoot `"$InstallRoot`"" }
             else { '.\setup.ps1' }

    Write-Detail "  cd `"$ScriptRoot`""
    Write-Detail '  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass'
    Write-Detail "  $rerun"
    Write-Detail ''
    Write-Detail 'Set-ExecutionPolicy -Scope Process applies to that PowerShell window only.'
    Write-Detail 'It does not change the execution policy for your account or for this machine,'
    Write-Detail 'and Windows forgets it when the window closes. It is there because Windows'
    Write-Detail 'blocks .ps1 files by default - the "running scripts is disabled on this'
    Write-Detail 'system" error.'
}

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
    Write-Detail 'and run:'
    Write-Detail ''
    Write-DeltaManualRerunCommands -ScriptRoot $Script:DeltaScriptRoot
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
            # The restart itself is offered by Request-DeltaWindowsRestart in
            # Main, not here: this function reports an outcome and returns a
            # code, and the machine must not go down from inside a reporting
            # function. The "restart it yourself" instructions live with the
            # decline path, which is where they are the answer.
            Write-DeltaWarning 'Windows must restart before installation can continue.'
            Write-Detail $Runtime.Reason
            return $Script:DeltaExitRebootRequired
        }
        'declined' {
            Write-Detail $Runtime.Reason
            Write-Detail 'Nothing was installed or changed. Run this installer again if you change your mind.'
            return $Script:DeltaExitOperatorDeclined
        }
        default {
            Write-Detail 'Installation cannot continue until the problem reported above is resolved.'
            # Only claimed when it is true. A run that installed Docker Desktop
            # and then found the engine unusable has changed this machine, and
            # telling the operator otherwise invites them to "start again" -
            # which is how a second Docker installation gets attempted over the
            # first.
            if ($Runtime.PSObject.Properties.Name -contains 'DockerInstallAttempted' -and $Runtime.DockerInstallAttempted) {
                Write-Detail 'Docker Desktop was installed by this run. Rerunning setup.ps1 detects it and does not'
                Write-Detail 'install it again or ask you to accept the licence again.'
            }
            elseif ($Runtime.PSObject.Properties.Name -contains 'WslInstalled' -and $Runtime.WslInstalled) {
                Write-Detail 'The WSL platform was installed by this run. Nothing about Docker was changed.'
            }
            else {
                Write-Detail 'Nothing was installed or changed.'
            }
            return $Script:DeltaExitPrerequisiteFailed
        }
    }
}

# Where the one-time logon continuation lives. RunOnce, not Run: Windows
# deletes a RunOnce value BEFORE executing it, so the entry is spent by the
# time setup.ps1 starts and a failed or cancelled continuation cannot fire
# again at the next logon. HKCU, so it belongs to - and fires for - the account
# that ran the installer, and needs no machine-wide write.
$Script:DeltaRunOnceKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$Script:DeltaRunOnceName = 'DELTASetupContinue'

function Unregister-DeltaLogonContinuation {
    <#
      Removes the one-time continuation, if it is there. Safe to call when
      nothing was ever registered.
    #>

    try {
        if (Test-Path -LiteralPath $Script:DeltaRunOnceKey) {
            Remove-ItemProperty -LiteralPath $Script:DeltaRunOnceKey -Name $Script:DeltaRunOnceName -ErrorAction SilentlyContinue
        }
        return $true
    }
    catch {
        return $false
    }
}

function Compress-DeltaContinuationScript {
    <#
      Removes comments and runs of blank lines from a generated script, so the
      -EncodedCommand it becomes carries code and nothing else.

      Done with the tokenizer rather than a regex, and by deleting the exact
      character spans the tokenizer reports as comments: a '#' inside a string
      literal - '  Start > type "Windows PowerShell" > ...' is one keystroke
      away from having one - is not a comment, and a regex that treated it as
      one would silently truncate a line of operator instructions.

      Everything that is not a comment is preserved byte for byte. If the
      tokenizer reports any error at all the script is returned untouched: a
      slightly longer command line is a trade worth making against a mangled
      one.
    #>
    param([Parameter(Mandatory)][string]$Script)

    $errors = $null
    $tokens = [System.Management.Automation.PSParser]::Tokenize($Script, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { return $Script }

    $text = $Script
    $comments = @($tokens | Where-Object { $_.Type -eq 'Comment' } | Sort-Object Start -Descending)
    foreach ($comment in $comments) {
        $text = $text.Remove($comment.Start, $comment.Length)
    }

    # A removed comment leaves the line it was on blank. Collapse those, and
    # any run of blank lines, to a single one - the script stays readable if
    # anyone ever decodes the registry value to audit it.
    $text = [regex]::Replace($text, '(?m)^[ \t]+$', '')
    $text = [regex]::Replace($text, '(\r?\n){3,}', "`r`n`r`n")

    return $text.Trim()
}

function Register-DeltaLogonContinuation {
    <#
      Arranges for setup.ps1 to run itself again at the operator's next
      interactive logon, once, after an installer-managed restart.

      Registered ONLY when the operator explicitly chose the restart below -
      OK on the restart dialog, or Y at its console fallback. A declined
      restart, a non-interactive run and a reboot the operator performs
      themselves all leave the machine with nothing scheduled.

      Three separate things stop this becoming a logon loop:

        - RunOnce. Windows deletes the value before it runs the command, so it
          is already spent when setup.ps1 starts.
        - The command deletes the value itself, first, before doing anything
          else - so a Windows that behaved differently, or an entry somehow
          written twice, still only fires once.
        - Nothing is re-registered except by another explicit approval of the
          restart. The continuation itself never registers anything.

      No step-specific resume state is written anywhere. The continuation runs
      the same setup.ps1 with the same -InstallRoot, and the installer's own
      state detection decides what happens next - which is exactly what a
      manual rerun does, so there is one resume path rather than two.

      -InstallRoot is carried across because it selects which installation is
      detected; a continuation that silently reverted to C:\DELTA would install
      the wrong thing. Other switches are not carried across, and the operator
      is told to rerun by hand if they need them.

      The relaunch elevates. RunOnce runs with the user's filtered token, so
      the command opens a visible window that explains itself and then asks for
      elevation - a UAC prompt appearing unexplained after a restart is how an
      operator learns to click No. It was also explained before the machine
      went down, in the restart dialog, which is where the operator agreed to
      all of this; nothing here asks them to agree a second time. setup.ps1
      itself never elevates; it checks and refuses. Keeping elevation here, in
      the one launcher, is what makes the resumed run exactly one UAC flow.

      Three things the generated script does that a bare Start-Process -Verb
      RunAs at logon does not, each of them a failure seen on Windows 11:

        - It waits for the desktop shell instead of sleeping a fixed five
          seconds. RunOnce fires while the logon is still in progress, and an
          elevation requested before the desktop can host the consent UI comes
          back as ERROR_CANCELLED without anything having been shown.
        - It skips elevation entirely when the logon session is already
          elevated (the built-in Administrator account, or UAC turned off).
          Asking again there would be a second, pointless prompt.
        - It offers the prompt again instead of dead-ending. Windows reports a
          declined prompt and an auto-cancelled one with the same error code,
          so the two cannot be told apart in code - but the operator can tell
          them apart, so the retry is theirs to ask for and never automatic.
          Typing N stops, and the manual instructions are printed either way.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    $result = [PSCustomObject]@{
        Succeeded = $false
        Reason    = $null
        Key       = $Script:DeltaRunOnceKey
        Name      = $Script:DeltaRunOnceName
    }

    $setupPath = Join-Path -Path $ScriptRoot -ChildPath 'setup.ps1'
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        $result.Reason = "setup.ps1 is not at '$setupPath', so there is nothing to continue with."
        return $result
    }

    # Quoted the same way the scheduled tasks are, so a path with spaces
    # survives the trip through the shell. -ExecutionPolicy Bypass is on this
    # command line, not applied to the machine: it lasts exactly as long as the
    # process it starts, and neither CurrentUser nor LocalMachine is touched.
    $relaunch = ConvertTo-DeltaCommandLine -Arguments @(
        '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass'
        '-File', $setupPath
        '-InstallRoot', $InstallRoot
    )

    # What the operator is told to type if the automatic path gives up. It has
    # to carry -InstallRoot for a non-default root, or the manual rerun resumes
    # against the wrong installation - the one thing the continuation exists to
    # prevent.
    $manualRerun = if ($InstallRoot -eq 'C:\DELTA') { '.\setup.ps1' }
                   else { ".\setup.ps1 -InstallRoot `"$InstallRoot`"" }

    # Single-quoted PowerShell literals in the generated script; a quote inside
    # a path is doubled rather than allowed to end the string early.
    $q = { param($text) $text -replace "'", "''" }

    # The title is cosmetic and the setter throws on a host with no console
    # window. Losing the resume over a caption would be absurd.
    $inner = @"
try { `$Host.UI.RawUI.WindowTitle = 'DELTA setup - continuing after restart' } catch { }
Remove-ItemProperty -LiteralPath '$(& $q $Script:DeltaRunOnceKey)' -Name '$(& $q $Script:DeltaRunOnceName)' -ErrorAction SilentlyContinue

`$scriptRoot = '$(& $q $ScriptRoot)'
`$relaunch   = '$(& $q $relaunch)'

Write-Host ''
Write-Host '  DELTA setup is continuing after the restart.'
Write-Host ''
Write-Host '  Windows is still finishing its sign-in, so this can take a short while.'
Write-Host '  Please wait - do not start setup.ps1 yourself while this window is open.'
Write-Host ''

function Show-DeltaManualRerun {
    Write-Host ''
    Write-Host '  To continue by hand:'
    Write-Host ''
    Write-Host '    1. Open Windows PowerShell as Administrator.'
    Write-Host '       Start > type "Windows PowerShell" > right-click it > Run as administrator.'
    Write-Host ''
    Write-Host '    2. Run these three lines:'
    Write-Host ''
    Write-Host ('         cd "' + `$scriptRoot + '"')
    Write-Host '         Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass'
    Write-Host '         $(& $q $manualRerun)'
    Write-Host ''
    Write-Host '  The Set-ExecutionPolicy line applies to that one PowerShell window only.'
    Write-Host '  It does not change the execution policy for your account or for this machine,'
    Write-Host '  and it is forgotten when the window closes. It is there because Windows blocks'
    Write-Host '  .ps1 files by default - the "running scripts is disabled on this system" error.'
    Write-Host ''
}

# RunOnce fires while the logon is still in progress. An elevation requested
# before the desktop can host the consent UI is cancelled by Windows itself,
# with no prompt shown and the same error code a declined prompt gives - so
# wait for the shell rather than guess at a delay. A session with no shell at
# all (a policy-replaced shell, a server with Explorer disabled) is not made
# to wait the full time for something that is never coming.
try {
    `$sessionId = (Get-Process -Id `$PID).SessionId
    `$deadline  = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt `$deadline) {
        `$shell = @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |
            Where-Object { `$_.SessionId -eq `$sessionId })
        if (`$shell.Count -gt 0) { break }
        Start-Sleep -Seconds 2
    }
}
catch { }
Start-Sleep -Seconds 3

# Behind a function so the two branches below can each be exercised by
# Test-RebootContinuation.ps1, which swaps this one definition out. The check
# is the same one Test-IsAdministrator makes; it is repeated rather than
# imported because this script runs with -NoProfile and no lib\ loaded.
function Test-DeltaContinuationElevated {
    `$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    `$principal = New-Object Security.Principal.WindowsPrincipal(`$identity)
    return `$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Nothing here asks the operator whether to continue. That decision was made
# before the machine went down, at the restart dialog, and asking again after
# the sign-in would be a second confirmation for one choice. The only thing
# that can still need a human after this point is the Windows UAC prompt.
`$started = `$false
if (Test-DeltaContinuationElevated) {
    # Already administrator, so there is nothing to elevate and no prompt to
    # show. Asking anyway would be a UAC prompt that changes nothing.
    Write-Host '  This session is already elevated, so no elevation prompt is needed.'
    try {
        Start-Process -FilePath 'powershell.exe' -WorkingDirectory `$scriptRoot -ArgumentList `$relaunch -ErrorAction Stop
        `$started = `$true
    }
    catch {
        Write-Host '  DELTA setup could not be started:' -ForegroundColor Yellow
        Write-Host "    `$(`$_.Exception.Message)"
    }
}
else {
    while (-not `$started) {
        Write-Host '  Approve the elevation prompt when it appears.'
        Write-Host ''
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory `$scriptRoot -ArgumentList `$relaunch -ErrorAction Stop
            `$started = `$true
        }
        catch {
            Write-Host '  DELTA setup was not started:' -ForegroundColor Yellow
            Write-Host "    `$(`$_.Exception.Message)"
            Write-Host ''
            Write-Host '  Windows reports a declined prompt and a prompt it cancelled itself the'
            Write-Host '  same way, and it does cancel its own while the desktop is still signing'
            Write-Host '  in. So this is worth one more try if you did not decline it.'
            Write-Host ''

            # Deliberate, and asked once per attempt. Never automatic: Windows
            # cannot tell this script whether the operator declined, so a retry
            # it did not ask for would be a UAC prompt that keeps coming back.
            `$answer = Read-Host '  Ask for elevation again? [Y/n]'
            if (`$answer -match '^\s*(n|no)\s*`$') { break }
        }
    }
}

if (`$started) {
    Write-Host ''
    Write-Host '  DELTA setup is running in the elevated window. This one can be closed.'
    Write-Host ''
    Start-Sleep -Seconds 5
}
else {
    Show-DeltaManualRerun
    Write-Host '  Press Enter to close this window.'
    `$null = Read-Host
}
"@

    # -EncodedCommand rather than a quoted one-liner: the registry value is
    # handed to CreateProcess as-is, and a path with spaces, quotes or an
    # ampersand in it has too many ways to be misread on the way through.
    #
    # The comments are stripped first. Base64 of UTF-16 is about 2.7 bytes of
    # command line per byte of script, and CreateProcess stops at 32767 - so
    # every explanatory line above costs nearly three times its length in a
    # budget that, if it were ever exceeded, would fail as a machine that
    # simply does not resume. The comments belong here, in the file a
    # maintainer actually reads; the encoded blob is machine-generated and
    # machine-consumed.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes((Compress-DeltaContinuationScript -Script $inner)))
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"

    # Refused rather than written long. A value CreateProcess will not accept
    # is a resume that silently never happens, and the caller already knows how
    # to report a continuation it could not register.
    if ($command.Length -ge 32000) {
        $result.Reason = "The continuation command would be $($command.Length) characters, which is beyond what Windows will run from RunOnce."
        return $result
    }

    try {
        if (-not (Test-Path -LiteralPath $Script:DeltaRunOnceKey)) {
            $null = New-Item -Path $Script:DeltaRunOnceKey -Force -ErrorAction Stop
        }
        $null = New-ItemProperty -LiteralPath $Script:DeltaRunOnceKey -Name $Script:DeltaRunOnceName `
            -Value $command -PropertyType String -Force -ErrorAction Stop
        $result.Succeeded = $true
    }
    catch {
        $result.Reason = $_.Exception.Message
    }

    return $result
}

$Script:DeltaRestartDialogCaption = 'DELTA Setup - Windows Restart Required'

function Get-DeltaRestartDialogText {
    <#
      What the operator has to know BEFORE the machine goes down, in one place
      so the dialog and its console fallback cannot say different things.

      It is longer than a question needs to be, deliberately. Everything an
      operator would otherwise have to discover after the restart - that they
      must sign back in as the same account, that the continuation is not
      instant, that waiting is the correct response to an empty screen, and
      that a UAC prompt has to be approved - is stated here, while there is
      still somebody at the keyboard to read it. After the restart the
      installer asks nothing and only Windows does: this text is the entire
      briefing for what follows.
    #>

    return (@(
        'Windows must restart before DELTA installation can continue.'
        ''
        'Save your work before continuing.'
        ''
        'Click OK to restart Windows now.'
        ''
        'After Windows restarts, sign back in using the same Windows'
        'account. DELTA setup will continue automatically.'
        ''
        'It may take a short while for the setup window to appear while'
        'Windows finishes starting. Please wait patiently and do not'
        'start setup.ps1 again.'
        ''
        'Windows may ask for administrator permission (UAC).'
        'Approve the UAC prompt to continue the installation.'
    ) -join [Environment]::NewLine)
}

function Request-DeltaWindowsRestart {
    <#
      Offers to restart Windows when a prerequisite has asked for one, and
      reports whether the operator agreed. It restarts nothing itself.

      That separation is the point. A restart is the most disruptive thing this
      installer can do to a machine, so the decision and the act are kept apart:
      this function only ever returns $true or $false, and Main performs the
      restart afterwards - once the transcript has been closed, so the log ends
      with a proper closing line instead of being cut off mid-write by a
      shutdown.

      The question is asked in a Windows dialog, because it is the one question
      in this installer whose answer depends on the operator having read a
      paragraph first. A [y/N] under half a screen of console text is answered
      without reading it; a modal dialog is not. What the dialog says is
      Get-DeltaRestartDialogText above, and it is the whole briefing for what
      happens after the sign-in - because after the sign-in this installer asks
      nothing at all.

      Three rules it cannot be talked out of:

        - Nothing restarts without an explicit approval: OK on the dialog, or
          a typed Y at the console fallback. Bare Enter is no there, as
          everywhere else in this installer, so an operator who hurried past
          the prompt keeps their machine up.
        - -NonInteractive never restarts, and never opens a window. An
          unattended run has nobody to judge whether this machine can go down
          right now, and rebooting a server on its own authority is not a
          decision an installer gets to make. It prints the manual
          instructions and exits with the same code.
        - Declining changes nothing about the outcome. The exit code is the
          reboot-required code either way; the restart is a convenience, not a
          different result.

      The dialog is best-effort and never a gate. A machine that cannot show
      one - Server Core, a session with no desktop - gets exactly the console
      question it got before dialogs existed here, with the same explanation
      printed above it, and the same typed-Y semantics. A GUI failure must
      never be the thing that stops an operator continuing.

      A confirmed restart registers the one-time logon continuation above, and
      that is the only thing that ever does. It is a convenience over the
      manual path, not a second one: it re-runs the same setup.ps1 with the
      same -InstallRoot, so the machine's actual state still decides what
      happens next and there is one resume story to get right.

      It is offered as an attempt, never as a promise. The continuation has to
      ask Windows for elevation, and a UAC prompt can be declined - so the
      manual commands are printed here as well, on both paths.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [bool]$AllowPrompt = $true
    )

    $rerun = { Write-DeltaManualRerunCommands -ScriptRoot $ScriptRoot -InstallRoot $InstallRoot }

    $declined = {
        Write-Detail ''
        Write-Detail 'Restart this machine, sign in, then start Windows PowerShell as Administrator'
        Write-Detail 'and run:'
        Write-Detail ''
        & $rerun
        Write-Detail ''
        Write-Detail 'Nothing else needs to be repeated - the installer picks up where it left off.'
    }

    if (-not $AllowPrompt) {
        Write-Detail ''
        Write-Detail 'This run is non-interactive, so Windows will not be restarted automatically.'
        & $declined
        return $false
    }

    Write-Detail ''
    Write-Detail 'Restarting closes every open application on this machine, so save your work first.'
    Write-Detail 'Nothing about the installation is lost either way.'
    Write-Host ''

    # $null is not an answer. It means no dialog could be shown on this
    # machine, so the operator was never asked - and the console asks instead,
    # exactly as it did before this dialog existed.
    $choice = Show-DeltaMessageDialog `
        -Text (Get-DeltaRestartDialogText) `
        -Caption $Script:DeltaRestartDialogCaption `
        -Buttons 'OKCancel' `
        -Icon 'Warning'

    if ($null -eq $choice) {
        # The same words the dialog would have shown, because the operator
        # needs them just as much on a machine that cannot draw a window.
        foreach ($line in ((Get-DeltaRestartDialogText) -split "`r?`n")) { Write-Detail $line }
        Write-Host ''
        $confirmed = Read-DeltaInlineConfirmation -Prompt 'Restart Windows now? [y/N]'
    }
    else {
        # Recorded because the transcript is read after the machine has been
        # down, when nothing on screen says which button was clicked.
        Write-Detail "Restart dialog answered: $choice."
        $confirmed = ($choice -eq 'ok')
    }

    if (-not $confirmed) {
        & $declined
        return $false
    }

    # Registered only here, after an explicit approval, and only for a prompted
    # run.
    $continuation = Register-DeltaLogonContinuation -ScriptRoot $ScriptRoot -InstallRoot $InstallRoot

    Write-Detail ''
    Write-Detail 'Windows will restart in a few seconds.'
    if ($continuation.Succeeded) {
        Write-Detail ''
        Write-Detail 'DELTA setup will TRY to continue by itself the next time you sign in to this'
        Write-Detail 'machine as this user. It is not instant - Windows has to finish signing in'
        Write-Detail 'first - so give it a short while before assuming nothing is happening, and do'
        Write-Detail 'not start setup.ps1 yourself in the meantime.'
        Write-Detail 'Windows may ask for administrator permission (UAC); approve it, and the'
        Write-Detail 'installation picks up from the state it finds.'
        Write-Detail 'It is a one-time arrangement: it runs once and removes itself, whatever happens.'
        Write-Detail ''
        # Deliberately not promised as automatic. The elevation prompt can be
        # declined, and Windows itself sometimes cancels it while the desktop
        # is still signing in - so the window offers to ask again and prints
        # these same commands if it gives up. An operator who was told this
        # was automatic reads that as a broken installer.
        Write-Detail 'If it does not manage it, or you would rather do it yourself, start Windows'
        Write-Detail 'PowerShell as Administrator and run:'
        Write-Detail ''
        & $rerun
    }
    else {
        # Never claim an automatic continuation that was not registered.
        Write-DeltaWarning "Automatic continuation could not be registered: $($continuation.Reason)"
        Write-Detail 'The restart still happens. After signing in, start Windows PowerShell as'
        Write-Detail 'Administrator and run:'
        Write-Detail ''
        & $rerun
    }
    return $true
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

# Set only by an explicit Y at the restart prompt. Acted on after the finally
# block, never inside the try: a shutdown started while the transcript is still
# open truncates the log the operator will want to read after the machine comes
# back.
$Script:DeltaRestartConfirmed = $false

# Terminal animation is for somebody who is watching. An unattended run is by
# definition one nobody is, and its output is usually being captured - so the
# activity indicator falls back to a single static line per operation. The
# console probe would catch a redirected run on its own; this catches the run
# that is unattended on a real console, which the probe cannot see.
if ($NonInteractive) {
    Set-DeltaActivityMode -Mode 'off'
}

try {
    $logPath = Start-DeltaLog -Directory $LogDirectory

    # The banner no longer states the installation root. On an interactive first
    # install it is not decided yet, and a banner that announced C:\DELTA before
    # the operator had been asked would be stating the very thing the question
    # below exists to settle. Show-DeltaInstallRootChoice states it instead, on
    # every path, once it is actually known.
    Show-Section -Title 'DELTA Windows Docker Installer'

    if ($logPath) {
        Write-Detail "Transcript: $logPath"
        Write-Detail ''
    }

    if (-not (Test-DeltaElevationRequirement)) {
        $exitCode = $Script:DeltaExitNotElevated
    }
    else {
        # Resolved here, and here only: after elevation - the writability probe
        # and everything under the root needs it - and before the first thing
        # that reads the root. Everything downstream then sees one value. That
        # includes Show-DeltaInstallationState, which picks install vs manage
        # mode, and the -InstallRoot that Register-DeltaLogonContinuation is
        # given for a post-restart resume: the continuation carries the chosen
        # root across the reboot, and comes back with it supplied explicitly,
        # which is what stops it asking the question a second time.
        $rootChoice = Resolve-DeltaInstallRoot `
            -DefaultRoot $InstallRoot `
            -WasSupplied:($PSBoundParameters.ContainsKey('InstallRoot')) `
            -AllowPrompt (-not $NonInteractive)

        Show-DeltaInstallRootChoice -Choice $rootChoice
        $InstallRoot = $rootChoice.Path

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

                # Downloading Docker Desktop is now the default, so
                # -AllowDockerDownload asks for what already happens and is
                # accepted only so existing command lines keep working.
                # -NoDockerDownload is the switch that changes anything, and it
                # wins if somebody supplies both rather than being silently
                # overruled by the one that no longer does anything.
                $allowDockerDownload = -not $NoDockerDownload
                if ($AllowDockerDownload -and $NoDockerDownload) {
                    Write-DeltaWarning '-AllowDockerDownload and -NoDockerDownload were both supplied. -NoDockerDownload wins: Docker Desktop will not be downloaded.'
                }

                $runtime = Invoke-DeltaRuntimeStage `
                    -InstallRoot $InstallRoot `
                    -ScriptRoot $Script:DeltaScriptRoot `
                    -DockerInstallerPath $DockerInstallerPath `
                    -AllowDownload $allowDockerDownload

                $exitCode = Show-DeltaRuntimeOutcome -Runtime $runtime -State $state -InstallRoot $InstallRoot

                if ($runtime.Outcome -eq 'reboot-required') {
                    # Only the answer is collected here. The restart happens
                    # after the finally block below, so the transcript is closed
                    # cleanly before the machine goes down.
                    $Script:DeltaRestartConfirmed = Request-DeltaWindowsRestart `
                        -ScriptRoot $Script:DeltaScriptRoot `
                        -InstallRoot $InstallRoot `
                        -AllowPrompt (-not $NonInteractive)
                }

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

                    # SMTP is offered only once DELTA is installed, published
                    # and verified - and it is offered BEFORE the completion
                    # summary so that the summary, and the administrator
                    # credential shown once inside it, stay the last thing on
                    # screen. It cannot change the installation's verdict:
                    # $exitCode is decided by Show-DeltaStackOutcome below,
                    # from $stack, which this does not touch.
                    if ($stack.Outcome -eq 'ready') {
                        $null = Invoke-DeltaPostInstallSmtpOffer `
                            -InstallRoot $InstallRoot `
                            -Configuration $stack.Configuration `
                            -AllowPrompt (-not $NonInteractive)
                    }

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

# The transcript is closed and every stage has reported. The only thing left is
# the restart the operator asked for at the prompt above.
#
# The exit code does not change: a confirmed restart is still the
# reboot-required outcome, and if the restart cannot be started - a policy, a
# blocking shutdown handler - the operator is told and left with a machine that
# is up and an exit code that says exactly what it said before.
if ($Script:DeltaRestartConfirmed) {
    try {
        Restart-Computer -Force -ErrorAction Stop
    }
    catch {
        # The restart did not happen, so the continuation registered for it must
        # not be left behind to fire at some unrelated logon later.
        $null = Unregister-DeltaLogonContinuation
        Write-Host ''
        Write-DeltaFailure "Windows could not be restarted: $($_.Exception.Message)"
        Write-Detail 'The automatic continuation has been removed, so nothing will run unexpectedly.'
        Write-Detail 'Restart this machine yourself, sign in, and run setup.ps1 again.'
        Write-Detail 'Nothing about the installation changed - it resumes from where it stopped.'
    }
}

exit $exitCode
