# =============================================================================
# Delta.Tls.ps1 - Certificate Management (menu option 7)
#
# Dot-source Delta.Common.ps1, Delta.Config.ps1, Delta.Docker.ps1,
# Delta.Stack.ps1, Delta.Network.ps1, Delta.Manage.ps1, Delta.Configure.ps1
# and Delta.Domain.ps1 first. This file composes their primitives:
#
#   certificate parse / pair match / expiry     Delta.Network.ps1
#   SAN reading and coverage                    Delta.Network.ps1
#   self-signed generation                      Delta.Network.ps1
#   staging with the private-key ACL            Delta.Network.ps1
#   NGINX + Compose generation                  Delta.Stack.ps1
#   nginx -t, nginx -s reload                   Delta.Network.ps1
#   firewall reconciliation                     Delta.Network.ps1
#   .env mutation, installer state              Delta.Config.ps1
#   the authoritative domain model              Delta.Config.ps1 (Domain Mgmt)
#   recreating the application container        Delta.Configure.ps1
#
# What lives here is the operator-facing screen and the ONE TLS transition
# transaction that installation, -Reconfigure and Management Mode all end up
# expressing. There is no second certificate implementation.
#
# Assessment references: A§11 (HTTPS and certificates), A§8.3 (NGINX
# generation and validation), A§14 (ports), A§17.3 (management menu),
# A§23 (no Windows certificate store, no BouncyCastle), A§24 (blast radius).
# =============================================================================

# ---------------------------------------------------------------------------
# Ownership, stated once
#
#   Certificate Management owns   HTTPS enablement, the certificate and key in
#                                 certs\, TLS_ENABLED/TLS_MODE, the HTTPS port,
#                                 the scheme half of PUBLIC_URL, and the
#                                 installer's HTTPS firewall rule.
#
#   Domain Management owns        which hostnames exist and which one is
#                                 primary - the host half of PUBLIC_URL.
#
# Neither reaches into the other. Adding a domain never touches a certificate;
# installing a certificate never adds, removes or re-designates a domain.
# ---------------------------------------------------------------------------

$Script:DeltaCertificateExpiryWarningDays = 30

function Get-DeltaTlsNetworkShape {
    <#
      The object New-DeltaNginxConfiguration expects, for a candidate TLS
      state. The certificate paths are the fixed container paths
      Install-DeltaCertificate stages to, from the same two constants the
      installer has always used.
    #>
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$PrimaryDomain,
        [Parameter(Mandatory)][bool]$TlsEnabled,
        [int]$HttpsPort
    )

    $port = if ($HttpsPort -gt 0) { $HttpsPort } else { [int]$Configuration.HttpsPort }

    return [PSCustomObject]@{
        HostName        = $PrimaryDomain
        HttpPort        = [int]$Configuration.HttpPort
        HttpsPort       = $port
        TlsEnabled      = $TlsEnabled
        TlsMode         = $Configuration.TlsMode
        CertificateFile = "/etc/nginx/certs/$Script:DeltaCertificateFileName"
        KeyFile         = "/etc/nginx/certs/$Script:DeltaCertificateKeyName"
    }
}

# ---------------------------------------------------------------------------
# Certificate input and the activation gate
# ---------------------------------------------------------------------------

function Resolve-DeltaCertificateInput {
    <#
      Turns whatever the operator has into a validated PEM certificate and key
      in a staging directory, ready to install - or a named reason it cannot
      be used.

      Two sources, and they converge immediately so that everything after this
      point is one code path:

        pem       a certificate file plus a separate key file
        staged    the certificate already in certs\, re-validated from scratch

      Nothing is converted on the way in. NGINX reads PEM, so PEM is what is
      supplied and PEM is what is installed - there is no transformation step
      between the operator's files and the ones being served.

      "staged" exists for re-enabling HTTPS after it was disabled: disabling
      preserves the material, and offering it back is the difference between a
      two-keystroke re-enable and hunting for files again. It is never trusted
      for having been there before - it goes through the identical validation,
      because a certificate that was valid in March is not necessarily valid in
      December.

      Validation is Phase 4's Test-DeltaCertificateMaterial unchanged: both
      files parse, the key is not passphrase-protected, THE KEY MATCHES THE
      CERTIFICATE, and the dates are current. The reference installer checked
      only the extension and that the certificate parsed; that is weaker and is
      not what this installer does.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][ValidateSet('pem', 'staged')][string]$Kind,
        [string]$CertificatePath,
        [string]$KeyPath,
        [Parameter(Mandatory)][string]$StagingDirectory
    )

    $result = [PSCustomObject]@{
        Succeeded       = $false
        Reason          = $null
        CertificatePath = $null
        KeyPath         = $null
        Validation      = $null
        Kind            = $Kind
    }

    $openSslImage = $Configuration.DbImage

    switch ($Kind) {
        'staged' {
            $installed = Get-DeltaInstalledCertificate -InstallRoot $InstallRoot
            if (-not $installed.Exists -or -not $installed.KeyExists) {
                $result.Reason = "There is no preserved certificate and key in $InstallRoot\certs to reuse."
                return $result
            }
            $result.CertificatePath = $installed.CertificatePath
            $result.KeyPath         = $installed.KeyPath
        }
        'pem' {
            if (-not $CertificatePath -or -not $KeyPath) {
                $result.Reason = 'A certificate file and a private key file are both required.'
                return $result
            }
            if ((Get-DeltaCertificateSourceKind -Path $CertificatePath) -ne 'pem') {
                $result.Reason = "'$CertificatePath' is not a supported certificate file. Supported: $($Script:DeltaPemCertificateExtensions -join ', '). NGINX serves PEM; convert another format to PEM first and supply the certificate and key."
                return $result
            }
            $keyExtension = ([System.IO.Path]::GetExtension($KeyPath)).ToLowerInvariant()
            if ($Script:DeltaPemKeyExtensions -notcontains $keyExtension) {
                $result.Reason = "'$KeyPath' is not a supported private key file. Supported: $($Script:DeltaPemKeyExtensions -join ', ')."
                return $result
            }
            $result.CertificatePath = $CertificatePath
            $result.KeyPath         = $KeyPath
        }
    }

    $validation = Test-DeltaCertificateMaterial -CertificatePath $result.CertificatePath -KeyPath $result.KeyPath -OpenSslImage $openSslImage
    $result.Validation = $validation
    if (-not $validation.IsValid) {
        $result.Reason = $validation.Reason
        return $result
    }

    $result.Succeeded = $true
    return $result
}

function Test-DeltaCertificateActivation {
    <#
      The activation gate: may this certificate become the one DELTA's
      canonical HTTPS URL is served with?

      The rule that is not negotiable is primary-domain coverage. PUBLIC_URL is
      what DELTA calls itself; configuring it as https://<host> while serving a
      certificate that fails hostname validation for <host> would mean every
      browser reaching DELTA at its own canonical address gets a security
      warning. That is a defect, not a preference, so it is refused rather than
      warned about (A§11.2's spirit, made explicit).

      Additional domains are different: they are aliases, an uncovered one
      warns, and blocking HTTPS for a correctly-covered primary because an
      alias is not in the SAN list would be the installer refusing to do the
      right thing on account of an optional extra.

      Coverage that cannot be DETERMINED is not the same as coverage that is
      absent, and is not treated as a refusal - it is reported as unknown, and
      the operator decides. Refusing on "we could not read the SAN extension"
      would make an unreadable certificate indistinguishable from a wrong one.
    #>
    param(
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][object]$DomainModel
    )

    $coverage = Get-DeltaCertificateDomainCoverage -CertificatePath $CertificatePath -Domains $DomainModel.All

    $result = [PSCustomObject]@{
        Allowed          = $false
        Reason           = $null
        Coverage         = $coverage
        PrimaryCovered   = $false
        PrimaryDetermined = $coverage.Determined
        UncoveredAdditional = @()
    }

    if (-not $coverage.Determined) {
        $result.Allowed = $true
        $result.Reason  = "The names this certificate covers could not be read ($($coverage.Reason)), so coverage of $($DomainModel.Primary) could not be confirmed."
        return $result
    }

    $primaryRow = $coverage.Rows | Where-Object { $_.Domain -eq $DomainModel.Primary } | Select-Object -First 1
    $result.PrimaryCovered = [bool]($primaryRow -and $primaryRow.IsCovered)

    if (-not $result.PrimaryCovered) {
        $result.Reason = "This certificate does not cover the primary domain $($DomainModel.Primary). It is valid for: $($coverage.Names -join ', '). DELTA's canonical URL would fail hostname validation in every browser, so it has not been installed."
        return $result
    }

    $result.UncoveredAdditional = @($coverage.Uncovered)
    $result.Allowed = $true
    return $result
}

# ---------------------------------------------------------------------------
# The TLS transition transaction
#
# Enabling and disabling HTTPS are the same transaction with a different target
# state, which is why they are one function rather than two that drift.
#
# The ordering below is not arbitrary; it is forced by two facts about this
# architecture, both established by measurement:
#
#   1. certs\ is bind-mounted into NGINX in BOTH the HTTP and the HTTPS Compose
#      shapes. So a candidate HTTPS configuration - certificate, key and all -
#      can be validated by `nginx -t` inside the still-HTTP running container
#      BEFORE any container is recreated. That is what makes this transactional
#      rather than hopeful.
#
#   2. the nginx service's published ports and its healthcheck both change
#      between the two shapes, and both are container-creation-time properties.
#      A reload cannot express them. So `up -d --no-deps nginx` is genuinely
#      required - and it is the narrowest operation that works, touching one
#      container and no volume.
#
# Compose reads HTTP_PORT/HTTPS_PORT/PUBLIC_URL from .env, so .env must be
# written before the recreation. That leaves one window - between the .env
# write and the recreation - in which the recorded state is ahead of the
# runtime. It is inside a single synchronous operation, and every exit from it
# rolls the whole thing back.
# ---------------------------------------------------------------------------

function New-DeltaTlsSnapshot {
    <#
      Everything needed to put this installation back exactly as it was.

      The .env values are held in memory rather than copied to a file: they
      include PUBLIC_URL, and a rollback snapshot is not a reason to make
      another copy of anything in that file. The certificate and key are backed
      up with the existing Phase 10 primitive, which keeps them inside certs\
      under the same restricted ACL - a private key does not leave the
      directory that protects it.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [switch]$IncludeCertificateMaterial
    )

    $envPath     = Join-Path -Path $InstallRoot -ChildPath '.env'
    $composePath = Join-Path -Path $InstallRoot -ChildPath 'docker-compose.yml'
    $nginxPath   = Join-Path -Path $InstallRoot -ChildPath 'nginx\conf.d\delta.conf'

    $values = [ordered]@{}
    foreach ($key in @('TLS_ENABLED', 'TLS_MODE', 'HTTPS_PORT', 'HTTP_PORT', 'PUBLIC_URL')) {
        $values[$key] = Get-DeltaEnvValue -Path $envPath -Key $key
    }

    return [PSCustomObject]@{
        EnvValues   = $values
        ComposeText = $(if (Test-Path -LiteralPath $composePath -PathType Leaf) { [System.IO.File]::ReadAllText($composePath, (New-Object System.Text.UTF8Encoding($false))) } else { $null })
        NginxText   = $(if (Test-Path -LiteralPath $nginxPath -PathType Leaf) { [System.IO.File]::ReadAllText($nginxPath, (New-Object System.Text.UTF8Encoding($false))) } else { $null })
        Certificate = $(if ($IncludeCertificateMaterial) { Backup-DeltaCertificateMaterial -InstallRoot $InstallRoot } else { $null })
        ComposePath = $composePath
        NginxPath   = $nginxPath
        EnvPath     = $envPath
    }
}

