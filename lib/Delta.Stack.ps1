# =============================================================================
# Delta.Stack.ps1 - installation root, artefact generation, image pinning,
#                   ordered startup, health gating, migration verification
#
# Dot-source Delta.Common.ps1, Delta.Config.ps1 and Delta.Docker.ps1 first.
#
# Assessment references: A§2.1 (the image migrates its own schema), A§3
# (services), A§6 (DELTA container), A§7 (PostgreSQL + PostGIS), A§8 (NGINX),
# A§9 (persistence, layout, the empty-data trap), A§16.2 (depends_on),
# A§18 (digest pinning), A§21 (logging), A§22 (failure behaviour),
# A§24 (secrets and ACLs), A§28 (rerun invariants).
#
# Two rules govern everything in this file:
#
#   1. The DELTA container's CMD is never overridden and its migrations are
#      never reimplemented here. The installer verifies; the container acts.
#   2. No code path issues `docker compose down -v`. That is the one command
#      that destroys the database.
# =============================================================================

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$Script:DeltaComposeProjectDefault = 'delta'

# Every directory the installation owns (A§9.1). Created, never deleted.
$Script:DeltaInstallDirectories = @(
    'nginx\conf.d'
    'certs'
    'uploads'
    'logs\delta'
    'logs\nginx'
    'logs\installer'
    'backups'
)

# Health budgets. The database is a cold initdb plus PostGIS; DELTA's cold
# first start loads the full schema and imports translations, measured at
# around 90 seconds, so its budget is deliberately generous (A§6, A§22).
$Script:DeltaDbHealthTimeoutSeconds    = 120
$Script:DeltaAppHealthTimeoutSeconds   = 300
$Script:DeltaNginxHealthTimeoutSeconds = 120

# The branch messages the image's own init script prints (A§2.1). Seeing one of
# them is necessary evidence that the migration step ran at all.
$Script:DeltaNewDatabaseMarker     = 'Initializing new database'
$Script:DeltaUpgradeDatabaseMarker = 'Applying upgrade migrations'

# ---------------------------------------------------------------------------
# Installation root
# ---------------------------------------------------------------------------

function New-DeltaInstallDirectories {
    <#
      Creates the installation root and its subdirectories, and refuses to
      touch a directory that is not this installer's (see
      Test-DeltaInstallRootOwned). Existing content is never removed - a rerun
      must be safe on a live installation.
    #>
    param([Parameter(Mandatory)][string]$InstallRoot)

    Write-Step 'Preparing the installation root'

    $ownership = Test-DeltaInstallRootOwned -InstallRoot $InstallRoot
    if (-not $ownership.IsOwned) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'The installation root cannot be used.'
        Write-Detail $ownership.Reason
        Write-Detail ''
        Write-Detail 'This installer will not adopt a directory it did not create. Choose an empty'
        Write-Detail 'or new directory, for example:  .\setup.ps1 -InstallRoot C:\DELTA-docker'
        return [PSCustomObject]@{ Succeeded = $false; Reason = $ownership.Reason; Created = @() }
    }

    $created = New-Object 'System.Collections.Generic.List[string]'
    try {
        if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $InstallRoot -Force
            $null = $created.Add($InstallRoot)
        }
        foreach ($relative in $Script:DeltaInstallDirectories) {
            $path = Join-Path -Path $InstallRoot -ChildPath $relative
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $path -Force
                $null = $created.Add($path)
            }
        }
    }
    catch {
        return [PSCustomObject]@{ Succeeded = $false; Reason = "Could not create the installation directories under '$InstallRoot': $($_.Exception.Message)"; Created = $created.ToArray() }
    }

    if ($created.Count -gt 0) {
        Write-Detail "Created $($created.Count) director$(if ($created.Count -eq 1) { 'y' } else { 'ies' }) under $InstallRoot"
    }
    else {
        Write-Detail "$InstallRoot already has the expected layout; nothing was created."
    }

    return [PSCustomObject]@{ Succeeded = $true; Reason = $null; Created = $created.ToArray() }
}

# ---------------------------------------------------------------------------
# Configuration generation
# ---------------------------------------------------------------------------

function New-DeltaDatabaseUrl {
    <#
      Builds the postgresql:// connection string, percent-encoding the username
      and password and nothing else - adapted from the reference installer's
      New-DatabaseUrl, which encodes those two components unconditionally
      because '/', '?' and '#' break connection-string parsing outright and the
      rest survive only on parser leniency.

      The host is always the Compose service name: the database has no
      published port and is reachable only from inside the project's network.
    #>
    param(
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory)][string]$DatabaseName,
        [string]$PostgresHost = 'db',
        [int]$Port = 5432
    )

    $encodedUser     = [System.Uri]::EscapeDataString($Username)
    $encodedPassword = [System.Uri]::EscapeDataString($Password)
    return "postgresql://${encodedUser}:${encodedPassword}@${PostgresHost}:${Port}/${DatabaseName}"
}

function Get-DeltaTemplatePath {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $path = Join-Path -Path $ScriptRoot -ChildPath "templates\$RelativePath"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Stop-Setup "Required template not found: $path. Run setup.ps1 from the directory it was distributed in, with its templates\ folder intact."
    }
    return $path
}

function Expand-DeltaTemplateRegions {
    <#
      Keeps or removes the #__IF_TLS__ / #__IF_NO_TLS__ regions of a template
      and strips the marker lines themselves, so the generated file contains
      only what applies to this installation.

      A marker-region template rather than two parallel template files: the
      HTTP and HTTPS server blocks share their proxy configuration almost
      exactly, and two files would drift apart the first time one of them was
      corrected.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][bool]$TlsEnabled
    )

    $keep   = if ($TlsEnabled) { 'TLS' }    else { 'NO_TLS' }
    $remove = if ($TlsEnabled) { 'NO_TLS' } else { 'TLS' }

    # ${remove} and ${keep}, not $remove/$keep: an underscore is a valid
    # variable-name character, so "$remove__" would be read as a variable
    # called remove__ and expand to nothing.
    $pattern = "(?ms)^[ \t]*#__IF_${remove}__[ \t]*\r?\n.*?^[ \t]*#__END_${remove}__[ \t]*\r?\n"
    $result = [regex]::Replace($Text, $pattern, '')

    # ...then drop the surviving region's own marker lines.
    $result = [regex]::Replace($result, "(?m)^[ \t]*#__(IF|END)_${keep}__[ \t]*\r?\n", '')

    return $result
}

