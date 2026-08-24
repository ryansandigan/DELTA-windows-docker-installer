# =============================================================================
# Delta.Config.ps1 - .env read/write, install-state file, secret generation,
#                    installation-state classification
#
# Dot-source Delta.Common.ps1 first: this file uses its console helpers, its
# UTF-8-without-BOM encoder and Stop-Setup.
#
# Assessment references: A§7.4/A§7.5 (credentials), A§17.2 (state file),
# A§24 (.env ACL), A§28 (state model and rerun invariants).
# =============================================================================

$Script:DeltaEnvFileName          = '.env'
$Script:DeltaComposeFileName      = 'docker-compose.yml'
$Script:DeltaInstallStateFileName = '.delta-install.json'
$Script:DeltaInstallStateSchemaVersion = 1

# The three states A§17.2 allows inside the state file itself. The richer
# classification A§28 describes is derived from evidence by
# Get-DeltaInstallationState below - the file records only what was written.
$Script:DeltaInstallStateValues = @('none', 'partial', 'installed')

# ---------------------------------------------------------------------------
# .env reading
# ---------------------------------------------------------------------------

function Read-DeltaEnvFile {
    <#
      Parses a .env-style file and returns everything a caller (or the writer
      below) needs: the raw lines in order, the parsed key/value pairs in
      order, the newline style in use, and any line that could not be parsed.

      Parsing rules follow the reference installer's Get-EnvFileValue exactly
      - the two installers read the same file format:
        - blank lines and whole-line '#' comments are ignored,
        - keys match case-insensitively,
        - a value wrapped in matching single or double quotes has the quotes
          stripped,
        - a trailing inline comment is excluded: after the closing quote for a
          quoted value, from the first whitespace-preceded '#' otherwise (so a
          '#' inside quotes or glued to the value survives, which is what a
          password or a URL fragment needs),
        - the first occurrence of a duplicated key wins.

      Never throws for a missing file - "absent" is a normal outcome the
      caller has to tell apart from "present but invalid".
    #>
    param([Parameter(Mandatory)][string]$Path)

    $result = [PSCustomObject]@{
        Path      = $Path
        Exists    = $false
        Lines     = @()
        Entries   = [ordered]@{}
        Malformed = @()
        Newline   = [Environment]::NewLine
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $result
    }

    $result.Exists = $true
    $raw = [System.IO.File]::ReadAllText($Path)
    if ($raw -notmatch "`r`n" -and $raw -match "`n") {
        $result.Newline = "`n"
    }
    else {
        $result.Newline = "`r`n"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($raw -split "`r`n|`n|`r")) {
        $null = $lines.Add($line)
    }
    # A trailing newline yields one empty trailing element; the writer always
    # emits a trailing newline, so drop it rather than round-tripping a blank
    # line into the file on every write.
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines.RemoveAt($lines.Count - 1)
    }
    $result.Lines = $lines.ToArray()

    $malformed = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $result.Lines.Count; $i++) {
        $parsed = ConvertFrom-DeltaEnvLine -Line $result.Lines[$i]
        if (-not $parsed) {
            continue
        }
        if ($parsed.IsMalformed) {
            $null = $malformed.Add([PSCustomObject]@{
                LineNumber = $i + 1
                Line       = $result.Lines[$i]
                Reason     = $parsed.Reason
            })
            continue
        }
        if ($result.Entries.Contains($parsed.Key)) {
            $null = $malformed.Add([PSCustomObject]@{
                LineNumber = $i + 1
                Line       = $result.Lines[$i]
                Reason     = "Duplicate key '$($parsed.Key)'. The first occurrence is the one in effect."
            })
            continue
        }
        $result.Entries[$parsed.Key] = $parsed.Value
    }
    $result.Malformed = $malformed.ToArray()

    return $result
}

function ConvertFrom-DeltaEnvLine {
    <#
      Parses one physical line. Returns $null for a blank line or a whole-line
      comment, an object with IsMalformed = $true for a line that is neither a
      comment nor a KEY=value, and otherwise Key, Value and the trailing
      inline Comment (kept verbatim so the writer can preserve it).
    #>
    param([AllowEmptyString()][string]$Line)

    $trimmed = $Line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#')) {
        return $null
    }

    $separatorIndex = $trimmed.IndexOf('=')
    if ($separatorIndex -lt 0) {
        return [PSCustomObject]@{
            IsMalformed = $true
            Reason      = 'Line is neither a comment nor a KEY=value assignment.'
            Key         = $null
            Value       = $null
            Comment     = ''
        }
    }

    $key = $trimmed.Substring(0, $separatorIndex).Trim()
    if (-not $key -or $key -match '\s') {
        return [PSCustomObject]@{
            IsMalformed = $true
            Reason      = "Invalid key '$key' - a key must be present and contain no whitespace."
            Key         = $null
            Value       = $null
            Comment     = ''
        }
    }

    $rest = $trimmed.Substring($separatorIndex + 1).Trim()
    $value = $rest
    $comment = ''

    if ($rest.Length -ge 2 -and ($rest[0] -eq '"' -or $rest[0] -eq "'")) {
        $closingQuoteIndex = $rest.IndexOf($rest[0], 1)
        if ($closingQuoteIndex -gt 0) {
            $value = $rest.Substring(1, $closingQuoteIndex - 1)
            $comment = $rest.Substring($closingQuoteIndex + 1)
        }
        else {
            # Unterminated quote: returned as-is, exactly as the reference
            # installer's strip-only-matching-outer-quotes logic did.
            $value = $rest
        }
    }
    else {
        $commentMatch = [regex]::Match($rest, '\s#')
        if ($commentMatch.Success) {
            $value = $rest.Substring(0, $commentMatch.Index).TrimEnd()
            $comment = $rest.Substring($commentMatch.Index)
        }
    }

    return [PSCustomObject]@{
        IsMalformed = $false
        Reason      = $null
        Key         = $key
        Value       = $value
        Comment     = $comment
    }
}

function Get-DeltaEnvValue {
    <#
      Reads a single key. Returns $null both when the file does not exist and
      when the key is not set in it - two normal outcomes a caller often needs
      to tell apart from "present but invalid" for itself.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )

    $envFile = Read-DeltaEnvFile -Path $Path
    if (-not $envFile.Exists -or -not $envFile.Entries.Contains($Key)) {
        return $null
    }
    return $envFile.Entries[$Key]
}

# ---------------------------------------------------------------------------
# .env writing
#
# The reference installer has no .env writer, so this is new code. Its one
# hard requirement is that an operator's hand edits survive: comments, key
# order, blank lines and inline comments are all preserved, an existing key
# is updated in place, and a new key is appended.
# ---------------------------------------------------------------------------

function Format-DeltaEnvValue {
    <#
      Quotes a value for .env. Double quotes by default (the shape the
      reference installer writes and .env.example ships); single quotes when
      the value itself contains a double quote.

      A value containing both quote characters is rejected rather than
      escaped: .env has no escaping convention shared by every consumer of
      this file (PowerShell here, Compose's env_file parser there), and a
      silently mangled password is worse than a refusal the operator can act
      on.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) {
        $Value = ''
    }
    if ($Value -match "[`r`n]") {
        Stop-Setup 'A .env value cannot contain a line break.'
    }

    $hasDouble = $Value.Contains('"')
    $hasSingle = $Value.Contains("'")

    if ($hasDouble -and $hasSingle) {
        Stop-Setup 'A .env value cannot contain both a single and a double quote character - there is no escaping convention every consumer of this file agrees on.'
    }
    if ($hasDouble) {
        return "'$Value'"
    }
    return """$Value"""
}

