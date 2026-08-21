# =============================================================================
# Delta.Domain.ps1 - Domain Management (menu option 8)
#
# Dot-source Delta.Common.ps1, Delta.Config.ps1, Delta.Docker.ps1,
# Delta.Stack.ps1, Delta.Network.ps1 and Delta.Manage.ps1 first. This file
# composes their primitives and implements none of them again:
#
#   the domain model, validation, normalisation    Delta.Config.ps1
#   PUBLIC_URL construction and parsing            Delta.Network.ps1
#   certificate name/coverage inspection           Delta.Network.ps1
#   NGINX generation                               Delta.Stack.ps1
#   nginx -t, nginx -s reload, the endpoint probe  Delta.Stack/Network
#   .env mutation                                  Delta.Config.ps1
#   recreating the application container           Delta.Configure.ps1
#
# What lives here is the operator-facing screen and the transaction that keeps
# persistent state and the running NGINX from disagreeing.
#
# Assessment references: A§8.3 (NGINX generation and validation), A§11
# (HTTPS and certificates), A§17.3 (management menu), A§24 (blast radius).
# =============================================================================

# ---------------------------------------------------------------------------
# The distinction this whole feature rests on
#
#   PUBLIC_URL      ONE canonical URL. The address DELTA calls itself by.
#   primary domain  its host part. Exactly one, always.
#   additional      further hostnames NGINX accepts. Not URLs, not alternative
#                   PUBLIC_URLs, and never shown as though they were.
#
# Domain Management owns hostnames. It does not own TLS enablement, it does not
# issue or delete certificates, and it does not touch ports or firewall rules -
# firewall rules are keyed on ports, and no port changes here.
# ---------------------------------------------------------------------------

function Get-DeltaDomainNetworkShape {
    <#
      The object New-DeltaNginxConfiguration expects, built from an
      installation that already exists plus a candidate primary domain.

      The certificate paths are the fixed container paths Install-DeltaCertificate
      stages to, from the same two constants the installer has always used - not
      re-derived, and never a Windows path: the generated configuration names
      files inside the read-only certs mount.
    #>
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$Primary
    )

    return [PSCustomObject]@{
        HostName        = $Primary
        HttpPort        = [int]$Configuration.HttpPort
        HttpsPort       = [int]$Configuration.HttpsPort
        TlsEnabled      = [bool]$Configuration.TlsEnabled
        TlsMode         = $Configuration.TlsMode
        CertificateFile = "/etc/nginx/certs/$Script:DeltaCertificateFileName"
        KeyFile         = "/etc/nginx/certs/$Script:DeltaCertificateKeyName"
    }
}

function Get-DeltaDomainCertificateState {
    <#
      What the certificate in use covers, for a candidate domain set.

      Returns $null when TLS is off - there is no certificate, and reporting
      coverage for one that does not exist would be inventing a problem. When
      TLS is on but the names cannot be read, Determined is false and the caller
      says so rather than claiming the domains are uncovered.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Domains
    )

    if (-not $Configuration.TlsEnabled) { return $null }

    $installed = Get-DeltaInstalledCertificate -InstallRoot $InstallRoot
    if (-not $installed.Exists) {
        return [PSCustomObject]@{
            Determined = $false
            Reason     = "TLS is enabled but there is no certificate at $($installed.CertificatePath)."
            Names      = @()
            Subject    = $null
            Rows       = @()
            Uncovered  = @($Domains)
            CoversAll  = $false
            CertificatePath = $installed.CertificatePath
        }
    }

    return (Get-DeltaCertificateDomainCoverage -CertificatePath $installed.CertificatePath -Domains $Domains)
}

function Write-DeltaDomainCoverageLine {
    <#
      One line about one domain's certificate coverage, in the three states
      that are actually distinguishable: covered, not covered, and not
      determinable. The third is never printed as the second.
    #>
    param(
        [Parameter(Mandatory)][string]$Domain,
        [object]$Coverage
    )

    if (-not $Coverage) { return }

    if (-not $Coverage.Determined) {
        Write-DeltaWarning "Certificate coverage for $Domain could not be determined."
        if ($Coverage.Reason) { Write-Detail "  $($Coverage.Reason)" }
        Write-Detail '  Check it in Certificate Management before relying on HTTPS for this domain.'
        return
    }

    $row = $Coverage.Rows | Where-Object { $_.Domain -eq $Domain } | Select-Object -First 1
    if (-not $row) { return }

    if ($row.IsCovered) {
        if ($row.MatchedBy -and $row.MatchedBy -ne $Domain) {
            Write-Detail "The active certificate covers $Domain (matched by $($row.MatchedBy))."
        }
        else {
            Write-Detail "The active certificate covers $Domain."
        }
        return
    }

    Write-DeltaWarning "The active certificate does not cover $Domain."
    Write-Detail "  It is valid for: $($Coverage.Names -join ', ')"
    Write-Detail '  NGINX will serve that hostname, and browsers reaching DELTA by it will show a'
    Write-Detail '  certificate warning until the certificate is replaced with one that covers it.'
    Write-Detail '  Replace it through Certificate Management (menu option 7).'
}