function New-DeltaEnvironmentFile {
    <#
      Generates <InstallRoot>\.env from templates\env.template.

      On a first run the template is copied and every __GENERATE__ placeholder
      is replaced with a real value. On a rerun the existing file is the source
      of truth: comments, ordering and hand edits survive, and any value that is
      already set is kept. Secrets are generated exactly once - regenerating
      SESSION_SECRET would invalidate every live session, and regenerating
      POSTGRES_PASSWORD would break authentication against a cluster that was
      already initialised with the old one.

      DATABASE_URL is always recomputed from the parts, because it is derived
      data rather than an independent setting.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Network,
        [string]$ComposeProject,
        [string]$PgDataVolume
    )

    Write-Step 'Generating configuration'

    $envPath = Join-Path -Path $InstallRoot -ChildPath '.env'
    $isFirstRun = -not (Test-Path -LiteralPath $envPath -PathType Leaf)

    if ($isFirstRun) {
        $templatePath = Get-DeltaTemplatePath -ScriptRoot $ScriptRoot -RelativePath 'env.template'
        $templateText = [System.IO.File]::ReadAllText($templatePath, (New-Object System.Text.UTF8Encoding($false)))
        Write-DeltaFileAtomic -Path $envPath -Content ($templateText -replace "`r`n", "`n")
        Protect-DeltaSecretFile -Path $envPath
        Write-Detail "Created $envPath from templates\env.template"
    }
    else {
        Write-Detail "$envPath already exists; existing values are kept and secrets are not regenerated."
        $null = Backup-DeltaEnvFile -Path $envPath
    }

    $existing = Read-DeltaEnvFile -Path $envPath
    if ($existing.Malformed.Count -gt 0) {
        foreach ($bad in $existing.Malformed) {
            Write-DeltaWarning "$envPath line $($bad.LineNumber): $($bad.Reason)"
        }
    }

    $resolve = {
        param($key, $fallback)
        $value = $null
        if ($existing.Entries.Contains($key)) { $value = [string]$existing.Entries[$key] }
        if ([string]::IsNullOrWhiteSpace($value) -or $value -eq '__GENERATE__') { return $fallback }
        return $value
    }

    $values = [ordered]@{}

    # Secrets: generated once, then preserved for the life of the installation.
    $postgresPassword = & $resolve 'POSTGRES_PASSWORD' $null
    if (-not $postgresPassword) {
        $postgresPassword = New-DeltaPassword -Length 32
        # Worded without the word "password" on purpose: the acceptance check
        # for secret leakage greps transcripts case-insensitively for
        # SESSION_SECRET|PASSWORD|postgresql://, and prose that trips it turns
        # a useful tripwire into noise everyone learns to ignore.
        Write-Detail 'Generated a new database credential.'
    }
    $deltaDbPassword = & $resolve 'DELTA_DB_PASSWORD' $null
    if (-not $deltaDbPassword) { $deltaDbPassword = $postgresPassword }

    $sessionSecret = & $resolve 'SESSION_SECRET' $null
    if (-not $sessionSecret) {
        $sessionSecret = New-DeltaSecret -ByteLength 48
        Write-Detail 'Generated a new session secret.'
    }

    Register-DeltaSecretValue -Value $postgresPassword
    Register-DeltaSecretValue -Value $deltaDbPassword
    Register-DeltaSecretValue -Value $sessionSecret

    $postgresUser = & $resolve 'POSTGRES_USER' 'delta'
    $postgresDb   = & $resolve 'POSTGRES_DB'   'delta'

    $databaseUrl = New-DeltaDatabaseUrl -Username $postgresUser -Password $postgresPassword -DatabaseName $postgresDb
    Register-DeltaSecretValue -Value $databaseUrl

    # Ports, hostname, TLS state and the public URL are all settled by the
    # network stage before generation runs, and PUBLIC_URL comes from the one
    # URL helper - never formatted here.
    $port      = "$($Network.HttpPort)"
    $publicUrl = $Network.PublicUrl

    # The project name and the volume name identify a live installation's
    # containers and its data, so they get their own precedence rule.
    #
    # On a first run a supplied name wins outright: the template has just been
    # copied into place, so the value sitting in .env is the template's default
    # rather than anybody's decision, and letting it win means a second
    # installation silently adopts the first one's project and data volume.
    # Measured the hard way - a fresh install on this host took over the
    # existing project's containers and then failed authentication against its
    # already-initialised cluster.
    #
    # On a rerun the existing value always wins, even against a parameter: by
    # then it is the identity of a running installation, not a default.
    $projectName = if ($isFirstRun -and $ComposeProject) { $ComposeProject } else { & $resolve 'COMPOSE_PROJECT_NAME' $(if ($ComposeProject) { $ComposeProject } else { $Script:DeltaComposeProjectDefault }) }
    $volumeName  = if ($isFirstRun -and $PgDataVolume)   { $PgDataVolume }   else { & $resolve 'PGDATA_VOLUME'        $(if ($PgDataVolume)   { $PgDataVolume }   else { 'delta_pgdata' }) }

    $values['COMPOSE_PROJECT_NAME'] = $projectName
    $values['DELTA_IMAGE']          = & $resolve 'DELTA_IMAGE'     'ghcr.io/preventionweb/delta-country:prod-latest'
    $values['DELTA_IMAGE_TAG']      = & $resolve 'DELTA_IMAGE_TAG' 'prod-latest'
    $values['DB_IMAGE']             = & $resolve 'DB_IMAGE'        'postgis/postgis:17-3.5'
    $values['NGINX_IMAGE']          = & $resolve 'NGINX_IMAGE'     'nginx:1.29-alpine'
    $values['PGDATA_VOLUME']        = $volumeName
    $values['HTTP_PORT']            = $port
    $values['HTTPS_PORT']           = "$($Network.HttpsPort)"
    $values['TLS_ENABLED']          = if ($Network.TlsEnabled) { 'true' } else { 'false' }
    $values['TLS_MODE']             = $Network.TlsMode
    $values['DELTA_HOSTNAME']       = $Network.HostName
    $values['POSTGRES_USER']        = $postgresUser
    $values['POSTGRES_DB']          = $postgresDb
    $values['POSTGRES_PASSWORD']    = $postgresPassword
    $values['DELTA_DB_PASSWORD']    = $deltaDbPassword
    $values['DATABASE_URL']         = $databaseUrl
    $values['SESSION_SECRET']       = $sessionSecret
    $values['NODE_ENV']             = 'production'
    $values['LOG_DIR']              = '/delta/logs'
    $values['LOG_LEVEL']            = & $resolve 'LOG_LEVEL' 'info'
    $values['LOG_RETENTION_DAYS']   = & $resolve 'LOG_RETENTION_DAYS' '30'
    $values['PUBLIC_URL']           = $publicUrl

    Set-DeltaEnvValues -Path $envPath -Values $values

    Write-Detail "Wrote $($values.Count) settings to $envPath (permissions restricted to Administrators and SYSTEM)."

    return [PSCustomObject]@{
        Path           = $envPath
        ProjectName    = $values['COMPOSE_PROJECT_NAME']
        HttpPort       = $port
        HttpsPort      = $values['HTTPS_PORT']
        TlsEnabled     = $Network.TlsEnabled
        TlsMode        = $Network.TlsMode
        HostName       = $Network.HostName
        PublicUrl      = $publicUrl
        PostgresUser   = $postgresUser
        PostgresDb     = $postgresDb
        PgDataVolume   = $values['PGDATA_VOLUME']
        DeltaImage     = $values['DELTA_IMAGE']
        DeltaImageTag  = $values['DELTA_IMAGE_TAG']
        DbImage        = $values['DB_IMAGE']
        NginxImage     = $values['NGINX_IMAGE']
        IsFirstRun     = $isFirstRun
    }
}

function Get-DeltaStackConfiguration {
    <#
      Reconstructs the configuration object from an installation that already
      exists, by reading .env - without generating, rewriting or regenerating
      anything.

      New-DeltaEnvironmentFile produces this shape as a by-product of writing
      the file. Operations that only need to *act* on an installation - "start
      DELTA", and the management operations after it - must not call that
      function to obtain it: writing .env to find out what is in .env would
      make reading the configuration a mutating act, on the one file that holds
      every secret. So this reads, and returns the same shape.

      Returns $null when there is no .env to read; the caller decides what an
      unconfigured installation means.
    #>
    param([Parameter(Mandatory)][string]$InstallRoot)

    $envPath = Join-Path -Path $InstallRoot -ChildPath '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        return $null
    }

    $value = {
        param($Key, $Default)
        $read = Get-DeltaEnvValue -Path $envPath -Key $Key
        if ($null -eq $read -or $read -eq '') { return $Default }
        return $read
    }

    # Registered so that anything echoing them - a compose warning, a psql
    # error - is redacted in the log, exactly as on the generation path.
    foreach ($key in @('POSTGRES_PASSWORD', 'DELTA_DB_PASSWORD', 'SESSION_SECRET')) {
        Register-DeltaSecretValue -Value (Get-DeltaEnvValue -Path $envPath -Key $key)
    }

    $httpPort  = 0
    $httpsPort = 0
    [void][int]::TryParse([string](& $value 'HTTP_PORT' '80'),   [ref]$httpPort)
    [void][int]::TryParse([string](& $value 'HTTPS_PORT' '443'), [ref]$httpsPort)

    return [PSCustomObject]@{
        Path          = $envPath
        ProjectName   = & $value 'COMPOSE_PROJECT_NAME' $Script:DeltaComposeProjectDefault
        HttpPort      = $httpPort
        HttpsPort     = $httpsPort
        TlsEnabled    = ((& $value 'TLS_ENABLED' 'false') -eq 'true')
        TlsMode       = & $value 'TLS_MODE' 'none'
        HostName      = & $value 'DELTA_HOSTNAME' 'localhost'
        PublicUrl     = & $value 'PUBLIC_URL' ''
        PostgresUser  = & $value 'POSTGRES_USER' 'delta'
        PostgresDb    = & $value 'POSTGRES_DB' 'delta'
        PgDataVolume  = & $value 'PGDATA_VOLUME' 'delta_pgdata'
        DeltaImage    = & $value 'DELTA_IMAGE' ''
        DeltaImageTag = & $value 'DELTA_IMAGE_TAG' ''
        DbImage       = & $value 'DB_IMAGE' 'postgis/postgis:17-3.5'
        NginxImage    = & $value 'NGINX_IMAGE' 'nginx:1.29-alpine'
        IsFirstRun    = $false
    }
}

function New-DeltaComposeFile {
    <#
      Renders templates\docker-compose.yml.template into
      <InstallRoot>\docker-compose.yml. The template needs no substitution -
      every value it varies on is a ${...} Compose reads from .env at run time,
      which is what keeps the generated file reproducible from .env plus the
      template.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [bool]$TlsEnabled = $false
    )

    $templatePath = Get-DeltaTemplatePath -ScriptRoot $ScriptRoot -RelativePath 'docker-compose.yml.template'
    $target = Join-Path -Path $InstallRoot -ChildPath 'docker-compose.yml'
    $text = [System.IO.File]::ReadAllText($templatePath, (New-Object System.Text.UTF8Encoding($false)))
    $text = Expand-DeltaTemplateRegions -Text $text -TlsEnabled $TlsEnabled
    Write-DeltaFileAtomic -Path $target -Content ($text -replace "`r`n", "`n")
    Write-Detail "Wrote $target"
    return $target
}

