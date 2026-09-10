function Get-PPXCustomConnectorUsage {
    <#
    .SYNOPSIS
        Tenant-wide report of custom connectors per Power Platform environment -- one row per
        (environment x custom connector), covering both connectors that are referenced by a
        resource and connectors that merely exist in the environment.
    .DESCRIPTION
        Second tool in the PPX collection. Same shape and approach as the Agent Governance Baseline
        tool: delegated Az token -> Power Platform API -> shape -> CSV plus a .limitations.txt
        sidecar. See PPXCustomConnectorUsage.md (in this tool's folder) for the full schema and design.

        Three data pulls, all against https://api.powerplatform.com with one delegated token:

          1. Inventory API -- every environment in the tenant, with its basic details.
          2. Inventory API -- every connector-emitting resource (canvas apps, model-driven apps,
             cloud flows, agent flows, workflow agent flows, Copilot Studio agents), with its
             properties.powerPlatformConnectors array. Both follow skipToken paging.
          3. Connectivity API -- GET /connectivity/environments/{id}/connectors, once per
             environment, to list the connectors that EXIST there and read the authoritative
             properties.isCustomApi flag plus display name / publisher / tier. This is what catches
             a custom connector that has been created but not yet used. Per-environment failures
             (403, environment mid-deletion, ...) are recorded, not fatal.

        The three are merged into one row per (environment x custom connector). By default only
        environments that have at least one custom connector produce rows; -IncludeAllEnvironments
        adds one placeholder row per clean environment.

        Runtime values default from the shared settings file (ppx.settings.psd1, section
        'CustomConnectorUsage', falling back to 'Common'); an explicit parameter overrides the file.
    .PARAMETER TenantId
        Entra tenant ID. Required -- here, or Common.TenantId / CustomConnectorUsage.TenantId in
        ppx.settings.psd1. No tenant is ever baked into the repo.
    .PARAMETER Top
        Inventory API page size (rows per request, 1-1000). Does not cap the total -- skipToken
        paging retrieves everything. Defaults to the settings file, then 1000.
    .PARAMETER MaxPages
        Cap on Inventory API pages per query. 0 (default) = retrieve everything. A small value gives
        a quick partial pull while testing; the report is then flagged INCOMPLETE.
    .PARAMETER MaxEnvironments
        Cap on how many environments to run the connectivity lookup against. 0 (default) = all. Set
        a small value for a quick test; the report notes that environment coverage is partial.
    .PARAMETER SkipEnvironmentConnectorLookup
        Skip the per-environment connectivity calls entirely. Fast, but then the report is built from
        the Inventory usage heuristic alone (Test-PPXCustomConnectorId): only custom connectors that
        a resource references appear, IsCustomApi is "Inferred", and ExistsInEnvironmentList is
        "Unknown".
    .PARAMETER UseDeviceAuthentication
        Device-code sign-in instead of the interactive browser prompt (needed under the VS Code
        debugger).
    .PARAMETER OutputPath
        Folder to auto-name a timestamped CSV into, or a full path ending in .csv. Defaults to the
        settings file, then the repo-root reports\ folder (git-ignored).
    .PARAMETER IncludeAllEnvironments
        Also emit a placeholder row for every environment with no custom connectors. Defaults to the
        settings file, then $false.
    .PARAMETER ExportReport
        Whether to write the CSV + sidecar. Defaults to $true; $false returns the rows in memory only.
    .EXAMPLE
        Get-PPXCustomConnectorUsage
        Full run -> reports\CustomConnectorUsage_<timestamp>.csv, one row per (environment x custom
        connector), plus a .limitations.txt sidecar. Returns the rows.
    .EXAMPLE
        Get-PPXCustomConnectorUsage -MaxPages 1 -MaxEnvironments 5
        Quick partial pull for testing.
    .EXAMPLE
        Get-PPXCustomConnectorUsage -SkipEnvironmentConnectorLookup
        Inventory-only, fast: custom connectors that are actually referenced by an app/flow/agent.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [int] $Top,

        [int] $MaxPages,

        [int] $MaxEnvironments,

        [switch] $SkipEnvironmentConnectorLookup,

        [switch] $UseDeviceAuthentication,

        [string] $OutputPath,

        [switch] $IncludeAllEnvironments,

        [bool] $ExportReport = $true
    )

    . (Join-Path $PSScriptRoot '..\_shared\Get-PPXSettings.ps1')

    $privatePath = Join-Path $PSScriptRoot 'private'
    Get-ChildItem -Path $privatePath -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    # Fall back to the shared settings file for any parameter not passed explicitly.
    $settings = Get-PPXSettings -Section 'CustomConnectorUsage'
    if (-not $PSBoundParameters.ContainsKey('TenantId') -and $settings.TenantId) { $TenantId = $settings.TenantId }
    if (-not $PSBoundParameters.ContainsKey('Top') -and $settings.Top) { $Top = $settings.Top }
    if (-not $PSBoundParameters.ContainsKey('MaxPages') -and $settings.MaxPages) { $MaxPages = $settings.MaxPages }
    if (-not $PSBoundParameters.ContainsKey('MaxEnvironments') -and $settings.MaxEnvironments) { $MaxEnvironments = $settings.MaxEnvironments }
    if (-not $PSBoundParameters.ContainsKey('SkipEnvironmentConnectorLookup') -and $settings.ContainsKey('SkipEnvironmentConnectorLookup')) {
        $SkipEnvironmentConnectorLookup = [bool] $settings.SkipEnvironmentConnectorLookup
    }
    if (-not $PSBoundParameters.ContainsKey('UseDeviceAuthentication') -and $settings.UseDeviceAuthentication) {
        $UseDeviceAuthentication = [bool] $settings.UseDeviceAuthentication
    }
    if (-not $PSBoundParameters.ContainsKey('OutputPath') -and $settings.OutputPath) { $OutputPath = $settings.OutputPath }
    if (-not $PSBoundParameters.ContainsKey('IncludeAllEnvironments') -and $settings.ContainsKey('IncludeAllEnvironments')) {
        $IncludeAllEnvironments = [bool] $settings.IncludeAllEnvironments
    }
    # ExportReport defaults to $true, so an explicit $false in settings must win over that default.
    if (-not $PSBoundParameters.ContainsKey('ExportReport') -and $settings.ContainsKey('ExportReport')) {
        $ExportReport = [bool] $settings.ExportReport
    }

    if (-not $TenantId) {
        throw @'
No tenant ID configured. This tool never ships with a tenant baked in -- set your own:

  1. Copy  ppx.settings.example.psd1  to  ppx.settings.psd1  (repo root; git-ignored), then
     set  Common.TenantId  to your Entra tenant ID.
  -- or --
  2. Pass it explicitly:  Get-PPXCustomConnectorUsage -TenantId <guid>
'@
    }

    $paging = @{}
    if ($Top) { $paging['Top'] = $Top }
    if ($MaxPages) { $paging['MaxPages'] = $MaxPages }

    # One delegated token for every call below (Inventory + connectivity share the resource). The
    # factory is passed down so a long multi-page / multi-environment run can refresh on a 401. It
    # must stay a plain scriptblock (NOT .GetNewClosure()) so it can still see the dot-sourced
    # Get-PPXPowerPlatformToken; $TenantId / $UseDeviceAuthentication resolve by dynamic scope when
    # it is invoked from a sub-function of this one.
    $tokenFactory = { Get-PPXPowerPlatformToken -TenantId $TenantId -UseDeviceAuthentication:$UseDeviceAuthentication }
    $token = & $tokenFactory

    # Both queries follow the Power Platform admin center default shape (as the Agent Governance
    # Baseline tool does): NO project clause -- return whole records and shape client-side -- and an
    # orderby on real, materialised columns (createdAt + the unique `name`). A projected query with
    # aliased columns and a dynamic array (powerPlatformConnectors) was observed to make Azure
    # Resource Graph's skipToken paging never terminate (thousands of tiny/empty pages).
    $orderby = [ordered]@{ '$type' = 'orderby'; FieldNamesAscDesc = [ordered]@{ 'tostring(properties.createdAt)' = 'desc'; 'name' = 'asc' } }

    # --- 1. Environments -------------------------------------------------------------------------
    Write-Host '..listing environments.'
    $envClauses = @(
        [ordered]@{ '$type' = 'where'; FieldName = 'type'; Operator = '=='; Values = @("'microsoft.powerplatform/environments'") }
        $orderby
    )
    $envInventory = Connect-PPXInventoryApi -Clauses $envClauses -AccessToken $token -TokenFactory $tokenFactory @paging
    $environments = @($envInventory.data)
    Write-Host "  $($environments.Count) environment(s)."

    # --- 2. Connector-emitting resources ------------------------------------------------------------
    Write-Host '..querying connector-emitting resources (apps, flows, agents).'
    $resourceTypes = @(
        "'microsoft.powerapps/canvasapps'"
        "'microsoft.powerapps/modeldrivenapps'"
        "'microsoft.powerautomate/cloudflows'"
        "'microsoft.powerautomate/agentflows'"
        "'microsoft.powerautomate/m365agentflows'"
        "'microsoft.copilotstudio/agents'"
    )
    $usageClauses = @(
        [ordered]@{ '$type' = 'where'; FieldName = 'type'; Operator = 'in~'; Values = $resourceTypes }
        $orderby
    )
    $usageInventory = Connect-PPXInventoryApi -Clauses $usageClauses -AccessToken $token -TokenFactory $tokenFactory @paging
    $usageRecords = @($usageInventory.data)
    Write-Host "  $($usageRecords.Count) of $($usageInventory.totalRecords) resource(s) across $($usageInventory.pagesRetrieved) page(s)."
    if ($usageInventory.resultTruncated -or $envInventory.resultTruncated) {
        Write-Warning 'An Inventory API result is INCOMPLETE. Re-run without -MaxPages for a full report.'
    }

    # --- 3. Per-environment connector lists (connectivity API) -----------------------------------
    $envConnectors = @{}
    $envErrors = @{}
    $envConnectorsScanned = 0
    $envConnectorsTargeted = 0
    if ($SkipEnvironmentConnectorLookup) {
        Write-Host '..skipping per-environment connector lookup (-SkipEnvironmentConnectorLookup): report is Inventory-heuristic only.'
    }
    else {
        $targets = @($environments | ForEach-Object { [string] $_.name } | Where-Object { $_ })
        if ($MaxEnvironments -gt 0 -and $targets.Count -gt $MaxEnvironments) {
            Write-Warning "Only the first $MaxEnvironments of $($targets.Count) environment(s) will be scanned for connectors (-MaxEnvironments). Coverage is PARTIAL."
            $targets = $targets[0..($MaxEnvironments - 1)]
        }
        $envConnectorsTargeted = $targets.Count
        Write-Host "..listing custom connectors in $($targets.Count) environment(s) (connectivity API)."
        $i = 0
        foreach ($envId in $targets) {
            $i++
            Write-Progress -Activity 'Connectivity API' -Status "$i / $($targets.Count) : $envId" -PercentComplete (($i / [Math]::Max($targets.Count, 1)) * 100)
            try {
                $envConnectors[$envId] = @(Get-PPXEnvironmentConnector -EnvironmentId $envId -AccessToken $token -TokenFactory $tokenFactory -CustomOnly)
                $envConnectorsScanned++
            }
            catch {
                $envErrors[$envId] = $_.Exception.Message
                Write-Warning "  environment $envId : $($_.Exception.Message)"
            }
        }
        Write-Progress -Activity 'Connectivity API' -Completed
        $customFound = ($envConnectors.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
        $envsWithCustom = @($envConnectors.GetEnumerator() | Where-Object { $_.Value.Count -gt 0 }).Count
        Write-Host "  scanned $envConnectorsScanned environment(s); $envsWithCustom have custom connectors ($customFound instance(s) total); $($envErrors.Count) lookup error(s)."
    }

    # --- 4. Shape -----------------------------------------------------------------------------------
    $rows = @(ConvertTo-PPXConnectorUsageRow -Environments $environments -UsageRecords $usageRecords `
        -EnvironmentConnectors $envConnectors -EnvironmentErrors $envErrors `
        -SkipEnvironmentConnectorLookup:$SkipEnvironmentConnectorLookup -IncludeAllEnvironments:$IncludeAllEnvironments)

    $envWithCustom = @($rows | Where-Object { $_.ConnectorId }).EnvironmentId | Sort-Object -Unique
    Write-Host "$($rows.Count) row(s); $($envWithCustom.Count) environment(s) with >= 1 custom connector."

    # --- 5. Export --------------------------------------------------------------------------------
    if ($ExportReport) {
        $exportParams = @{
            EnvironmentInventory   = $envInventory
            UsageInventory         = $usageInventory
            Rows                   = $rows
            EnvironmentErrors      = $envErrors
            EnvironmentsScanned    = $envConnectorsScanned
            EnvironmentsTargeted   = $envConnectorsTargeted
            EnvironmentsTotal      = $environments.Count
            SkipLookup             = [bool] $SkipEnvironmentConnectorLookup
            IncludeAllEnvironments = [bool] $IncludeAllEnvironments
        }
        if ($OutputPath) { $exportParams['Path'] = $OutputPath }

        $result = Export-PPXReport @exportParams
        Write-Host "Report: $($result.CsvPath) ($($result.RowCount) row(s))."
        Write-Host "Known limitations: $($result.LimitationsPath)"
        return $result.Rows
    }

    Write-Host "ExportReport is `$false -- nothing written. Returning $($rows.Count) shaped row(s)."
    return $rows
}