# ---------------------------------------------------------------------------
# The transaction
#
# Build candidate, validate candidate, apply, persist, verify - in that order,
# and with the previous configuration put back at every step that fails. The
# ordering is chosen so the two things that must agree - what NGINX serves and
# what is persisted - are never left disagreeing by a failure:
#
#   1. the candidate NGINX configuration is written, with the previous contents
#      held in memory
#   2. nginx -t reads it. A rejection restores the previous file and stops.
#      NGINX was never signalled, so it is still serving the old set from
#      memory and the site never went down.
#   3. nginx -s reload applies it. A failure restores and reloads back.
#   4. only now is anything persisted. At this point the runtime is already
#      serving the candidate set, so a persistence failure is recoverable by
#      putting the runtime back - which is what it does.
#   5. the result is verified against the running installation.
#
# There is no window in which the live NGINX configuration is a file that has
# not been validated.
# ---------------------------------------------------------------------------

function Set-DeltaDomainConfiguration {
    <#
      Applies a candidate domain set: regenerate, validate, reload, persist,
      verify - with rollback.

      -NewPrimary changes PUBLIC_URL and DELTA_HOSTNAME; omitting it leaves both
      exactly as they are, which is what Add Domain and Remove Domain need. The
      scheme and port are never touched: they are read from the installation and
      fed back through Get-DeltaPublicUrl, so an HTTP installation stays HTTP
      and an HTTPS installation stays HTTPS. Domain Management cannot enable or
      disable TLS, by construction rather than by promise.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$Model,
        [string]$NewPrimary,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$NewAdditional,
        [Parameter(Mandatory)][string]$Description
    )

    $result = [PSCustomObject]@{
        Succeeded     = $false
        Stage         = 'start'
        Reason        = $null
        Primary       = $null
        Additional    = @()
        ServerName    = $null
        NginxTest     = $null
        Reloaded      = $false
        RolledBack    = $false
        PublicUrl     = $null
        PrimaryChanged = $false
        Application   = $null
        Http          = $null
    }

    $primary = if ($NewPrimary) { ConvertTo-DeltaDomainName -Value $NewPrimary } else { $Model.Primary }
    $result.PrimaryChanged = ($primary -ne $Model.Primary)

    # The candidate set, through the one boundary. Anything that is not a plain
    # hostname stops here, before a byte is written.
    $ordered = @(Get-DeltaDomainNameList -Primary $primary -Additional $NewAdditional)
    $result.Primary    = $ordered[0]
    $result.Additional = @($ordered | Select-Object -Skip 1)
    $result.ServerName = ($ordered -join ' ')

    # --- NGINX must be there to validate against ---------------------------
    # Without it the candidate could be written but neither tested nor applied,
    # and persisting a set nothing is serving is exactly the drift this
    # transaction exists to prevent.
    $services = @(Get-DeltaComposeServiceStatus -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName)
    $nginx = $services | Where-Object { $_.Service -eq 'nginx' } | Select-Object -First 1
    if (-not $nginx -or $nginx.State -ne 'running') {
        $result.Stage = 'nginx-unavailable'
        $result.Reason = 'NGINX is not running, so a domain change could be neither validated nor applied. Nothing was changed.'
        return $result
    }

    # --- 1. write the candidate -------------------------------------------
    $result.Stage = 'generate'
    Write-Step 'Regenerating the NGINX configuration'
    $generated = $null
    try {
        $generated = New-DeltaNginxConfiguration -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
            -Network (Get-DeltaDomainNetworkShape -Configuration $Configuration -Primary $result.Primary) `
            -AdditionalDomain $result.Additional
    }
    catch {
        $result.Reason = "The NGINX configuration could not be generated: $($_.Exception.Message). Nothing was changed."
        return $result
    }
    Write-Detail "server_name $($result.ServerName);"

    $restore = {
        # One rollback, used by every failure path below, so "we put it back"
        # is the same operation everywhere.
        if ($null -ne $generated.Previous) {
            Write-DeltaFileAtomic -Path $generated.Path -Content $generated.Previous
            $result.RolledBack = $true
            Write-Detail 'The previous NGINX configuration has been put back.'
        }
    }

    # --- 2. nginx -t -------------------------------------------------------
    $result.Stage = 'nginx-test'
    Write-Step 'Validating the generated configuration'
    $result.NginxTest = Test-DeltaNginxConfiguration -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName

    if ($result.NginxTest.Tested -and -not $result.NginxTest.Succeeded) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'NGINX rejected the generated configuration. It has NOT been reloaded.'
        foreach ($line in ($result.NginxTest.Output -split "`r?`n")) { if ($line.Trim()) { Write-Detail "  $line" } }
        & $restore
        Write-Detail 'NGINX was never signalled, so it has been serving the previous domains throughout.'
        $result.Reason = 'nginx -t rejected the generated configuration, so nothing was applied or recorded.'
        return $result
    }
    if (-not $result.NginxTest.Tested) {
        & $restore
        $result.Stage = 'nginx-unavailable'
        $result.Reason = "The generated configuration could not be validated ($($result.NginxTest.Reason)). Nothing was applied or recorded."
        return $result
    }
    Write-Detail '[ ok ]     nginx -t accepted the generated configuration'

    # --- 3. reload ---------------------------------------------------------
    $result.Stage = 'reload'
    Write-Step 'Reloading NGINX'
    $result.Reloaded = Invoke-DeltaNginxReload -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName
    if (-not $result.Reloaded) {
        Write-DeltaFailure ''
        Write-DeltaFailure 'NGINX would not reload.'
        & $restore
        $null = Invoke-DeltaNginxReload -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName
        Write-Detail 'No container was recreated. Check `docker compose logs nginx`.'
        $result.Reason = 'NGINX did not accept the reload signal, so nothing was recorded.'
        return $result
    }
    Write-Detail '[ ok ]     reload accepted; no container was recreated'

    # --- 4. persist --------------------------------------------------------
    $result.Stage = 'persist'
    $envPath = Join-Path -Path $InstallRoot -ChildPath '.env'
    $publicUrl = Get-DeltaPublicUrl -Scheme $Model.Scheme -HostName $result.Primary -Port ([int]$Model.Port)
    $result.PublicUrl = $publicUrl

    try {
        if ($result.PrimaryChanged) {
            # Exactly the two keys that depend on the canonical hostname. Every
            # other value in .env is left alone - Set-DeltaEnvValues updates
            # keys in place, preserves comments, ordering and the file's
            # newline style, and re-applies the Administrators + SYSTEM ACL.
            Set-DeltaEnvValues -Path $envPath -Values ([ordered]@{
                DELTA_HOSTNAME = $result.Primary
                PUBLIC_URL     = $publicUrl
            })
            Write-Detail "PUBLIC_URL   $publicUrl"
        }

        $stateFields = [ordered]@{}
        if ($result.PrimaryChanged) {
            # The state file's own record of what the installer wrote, kept
            # honest for the same reason .env is.
            $stateFields['hostname']  = $result.Primary
            $stateFields['publicUrl'] = $publicUrl
        }
        $null = Set-DeltaPersistedDomain -InstallRoot $InstallRoot -Additional $result.Additional -AdditionalProperties $stateFields
    }
    catch {
        Write-DeltaFailure ''
        Write-DeltaFailure "The change was applied to NGINX but could not be recorded: $($_.Exception.Message)"
        Write-Step 'Putting NGINX back'
        & $restore
        $null = Invoke-DeltaNginxReload -InstallRoot $InstallRoot -ProjectName $Configuration.ProjectName
        Write-Detail 'NGINX is serving the previous domains again, so the recorded configuration and'
        Write-Detail 'what is actually served still agree.'
        $result.Reason = "The domain configuration could not be recorded: $($_.Exception.Message)"
        return $result
    }

    # --- 5. the application container, only when PUBLIC_URL changed --------
    # Adding or removing an accepted hostname changes NGINX and nothing else,
    # so no container is touched. Changing the primary changes PUBLIC_URL, and
    # DELTA reads that from its environment at start - so the container has to
    # be recreated for the canonical URL it reports to be the one now
    # configured. This is the same primitive the SMTP flow uses for the same
    # reason, not a second implementation of it.
    if ($result.PrimaryChanged) {
        $result.Stage = 'application'
        Write-Step 'Applying the new canonical URL to the DELTA container'
        $result.Application = Update-DeltaApplicationContainer -InstallRoot $InstallRoot -Configuration $Configuration
        if (-not $result.Application.Succeeded) {
            Write-DeltaWarning "The DELTA container did not come back cleanly: $($result.Application.Reason)"
            Write-Detail 'The domain configuration is recorded and NGINX is serving it. The application'
            Write-Detail 'container is the part that needs attention - check View Logs.'
            $result.Reason = "The domain configuration was applied, but the DELTA container did not come back cleanly: $($result.Application.Reason)"
            return $result
        }
    }

    # --- 6. verify ---------------------------------------------------------
    $result.Stage = 'verify'
    $loopback = (Get-DeltaPublicUrl -Scheme $Model.Scheme -HostName 'localhost' -Port ([int]$Model.Port)) + '/'
    $result.Http = Test-DeltaHttpEndpoint -Url $loopback -TimeoutSeconds 30
    if (-not $result.Http.Succeeded) {
        Write-DeltaWarning "$loopback did not answer after the change ($(if ($result.Http.Error) { $result.Http.Error } else { "HTTP $($result.Http.StatusCode)" }))."
        Write-Detail 'The configuration is recorded and NGINX accepted it; the site not answering is a'
        Write-Detail 'separate problem - check the status block and View Logs.'
        $result.Reason = "The domain configuration was applied, but $loopback did not answer."
        return $result
    }
    Write-Detail "[ ok ]     GET $loopback returned $($result.Http.StatusCode)"

    $result.Stage = 'complete'
    $result.Succeeded = $true
    $result.Reason = $Description
    return $result
}

# ---------------------------------------------------------------------------
# The screen
# ---------------------------------------------------------------------------

function Show-DeltaDomainScreen {
    <#
      The Domain Management screen: the canonical URL, the primary domain, and
      the additional accepted hostnames - labelled so the difference is obvious
      to somebody who does not know what a server_name is.

      No empty rows. With no additional domains it says so in a sentence.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][object]$Model,
        [object]$Coverage
    )

    Show-Section -Title 'Domain Management' -Subtitle $InstallRoot

    Write-Host 'Primary URL'
    Write-Detail "$(Get-DeltaPublicUrl -Scheme $Model.Scheme -HostName $Model.Primary -Port ([int]$Model.Port))"
    Write-Detail 'The one canonical address DELTA uses for itself. There is exactly one.'
    Write-Host ''

    Write-Host 'Primary domain'
    Write-Detail $Model.Primary
    Write-Host ''

    Write-Host 'Additional domains'
    if ($Model.Additional.Count -eq 0) {
        Write-Detail 'None. NGINX accepts the primary domain only.'
    }
    else {
        foreach ($domain in $Model.Additional) {
            Write-Detail $domain
        }
        Write-Detail ''
        Write-Detail 'NGINX also answers to these hostnames. They are not additional public URLs -'
        Write-Detail 'DELTA still calls itself by the primary URL above.'
    }

    if ($Coverage) {
        Write-Host ''
        Write-Host 'Certificate'
        if (-not $Coverage.Determined) {
            Write-DeltaWarning 'The names the active certificate covers could not be read.'
            if ($Coverage.Reason) { Write-Detail $Coverage.Reason }
        }
        elseif ($Coverage.CoversAll) {
            Write-Detail 'The active certificate covers every configured domain.'
        }
        else {
            Write-DeltaWarning "Not covered by the active certificate: $($Coverage.Uncovered -join ', ')"
            Write-Detail "Valid for: $($Coverage.Names -join ', ')"
            Write-Detail 'Browsers reaching DELTA by an uncovered hostname will warn. Replace the'
            Write-Detail 'certificate through Certificate Management (menu option 7).'
        }
    }
    elseif (-not $Model.Scheme -or $Model.Scheme -eq 'http') {
        Write-Host ''
        Write-Host 'Certificate'
        Write-Detail 'HTTPS is not enabled for this installation, so no certificate is in use.'
    }

    foreach ($warning in $Model.Warnings) {
        Write-Host ''
        Write-DeltaWarning $warning
    }
}

function Show-DeltaDomainMenu {
    param([Parameter(Mandatory)][object]$Model)

    Write-Host ''
    Write-Host '  1. Add Domain'
    if ($Model.Additional.Count -gt 0) {
        Write-Host '  2. Remove Domain'
    }
    else {
        Write-Host '  2. Remove Domain                 (no additional domains to remove)'
    }
    Write-Host '  3. Set Primary Domain'
    Write-Host '  0. Return'
    Write-Host ''

    return ([string](Read-Host -Prompt 'Selection')).Trim()
}

function Read-DeltaDomainChoice {
    <#
      Picks one domain from a list by number, so the operator never retypes a
      hostname the installer already knows. Blank cancels, which is this
      project's "blank means the safe choice" convention.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Domains,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$PrimaryDomain
    )

    Write-Host ''
    for ($i = 0; $i -lt $Domains.Count; $i++) {
        $label = if ($PrimaryDomain -and $Domains[$i] -eq $PrimaryDomain) { "$($Domains[$i])   (primary)" } else { $Domains[$i] }
        Write-Host ("  {0}. {1}" -f ($i + 1), $label)
    }
    Write-Host '  0. Cancel'
    Write-Host ''

    while ($true) {
        $answer = ([string](Read-Host -Prompt $Prompt)).Trim()
        if (-not $answer -or $answer -eq '0') { return $null }

        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $Domains.Count) {
            return $Domains[$index - 1]
        }
        Write-DeltaWarning "Enter a number between 1 and $($Domains.Count), or 0 to cancel."
    }
}

# ---------------------------------------------------------------------------
# The three operations
# ---------------------------------------------------------------------------

function Invoke-DeltaDomainAdd {
    <#
      Add one accepted hostname. PUBLIC_URL does not change - that is the whole
      point of the distinction, and it is stated on the confirmation so the
      operator is not left guessing.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$Model,
        [string]$Domain,
        [bool]$AllowPrompt = $true
    )

    $candidate = $Domain
    while ($true) {
        if (-not $candidate) {
            if (-not $AllowPrompt) {
                return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'input'; Reason = 'No domain was supplied and this run is non-interactive. Nothing was changed.' }
            }
            Write-Host ''
            Write-Host 'Add a hostname NGINX should accept.'
            Write-Detail 'Enter the hostname only - no scheme, no port, no path. For example:'
            Write-Detail '  delta.internal.example.org'
            Write-Detail 'Leave it blank to cancel.'
            Write-Host ''
            $candidate = ([string](Read-Host -Prompt 'Domain')).Trim()
            if (-not $candidate) {
                return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'cancelled'; Reason = 'Cancelled. The configured domains are unchanged.' }
            }
        }

        $check = Test-DeltaDomainName -Value $candidate
        if (-not $check.IsValid) {
            Write-DeltaWarning $check.Reason
            if (-not $AllowPrompt) {
                return [PSCustomObject]@{ Succeeded = $false; Cancelled = $false; Stage = 'validate'; Reason = $check.Reason }
            }
            $candidate = $null
            continue
        }

        if ($Model.All -contains $check.Normalized) {
            $where = if ($check.Normalized -eq $Model.Primary) { 'the primary domain' } else { 'already configured' }
            Write-DeltaWarning "$($check.Normalized) is $where. Nothing was changed."
            if (-not $AllowPrompt) {
                return [PSCustomObject]@{ Succeeded = $false; Cancelled = $false; Stage = 'duplicate'; Reason = "$($check.Normalized) is $where." }
            }
            $candidate = $null
            continue
        }

        break
    }

    $normalized = $check.Normalized
    $newAdditional = @($Model.Additional) + @($normalized)

    Write-Host ''
    Write-Host 'This change'
    Write-Detail "Add                  $normalized"
    Write-Detail "Primary URL          $(Get-DeltaPublicUrl -Scheme $Model.Scheme -HostName $Model.Primary -Port ([int]$Model.Port))  (unchanged)"
    Write-Detail "NGINX will accept    $((Get-DeltaDomainNameList -Primary $Model.Primary -Additional $newAdditional) -join ', ')"

    # An HTTPS installation gets the certificate answer BEFORE the change, not
    # after it, because it may change the operator's mind.
    $coverage = Get-DeltaDomainCertificateState -InstallRoot $InstallRoot -Configuration $Configuration -Domains @($normalized)
    if ($coverage) {
        Write-Host ''
        Write-DeltaDomainCoverageLine -Domain $normalized -Coverage $coverage
    }

    if ($AllowPrompt) {
        $confirmed = Read-DeltaYesNoConfirmation -Body {
            Write-Host "Add $normalized to the hostnames NGINX accepts?"
            Write-Host ''
            Write-Host 'The NGINX configuration is regenerated, validated with nginx -t and reloaded.'
            Write-Host 'No container is recreated. PUBLIC_URL, ports, certificates and firewall rules'
            Write-Host 'are not changed.'
        }
        if (-not $confirmed) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'cancelled'; Reason = 'Cancelled. The configured domains are unchanged.' }
        }
    }

    $outcome = Set-DeltaDomainConfiguration -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
        -Configuration $Configuration -Model $Model -NewAdditional $newAdditional `
        -Description "$normalized added. NGINX accepts it; PUBLIC_URL is unchanged."

    Add-Member -InputObject $outcome -NotePropertyName 'Cancelled' -NotePropertyValue $false -Force
    Add-Member -InputObject $outcome -NotePropertyName 'Domain' -NotePropertyValue $normalized -Force
    Add-Member -InputObject $outcome -NotePropertyName 'Coverage' -NotePropertyValue $coverage -Force
    return $outcome
}