function New-DeltaNginxConfiguration {
    <#
      Renders the NGINX site configuration into
      <InstallRoot>\nginx\conf.d\delta.conf, selecting the HTTP-only or the
      redirect-plus-TLS shape.

      Returns the previous contents alongside the path, so a caller can put
      them back if `nginx -t` rejects what was just written - the rule is that
      an invalid configuration never stays in the live path.

      server_name is the configured hostname, and both server blocks are also
      default_server, so the installation still answers when it is reached by
      IP or by a name nobody configured.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Network
    )

    $templatePath = Get-DeltaTemplatePath -ScriptRoot $ScriptRoot -RelativePath 'nginx\delta.conf.template'
    $target = Join-Path -Path $InstallRoot -ChildPath 'nginx\conf.d\delta.conf'

    $previous = $null
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $previous = [System.IO.File]::ReadAllText($target, (New-Object System.Text.UTF8Encoding($false)))
    }

    $serverName = if ($Network.HostName) { $Network.HostName } else { '_' }

    $text = [System.IO.File]::ReadAllText($templatePath, (New-Object System.Text.UTF8Encoding($false)))
    $text = Expand-DeltaTemplateRegions -Text $text -TlsEnabled ([bool]$Network.TlsEnabled)
    $text = $text.Replace('__DELTA_SERVER_NAME__', $serverName)

    if ($Network.TlsEnabled) {
        # $host keeps the redirect correct for a hostname or a bare IP; the
        # port comes from the single URL helper, which omits 443 and includes
        # anything else.
        $redirectPrefix = (Get-DeltaPublicUrl -Scheme 'https' -HostName '$host' -Port ([int]$Network.HttpsPort))
        $text = $text.Replace('__DELTA_HTTPS_REDIRECT_PREFIX__', $redirectPrefix)
        $text = $text.Replace('__DELTA_CERT_FILE__', $Network.CertificateFile)
        $text = $text.Replace('__DELTA_KEY_FILE__', $Network.KeyFile)
    }

    Write-DeltaFileAtomic -Path $target -Content ($text -replace "`r`n", "`n")
    Write-Detail "Wrote $target"

    return [PSCustomObject]@{ Path = $target; Previous = $previous }
}

# ---------------------------------------------------------------------------
# Compose invocation
#
# Every Compose call goes through here, and every call carries an explicit
# project name, project directory, compose file and env file. That is what
# keeps this installer's operations scoped to its own project on a host that
# runs other Compose stacks: nothing here can act on a container, network or
# volume belonging to anything else.
# ---------------------------------------------------------------------------

function Invoke-DeltaCompose {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 600
    )

    $composeFile = Join-Path -Path $InstallRoot -ChildPath 'docker-compose.yml'
    $envFile     = Join-Path -Path $InstallRoot -ChildPath '.env'

    $full = @(
        'compose'
        '--project-name', $ProjectName
        '--project-directory', $InstallRoot
        '--file', $composeFile
        '--env-file', $envFile
    ) + $Arguments

    return (Invoke-DeltaDockerCommand -Arguments $full -TimeoutSeconds $TimeoutSeconds)
}

function Test-DeltaComposeConfiguration {
    <#
      `docker compose config` renders the file with every variable substituted
      and validates the result. It is the cheapest possible proof that .env and
      the template agree before anything is pulled or started.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName
    )

    Write-Step 'Validating the generated Compose file'
    $capture = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @('config') -TimeoutSeconds 120

    if ($capture.ExitCode -ne 0) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'The generated docker-compose.yml is not valid.'
        if ($capture.StdErr) { Write-Detail $capture.StdErr }
        return [PSCustomObject]@{ Succeeded = $false; Rendered = $null; Reason = $capture.StdErr }
    }

    Write-Detail 'docker compose config validates.'
    return [PSCustomObject]@{ Succeeded = $true; Rendered = $capture.StdOut; Reason = $null }
}

function Test-DeltaComposeRestartPolicy {
    <#
      Reads the restart policy out of the rendered Compose model and confirms
      every service carries the expected one.

      It reads the model rather than the file: `docker compose config` is what
      Compose itself will act on, after interpolation and after any override,
      and it is the only artefact whose answer is not a guess about how the
      template was rendered.

      This verifies; it never sets. The policy belongs to
      templates\docker-compose.yml.template, and a policy patched into the
      generated file here would be silently lost the next time the file was
      regenerated - which is exactly the failure mode that makes a reboot claim
      untrue later (A§16.2).
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$Expected = 'unless-stopped'
    )

    $result = [PSCustomObject]@{
        Succeeded = $false
        Policy    = $Expected
        Services  = @()
        Reason    = $null
    }

    $capture = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @('config', '--format', 'json') -TimeoutSeconds 120
    if ($capture.ExitCode -ne 0 -or -not $capture.StdOut) {
        $result.Reason = "The Compose model could not be rendered: $((($capture.StdErr + ' ' + $capture.StdOut)).Trim())"
        return $result
    }

    $model = $null
    try { $model = $capture.StdOut | ConvertFrom-Json }
    catch {
        $result.Reason = "The Compose model could not be parsed: $($_.Exception.Message)"
        return $result
    }

    $services = New-Object 'System.Collections.Generic.List[object]'
    foreach ($property in $model.services.PSObject.Properties) {
        $policy = $null
        if (@($property.Value.PSObject.Properties.Name) -contains 'restart') { $policy = [string]$property.Value.restart }
        $null = $services.Add([PSCustomObject]@{ Service = $property.Name; Restart = $policy })
    }
    $result.Services = $services.ToArray()

    if ($result.Services.Count -eq 0) {
        $result.Reason = 'The rendered Compose model declares no services.'
        return $result
    }

    $wrong = @($result.Services | Where-Object { $_.Restart -ne $Expected })
    if ($wrong.Count -gt 0) {
        $result.Reason = "These services do not use restart: ${Expected} - " +
            (($wrong | ForEach-Object { "$($_.Service)=$(if ($_.Restart) { $_.Restart } else { '(none)' })" }) -join ', ') +
            ". Fix it in templates\docker-compose.yml.template and regenerate, not in the generated file."
        return $result
    }

    $result.Succeeded = $true
    return $result
}

function Test-DeltaComposeProjectConflict {
    <#
      Whether containers already exist under this project name that were
      created from a different compose file - that is, whether this project
      name is already another installation's identity.

      Containers this installation created are recognised by their
      com.docker.compose.project.config_files label pointing at this
      installation's own compose file.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName
    )

    $composeFile = Join-Path -Path $InstallRoot -ChildPath 'docker-compose.yml'
    $result = [PSCustomObject]@{ HasConflict = $false; Reason = $null; Containers = @() }

    $foreign = New-Object 'System.Collections.Generic.List[string]'
    foreach ($service in (Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $ProjectName)) {
        if (-not $service.Name) { continue }
        if (-not (Test-DeltaContainerFromInstallation -ContainerName $service.Name -ComposeFile $composeFile)) {
            $null = $foreign.Add($service.Name)
        }
    }

    if ($foreign.Count -gt 0) {
        $result.HasConflict = $true
        $result.Containers = $foreign.ToArray()
        $result.Reason = "Compose project '$ProjectName' already contains container(s) $($foreign -join ', ') created from a different compose file. This installation would recreate them against its own configuration."
    }
    return $result
}

function Get-DeltaComposeServiceStatus {
    <#
      One `docker compose ps` call returns the state and health of every
      service. Compose has emitted this as both a JSON array and as one object
      per line depending on version, so both are accepted rather than pinning
      the parser to whichever this host happens to ship.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName
    )

    $capture = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @('ps', '--all', '--format', 'json') -TimeoutSeconds 120
    $services = New-Object 'System.Collections.Generic.List[object]'

    if ($capture.ExitCode -ne 0 -or -not $capture.StdOut) {
        return $services.ToArray()
    }

    $objects = @()
    $text = $capture.StdOut.Trim()
    try {
        $objects = @($text | ConvertFrom-Json)
    }
    catch {
        foreach ($line in ($text -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            try { $objects += ($line | ConvertFrom-Json) } catch { }
        }
    }

    foreach ($object in $objects) {
        if (-not $object) { continue }
        $health = ''
        if ($object.PSObject.Properties.Name -contains 'Health') { $health = [string]$object.Health }
        $status = ''
        if ($object.PSObject.Properties.Name -contains 'Status') { $status = [string]$object.Status }
        if (-not $health -and $status -match '\((healthy|unhealthy|starting|health: starting)\)') {
            $health = $Matches[1] -replace 'health: ', ''
        }
        $null = $services.Add([PSCustomObject]@{
            Service = [string]$object.Service
            Name    = [string]$object.Name
            State   = [string]$object.State
            Status  = $status
            Health  = $health
            Ports   = if ($object.PSObject.Properties.Name -contains 'Publishers') { $object.Publishers } else { $null }
        })
    }

    return $services.ToArray()
}

