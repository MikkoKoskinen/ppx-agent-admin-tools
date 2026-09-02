#Requires -Modules MSAL.PS

# Entra app registration for the Power Platform API (delegated permissions only).
# See: https://learn.microsoft.com/en-us/power-platform/admin/programmability-authentication-v2
$script:PPXInventoryApiClientId = '8578e004-a5c6-46e7-913e-12f58912df43'
$script:PPXInventoryApiScope = 'https://api.powerplatform.com/.default'
$script:PPXInventoryApiBaseUri = 'https://api.powerplatform.com/resourcequery/resources/query'
$script:PPXInventoryApiToken = $null

function Connect-PPXInventoryApi {
    <#
    .SYNOPSIS
        Acquires an interactive delegated token for the Power Platform Inventory API and queries
        Copilot Studio (V2) agent resources joined with their environments.
    .DESCRIPTION
        Wraps POST https://api.powerplatform.com/resourcequery/resources/query.

        Auth is interactive delegated (MSAL) only for this patch. Unattended/service-principal auth
        against this endpoint is a known open item (request is forwarded to Azure Resource Graph,
        which currently expects an On-Behalf-Of flow) — not implemented here, see the companion
        solution description §10.

        Returns the raw deserialized resource records (agents + environments). No shaping, joining,
        or column calculation is performed here — that happens in the assembly step of the caller.
    .PARAMETER TenantId
        Optional Entra tenant ID to hint the interactive sign-in to a specific tenant.
    .PARAMETER Top
        Optional page size for the resource query. Defaults to the API's own default when omitted.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [int] $Top
    )

    if (-not $script:PPXInventoryApiToken -or $script:PPXInventoryApiToken.ExpiresOn -le (Get-Date)) {
        $msalParams = @{
            ClientId    = $script:PPXInventoryApiClientId
            Scopes      = $script:PPXInventoryApiScope
            Interactive = $true
        }
        if ($TenantId) {
            $msalParams['TenantId'] = $TenantId
        }

        Write-Verbose 'Acquiring interactive delegated token for the Power Platform Inventory API.'
        $script:PPXInventoryApiToken = Get-MsalToken @msalParams
    }

    $headers = @{
        Authorization = "Bearer $($script:PPXInventoryApiToken.AccessToken)"
        'Content-Type' = 'application/json'
    }

    # Query clause structure per the Microsoft inventory schema reference:
    #   https://learn.microsoft.com/en-us/power-platform/admin/inventory-api
    #   https://learn.microsoft.com/en-us/power-platform/admin/inventory-schema-copilot-studio-agents
    # Requests Copilot Studio (V2) agent resources and environment resources in one call so the
    # caller can join them without a second round trip.
    $body = @{
        select = @(
            'properties.displayName'
            'properties.environmentId'
            'properties.createdAt'
            'properties.authentication'
            'properties.orchestration'
            'properties.powerPlatformConnectors'
            'properties.capabilitiesCounts'
        )
        from   = 'powerplatformresources'
        where  = "type in ('microsoft.powerplatform/environments', 'microsoft.copilotstudio/bots')"
    }
    if ($Top) {
        $body['top'] = $Top
    }

    $uri = $script:PPXInventoryApiBaseUri

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json -Depth 10)
    }
    catch {
        $responseBody = $null
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = [System.IO.StreamReader]::new($stream)
                $responseBody = $reader.ReadToEnd()
            }
            catch {
                # Best-effort only; fall through with $responseBody still $null.
            }
        }
        throw "Power Platform Inventory API request failed: $($_.Exception.Message)`n$responseBody"
    }

    return $response
}
