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

function Protect-DeltaSecretFile {
    <#
      Restricts $Path to Administrators + SYSTEM with inheritance disabled
      (A§24). Adapted from the reference installer's Protect-DeltaSecretFile.

      Mechanics, in order: /inheritance:d materialises the inherited ACEs so
      the ones that should survive still exist before anything is removed;
      /remove:g drops the broad principals (absent principals are a no-op, so
      this is idempotent); Administrators and SYSTEM are then re-granted
      explicitly rather than assumed to have survived.

      Non-fatal by design: this hardens an existing file, it is not a
      precondition for a working installation, and aborting because icacls
      could not adjust an ACL would trade a working deployment for a
      permissions nicety. The failure is reported loudly instead.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $broadPrincipals = @('BUILTIN\Users', 'Everyone', 'NT AUTHORITY\Authenticated Users')

    try {
        $output = & icacls.exe $Path /inheritance:d /C 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "icacls /inheritance:d failed: $(($output | Out-String).Trim())"
        }

        foreach ($principal in $broadPrincipals) {
            $null = & icacls.exe $Path /remove:g $principal /C 2>&1
        }

        foreach ($grant in @('BUILTIN\Administrators:(F)', 'NT AUTHORITY\SYSTEM:(F)')) {
            $output = & icacls.exe $Path /grant $grant /C 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "icacls /grant $grant failed: $(($output | Out-String).Trim())"
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

function Read-DeltaInstallPassword {
    <#
      A credential the administrator may either choose or delegate.

      Bare Enter means "generate a strong one", which is what makes this a
      convenience rather than an interrogation: the installer creates both the
      PostgreSQL cluster and the DELTA administrator account, so it does not
      need to be *told* either password - it offers the choice to an operator
      who wants one they can use elsewhere.

      A typed password is entered twice and must match. Nothing is echoed, and
      the value is returned as a SecureString so it is converted to plain text
      only at the single point it is used.

      Returns the SecureString plus whether it was generated, because the
      completion summary has to show a generated credential exactly once and
      must never show one the operator chose and already knows.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Prompt,
        [string[]]$Explanation = @(),
        [int]$GeneratedLength = 24,
        [int]$MinimumLength = 8
    )

    Write-Host ''
    Write-Host $Title
    foreach ($line in $Explanation) { Write-Detail $line }
    Write-Detail 'Press Enter to have a strong one generated for you.'
    Write-Host ''

    while ($true) {
        $first = Read-Host -Prompt "$Prompt [Enter = generate]" -AsSecureString
        $plainFirst = ConvertTo-DeltaPlainText -SecureString $first
        try {
            if ($plainFirst.Length -eq 0) {
                $generated = New-DeltaPassword -Length $GeneratedLength
                try {
                    Register-DeltaSecretValue -Value $generated
                    Write-Detail 'A strong password will be generated.'
                    return [PSCustomObject]@{
                        Password     = (ConvertTo-SecureString -String $generated -AsPlainText -Force)
                        WasGenerated = $true
                    }
                }
                finally { $generated = $null }
            }

            if ($plainFirst.Length -lt $MinimumLength) {
                Write-DeltaWarning "Use at least $MinimumLength characters, or press Enter to have one generated."
                continue
            }
            # The one shape .env cannot represent, refused while it can still
            # be retyped rather than silently mangled later.
            if ($plainFirst.Contains('"') -and $plainFirst.Contains("'")) {
                Write-DeltaWarning 'A password cannot contain both single and double quotes.'
                continue
            }

            $second = Read-Host -Prompt 'Confirm' -AsSecureString
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
        $answer = Read-DeltaInstallPassword -Title 'Database password' `
            -Prompt 'Database password' `
            -Explanation @(
                'The installer creates the PostgreSQL database for DELTA and sets this password'
                'on it. Nothing outside this machine can reach that database - it is never'
                'published to the network - so a generated password is a perfectly good answer.'
                'Choose your own if you want to connect with other tooling.'
            ) -GeneratedLength 32
        $result.PostgresPassword = $answer.Password
        $result.AskedPostgresPassword = $true
    }

    if (-not $alreadyBootstrapped) {
        $answer = Read-DeltaInstallPassword -Title 'DELTA administrator password' `
            -Prompt 'Administrator password' `
            -Explanation @(
                'The password for signing in to DELTA as admin@admin.com. The image ships a'
                'publicly known default, so the installer always replaces it before DELTA is'
                'reachable. A generated one is shown once at the end.'
            ) -GeneratedLength 20
        $result.AdminPassword = $answer.Password
        $result.AdminPasswordWasGenerated = $answer.WasGenerated
        $result.AskedAdminPassword = $true
    }

    return $result
}
