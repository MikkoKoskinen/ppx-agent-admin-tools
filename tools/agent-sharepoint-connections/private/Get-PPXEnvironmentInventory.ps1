function Get-PPXEnvironmentInventory {
    <#
    .SYNOPSIS
        Pulls environments from the Power Platform Inventory API (all, or only the given IDs) and
        returns a lookup keyed by environment ID, including the Dataverse instance URL when the
        Inventory record carries one.
    .DESCRIPTION
        Runs `microsoft.powerplatform/environments` through Connect-PPXInventoryApi's -Clauses
        override. When -EnvironmentId is supplied a `name in~ (...)` clause is added server-side
        (`name` is the environment GUID, a top-level field already used for ordering elsewhere).

        The Dataverse instance URL is NOT a documented Inventory field. It is looked up defensively:
        the record's `properties` object is serialised and searched for the first
        https://<org>.crm*.<dynamics host> URL (research log: environment records carry it under
        linkedEnvironmentMetadata). If none is found, InstanceUrl is blank and the caller falls back
        to the BAP admin API (Resolve-PPXEnvironmentInstanceUrl).
    .PARAMETER EnvironmentId
        Optional list of environment GUIDs to restrict the query to.
    .OUTPUTS
        [PSCustomObject] with Lookup (case-insensitive dictionary: id -> environmentName,
        environmentType, isManagedEnvironment, instanceUrl) and Inventory (the raw envelope).
    #>
    [CmdletBinding()]
    param(
        [string[]] $EnvironmentId,

        [string] $TenantId,

        [int] $Top,

        [int] $MaxPages,

        [switch] $UseDeviceAuthentication
    )

    $clauses = @(
        [ordered]@{
            '$type'   = 'where'
            FieldName = 'type'
            Operator  = '=='
            Values    = @("'microsoft.powerplatform/environments'")
        }
    )
    if ($EnvironmentId) {
        $clauses += [ordered]@{
            '$type'   = 'where'
            FieldName = 'name'
            Operator  = 'in~'
            Values    = @($EnvironmentId | ForEach-Object { "'$_'" })
        }
    }
    $clauses += [ordered]@{
        '$type'           = 'orderby'
        FieldNamesAscDesc = [ordered]@{ 'name' = 'asc' }
    }

    $connectParams = @{ Clauses = $clauses }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    if ($Top) { $connectParams['Top'] = $Top }
    if ($MaxPages) { $connectParams['MaxPages'] = $MaxPages }
    if ($UseDeviceAuthentication) { $connectParams['UseDeviceAuthentication'] = $true }

    $inventory = Connect-PPXInventoryApi @connectParams

    $lookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($inventory.data)) {
        $key = [string] (Get-PPXNestedValue $record 'name' -Default '')
        if ([string]::IsNullOrEmpty($key)) { continue }

        $properties = Get-PPXNestedValue $record 'properties' -Default $null

        $instanceUrl = ''
        if ($properties) {
            try {
                $json = $properties | ConvertTo-Json -Depth 10 -Compress
                $m = [regex]::Match($json, 'https://[A-Za-z0-9-]+\.crm[0-9]*\.[A-Za-z0-9.]+')
                if ($m.Success) { $instanceUrl = $m.Value.TrimEnd('/') }
            }
            catch { }
        }

        $lookup[$key] = [PSCustomObject]@{
            environmentName      = Get-PPXNestedValue $properties 'displayName' -Default ''
            environmentType      = Get-PPXNestedValue $properties 'environmentType' -Default ''
            isManagedEnvironment = Get-PPXNestedValue $properties 'isManaged' -Default ''
            instanceUrl          = $instanceUrl
        }
    }

    return [PSCustomObject]@{
        Lookup    = $lookup
        Inventory = $inventory
    }
}
