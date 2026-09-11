function Resolve-PPXEnvironmentLookup {
    <#
    .SYNOPSIS
        Pulls every environment from the Power Platform Inventory API as its own independent query
        and returns a lookup keyed by lowercased environment ID.
    .DESCRIPTION
        Runs `microsoft.powerplatform/environments` through Connect-PPXInventoryApi's `-Clauses`
        override -- no `project` clause, matching the no-project shape already proven elsewhere in
        this repo (see Connect-PPXInventoryApi.ps1 and CHANGELOG.md "Custom Connector Usage —
        bring-up fixes"). Fields are read off the raw record shape (`name` / `properties.*` /
        `location`).

        This replaced a server-side leftouter join from agents to environments (one request instead
        of a join baked into every agent-query page). The join was found to fan out badly against a
        large tenant -- see Connect-PPXInventoryApi.ps1's .DESCRIPTION for the numbers -- so the
        entry point now fetches agents and environments as two independent paged queries and joins
        them client-side here instead.
    .PARAMETER TenantId
        Forwarded to Connect-PPXInventoryApi.
    .PARAMETER Top
        Forwarded to Connect-PPXInventoryApi.
    .PARAMETER MaxPages
        Forwarded to Connect-PPXInventoryApi.
    .PARAMETER UseDeviceAuthentication
        Forwarded to Connect-PPXInventoryApi.
    .OUTPUTS
        [PSCustomObject] with:
          - Lookup: a case-insensitive hashtable, lowercased environment ID -> { environmentName,
            environmentType, isManagedEnvironment, environmentRegion }.
          - Inventory: the raw Connect-PPXInventoryApi envelope for this query (totalRecords,
            resultTruncated, pagesRetrieved, ...), so the caller can flag an incomplete environment
            pull the same way an incomplete agent pull is flagged.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [int] $Top,

        [int] $MaxPages,

        [switch] $UseDeviceAuthentication
    )

    $environmentClauses = @(
        [ordered]@{
            '$type'   = 'where'
            FieldName = 'type'
            Operator  = '=='
            Values    = @("'microsoft.powerplatform/environments'")
        }
        [ordered]@{
            '$type'           = 'orderby'
            FieldNamesAscDesc = [ordered]@{
                'name' = 'asc'
            }
        }
    )

    $connectParams = @{ Clauses = $environmentClauses }
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
        $lookup[$key] = [PSCustomObject]@{
            environmentName      = Get-PPXNestedValue $properties 'displayName' -Default ''
            environmentType      = Get-PPXNestedValue $properties 'environmentType' -Default ''
            isManagedEnvironment = Get-PPXNestedValue $properties 'isManaged' -Default ''
            environmentRegion    = Get-PPXNestedValue $record 'location' -Default ''
        }
    }

    return [PSCustomObject]@{
        Lookup    = $lookup
        Inventory = $inventory
    }
}