function Invoke-DeltaDomainRemove {
    <#
      Remove one ADDITIONAL hostname.

      The primary is not offered and cannot be reached from here. An operator
      who wants to stop using it sets a different primary first, at which point
      the old one becomes an additional domain and can be removed like any
      other - which is what makes "no primary domain" a state this menu cannot
      produce.

      No certificate material is touched. A certificate that covers a hostname
      NGINX no longer accepts is not a defect, and deleting key material because
      a name was removed from a list would be Domain Management reaching outside
      what it owns.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$Model,
        [string]$Domain,
        [bool]$AllowPrompt = $true
    )

    if ($Model.Additional.Count -eq 0) {
        Write-Host ''
        Write-Detail 'There are no additional domains to remove - NGINX accepts the primary domain only.'
        Write-Detail "The primary domain ($($Model.Primary)) cannot be removed here. To stop using it,"
        Write-Detail 'add another domain, make it primary, and then remove this one.'
        return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'nothing-to-remove'; Reason = 'There are no additional domains to remove.' }
    }

    $target = $null
    if ($Domain) {
        $normalized = ConvertTo-DeltaDomainName -Value $Domain
        if ($normalized -eq $Model.Primary) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $false; Stage = 'primary-protected'; Reason = "$normalized is the primary domain and cannot be removed. Set a different primary domain first." }
        }
        if ($Model.Additional -notcontains $normalized) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $false; Stage = 'not-configured'; Reason = "$normalized is not a configured domain. Nothing was changed." }
        }
        $target = $normalized
    }
    else {
        if (-not $AllowPrompt) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'input'; Reason = 'No domain was supplied and this run is non-interactive. Nothing was changed.' }
        }
        Write-Host ''
        Write-Host 'Remove an additional domain.'
        Write-Detail "The primary domain ($($Model.Primary)) is not listed: it cannot be removed here."
        $target = Read-DeltaDomainChoice -Domains $Model.Additional -Prompt 'Domain to remove'
        if (-not $target) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'cancelled'; Reason = 'Cancelled. The configured domains are unchanged.' }
        }
    }

    $newAdditional = @($Model.Additional | Where-Object { $_ -ne $target })

    Write-Host ''
    Write-Host 'This change'
    Write-Detail "Remove               $target"
    Write-Detail "Primary URL          $(Get-DeltaPublicUrl -Scheme $Model.Scheme -HostName $Model.Primary -Port ([int]$Model.Port))  (unchanged)"
    Write-Detail "NGINX will accept    $((Get-DeltaDomainNameList -Primary $Model.Primary -Additional $newAdditional) -join ', ')"
    Write-Detail 'No certificate is deleted or altered.'

    if ($AllowPrompt) {
        $confirmed = Read-DeltaYesNoConfirmation -Body {
            Write-Host "Stop accepting $target ?"
            Write-Host ''
            Write-Host 'NGINX will no longer answer to that hostname. Anyone using it will reach the'
            Write-Host 'default server block instead. PUBLIC_URL, ports, certificates and firewall'
            Write-Host 'rules are not changed, and no container is recreated.'
        }
        if (-not $confirmed) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'cancelled'; Reason = 'Cancelled. The configured domains are unchanged.' }
        }
    }

    $outcome = Set-DeltaDomainConfiguration -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
        -Configuration $Configuration -Model $Model -NewAdditional $newAdditional `
        -Description "$target removed. NGINX no longer accepts it; PUBLIC_URL is unchanged."

    Add-Member -InputObject $outcome -NotePropertyName 'Cancelled' -NotePropertyValue $false -Force
    Add-Member -InputObject $outcome -NotePropertyName 'Domain' -NotePropertyValue $target -Force
    return $outcome
}

function Invoke-DeltaDomainSetPrimary {
    <#
      Promote any configured domain to primary.

      The scheme is carried over unchanged. An HTTPS installation stays HTTPS
      and an HTTP one stays HTTP: this operation swaps a hostname, and enabling
      or disabling TLS belongs to the certificate workflow, not to a rename.

      The old primary becomes an additional domain rather than disappearing.
      Silently dropping it would take down every existing bookmark, and an
      operator who wants it gone can remove it in the next operation - visibly.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][object]$Model,
        [string]$Domain,
        [bool]$AllowPrompt = $true
    )

    $target = $null
    if ($Domain) {
        $check = Test-DeltaDomainName -Value $Domain
        if (-not $check.IsValid) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $false; Stage = 'validate'; Reason = $check.Reason }
        }
        if ($Model.All -notcontains $check.Normalized) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $false; Stage = 'not-configured'; Reason = "$($check.Normalized) is not a configured domain. Add it first, then set it as primary." }
        }
        $target = $check.Normalized
    }
    else {
        if (-not $AllowPrompt) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'input'; Reason = 'No domain was supplied and this run is non-interactive. Nothing was changed.' }
        }
        Write-Host ''
        Write-Host 'Choose the domain DELTA should call itself by.'
        Write-Detail 'That domain becomes the host part of PUBLIC_URL. The current primary stays'
        Write-Detail 'configured as an additional domain, so links using it keep working.'
        $target = Read-DeltaDomainChoice -Domains $Model.All -Prompt 'New primary domain' -PrimaryDomain $Model.Primary
        if (-not $target) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'cancelled'; Reason = 'Cancelled. The primary domain is unchanged.' }
        }
    }

    if ($target -eq $Model.Primary) {
        Write-Host ''
        Write-Detail "$target is already the primary domain. Nothing was changed."
        return [PSCustomObject]@{ Succeeded = $true; Cancelled = $false; Stage = 'no-op'; Reason = "$target was already the primary domain. Nothing was changed."; NoOp = $true }
    }

    # The old primary joins the additional domains; the new primary leaves them.
    # Get-DeltaDomainNameList deduplicates, so the ordering below cannot produce
    # the same hostname twice.
    $newAdditional = @(@($Model.Additional | Where-Object { $_ -ne $target }) + @($Model.Primary))
    $newPublicUrl = Get-DeltaPublicUrl -Scheme $Model.Scheme -HostName $target -Port ([int]$Model.Port)

    Write-Host ''
    Write-Host 'This change'
    Write-Detail "Primary URL          $($Model.PublicUrl)"
    Write-Detail "                  -> $newPublicUrl"
    Write-Detail "Primary domain       $($Model.Primary) -> $target"
    Write-Detail "Additional           $(if ($newAdditional.Count -gt 0) { $newAdditional -join ', ' } else { 'none' })"
    Write-Detail "Scheme               $($Model.Scheme) (unchanged - HTTPS is enabled or disabled through Certificate Management, never here)"

    $coverage = Get-DeltaDomainCertificateState -InstallRoot $InstallRoot -Configuration $Configuration -Domains @($target)
    if ($coverage) {
        Write-Host ''
        Write-DeltaDomainCoverageLine -Domain $target -Coverage $coverage
    }

    if ($AllowPrompt) {
        $confirmed = Read-DeltaYesNoConfirmation -Body {
            Write-Host "Make $target the primary domain?"
            Write-Host ''
            Write-Host "PUBLIC_URL becomes $newPublicUrl, NGINX is regenerated and reloaded, and the"
            Write-Host 'DELTA container is recreated so it reports the new canonical URL. The database'
            Write-Host 'and its volume are not touched, and no certificate is issued or replaced.'
        }
        if (-not $confirmed) {
            return [PSCustomObject]@{ Succeeded = $false; Cancelled = $true; Stage = 'cancelled'; Reason = 'Cancelled. The primary domain is unchanged.' }
        }
    }

    $outcome = Set-DeltaDomainConfiguration -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot `
        -Configuration $Configuration -Model $Model -NewPrimary $target -NewAdditional $newAdditional `
        -Description "$target is now the primary domain; PUBLIC_URL is $newPublicUrl."

    Add-Member -InputObject $outcome -NotePropertyName 'Cancelled' -NotePropertyValue $false -Force
    Add-Member -InputObject $outcome -NotePropertyName 'Domain' -NotePropertyValue $target -Force
    Add-Member -InputObject $outcome -NotePropertyName 'Coverage' -NotePropertyValue $coverage -Force
    return $outcome
}

# ---------------------------------------------------------------------------
# Menu option 8
# ---------------------------------------------------------------------------

function Show-DeltaDomainOutcome {
    param([Parameter(Mandatory)][object]$Outcome)

    Write-Host ''
    if ($Outcome.Succeeded) {
        if ($Outcome.PSObject.Properties.Name -contains 'NoOp' -and $Outcome.NoOp) {
            Write-Detail $Outcome.Reason
        }
        else {
            Write-Success $Outcome.Reason
            if ($Outcome.PSObject.Properties.Name -contains 'ServerName') {
                Write-Detail "server_name          $($Outcome.ServerName)"
            }
            if ($Outcome.PSObject.Properties.Name -contains 'PublicUrl' -and $Outcome.PublicUrl) {
                Write-Detail "PUBLIC_URL           $($Outcome.PublicUrl)"
            }
            if ($Outcome.PSObject.Properties.Name -contains 'PrimaryChanged' -and -not $Outcome.PrimaryChanged) {
                Write-Detail 'No container was recreated - NGINX reloaded in place, and DELTA and the'
                Write-Detail 'database were not involved at all.'
            }
            if ($Outcome.PSObject.Properties.Name -contains 'Coverage' -and $Outcome.Coverage -and $Outcome.Domain) {
                Write-Host ''
                Write-DeltaDomainCoverageLine -Domain $Outcome.Domain -Coverage $Outcome.Coverage
            }
        }
    }
    elseif ($Outcome.Cancelled) {
        Write-Detail $Outcome.Reason
    }
    else {
        Write-DeltaFailure 'The domain configuration was not changed.'
        Write-Detail "Stage reached        $($Outcome.Stage)"
        Write-Detail $Outcome.Reason
        if ($Outcome.PSObject.Properties.Name -contains 'RolledBack' -and $Outcome.RolledBack) {
            Write-Detail 'The previous NGINX configuration is back in place.'
        }
    }
}

function Invoke-DeltaDomainManagement {
    <#
      Menu option 8.

      Displaying is read-only: entering this screen and leaving it again reads
      .env and .delta-install.json and writes neither. An installation that has
      never had a domain recorded shows its primary and "no additional domains"
      without gaining a state-file record for having been looked at.
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
            Write-DeltaFailure "This installation's .env could not be read, so its domains cannot be managed."
            return $null
        }

        $model = Get-DeltaDomainModel -InstallRoot $InstallRoot -Configuration $configuration
        $coverage = Get-DeltaDomainCertificateState -InstallRoot $InstallRoot -Configuration $configuration -Domains $model.All

        Show-DeltaDomainScreen -InstallRoot $InstallRoot -Model $model -Coverage $coverage

        if (-not $AllowPrompt) {
            Write-Host ''
            Write-Detail 'Running non-interactively, so the domains above are all this run reports.'
            return $model
        }

        $choice = Show-DeltaDomainMenu -Model $model

        switch ($choice) {
            '' { continue }
            '0' { return $model }
            '1' {
                $outcome = Invoke-DeltaDomainAdd -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Configuration $configuration -Model $model -AllowPrompt $AllowPrompt
                Show-DeltaDomainOutcome -Outcome $outcome
                Write-Host ''
                Write-Detail 'Press Enter to return to Domain Management.'
                $null = Read-Host
            }
            '2' {
                $outcome = Invoke-DeltaDomainRemove -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Configuration $configuration -Model $model -AllowPrompt $AllowPrompt
                Show-DeltaDomainOutcome -Outcome $outcome
                Write-Host ''
                Write-Detail 'Press Enter to return to Domain Management.'
                $null = Read-Host
            }
            '3' {
                $outcome = Invoke-DeltaDomainSetPrimary -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Configuration $configuration -Model $model -AllowPrompt $AllowPrompt
                Show-DeltaDomainOutcome -Outcome $outcome
                Write-Host ''
                Write-Detail 'Press Enter to return to Domain Management.'
                $null = Read-Host
            }
            default {
                Write-DeltaWarning "'$choice' is not a valid option."
            }
        }
    }
}

function Invoke-DeltaDomainOperation {
    <#
      Menu option 8's entry point, matching the shape of the other management
      operations so the dispatch table stays uniform.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [bool]$AllowPrompt = $true
    )

    return (Invoke-DeltaDomainManagement -InstallRoot $InstallRoot -ScriptRoot $ScriptRoot -Configuration $Configuration -AllowPrompt $AllowPrompt)
}