function Set-DeltaEnvValues {
    <#
      Writes one or more KEY=value pairs into $Path, preserving comments,
      blank lines, key order and inline comments. Keys already present are
      updated in place; keys that are not are appended in the order supplied.

      The write is atomic - a temporary file in the same directory, then a
      replace - so a failure part-way through can never leave a half-written
      .env holding the credentials the running stack depends on. The
      restrictive ACL is re-applied after every write, because the replace
      creates a new file that would otherwise inherit the directory's ACL
      (A§24).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [switch]$NoProtect
    )

    $envFile = Read-DeltaEnvFile -Path $Path
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $envFile.Lines) {
        $null = $lines.Add($line)
    }

    $pending = [ordered]@{}
    foreach ($key in $Values.Keys) {
        $pending[[string]$key] = [string]$Values[$key]
    }

    $written = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $parsed = ConvertFrom-DeltaEnvLine -Line $lines[$i]
        if (-not $parsed -or $parsed.IsMalformed) {
            # Malformed lines are left exactly as they are. This writer never
            # silently rewrites something it did not understand.
            continue
        }
        if (-not $pending.Contains($parsed.Key) -or $written.Contains($parsed.Key)) {
            continue
        }
        $formatted = Format-DeltaEnvValue -Value $pending[$parsed.Key]
        $suffix = ''
        if ($parsed.Comment) {
            $suffix = $parsed.Comment
            if (-not $suffix.StartsWith(' ') -and -not $suffix.StartsWith("`t")) {
                $suffix = ' ' + $suffix
            }
        }
        $lines[$i] = "$($parsed.Key)=$formatted$suffix"
        $null = $written.Add($parsed.Key)
    }

    foreach ($key in $pending.Keys) {
        if ($written.Contains($key)) {
            continue
        }
        $formatted = Format-DeltaEnvValue -Value $pending[$key]
        $null = $lines.Add("$key=$formatted")
        $null = $written.Add($key)
    }

    $newline = $envFile.Newline
    $content = ($lines -join $newline) + $newline

    Write-DeltaFileAtomic -Path $Path -Content $content

    if (-not $NoProtect) {
        Protect-DeltaSecretFile -Path $Path
    }
}

function Set-DeltaEnvValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [switch]$NoProtect
    )

    $values = [ordered]@{}
    $values[$Key] = $Value
    Set-DeltaEnvValues -Path $Path -Values $values -NoProtect:$NoProtect
}

function Write-DeltaFileAtomic {
    <#
      Writes $Content to $Path through a temporary file in the same directory,
      then replaces the target. UTF-8 without a BOM throughout: .env is read
      by Compose inside a Linux container, and a BOM would arrive glued to the
      first key's name.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        Stop-Setup "Cannot write '$Path': the directory '$directory' does not exist."
    }

    $temporaryPath = Join-Path -Path $directory -ChildPath ".delta-write-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, $Script:DeltaUtf8NoBom)

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # File.Replace is the atomic same-volume swap; it keeps the
            # destination's identity rather than deleting and recreating it.
            # [NullString]::Value, not $null: PowerShell 5.1 binds a bare
            # $null to the string overload as an empty path and File.Replace
            # rejects it with "The path is not of a legal form".
            [System.IO.File]::Replace($temporaryPath, $Path, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    catch {
        Stop-Setup "Failed to write '$Path': $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Backup-DeltaEnvFile {
    <#
      Timestamped copy of an existing .env before it is rewritten, hardened
      the same way the original is - a backup sitting next to a locked-down
      .env with an inherited ACL would defeat the hardening entirely.
      A no-op when there is nothing to protect.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $backupPath = "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    Protect-DeltaSecretFile -Path $backupPath
    Write-Detail "Existing .env backed up to: $backupPath"
    return $backupPath
}

function Get-DeltaDockerFileReadSid {
    <#
      The SID of the Windows account Docker Desktop reads host files as, in the
      *S-1-... form icacls takes, or $null when there is nothing worth granting.

      Why an account has to be named at all. Measured on Docker Desktop's WSL2
      backend: a Windows drive reaches the docker-desktop distro over 9p, as

          C:\ on /mnt/host/c type 9p (rw,...,aname=drvfs;path=C:\;...,metadata,...)

      and the 9p SERVER sits on the Windows side, inside wsl.exe / wslhost.exe,
      owned by the logged-on user - not SYSTEM, and holding no ACL-bypass
      privilege. With `metadata` on that mount WSL synthesises each file's Linux
      mode from that account's EFFECTIVE Windows access. Measured, same host,
      same bind mount, one file per ACL:

          inherited                              -> 777
          Administrators:(F) SYSTEM:(F)          -> 777   (see below)
          SYSTEM:(F) only                        -> 000
          <this user>:(R) only                   -> 444

      SYSTEM-only projecting as 000 is the proof that the reader is neither
      SYSTEM nor privileged; <user>:(R) projecting as 444 is the proof that it
      is the logged-on account. A file that account cannot open arrives in the
      container as mode 0000, and container-side root cannot help - the refusal
      is on the Windows side of the 9p link, before Linux permissions apply.

      Which makes Administrators:(F) a coin toss rather than a grant. It works
      only while the account's token carries BUILTIN\Administrators ENABLED -
      true when signed in as the built-in Administrator with Admin Approval
      Mode off, which is the normal Windows Server posture, and false for an
      ordinary administrator under UAC on Windows 11, where the unelevated
      token Docker Desktop runs with holds that group as deny-only. A deny-only
      SID can never grant access, so the same ACL that reads 777 on one machine
      reads 0000 on the other. A user SID is never deny-only, which is why this
      returns one.

      setup.ps1 runs elevated, but elevation does not change the user SID - only
      the groups and the integrity level - so the SID taken here is the same one
      Docker Desktop's unelevated processes carry. It is also the account this
      installer already binds an installation to: the HKCU RunOnce continuation
      and the S4U startup task both name it.

      $null when running as SYSTEM: that account already has its own full
      control ACE, and Docker Desktop is never running as it.
    #>

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity.IsSystem) { return $null }
        # The SID, not the name. icacls takes *S-1-... directly, which sidesteps
        # account-name resolution and localisation entirely.
        return '*' + $identity.User.Value
    }
    catch {
        return $null
    }
}

