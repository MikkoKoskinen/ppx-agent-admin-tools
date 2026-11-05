function Resolve-PPXEnvironmentInstanceUrl {
    <#
    .SYNOPSIS
        Fallback lookup of an environment's Dataverse org URL via the BAP admin API.
    .DESCRIPTION
        Used only when the Inventory environment record carried no instance URL.
          GET https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/{id}?api-version=2021-04-01
        Reads properties.linkedEnvironmentMetadata.instanceApiUrl (falling back to instanceUrl).
        Token audience: https://service.powerapps.com/ . This is the same (unofficial-for-automation)
        BAP endpoint the Power Platform admin tooling uses; no precedent elsewhere in this repo, so
        failures are returned as a blank URL plus an Error string, never thrown.
    .OUTPUTS
        [PSCustomObject] with InstanceUrl (blank when not found) and Error (blank on success).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentId,

        [string] $TenantId,

        [switch] $UseDeviceAuthentication
    )

    try {
        $tokenParams = @{ ResourceUrl = 'https://service.powerapps.com/' }
        if ($TenantId) { $tokenParams['TenantId'] = $TenantId }
        if ($UseDeviceAuthentication) { $tokenParams['UseDeviceAuthentication'] = $true }
        $token = Get-PPXAccessToken @tokenParams

        $uri = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/${EnvironmentId}?api-version=2021-04-01"
        $env = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop

        $url = Get-PPXNestedValue $env 'properties.linkedEnvironmentMetadata.instanceApiUrl' -Default ''
        if (-not $url) { $url = Get-PPXNestedValue $env 'properties.linkedEnvironmentMetadata.instanceUrl' -Default '' }
        if (-not $url) {
            return [PSCustomObject]@{ InstanceUrl = ''; Error = 'BAP returned no linkedEnvironmentMetadata (environment has no Dataverse database?).' }
        }
        return [PSCustomObject]@{ InstanceUrl = ([string] $url).TrimEnd('/'); Error = '' }
    }
    catch {
        return [PSCustomObject]@{ InstanceUrl = ''; Error = "BAP lookup failed: $($_.Exception.Message)" }
    }
}