function Restore-DeltaTlsSnapshot {
    <#
      Puts back everything New-DeltaTlsSnapshot preserved, then brings the
      runtime back to match it, and reports what it actually managed - never a
      blanket claim of success. A rollback that says it worked when it did not
      is worse than no rollback at all.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][object]$Configuration,
        [switch]$RecreateNginx
    )

    $result = [PSCustomObject]@{
        FilesRestored     = $false
        CertificateRestored = $false
        NginxRecreated    = $false
        ApplicationRestored = $false
        Healthy           = $false
        Reason            = $null
    }

    Write-Step 'Putting the previous configuration back'

    try {
        $written = [ordered]@{}
        foreach ($key in $Snapshot.EnvValues.Keys) {
            if ($null -ne $Snapshot.EnvValues[$key]) { $written[$key] = [string]$Snapshot.EnvValues[$key] }
        }
        if ($written.Count -gt 0) { Set-DeltaEnvValues -Path $Snapshot.EnvPath -Values $written }

        if ($null -ne $Snapshot.ComposeText) { Write-DeltaFileAtomic -Path $Snapshot.ComposePath -Content $Snapshot.ComposeText }
        if ($null -ne $Snapshot.NginxText)   { Write-DeltaFileAtomic -Path $Snapshot.NginxPath   -Content $Snapshot.NginxText }
        $result.FilesRestored = $true
    }
    catch {
        $result.Reason = "The previous configuration files could not all be restored: $($_.Exception.Message)"
        return $result
    }

    if ($Snapshot.Certificate -and ($Snapshot.Certificate.CertificateBackup -or $Snapshot.Certificate.KeyBackup)) {
        $result.CertificateRestored = Restore-DeltaCertificateMaterial -InstallRoot $InstallRoot -Backup $Snapshot.Certificate
    }

    # The previous .env is back, so recreating nginx re-publishes exactly the
    # ports it had before.
    if ($RecreateNginx) {
        $up = Invoke-DeltaActivity -Message 'Restoring the NGINX container' -WhenIdle -ScriptBlock {
            Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName -Arguments @('up', '-d', '--no-deps', 'nginx') -TimeoutSeconds 300
        }
        $result.NginxRecreated = ($up.ExitCode -eq 0)
    }
    else {
        $result.NginxRecreated = (Invoke-DeltaNginxReload -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName)
    }

    # PUBLIC_URL is back to its previous value, so the application container
    # has to be told, exactly as it was told on the way out.
    $restoredPublicUrl = [string]$Snapshot.EnvValues['PUBLIC_URL']
    if ($restoredPublicUrl) {
        $application = Update-DeltaApplicationContainer -InstallRoot $InstallRoot -Configuration (Get-DeltaStackConfiguration -InstallRoot $InstallRoot)
        $result.ApplicationRestored = $application.Succeeded
    }

    $restored = Get-DeltaStackConfiguration -InstallRoot $InstallRoot
    $scheme = if ($restored.TlsEnabled) { 'https' } else { 'http' }
    $port   = if ($restored.TlsEnabled) { [int]$restored.HttpsPort } else { [int]$restored.HttpPort }
    $probe  = Test-DeltaHttpEndpoint -Url ((Get-DeltaPublicUrl -Scheme $scheme -HostName 'localhost' -Port $port) + '/') -TimeoutSeconds 60
    $result.Healthy = $probe.Succeeded

    if ($result.Healthy) {
        Write-Success 'The previous configuration is back in place and DELTA answers on it.'
    }
    else {
        Write-DeltaFailure 'The previous configuration was restored but DELTA is not answering on it yet.'
        Write-Detail 'Check the status block and View Logs. No data, volume or upload was involved at any point.'
    }
    return $result
}

