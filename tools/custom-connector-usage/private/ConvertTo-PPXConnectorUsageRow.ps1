function ConvertTo-PPXConnectorUsageRow {
    <#
    .SYNOPSIS
        Produces the connector-usage report: ONE ROW PER (environment x custom connector), merging
        "the connector exists in the environment" (connectivity API) with "a resource references it"
        (Inventory API).
    .DESCRIPTION
        See PPXCustomConnectorUsage.md 5 for the schema. Row sources, unioned per environment:

          1. Connectivity API (Get-PPXEnvironmentConnector) -- authoritative. Every connector in the
             environment whose properties.isCustomApi is $true, whether or not anything uses it.
             Supplies display name / publisher / tier. IsCustomApi = "True".
          2. Inventory usage heuristic -- a fallback that catches custom connectors referenced by a
             resource but NOT returned by the connectivity call (call failed for that environment,
             or was skipped with -SkipEnvironmentConnectorLookup). Classified by
             Test-PPXCustomConnectorId (ID shape). IsCustomApi = "Inferred".

        Matching the two surfaces is done on Get-PPXNormalizedConnectorKey (their suffix formatting
        differs); see that helper for the collision caveat.

        With -IncludeAllEnvironments, an environment that yields no custom-connector rows still gets
        one placeholder row (connector columns blank, DetectionSource = "(none)") so the CSV doubles
        as a "confirmed clean" list.
    .PARAMETER Environments
        Environment detail records from the environments Inventory query: environmentId /
        environmentName / environmentType / isManagedEnvironment / environmentGroup /
        environmentGroupId / environmentRegion.
    .PARAMETER UsageRecords
        Flat resource records from the connector-usage Inventory query: resourceId / resourceType /
        resourceName / environmentId / connectors.
    .PARAMETER EnvironmentConnectors
        Hashtable environmentId -> array of connectivity-API connector objects (already filtered to
        isCustomApi = $true). An environment absent from the hashtable had its lookup skipped or
        failed -- see -EnvironmentErrors.
    .PARAMETER EnvironmentErrors
        Hashtable environmentId -> error string for environments whose connectivity lookup threw.
    .PARAMETER SkipEnvironmentConnectorLookup
        Set when the connectivity lookup was disabled globally -- changes "lookup failed" wording to
        "lookup skipped" and means every row is heuristic.
    .PARAMETER IncludeAllEnvironments
        Emit a placeholder row for environments with no custom-connector rows.
    .PARAMETER MaxListItems
        Cap for the '; '-joined ConsumingResources column.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Environments,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $UsageRecords,
        [hashtable] $EnvironmentConnectors,
        [hashtable] $EnvironmentErrors,
        [switch] $SkipEnvironmentConnectorLookup,
        [switch] $IncludeAllEnvironments,
        [int] $MaxListItems = 15
    )

    if (-not $EnvironmentConnectors) { $EnvironmentConnectors = @{} }
    if (-not $EnvironmentErrors) { $EnvironmentErrors = @{} }

    # Inventory records arrive whole (no project clause), so every field is read off the raw shape:
    # environments carry name / properties.* / location; resources carry name / type / properties.*.

    # --- Environment detail lookup -------------------------------------------------------------
    $envDetail = [ordered]@{}
    foreach ($e in $Environments) {
        $id = [string] (Get-PPXNestedValue $e 'name' -Default '')
        if ($id) { $envDetail[$id] = $e }
    }

    # --- Usage index: envId -> normalizedKey -> { RawIds, Resources, ByType, AnyHeuristicCustom } --
    $usage = [ordered]@{}
    foreach ($rec in $UsageRecords) {
        $envId = [string] (Get-PPXNestedValue $rec 'properties.environmentId' -Default '')
        if (-not $envId) { $envId = '(unknown)' }

        $connectors = Get-PPXNestedValue $rec 'properties.powerPlatformConnectors' -Default $null
        if ($connectors -is [string]) {
            try { $connectors = $connectors | ConvertFrom-Json } catch { $connectors = $null }
        }
        $connectors = @($connectors)
        if ($connectors.Count -eq 0) { continue }

        if (-not $usage.Contains($envId)) { $usage[$envId] = [ordered]@{} }
        $envUsage = $usage[$envId]

        $keysThisResource = [ordered]@{}
        foreach ($c in $connectors) {
            $cid = if ($c -is [string]) { $c } else { [string] $c.connectorId }
            if ([string]::IsNullOrWhiteSpace($cid)) { continue }
            $nk = Get-PPXNormalizedConnectorKey -ConnectorId $cid
            if (-not $envUsage.Contains($nk)) {
                $envUsage[$nk] = [PSCustomObject]@{
                    RawIds             = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    Resources          = [System.Collections.Generic.List[string]]::new()
                    ByType             = [ordered]@{}
                    AnyHeuristicCustom = $false
                }
            }
            $null = $envUsage[$nk].RawIds.Add($cid)
            if (Test-PPXCustomConnectorId -ConnectorId $cid) { $envUsage[$nk].AnyHeuristicCustom = $true }
            $keysThisResource[$nk] = $true
        }

        $rType = (([string] (Get-PPXNestedValue $rec 'type' -Default '')) -split '/')[-1]
        if (-not $rType) { $rType = 'unknown' }
        $rName = [string] (Get-PPXNestedValue $rec 'properties.displayName' -Default '')
        if (-not $rName) { $rName = [string] (Get-PPXNestedValue $rec 'name' -Default '(unnamed)') }

        foreach ($nk in @($keysThisResource.Keys)) {
            $entry = $envUsage[$nk]
            $entry.Resources.Add("$rName ($rType)")
            if (-not $entry.ByType.Contains($rType)) { $entry.ByType[$rType] = 0 }
            $entry.ByType[$rType]++
        }
    }

    # --- Environments to walk: union of env list, envs with usage, envs with a connector lookup ---
    $envIds = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($envDetail.Keys))            { if (-not $envIds.Contains($id)) { $envIds.Add($id) } }
    foreach ($id in @($usage.Keys))                { if (-not $envIds.Contains($id)) { $envIds.Add($id) } }
    foreach ($id in @($EnvironmentConnectors.Keys)) { if (-not $envIds.Contains($id)) { $envIds.Add($id) } }

    function New-Row {
        param($EnvId, $Detail, $ConnectorId, $ConnectorName, $Publisher, $Tier, $CreatedTime,
              $IsCustomApi, $ExistsInList, $IsReferenced, $ResourceCount, $ByType, $Resources, $Source)
        [PSCustomObject][ordered]@{
            EnvironmentName           = [string] (Get-PPXNestedValue $Detail 'properties.displayName' -Default '')
            EnvironmentId             = if ($EnvId -eq '(unknown)') { '' } else { $EnvId }
            EnvironmentType           = [string] (Get-PPXNestedValue $Detail 'properties.environmentType' -Default '')
            IsManagedEnvironment      = Get-PPXNestedValue $Detail 'properties.isManaged' -Default ''
            EnvironmentGroup          = [string] (Get-PPXNestedValue $Detail 'properties.environmentGroup' -Default '')
            EnvironmentGroupId        = [string] (Get-PPXNestedValue $Detail 'properties.environmentGroupId' -Default '')
            EnvironmentRegion         = [string] (Get-PPXNestedValue $Detail 'location' -Default '')
            ConnectorId               = $ConnectorId
            ConnectorName             = $ConnectorName
            ConnectorPublisher        = $Publisher
            ConnectorTier             = $Tier
            ConnectorCreatedTime      = $CreatedTime
            IsCustomApi               = $IsCustomApi
            ExistsInEnvironmentList   = $ExistsInList
            IsReferencedByResource    = $IsReferenced
            ConsumingResourceCount    = $ResourceCount
            ConsumingResourcesByType  = $ByType
            ConsumingResources        = $Resources
            DetectionSource           = $Source
        }
    }

    foreach ($envId in $envIds) {
        $detail   = if ($envDetail.Contains($envId)) { $envDetail[$envId] } else { $null }
        $envUsage = if ($usage.Contains($envId)) { $usage[$envId] } else { [ordered]@{} }
        $lookupFailed  = $EnvironmentErrors.ContainsKey($envId)
        $lookupHappened = $EnvironmentConnectors.ContainsKey($envId)

        $unknownExists = if ($SkipEnvironmentConnectorLookup) { 'Unknown (lookup skipped)' }
                         elseif ($lookupFailed) { 'Unknown (lookup failed)' }
                         else { 'Unknown (lookup skipped)' }

        $coveredKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $rowsForEnv  = 0

        # (1) Authoritative: custom connectors that EXIST in the environment.
        foreach ($c in @($EnvironmentConnectors[$envId] | Where-Object { $_ })) {
            $rawId = [string] $c.name
            $nk    = Get-PPXNormalizedConnectorKey -ConnectorId $rawId
            $null  = $coveredKeys.Add($nk)

            $u = if ($envUsage.Contains($nk)) { $envUsage[$nk] } else { $null }
            $isRef = [bool] $u

            $createdRaw = [string] (Get-PPXNestedValue $c 'properties.createdTime' -Default '')
            $created = $createdRaw
            if ($createdRaw) { try { $created = ([datetime] $createdRaw).ToString('o') } catch { } }

            New-Row -EnvId $envId -Detail $detail `
                -ConnectorId $rawId `
                -ConnectorName ([string] (Get-PPXNestedValue $c 'properties.displayName' -Default '')) `
                -Publisher ([string] (Get-PPXNestedValue $c 'properties.publisher' -Default '')) `
                -Tier ([string] (Get-PPXNestedValue $c 'properties.tier' -Default '')) `
                -CreatedTime $created `
                -IsCustomApi 'True' `
                -ExistsInList 'True' `
                -IsReferenced $isRef `
                -ResourceCount $(if ($u) { $u.Resources.Count } else { 0 }) `
                -ByType $(if ($u) { (@($u.ByType.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" })) -join '; ' } else { '' }) `
                -Resources $(if ($u) { ConvertTo-PPXJoinedList -Items $u.Resources -MaxItems $MaxListItems } else { '' }) `
                -Source $(if ($isRef) { 'Both' } else { 'ConnectivityApi' })
            $rowsForEnv++
        }

        # (2) Fallback: custom-looking connectors referenced by a resource but not covered by (1).
        foreach ($nk in @($envUsage.Keys)) {
            if ($coveredKeys.Contains($nk)) { continue }
            $u = $envUsage[$nk]
            if (-not $u.AnyHeuristicCustom) { continue }

            $existsVal = if ($lookupHappened -and -not $lookupFailed) { 'False' } else { $unknownExists }

            New-Row -EnvId $envId -Detail $detail `
                -ConnectorId (@($u.RawIds)[0]) `
                -ConnectorName '' -Publisher '' -Tier '' -CreatedTime '' `
                -IsCustomApi 'Inferred' `
                -ExistsInList $existsVal `
                -IsReferenced 'True' `
                -ResourceCount $u.Resources.Count `
                -ByType ((@($u.ByType.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" })) -join '; ') `
                -Resources (ConvertTo-PPXJoinedList -Items $u.Resources -MaxItems $MaxListItems) `
                -Source 'UsageHeuristic'
            $rowsForEnv++
        }

        # (3) Placeholder for a clean environment.
        if ($rowsForEnv -eq 0 -and $IncludeAllEnvironments) {
            $existsVal = if ($lookupHappened -and -not $lookupFailed) { 'n/a (no custom connectors)' } else { $unknownExists }
            New-Row -EnvId $envId -Detail $detail `
                -ConnectorId '' -ConnectorName '' -Publisher '' -Tier '' -CreatedTime '' `
                -IsCustomApi '' -ExistsInList $existsVal -IsReferenced '' `
                -ResourceCount 0 -ByType '' -Resources '' -Source '(none)'
        }
    }
}
