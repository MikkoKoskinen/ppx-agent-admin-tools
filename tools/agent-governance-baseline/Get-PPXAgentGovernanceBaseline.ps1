function Get-PPXAgentGovernanceBaseline {
    <#
    .SYNOPSIS
        Tenant-wide, one-row-per-agent governance baseline report for published Copilot Studio (V2)
        agents.
    .DESCRIPTION
        Primary entry point for the PPX Agent Governance Baseline tool. See the solution and
        high-level technical description for the full schema and architecture:
        PPXAgentGovernanceBaseline.md (in this tool's folder).

        Current state: Inventory API connectivity, schema assembly, CSV export, and owner resolution
        (Microsoft Graph) are implemented. Connector-tier resolution and the DLP coverage flag are
        not yet built, so PremiumConnectorCount and HasZeroDlpCoverage are blank in every row;
        EnvironmentGroup is also blank (not currently projected by the Inventory API query) — see
        the inline TODOs, the private/ script headers, and the known-limitations sidecar file
        written alongside every report.
        Runtime values default from the shared settings file (ppx.settings.psd1 at the repo root,
        section 'AgentGovernanceBaseline'); an explicit parameter here overrides that file.
    .PARAMETER TenantId
        Entra tenant ID to sign in against. Required — supply it here, or set Common.TenantId
        (or AgentGovernanceBaseline.TenantId) in ppx.settings.psd1. The function throws if neither
        is set; no tenant is ever baked into the repo.
    .PARAMETER Top
        Optional page size (rows per request, 1-1000) passed through to the Inventory API query.
        This does not cap the total — the tool follows Skip-offset paging until every agent record
        has been retrieved. Defaults to the settings file (AgentGovernanceBaseline.Top).
    .PARAMETER MaxPages
        Optional cap on how many Inventory API pages to follow. 0 (default) means retrieve
        everything. Set a small value for a quick partial pull while testing; the report is then
        flagged INCOMPLETE in its .limitations.txt sidecar. Defaults to the settings file
        (AgentGovernanceBaseline.MaxPages).
    .PARAMETER UseDeviceAuthentication
        Sign in with device-code flow instead of the interactive browser prompt. Set this (or
        Common.UseDeviceAuthentication in the settings file) when running under the VS Code debugger,
        where the browser/WAM prompt hangs.
    .PARAMETER OutputPath
        Optional. A folder to auto-name a timestamped CSV into, or a full path ending in .csv.
        Defaults to the settings file (AgentGovernanceBaseline.OutputPath), then to the repo-root
        reports\ folder (git-ignored) if neither is set.
    .PARAMETER ExportReport
        Whether to write the CSV report (and its .limitations.txt sidecar) to disk. Defaults to
        $true. Set to $false (or AgentGovernanceBaseline.ExportReport = $false in the settings file)
        to only build and return the shaped rows in memory, without writing anything to disk.
    .EXAMPLE
        Get-PPXAgentGovernanceBaseline
        Signs in interactively via Connect-AzAccount (only if there is no usable Az context), writes
        a governance-baseline CSV (plus a sidecar known-limitations file) to reports\, and returns
        the shaped rows.
    .EXAMPLE
        Get-PPXAgentGovernanceBaseline -ExportReport:$false
        Same as above, but returns the shaped rows without writing a CSV or limitations file.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [int] $Top,

        [int] $MaxPages,

        [switch] $UseDeviceAuthentication,

        [string] $OutputPath,

        [bool] $ExportReport = $true
    )

    . (Join-Path $PSScriptRoot '..\_shared\Get-PPXSettings.ps1')

    $privatePath = Join-Path $PSScriptRoot 'private'
    Get-ChildItem -Path $privatePath -Filter '*.ps1' | ForEach-Object {
        . $_.FullName
    }

    # Fall back to the shared settings file for any parameter not passed explicitly.
    $settings = Get-PPXSettings -Section 'AgentGovernanceBaseline'
    if (-not $PSBoundParameters.ContainsKey('TenantId') -and $settings.TenantId) { $TenantId = $settings.TenantId }
    if (-not $PSBoundParameters.ContainsKey('Top') -and $settings.Top) { $Top = $settings.Top }
    if (-not $PSBoundParameters.ContainsKey('MaxPages') -and $settings.MaxPages) { $MaxPages = $settings.MaxPages }
    if (-not $PSBoundParameters.ContainsKey('UseDeviceAuthentication') -and $settings.UseDeviceAuthentication) {
        $UseDeviceAuthentication = [bool] $settings.UseDeviceAuthentication
    }
    if (-not $PSBoundParameters.ContainsKey('OutputPath') -and $settings.OutputPath) { $OutputPath = $settings.OutputPath }
    # ExportReport defaults to $true, so an explicit $false in settings must win over that default —
    # a truthiness check (like the fallbacks above) can't distinguish "unset" from "explicitly off".
    if (-not $PSBoundParameters.ContainsKey('ExportReport') -and $settings.ContainsKey('ExportReport')) {
        $ExportReport = [bool] $settings.ExportReport
    }

    if (-not $TenantId) {
        throw @'
No tenant ID configured. This tool never ships with a tenant baked in — set your own:

  1. Copy  ppx.settings.example.psd1  to  ppx.settings.psd1  (repo root; git-ignored), then
     set  Common.TenantId  to your Entra tenant ID.
  -- or --
  2. Pass it explicitly:  Get-PPXAgentGovernanceBaseline -TenantId <guid>
'@
    }

    $connectParams = @{}
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    if ($Top) { $connectParams['Top'] = $Top }
    if ($MaxPages) { $connectParams['MaxPages'] = $MaxPages }
    if ($UseDeviceAuthentication) { $connectParams['UseDeviceAuthentication'] = $true }

    write-Host "..get base agent listing."

    $inventory = Connect-PPXInventoryApi @connectParams

    $records = @($inventory.data)
    Write-Host "Inventory API returned $($records.Count) of $($inventory.totalRecords) agent record(s) across $($inventory.pagesRetrieved) page(s)."
    if ($inventory.resultTruncated) {
        Write-Warning "Inventory API result is INCOMPLETE ($($records.Count) of $($inventory.totalRecords) retrieved). Re-run without -MaxPages / AgentGovernanceBaseline.MaxPages for a full report."
    }

    write-Host "..get environment listing (for the environment name/type/managed columns)."

    $environmentResult = Resolve-PPXEnvironmentLookup @connectParams
    $envLookup = $environmentResult.Lookup
    Write-Host "Inventory API returned $($envLookup.Count) of $($environmentResult.Inventory.totalRecords) environment record(s) across $($environmentResult.Inventory.pagesRetrieved) page(s)."
    if ($environmentResult.Inventory.resultTruncated) {
        Write-Warning "Environment lookup is INCOMPLETE ($($envLookup.Count) of $($environmentResult.Inventory.totalRecords) retrieved) -- some agents' EnvironmentName/EnvironmentType/IsManagedEnvironment will be blank even though they belong to a real environment."
    }

    # Client-side join: the Inventory API query no longer joins agents to environments server-side
    # (it fanned out badly against a large tenant -- see Connect-PPXInventoryApi.ps1's .DESCRIPTION),
    # so attach the same fields the old join projected onto each agent record here instead.
    # ConvertTo-PPXGovernanceRow reads them off the record top-level (environmentName / environmentType
    # / isManagedEnvironment), matching what the join used to produce.
    $unmatchedCount = 0
    foreach ($record in $records) {
        $environmentId = Get-PPXNestedValue $record 'properties.environmentId' -Default ''
        # A plain truthy check treats a whitespace-only value as "present" even though it can never
        # be a real key, so it must be excluded the same way a blank one is.
        $env = if (-not [string]::IsNullOrWhiteSpace($environmentId)) { $envLookup[$environmentId] } else { $null }
        if ($env) {
            $record | Add-Member -NotePropertyName 'environmentName' -NotePropertyValue $env.environmentName -Force
            $record | Add-Member -NotePropertyName 'environmentType' -NotePropertyValue $env.environmentType -Force
            $record | Add-Member -NotePropertyName 'isManagedEnvironment' -NotePropertyValue $env.isManagedEnvironment -Force
        }
        else {
            $unmatchedCount++
        }
    }
    if ($unmatchedCount -gt 0) {
        Write-Warning "$unmatchedCount of $($records.Count) agent record(s) had no matching environment (unpublished/blank environmentId, or the environment lookup above was incomplete) -- their EnvironmentName/EnvironmentType/IsManagedEnvironment columns will be blank."
    }

    write-Host "..resolve agent owner identities (Microsoft Graph, batched)."

    # Microsoft-shipped managed-solution agents (msdyn_* schema names, properties.isManaged = True --
    # confirmed, see PPXAgentGovernanceBaseline.md §8) have no individual owner -- but some still
    # carry a real-looking (e.g. all-zero sentinel) ownerId rather than a blank one, which Graph will
    # never resolve. Deciding "no owner" from IsManagedAgent rather than from ownerId content is what
    # actually catches those: skip them from the Graph batch entirely and never let them fall through
    # to a "resolved" (but blank) result.
    $ownerIds = @(
        $records |
            Where-Object { -not [bool] (Get-PPXNestedValue $_ 'properties.isManaged' -Default $false) } |
            ForEach-Object { Get-PPXNestedValue $_ 'properties.ownerId' -Default '' } |
            # A plain truthy filter keeps a whitespace-only value, but Resolve-PPXOwnerIdentity treats
            # that the same as blank (IsNullOrWhiteSpace) and never gives it a lookup key -- match that
            # here so it isn't sent to Graph as a distinct "id" that will never resolve.
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $ownerParams = @{}
    if ($TenantId) { $ownerParams['TenantId'] = $TenantId }
    if ($UseDeviceAuthentication) { $ownerParams['UseDeviceAuthentication'] = $true }
    $ownerLookup = $ownerIds | Resolve-PPXOwnerIdentity @ownerParams
    Write-Host "Resolved $($ownerLookup.Count) distinct owner identity(ies) via Microsoft Graph."

    $managedAgentCount = 0
    $noOwnerIdCount = 0
    foreach ($record in $records) {
        $isManagedAgent = [bool] (Get-PPXNestedValue $record 'properties.isManaged' -Default $false)
        if ($isManagedAgent) {
            $managedAgentCount++
            $record | Add-Member -NotePropertyName 'ownerName' -NotePropertyValue 'Microsoft (managed agent)' -Force
            $record | Add-Member -NotePropertyName 'ownerUPN' -NotePropertyValue '' -Force
            $record | Add-Member -NotePropertyName 'ownerAccountStatus' -NotePropertyValue 'NotApplicable' -Force
            continue
        }

        $ownerId = Get-PPXNestedValue $record 'properties.ownerId' -Default ''
        $owner = if (-not [string]::IsNullOrWhiteSpace($ownerId)) { $ownerLookup[$ownerId] } else { $null }
        if ($owner) {
            $record | Add-Member -NotePropertyName 'ownerName' -NotePropertyValue $owner.OwnerName -Force
            $record | Add-Member -NotePropertyName 'ownerUPN' -NotePropertyValue $owner.OwnerUPN -Force
            $record | Add-Member -NotePropertyName 'ownerAccountStatus' -NotePropertyValue $owner.OwnerAccountStatus -Force
        }
        else {
            $noOwnerIdCount++
            $record | Add-Member -NotePropertyName 'ownerName' -NotePropertyValue '(no owner)' -Force
            $record | Add-Member -NotePropertyName 'ownerUPN' -NotePropertyValue '' -Force
            $record | Add-Member -NotePropertyName 'ownerAccountStatus' -NotePropertyValue 'NotApplicable' -Force
        }
    }
    if ($managedAgentCount -gt 0) {
        Write-Host "$managedAgentCount of $($records.Count) agent record(s) are Microsoft-shipped managed agents (IsManagedAgent = True) -- OwnerName is set to 'Microsoft (managed agent)' and OwnerAccountStatus to 'NotApplicable'; not sent to Graph."
    }
    if ($noOwnerIdCount -gt 0) {
        Write-Host "$noOwnerIdCount of $($records.Count) non-managed agent record(s) have no ownerId to resolve -- OwnerName is set to '(no owner)' and OwnerAccountStatus to 'NotApplicable'."
    }

    # TODO: Patch 1 step 2 — Resolve-PPXConnectorTier (connector catalog + premium count)
    # TODO: Patch 1 step 4 — Get-PPXDlpCoverageFlag (DLP coverage boolean)

    if ($ExportReport) {
        $exportParams = @{
            Inventory                 = $inventory
            EnvironmentInventory      = $environmentResult.Inventory
            UnmatchedEnvironmentCount = $unmatchedCount
        }
        if ($OutputPath) { $exportParams['Path'] = $OutputPath }

        $result = Export-PPXReport @exportParams

        Write-Host "Report: $($result.CsvPath) ($($result.RowCount) of $($inventory.totalRecords) row(s))."
        Write-Host "Known limitations: $($result.LimitationsPath)"

        return $result.Rows
    }

    $rows = @($inventory.data) | ConvertTo-PPXGovernanceRow
    Write-Host "ExportReport is `$false — no CSV/limitations file written. Returning $($rows.Count) shaped row(s) in memory."
    return $rows
}
