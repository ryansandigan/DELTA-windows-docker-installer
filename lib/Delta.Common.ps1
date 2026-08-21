# =============================================================================
# Delta.Common.ps1 - console output, redacting log, elevation, validation
#
# Dot-sourced by setup.ps1 (and by any tools\ script that needs the same
# primitives). Defines no top-level side effects other than its own script
# variables, so it is safe to load more than once.
#
# Assessment references: A§21 (logging), A§24 (secret redaction), A§9.5
# (install-root constraints).
#
# This file - like every .ps1 in this project - is stored as UTF-8 *with* a
# BOM. Windows PowerShell 5.1 decodes a BOM-less script as the system ANSI
# code page, which turns any non-ASCII character in it into mojibake at run
# time. The BOM is what keeps the source and the console output identical.
# (.env and the state file are the opposite case: no BOM, ever - see
# Delta.Config.ps1.)
# =============================================================================

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$Script:DeltaBannerWidth = 72

# Exit codes. setup.ps1 owns exactly one top-level try/catch and is the only
# place that calls exit; functions raise terminating errors via Stop-Setup.
$Script:DeltaExitSuccess            = 0
$Script:DeltaExitFailure            = 1
$Script:DeltaExitNotElevated        = 2
$Script:DeltaExitInvalidInstallRoot = 3
# Phase 2 outcomes. A blocked prerequisite and a required-but-declined
# disclosure are distinct from a crash, and "restart Windows and run this
# again" is not a failure at all - it is the documented next step, so it gets
# its own code rather than being flattened into 1.
$Script:DeltaExitPrerequisiteFailed = 4
$Script:DeltaExitRebootRequired     = 5
$Script:DeltaExitOperatorDeclined   = 6
# Phase 3 outcomes. Migration verification gets its own code because it is the
# highest-consequence stop in the product: it means the schema may be
# half-migrated, and the response is a restore, not a retry.
$Script:DeltaExitStackFailed        = 7
$Script:DeltaExitMigrationFailed    = 8
# The install stopped before publishing DELTA because the seeded administrator
# credential could not be replaced. Distinct from a generic stack failure: the
# stack is fine, the security bootstrap is not, and nothing is externally
# reachable.
$Script:DeltaExitSecurityBootstrapFailed = 9

# UTF-8 *without* a byte-order mark. Every file this installer writes that is
# later read by a Linux container (.env above all) must not carry a BOM -
# Compose passes the first key through with the BOM glued to its name.
$Script:DeltaUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------------------
# Secret redaction (A§24)
#
# Redaction is a property of the logger, not of the call sites: every console
# helper below routes its message through Protect-DeltaSecretText on the way
# to the log file. A call site cannot forget to redact, because a call site
# never redacts.
#
# The console is deliberately NOT redacted - the completion summary has to be
# able to show a generated credential to the operator exactly once (A§24) -
# so the split is: full text to the screen, redacted text to disk.
# ---------------------------------------------------------------------------

$Script:DeltaRedactionMarker = '<redacted>'

# DATABASE_URL is on this list because it embeds the database password and is
# the one that gets forgotten (A§24). DELTA_DB_PASSWORD is on it because
# A§7.4 defines it as a separate key from day one.
$Script:DeltaSecretKeyNames = @(
    'POSTGRES_PASSWORD'
    'DELTA_DB_PASSWORD'
    'SESSION_SECRET'
    'SMTP_PASS'
    'DATABASE_URL'
    'DELTA_ADMIN_NEW_PASSWORD'
    'PGPASSWORD'
)

# KEY=value, KEY: value, or KEY value - with or without quotes, and with the
# separator optional so that a bare mention of the key name is caught too. The
# whole match is replaced, key name included, for two reasons: a log line that
# still named the key would defeat the "no secret key names in a transcript"
# check the acceptance gate greps for, and a .env line malformed enough to
# lose its '=' (which the installer echoes back so the operator can fix it)
# still carries a real secret on the right-hand side.
$Script:DeltaSecretAssignmentPattern =
    '(?i)\b(' +
    (($Script:DeltaSecretKeyNames | ForEach-Object { [regex]::Escape($_) }) -join '|') +
    ')\b(\s*[:=]\s*|\s+)?("[^"]*"|''[^'']*''|\S*)'

# Any PostgreSQL connection URI, however it reached the text - a psql error,
# a compose warning, an operator-pasted value. It always carries credentials.
$Script:DeltaConnectionStringPattern = '(?i)\bpostgres(?:ql)?://\S*'

# Literal secret values registered at generation time, masked wherever they
# subsequently appear. This is what catches a secret that arrives inside
# output this installer did not format itself.
$Script:DeltaRegisteredSecrets = New-Object System.Collections.Generic.List[string]