function Protect-DeltaSecretFile {
    <#
      Restricts $Path to Administrators + SYSTEM with inheritance disabled
      (A§24). Adapted from the reference installer's Protect-DeltaSecretFile.

      Mechanics, in order: /inheritance:d materialises the inherited ACEs so
      the ones that should survive still exist before anything is removed;
      /remove:g drops the broad principals (absent principals are a no-op, so
      this is idempotent); Administrators and SYSTEM are then re-granted
      explicitly rather than assumed to have survived.

      -AllowDockerRead adds ONE more access control entry: READ, for the single
      account Docker Desktop reads host files as. It exists for the private key
      in certs\, which NGINX opens from inside a container through a bind mount
      and which is otherwise projected into that container as mode 0000. See
      Get-DeltaDockerFileReadSid for the measurement behind it.

      It is read and nothing else, deliberately. The container must open this
      file; it must never change it. That is not left to `:ro` on the mount -
      the host ACL itself refuses the write, so a Compose file edited later
      cannot turn the key into something a container can overwrite.

      The switch is not the default. Every other caller here protects something
      no container ever opens - .env, its backups, the key backups in certs\ -
      and those keep the narrower ACL they already had.

      Non-fatal by design: this hardens an existing file, it is not a
      precondition for a working installation, and aborting because icacls
      could not adjust an ACL would trade a working deployment for a
      permissions nicety. The failure is reported loudly instead.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowDockerRead
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $broadPrincipals = @('BUILTIN\Users', 'Everyone', 'NT AUTHORITY\Authenticated Users')

    $grants = @('BUILTIN\Administrators:(F)', 'NT AUTHORITY\SYSTEM:(F)')

    $dockerGrant = $null
    if ($AllowDockerRead) {
        $dockerSid = Get-DeltaDockerFileReadSid
        if ($dockerSid) { $dockerGrant = "${dockerSid}:(R)" }
    }

    try {
        $output = & icacls.exe $Path /inheritance:d /C 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "icacls /inheritance:d failed: $(($output | Out-String).Trim())"
        }

        foreach ($principal in $broadPrincipals) {
            $null = & icacls.exe $Path /remove:g $principal /C 2>&1
        }

        # Granted after the removals, so an account that is also a member of one
        # of the broad principals still ends up with its explicit entry. Re-run
        # safe: icacls /grant replaces that principal's entry rather than adding
        # a second one, which is what lets a rerun repair a key staged by an
        # earlier version of this installer.
        foreach ($grant in $grants) {
            $output = & icacls.exe $Path /grant $grant /C 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "icacls /grant $grant failed: $(($output | Out-String).Trim())"
            }
        }

        # /grant:r, not /grant, and only for this one entry. icacls /grant ADDS
        # to whatever that principal already holds, so on an installation root
        # under a user profile - where the account may already carry an
        # inherited Full Control that /inheritance:d has just materialised -
        # a plain /grant would leave it holding Full Control over a private key
        # and quietly call that the fix. :r replaces the entry outright, so what
        # this account ends up with is Read, on every host, whatever it had
        # before. The two grants above keep /grant: their rights are unchanged
        # from what this installer has always applied.
        if ($dockerGrant) {
            $output = & icacls.exe $Path /grant:r $dockerGrant /C 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "icacls /grant:r $dockerGrant failed: $(($output | Out-String).Trim())"
            }
        }
    }
    catch {
        Write-DeltaWarning "Could not restrict permissions on '$Path': $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Secret generation (A§24)
#
# Both generators use RNGCryptoServiceProvider - a real CSPRNG - rather than
# [guid]::NewGuid() or Get-Random, neither of which is documented to be
# cryptographically unpredictable. These values stand in for real credentials.
# ---------------------------------------------------------------------------

function New-DeltaSecret {
    <#
      A high-entropy token for values that are never parsed as part of a URL -
      SESSION_SECRET above all. Base64 of $ByteLength CSPRNG bytes.
    #>
    param([int]$ByteLength = 48)

    $bytes = New-Object byte[] $ByteLength
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    return [Convert]::ToBase64String($bytes)
}

function New-DeltaPassword {
    <#
      A CSPRNG password drawn from [A-Za-z0-9] only.

      The restricted alphabet is deliberate: POSTGRES_PASSWORD ends up inside
      DATABASE_URL (A§7.4), where '/', '+', '@', ':' and '=' would all have to
      be percent-encoded correctly by every consumer of that string. An
      alphanumeric password of this length carries ample entropy
      (62^32 ~ 2^190) and cannot be corrupted by a URL-encoding mistake.

      Rejection sampling rather than modulo: 256 is not a multiple of 62, so a
      plain modulo would bias the first eight characters of the alphabet.
    #>
    param([int]$Length = 32)

    if ($Length -lt 8) {
        Stop-Setup 'A generated password must be at least 8 characters.'
    }

    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $limit = [math]::Floor(256 / $alphabet.Length) * $alphabet.Length

    $builder = New-Object System.Text.StringBuilder
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $buffer = New-Object byte[] 1
        while ($builder.Length -lt $Length) {
            $rng.GetBytes($buffer)
            if ($buffer[0] -ge $limit) {
                continue
            }
            $null = $builder.Append($alphabet[$buffer[0] % $alphabet.Length])
        }
    }
    finally {
        $rng.Dispose()
    }
    return $builder.ToString()
}

# ---------------------------------------------------------------------------
# Install-state file (A§17.2)
#
# Non-secret facts only. Secrets live exclusively in .env.
# ---------------------------------------------------------------------------

function Get-DeltaInstallStatePath {
    param([Parameter(Mandatory)][string]$InstallRoot)
    return (Join-Path -Path $InstallRoot -ChildPath $Script:DeltaInstallStateFileName)
}

function Read-DeltaInstallState {
    <#
      Reads and validates .delta-install.json. Returns Exists / IsValid /
      Error / Data. A malformed file is reported by naming the offending
      field - it is never silently rewritten, because it is the record of what
      a previous run actually did.
    #>
    param([Parameter(Mandatory)][string]$InstallRoot)

    $path = Get-DeltaInstallStatePath -InstallRoot $InstallRoot
    $result = [PSCustomObject]@{
        Path    = $path
        Exists  = $false
        IsValid = $false
        Error   = $null
        Data    = $null
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $result
    }
    $result.Exists = $true

    $raw = $null
    try {
        $raw = [System.IO.File]::ReadAllText($path)
    }
    catch {
        $result.Error = "'$path' could not be read: $($_.Exception.Message)"
        return $result
    }

    $data = $null
    try {
        $data = $raw | ConvertFrom-Json
    }
    catch {
        $result.Error = "'$path' is not valid JSON: $($_.Exception.Message)"
        return $result
    }

    if ($null -eq $data) {
        $result.Error = "'$path' is empty."
        return $result
    }

    $properties = @($data.PSObject.Properties.Name)

    if ($properties -notcontains 'schemaVersion') {
        $result.Error = "'$path' is missing the required field 'schemaVersion'."
        return $result
    }
    $schemaVersion = 0
    if (-not [int]::TryParse([string]$data.schemaVersion, [ref]$schemaVersion)) {
        $result.Error = "'$path' has a non-numeric 'schemaVersion' value: $($data.schemaVersion)"
        return $result
    }
    if ($schemaVersion -gt $Script:DeltaInstallStateSchemaVersion) {
        $result.Error = "'$path' has 'schemaVersion' $schemaVersion, which is newer than this installer understands ($Script:DeltaInstallStateSchemaVersion). It was probably written by a later version of the installer."
        return $result
    }

    if ($properties -notcontains 'state') {
        $result.Error = "'$path' is missing the required field 'state'."
        return $result
    }
    if ($Script:DeltaInstallStateValues -notcontains [string]$data.state) {
        $result.Error = "'$path' has an unrecognised 'state' value '$($data.state)'. Expected one of: $($Script:DeltaInstallStateValues -join ', ')."
        return $result
    }

    $result.IsValid = $true
    $result.Data = $data
    return $result
}