function Set-DeltaTlsState {
    <#
      Enables or disables HTTPS, as one transaction.

      Sequence, and every step after the first is reversible by the snapshot
      taken before it:

        1. snapshot          .env values, compose, NGINX config, certificate
        2. stage certificate when enabling, into certs\ with the key ACL
        3. NGINX candidate   generated for the target state
        4. nginx -t          inside the RUNNING container, which already mounts
                             certs\ - so the certificate and key are proved
                             usable before any container is recreated
        5. .env              TLS_ENABLED, TLS_MODE, HTTPS_PORT, PUBLIC_URL
        6. compose candidate regenerated for the target state
        7. docker compose config validates it
        8. recreate nginx    required: ports and healthcheck are creation-time
        9. recreate delta    required: PUBLIC_URL is in its environment
       10. firewall          reconciled to the target state
       11. verify            a real request to the endpoint that should now
                             be serving
       12. state file        written last, once everything above held

      Any failure from step 3 onwards restores the snapshot and brings the
      runtime back to it. Nothing here removes a container, a network or a
      volume, and no path reaches `down`, `prune` or `volume rm`.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][bool]$EnableTls,
        [Parameter(Mandatory)][object]$DomainModel,
        # Enabling only.
        [ValidateSet('supplied', 'self-signed', '')][string]$TlsMode = '',
        [string]$StagedCertificatePath,
        [string]$StagedKeyPath,
        [int]$HttpsPort
    )

    $result = [PSCustomObject]@{
        Succeeded    = $false
        Stage        = 'start'
        Reason       = $null
        TlsEnabled   = $EnableTls
        PublicUrl    = $null
        HttpsPort    = 0
        NginxTest    = $null
        Firewall     = $null
        Http         = $null
        Served       = $null
        RolledBack   = $false
        Rollback     = $null
    }

    $projectName = $Configuration.ProjectName
    $primary     = $DomainModel.Primary

    # --- NGINX must be running: it is what validates the candidate ---------
    $services = @(Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $projectName)
    $nginx = $services | Where-Object { $_.Service -eq 'nginx' } | Select-Object -First 1
    if (-not $nginx -or $nginx.State -ne 'running') {
        $result.Stage  = 'nginx-unavailable'
        $result.Reason = 'NGINX is not running, so a TLS change could be neither validated nor applied. Nothing was changed.'
        return $result
    }

    $targetHttpsPort = if ($EnableTls) { if ($HttpsPort -gt 0) { $HttpsPort } else { [int]$Configuration.HttpsPort } } else { [int]$Configuration.HttpsPort }
    $result.HttpsPort = $targetHttpsPort

    $scheme    = if ($EnableTls) { 'https' } else { 'http' }
    $port      = if ($EnableTls) { $targetHttpsPort } else { [int]$Configuration.HttpPort }
    $publicUrl = Get-DeltaPublicUrl -Scheme $scheme -HostName $primary -Port $port
    $result.PublicUrl = $publicUrl

    # --- 1. snapshot -------------------------------------------------------
    $result.Stage = 'snapshot'
    $snapshot = New-DeltaTlsSnapshot -InstallRoot $InstallRoot -IncludeCertificateMaterial:$EnableTls

    $rollback = {
        $result.Rollback = Restore-DeltaTlsSnapshot -InstallRoot $InstallRoot -Snapshot $snapshot -Configuration $Configuration -RecreateNginx
        $result.RolledBack = [bool]$result.Rollback.FilesRestored
    }

    try {
        # --- 2. stage the certificate --------------------------------------
        if ($EnableTls) {
            $result.Stage = 'stage-certificate'
            Write-Step 'Installing the certificate'
            $installed = Install-DeltaCertificate -InstallRoot $InstallRoot -CertificatePath $StagedCertificatePath -KeyPath $StagedKeyPath
            Write-Detail "Certificate  $($installed.CertificatePath)"
            Write-Detail "Private key  $($installed.KeyPath)  (Administrators and SYSTEM only)"
        }

        # --- 3. NGINX candidate --------------------------------------------
        $result.Stage = 'nginx-generate'
        Write-Step "Generating the NGINX configuration for $(if ($EnableTls) { 'HTTPS' } else { 'HTTP' })"
        $network = Get-DeltaTlsNetworkShape -Configuration $Configuration -PrimaryDomain $primary -TlsEnabled $EnableTls -HttpsPort $targetHttpsPort
        # No -AdditionalDomain: unbound means "use the persisted domain set",
        # which is Domain Management's, and this operation has no business
        # changing it.
        $null = New-DeltaNginxConfiguration -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Network $network

        # --- 4. nginx -t against the running container ----------------------
        $result.Stage = 'nginx-test'
        Write-Step 'Validating the candidate configuration'
        $result.NginxTest = Test-DeltaNginxConfiguration -InstallRoot $InstallRoot -ProjectName $projectName
        if (-not $result.NginxTest.Tested) {
            & $rollback
            $result.Stage  = 'nginx-unavailable'
            $result.Reason = "The candidate configuration could not be validated ($($result.NginxTest.Reason)). Nothing was applied."
            return $result
        }
        if (-not $result.NginxTest.Succeeded) {
            Write-DeltaFailure ''
            Write-DeltaFailure 'NGINX rejected the candidate configuration. No container was recreated.'
            foreach ($line in ($result.NginxTest.Output -split "`r?`n")) { if ($line.Trim()) { Write-Detail "  $line" } }
            & $rollback
            $result.Reason = 'nginx -t rejected the candidate configuration, so nothing was applied or recorded.'
            return $result
        }
        Write-Detail '[ ok ]     nginx -t accepted the candidate, reading the certificate from the live mount'

        # --- 5. .env --------------------------------------------------------
        $result.Stage = 'env'
        $values = [ordered]@{
            TLS_ENABLED = $(if ($EnableTls) { 'true' } else { 'false' })
            PUBLIC_URL  = $publicUrl
        }
        if ($EnableTls) {
            $values['TLS_MODE']   = $(if ($TlsMode) { $TlsMode } else { 'supplied' })
            $values['HTTPS_PORT'] = "$targetHttpsPort"
        }
        else {
            # TLS_MODE becomes none; the HTTPS port is left recorded exactly as
            # it was, so re-enabling later offers the port this installation
            # already chose rather than silently reverting to 443.
            $values['TLS_MODE'] = 'none'
        }
        Set-DeltaEnvValues -Path $snapshot.EnvPath -Values $values
        Write-Detail "PUBLIC_URL   $publicUrl"

        # --- 6/7. Compose ---------------------------------------------------
        $result.Stage = 'compose'
        Write-Step 'Regenerating the Compose file'
        $null = New-DeltaComposeFile -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -TlsEnabled $EnableTls
        $composeCheck = Test-DeltaComposeConfiguration -InstallRoot $InstallRoot -ProjectName $projectName
        if (-not $composeCheck.Succeeded) {
            Write-DeltaFailure 'The regenerated Compose file is not valid. No container was recreated.'
            & $rollback
            $result.Reason = 'The regenerated Compose file failed validation, so nothing was applied.'
            return $result
        }
        Write-Detail "[ ok ]     the Compose file $(if ($EnableTls) { 'publishes' } else { 'no longer publishes' }) the HTTPS port"

        # --- 8. recreate nginx ----------------------------------------------
        # Necessary, not defensive: the published ports and the healthcheck are
        # both container-creation-time properties and a reload cannot express
        # either. --no-deps keeps it to this one service.
        $result.Stage = 'nginx-recreate'
        Write-Step 'Recreating the NGINX container'
        # The health wait below announces itself (-WhenIdle finds nothing
        # running once this returns), so the two halves are consecutive
        # activities rather than one - there is no gap between them.
        $up = Invoke-DeltaActivity -Message 'Recreating the NGINX container' -ScriptBlock {
            Invoke-DeltaCompose -InstallRoot $InstallRoot -ProjectName $projectName -Arguments @('up', '-d', '--no-deps', 'nginx') -TimeoutSeconds 300
        }
        if ($up.ExitCode -ne 0) {
            Write-DeltaFailure "The NGINX container could not be recreated: $((($up.StdErr + ' ' + $up.StdOut)).Trim())"
            & $rollback
            $result.Reason = 'The NGINX container could not be recreated.'
            return $result
        }
        $health = Wait-DeltaServiceHealthy -InstallRoot $InstallRoot -ProjectName $projectName -Service 'nginx' -TimeoutSeconds 180
        if (-not $health.Succeeded) {
            Write-DeltaFailure 'The NGINX container did not become healthy.'
            Show-DeltaServiceLogs -InstallRoot $InstallRoot -ProjectName $projectName -Service 'nginx' -Tail 30
            & $rollback
            $result.Reason = 'The NGINX container did not become healthy on the new configuration.'
            return $result
        }
        Write-Detail '[ ok ]     NGINX recreated and healthy; the database and the data volume were not involved'

        # --- 9. recreate delta ----------------------------------------------
        # PUBLIC_URL is in the delta service's environment and is read at
        # start, so the canonical URL DELTA reports would otherwise still be
        # the old one. Same primitive the SMTP flow and Domain Management use.
        $result.Stage = 'application'
        Write-Step 'Applying the new canonical URL to the DELTA container'
        $application = Update-DeltaApplicationContainer -InstallRoot $InstallRoot -Configuration (Get-DeltaStackConfiguration -InstallRoot $InstallRoot)
        if (-not $application.Succeeded) {
            Write-DeltaFailure "The DELTA container did not come back cleanly: $($application.Reason)"
            & $rollback
            $result.Reason = "The DELTA container did not come back cleanly: $($application.Reason)"
            return $result
        }

        # --- 10. firewall ----------------------------------------------------
        # The installer's own two rules only, named by project, reconciled to
        # the target state - Invoke-DeltaFirewallConfiguration adds the HTTPS
        # rule when TLS is on and retires it when it is not. Never fatal: a
        # host under policy that forbids local rules still has a working
        # installation, it is just not reachable from elsewhere yet.
        $result.Stage = 'firewall'
        $result.Firewall = Invoke-DeltaFirewallConfiguration -ProjectName $projectName `
            -HttpPort ([int]$Configuration.HttpPort) -HttpsPort $targetHttpsPort -TlsEnabled $EnableTls

        # --- 11. verify ------------------------------------------------------
        $result.Stage = 'verify'
        $loopback = (Get-DeltaPublicUrl -Scheme $scheme -HostName 'localhost' -Port $port) + '/'
        $result.Http = Test-DeltaHttpEndpoint -Url $loopback -TimeoutSeconds 60
        if (-not $result.Http.Succeeded) {
            Write-DeltaFailure "$loopback did not answer after the change."
            Write-Detail $(if ($result.Http.Error) { $result.Http.Error } else { "HTTP $($result.Http.StatusCode)" })
            & $rollback
            $result.Reason = "$loopback did not answer after the change, so it was rolled back."
            return $result
        }
        Write-Detail "[ ok ]     GET $loopback returned $($result.Http.StatusCode)"

        if ($EnableTls) {
            $result.Served = Get-DeltaServedCertificateThumbprint -HostName 'localhost' -Port $port
            $expected = (Get-DeltaInstalledCertificate -InstallRoot $InstallRoot).Thumbprint
            if ($result.Served -and $expected -and $result.Served -ne $expected) {
                Write-DeltaWarning "NGINX is serving thumbprint $($result.Served), but the installed certificate is $expected."
                & $rollback
                $result.Reason = 'The certificate being served is not the one that was installed.'
                return $result
            }
            if ($result.Served) { Write-Detail "[ ok ]     the certificate being served is the one installed ($($result.Served))" }
        }

        # --- 12. state file ---------------------------------------------------
        $result.Stage = 'record'
        $detail = if ($EnableTls) { Get-DeltaCertificateDetail -CertificatePath (Join-Path $InstallRoot "certs\$Script:DeltaCertificateFileName") } else { $null }
        try {
            $facts = [ordered]@{
                tlsEnabled = $EnableTls
                tlsMode    = $(if ($EnableTls) { $(if ($TlsMode) { $TlsMode } else { 'supplied' }) } else { 'none' })
                publicUrl  = $publicUrl
                httpsPort  = $targetHttpsPort
                certificateThumbprint = $(if ($detail -and $detail.IsReadable) { $detail.Thumbprint } else { $null })
                certificateNotAfter   = $(if ($detail -and $detail.IsReadable) { $detail.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null })
            }
            $null = Write-DeltaInstallState -InstallRoot $InstallRoot -Properties $facts
        }
        catch {
            Write-DeltaWarning "The change was applied but the state file could not be updated: $($_.Exception.Message)"
        }

        $result.Stage = 'complete'
        $result.Succeeded = $true
        $result.Reason = if ($EnableTls) { "HTTPS is enabled. DELTA's canonical URL is $publicUrl." } else { "HTTPS is disabled. DELTA's canonical URL is $publicUrl." }
        return $result
    }
    catch {
        Write-DeltaFailure ''
        Write-DeltaFailure "The TLS change failed at stage '$($result.Stage)': $($_.Exception.Message)"
        & $rollback
        $result.Reason = "The TLS change failed at stage '$($result.Stage)': $($_.Exception.Message)"
        return $result
    }
}

function Set-DeltaCertificateMaterial {
    <#
      Replaces the certificate and key on an installation that is ALREADY
      serving HTTPS.

      Deliberately not Set-DeltaTlsState: nothing about the Compose file, the
      published ports, the healthcheck or PUBLIC_URL changes here, so nothing
      needs recreating. The generated configuration names fixed files inside
      the read-only certs mount, which means replacing the certificate is
      replacing two files and reloading - and a reload drains connections
      rather than dropping them, so the site does not go down at any point.

      This is Phase 10's flow, kept, with the certificate input and the
      primary-domain gate now shared with the enable path.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$TlsMode
    )

    $result = [PSCustomObject]@{
        Succeeded  = $false
        Stage      = 'start'
        Reason     = $null
        Backup     = $null
        NginxTest  = $null
        Reloaded   = $false
        Restored   = $false
        Http       = $null
        Served     = $null
        Expected   = $null
    }

    $projectName = $Configuration.ProjectName

    $result.Stage = 'install'
    $result.Backup = Backup-DeltaCertificateMaterial -InstallRoot $InstallRoot
    if ($result.Backup.CertificateBackup) { Write-Detail "Previous certificate saved as $($result.Backup.CertificateBackup)" }

    try {
        $installed = Install-DeltaCertificate -InstallRoot $InstallRoot -CertificatePath $CertificatePath -KeyPath $KeyPath
        Write-Detail "Staged $($installed.CertificatePath)"
        $result.Expected = (Get-DeltaCertificateDetail -CertificatePath $installed.CertificatePath).Thumbprint
    }
    catch {
        $result.Reason = "The certificate could not be staged: $($_.Exception.Message). The previous certificate is still in place."
        return $result
    }

    $result.Stage = 'nginx-test'
    Write-Step 'Validating the NGINX configuration with the new certificate'
    $result.NginxTest = Test-DeltaNginxConfiguration -InstallRoot $InstallRoot -ProjectName $projectName
    if ($result.NginxTest.Tested -and -not $result.NginxTest.Succeeded) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'NGINX rejected the new certificate. It has NOT been reloaded.'
        foreach ($line in ($result.NginxTest.Output -split "`r?`n")) { if ($line.Trim()) { Write-Detail "  $line" } }
        $result.Restored = Restore-DeltaCertificateMaterial -InstallRoot $InstallRoot -Backup $result.Backup
        if ($result.Restored) {
            Write-Success 'The previous certificate is back in place.'
            Write-Detail 'NGINX was never signalled, so it has been serving the previous certificate throughout.'
        }
        else {
            Write-DeltaFailure 'The previous certificate could NOT be restored automatically.'
            Write-Detail "Copies are at $($result.Backup.CertificateBackup) and $($result.Backup.KeyBackup)."
        }
        $result.Reason = 'nginx -t rejected the new certificate.'
        return $result
    }
    if ($result.NginxTest.Tested) { Write-Detail '[ ok ]     nginx -t passed' }

    $result.Stage = 'reload'
    Write-Step 'Reloading NGINX'
    $result.Reloaded = Invoke-DeltaNginxReload -InstallRoot $InstallRoot -ProjectName $projectName
    if (-not $result.Reloaded) {
        Write-DeltaFailure 'NGINX would not reload.'
        $result.Restored = Restore-DeltaCertificateMaterial -InstallRoot $InstallRoot -Backup $result.Backup
        if ($result.Restored) { $null = Invoke-DeltaNginxReload -InstallRoot $InstallRoot -ProjectName $projectName }
        Write-Detail 'No container was recreated.'
        $result.Reason = 'NGINX did not accept the reload signal.'
        return $result
    }
    Write-Detail '[ ok ]     reload accepted; no container was recreated'

    $result.Stage = 'verify'
    Start-Sleep -Seconds 2
    $url = (Get-DeltaPublicUrl -Scheme 'https' -HostName 'localhost' -Port ([int]$Configuration.HttpsPort)) + '/'
    $result.Http = Test-DeltaHttpEndpoint -Url $url -TimeoutSeconds 60
    $result.Served = Get-DeltaServedCertificateThumbprint -HostName 'localhost' -Port ([int]$Configuration.HttpsPort)

    if (-not $result.Http.Succeeded) {
        Write-DeltaFailure "The certificate was installed and NGINX reloaded, but $url did not answer."
        $result.Restored = Restore-DeltaCertificateMaterial -InstallRoot $InstallRoot -Backup $result.Backup
        if ($result.Restored -and (Invoke-DeltaNginxReload -InstallRoot $InstallRoot -ProjectName $projectName)) {
            $back = Test-DeltaHttpEndpoint -Url $url -TimeoutSeconds 60
            if ($back.Succeeded) { Write-Success 'The previous certificate is back in place and the site answers again.' }
            else { Write-DeltaFailure 'The previous certificate was restored but the site still does not answer.' }
        }
        $result.Reason = 'The site did not answer over HTTPS after the certificate was replaced.'
        return $result
    }
    Write-Detail "[ ok ]     GET $url returned $($result.Http.StatusCode)"

    if ($result.Served -and $result.Expected -and $result.Served -ne $result.Expected) {
        Write-DeltaWarning "NGINX is serving thumbprint $($result.Served), but the new certificate is $($result.Expected)."
        $result.Restored = Restore-DeltaCertificateMaterial -InstallRoot $InstallRoot -Backup $result.Backup
        $null = Invoke-DeltaNginxReload -InstallRoot $InstallRoot -ProjectName $projectName
        $result.Reason = 'The reload succeeded but the certificate being served is not the new one.'
        return $result
    }
    if ($result.Served) { Write-Detail "[ ok ]     the certificate being served is the new one ($($result.Served))" }

    try {
        $detail = Get-DeltaCertificateDetail -CertificatePath (Join-Path $InstallRoot "certs\$Script:DeltaCertificateFileName")
        $null = Write-DeltaInstallState -InstallRoot $InstallRoot -Properties ([ordered]@{
            certificateThumbprint = $detail.Thumbprint
            certificateNotAfter   = $detail.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            tlsMode               = $TlsMode
        })
    }
    catch {
        Write-DeltaWarning "The certificate was replaced but the state file could not be updated: $($_.Exception.Message)"
    }

    $result.Stage = 'complete'
    $result.Succeeded = $true
    $result.Reason = 'Certificate replaced; NGINX reloaded without recreating any container.'
    return $result
}

# ---------------------------------------------------------------------------
# The screen
# ---------------------------------------------------------------------------

function Show-DeltaCertificateScreen {
    <#
      Certificate Management, adapted to the state it finds.

      An HTTP installation is shown what it is and offered the one thing it
      needs - Enable HTTPS. It is not told to leave the utility and run
      setup.ps1 -Reconfigure, which was the whole reason for this rework.

      Nothing that cannot be determined is shown. A field this host could not
      read says so rather than being printed blank or guessed at.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$DomainModel,
        [object]$Detail,
        [object]$Coverage
    )

    Show-Section -Title 'Certificate Management' -Subtitle $InstallRoot

    Write-Host 'HTTPS'
    if ($Configuration.TlsEnabled) {
        Write-Detail "Enabled on port $($Configuration.HttpsPort)"
    }
    else {
        Write-Detail "Disabled - NGINX serves HTTP on port $($Configuration.HttpPort)"
    }
    Write-Host ''

    if ($Configuration.TlsEnabled) {
        Write-Host 'Primary URL'
        Write-Detail (Get-DeltaPublicUrl -Scheme 'https' -HostName $DomainModel.Primary -Port ([int]$Configuration.HttpsPort))
        Write-Host ''
    }
    else {
        Write-Host 'Primary domain'
        Write-Detail $DomainModel.Primary
        Write-Host ''
        Write-Host 'Configured domains'
        foreach ($domain in $DomainModel.All) {
            if ($domain -eq $DomainModel.Primary) { Write-Detail "$domain   (primary)" }
            else { Write-Detail $domain }
        }
        Write-Host ''
    }

    Write-Host 'Certificate'
    $keyPath = Join-Path -Path $InstallRoot -ChildPath "certs\$Script:DeltaCertificateKeyName"
    if (-not $Detail -or -not $Detail.Exists) {
        Write-Detail 'None active'
    }
    elseif (-not $Detail.IsReadable) {
        Write-DeltaWarning $Detail.Reason
    }
    else {
        Write-Detail "Subject        $($Detail.Subject)"
        Write-Detail "Issuer         $($Detail.Issuer)"
        Write-Detail "Valid from     $($Detail.NotBefore.ToString('yyyy-MM-dd'))"
        Write-Detail "Expires        $($Detail.NotAfter.ToString('yyyy-MM-dd'))  ($($Detail.DaysRemaining) day(s) remaining)"
        Write-Detail "Thumbprint     $($Detail.Thumbprint)"
        Write-Detail "Private key    $(if (Test-Path -LiteralPath $keyPath -PathType Leaf) { 'Available' } else { 'MISSING' })"
        if ($Detail.IsSelfSigned) {
            Write-DeltaWarning 'Self-signed - browsers will warn until it is trusted or replaced.'
        }
        if ($Detail.IsExpired) {
            Write-DeltaFailure "EXPIRED on $($Detail.NotAfter.ToString('yyyy-MM-dd'))."
        }
        elseif ($Detail.IsNotYetValid) {
            Write-DeltaWarning "Not valid until $($Detail.NotBefore.ToString('yyyy-MM-dd'))."
        }
        elseif ($Detail.DaysRemaining -le $Script:DeltaCertificateExpiryWarningDays) {
            Write-DeltaWarning "Expires in $($Detail.DaysRemaining) day(s). Plan its replacement now."
        }
    }

    if ($Coverage) {
        Write-Host ''
        Write-Host 'Domain coverage'
        if (-not $Coverage.Determined) {
            Write-DeltaWarning 'The names this certificate covers could not be read on this host.'
            if ($Coverage.Reason) { Write-Detail $Coverage.Reason }
        }
        else {
            foreach ($row in $Coverage.Rows) {
                $role = if ($row.Domain -eq $DomainModel.Primary) { '(primary)   ' } else { '(additional)' }
                $verdict = if ($row.IsCovered) { 'Covered' } else { 'NOT COVERED' }
                Write-Detail ("{0,-40} {1}  {2}" -f $row.Domain, $role, $verdict)
            }
            if (-not $Coverage.CoversAll) {
                Write-DeltaWarning "Browsers reaching DELTA by an uncovered hostname will warn. A replacement should cover: $($DomainModel.All -join ', ')"
            }
        }
    }
}

function Show-DeltaCertificateMenu {
    param([Parameter(Mandatory)][object]$Configuration)

    Write-Host ''
    if ($Configuration.TlsEnabled) {
        Write-Host '  1. Replace Certificate'
        Write-Host '  2. Inspect Certificate'
        Write-Host '  3. Disable HTTPS'
    }
    else {
        Write-Host '  1. Enable HTTPS'
    }
    Write-Host '  0. Return'
    Write-Host ''

    return ([string](Read-Host -Prompt 'Selection')).Trim()
}

# ---------------------------------------------------------------------------
# Certificate collection
# ---------------------------------------------------------------------------

# The two file selection dialogs that collect a certificate and its key are
# Read-DeltaCertificateFilePair, in Delta.Network.ps1 beside the extension
# lists and the validator they answer to. They started here, when this menu was
# the only caller; the installer's own "I have a certificate" choice now asks
# for the same two files, and asking for them twice in two places is how the
# two prompts come to differ. Read-DeltaCertificateSource below calls it
# unchanged.

function Read-DeltaCertificateSource {
    <#
      Asks where the certificate is coming from, and collects it.

      There is no bare-Enter default. The reference installer's
      Read-ExistingSslCertificateChoice deliberately refuses to make a
      consequential certificate decision for somebody who pressed Enter without
      reading, and choosing between a production certificate and a self-signed
      one is exactly that decision. Enter cancels.

      The certificate and the key are chosen from Windows file selection
      dialogs, one each, exactly as the reference installer's
      Install-DeltaSslCertificateFiles does - Select-DeltaSslFile with the same
      two filters. Locating a certificate wherever it happens to sit on disk is
      what a file picker is for, and an operator who has just been handed a
      bundle by their CA should not have to transcribe its path.

      Typing the paths remains as a fallback, and only as a fallback: a session
      that cannot show a dialog at all - Server Core, or an MTA thread - would
      otherwise leave the operator with no way to install a certificate.
      Test-DeltaFileDialogSupported decides that up front rather than half-way
      through the flow.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [bool]$OfferStaged = $false
    )

    $staged = Get-DeltaInstalledCertificate -InstallRoot $InstallRoot
    $canOfferStaged = ($OfferStaged -and $staged.Exists -and $staged.KeyExists)

    Write-Host ''
    Write-Host 'Where is the certificate coming from?'
    Write-Host ''
    Write-Host '  1. Use an existing certificate and private key'
    Write-Detail 'Select a certificate (.crt/.cer/.pem) and private key (.key).'
    Write-Detail 'Recommended for production certificates issued by your'
    Write-Detail 'organization or certificate provider.'
    Write-Host ''
    Write-Host '  2. Generate a self-signed certificate'
    Write-Detail 'For testing or internal use. Browsers will warn unless trusted.'
    if ($canOfferStaged) {
        Write-Host ''
        Write-Host '  3. Reuse the certificate already in certs\'
        Write-Detail "$($staged.Subject)"
        Write-Detail 'It is validated again from scratch before it is used.'
    }
    Write-Host ''
    Write-Host '  0. Cancel'
    Write-Host ''

    while ($true) {
        $choice = ([string](Read-Host -Prompt 'Selection')).Trim()
        if ($choice -eq '0' -or $choice -eq '') { return $null }

        if ($choice -eq '1') {
            $selection = Read-DeltaCertificateFilePair
            if (-not $selection) { return $null }
            return $selection
        }
        if ($choice -eq '2') {
            return [PSCustomObject]@{ Kind = 'self-signed'; CertificatePath = $null; KeyPath = $null }
        }
        if ($choice -eq '3' -and $canOfferStaged) {
            return [PSCustomObject]@{ Kind = 'staged'; CertificatePath = $null; KeyPath = $null }
        }
        Write-DeltaWarning "'$choice' is not a valid option."
    }
}

function Get-DeltaCertificateForActivation {
    <#
      Collects, converts, validates and gates a certificate - everything that
      must be true before anything on the installation is touched.

      Returns a validated PEM pair plus the coverage verdict, or a named
      reason.

      One thing here CAN write into the live configuration, and only with the
      operator's explicit answer: when the certificate is valid but names a
      different host than the current primary domain, the certificate's own
      names are offered as primary domains and the chosen one is applied
      through Domain Management. When that happens the refreshed domain model
      is returned in DomainModel and a record of the change in Remediation, and
      the caller must use both - the model because everything downstream is
      built from the primary domain, and the record because a later failure has
      to undo it.

      Everything else is read-only: the staging directory is this installer's
      own temporary path, and the operator's source files are only ever read.

      -PrimaryDomainChoice pre-answers the remediation question instead of
      asking: a domain name accepts that domain, 'decline' keeps the current
      primary. It exists so the flow can be exercised without a console, and it
      is the same injection the -Source parameter already provides for the
      certificate itself.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$DomainModel,
        [Parameter(Mandatory)][string]$StagingDirectory,
        [object]$Source,
        [string]$PrimaryDomainChoice,
        [bool]$AllowPrompt = $true,
        [bool]$OfferStaged = $false
    )

    $result = [PSCustomObject]@{
        Succeeded       = $false
        Cancelled       = $false
        Reason          = $null
        CertificatePath = $null
        KeyPath         = $null
        TlsMode         = 'supplied'
        Validation      = $null
        Gate            = $null
        DomainModel     = $DomainModel
        Remediation     = $null
    }

    $pending = $Source

    while ($true) {
        $chosen = $pending
        $pending = $null

        if (-not $chosen) {
            if (-not $AllowPrompt) {
                $result.Cancelled = $true
                $result.Reason = 'No certificate was supplied and this run is non-interactive. Nothing was changed.'
                return $result
            }
            $chosen = Read-DeltaCertificateSource -InstallRoot $InstallRoot -OfferStaged $OfferStaged
            if (-not $chosen) {
                $result.Cancelled = $true
                $result.Reason = 'Cancelled. Nothing was changed.'
                return $result
            }
        }

        $resolved = $null

        if ($chosen.Kind -eq 'self-signed') {
            # Phase 4's generator, which since Domain Management covers the
            # whole configured domain set rather than the primary alone.
            # Generated into the staging directory, never straight into certs\:
            # nothing reaches the live directory before it has been validated.
            $generated = New-DeltaSelfSignedCertificate -HostName $DomainModel.Primary `
                -OutputDirectory $StagingDirectory -OpenSslImage $Configuration.DbImage `
                -AdditionalName @($DomainModel.Additional)
            if (-not $generated.Succeeded) {
                Write-DeltaFailure $generated.Reason
                if (-not $AllowPrompt) { $result.Reason = $generated.Reason; return $result }
                continue
            }
            $result.TlsMode = 'self-signed'
            $resolved = Resolve-DeltaCertificateInput -InstallRoot $InstallRoot -Configuration $Configuration `
                -Kind 'pem' -CertificatePath $generated.CertificatePath -KeyPath $generated.KeyPath `
                -StagingDirectory $StagingDirectory
        }
        else {
            $kind = $chosen.Kind
            $result.TlsMode = if ($kind -eq 'staged' -and $Configuration.TlsMode -and $Configuration.TlsMode -ne 'none') { $Configuration.TlsMode } else { 'supplied' }

            $resolved = Resolve-DeltaCertificateInput -InstallRoot $InstallRoot -Configuration $Configuration `
                -Kind $kind -CertificatePath $chosen.CertificatePath -KeyPath $chosen.KeyPath `
                -StagingDirectory $StagingDirectory
        }

        if (-not $resolved.Succeeded) {
            Write-DeltaFailure ''
            Write-DeltaFailure 'The certificate cannot be used.'
            Write-Detail $resolved.Reason
            Write-Detail 'Nothing has been changed.'
            if (-not $AllowPrompt) { $result.Reason = $resolved.Reason; return $result }
            Write-Host ''
            if (-not (Read-DeltaYesNoConfirmation -Body { Write-Host 'Try a different certificate?' })) {
                $result.Cancelled = $true
                $result.Reason = "Cancelled after a validation failure: $($resolved.Reason)"
                return $result
            }
            continue
        }

        $result.Validation = $resolved.Validation
        Write-Detail "[ ok ]     subject $($resolved.Validation.Subject)"
        Write-Detail '[ ok ]     the private key matches the certificate'
        Write-Detail "[ ok ]     valid until $($resolved.Validation.NotAfter.ToString('yyyy-MM-dd'))"
        if ($resolved.Validation.Warning) { Write-DeltaWarning $resolved.Validation.Warning }

        # --- the primary-domain gate ---------------------------------------
        $gate = Test-DeltaCertificateActivation -CertificatePath $resolved.CertificatePath -DomainModel $result.DomainModel
        $result.Gate = $gate

        if (-not $gate.Allowed) {
            Write-DeltaFailure ''
            Write-DeltaFailure 'The certificate was refused.'
            Write-Detail $gate.Reason

            # --- offer the certificate's own names as the primary domain ----
            # The refusal above stands. What follows is an offer to change the
            # thing that makes it a refusal, using the names this certificate
            # already carries - not a way around the check. If the operator
            # declines, or there is nothing usable to offer, the refusal is
            # exactly what it was before.
            $candidates = @(Get-DeltaCertificateCandidateDomain -CertificateName $gate.Coverage.Names -DomainModel $result.DomainModel)
            $chosenDomain = $null

            if ($candidates.Count -gt 0) {
                if ($PSBoundParameters.ContainsKey('PrimaryDomainChoice') -and $PrimaryDomainChoice) {
                    if ($PrimaryDomainChoice -ne 'decline') {
                        $normalized = ConvertTo-DeltaDomainName -Value $PrimaryDomainChoice
                        if (@($candidates | ForEach-Object { $_.Domain }) -contains $normalized) { $chosenDomain = $normalized }
                        else {
                            $result.Reason = "$PrimaryDomainChoice is not one of the domains this certificate covers."
                            return $result
                        }
                    }
                }
                elseif ($AllowPrompt) {
                    $chosenDomain = Read-DeltaCertificatePrimaryDomainChoice -Candidate $candidates `
                        -DomainModel $result.DomainModel -CertificateName $gate.Coverage.Names
                }
            }

            if ($chosenDomain) {
                $remediation = Invoke-DeltaCertificateDomainRemediation -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
                    -Configuration $Configuration -DomainModel $result.DomainModel `
                    -Domain $chosenDomain -CertificatePath $resolved.CertificatePath
                $result.Remediation = $remediation

                if (-not $remediation.Succeeded) {
                    Write-DeltaFailure ''
                    Write-DeltaFailure $remediation.Reason
                    Write-Detail 'The certificate was not installed.'
                    $result.Reason = $remediation.Reason
                    return $result
                }

                # Everything downstream is built from the primary domain, so the
                # model is re-read rather than patched, and the gate is asked
                # again against it - the promotion is not assumed to have made
                # the certificate acceptable, it is checked.
                $result.DomainModel = Get-DeltaDomainModel -InstallRoot $InstallRoot -Configuration (Get-DeltaStackConfiguration -InstallRoot $InstallRoot)
                $gate = Test-DeltaCertificateActivation -CertificatePath $resolved.CertificatePath -DomainModel $result.DomainModel
                $result.Gate = $gate

                if (-not $gate.Allowed) {
                    Write-DeltaFailure ''
                    Write-DeltaFailure "The certificate still does not cover the primary domain after the change: $($gate.Reason)"
                    $null = Undo-DeltaCertificateDomainRemediation -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Remediation $remediation
                    $result.Remediation = $null
                    $result.DomainModel = Get-DeltaDomainModel -InstallRoot $InstallRoot -Configuration (Get-DeltaStackConfiguration -InstallRoot $InstallRoot)
                    $result.Reason = $gate.Reason
                    return $result
                }

                Write-Success $remediation.Reason
                # Falls through to the acceptance path below with the SAME
                # certificate and key: the operator is never asked for the
                # files a second time.
            }
            else {
                Write-Detail ''
                Write-Detail "Either supply a certificate that covers $($result.DomainModel.Primary), or use Domain"
                Write-Detail 'Management (menu option 8) to make a domain this certificate does cover the'
                Write-Detail 'primary one.'
                if (-not $AllowPrompt) { $result.Reason = $gate.Reason; return $result }
                Write-Host ''
                if (-not (Read-DeltaYesNoConfirmation -Body { Write-Host 'Try a different certificate?' })) {
                    $result.Cancelled = $true
                    $result.Reason = $gate.Reason
                    return $result
                }
                continue
            }
        }

        if (-not $gate.PrimaryDetermined) {
            Write-DeltaWarning $gate.Reason
        }
        else {
            Write-Detail "[ ok ]     covers the primary domain $($result.DomainModel.Primary)"
            foreach ($uncovered in $gate.UncoveredAdditional) {
                Write-DeltaWarning "The additional domain $uncovered is NOT covered by this certificate. NGINX will still serve it, and browsers reaching DELTA by it will warn."
            }
        }

        $result.CertificatePath = $resolved.CertificatePath
        $result.KeyPath         = $resolved.KeyPath
        $result.Succeeded       = $true
        return $result
    }
}

# ---------------------------------------------------------------------------
# Primary-domain remediation
#
# A certificate that validates perfectly but names a different host than the
# current primary domain is not a broken certificate - it is very often a
# correct certificate arriving before the domain has been made primary. The
# gate above still refuses it, because PUBLIC_URL must not knowingly point at a
# hostname the serving certificate cannot validate. What changes here is what
# happens next: instead of sending the operator away to Domain Management and
# back again, the names already extracted from the certificate are offered as
# primary domains.
#
# Every domain mutation below goes through Domain Management's own functions.
# There is no second implementation of adding or promoting a domain, and the
# undo path uses the same three functions in reverse.
# ---------------------------------------------------------------------------

function Get-DeltaCertificateCandidateDomain {
    <#
      The certificate's own DNS names, filtered to those that could actually
      become this installation's primary domain, in the order they should be
      offered.

      Filtered by Test-DeltaDomainName - Domain Management's rule, not a second
      one - so a wildcard, an IPv6 literal or anything malformed is dropped
      rather than promoted. A wildcard SAN is a real and common thing to find
      on a certificate; it is not a hostname DELTA can be reached at, and
      offering *.example.org as a primary domain would produce a PUBLIC_URL
      nobody can type.

      Already-configured domains come first. Promoting a domain the operator
      has already declared is a smaller change than inventing one, so it is the
      one offered first when both are available.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CertificateName,
        [Parameter(Mandatory)][object]$DomainModel
    )

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($name in $CertificateName) {
        $check = Test-DeltaDomainName -Value $name
        if (-not $check.IsValid) { continue }
        if ($check.Normalized -eq $DomainModel.Primary) { continue }
        if (-not $seen.Add($check.Normalized)) { continue }

        $null = $candidates.Add([PSCustomObject]@{
            Domain       = $check.Normalized
            IsConfigured = ($DomainModel.All -contains $check.Normalized)
        })
    }

    return @(@($candidates | Where-Object { $_.IsConfigured }) + @($candidates | Where-Object { -not $_.IsConfigured }))
}

function Read-DeltaCertificatePrimaryDomainChoice {
    <#
      Offers the certificate's usable names as primary domains, and returns the
      chosen one or $null for "keep the current primary".

      One candidate is offered as a yes/no question, because that is what it is.
      Several are offered as a numbered list, because picking the first one on
      the operator's behalf would be exactly the blind choice this is meant to
      avoid - a certificate carrying four SANs does not say which of them the
      installation should call itself.

      There is no bare-Enter default, and Enter keeps the current primary: the
      safe answer is the one that changes nothing.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Candidate,
        [Parameter(Mandatory)][object]$DomainModel,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CertificateName
    )

    Write-Host ''
    Write-Host 'The certificate does not cover the current primary domain:'
    Write-Host ''
    Write-Detail $DomainModel.Primary
    Write-Host ''
    Write-Host 'The certificate is valid for:'
    Write-Host ''
    foreach ($name in $CertificateName) { Write-Detail $name }
    Write-Host ''

    if ($Candidate.Count -eq 1) {
        $only = $Candidate[0].Domain
        Write-Host "Would you like to use $only as the primary domain?"
        Write-Host ''
        Write-Host "  1. Yes - Make it the primary domain and continue"
        Write-Host "  2. No  - Keep the current primary domain"
        Write-Host ''
        while ($true) {
            $choice = ([string](Read-Host -Prompt 'Selection')).Trim()
            if ($choice -eq '1') { return $only }
            if ($choice -eq '2' -or $choice -eq '0' -or $choice -eq '') { return $null }
            Write-DeltaWarning "'$choice' is not a valid option."
        }
    }

    Write-Host 'Which of them should become the primary domain?'
    Write-Host ''
    for ($i = 0; $i -lt $Candidate.Count; $i++) {
        $suffix = if ($Candidate[$i].IsConfigured) { '   (already configured)' } else { '   (will be added)' }
        Write-Host ("  {0}. {1}{2}" -f ($i + 1), $Candidate[$i].Domain, $suffix)
    }
    Write-Host ("  {0}. None - Keep the current primary domain ({1})" -f ($Candidate.Count + 1), $DomainModel.Primary)
    Write-Host ''

    while ($true) {
        $choice = ([string](Read-Host -Prompt 'Selection')).Trim()
        if ($choice -eq '' -or $choice -eq '0') { return $null }
        $index = 0
        if ([int]::TryParse($choice, [ref]$index)) {
            if ($index -ge 1 -and $index -le $Candidate.Count) { return $Candidate[$index - 1].Domain }
            if ($index -eq ($Candidate.Count + 1)) { return $null }
        }
        Write-DeltaWarning "'$choice' is not a valid option."
    }
}

function Invoke-DeltaCertificateDomainRemediation {
    <#
      Makes a certificate-covered domain the primary one, through Domain
      Management's own functions and nothing else.

      Two steps, in this order, both of which are already transactional in
      their own right: add the domain if it is not configured yet, then promote
      it. Each regenerates and validates NGINX and puts itself back if that
      fails, so there is no half-applied domain state to invent handling for -
      what this function adds is a record of what it did, so the caller can
      reverse it if the certificate transaction that follows fails.

      -CoverageCertificatePath is passed to the promotion so the HTTPS
      invariant is judged against the certificate that is about to serve the
      URL. On an installation that is still HTTP the invariant does not apply
      at all; on one already serving HTTPS the outgoing certificate would
      otherwise refuse a promotion the incoming one makes correct.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$DomainModel,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$CertificatePath
    )

    $result = [PSCustomObject]@{
        Succeeded       = $false
        Reason          = $null
        Stage           = 'start'
        Domain          = $Domain
        PreviousPrimary = $DomainModel.Primary
        DomainWasAdded  = $false
        PromotionApplied = $false
    }

    # --- add, if it is not configured yet ---------------------------------
    if ($DomainModel.All -notcontains $Domain) {
        $result.Stage = 'add'
        Write-Step "Adding $Domain to the configured domains"
        $added = Invoke-DeltaDomainAdd -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
            -Configuration $Configuration -Model $DomainModel -Domain $Domain -AllowPrompt $false
        if (-not $added.Succeeded) {
            $result.Reason = "$Domain could not be added to the configured domains: $($added.Reason)"
            return $result
        }
        $result.DomainWasAdded = $true
    }

    # --- promote ----------------------------------------------------------
    $result.Stage = 'promote'
    Write-Step "Making $Domain the primary domain"
    $current = Get-DeltaDomainModel -InstallRoot $InstallRoot -Configuration (Get-DeltaStackConfiguration -InstallRoot $InstallRoot)
    $promoted = Invoke-DeltaDomainSetPrimary -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
        -Configuration (Get-DeltaStackConfiguration -InstallRoot $InstallRoot) -Model $current `
        -Domain $Domain -CoverageCertificatePath $CertificatePath -AllowPrompt $false

    if (-not $promoted.Succeeded) {
        $result.Reason = "$Domain could not be made the primary domain: $($promoted.Reason)"
        # The add, if there was one, is left in place deliberately: it is a
        # configured domain the operator asked for and NGINX is already serving
        # it. The caller's undo removes it if the whole operation is abandoned.
        return $result
    }
    $result.PromotionApplied = -not ($promoted.PSObject.Properties.Name -contains 'NoOp' -and $promoted.NoOp)

    $result.Stage = 'complete'
    $result.Succeeded = $true
    $result.Reason = "$Domain is now the primary domain."
    return $result
}

