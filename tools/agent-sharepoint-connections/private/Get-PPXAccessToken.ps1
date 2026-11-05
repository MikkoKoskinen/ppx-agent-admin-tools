#Requires -Modules Az.Accounts

function Get-PPXAccessToken {
    <#
    .SYNOPSIS
        Returns a delegated access token (plain string) for an arbitrary resource, via Az PowerShell.
    .DESCRIPTION
        Same pattern as Connect-PPXInventoryApi: sign in with Connect-AzAccount only if there is no
        Az context (or it is for another tenant), then Get-AzAccessToken -ResourceUrl <resource>.
        Used here for the two resources besides the Power Platform API that this tool talks to:
        the environment's Dataverse org URL (https://<org>.crm*.dynamics.com) and, as an instance-URL
        fallback, the BAP admin API (https://service.powerapps.com/).
    .PARAMETER ResourceUrl
        Resource (audience) to request a token for.
    .PARAMETER TenantId
        Optional Entra tenant ID; forces a new sign-in if the current Az context is for another tenant.
    .PARAMETER UseDeviceAuthentication
        Device-code sign-in instead of the interactive browser/WAM prompt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceUrl,

        [string] $TenantId,

        [switch] $UseDeviceAuthentication
    )

    $context = Get-AzContext
    if (-not $context -or ($TenantId -and $context.Tenant.Id -ne $TenantId)) {
        $connectParams = @{ ErrorAction = 'Stop' }
        if ($TenantId) { $connectParams['TenantId'] = $TenantId }
        if ($UseDeviceAuthentication) { $connectParams['UseDeviceAuthentication'] = $true }
        $null = Connect-AzAccount @connectParams
    }

    $tokenResponse = Get-AzAccessToken -ResourceUrl $ResourceUrl -ErrorAction Stop
    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    }
    return $tokenResponse.Token
}