function Write-DeltaInstallState {
    <#
      Writes .delta-install.json atomically. By default the supplied
      properties are merged over whatever a valid existing file holds, so a
      caller updating one field does not have to restate the rest; -Replace
      writes only what was supplied.

      The installation root must already exist - creating it belongs to the
      stage that owns the directory tree, not to the state writer.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Properties,
        [switch]$Replace
    )

    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
        Stop-Setup "Cannot write the installation state file: '$InstallRoot' does not exist."
    }

    $merged = [ordered]@{}
    $merged['schemaVersion'] = $Script:DeltaInstallStateSchemaVersion

    if (-not $Replace) {
        $existing = Read-DeltaInstallState -InstallRoot $InstallRoot
        if ($existing.Exists -and $existing.IsValid) {
            foreach ($property in $existing.Data.PSObject.Properties) {
                if ($property.Name -eq 'schemaVersion') {
                    continue
                }
                $merged[$property.Name] = $property.Value
            }
        }
    }

    foreach ($key in $Properties.Keys) {
        if ([string]$key -eq 'schemaVersion') {
            # schemaVersion describes the format of this file and belongs to
            # the writer. A caller passing its own - the DELTA database schema
            # version, say - would make the file unreadable to
            # Read-DeltaInstallState and, through it, make the installer refuse
            # its own installation root. Observed exactly that during Phase 3.
            Stop-Setup "Refusing to overwrite the state file's own 'schemaVersion' field. Record a different kind of version under its own key."
        }
        $merged[[string]$key] = $Properties[$key]
    }

    if ($merged.Contains('state') -and $Script:DeltaInstallStateValues -notcontains [string]$merged['state']) {
        Stop-Setup "Refusing to write installation state '$($merged['state'])'. Expected one of: $($Script:DeltaInstallStateValues -join ', ')."
    }

    $path = Get-DeltaInstallStatePath -InstallRoot $InstallRoot
    $json = ([PSCustomObject]$merged | ConvertTo-Json -Depth 8)
    Write-DeltaFileAtomic -Path $path -Content ($json + [Environment]::NewLine)
    return $path
}

# ---------------------------------------------------------------------------
# Installation-state classification (A§28)
#
# Evidence-based, following the reference installer's Get-DeltaInstallPath
# principle: the state file is a cache, never the sole authority. A missing
# state file over a populated installation root is a *partial* installation,
# not an absent one.
# ---------------------------------------------------------------------------

function Test-DeltaInstallRootOwned {
    <#
      Decides whether it is safe for this installer to write into $InstallRoot.

      Safe means one of three things: the directory does not exist yet, it
      exists and is empty, or it already holds a valid .delta-install.json this
      installer wrote. Anything else - a populated directory with no state file,
      or a state file that cannot be read - is someone else's, and is left
      completely alone.

      This is not defensive decoration. On the development host C:\DELTA holds
      an unrelated *native* DELTA installation; adopting it, writing a state
      file into it, or generating a compose stack on top of it would all be
      variations of the same mistake. An installer that cannot tell its own
      directory from someone else's must stop, not guess.

      Returns IsOwned plus Reason and the evidence the decision was made on.
    #>
    param([Parameter(Mandatory)][string]$InstallRoot)

    $result = [PSCustomObject]@{
        InstallRoot = $InstallRoot
        IsOwned     = $false
        Exists      = $false
        IsEmpty     = $false
        HasState    = $false
        Reason      = $null
    }

    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
        $result.IsOwned = $true
        $result.Reason  = "'$InstallRoot' does not exist yet and can be created."
        return $result
    }
    $result.Exists = $true

    $state = Read-DeltaInstallState -InstallRoot $InstallRoot
    $result.HasState = $state.Exists

    if ($state.Exists -and $state.IsValid) {
        $result.IsOwned = $true
        $result.Reason  = "'$InstallRoot' holds a valid $Script:DeltaInstallStateFileName written by this installer."
        return $result
    }

    if ($state.Exists) {
        $result.Reason = "'$($state.Path)' exists but could not be read ($($state.Error)). Refusing to write over an installation state this installer cannot understand."
        return $result
    }

    $result.IsEmpty = (@(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue).Count -eq 0)
    if ($result.IsEmpty) {
        $result.IsOwned = $true
        $result.Reason  = "'$InstallRoot' exists and is empty."
        return $result
    }

    $result.Reason = "'$InstallRoot' already contains files that this installer did not create, and there is no $Script:DeltaInstallStateFileName to say otherwise."
    return $result
}

function Get-DeltaInstallationState {
    <#
      Classifies the installation at $InstallRoot as one of:

        none                - no installation root, or an empty one
        partial             - evidence exists but the installation is not
                              registered as complete
        installed           - registered complete and its artefacts are present
        installed-stopped   - installed, and Docker reports the containers
                              absent or exited
        docker-unavailable  - installed, and the Docker engine is unreachable

      The last two are the same filesystem evidence seen through Docker.
      Because this function performs no Docker interaction of its own, that
      evidence is supplied by the caller through -DockerStatus; with the
      default 'unknown' the classification stops at the filesystem and a
      complete installation reports 'installed'.

      Returns State, Reason and an Evidence list, plus the raw state-file and
      .env read results so a caller can report specifics without re-reading.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [ValidateSet('unknown', 'unavailable', 'running', 'stopped')]
        [string]$DockerStatus = 'unknown'
    )

    $evidence = [System.Collections.Generic.List[object]]::new()
    $addEvidence = {
        param($item, $present, $detail)
        $null = $evidence.Add([PSCustomObject]@{ Item = $item; Present = $present; Detail = $detail })
    }

    $rootExists = Test-Path -LiteralPath $InstallRoot -PathType Container
    & $addEvidence 'Installation root' $rootExists $InstallRoot

    $result = [PSCustomObject]@{
        InstallRoot = $InstallRoot
        State       = 'none'
        Reason      = "No installation root at '$InstallRoot'."
        Evidence    = @()
        StateFile   = $null
        EnvFile     = $null
    }

    if (-not $rootExists) {
        $result.Evidence = $evidence.ToArray()
        return $result
    }

    $children = @(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) {
        $result.Reason = "The installation root '$InstallRoot' exists but is empty."
        $result.Evidence = $evidence.ToArray()
        return $result
    }

    $envPath = Join-Path -Path $InstallRoot -ChildPath $Script:DeltaEnvFileName
    $composePath = Join-Path -Path $InstallRoot -ChildPath $Script:DeltaComposeFileName

    $envFile = Read-DeltaEnvFile -Path $envPath
    $stateFile = Read-DeltaInstallState -InstallRoot $InstallRoot
    $result.EnvFile = $envFile
    $result.StateFile = $stateFile

    $envDetail = $envPath
    if ($envFile.Exists -and $envFile.Malformed.Count -gt 0) {
        $envDetail = "$envPath ($($envFile.Malformed.Count) line(s) could not be parsed)"
    }
    & $addEvidence '.env' $envFile.Exists $envDetail

    $composeExists = Test-Path -LiteralPath $composePath -PathType Leaf
    & $addEvidence 'docker-compose.yml' $composeExists $composePath

    $stateDetail = $stateFile.Path
    if ($stateFile.Exists -and $stateFile.IsValid) {
        $stateDetail = "$($stateFile.Path) (state = $($stateFile.Data.state))"
    }
    elseif ($stateFile.Exists) {
        $stateDetail = $stateFile.Error
    }
    & $addEvidence 'Installation state file' $stateFile.Exists $stateDetail

    foreach ($relative in @('nginx\conf.d\delta.conf', 'certs', 'uploads', 'logs', 'backups')) {
        $candidate = Join-Path -Path $InstallRoot -ChildPath $relative
        & $addEvidence $relative (Test-Path -LiteralPath $candidate) $candidate
    }

    $result.Evidence = $evidence.ToArray()

    if ($stateFile.Exists -and -not $stateFile.IsValid) {
        $result.State = 'partial'
        $result.Reason = $stateFile.Error
        return $result
    }

    if (-not $stateFile.Exists) {
        $result.State = 'partial'
        $result.Reason = "'$InstallRoot' contains installation artefacts but no $Script:DeltaInstallStateFileName, so a previous run did not complete."
        return $result
    }

    if ([string]$stateFile.Data.state -ne 'installed') {
        $result.State = 'partial'
        $result.Reason = "$Script:DeltaInstallStateFileName records state = '$($stateFile.Data.state)'."
        return $result
    }

    $missing = @()
    if (-not $envFile.Exists)  { $missing += $Script:DeltaEnvFileName }
    if (-not $composeExists)   { $missing += $Script:DeltaComposeFileName }
    if ($missing.Count -gt 0) {
        $result.State = 'partial'
        $result.Reason = "$Script:DeltaInstallStateFileName records a complete installation, but these artefacts are missing: $($missing -join ', ')."
        return $result
    }

    $result.State = 'installed'
    $result.Reason = "A registered DELTA Docker installation is present at '$InstallRoot'."

    switch ($DockerStatus) {
        'unavailable' {
            $result.State = 'docker-unavailable'
            $result.Reason = "A registered DELTA Docker installation is present at '$InstallRoot', but the Docker engine is not reachable."
        }
        'stopped' {
            $result.State = 'installed-stopped'
            $result.Reason = "A registered DELTA Docker installation is present at '$InstallRoot' and its containers are not running."
        }
    }

    return $result
}