function Undo-DeltaCertificateDomainRemediation {
    <#
      Puts the primary domain back the way it was, and removes a domain that
      was added only for this operation.

      Reached when the certificate transaction that the promotion was made for
      subsequently fails. Without it a failed Enable HTTPS would leave the
      installation renamed - the domain change would have survived the very
      operation it was made to enable, which is the partial state the
      transaction rules exist to prevent.

      Same three Domain Management functions as the forward path, in reverse,
      and each is transactional in its own right. It reports what it managed
      rather than claiming success: a rollback that lies is worse than none.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Remediation
    )

    $result = [PSCustomObject]@{ PrimaryRestored = $false; DomainRemoved = $false; Reason = $null }
    if (-not $Remediation -or -not $Remediation.Succeeded) { return $result }

    Write-Step "Putting the primary domain back to $($Remediation.PreviousPrimary)"

    if ($Remediation.PromotionApplied) {
        $configuration = Get-DeltaStackConfiguration -InstallRoot $InstallRoot
        $model = Get-DeltaDomainModel -InstallRoot $InstallRoot -Configuration $configuration
        # No -CoverageCertificatePath: this is going back to the domain that was
        # primary before, which the installed certificate already covered if it
        # covered anything - the ordinary invariant is the right one here.
        $back = Invoke-DeltaDomainSetPrimary -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
            -Configuration $configuration -Model $model -Domain $Remediation.PreviousPrimary -AllowPrompt $false
        $result.PrimaryRestored = [bool]$back.Succeeded
        if (-not $back.Succeeded) {
            $result.Reason = "The primary domain could not be put back to $($Remediation.PreviousPrimary): $($back.Reason)"
            return $result
        }
    }
    else {
        $result.PrimaryRestored = $true
    }

    if ($Remediation.DomainWasAdded) {
        $configuration = Get-DeltaStackConfiguration -InstallRoot $InstallRoot
        $model = Get-DeltaDomainModel -InstallRoot $InstallRoot -Configuration $configuration
        $removed = Invoke-DeltaDomainRemove -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
            -Configuration $configuration -Model $model -Domain $Remediation.Domain -AllowPrompt $false
        $result.DomainRemoved = [bool]$removed.Succeeded
        if (-not $removed.Succeeded) {
            $result.Reason = "$($Remediation.Domain) was added for this operation and could not be removed again: $($removed.Reason)"
        }
    }

    if (-not $result.Reason) {
        Write-Detail "The primary domain is $($Remediation.PreviousPrimary) again."
    }
    return $result
}