function Register-DeltaSecretValue {
    <#
      Records a literal value that must never reach a transcript. Call this
      immediately after generating or reading a secret, before it is used
      anywhere else.

      Values shorter than 8 characters are ignored: masking a short literal
      would corrupt unrelated text (a 4-character value would blank out every
      accidental occurrence of those characters in every log line), and a
      secret this installer generates is never that short.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if (-not $Value -or $Value.Length -lt 8) {
        return
    }
    if (-not $Script:DeltaRegisteredSecrets.Contains($Value)) {
        $null = $Script:DeltaRegisteredSecrets.Add($Value)
    }
}

function Protect-DeltaSecretText {
    <#
      Returns $Text with every known secret shape replaced by the redaction
      marker: secret KEY=value assignments, PostgreSQL connection URIs, and
      any literal registered through Register-DeltaSecretValue.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $result = [regex]::Replace($Text, $Script:DeltaSecretAssignmentPattern, $Script:DeltaRedactionMarker)
    $result = [regex]::Replace($result, $Script:DeltaConnectionStringPattern, $Script:DeltaRedactionMarker)

    foreach ($secret in $Script:DeltaRegisteredSecrets) {
        $result = $result.Replace($secret, $Script:DeltaRedactionMarker)
    }

    return $result
}

# ---------------------------------------------------------------------------
# Transcript log
#
# Deliberately not Start-Transcript: a PowerShell transcript captures raw
# console output verbatim, which is precisely what A§24 forbids for the lines
# that carry credentials. An own-format log is the only way redaction can be
# a property of the writer.
# ---------------------------------------------------------------------------

$Script:DeltaLogPath = $null
$Script:DeltaLogWriteFailureReported = $false

# Bounds for the appended startup log only. The per-run transcripts are one
# file per run and are the operator's to keep or delete.
$Script:DeltaAppendLogMaxBytes  = 1MB
$Script:DeltaAppendLogKeepBytes = 256KB

function Limit-DeltaLogFile {
    <#
      Trims an appended log to its most recent lines once it passes the size
      cap. Best effort: a log that cannot be trimmed is left exactly as it is
      rather than being lost.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
        $file = Get-Item -LiteralPath $Path
        if ($file.Length -le $Script:DeltaAppendLogMaxBytes) { return }

        $lines = [System.IO.File]::ReadAllLines($Path)
        $kept = New-Object 'System.Collections.Generic.List[string]'
        $bytes = 0
        for ($i = $lines.Length - 1; $i -ge 0; $i--) {
            $bytes += $lines[$i].Length + 2
            if ($bytes -gt $Script:DeltaAppendLogKeepBytes) { break }
            $kept.Insert(0, $lines[$i])
        }
        $kept.Insert(0, "--- earlier entries trimmed on $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) ---")
        [System.IO.File]::WriteAllLines($Path, $kept.ToArray(), $Script:DeltaUtf8NoBom)
    }
    catch { }
}

function Start-DeltaLog {
    <#
      Opens the installer transcript in $Directory and returns its full path.
      The directory is created if it does not exist; a failure to create it
      is reported once and then downgraded to "no log this run" - an
      installation must not be blocked by a logging problem.

      -Append opens one fixed file, "<Name>.log", and adds to it instead of
      creating a new timestamped file per run. That is what the unattended
      startup path needs: after a reboot the operator has to be able to read
      one file and see the history of boots, not hunt through a directory of
      per-boot transcripts. Because that file is written by something nobody
      watches, it is trimmed to the most recent $Script:DeltaAppendLogKeepBytes
      when it grows past $Script:DeltaAppendLogMaxBytes - the alternative is a
      log that grows without limit on a machine that reboots for patching.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$Name = 'setup',
        [switch]$Append
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            $null = New-Item -ItemType Directory -Path $Directory -Force
        }
        if ($Append) {
            $Script:DeltaLogPath = Join-Path -Path $Directory -ChildPath "$Name.log"
            Limit-DeltaLogFile -Path $Script:DeltaLogPath
            if (-not (Test-Path -LiteralPath $Script:DeltaLogPath -PathType Leaf)) {
                [System.IO.File]::WriteAllText($Script:DeltaLogPath, '', $Script:DeltaUtf8NoBom)
            }
            [System.IO.File]::AppendAllText($Script:DeltaLogPath, [Environment]::NewLine, $Script:DeltaUtf8NoBom)
        }
        else {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $Script:DeltaLogPath = Join-Path -Path $Directory -ChildPath "$Name-$stamp.log"
            [System.IO.File]::WriteAllText($Script:DeltaLogPath, '', $Script:DeltaUtf8NoBom)
        }
    }
    catch {
        $Script:DeltaLogPath = $null
        Write-Host "    Warning: could not open a log file in ${Directory}: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }

    Write-DeltaLogLine -Message "DELTA Windows Docker Installer - transcript started" -Level 'INFO'
    Write-DeltaLogLine -Message "PowerShell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.VersionString)" -Level 'INFO'
    Write-DeltaLogLine -Message "User $([Environment]::UserDomainName)\$([Environment]::UserName), elevated=$(Test-IsAdministrator)" -Level 'INFO'
    return $Script:DeltaLogPath
}