# ---------------------------------------------------------------------------
# Fresh-install settings (Phase 10.5)
#
# The three things only the administrator can tell the installer, asked once,
# up front, before anything slow or irreversible happens. Everything else the
# installation needs it either detects or generates.
#
# The ordering matters more than it looks. Before this, the administrator
# password was asked by the security bootstrap - which runs after the
# prerequisite checks, artefact generation, a ~700 MB image pull and two health
# gates. Somebody who started the installer and went to make coffee came back
# to a prompt. Questions belong at the front, where a person is still watching.
# ---------------------------------------------------------------------------

function Test-DeltaHostName {
    <#
      Whether a string is usable as the name this installation is reached by.

      Accepts 'localhost', a DNS name, or an IP literal. Deliberately does NOT
      resolve anything: an administrator installing on a server whose DNS entry
      does not exist yet is doing something completely normal, and refusing
      their hostname because a lookup failed would be this installer inventing
      a prerequisite. The name drives NGINX's server_name and PUBLIC_URL; DNS
      is somebody else's job and is reported, never enforced.

      The rules are the ones that would actually break the generated
      configuration: no whitespace, no scheme, no path, no port, and DNS label
      syntax where it is a name rather than an address.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $result = [PSCustomObject]@{ IsValid = $false; Reason = $null; IsAddress = $false }

    $candidate = $Value.Trim()
    if (-not $candidate) {
        $result.Reason = 'A hostname is required.'
        return $result
    }
    if ($candidate -match '\s') {
        $result.Reason = 'A hostname cannot contain spaces.'
        return $result
    }
    if ($candidate -match '://') {
        $result.Reason = "Enter the hostname only, without a scheme - '$($candidate -replace '^.*://', '')' rather than '$candidate'."
        return $result
    }
    if ($candidate -match '/') {
        $result.Reason = 'Enter the hostname only, without a path.'
        return $result
    }
    # A bare IPv6 literal contains colons and is fine; anything else with a
    # colon is somebody adding a port, which belongs to the port question.
    $address = [System.Net.IPAddress]::None
    if ([System.Net.IPAddress]::TryParse($candidate, [ref]$address)) {
        $result.IsValid = $true
        $result.IsAddress = $true
        return $result
    }
    if ($candidate -match ':') {
        $result.Reason = 'Enter the hostname only, without a port - the port is asked for separately if it is needed.'
        return $result
    }
    if ($candidate.Length -gt 253) {
        $result.Reason = 'A hostname cannot be longer than 253 characters.'
        return $result
    }
    foreach ($label in $candidate.Split('.')) {
        if (-not $label) {
            $result.Reason = "'$candidate' has an empty part - check for a doubled or trailing dot."
            return $result
        }
        if ($label.Length -gt 63) {
            $result.Reason = "'$label' is longer than the 63 characters a hostname part allows."
            return $result
        }
        if ($label -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$') {
            $result.Reason = "'$label' is not a valid hostname part - use letters, digits and hyphens, not starting or ending with a hyphen."
            return $result
        }
    }

    $result.IsValid = $true
    return $result
}

# ---------------------------------------------------------------------------
# The domain model
#
# PUBLIC_URL is, and stays, ONE canonical URL. NGINX may accept several
# hostnames. Those are two different things and this section keeps them
# separate:
#
#   primary domain      the host part of PUBLIC_URL. Exactly one, always.
#                       Persisted where it has always been persisted -
#                       DELTA_HOSTNAME in .env - so there is no second copy to
#                       drift from it.
#   additional domains  further hostnames NGINX accepts. Persisted in
#                       .delta-install.json under "domains", which is the
#                       existing store for non-secret installation facts.
#
# A contradictory state is not rejected here, it is unrepresentable: the
# primary is read from the one place that defines it, the additional list is
# normalised and has the primary removed from it on every read, and the whole
# set is deduplicated case-insensitively. There is no way to express two
# primaries, a primary missing from the served set, or a case-variant
# duplicate.
# ---------------------------------------------------------------------------

$Script:DeltaDomainStateKey = 'domains'

function ConvertTo-DeltaDomainName {
    <#
      The normal form a domain is compared and stored in: trimmed, with any
      trailing dot removed, and lower-cased.

      DNS is case-insensitive and NGINX matches server_name case-insensitively,
      so DELTA.example.org and delta.example.org are one domain. Storing the
      normal form is what makes "reject duplicates" a comparison rather than a
      guess.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }
    return $Value.Trim().TrimEnd('.').ToLowerInvariant()
}

function Test-DeltaDomainName {
    <#
      Whether a string is usable as a hostname NGINX should accept.

      The rules are Test-DeltaHostName's - this deliberately does not implement
      a second hostname grammar - with three additions that only matter for a
      domain being added to a served set:

        * a wildcard is named as a wildcard rather than reported as a bad
          hostname part, because that is the mistake the operator actually
          made. NGINX supports wildcard server_name; this installer does not
          offer it, because nothing else in the architecture (certificate
          coverage, the access guide, PUBLIC_URL) is built for one.
        * an IPv6 literal is refused. Test-DeltaHostName accepts it for the
          hostname question, but a bare IPv6 literal in server_name is not the
          address match an operator expects.
        * credentials, query strings and fragments are named, because "user@"
          and "?" reaching this prompt mean a URL was pasted.

      Returns IsValid, Reason and the normalised value.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Value)

    $result = [PSCustomObject]@{
        IsValid    = $false
        Reason     = $null
        Normalized = $null
        IsAddress  = $false
    }

    $candidate = if ($null -eq $Value) { '' } else { $Value.Trim() }

    if (-not $candidate) {
        $result.Reason = 'A domain is required.'
        return $result
    }
    if ($candidate.Contains('*')) {
        $result.Reason = "Wildcard domains are not supported. Add each hostname DELTA should answer to, for example 'delta.example.org'."
        return $result
    }
    if ($candidate.Contains('@')) {
        $result.Reason = 'Enter the hostname only, without a user name - a domain is not a URL.'
        return $result
    }
    if ($candidate.Contains('?')) {
        $result.Reason = 'Enter the hostname only, without a query string.'
        return $result
    }
    if ($candidate.Contains('#')) {
        $result.Reason = 'Enter the hostname only, without a fragment.'
        return $result
    }

    # Validate the NORMAL form, not the raw input. A fully qualified name
    # written with the DNS root dot - delta.example.org. - is a legitimate way
    # to type a hostname, and Test-DeltaHostName correctly reads that trailing
    # dot as an empty label. Normalising first means the operator's spelling is
    # accepted and the stored value is still the one form everything compares
    # against.
    $candidate = ConvertTo-DeltaDomainName -Value $candidate
    if (-not $candidate) {
        $result.Reason = 'A domain is required.'
        return $result
    }

    $check = Test-DeltaHostName -Value $candidate
    if (-not $check.IsValid) {
        $result.Reason = $check.Reason
        return $result
    }

    if ($check.IsAddress -and $candidate.Contains(':')) {
        $result.Reason = "'$candidate' is an IPv6 address. NGINX matches server_name by name, so an IPv6 literal cannot be added as a domain - the installation already answers on any address it is reached by."
        return $result
    }

    $result.IsAddress  = $check.IsAddress
    $result.Normalized = ConvertTo-DeltaDomainName -Value $candidate
    $result.IsValid    = $true
    return $result
}