function New-DeltaCertificateStaging {
    <#
      A private working directory for one certificate operation, under the
      installation root rather than in the user's temp: material passing
      through it includes a private key, and the installer's own tree is where
      this product already keeps such things. Removed by the caller in a
      finally block, whatever happened.
    #>
    param([Parameter(Mandatory)][string]$InstallRoot)

    $path = Join-Path -Path $InstallRoot -ChildPath ("certs\.staging-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $path -Force

    # Hardened after creation, and a hardening failure must not throw: the
    # caller records the returned path and removes it in a finally block, so
    # throwing between the mkdir and the return orphans the directory inside
    # certs\ with nobody left holding its name. It inherits certs\'s own
    # protection either way; the explicit ACL is a tightening, not the only
    # thing standing between this and the world.
    try { Protect-DeltaSecretFile -Path $path }
    catch { Write-DeltaWarning "The certificate staging directory could not be ACL-restricted: $($_.Exception.Message)" }

    return $path
}

function Remove-DeltaCertificateStaging {
    <#
      Removes a staging directory, and tolerates being handed nothing.

      [AllowEmptyString()] as well as [AllowNull()]: PowerShell coerces $null
      bound to a [string] parameter into the empty string, so [AllowNull()]
      alone still throws - which would turn a cleanup call in a finally block
      into a second, louder failure masking the first one.
    #>
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# The four operations
# ---------------------------------------------------------------------------

function Invoke-DeltaTlsEnable {
    <#
      Enable HTTPS, from Management Mode, without setup.ps1 -Reconfigure.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$DomainModel,
        [object]$Source,
        [string]$PrimaryDomainChoice,
        [int]$HttpsPort,
        [bool]$AllowPrompt = $true
    )

    if ($Configuration.TlsEnabled) {
        return [PSCustomObject]@{ Succeeded = $true; Cancelled = $false; Stage = 'no-op'; NoOp = $true
            Reason = 'HTTPS is already enabled. Use Replace Certificate to change the certificate it serves.' }
    }

    # --- the HTTPS port ----------------------------------------------------
    # Through the same resolver installation uses, so a port already held by
    # something else is reported and the incumbent left alone, rather than DELTA
    # being recreated onto a port it cannot bind.
    $candidate = if ($HttpsPort -gt 0) { $HttpsPort } else { [int]$Configuration.HttpsPort }
    if ($candidate -le 0) { $candidate = 443 }
    $port = Resolve-DeltaPort -Purpose 'HTTPS' -Candidate $candidate -Suggested 8443 `
        -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName `
        -OtherPort ([int]$Configuration.HttpPort) -OtherPurpose 'HTTP' -AllowPrompt $AllowPrompt
    if (-not $port.Succeeded) {
        return [PSCustomObject]@{ Succeeded = $false; Cancelled = $false; Stage = 'port'; Reason = $port.Reason }
    }

    $staging = $null
    try {
        $staging = New-DeltaCertificateStaging -InstallRoot $InstallRoot
        $activationArguments = @{
            InstallRoot = $InstallRoot; ScriptRoot = $ScriptRoot; Configuration = $Configuration
            DomainModel = $DomainModel; StagingDirectory = $staging; Source = $Source
            AllowPrompt = $AllowPrompt; OfferStaged = $true
        }
        if ($PSBoundParameters.ContainsKey('PrimaryDomainChoice')) { $activationArguments['PrimaryDomainChoice'] = $PrimaryDomainChoice }
        $certificate = Get-DeltaCertificateForActivation @activationArguments
        if (-not $certificate.Succeeded) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $certificate.Cancelled
                Stage = $(if ($certificate.Cancelled) { 'cancelled' } else { 'certificate' }); Reason = $certificate.Reason }
        }

        # The primary domain may have just changed, at the operator's request,
        # to one this certificate covers. Everything below is built from the
        # refreshed model - the configuration is re-read for the same reason,
        # because the promotion rewrote PUBLIC_URL in .env.
        $remediation = $certificate.Remediation
        $DomainModel = $certificate.DomainModel
        if ($remediation -and $remediation.Succeeded) {
            $Configuration = Get-DeltaStackConfiguration -InstallRoot $InstallRoot
        }

        $newUrl = Get-DeltaPublicUrl -Scheme 'https' -HostName $DomainModel.Primary -Port $port.Port

        Write-Host ''
        Write-Host 'This change'
        Write-Detail "HTTPS                enabled on port $($port.Port)"
        Write-Detail "Primary URL          $($Configuration.PublicUrl)"
        Write-Detail "                  -> $newUrl"
        Write-Detail "Certificate          $($certificate.Validation.Subject)"
        Write-Detail "HTTP port $($Configuration.HttpPort)         kept, and redirects to HTTPS"
        Write-Detail 'Firewall             the installer''s own HTTPS rule is added for that port'
        Write-Detail 'NGINX and DELTA      recreated; the database, its volume and uploads are not touched'

        if ($AllowPrompt) {
            $confirmed = Read-DeltaYesNoConfirmation -Body {
                Write-Host "Enable HTTPS and make $newUrl DELTA's canonical URL?"
                Write-Host ''
                Write-Host 'The candidate configuration is validated with nginx -t before any container is'
                Write-Host 'recreated. If anything fails, the current HTTP configuration is put back and'
                Write-Host 'DELTA is returned to it.'
            }
            if (-not $confirmed) {
                # The promotion happened before this question was asked, so
                # declining here has to undo it - otherwise "nothing was
                # changed" would be untrue.
                $null = Undo-DeltaCertificateDomainRemediation -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Remediation $remediation
                return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'cancelled'
                    Reason = 'Cancelled. HTTPS was not enabled and nothing was changed.' }
            }
        }

        $outcome = Set-DeltaTlsState -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Configuration $Configuration `
            -EnableTls $true -DomainModel $DomainModel -TlsMode $certificate.TlsMode `
            -StagedCertificatePath $certificate.CertificatePath -StagedKeyPath $certificate.KeyPath -HttpsPort $port.Port

        # A promotion made FOR this transaction must not outlive it failing.
        # Set-DeltaTlsState has already put .env, Compose, NGINX and the
        # certificate back from its own snapshot; the domain change was made
        # before that snapshot was taken, so it is this function's to reverse.
        if (-not $outcome.Succeeded -and $remediation -and $remediation.Succeeded) {
            Add-Member -InputObject $outcome -NotePropertyName 'DomainRolledBack' `
                -NotePropertyValue (Undo-DeltaCertificateDomainRemediation -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Remediation $remediation) -Force
        }

        Add-Member -InputObject $outcome -NotePropertyName 'Cancelled' -NotePropertyValue $false -Force
        Add-Member -InputObject $outcome -NotePropertyName 'Gate' -NotePropertyValue $certificate.Gate -Force
        Add-Member -InputObject $outcome -NotePropertyName 'Remediation' -NotePropertyValue $remediation -Force
        Add-Member -InputObject $outcome -NotePropertyName 'SelfSigned' -NotePropertyValue ($certificate.TlsMode -eq 'self-signed') -Force
        return $outcome
    }
    finally {
        Remove-DeltaCertificateStaging -Path $staging
    }
}

function Invoke-DeltaTlsDisable {
    <#
      Return an HTTPS installation to HTTP.

      The certificate and key are deliberately left exactly where they are.
      Deleting them because HTTPS was switched off would destroy material the
      operator may be about to switch back on - and may not have another copy
      of. Preservation is the safe default, and re-enabling offers it back.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$DomainModel,
        [bool]$AllowPrompt = $true
    )

    if (-not $Configuration.TlsEnabled) {
        return [PSCustomObject]@{ Succeeded = $true; Cancelled = $false; Stage = 'no-op'; NoOp = $true
            Reason = 'HTTPS is already disabled. Nothing was changed.' }
    }

    $newUrl = Get-DeltaPublicUrl -Scheme 'http' -HostName $DomainModel.Primary -Port ([int]$Configuration.HttpPort)

    Write-Host ''
    Write-Host 'This change'
    Write-Detail "HTTPS                disabled; port $($Configuration.HttpsPort) is no longer published"
    Write-Detail "Primary URL          $($Configuration.PublicUrl)"
    Write-Detail "                  -> $newUrl"
    Write-Detail "HTTP port $($Configuration.HttpPort)         serves DELTA directly; the HTTPS redirect is removed"
    Write-Detail 'Firewall             the installer''s own HTTPS rule is retired'
    Write-Detail 'Certificate          KEPT in certs\ - nothing is deleted, and it is offered back'
    Write-Detail '                     if HTTPS is enabled again'

    if ($AllowPrompt) {
        $confirmed = Read-DeltaYesNoConfirmation -Body {
            Write-Host 'Disable HTTPS and return DELTA to plain HTTP?'
            Write-Host ''
            Write-Host 'DELTA marks its session cookies Secure, so users reaching this server by'
            Write-Host 'hostname over plain HTTP will not stay signed in. That is the trade-off this'
            Write-Host 'is asking you to accept.'
        }
        if (-not $confirmed) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'cancelled'
                Reason = 'Cancelled. HTTPS is unchanged.' }
        }
    }

    $outcome = Set-DeltaTlsState -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Configuration $Configuration `
        -EnableTls $false -DomainModel $DomainModel

    Add-Member -InputObject $outcome -NotePropertyName 'Cancelled' -NotePropertyValue $false -Force
    return $outcome
}