function Wait-DeltaServiceHealthy {
    <#
      Waits for one service to report healthy. A container that has exited is
      reported immediately rather than waited on to the end of the budget - the
      interesting failure is almost always visible in its logs within seconds.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$Service,
        [int]$TimeoutSeconds = 120
    )

    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $lastReport = $started
    $last = $null

    while ((Get-Date) -lt $deadline) {
        $status = Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $ProjectName
        $last = $status | Where-Object { $_.Service -eq $Service } | Select-Object -First 1

        if ($last) {
            if ($last.Health -eq 'healthy') {
                $elapsed = [int]((Get-Date) - $started).TotalSeconds
                Write-Detail "[ ok ]     $Service healthy after $elapsed s"
                return [PSCustomObject]@{ Succeeded = $true; Status = $last; ElapsedSeconds = $elapsed }
            }
            if ($last.State -eq 'exited' -or $last.State -eq 'dead') {
                return [PSCustomObject]@{ Succeeded = $false; Status = $last; ElapsedSeconds = [int]((Get-Date) - $started).TotalSeconds }
            }
        }

        if (((Get-Date) - $lastReport).TotalSeconds -ge 15) {
            $lastReport = Get-Date
            $elapsed = [int]((Get-Date) - $started).TotalSeconds
            $where = if ($last) { "state $($last.State), health $($last.Health)" } else { 'container not created yet' }
            Write-Detail "Waiting for $Service ($elapsed s; $where)"
        }
        Start-Sleep -Seconds 3
    }

    return [PSCustomObject]@{ Succeeded = $false; Status = $last; ElapsedSeconds = [int]((Get-Date) - $started).TotalSeconds }
}

function Show-DeltaServiceLogs {
    <#
      Surfaces a failing service's own output. A health timeout with no logs is
      not a diagnostic (A§22).
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$Service,
        [int]$Tail = 40
    )

    $capture = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @('logs', '--no-color', '--tail', "$Tail", $Service) -TimeoutSeconds 120
    $text = (($capture.StdOut + "`n" + $capture.StdErr)).Trim()
    if (-not $text) { return }

    Write-Detail ''
    Write-Detail "Last $Tail lines from ${Service}:"
    foreach ($line in ($text -split "`r?`n")) {
        Write-Detail "  $line"
    }
}

function Invoke-DeltaPsql {
    <#
      Runs psql inside the db container. Always -T: without it there is no TTY
      suppression and the stream is corrupted.

      The password is passed through the process environment with `exec -e`,
      never on a command line where it would be visible in the process list.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query,
        [switch]$TuplesOnly,
        [int]$TimeoutSeconds = 120
    )

    $arguments = @('exec', '-T', 'db', 'psql', '-U', $User, '-d', $Database)
    if ($TuplesOnly) { $arguments += @('-tA') }
    $arguments += @('-c', $Query)

    return (Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments $arguments -TimeoutSeconds $TimeoutSeconds)
}

# ---------------------------------------------------------------------------
# Images: pull, classify failures, pin digests
# ---------------------------------------------------------------------------

function Get-DeltaPullFailureExplanation {
    <#
      Turns a pull failure into something the operator can act on (A§22).
      GHCR is anonymous for this image, so a 401 is almost never a credential
      problem - it is an intercepting proxy, and saying so saves an hour.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ErrorText)

    $text = $ErrorText
    if ($text -match '(?i)no such host|dial tcp.*lookup|temporary failure in name resolution') {
        return 'DNS resolution failed. The host cannot resolve the registry name - check DNS settings and whether this network requires a proxy.'
    }
    if ($text -match '(?i)proxyconnect|proxy') {
        return 'The connection went through an HTTP proxy and failed. Configure Docker Desktop''s proxy settings (Settings > Resources > Proxies) and try again.'
    }
    if ($text -match '(?i)x509|certificate signed by unknown authority|tls') {
        return 'TLS verification failed. Something is intercepting HTTPS to the registry - usually a corporate TLS-inspection proxy whose CA certificate Docker does not trust.'
    }
    if ($text -match '(?i)401 unauthorized|denied|403 forbidden') {
        return 'The registry returned 401/403. This image pulls anonymously, so this almost certainly means a proxy is intercepting the request rather than a credential problem.'
    }
    if ($text -match '(?i)no space left on device') {
        return 'The Docker disk is full. Free space in the Docker Desktop disk image, then try again.'
    }
    if ($text -match '(?i)manifest unknown|not found') {
        return 'The registry does not have that image or tag. Check DELTA_IMAGE and DELTA_IMAGE_TAG in .env.'
    }
    return 'The pull failed for a reason this installer does not recognise. The registry output above is verbatim.'
}

function Invoke-DeltaImagePull {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ProjectName
    )

    Write-Step 'Pulling images'
    Write-Detail 'The first pull downloads roughly 700 MB and can take several minutes.'

    $capture = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $ProjectName -Arguments @('pull') -TimeoutSeconds 3600

    if ($capture.ExitCode -ne 0) {
        $text = (($capture.StdErr + "`n" + $capture.StdOut)).Trim()
        Write-DeltaFailure ''
        Write-DeltaFailure 'Pulling the images failed.'
        if ($text) {
            foreach ($line in ($text -split "`r?`n" | Select-Object -Last 15)) { Write-Detail "  $line" }
        }
        Write-Detail ''
        Write-Detail (Get-DeltaPullFailureExplanation -ErrorText $text)
        return [PSCustomObject]@{ Succeeded = $false; Reason = 'Image pull failed.' }
    }

    Write-Detail 'All three images are present locally.'
    return [PSCustomObject]@{ Succeeded = $true; Reason = $null }
}

function Get-DeltaImageDigest {
    <#
      The repository digest of a local image - what actually got pulled, as
      opposed to what the tag pointed at when it was pulled.
    #>
    param([Parameter(Mandatory)][string]$Image)

    $capture = Invoke-DeltaDockerCommand -Arguments @('image', 'inspect', $Image, '--format', '{{index .RepoDigests 0}}') -TimeoutSeconds 60
    if ($capture.ExitCode -ne 0 -or -not $capture.StdOut) { return $null }

    $reference = ($capture.StdOut -split "`r?`n" | Select-Object -First 1).Trim()
    if ($reference -match '@(sha256:[0-9a-f]{64})$') {
        return [PSCustomObject]@{ Reference = $reference; Digest = $Matches[1] }
    }
    return $null
}

function Set-DeltaImagePins {
    <#
      Freezes exactly what will run.

      DELTA is pinned by digest in .env, because prod-latest moves and
      recreating that container *is* a schema migration - a restart or repair
      must never silently migrate. The database and NGINX images stay on their
      pinned tags, which are deliberate choices that change rarely, and their
      resolved digests are recorded in the state file so "what is running?" has
      an exact answer for all three.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration
    )

    Write-Step 'Pinning images'

    $deltaDigest = Get-DeltaImageDigest -Image $Configuration.DeltaImage
    $dbDigest    = Get-DeltaImageDigest -Image $Configuration.DbImage
    $nginxDigest = Get-DeltaImageDigest -Image $Configuration.NginxImage

    $result = [PSCustomObject]@{
        DeltaImage  = $Configuration.DeltaImage
        DeltaDigest = if ($deltaDigest) { $deltaDigest.Digest } else { $null }
        DbDigest    = if ($dbDigest)    { $dbDigest.Digest }    else { $null }
        NginxDigest = if ($nginxDigest) { $nginxDigest.Digest } else { $null }
    }

    if ($deltaDigest) {
        if ($Configuration.DeltaImage -ne $deltaDigest.Reference) {
            Set-DeltaEnvValue -Path (Join-Path $InstallRoot '.env') -Key 'DELTA_IMAGE' -Value $deltaDigest.Reference
            Write-Detail "DELTA_IMAGE pinned to $($deltaDigest.Reference)"
        }
        else {
            Write-Detail "DELTA_IMAGE already pinned to $($deltaDigest.Reference)"
        }
        $result.DeltaImage = $deltaDigest.Reference
    }
    else {
        Write-DeltaWarning 'Could not resolve a repository digest for the DELTA image; it stays pinned to its tag for now.'
    }

    Write-Detail "db    $($Configuration.DbImage) $($result.DbDigest)"
    Write-Detail "nginx $($Configuration.NginxImage) $($result.NginxDigest)"

    return $result
}

