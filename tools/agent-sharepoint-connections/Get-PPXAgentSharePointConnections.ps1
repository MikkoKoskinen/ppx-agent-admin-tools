function Get-PPXAgentSharePointConnections {
    <#
    .SYNOPSIS
        Lists every Copilot Studio agent that uses SharePoint as a knowledge source, with the
        attached SharePoint URLs. Whole tenant, or only selected environments.
    .DESCRIPTION
        The Power Platform Inventory API only exposes knowledge COUNTS per agent, not the sources
        themselves, and no official API returns an agent's definition. This tool therefore:

          1. Queries the Inventory API for agents (all, or only the environment(s) given in
             -EnvironmentId) and for the matching environments.
          2. Keeps agents with at least one knowledge source (componentsCounts.knowledge > 0).
          3. Per environment: resolves the Dataverse org URL, gets a Dataverse token, and reads the
             agents' botcomponents rows (UNOFFICIAL table access, read-only).
          4. Parses each component's YAML for the knowledge-source kind and SharePoint URL.
          5. Emits one row per SharePoint knowledge source (an agent can have several).

        Read-only. See PPXAgentSharePointConnections.md for the design and the open verification
        points (component-type value, instance URL source, YAML shape).

        Runtime values default from ppx.settings.psd1 (section 'AgentSharePointConnections'); an
        explicit parameter overrides the file.
    .PARAMETER TenantId
        Entra tenant ID. Required (parameter or Common.TenantId in ppx.settings.psd1).
    .PARAMETER EnvironmentId
        Optional. One or more environment GUIDs (array or comma-separated string) to inventory.
        Omit to inventory ALL environments. The filter is applied server-side where possible and
        always again client-side.
    .PARAMETER Top
        Inventory API page size (1-1000). Does not cap the total.
    .PARAMETER MaxPages
        Cap on Inventory API pages per query (0 = all). A capped run is flagged INCOMPLETE.
    .PARAMETER MaxEnvironments
        Cap on how many environments get the Dataverse scan (0 = all). Useful for a quick test.
    .PARAMETER IncludeAllKnowledge
        Also emit non-SharePoint knowledge sources (public websites, etc.) instead of only SharePoint.
    .PARAMETER ScanAllAgents
        Also scan agents whose Inventory knowledge count is 0 (diagnostic; slower).
    .PARAMETER KnowledgeComponentType
        Optional botcomponent componenttype value to filter server-side once confirmed in your
        tenant (see the ComponentType column of a first report). Default: no type filter.
    .PARAMETER UseDeviceAuthentication
        Device-code sign-in (use under the VS Code debugger).
    .PARAMETER OutputPath
        Folder or full .csv path. Default: repo-root reports\ folder.
    .PARAMETER ExportReport
        Write the CSV + .limitations.txt (default $true). $false returns rows only.
    .EXAMPLE
        Get-PPXAgentSharePointConnections
        Whole tenant.
    .EXAMPLE
        Get-PPXAgentSharePointConnections -EnvironmentId 11111111-2222-3333-4444-555555555555
        One environment only.
    .EXAMPLE
        Get-PPXAgentSharePointConnections -EnvironmentId 'guid1','guid2' -IncludeAllKnowledge -Verbose
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [string[]] $EnvironmentId,

        [int] $Top,

        [int] $MaxPages,

        [int] $MaxEnvironments,

        [switch] $IncludeAllKnowledge,

        [switch] $ScanAllAgents,

        [Nullable[int]] $KnowledgeComponentType,

        [switch] $UseDeviceAuthentication,

        [string] $OutputPath,

        [bool] $ExportReport = $true
    )

    . (Join-Path $PSScriptRoot '..\_shared\Get-PPXSettings.ps1')
    Get-ChildItem -Path (Join-Path $PSScriptRoot 'private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    $settings = Get-PPXSettings -Section 'AgentSharePointConnections'
    if (-not $PSBoundParameters.ContainsKey('TenantId') -and $settings.TenantId) { $TenantId = $settings.TenantId }
    if (-not $PSBoundParameters.ContainsKey('Top') -and $settings.Top) { $Top = $settings.Top }
    if (-not $PSBoundParameters.ContainsKey('MaxPages') -and $settings.MaxPages) { $MaxPages = $settings.MaxPages }
    if (-not $PSBoundParameters.ContainsKey('MaxEnvironments') -and $settings.MaxEnvironments) { $MaxEnvironments = $settings.MaxEnvironments }
    if (-not $PSBoundParameters.ContainsKey('KnowledgeComponentType') -and $settings.KnowledgeComponentType) { $KnowledgeComponentType = [int] $settings.KnowledgeComponentType }
    if (-not $PSBoundParameters.ContainsKey('UseDeviceAuthentication') -and $settings.UseDeviceAuthentication) { $UseDeviceAuthentication = [bool] $settings.UseDeviceAuthentication }
    if (-not $PSBoundParameters.ContainsKey('OutputPath') -and $settings.OutputPath) { $OutputPath = $settings.OutputPath }
    if (-not $PSBoundParameters.ContainsKey('ExportReport') -and $settings.ContainsKey('ExportReport')) { $ExportReport = [bool] $settings.ExportReport }
    if (-not $PSBoundParameters.ContainsKey('IncludeAllKnowledge') -and $settings.IncludeAllKnowledge) { $IncludeAllKnowledge = [bool] $settings.IncludeAllKnowledge }

    if (-not $TenantId) {
        throw @'
No tenant ID configured. This tool never ships with a tenant baked in — set your own:

  1. Copy  ppx.settings.example.psd1  to  ppx.settings.psd1  (repo root; git-ignored), then
     set  Common.TenantId  to your Entra tenant ID.
  -- or --
  2. Pass it explicitly:  Get-PPXAgentSharePointConnections -TenantId <guid>
'@
    }

    # --- Normalise the optional environment selection -------------------------------------------
    $selectedIds = @()
    if ($EnvironmentId) {
        $selectedIds = @(
            $EnvironmentId -split '[,;\s]+' |
                Where-Object { $_ } |
                ForEach-Object {
                    $g = [guid]::Empty
                    if (-not [guid]::TryParse($_.Trim('{', '}', '''', '"'), [ref] $g)) {
                        throw "Invalid -EnvironmentId value '$_': not a GUID."
                    }
                    $g.ToString().ToLowerInvariant()
                } |
                Select-Object -Unique
        )
    }
    $selectionLabel = if ($selectedIds.Count) { "$($selectedIds.Count) selected environment(s)" } else { 'ALL environments' }

    $connectParams = @{}
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    if ($Top) { $connectParams['Top'] = $Top }
    if ($MaxPages) { $connectParams['MaxPages'] = $MaxPages }
    if ($UseDeviceAuthentication) { $connectParams['UseDeviceAuthentication'] = $true }

    $runErrors = [System.Collections.Generic.List[string]]::new()
    $incomplete = [System.Collections.Generic.List[string]]::new()

    # --- 1a. Environments -----------------------------------------------------------------------
    Write-Host "..get environment listing ($selectionLabel)."
    $envParams = $connectParams.Clone()
    if ($selectedIds.Count) { $envParams['EnvironmentId'] = $selectedIds }
    $envResult = Get-PPXEnvironmentInventory @envParams
    $envLookup = $envResult.Lookup
    Write-Host "Inventory API returned $($envLookup.Count) environment record(s)."
    if ($envResult.Inventory.resultTruncated) {
        $incomplete.Add('Environment listing was truncated (-MaxPages); some environments may be missing.')
    }
    foreach ($id in $selectedIds) {
        if (-not $envLookup.ContainsKey($id)) {
            Write-Warning "Selected environment $id was not found in the Inventory environment list."
            $runErrors.Add("Selected environment $id not found in Inventory.")
        }
    }

    # --- 1b. Agents (server-side environment filter, with client-side fallback) ------------------
    Write-Host "..get agent listing ($selectionLabel)."
    $agentClauses = @(
        [ordered]@{
            '$type'   = 'where'
            FieldName = 'type'
            Operator  = 'in~'
            Values    = @("'microsoft.copilotstudio/agents'")
        }
    )
    if ($selectedIds.Count) {
        $agentClauses += [ordered]@{
            '$type'   = 'where'
            FieldName = 'properties.environmentId'
            Operator  = 'in~'
            Values    = @($selectedIds | ForEach-Object { "'$_'" })
        }
    }
    $agentClauses += [ordered]@{
        '$type'           = 'orderby'
        FieldNamesAscDesc = [ordered]@{ 'name' = 'asc' }
    }

    try {
        $agentInventory = Connect-PPXInventoryApi @connectParams -Clauses $agentClauses
    }
    catch {
        if (-not $selectedIds.Count) { throw }
        Write-Warning "Server-side environment filter on agents was rejected ($($_.Exception.Message.Split("`n")[0])). Falling back to a tenant-wide agent pull filtered client-side."
        $runErrors.Add('Server-side properties.environmentId filter rejected by Inventory API; used tenant-wide pull + client-side filter.')
        $fallbackClauses = @($agentClauses | Where-Object { $_.FieldName -ne 'properties.environmentId' })
        $agentInventory = Connect-PPXInventoryApi @connectParams -Clauses $fallbackClauses
    }
    if ($agentInventory.resultTruncated) {
        $incomplete.Add("Agent listing was truncated ($($agentInventory.count) of $($agentInventory.totalRecords) records).")
        Write-Warning 'Agent listing is INCOMPLETE. Re-run without -MaxPages for a full report.'
    }

    $agents = @($agentInventory.data)
    if ($selectedIds.Count) {
        $agents = @($agents | Where-Object {
                $selectedIds -contains ([string] (Get-PPXNestedValue $_ 'properties.environmentId' -Default '')).ToLowerInvariant()
            })
    }
    Write-Host "Agents in scope: $($agents.Count)."

    # --- 2. Keep agents that have knowledge sources, group by environment ------------------------
    $candidates = [System.Collections.Generic.List[object]]::new()
    $skippedNoKnowledge = 0
    foreach ($a in $agents) {
        $kc = Get-PPXNestedValue $a 'properties.componentsCounts.knowledge' -Default $null
        if (-not $ScanAllAgents -and $null -ne $kc -and [int] $kc -eq 0) { $skippedNoKnowledge++; continue }

        $botId = [string] (Get-PPXNestedValue $a 'properties.botId' -Default '')
        if (-not $botId) { $botId = [string] (Get-PPXNestedValue $a 'properties.name' -Default '') }
        if (-not $botId) { $botId = [string] (Get-PPXNestedValue $a 'name' -Default '') }

        $candidates.Add([PSCustomObject]@{
                Record      = $a
                BotId       = $botId
                EnvId       = ([string] (Get-PPXNestedValue $a 'properties.environmentId' -Default '')).ToLowerInvariant()
                AgentName   = [string] (Get-PPXNestedValue $a 'properties.displayName' -Default '')
                SchemaName  = [string] (Get-PPXNestedValue $a 'properties.schemaName' -Default '')
                KnowledgeCt = $kc
            })
    }
    Write-Host "$($candidates.Count) agent(s) have knowledge sources to scan ($skippedNoKnowledge skipped with knowledge count 0)."

    $envGroups = @($candidates | Where-Object { $_.EnvId -and $_.BotId } | Group-Object EnvId)
    $unscannable = @($candidates | Where-Object { -not $_.EnvId -or -not $_.BotId })
    if ($unscannable.Count) {
        $runErrors.Add("$($unscannable.Count) agent(s) had no environmentId or bot id and were not scanned.")
    }
    if ($MaxEnvironments -gt 0 -and $envGroups.Count -gt $MaxEnvironments) {
        $incomplete.Add("-MaxEnvironments ${MaxEnvironments}: scanned $MaxEnvironments of $($envGroups.Count) environment(s) that have agents with knowledge.")
        $envGroups = @($envGroups | Select-Object -First $MaxEnvironments)
    }

    # --- 3/4/5. Per environment: Dataverse read, parse, shape rows --------------------------------
    $rows = [System.Collections.Generic.List[object]]::new()
    $envScanned = 0
    $envFailed = 0
    $agentsScanned = 0
    $agentsWithSp = 0
    $spSourceCount = 0
    $observedTypes = @{}

    function New-Row($c, $envInfo, $envIdText, $status, $comp, $parsed) {
        [PSCustomObject][ordered]@{
            EnvironmentId           = $envIdText
            EnvironmentName         = if ($envInfo) { $envInfo.environmentName } else { '' }
            EnvironmentType         = if ($envInfo) { $envInfo.environmentType } else { '' }
            AgentId                 = $c.BotId
            AgentName               = $c.AgentName
            SchemaName              = $c.SchemaName
            IsManagedAgent          = Get-PPXNestedValue $c.Record 'properties.isManaged' -Default ''
            OwnerId                 = Get-PPXNestedValue $c.Record 'properties.ownerId' -Default ''
            LastPublishedAt         = Get-PPXNestedValue $c.Record 'properties.lastPublishedAt' -Default ''
            KnowledgeCountInventory = $c.KnowledgeCt
            KnowledgeSourceName     = if ($comp) { Get-PPXNestedValue $comp 'name' -Default '' } else { '' }
            SourceKind              = if ($parsed) { $parsed.SourceKind } else { '' }
            SharePointUrl           = if ($parsed) { $parsed.Url } else { '' }
            SiteHost                = if ($parsed) { $parsed.SiteHost } else { '' }
            ComponentType           = if ($comp) { Get-PPXNestedValue $comp 'componenttype' -Default '' } else { '' }
            ComponentId             = if ($comp) { Get-PPXNestedValue $comp 'botcomponentid' -Default '' } else { '' }
            Status                  = $status
        }
    }

    $tokenCache = @{}
    $idx = 0
    foreach ($group in $envGroups) {
        $idx++
        $envIdText = $group.Name
        $envInfo = if ($envLookup.ContainsKey($envIdText)) { $envLookup[$envIdText] } else { $null }
        $label = if ($envInfo -and $envInfo.environmentName) { "$($envInfo.environmentName) ($envIdText)" } else { $envIdText }
        Write-Host "..[$idx/$($envGroups.Count)] $label : $($group.Count) agent(s)"

        # Dataverse org URL: Inventory record first, BAP fallback.
        $instanceUrl = if ($envInfo) { $envInfo.instanceUrl } else { '' }
        if (-not $instanceUrl) {
            $bapParams = @{ EnvironmentId = $envIdText }
            if ($TenantId) { $bapParams['TenantId'] = $TenantId }
            if ($UseDeviceAuthentication) { $bapParams['UseDeviceAuthentication'] = $true }
            $bap = Resolve-PPXEnvironmentInstanceUrl @bapParams
            $instanceUrl = $bap.InstanceUrl
            if (-not $instanceUrl) {
                $failMessage = "no Dataverse instance URL ($($bap.Error))"
                $envFailed++
                $runErrors.Add("${label}: $failMessage")
                Write-Warning "${label}: $failMessage"
                foreach ($c in $group.Group) { $rows.Add((New-Row $c $envInfo $envIdText "Error ($failMessage)" $null $null)) }
                continue
            }
        }

        $tokenParams = @{ ResourceUrl = $instanceUrl }
        if ($TenantId) { $tokenParams['TenantId'] = $TenantId }
        if ($UseDeviceAuthentication) { $tokenParams['UseDeviceAuthentication'] = $true }
        # No GetNewClosure(): a closure runs in its own module scope and cannot see the dot-sourced
        # Get-PPXAccessToken. The factory is only invoked within this loop iteration, so $tokenParams
        # is still the right value when it runs.
        $tokenFactory = { Get-PPXAccessToken @tokenParams }

        try {
            $componentParams = @{
                InstanceUrl  = $instanceUrl
                BotId        = @($group.Group | ForEach-Object { $_.BotId })
                TokenFactory = $tokenFactory
            }
            if ($null -ne $KnowledgeComponentType) { $componentParams['ComponentType'] = $KnowledgeComponentType }
            $components = @(Get-PPXAgentKnowledgeComponent @componentParams)
        }
        catch {
            $failMessage = "Dataverse read failed: $($_.Exception.Message)"
            $envFailed++
            $runErrors.Add("${label}: $failMessage")
            Write-Warning "${label}: $failMessage"
            foreach ($c in $group.Group) { $rows.Add((New-Row $c $envInfo $envIdText "Error ($failMessage)" $null $null)) }
            continue
        }

        $envScanned++
        Write-Verbose "$label : $($components.Count) botcomponent row(s) returned."

        $byBot = @{}
        foreach ($comp in $components) {
            $parentId = ([string] (Get-PPXNestedValue $comp '_parentbotid_value' -Default '')).ToLowerInvariant()
            if (-not $parentId) { continue }
            if (-not $byBot.ContainsKey($parentId)) { $byBot[$parentId] = [System.Collections.Generic.List[object]]::new() }
            $byBot[$parentId].Add($comp)
        }

        foreach ($c in $group.Group) {
            $agentsScanned++
            $hadSp = $false
            $botKey = $c.BotId.ToLowerInvariant()
            if ($byBot.ContainsKey($botKey)) {
                foreach ($comp in $byBot[$botKey]) {
                    $parsed = ConvertFrom-PPXKnowledgeComponent -Component $comp
                    if (-not $parsed) { continue }

                    $ct = [string] (Get-PPXNestedValue $comp 'componenttype' -Default '')
                    $observedTypes[$ct] = 1 + [int] $observedTypes[$ct]

                    if ($parsed.IsSharePoint) { $hadSp = $true; $spSourceCount++ }
                    if ($parsed.IsSharePoint -or $IncludeAllKnowledge) {
                        $rows.Add((New-Row $c $envInfo $envIdText 'Found' $comp $parsed))
                    }
                }
            }
            if ($hadSp) { $agentsWithSp++ }
        }
    }

    # --- Summary / export ---------------------------------------------------------------------------
    $summary = @(
        "Scope: $selectionLabel$(if ($selectedIds.Count) { ' [' + ($selectedIds -join ', ') + ']' })",
        "Agents in scope: $($agents.Count); with knowledge sources (scanned candidates): $($candidates.Count); skipped (knowledge count 0): $skippedNoKnowledge",
        "Environments scanned via Dataverse: $envScanned; failed: $envFailed",
        "Agents scanned: $agentsScanned; agents with >=1 SharePoint source: $agentsWithSp; SharePoint sources found: $spSourceCount",
        "Knowledge-source componenttype values observed: $(if ($observedTypes.Count) { ($observedTypes.GetEnumerator() | ForEach-Object { "$($_.Key) (x$($_.Value))" }) -join ', ' } else { '(none)' })"
    )
    $summary | ForEach-Object { Write-Host $_ }
    if ($envFailed) { $incomplete.Add("$envFailed environment(s) could not be scanned (see Errors); their agents appear as Error rows.") }

    if ($ExportReport) {
        $exportParams = @{
            Rows              = $rows.ToArray()
            Summary           = $summary
            Errors            = $runErrors.ToArray()
            IncompleteReasons = $incomplete.ToArray()
        }
        if ($OutputPath) { $exportParams['Path'] = $OutputPath }
        $result = Export-PPXReport @exportParams
        Write-Host "Report: $($result.CsvPath) ($($result.RowCount) row(s))."
        Write-Host "Notes:  $($result.LimitationsPath)"
        return $result.Rows
    }

    Write-Host "ExportReport is `$false -- nothing written. Returning $($rows.Count) row(s)."
    return $rows.ToArray()
}
