#Requires -Modules Az.Accounts

# The Power Platform API is called with a user (delegated) token.
#
# 8578e004-a5c6-46e7-913e-12f58912df43 is the API *resource*, not a client you can sign in as, and
# Microsoft publishes no sample public client for this API. Rather than require every user to register
# their own Entra app, this tool piggybacks on the Az PowerShell first-party client (already consented
# for the Power Platform API) via Connect-AzAccount / Get-AzAccessToken.
# See: https://learn.microsoft.com/en-us/power-platform/admin/programmability-authentication-v2
$script:PPXPowerPlatformResourceUrl = 'https://api.powerplatform.com'

function Get-PPXPowerPlatformToken {
    <#
    .SYNOPSIS
        Acquires a delegated bearer token for the Power Platform API (https://api.powerplatform.com),
        reusing the current Az context when possible.
    .DESCRIPTION
        Both callers in this tool -- Connect-PPXInventoryApi (resourcequery) and
        Get-PPXEnvironmentConnector (connectivity) -- hit the same api.powerplatform.com resource, so
        the token is acquired once by the entry point and passed down, rather than re-running the Az
        context check per environment.

        If there is no current Az context (or it is for a different tenant) Connect-AzAccount runs
        interactively, then Get-AzAccessToken issues a token for https://api.powerplatform.com.
        Requires the Az.Accounts module. Unattended/service-principal auth against these endpoints is
        a known platform limitation and is not implemented.
    .PARAMETER TenantId
        Optional Entra tenant ID. If an Az context for a different tenant is already active, a new
        interactive Connect-AzAccount is forced for this tenant.
    .PARAMETER UseDeviceAuthentication
        Sign in with device-code flow instead of the interactive browser/WAM prompt. Needed when the
        browser prompt cannot render -- e.g. inside the VS Code debugger / PowerShell Integrated
        Console, where WAM silently hangs.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [switch] $UseDeviceAuthentication
    )

    $context = Get-AzContext
    if (-not $context -or ($TenantId -and $context.Tenant.Id -ne $TenantId)) {
        $connectParams = @{ ErrorAction = 'Stop' }
        if ($TenantId) { $connectParams['TenantId'] = $TenantId }
        if ($UseDeviceAuthentication) { $connectParams['UseDeviceAuthentication'] = $true }

        Write-Verbose 'No usable Az context; signing in with Connect-AzAccount.'
        $null = Connect-AzAccount @connectParams
    }

    Write-Verbose "Requesting a delegated token for $script:PPXPowerPlatformResourceUrl"
    $tokenResponse = Get-AzAccessToken -ResourceUrl $script:PPXPowerPlatformResourceUrl -ErrorAction Stop

    # Az.Accounts 5.x returns Token as a SecureString by default; older versions return a plain string.
    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    }
    return $tokenResponse.Token
}