function Invoke-DeltaCertificateReplace {
    <#
      Replace the certificate on an installation already serving HTTPS.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$DomainModel,
        [object]$Source,
        [string]$PrimaryDomainChoice,
        [bool]$AllowPrompt = $true
    )

    if (-not $Configuration.TlsEnabled) {
        return [PSCustomObject]@{ Succeeded = $false; Cancelled = $false; Stage = 'tls-disabled'
            Reason = 'HTTPS is not enabled, so there is no certificate in use to replace. Choose Enable HTTPS instead.' }
    }

    $staging = $null
    try {
        $staging = New-DeltaCertificateStaging -InstallRoot $InstallRoot
        # -OfferStaged is deliberately off: "replace the certificate with the
        # certificate already installed" is not a replacement.
        $activationArguments = @{
            InstallRoot = $InstallRoot; ScriptRoot = $ScriptRoot; Configuration = $Configuration
            DomainModel = $DomainModel; StagingDirectory = $staging; Source = $Source
            AllowPrompt = $AllowPrompt; OfferStaged = $false
        }
        if ($PSBoundParameters.ContainsKey('PrimaryDomainChoice')) { $activationArguments['PrimaryDomainChoice'] = $PrimaryDomainChoice }
        $certificate = Get-DeltaCertificateForActivation @activationArguments
        if (-not $certificate.Succeeded) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $certificate.Cancelled
                Stage = $(if ($certificate.Cancelled) { 'cancelled' } else { 'certificate' }); Reason = $certificate.Reason }
        }

        # A promotion rewrites PUBLIC_URL and regenerates NGINX, so the
        # configuration this operation acts on is re-read rather than reused.
        $remediation = $certificate.Remediation
        $DomainModel = $certificate.DomainModel
        if ($remediation -and $remediation.Succeeded) {
            $Configuration = Get-DeltaStackConfiguration -InstallRoot $InstallRoot
        }

        $current = Get-DeltaInstalledCertificate -InstallRoot $InstallRoot

        Write-Host ''
        Write-Host 'This change'
        Write-Detail "Replace              $(if ($current.Subject) { $current.Subject } else { '(no readable certificate)' })"
        Write-Detail "                  -> $($certificate.Validation.Subject)"
        Write-Detail "Expires              $($certificate.Validation.NotAfter.ToString('yyyy-MM-dd'))"
        Write-Detail 'PUBLIC_URL, ports    unchanged'
        Write-Detail 'NGINX                reloaded in place; no container is recreated'

        if ($AllowPrompt) {
            $confirmed = Read-DeltaYesNoConfirmation -Body {
                Write-Host 'Replace the certificate NGINX is serving?'
                Write-Host ''
                Write-Host 'The current certificate is copied aside first. If NGINX rejects the new one'
                Write-Host 'it is never signalled, so it carries on serving the current certificate and'
                Write-Host 'the site does not go down.'
            }
            if (-not $confirmed) {
                $null = Undo-DeltaCertificateDomainRemediation -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Remediation $remediation
                return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'cancelled'
                    Reason = 'Cancelled. The certificate in use is unchanged.' }
            }
        }

        $outcome = Set-DeltaCertificateMaterial -InstallRoot $InstallRoot -Configuration $Configuration `
            -CertificatePath $certificate.CertificatePath -KeyPath $certificate.KeyPath -TlsMode $certificate.TlsMode

        # The promotion was made so this replacement could happen. If it did
        # not, the rename does not get to survive it.
        if (-not $outcome.Succeeded -and $remediation -and $remediation.Succeeded) {
            Add-Member -InputObject $outcome -NotePropertyName 'DomainRolledBack' `
                -NotePropertyValue (Undo-DeltaCertificateDomainRemediation -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Remediation $remediation) -Force
        }

        Add-Member -InputObject $outcome -NotePropertyName 'Cancelled' -NotePropertyValue $false -Force
        Add-Member -InputObject $outcome -NotePropertyName 'Gate' -NotePropertyValue $certificate.Gate -Force
        Add-Member -InputObject $outcome -NotePropertyName 'Remediation' -NotePropertyValue $remediation -Force
        Add-Member -InputObject $outcome -NotePropertyName 'SelfSigned' -NotePropertyValue ($certificate.TlsMode -eq 'self-signed') -Force
        return $outcome
    }
    finally {
        Remove-DeltaCertificateStaging -Path $staging
    }
}