function Get-DeltaDomainNameList {
    <#
      A validated, deduplicated, deterministically ordered domain set: the
      primary first, then the additional domains in the order they were
      configured.

      This is the configuration-injection boundary, and it is deliberately
      placed here rather than at the prompt. Domain input is data; it becomes
      part of an NGINX directive only by passing through this function, and
      anything that is not a plain hostname stops the operation outright rather
      than being escaped, quoted or dropped quietly. A caller cannot reach the
      generator without coming through it.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Primary,
        [AllowEmptyCollection()][string[]]$Additional = @()
    )

    $ordered = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($value in (@($Primary) + @($Additional))) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $normalized = ConvertTo-DeltaDomainName -Value $value
        if ($normalized -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$') {
            Stop-Setup "Refusing to write '$value' into the NGINX configuration: a domain is letters, digits, dots and hyphens, and nothing else."
        }
        if ($seen.Add($normalized)) { $null = $ordered.Add($normalized) }
    }

    # Returned as a plain array, and every caller wraps the call in @() - the
    # convention the rest of this project already uses for list-returning
    # functions. It matters here: PowerShell unrolls a one-element array onto
    # the pipeline, so a caller that indexed an unwrapped result would be
    # indexing the characters of a string instead of the list.
    return $ordered.ToArray()
}

function Get-DeltaDomainModel {
    <#
      The authoritative domain model for an installation, assembled from the
      two places that already hold it.

      Backward compatibility is not a migration, it is the shape of this
      function: an installation that predates Domain Management has no "domains"
      record, so the additional list is empty and the primary is the hostname it
      always had. Nothing is written to make that true, so entering Management
      Mode on an old installation reads and reports without changing a byte.

      The primary is DELTA_HOSTNAME. If that is missing or unusable, it falls
      back to the host part of PUBLIC_URL - through the one URL parser, never a
      -replace here - and finally to localhost, which is what every other reader
      in this installer already defaults to.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        # Optional: management mode has already read .env and should not read it
        # again. The shape is Get-DeltaStackConfiguration's.
        [object]$Configuration
    )

    $envPath = Join-Path -Path $InstallRoot -ChildPath $Script:DeltaEnvFileName

    $model = [PSCustomObject]@{
        InstallRoot   = $InstallRoot
        Primary       = $null
        Additional    = @()
        All           = @()
        Scheme        = 'http'
        Port          = 80
        PublicUrl     = $null
        PrimarySource = 'default'
        HasPersisted  = $false
        Warnings      = @()
    }

    $publicUrl  = $null
    $hostValue  = $null
    $tlsEnabled = $false
    $httpPort   = 80
    $httpsPort  = 443

    if ($Configuration) {
        $hostValue  = [string]$Configuration.HostName
        $publicUrl  = [string]$Configuration.PublicUrl
        $tlsEnabled = [bool]$Configuration.TlsEnabled
        $httpPort   = [int]$Configuration.HttpPort
        $httpsPort  = [int]$Configuration.HttpsPort
    }
    elseif (Test-Path -LiteralPath $envPath -PathType Leaf) {
        $envFile = Read-DeltaEnvFile -Path $envPath
        $read = {
            param($key, $fallback)
            if ($envFile.Entries.Contains($key)) {
                $value = [string]$envFile.Entries[$key]
                if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
            }
            return $fallback
        }
        $hostValue  = & $read 'DELTA_HOSTNAME' $null
        $publicUrl  = & $read 'PUBLIC_URL' $null
        $tlsEnabled = ((& $read 'TLS_ENABLED' 'false') -eq 'true')
        [void][int]::TryParse([string](& $read 'HTTP_PORT'  '80'),  [ref]$httpPort)
        [void][int]::TryParse([string](& $read 'HTTPS_PORT' '443'), [ref]$httpsPort)
    }

    $model.PublicUrl = $publicUrl
    $model.Scheme    = if ($tlsEnabled) { 'https' } else { 'http' }
    $model.Port      = if ($tlsEnabled) { $httpsPort } else { $httpPort }

    # --- the primary ------------------------------------------------------
    if ($hostValue) {
        $check = Test-DeltaDomainName -Value $hostValue
        if ($check.IsValid) {
            $model.Primary = $check.Normalized
            $model.PrimarySource = 'DELTA_HOSTNAME'
        }
        else {
            $model.Warnings += "DELTA_HOSTNAME is '$hostValue', which is not a usable domain ($($check.Reason))."
        }
    }
    if (-not $model.Primary -and $publicUrl) {
        $parts = Get-DeltaPublicUrlParts -Url $publicUrl
        if ($parts.IsValid) {
            $check = Test-DeltaDomainName -Value $parts.HostName
            if ($check.IsValid) {
                $model.Primary = $check.Normalized
                $model.PrimarySource = 'PUBLIC_URL'
            }
        }
    }
    if (-not $model.Primary) {
        $model.Primary = 'localhost'
        $model.PrimarySource = 'default'
    }

    # --- the additional domains -------------------------------------------
    $state = Read-DeltaInstallState -InstallRoot $InstallRoot
    $persisted = @()
    if ($state.Exists -and -not $state.IsValid) {
        $model.Warnings += "The installation state file could not be read ($($state.Error)). Only the primary domain is known."
    }
    elseif ($state.Exists -and $state.IsValid -and (@($state.Data.PSObject.Properties.Name) -contains $Script:DeltaDomainStateKey)) {
        $record = $state.Data.$Script:DeltaDomainStateKey
        if ($record -and (@($record.PSObject.Properties.Name) -contains 'additional')) {
            $model.HasPersisted = $true
            # @() around it on purpose: a one-element JSON array comes back from
            # ConvertFrom-Json as a bare string, and iterating a string yields
            # the string, not its characters - but a null yields one null.
            $persisted = @($record.additional | Where-Object { $_ })
        }
        elseif ($record) {
            $model.Warnings += "The installation state file has a 'domains' record with no 'additional' list. It was ignored and nothing was rewritten."
        }
    }

    $additional = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $null = $seen.Add($model.Primary)

    foreach ($entry in $persisted) {
        $check = Test-DeltaDomainName -Value ([string]$entry)
        if (-not $check.IsValid) {
            $model.Warnings += "The recorded domain '$entry' is not a usable domain ($($check.Reason)). It is not being served."
            continue
        }
        if ($seen.Add($check.Normalized)) { $null = $additional.Add($check.Normalized) }
    }

    $model.Additional = @($additional.ToArray())
    $model.All = @(Get-DeltaDomainNameList -Primary $model.Primary -Additional $model.Additional)
    return $model
}