function Write-DeltaLogLine {
    <#
      Appends one redacted, timestamped line to the transcript. A no-op when
      no log is open. Never throws - a logging failure is reported once and
      then tolerated.
    #>
    param(
        [AllowEmptyString()][string]$Message,
        [string]$Level = 'INFO'
    )

    if (-not $Script:DeltaLogPath) {
        return
    }

    $safe = Protect-DeltaSecretText -Text $Message
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = '{0} [{1}] {2}{3}' -f $timestamp, $Level.PadRight(7), $safe, [Environment]::NewLine

    try {
        [System.IO.File]::AppendAllText($Script:DeltaLogPath, $line, $Script:DeltaUtf8NoBom)
    }
    catch {
        if (-not $Script:DeltaLogWriteFailureReported) {
            $Script:DeltaLogWriteFailureReported = $true
            Write-Host "    Warning: writing to the transcript failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Stop-DeltaLog {
    <#
      Writes the closing line and releases the log path. Reports where the
      transcript was written so the operator can find it.
    #>
    param([int]$ExitCode = 0)

    if (-not $Script:DeltaLogPath) {
        return
    }
    Write-DeltaLogLine -Message "Transcript finished, exit code $ExitCode" -Level 'INFO'
    $Script:DeltaLogPath = $null
}

function Get-DeltaLogPath {
    return $Script:DeltaLogPath
}

# ---------------------------------------------------------------------------
# Console output vocabulary (reused from the reference installer, A§23)
# ---------------------------------------------------------------------------

function Show-Section {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle
    )
    $rule = '=' * $Script:DeltaBannerWidth
    Write-Host ''
    Write-Host $rule
    Write-Host $Title
    if ($Subtitle) {
        Write-Host $Subtitle
    }
    Write-Host $rule
    Write-Host ''

    Write-DeltaLogLine -Message "== $Title$(if ($Subtitle) { " - $Subtitle" })" -Level 'SECTION'
}

function Write-Step {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
    Write-DeltaLogLine -Message $Message -Level 'STEP'
}

function Write-Detail {
    param([AllowEmptyString()][string]$Message)
    Write-Host "    $Message"
    Write-DeltaLogLine -Message $Message -Level 'DETAIL'
}

function Write-Success {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Write-Host $Message -ForegroundColor Green
    Write-DeltaLogLine -Message $Message -Level 'SUCCESS'
}

function Write-DeltaWarning {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Write-Host "    $Message" -ForegroundColor Yellow
    Write-DeltaLogLine -Message $Message -Level 'WARNING'
}

function Write-DeltaFailure {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Write-Host $Message -ForegroundColor Red
    Write-DeltaLogLine -Message $Message -Level 'ERROR'
}

function Read-DeltaYesNoConfirmation {
    <#
      The shared shape behind every Y/N confirmation in this installer,
      adapted from the reference installer's function of the same name: a
      rule, the caller-supplied body, a '[y/N]' prompt, a closing rule.

      Bare Enter - or anything other than Y/y - always means No. Every
      confirmation in this project follows that "blank means the safe choice"
      convention, which is what makes a disclosure the operator did not read
      fail closed rather than open.

      $Body is a scriptblock that writes the question-specific text. It is
      invoked with & so it can still read the local variables of the scope it
      was written in.
    #>
    param([Parameter(Mandatory)][scriptblock]$Body)

    $rule = '-' * $Script:DeltaBannerWidth
    Write-Host ''
    Write-Host $rule
    Write-Host ''
    & $Body
    Write-Host ''
    $choice = Read-Host -Prompt '[y/N]'
    Write-Host ''
    Write-Host $rule

    $confirmed = ($choice -and $choice.Trim() -in @('Y', 'y'))
    Write-DeltaLogLine -Message "Confirmation prompt answered: $(if ($confirmed) { 'yes' } else { 'no' })" -Level 'DETAIL'
    return $confirmed
}

function ConvertTo-DeltaPlainText {
    <#
      SecureString to plain text, at the point it is genuinely needed. Uses
      NetworkCredential rather than manual Marshal calls - the standard,
      PowerShell 5.1-compatible idiom, adapted from the reference installer.

      Lives here, in the file every entry point loads first, because callers
      exist at every layer - the administrator reset, the .env generator, the
      completion summary. Defining it in a late-loading file once made an
      earlier-loading caller resolve it to nothing and silently substitute an
      empty string, which is the kind of failure a credential helper must not
      be able to have.
    #>
    param([Parameter(Mandatory)][SecureString]$SecureString)
    return [System.Net.NetworkCredential]::new('', $SecureString).Password
}

function Stop-Setup {
    <#
      Raises a terminating error with an operator-readable message. setup.ps1's
      single top-level catch turns this into the error banner and the process
      exit code, so functions never call exit themselves.
    #>
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

function Test-DeltaIntegerInRange {
    <#
      Strict integer validation for operator input: the whole string must
      parse as an integer in the invariant culture (so "8080 " is accepted
      after trimming but "8080x", "0x50" and "" are not) and fall inside
      [$Minimum, $Maximum]. Returns $true/$false; never throws.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][int]$Minimum,
        [Parameter(Mandatory)][int]$Maximum
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $parsed = 0
    $styles = [System.Globalization.NumberStyles]::None
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [int]::TryParse($Value.Trim(), $styles, $culture, [ref]$parsed)) {
        return $false
    }

    return ($parsed -ge $Minimum -and $parsed -le $Maximum)
}