# ---------------------------------------------------------------------------
# Persistent data
# ---------------------------------------------------------------------------

function Get-DeltaVolumeState {
    <#
      Whether the PostgreSQL volume exists and, if so, which major version
      initialised it. PG_VERSION is read by a throwaway container using the
      database image that is already local, so no extra image is pulled and
      nothing is written.
    #>
    param(
        [Parameter(Mandatory)][string]$VolumeName,
        [Parameter(Mandatory)][string]$DbImage
    )

    $result = [PSCustomObject]@{ Name = $VolumeName; Exists = $false; PgVersion = $null; IsEmpty = $false }

    $inspect = Invoke-DeltaDockerCommand -Arguments @('volume', 'inspect', $VolumeName) -TimeoutSeconds 60
    if ($inspect.ExitCode -ne 0) { return $result }
    $result.Exists = $true

    $read = Invoke-DeltaDockerCommand -Arguments @(
        'run', '--rm',
        '-v', "${VolumeName}:/var/lib/postgresql/data:ro",
        '--entrypoint', 'sh',
        $DbImage,
        '-c', 'cat /var/lib/postgresql/data/PG_VERSION 2>/dev/null || echo __EMPTY__'
    ) -TimeoutSeconds 180

    if ($read.ExitCode -eq 0 -and $read.StdOut) {
        $value = ($read.StdOut -split "`r?`n" | Select-Object -First 1).Trim()
        if ($value -eq '__EMPTY__' -or -not $value) { $result.IsEmpty = $true }
        else { $result.PgVersion = $value }
    }

    return $result
}

function Test-DeltaPersistentDataPrecheck {
    <#
      The check that stands between a registered installation and the worst
      outcome in the design (A§9.4): if the data volume is missing or empty,
      `up` would let PostgreSQL initialise a brand-new cluster, DELTA would see
      an empty database, create a fresh schema with seed data and a default
      administrator, and present as "DELTA works, but all the data is gone".

      So: once a run has recorded that this installation has a database, the
      volume must exist and its major version must match the configured image.
      Anything else stops the run. Missing containers are disposable; missing
      data is not.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration
    )

    $state = Read-DeltaInstallState -InstallRoot $InstallRoot
    $registeredVolume = $null
    $registeredMajor = $null
    if ($state.Exists -and $state.IsValid) {
        $properties = @($state.Data.PSObject.Properties.Name)
        if ($properties -contains 'pgDataVolume') { $registeredVolume = [string]$state.Data.pgDataVolume }
        if ($properties -contains 'postgresMajor') { $registeredMajor = [string]$state.Data.postgresMajor }
    }

    if (-not $registeredVolume) {
        # Nothing has recorded a database for this installation yet, so there is
        # no data that could be missing.
        return [PSCustomObject]@{ Succeeded = $true; Reason = 'No database has been initialised for this installation yet.'; Volume = $null }
    }

    Write-Step 'Checking persistent data'
    $volume = Get-DeltaVolumeState -VolumeName $registeredVolume -DbImage $Configuration.DbImage

    if (-not $volume.Exists) {
        return [PSCustomObject]@{
            Succeeded = $false
            Volume    = $volume
            Reason    = "This installation is registered as having a database in the Docker volume '$registeredVolume', but that volume does not exist. Starting the stack now would initialise an empty cluster and DELTA would build a brand-new schema - the installation would come up looking healthy with all data gone. Nothing was started. Restore the volume, or restore a pg_dump backup into a new installation."
        }
    }
    if ($volume.IsEmpty) {
        return [PSCustomObject]@{
            Succeeded = $false
            Volume    = $volume
            Reason    = "The Docker volume '$registeredVolume' exists but contains no PostgreSQL data directory. Starting the stack now would initialise an empty cluster over a registered installation. Nothing was started."
        }
    }
    if ($registeredMajor -and $volume.PgVersion -and $volume.PgVersion -ne $registeredMajor) {
        return [PSCustomObject]@{
            Succeeded = $false
            Volume    = $volume
            Reason    = "The Docker volume '$registeredVolume' holds a PostgreSQL $($volume.PgVersion) data directory, but this installation is configured for PostgreSQL $registeredMajor. PostgreSQL will not start against a data directory from a different major version, and there is no in-place upgrade path in this design. Nothing was started."
        }
    }

    Write-Detail "[ ok ]     $registeredVolume present, PostgreSQL $($volume.PgVersion) data directory"
    return [PSCustomObject]@{ Succeeded = $true; Reason = $null; Volume = $volume }
}

# ---------------------------------------------------------------------------
# Database and migration verification
# ---------------------------------------------------------------------------

function Get-DeltaDatabaseFacts {
    <#
      What the database actually is, read from the running container: server
      version, PostGIS version, and the installed extensions.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration
    )

    $facts = [PSCustomObject]@{
        ServerVersion  = $null
        PostgresMajor  = $null
        PostgisVersion = $null
        Extensions     = @()
    }

    $version = Invoke-DeltaPsql -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -User $Configuration.PostgresUser -Database $Configuration.PostgresDb -Query 'select current_setting(''server_version'');' -TuplesOnly
    if ($version.ExitCode -eq 0 -and $version.StdOut) {
        $facts.ServerVersion = ($version.StdOut -split "`r?`n" | Select-Object -First 1).Trim()
        if ($facts.ServerVersion -match '^(\d+)') { $facts.PostgresMajor = $Matches[1] }
    }

    $postgis = Invoke-DeltaPsql -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -User $Configuration.PostgresUser -Database $Configuration.PostgresDb -Query 'select extversion from pg_extension where extname = ''postgis'';' -TuplesOnly
    if ($postgis.ExitCode -eq 0 -and $postgis.StdOut) {
        $facts.PostgisVersion = ($postgis.StdOut -split "`r?`n" | Select-Object -First 1).Trim()
    }

    $extensions = Invoke-DeltaPsql -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -User $Configuration.PostgresUser -Database $Configuration.PostgresDb -Query 'select extname from pg_extension order by 1;' -TuplesOnly
    if ($extensions.ExitCode -eq 0 -and $extensions.StdOut) {
        $facts.Extensions = @($extensions.StdOut -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    return $facts
}

function Test-DeltaMigrationOutcome {
    <#
      Verifies that the container's own initialisation actually succeeded.

      This exists because the image's start command runs psql WITHOUT
      ON_ERROR_STOP: a migration can fail halfway, psql still exits 0, the
      application still starts, and the container still reports healthy on a
      half-migrated schema. Container health is not evidence, so this checks
      three independent things:

        1. the log shows one of the two branch messages, so the step ran at all;
        2. the log contains no psql errors;
        3. dts_system_info.version_no can actually be read back.

      All three must hold. Any of them failing stops the installation - a
      reachable stack on a broken schema is worse than a stopped one.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration
    )

    Write-Step 'Verifying database initialisation'

    $result = [PSCustomObject]@{
        Succeeded     = $false
        Branch        = $null
        Errors        = @()
        SchemaVersion = $null
        TableCount    = $null
        Reason        = $null
    }

    $logs = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Arguments @('logs', '--no-color', 'delta') -TimeoutSeconds 120
    $logText = (($logs.StdOut + "`n" + $logs.StdErr))
    $logLines = @($logText -split "`r?`n")

    # `docker compose logs` returns everything the container has ever written,
    # and the container re-runs its init/migration command on every start. So
    # the question "which branch did it take" has to be asked of the *most
    # recent* start, not of the whole file: a container that initialised a
    # database once and has since been restarted a hundred times still carries
    # that first "Initializing new database" line, and reading from the top
    # would report it forever - and would also fail a perfectly good start
    # because of an error line from a run that happened days ago. Phase 6 makes
    # this routine: every reboot restarts the container.
    $branchIndex = -1
    for ($i = $logLines.Length - 1; $i -ge 0; $i--) {
        if ($logLines[$i] -match [regex]::Escape($Script:DeltaNewDatabaseMarker)) {
            $branchIndex = $i; $result.Branch = 'initialise'; break
        }
        if ($logLines[$i] -match [regex]::Escape($Script:DeltaUpgradeDatabaseMarker)) {
            $branchIndex = $i; $result.Branch = 'upgrade'; break
        }
    }

    # Errors from the current start only, for the same reason.
    $scanned = if ($branchIndex -ge 0) { $logLines[$branchIndex..($logLines.Length - 1)] } else { $logLines }
    $result.Errors = @($scanned | Where-Object { $_ -match '(?i)^\s*(delta\S*\s*\|\s*)?(psql:|ERROR:|FATAL:|PANIC:)' })

    $version = Invoke-DeltaPsql -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -User $Configuration.PostgresUser -Database $Configuration.PostgresDb -Query 'select version_no from dts_system_info;' -TuplesOnly
    if ($version.ExitCode -eq 0 -and $version.StdOut) {
        $result.SchemaVersion = ($version.StdOut -split "`r?`n" | Select-Object -First 1).Trim()
    }

    $tables = Invoke-DeltaPsql -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -User $Configuration.PostgresUser -Database $Configuration.PostgresDb -Query 'select count(*) from pg_tables where schemaname = ''public'';' -TuplesOnly
    if ($tables.ExitCode -eq 0 -and $tables.StdOut) {
        $result.TableCount = ($tables.StdOut -split "`r?`n" | Select-Object -First 1).Trim()
    }

    if (-not $result.Branch) {
        $result.Reason = 'The DELTA container log does not show either database branch message, so its initialisation step did not run as expected.'
    }
    elseif ($result.Errors.Count -gt 0) {
        $result.Reason = "The database initialisation reported $($result.Errors.Count) error line(s). Because the image runs psql without ON_ERROR_STOP, the container can look healthy on a half-migrated schema, so this is treated as a failure."
    }
    elseif (-not $result.SchemaVersion) {
        $result.Reason = 'dts_system_info.version_no could not be read, so the schema is not in a usable state even though the container may be running.'
    }
    else {
        $result.Succeeded = $true
    }

    if ($result.Succeeded) {
        Write-Detail "[ ok ]     branch: $($result.Branch); schema version $($result.SchemaVersion); $($result.TableCount) tables in public"
    }

    return $result
}