function Set-DeltaPersistedDomain {
    <#
      Records the additional domains in .delta-install.json.

      Only the additional list is written. The primary is not duplicated here:
      it is DELTA_HOSTNAME, and a second copy of it in the state file would be a
      second thing to keep in step - which is exactly the drift this feature
      exists to prevent. The state file's existing 'hostname' and 'publicUrl'
      fields remain what they have always been, the installer's record of what
      it wrote, and Set Primary Domain updates them for the same reason it
      updates .env.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Additional,
        [System.Collections.IDictionary]$AdditionalProperties
    )

    $properties = [ordered]@{}
    if ($AdditionalProperties) {
        foreach ($key in $AdditionalProperties.Keys) { $properties[[string]$key] = $AdditionalProperties[$key] }
    }
    $properties[$Script:DeltaDomainStateKey] = [ordered]@{
        additional = @($Additional)
        updatedAt  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    return (Write-DeltaInstallState -InstallRoot $InstallRoot -Properties $properties)
}

function Read-DeltaHostName {
    <#
      Asks for the name users will reach DELTA by, defaulting to localhost.

      The default is the point of the prompt. An administrator should be able
      to install DELTA on a machine, press Enter, and immediately try it from
      that machine - without owning a DNS name, and without the installer
      pretending it needs one. A real hostname is accepted just as readily and
      then drives NGINX, PUBLIC_URL, the certificate subject when one is
      generated, and the access guide.
    #>
    param(
        [string]$Current,
        [string]$Default = 'localhost'
    )

    $shown = if ($Current) { $Current } else { $Default }

    Write-Host ''
    Write-Host 'Hostname or domain'
    Write-Detail 'The name people will use to reach DELTA in a browser. Press Enter to keep'
    Write-Detail "'$shown', which is right for installing and testing on this machine."
    Write-Detail 'A name does not have to resolve in DNS yet - nothing here looks it up.'
    Write-Host ''

    while ($true) {
        $answer = ([string](Read-Host -Prompt "Hostname/domain [$shown]")).Trim()
        if (-not $answer) { return $shown }

        $check = Test-DeltaHostName -Value $answer
        if ($check.IsValid) { return $answer }
        Write-DeltaWarning $check.Reason
    }
}

function Read-DeltaTypedPasswordEntry {
    <#
      Option 1 of the question below: the operator types the credential.

      Entered twice, masked both times, and the two entries must match. Nothing
      is echoed and nothing typed here reaches the transcript - the accepted
      value is registered as a secret before it is returned, so even output this
      installer did not format itself is redacted on its way to the log.

      Returns $null when the operator enters nothing at all. That is not a
      fallback to generation - it is "I did not mean to be here", and the caller
      puts the choice back on screen so that generating stays something the
      operator picks rather than something that happens to them. Every other
      way out of this loop is a password the operator typed twice.

      The two validity rules are the ones this installer has always applied to a
      chosen credential: a minimum length, and a refusal of the one shape .env
      cannot represent. They are checked before the confirmation is asked for,
      so a password that was never going to be accepted is not typed twice.

      The prompts are parameters because the administrator credential and the
      database password ask the same question about different secrets, and the
      masked-entry rules above are the part that must not be written twice. The
      defaults are the administrator's, so its call site reads as it always did.
    #>
    param(
        [string]$Prompt = 'Administrator password',
        [string]$ConfirmPrompt = 'Confirm administrator password',
        [int]$MinimumLength = 8
    )

    while ($true) {
        $first = Read-Host -Prompt $Prompt -AsSecureString
        $plainFirst = ConvertTo-DeltaPlainText -SecureString $first
        try {
            if ($plainFirst.Length -eq 0) {
                Write-Detail 'Nothing was entered, so no password has been set.'
                return $null
            }
            if ($plainFirst.Length -lt $MinimumLength) {
                Write-DeltaWarning "Use at least $MinimumLength characters."
                continue
            }
            # The one shape .env cannot represent, refused while it can still
            # be retyped rather than silently mangled later.
            if ($plainFirst.Contains('"') -and $plainFirst.Contains("'")) {
                Write-DeltaWarning 'A password cannot contain both single and double quotes.'
                continue
            }

            $second = Read-Host -Prompt $ConfirmPrompt -AsSecureString
            $plainSecond = ConvertTo-DeltaPlainText -SecureString $second
            try {
                if ($plainFirst -cne $plainSecond) {
                    Write-DeltaWarning 'The two entries did not match. Try again.'
                    continue
                }
            }
            finally { $plainSecond = $null }

            Register-DeltaSecretValue -Value $plainFirst
            return [PSCustomObject]@{ Password = $first; WasGenerated = $false }
        }
        finally { $plainFirst = $null }
    }
}