function Show-DeltaCertificateInspection {
    <#
      The full inspection view. Reads; changes nothing.

      Everything shown here is public certificate metadata. The private key is
      never opened - its presence is answered from the filesystem - and no
      value from .env appears anywhere on this screen.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$DomainModel
    )

    $certPath = Join-Path -Path $InstallRoot -ChildPath "certs\$Script:DeltaCertificateFileName"
    $keyPath  = Join-Path -Path $InstallRoot -ChildPath "certs\$Script:DeltaCertificateKeyName"
    $detail   = Get-DeltaCertificateDetail -CertificatePath $certPath

    Show-Section -Title 'Certificate' -Subtitle $certPath

    if (-not $detail.Exists) {
        Write-DeltaWarning "There is no certificate at $certPath."
        return $detail
    }
    if (-not $detail.IsReadable) {
        Write-DeltaFailure $detail.Reason
        return $detail
    }

    Write-Host 'Identity'
    Write-Detail "Subject              $($detail.Subject)"
    Write-Detail "Issuer               $($detail.Issuer)"
    if ($detail.SerialNumber) { Write-Detail "Serial number        $($detail.SerialNumber)" }
    Write-Detail "Thumbprint           $($detail.Thumbprint)"
    Write-Detail "Self-signed          $(if ($detail.IsSelfSigned) { 'Yes' } else { 'No' })"
    Write-Host ''

    Write-Host 'Validity'
    Write-Detail "Valid from           $($detail.NotBefore.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Detail "Expires              $($detail.NotAfter.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Detail "Days remaining       $($detail.DaysRemaining)"
    if ($detail.IsExpired) {
        Write-DeltaFailure 'This certificate has EXPIRED. Browsers refuse it.'
    }
    elseif ($detail.IsNotYetValid) {
        Write-DeltaWarning 'This certificate is not valid yet.'
    }
    elseif ($detail.DaysRemaining -le $Script:DeltaCertificateExpiryWarningDays) {
        Write-DeltaWarning "This certificate expires in $($detail.DaysRemaining) day(s). Plan its replacement now."
    }
    Write-Host ''

    # Only what this host could actually read. A blank line would be a claim
    # too; an absent one is not.
    if ($detail.KeyAlgorithm -or $detail.KeySize -or $detail.SignatureAlgorithm) {
        Write-Host 'Key'
        if ($detail.KeyAlgorithm) { Write-Detail "Public key           $($detail.KeyAlgorithm)$(if ($detail.KeySize) { " $($detail.KeySize)-bit" })" }
        if ($detail.SignatureAlgorithm) { Write-Detail "Signature            $($detail.SignatureAlgorithm)" }
        Write-Detail "Private key          $(if (Test-Path -LiteralPath $keyPath -PathType Leaf) { 'Available (Administrators and SYSTEM only)' } else { 'MISSING - NGINX cannot serve HTTPS without it' })"
        Write-Host ''
    }

    Write-Host 'Names on the certificate'
    if (-not $detail.NamesDetermined) {
        Write-DeltaWarning 'They could not be read on this host.'
    }
    else {
        foreach ($name in $detail.SanNames) { Write-Detail $name }
    }
    Write-Host ''

    Write-Host 'Configured domain coverage'
    $coverage = Get-DeltaCertificateDomainCoverage -CertificatePath $certPath -Domains $DomainModel.All
    if (-not $coverage.Determined) {
        Write-DeltaWarning 'Coverage could not be determined on this host.'
    }
    else {
        foreach ($row in $coverage.Rows) {
            $role = if ($row.Domain -eq $DomainModel.Primary) { '(primary)   ' } else { '(additional)' }
            $verdict = if ($row.IsCovered) { 'Covered' } else { 'NOT COVERED' }
            Write-Detail ("{0,-40} {1}  {2}" -f $row.Domain, $role, $verdict)
        }
    }

    if ($detail.IsSelfSigned) {
        Write-Host ''
        Write-DeltaWarning 'This certificate is self-signed. It is not trusted by any browser until it is'
        Write-DeltaWarning 'installed as trusted on each machine that reaches DELTA.'
    }

    Write-Host ''
    return $detail
}