# ---------------------------------------------------------------------------
# HTTP verification
# ---------------------------------------------------------------------------

function Test-DeltaHttpEndpoint {
    <#
      A real request through NGINX. HttpWebRequest rather than
      Invoke-WebRequest so a 3xx or 4xx is a status code to report rather than
      a terminating error, and so redirects are not followed silently - the
      HTTP->HTTPS redirect has to be observable, not swallowed.

      For an HTTPS endpoint the certificate the server presents is captured and
      returned. Its trust is deliberately not enforced: this is a reachability
      check against a host that may legitimately be serving a self-signed
      certificate, and refusing to look would mean the installer could not
      verify the very certificate it just installed. What it must never do is
      leave that relaxed check in place afterwards, so the previous callback is
      restored in a finally block.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSeconds = 30
    )

    $result = [PSCustomObject]@{
        Url                 = $Url
        StatusCode          = 0
        Succeeded           = $false
        Error               = $null
        RedirectLocation    = $null
        PresentedCertificate = $null
    }

    $isHttps = $Url.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)
    $previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    $previousProtocol = [System.Net.ServicePointManager]::SecurityProtocol
    $captured = $null

    try {
        if ($isHttps) {
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
            # The certificate's native handle is released as soon as the
            # request completes, so its details are read here, inside the
            # callback, rather than kept for later - reading them afterwards
            # fails with "m_safeCertContext is an invalid handle".
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
                param($senderObject, $certificate, $chain, $errors)
                $script:DeltaLastPresentedCertificate = [PSCustomObject]@{
                    Subject    = $certificate.Subject
                    Issuer     = $certificate.Issuer
                    Thumbprint = $certificate.GetCertHashString()
                    NotAfter   = $certificate.GetExpirationDateString()
                    ChainValid = ($errors -eq [System.Net.Security.SslPolicyErrors]::None)
                }
                return $true
            }
        }

        try {
            $request = [System.Net.HttpWebRequest]::Create($Url)
            $request.Method = 'GET'
            $request.Timeout = $TimeoutSeconds * 1000
            $request.AllowAutoRedirect = $false
            $request.UserAgent = 'DELTA-installer'
            $response = $request.GetResponse()
            $result.StatusCode = [int]$response.StatusCode
            $result.RedirectLocation = $response.Headers['Location']
            $response.Close()
        }
        catch [System.Net.WebException] {
            if ($_.Exception.Response) {
                $result.StatusCode = [int]$_.Exception.Response.StatusCode
                $result.RedirectLocation = $_.Exception.Response.Headers['Location']
                $_.Exception.Response.Close()
            }
            else {
                $result.Error = $_.Exception.Message
            }
        }
        catch {
            $result.Error = $_.Exception.Message
        }

        $result.PresentedCertificate = $script:DeltaLastPresentedCertificate
    }
    finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
        [System.Net.ServicePointManager]::SecurityProtocol = $previousProtocol
        $script:DeltaLastPresentedCertificate = $null
    }

    $result.Succeeded = ($result.StatusCode -ge 200 -and $result.StatusCode -lt 400)
    return $result
}

# ---------------------------------------------------------------------------
# Ordered startup
# ---------------------------------------------------------------------------