function Read-DeltaPasswordChoice {
    <#
      How a credential this installer creates gets decided during a new
      installation: an explicit question with two answers, rather than a
      password prompt whose empty answer meant something.

      Both prompts this installer asks used to end `[Enter = generate]`.
      Generation was the likeliest outcome and the easiest one to reach by
      accident, and an operator who pressed Enter to get past a prompt they had
      not read did not necessarily know they had just chosen a credential. The
      choice is the same; what changed is that it is now asked as one:

        1. Enter a password
        2. Generate a strong password automatically

      Option 2 is the default because it is the better answer for almost every
      installation and the safe answer when somebody presses Enter - the same
      reason the reset flow in Delta.Manage.ps1 defaults to generating. Nothing
      but 1, 2 or Enter is accepted: at a question about which METHOD to use, an
      unrecognised answer is a misunderstanding to correct, never a password to
      silently accept.

      The question, its two options, the default and the rules for what is
      accepted are the same for every credential and live here once. Only the
      heading, the explanation, the prompts and the generated length differ, and
      those are the parameters. Read-DeltaAdministratorPassword and
      Read-DeltaPostgresPassword below are the two call sites; they exist so
      each credential's wording is stated in one obvious place rather than
      assembled at the point of use.

      Returns the SecureString plus whether it was generated, because the
      completion summary shows a generated credential once and must never show
      one the operator chose and already knows.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Explanation,
        [Parameter(Mandatory)][string]$EntryPrompt,
        [Parameter(Mandatory)][string]$ConfirmPrompt,
        [Parameter(Mandatory)][string[]]$GeneratedMessage,
        [Parameter(Mandatory)][string]$LogLabel,
        [int]$GeneratedLength = 20,
        [int]$MinimumLength = 8
    )

    # Nothing animates over a question. Suspended rather than stopped, and
    # released in the finally, so an operation that was in progress when this
    # was reached carries on saying so afterwards. Suspension is counted, so
    # the Write-Detail calls below cannot bring an animation back while the
    # question is still on screen.
    Suspend-DeltaActivity
    try {
        Write-Host ''
        Write-Host $Title
        Write-Host ''
        foreach ($line in $Explanation) { Write-Detail $line }
        Write-Host ''
        Write-Host 'Choose how to set the password:'
        Write-Host ''
        Write-Host '  1. Enter a password'
        Write-Host '  2. Generate a strong password automatically'
        Write-Host ''

        while ($true) {
            $choice = ([string](Read-Host -Prompt 'Choose 1 or 2 [2]')).Trim()

            if ($choice -eq '1') {
                $typed = Read-DeltaTypedPasswordEntry -Prompt $EntryPrompt `
                    -ConfirmPrompt $ConfirmPrompt -MinimumLength $MinimumLength
                if ($typed) {
                    Write-DeltaLogLine -Message "${LogLabel}: entered by the operator." -Level 'DETAIL'
                    return $typed
                }
                # Nothing was entered. Ask the question again rather than
                # deciding on the operator's behalf.
                continue
            }

            if ($choice -eq '' -or $choice -eq '2') {
                # The same CSPRNG generator every other secret in this
                # installation comes from, at the length this credential has
                # always been generated at.
                $generated = New-DeltaPassword -Length $GeneratedLength
                try {
                    Register-DeltaSecretValue -Value $generated
                    foreach ($line in $GeneratedMessage) { Write-Detail $line }
                    Write-DeltaLogLine -Message "${LogLabel}: generated by the installer." -Level 'DETAIL'
                    return [PSCustomObject]@{
                        Password     = (ConvertTo-SecureString -String $generated -AsPlainText -Force)
                        WasGenerated = $true
                    }
                }
                finally { $generated = $null }
            }

            # The answer is deliberately NOT quoted back. This question stands
            # where a password prompt used to, so the likeliest wrong answer an
            # operator gives it is the password they meant to set - and echoing
            # that would put it on the screen and in the transcript, which is
            # the one thing this whole flow exists to avoid. What was typed is
            # not information the operator needs; what the valid answers are, is.
            Write-DeltaWarning 'That is not one of the choices. Enter 1 to type a password, or 2 - or just Enter - to have one generated.'
        }
    }
    finally { Resume-DeltaActivity }
}

function Read-DeltaAdministratorPassword {
    <#
      The DELTA administrator credential: the one an operator signs in with.
      Everything about how it is asked is Read-DeltaPasswordChoice's; this is
      the wording, and the length this credential has always been generated at.
    #>
    param(
        [int]$GeneratedLength = 20,
        [int]$MinimumLength = 8
    )

    return (Read-DeltaPasswordChoice `
        -Title 'DELTA administrator password' `
        -Explanation @(
            'The password for signing in to DELTA as admin@admin.com. The image ships a'
            'publicly known default, so the installer always replaces it before DELTA is'
            'reachable.'
        ) `
        -EntryPrompt 'Administrator password' `
        -ConfirmPrompt 'Confirm administrator password' `
        -GeneratedMessage @(
            'A strong administrator password will be generated. It is shown once when'
            'the installation finishes.'
        ) `
        -LogLabel 'Administrator password' `
        -GeneratedLength $GeneratedLength `
        -MinimumLength $MinimumLength)
}

function Read-DeltaPostgresPassword {
    <#
      The PostgreSQL password for the database this installer creates.

      Asked the same way as the administrator credential above, for the same
      reason: the old prompt was `Database password [Enter = generate]`, and an
      empty answer is not a decision an operator can be assumed to have made
      deliberately. Nothing else about this credential changed - the installer
      still creates the cluster itself and does not need to be told the
      password, so generating remains the default and the right answer for
      almost every installation.

      Unlike the administrator credential, a generated database password is
      never displayed: the completion summary has no line for it, and nothing
      reads it back. So the generated message says what will happen and stops
      there rather than promising a value that is coming.
    #>
    param(
        [int]$GeneratedLength = 32,
        [int]$MinimumLength = 8
    )

    return (Read-DeltaPasswordChoice `
        -Title 'Database password' `
        -Explanation @(
            'The installer creates the PostgreSQL database for DELTA and protects it'
            'with this password. The database is not published to the network.'
        ) `
        -EntryPrompt 'Database password' `
        -ConfirmPrompt 'Confirm database password' `
        -GeneratedMessage @(
            'A strong database password will be generated.'
        ) `
        -LogLabel 'Database password' `
        -GeneratedLength $GeneratedLength `
        -MinimumLength $MinimumLength)
}

function Read-DeltaFreshInstallSettings {
    <#
      The Installation settings step: everything the administrator is asked
      before the installer starts doing slow or irreversible work.

      What is asked depends on what the installation already has, which is what
      keeps a rerun quiet and a -Reconfigure honest:

        hostname            always offered, current value as the default
        database password   only when there is not one yet. Changing it later
                            does not change what the cluster expects, so
                            re-asking on a rerun would be offering a foot-gun
                            (A§7.5)
        administrator        only when the security bootstrap has not already
                            completed, so a rerun never silently replaces a
                            credential somebody is using

      In a non-interactive run nothing is asked and nothing is invented beyond
      the generation the project has always done: the .env template ships
      __GENERATE__ for the database password and Phase 5 generates the
      administrator credential when it cannot prompt. That is pre-existing,
      documented behaviour, not a default introduced to dodge a question.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [bool]$AllowPrompt = $true,
        [string]$HostName
    )

    $result = [PSCustomObject]@{
        HostName                 = $null
        PostgresPassword         = $null
        AdminPassword            = $null
        AdminPasswordWasGenerated = $false
        AskedHostName            = $false
        AskedPostgresPassword    = $false
        AskedAdminPassword       = $false
    }

    $envPath = Join-Path -Path $InstallRoot -ChildPath '.env'
    $existingHost = Get-DeltaEnvValue -Path $envPath -Key 'DELTA_HOSTNAME'
    $existingPostgres = Get-DeltaEnvValue -Path $envPath -Key 'POSTGRES_PASSWORD'
    $needsPostgres = ([string]::IsNullOrWhiteSpace($existingPostgres) -or $existingPostgres -eq '__GENERATE__')

    $state = Read-DeltaInstallState -InstallRoot $InstallRoot
    $alreadyBootstrapped = $false
    if ($state.Exists -and $state.IsValid -and (@($state.Data.PSObject.Properties.Name) -contains 'adminBootstrap')) {
        $alreadyBootstrapped = [bool]$state.Data.adminBootstrap.completed
    }

    # A hostname supplied on the command line is an answer, not a default.
    if ($HostName) { $result.HostName = $HostName }

    if (-not $AllowPrompt) {
        if (-not $result.HostName) {
            $result.HostName = if ($existingHost) { $existingHost } else { 'localhost' }
        }
        return $result
    }

    if (-not $result.HostName -or $needsPostgres -or -not $alreadyBootstrapped) {
        Show-Section -Title 'Installation settings'
        Write-Host 'A few things only you can tell the installer. Everything else is detected or'
        Write-Host 'generated, and nothing below needs a file prepared in advance.'
    }

    if (-not $result.HostName) {
        $result.HostName = Read-DeltaHostName -Current $existingHost
        $result.AskedHostName = $true
    }

    if ($needsPostgres) {
        # Asked as an explicit choice rather than as a password prompt with a
        # meaningful empty answer, the same way the administrator credential is
        # below. The condition guarding it is unchanged: a cluster that already
        # has a password is never asked again, because changing it here would
        # not change what PostgreSQL expects (A§7.5).
        $answer = Read-DeltaPostgresPassword -GeneratedLength 32
        $result.PostgresPassword = $answer.Password
        $result.AskedPostgresPassword = $true
    }

    if (-not $alreadyBootstrapped) {
        # Asked as an explicit choice rather than as a password prompt with a
        # meaningful empty answer. The condition guarding it is unchanged: an
        # installation whose administrator has already been secured is never
        # asked again, so a rerun, an update and a -Reconfigure stay quiet and
        # keep the credential somebody is already using.
        $answer = Read-DeltaAdministratorPassword -GeneratedLength 20
        $result.AdminPassword = $answer.Password
        $result.AdminPasswordWasGenerated = $answer.WasGenerated
        $result.AskedAdminPassword = $true
    }

    return $result
}