# ---------------------------------------------------------------------------
# Menu option 7
# ---------------------------------------------------------------------------

function Show-DeltaCertificateOutcome {
    <#
      What happened, stated at the level of confidence the evidence supports.

      The verification wording is the careful part. A loopback probe proves the
      transport terminates TLS and DELTA answers through it. It does NOT prove
      that a browser on another machine will trust the certificate or that the
      primary hostname resolves - those depend on DNS and on the trust store,
      neither of which this host can speak for. So the two claims are made
      separately and neither is inflated into the other.
    #>
    param([Parameter(Mandatory)][object]$Outcome)

    Write-Host ''

    if ($Outcome.PSObject.Properties.Name -contains 'NoOp' -and $Outcome.NoOp) {
        Write-Detail $Outcome.Reason
        return
    }

    if ($Outcome.Succeeded) {
        Write-Success $Outcome.Reason

        if ($Outcome.PSObject.Properties.Name -contains 'Remediation' -and $Outcome.Remediation -and $Outcome.Remediation.Succeeded) {
            Write-Detail "Primary domain       $($Outcome.Remediation.PreviousPrimary) -> $($Outcome.Remediation.Domain)"
            if ($Outcome.Remediation.DomainWasAdded) {
                Write-Detail "                     $($Outcome.Remediation.Domain) was added to the configured domains"
            }
            Write-Detail "                     $($Outcome.Remediation.PreviousPrimary) is kept as an additional domain"
        }
        if ($Outcome.PSObject.Properties.Name -contains 'PublicUrl' -and $Outcome.PublicUrl) {
            Write-Detail "PUBLIC_URL           $($Outcome.PublicUrl)"
        }
        if ($Outcome.PSObject.Properties.Name -contains 'Http' -and $Outcome.Http -and $Outcome.Http.Succeeded) {
            Write-Detail "Verified             GET $($Outcome.Http.Url) returned HTTP $($Outcome.Http.StatusCode)"
            if ($Outcome.Http.Url -like 'https://*') {
                Write-Detail '                     that proves this machine terminates TLS and DELTA answers'
                Write-Detail '                     through it. Whether a browser elsewhere trusts the'
                Write-Detail '                     certificate additionally depends on DNS and on that'
                Write-Detail '                     machine trusting the issuer.'
            }
        }
        if ($Outcome.PSObject.Properties.Name -contains 'Firewall' -and $Outcome.Firewall) {
            if ($Outcome.Firewall.Succeeded) {
                $ports = ($Outcome.Firewall.Applied | ForEach-Object { $_.Port }) -join ', '
                if ($ports) { Write-Detail "Firewall             inbound TCP $ports allowed" }
            }
            else {
                Write-DeltaWarning 'The firewall rules could not all be reconciled - see the warning above.'
            }
        }
        if ($Outcome.PSObject.Properties.Name -contains 'Gate' -and $Outcome.Gate -and $Outcome.Gate.UncoveredAdditional.Count -gt 0) {
            Write-Host ''
            Write-DeltaWarning "Not covered by this certificate: $($Outcome.Gate.UncoveredAdditional -join ', ')"
            Write-Detail 'NGINX serves those hostnames and browsers reaching DELTA by them will warn.'
            Write-Detail 'They are additional domains; the primary domain is covered.'
        }
        if ($Outcome.PSObject.Properties.Name -contains 'SelfSigned' -and $Outcome.SelfSigned) {
            Write-Host ''
            Write-DeltaWarning 'The certificate is self-signed, so browsers will warn until it is trusted or'
            Write-DeltaWarning 'replaced. This is not a production configuration.'
        }
        return
    }

    if ($Outcome.Cancelled) {
        Write-Detail $Outcome.Reason
        return
    }

    Write-DeltaFailure 'The change was not applied.'
    Write-Detail "Stage reached        $($Outcome.Stage)"
    Write-Detail $Outcome.Reason
    if ($Outcome.PSObject.Properties.Name -contains 'RolledBack' -and $Outcome.RolledBack) {
        Write-Detail 'The previous configuration was restored.'
        if ($Outcome.Rollback -and -not $Outcome.Rollback.Healthy) {
            Write-DeltaWarning 'DELTA was not answering on the restored configuration when it was checked.'
            Write-Detail 'No database, volume or upload was involved at any point. Check View Logs.'
        }
    }
    if ($Outcome.PSObject.Properties.Name -contains 'Restored' -and $Outcome.Restored) {
        Write-Detail 'The previous certificate is back in place.'
    }
    if ($Outcome.PSObject.Properties.Name -contains 'DomainRolledBack' -and $Outcome.DomainRolledBack) {
        if ($Outcome.DomainRolledBack.PrimaryRestored -and -not $Outcome.DomainRolledBack.Reason) {
            Write-Detail "The primary domain was put back to $($Outcome.Remediation.PreviousPrimary)."
        }
        else {
            Write-DeltaWarning "The primary domain could not be fully put back: $($Outcome.DomainRolledBack.Reason)"
        }
    }
}

function Invoke-DeltaCertificateManagement {
    <#
      Menu option 7.

      Displaying is read-only: entering this screen and leaving it again reads
      .env, the state file and the certificate, and writes none of them.

      The menu adapts to the state, so an HTTP installation is offered Enable
      HTTPS and an HTTPS one is offered replace/inspect/disable. This replaces
      the Phase 10 behaviour of telling an HTTP installation to leave the
      utility and run setup.ps1 -Reconfigure.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [bool]$AllowPrompt = $true
    )

    while ($true) {
        # Re-read every pass: an operation that changed .env must not be
        # followed by a screen drawn from what was true before it.
        $configuration = Get-DeltaStackConfiguration -InstallRoot $InstallRoot
        if (-not $configuration) {
            Write-DeltaFailure "This installation's .env could not be read, so its certificate cannot be managed."
            return $null
        }

        $domainModel = Get-DeltaDomainModel -InstallRoot $InstallRoot -Configuration $configuration
        $certPath = Join-Path -Path $InstallRoot -ChildPath "certs\$Script:DeltaCertificateFileName"
        $detail = Get-DeltaCertificateDetail -CertificatePath $certPath
        $coverage = $null
        if ($configuration.TlsEnabled -and $detail.IsReadable) {
            $coverage = Get-DeltaCertificateDomainCoverage -CertificatePath $certPath -Domains $domainModel.All
        }

        Show-DeltaCertificateScreen -InstallRoot $InstallRoot -Configuration $configuration `
            -DomainModel $domainModel -Detail $detail -Coverage $coverage

        if (-not $AllowPrompt) {
            Write-Host ''
            Write-Detail 'Running non-interactively, so the state above is all this run reports.'
            return $configuration
        }

        $choice = Show-DeltaCertificateMenu -Configuration $configuration

        $pause = $true
        if ($configuration.TlsEnabled) {
            switch ($choice) {
                '' { $pause = $false }
                '0' { return $configuration }
                '1' {
                    $outcome = Invoke-DeltaCertificateReplace -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
                        -Configuration $configuration -DomainModel $domainModel -AllowPrompt $AllowPrompt
                    Show-DeltaCertificateOutcome -Outcome $outcome
                }
                '2' {
                    $null = Show-DeltaCertificateInspection -InstallRoot $InstallRoot -Configuration $configuration -DomainModel $domainModel
                }
                '3' {
                    $outcome = Invoke-DeltaTlsDisable -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
                        -Configuration $configuration -DomainModel $domainModel -AllowPrompt $AllowPrompt
                    Show-DeltaCertificateOutcome -Outcome $outcome
                }
                default { Write-DeltaWarning "'$choice' is not a valid option."; $pause = $false }
            }
        }
        else {
            switch ($choice) {
                '' { $pause = $false }
                '0' { return $configuration }
                '1' {
                    $outcome = Invoke-DeltaTlsEnable -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
                        -Configuration $configuration -DomainModel $domainModel -AllowPrompt $AllowPrompt
                    Show-DeltaCertificateOutcome -Outcome $outcome
                }
                default { Write-DeltaWarning "'$choice' is not a valid option."; $pause = $false }
            }
        }

        if ($pause) {
            Write-Host ''
            Write-Detail 'Press Enter to return to Certificate Management.'
            $null = Read-Host
        }
    }
}

function Invoke-DeltaCertificateOperation {
    <#
      Menu option 7's entry point, matching the shape of the other management
      operations so the dispatch table stays uniform.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [bool]$AllowPrompt = $true
    )

    return (Invoke-DeltaCertificateManagement -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
        -Configuration $Configuration -AllowPrompt $AllowPrompt)
}