function Start-DeltaStack {
    <#
      Brings the stack up one service at a time, db -> delta -> nginx, each
      gated on the previous one being healthy, and verifies the database
      initialisation between delta starting and nginx publishing a port.

      Compose's own depends_on would start them in this order anyway; doing it
      explicitly is what makes each step's failure attributable and lets the
      migration check sit in the middle of the sequence rather than after
      everything is already reachable.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [scriptblock]$SecurityBootstrap,
        [bool]$AllowPrompt = $true
    )

    $result = [PSCustomObject]@{
        Succeeded = $false
        Stage     = 'db'
        Reason    = $null
        Migration = $null
        Database  = $null
        Bootstrap = $null
        Http      = $null
        Redirect  = $null
    }

    # --- db ---------------------------------------------------------------
    Write-Step 'Starting PostgreSQL'
    $up = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Arguments @('up', '-d', 'db') -TimeoutSeconds 600
    if ($up.ExitCode -ne 0) {
        $result.Reason = "Starting the database container failed: $((($up.StdErr + ' ' + $up.StdOut)).Trim())"
        return $result
    }

    $health = Wait-DeltaServiceHealthy -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Service 'db' -TimeoutSeconds $Script:DeltaDbHealthTimeoutSeconds
    if (-not $health.Succeeded) {
        Write-DeltaFailure ''
        Write-DeltaFailure "PostgreSQL did not become healthy within $Script:DeltaDbHealthTimeoutSeconds seconds."
        Show-DeltaServiceLogs -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Service 'db'
        Write-Detail ''
        Write-Detail 'If the log shows an authentication failure, the password in .env no longer matches the one the'
        Write-Detail 'cluster was initialised with. Fix that with ALTER ROLE plus .env - never by deleting the volume,'
        Write-Detail 'which would destroy the database.'
        $result.Reason = 'The database did not become healthy.'
        return $result
    }

    $result.Database = Get-DeltaDatabaseFacts -InstallRoot $InstallRoot -Configuration $Configuration
    Write-Detail "[ ok ]     PostgreSQL $($result.Database.ServerVersion), PostGIS $($result.Database.PostgisVersion)"
    Write-Detail "[ ok ]     extensions: $($result.Database.Extensions -join ', ')"

    # --- delta ------------------------------------------------------------
    $result.Stage = 'delta'
    Write-Step 'Starting DELTA'
    Write-Detail 'The container initialises or migrates its own schema on start; a cold first start takes around 90 seconds.'

    $up = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Arguments @('up', '-d', 'delta') -TimeoutSeconds 900
    if ($up.ExitCode -ne 0) {
        $result.Reason = "Starting the DELTA container failed: $((($up.StdErr + ' ' + $up.StdOut)).Trim())"
        return $result
    }

    $health = Wait-DeltaServiceHealthy -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Service 'delta' -TimeoutSeconds $Script:DeltaAppHealthTimeoutSeconds
    if (-not $health.Succeeded) {
        Write-DeltaFailure ''
        Write-DeltaFailure "DELTA did not become healthy within $Script:DeltaAppHealthTimeoutSeconds seconds."
        Show-DeltaServiceLogs -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Service 'delta'
        $result.Reason = 'The DELTA container did not become healthy.'
        return $result
    }

    # --- migration --------------------------------------------------------
    $result.Stage = 'migration'
    $result.Migration = Test-DeltaMigrationOutcome -InstallRoot $InstallRoot -Configuration $Configuration
    if (-not $result.Migration.Succeeded) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'The database initialisation did not complete correctly.'
        Write-Detail $result.Migration.Reason
        if ($result.Migration.Errors.Count -gt 0) {
            Write-Detail ''
            Write-Detail 'Errors reported during initialisation:'
            foreach ($line in ($result.Migration.Errors | Select-Object -First 20)) { Write-Detail "  $line" }
        }
        Write-Detail ''
        Write-Detail 'Stopping here deliberately: the stack is not published, because a reachable DELTA on a'
        Write-Detail 'half-migrated schema is worse than one that is not running. The database has been left'
        Write-Detail 'exactly as it is so it can be inspected or restored.'
        $result.Reason = 'Database initialisation verification failed.'
        return $result
    }

    # --- security bootstrap ----------------------------------------------
    # This runs between "DELTA is healthy" and "NGINX publishes host ports",
    # and the ordering is the point: the schema seeds an administrator whose
    # bcrypt hash is published in a public image, so the installation must
    # never be externally reachable while that credential still works. Putting
    # the hook here rather than in the caller means the ordering cannot be got
    # wrong by a future caller that forgets it.
    if ($SecurityBootstrap) {
        $result.Stage = 'bootstrap'
        # Everything the callback needs is passed in, so it never depends on
        # what happens to be in scope where it runs.
        $result.Bootstrap = & $SecurityBootstrap $InstallRoot $Configuration $AllowPrompt
        if (-not $result.Bootstrap -or -not $result.Bootstrap.Succeeded) {
            Write-DeltaFailure ''
            Write-DeltaFailure 'The administrator account could not be secured.'
            if ($result.Bootstrap -and $result.Bootstrap.Reason) { Write-Detail $result.Bootstrap.Reason }
            Write-Detail ''
            Write-Detail 'NGINX has deliberately NOT been started, so the application is not reachable from'
            Write-Detail 'this machine or any other. The database and its data are untouched. Resolve the'
            Write-Detail 'problem above and run this installer again - it will resume from here.'
            $result.Reason = 'The administrator security bootstrap did not succeed.'
            return $result
        }
    }

    # --- nginx ------------------------------------------------------------
    $result.Stage = 'nginx'
    Write-Step 'Starting NGINX'
    $up = Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Arguments @('up', '-d', 'nginx') -TimeoutSeconds 600
    if ($up.ExitCode -ne 0) {
        $result.Reason = "Starting NGINX failed: $((($up.StdErr + ' ' + $up.StdOut)).Trim())"
        return $result
    }

    $health = Wait-DeltaServiceHealthy -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Service 'nginx' -TimeoutSeconds $Script:DeltaNginxHealthTimeoutSeconds
    if (-not $health.Succeeded) {
        Write-DeltaFailure ''
        Write-DeltaFailure "NGINX did not become healthy within $Script:DeltaNginxHealthTimeoutSeconds seconds."
        Show-DeltaServiceLogs -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Service 'nginx'
        $result.Reason = 'NGINX did not become healthy.'
        return $result
    }

    # --- end to end -------------------------------------------------------
    $result.Stage = 'verify'
    Write-Step 'Verifying the stack end to end'

    # The probe always goes to localhost, whatever hostname is configured: it
    # is testing that this machine's published port reaches DELTA, not that
    # DNS elsewhere resolves.
    $url = if ($Configuration.TlsEnabled) {
        "https://localhost:$($Configuration.HttpsPort)/"
    }
    else {
        "http://localhost:$($Configuration.HttpPort)/"
    }

    $result.Http = Test-DeltaHttpEndpoint -Url $url
    if (-not $result.Http.Succeeded) {
        Write-DeltaFailure ''
        Write-DeltaFailure "A request to $url did not succeed."
        if ($result.Http.Error) { Write-Detail $result.Http.Error }
        else { Write-Detail "HTTP $($result.Http.StatusCode)" }
        Show-DeltaServiceLogs -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Service 'nginx' -Tail 20
        $result.Reason = 'The stack is running but did not answer over HTTP.'
        return $result
    }

    Write-Detail "[ ok ]     GET $url returned $($result.Http.StatusCode)"
    if ($result.Http.PresentedCertificate) {
        Write-Detail "[ ok ]     served certificate $($result.Http.PresentedCertificate.Subject) (thumbprint $($result.Http.PresentedCertificate.Thumbprint))"
    }

    if ($Configuration.TlsEnabled) {
        $redirectUrl = "http://localhost:$($Configuration.HttpPort)/"
        $result.Redirect = Test-DeltaHttpEndpoint -Url $redirectUrl
        if ($result.Redirect.StatusCode -eq 301 -and $result.Redirect.RedirectLocation) {
            Write-Detail "[ ok ]     GET $redirectUrl returned 301 to $($result.Redirect.RedirectLocation)"
        }
        else {
            Write-DeltaWarning "The HTTP endpoint $redirectUrl returned $($result.Redirect.StatusCode) instead of a 301 redirect to HTTPS."
        }
    }

    $result.Succeeded = $true
    return $result
}

# ---------------------------------------------------------------------------
# Stage orchestration
# ---------------------------------------------------------------------------