function Test-DeltaInstallRootCandidate {
    <#
      Validates a candidate installation root against the A§9.5 constraints:
      a rooted local path on a fixed volume, no UNC path, no mapped or
      removable drive, and short enough to leave room for the deepest file
      the installation creates under it.

      Returns an object with IsValid and, when it is not, a Reason naming the
      path and the specific constraint it failed. Never throws - the caller
      decides whether an invalid path is fatal or a re-prompt.

      -TestWritable additionally probes an existing directory by creating and
      deleting a temporary file, which is the only reliable writability test
      on Windows (an ACL read cannot account for share, EFS or policy
      restrictions). It is a no-op when the directory does not exist yet.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [switch]$TestWritable
    )

    $result = [PSCustomObject]@{
        Path    = $Path
        IsValid = $false
        Reason  = $null
        Exists  = $false
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.Reason = 'No installation root was supplied.'
        return $result
    }

    $invalidChars = [System.IO.Path]::GetInvalidPathChars()
    if ($Path.IndexOfAny($invalidChars) -ge 0) {
        $result.Reason = "The path '$Path' contains characters that are not valid in a Windows path."
        return $result
    }

    if ($Path.StartsWith('\\')) {
        $result.Reason = "The path '$Path' is a UNC path. The installation root must be a local fixed volume - uploads, logs, certificates and backups live under it."
        return $result
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $result.Reason = "The path '$Path' is not absolute. Supply a full path such as C:\DELTA."
        return $result
    }

    if ($Path.Length -gt 120) {
        $result.Reason = "The path '$Path' is $($Path.Length) characters long. Use a short root such as C:\DELTA so container bind-mount paths stay well inside the Windows path limit."
        return $result
    }

    $qualifier = $null
    try {
        $qualifier = [System.IO.Path]::GetPathRoot($Path)
    }
    catch {
        $result.Reason = "The path '$Path' could not be parsed: $($_.Exception.Message)"
        return $result
    }

    try {
        $drive = New-Object System.IO.DriveInfo($qualifier)
        if (-not $drive.IsReady) {
            $result.Reason = "The volume $qualifier is not ready."
            return $result
        }
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
            $result.Reason = "The volume $qualifier is a $($drive.DriveType) drive. The installation root must be on a local fixed volume - a mapped or removable drive is not available to the Docker bind mounts at every point the stack needs it."
            return $result
        }
    }
    catch {
        $result.Reason = "The volume $qualifier could not be inspected: $($_.Exception.Message)"
        return $result
    }

    $result.Exists = Test-Path -LiteralPath $Path -PathType Container

    if ($TestWritable -and $result.Exists) {
        $probe = Join-Path -Path $Path -ChildPath ".delta-write-probe-$([guid]::NewGuid().ToString('N'))"
        try {
            [System.IO.File]::WriteAllText($probe, '', $Script:DeltaUtf8NoBom)
        }
        catch {
            $result.Reason = "The directory '$Path' is not writable by this account: $($_.Exception.Message)"
            return $result
        }
        finally {
            if (Test-Path -LiteralPath $probe -PathType Leaf) {
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $result.IsValid = $true
    return $result
}
