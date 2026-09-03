#Requires -Modules Az.Accounts

# The Power Platform API is called with a user (delegated) token.
#
# 8578e004-a5c6-46e7-913e-12f58912df43 is the API *resource*, not a client you can sign in as, and
# Microsoft publishes no sample public client for this API. Rather than require every user to register
# their own Entra app, this tool piggybacks on the Az PowerShell first-party client (already consented
# for the Power Platform API) via Connect-AzAccount / Get-AzAccessToken.
# See: https://learn.microsoft.com/en-us/power-platform/admin/programmability-authentication-v2
$script:PPXInventoryApiResourceUrl = 'https://api.powerplatform.com'
$script:PPXInventoryApiBaseUri     = 'https://api.powerplatform.com/resourcequery/resources/query'
$script:PPXInventoryApiVersion     = '2024-10-01'

function Connect-PPXInventoryApi {
    <#
    .SYNOPSIS
        Acquires a delegated token for the Power Platform Inventory API and queries Copilot Studio
        (V2) agent resources joined with their environments.
    .DESCRIPTION
        Wraps POST https://api.powerplatform.com/resourcequery/resources/query.

        Auth is interactive delegated, obtained through Az PowerShell: if there is no current Az
        context (or it is for a different tenant) Connect-AzAccount runs interactively, then
        Get-AzAccessToken issues a token for https://api.powerplatform.com. Requires the Az.Accounts
        module. Unattended/service-principal auth against this endpoint is a known platform
        limitation (the request is forwarded to Azure Resource Graph, which currently expects an
        On-Behalf-Of flow) — not implemented here, see PPXAgentGovernanceBaseline.md § 6.3.

        Returns the raw deserialized resource records (agents + environments). No shaping, joining,
        or column calculation is performed here — that happens in the assembly step of the caller.
    .PARAMETER TenantId
        Optional Entra tenant ID. If an Az context for a different tenant is already active, a new
        interactive Connect-AzAccount is forced for this tenant.
    .PARAMETER Top
        Optional page size for the resource query. Defaults to the API's own default when omitted.
    .PARAMETER UseDeviceAuthentication
        Sign in with device-code flow (a code + URL to complete in any browser) instead of the
        interactive browser/WAM prompt. Needed when the browser prompt cannot render — e.g. running
        inside the VS Code debugger / PowerShell Integrated Console, where WAM silently hangs.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [int] $Top,

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

    Write-Verbose "Requesting a delegated token for $script:PPXInventoryApiResourceUrl"
    $tokenResponse = Get-AzAccessToken -ResourceUrl $script:PPXInventoryApiResourceUrl -ErrorAction Stop

    # Az.Accounts 5.x returns Token as a SecureString by default; older versions return a plain string.
    $accessToken = if ($tokenResponse.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    }
    else {
        $tokenResponse.Token
    }

    $headers = @{
        Authorization = "Bearer $accessToken"
        'Content-Type' = 'application/json'
    }

    # Query request per the inventory API contract (typed clauses, not a KQL/SQL string):
    #   https://learn.microsoft.com/en-us/power-platform/admin/inventory-api
    #   https://learn.microsoft.com/en-us/power-platform/admin/inventory-schema
    # Mirrors the Power Platform admin center default pattern: left-join every resource to its
    # environment record, then filter to Copilot Studio (V2) agents. Agent-side fields are returned
    # whole for now (no project clause) — column selection / §5 shaping is a later build step.
    #
    # Every clause object is [ordered] so that '$type' serialises as the FIRST property. The service
    # deserialises Clauses polymorphically (System.Text.Json), which requires the type discriminator
    # to lead the object; a plain @{} hashtable has no key order and yields
    # "KQLOM format is wrong or it cannot be null".
    $query = [ordered]@{
        TableName = 'PowerPlatformResources'
        Options   = [ordered]@{
            Top  = if ($Top) { $Top } else { 1000 }
            Skip = 0
        }
        Clauses   = @(
            [ordered]@{
                '$type'    = 'extend'
                FieldName  = 'joinKey'
                Expression = 'tolower(tostring(properties.environmentId))'
            }
            [ordered]@{
                '$type'    = 'join'
                JoinKind   = 'leftouter'
                RightTable = [ordered]@{
                    TableName = 'PowerPlatformResources'
                    Clauses   = @(
                        [ordered]@{
                            '$type'   = 'where'
                            FieldName = 'type'
                            Operator  = '=='
                            Values    = @("'microsoft.powerplatform/environments'")
                        }
                        [ordered]@{
                            '$type'   = 'project'
                            FieldList = @(
                                'joinKey = tolower(name)'
                                'environmentName = properties.displayName'
                                'environmentType = properties.environmentType'
                                'isManagedEnvironment = properties.isManaged'
                                'environmentRegion = location'
                            )
                        }
                    )
                }
                LeftColumnName  = 'joinKey'
                RightColumnName = 'joinKey'
            }
            [ordered]@{
                '$type'   = 'where'
                FieldName = 'type'
                Operator  = 'in~'
                Values    = @("'microsoft.copilotstudio/agents'")
            }
            [ordered]@{
                '$type'           = 'orderby'
                FieldNamesAscDesc = [ordered]@{ 'tostring(properties.createdAt)' = 'desc' }
            }
        )
    }

    $uri = "${script:PPXInventoryApiBaseUri}?api-version=${script:PPXInventoryApiVersion}"

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($query | ConvertTo-Json -Depth 20)
    }
    catch {
        # PowerShell 7 puts the response body in ErrorDetails.Message; 5.1 needs the response stream.
        $detail = $_.ErrorDetails.Message
        if (-not $detail -and $_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = [System.IO.StreamReader]::new($stream)
                $detail = $reader.ReadToEnd()
            }
            catch {
                # Best-effort only; fall through with $detail still $null.
            }
        }
        throw "Power Platform Inventory API request failed ($($_.Exception.Message)).`n$detail"
    }

    return $response
}