function Invoke-DeltaStackStage {
    <#
      Creates the installation root, generates .env, docker-compose.yml and the
      NGINX configuration, pulls and pins the images, and brings the stack up
      in order with health gating and migration verification.

      Returns an outcome the caller maps to an exit code:

        ready      - the stack is running and answered over HTTP
        blocked    - something stopped the run; nothing destructive happened
        migration  - the database initialisation could not be verified

      Nothing here removes containers, images, networks or volumes, and no path
      reaches `docker compose down -v`.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [int]$HttpPort,
        [int]$HttpsPort,
        [string]$HostName,
        [string]$TlsMode,
        [string]$CertificatePath,
        [string]$CertificateKeyPath,
        [string]$ComposeProject,
        [string]$PgDataVolume,
        [bool]$AllowPrompt = $true,
        [System.Collections.IDictionary]$PendingFacts,
        [object]$Runtime
    )

    $result = [PSCustomObject]@{
        Outcome       = 'blocked'
        Reason        = $null
        Configuration = $null
        Network       = $null
        Pins          = $null
        Start         = $null
        Bootstrap     = $null
        Firewall      = $null
        Startup       = $null
    }

    # --- installation root ------------------------------------------------
    $directories = New-DeltaInstallDirectories -InstallRoot $InstallRoot
    if (-not $directories.Succeeded) {
        $result.Reason = $directories.Reason
        return $result
    }

    # Phase 2 could not write these because it is not allowed to create the
    # installation root; this is the first point at which there is somewhere
    # legitimate to put them.
    $facts = [ordered]@{ state = 'partial'; installRoot = $InstallRoot }
    if ($PendingFacts) {
        foreach ($key in $PendingFacts.Keys) { $facts[[string]$key] = $PendingFacts[$key] }
    }
    $null = Write-DeltaInstallState -InstallRoot $InstallRoot -Properties $facts

    # --- ports and TLS ----------------------------------------------------
    # Resolved before anything is generated: PUBLIC_URL, the NGINX server
    # blocks and the published ports all derive from these answers.
    $envPath = Join-Path -Path $InstallRoot -ChildPath '.env'
    $projectName = Get-DeltaEnvValue -Path $envPath -Key 'COMPOSE_PROJECT_NAME'
    if (-not $projectName -and $ComposeProject) { $projectName = $ComposeProject }
    if (-not $projectName) { $projectName = $Script:DeltaComposeProjectDefault }
    $openSslImage = Get-DeltaEnvValue -Path $envPath -Key 'DB_IMAGE'
    if (-not $openSslImage) { $openSslImage = 'postgis/postgis:17-3.5' }

    $network = Invoke-DeltaNetworkStage -InstallRoot $InstallRoot -ProjectName $projectName -OpenSslImage $openSslImage `
        -HttpPort $HttpPort -HttpsPort $HttpsPort -HostName $HostName -TlsMode $TlsMode `
        -CertificatePath $CertificatePath -CertificateKeyPath $CertificateKeyPath -AllowPrompt $AllowPrompt
    $result.Network = $network
    if (-not $network.Succeeded) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'Ports and TLS could not be settled.'
        Write-Detail $network.Reason
        $result.Reason = $network.Reason
        return $result
    }

    # --- configuration ----------------------------------------------------
    $configuration = New-DeltaEnvironmentFile -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Network $network `
        -ComposeProject $ComposeProject -PgDataVolume $PgDataVolume
    $result.Configuration = $configuration

    $null = New-DeltaComposeFile -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -TlsEnabled ([bool]$network.TlsEnabled)
    $nginxConfiguration = New-DeltaNginxConfiguration -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Network $network

    $config = Test-DeltaComposeConfiguration -InstallRoot $InstallRoot -ProjectName $configuration.ProjectName
    if (-not $config.Succeeded) {
        $result.Reason = 'The generated Compose file is not valid.'
        return $result
    }

    # --- is this project name already somebody else's? --------------------
    # A Compose project name is an identity. If containers already carry it but
    # were created from a different compose file, continuing would recreate
    # another installation's containers against this configuration and point
    # its database container at a volume initialised with different
    # credentials. Observed exactly that during Phase 5 development, which is
    # why this check exists.
    $foreign = Test-DeltaComposeProjectConflict -InstallRoot $InstallRoot -ProjectName $configuration.ProjectName
    if ($foreign.HasConflict) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'That Compose project name already belongs to another installation.'
        Write-Detail $foreign.Reason
        Write-Detail ''
        Write-Detail 'Nothing was started. Give this installation its own project name and data volume,'
        Write-Detail 'for example:  .\setup.ps1 -InstallRoot <root> -ComposeProject <name> -PgDataVolume <name>'
        $result.Reason = $foreign.Reason
        return $result
    }

    # --- nginx -t gate ----------------------------------------------------
    # Against the running container, because `proxy_pass http://delta:3000`
    # makes nginx resolve the upstream at test time. If the test fails, the
    # previous configuration goes straight back: an invalid file never stays
    # in the live path.
    $nginxTest = Test-DeltaNginxConfiguration -InstallRoot $InstallRoot -ProjectName $configuration.ProjectName
    if ($nginxTest.Tested -and -not $nginxTest.Succeeded) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'The generated NGINX configuration was rejected by nginx -t.'
        foreach ($line in ($nginxTest.Output -split "`r?`n")) { Write-Detail "  $line" }
        if ($null -ne $nginxConfiguration.Previous) {
            Write-DeltaFileAtomic -Path $nginxConfiguration.Path -Content $nginxConfiguration.Previous
            Write-Detail 'The previous NGINX configuration has been put back.'
        }
        $result.Reason = 'The generated NGINX configuration failed nginx -t and was not installed.'
        return $result
    }
    if ($nginxTest.Tested) {
        Write-Detail '[ ok ]     nginx -t accepted the generated configuration.'
        if (Invoke-DeltaNginxReload -InstallRoot $InstallRoot -ProjectName $configuration.ProjectName) {
            Write-Detail '[ ok ]     NGINX reloaded.'
        }
    }
    else {
        Write-Detail $nginxTest.Reason
    }

    # --- persistent data --------------------------------------------------
    $precheck = Test-DeltaPersistentDataPrecheck -InstallRoot $InstallRoot -Configuration $configuration
    if (-not $precheck.Succeeded) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'Persistent data is missing.'
        Write-Detail $precheck.Reason
        $result.Reason = $precheck.Reason
        return $result
    }

    # --- images -----------------------------------------------------------
    $pull = Invoke-DeltaImagePull -InstallRoot $InstallRoot -ProjectName $configuration.ProjectName
    if (-not $pull.Succeeded) {
        $result.Reason = $pull.Reason
        return $result
    }

    $result.Pins = Set-DeltaImagePins -InstallRoot $InstallRoot -Configuration $configuration
    # The pin rewrote DELTA_IMAGE, so the in-memory configuration is refreshed
    # from the file that Compose will actually read.
    $configuration.DeltaImage = $result.Pins.DeltaImage

    # --- start, with the security bootstrap wired into the right place -----
    # The administrator reset runs once per installation. Its completion is
    # recorded in the state file - a non-secret fact, never the credential -
    # so an ordinary rerun of a secured installation does not silently replace
    # a credential the operator is already using.
    $state = Read-DeltaInstallState -InstallRoot $InstallRoot
    $alreadyBootstrapped = $false
    if ($state.Exists -and $state.IsValid -and (@($state.Data.PSObject.Properties.Name) -contains 'adminBootstrap')) {
        $alreadyBootstrapped = [bool]$state.Data.adminBootstrap.completed
    }

    $bootstrap = $null
    $bootstrapBlock = $null
    if (-not $alreadyBootstrapped) {
        # A plain scriptblock taking arguments, deliberately not a closure.
        # GetNewClosure() rebinds a scriptblock to a new dynamic module, and
        # what a scriptblock in that state can see depends on how the installer
        # happens to have been loaded - which is a fragile thing to hang the
        # single most important security step of the installation on. A plain
        # scriptblock literal keeps the session state of the file it was
        # written in, so the reset function resolves the same way every other
        # call in this file does, and everything it needs arrives as an
        # argument rather than as captured ambient state.
        $bootstrapBlock = {
            param($BootstrapInstallRoot, $BootstrapConfiguration, $BootstrapAllowPrompt)
            Invoke-DeltaAdminPasswordReset `
                -InstallRoot $BootstrapInstallRoot `
                -Configuration $BootstrapConfiguration `
                -Automatic `
                -AllowPrompt $BootstrapAllowPrompt
        }
    }

    $result.Start = Start-DeltaStack -InstallRoot $InstallRoot -Configuration $configuration `
        -SecurityBootstrap $bootstrapBlock -AllowPrompt $AllowPrompt

    if (-not $result.Start.Succeeded) {
        $result.Reason = $result.Start.Reason
        if ($result.Start.Stage -eq 'migration')  { $result.Outcome = 'migration' }
        if ($result.Start.Stage -eq 'bootstrap')  { $result.Outcome = 'bootstrap' }
        return $result
    }

    $bootstrap = $result.Start.Bootstrap
    $result.Bootstrap = $bootstrap
    if ($alreadyBootstrapped) {
        Write-Detail 'The administrator account was secured by an earlier run; it is left as it is.'
    }

    # --- firewall ---------------------------------------------------------
    # Only the ports this installation actually publishes, and a failure here
    # warns rather than failing an installation that is otherwise complete.
    $result.Firewall = Invoke-DeltaFirewallConfiguration -ProjectName $configuration.ProjectName `
        -HttpPort ([int]$configuration.HttpPort) `
        -HttpsPort ([int]$configuration.HttpsPort) -TlsEnabled ([bool]$network.TlsEnabled)

    # --- record what is running -------------------------------------------
    # Everything mandatory has now succeeded - the schema is verified, the
    # administrator credential is no longer the published default, and the
    # stack answered over HTTP - so this is the point at which the
    # installation is registered as complete. Anything earlier would have
    # marked an installation "installed" while it was still insecure.
    $stateFacts = [ordered]@{
        state          = 'installed'
        installedAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        installRoot    = $InstallRoot
        composeProject = $configuration.ProjectName
        deltaImage     = $configuration.DeltaImage
        deltaImageTag  = $configuration.DeltaImageTag
        deltaImageDigest = $result.Pins.DeltaDigest
        dbImage        = $configuration.DbImage
        dbImageDigest  = $result.Pins.DbDigest
        nginxImage     = $configuration.NginxImage
        nginxImageDigest = $result.Pins.NginxDigest
        postgresMajor  = [int]$result.Start.Database.PostgresMajor
        pgDataVolume   = $configuration.PgDataVolume
        httpPort       = [int]$configuration.HttpPort
        httpsPort      = [int]$configuration.HttpsPort
        tlsEnabled     = [bool]$network.TlsEnabled
        tlsMode        = $network.TlsMode
        hostname       = $network.HostName
        publicUrl      = $network.PublicUrl
        # Non-secret certificate identity only: never the key, never a path
        # outside the installation.
        certificateThumbprint = if ($network.Certificate) { $network.Certificate.Thumbprint } else { $null }
        certificateNotAfter   = if ($network.Certificate) { $network.Certificate.NotAfter.ToString('yyyy-MM-dd') } else { $null }
        # Not 'schemaVersion': that field describes the format of the state
        # file itself, and overwriting it with the database's schema version
        # makes the file unreadable to the installer that wrote it.
        deltaSchemaVersion = $result.Start.Migration.SchemaVersion
    }

    # Proof that the security bootstrap ran, and nothing more: when it
    # happened, which account, and how the credential was chosen. Never the
    # credential itself. This is what a rerun reads to know it must not
    # replace a credential the operator is already using.
    if ($bootstrap -and $bootstrap.Succeeded) {
        $stateFacts['adminBootstrap'] = [ordered]@{
            completed = $true
            at        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            email     = $bootstrap.Email
            method    = $bootstrap.Method
        }
    }

    $null = Write-DeltaInstallState -InstallRoot $InstallRoot -Properties $stateFacts

    # --- unattended startup ------------------------------------------------
    # Last, and after the installation is registered: it configures what
    # happens at the *next* boot, so it can neither help nor harm the
    # installation that has just succeeded. The restart policy is verified here
    # rather than inside the startup stage, so that the layer which owns
    # Compose stays the only one that talks to it.
    $restartPolicy = Test-DeltaComposeRestartPolicy -InstallRoot $InstallRoot -ProjectName $configuration.ProjectName
    $result.Startup = Invoke-DeltaStartupConfiguration -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
        -ProjectName $configuration.ProjectName -RestartPolicy $restartPolicy

    $result.Outcome = 'ready'
    $result.Reason = "The stack is running and answered HTTP $($result.Start.Http.StatusCode) at $($configuration.PublicUrl)."
    return $result
}
