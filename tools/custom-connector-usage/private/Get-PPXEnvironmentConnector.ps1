#Requires -Modules Az.Accounts

$script:PPXConnectivityApiBaseUri = 'https://api.powerplatform.com/connectivity/environments'
$script:PPXConnectivityApiVersion = '2024-10-01'

function Get-PPXEnvironmentConnector {
    <#
    .SYNOPSIS
        Lists the connectors that EXIST in one environment via the Power Platform API connectivity
        endpoint, with the authoritative `properties.isCustomApi` flag and connector metadata.
    .DESCRIPTION
        GET https://api.powerplatform.com/connectivity/environments/{environmentId}/connectors
            ?$filter=environment eq '{environmentId}'&api-version=2024-10-01

        This is the piece the Inventory API can't give: a custom connector that has been created or
        imported into an environment but is not yet referenced by any app / flow / agent. It also
        supplies the real display name, publisher, and tier (the Inventory connector-usage array is
        IDs only).

        Same resource (https://api.powerplatform.com) as the Inventory API, so the same delegated
        token is reused -- pass it in via -AccessToken (the entry point acquires it once rather than
        re-checking the Az context per environment).

        Environment-scoped, so the caller loops this over every environment. Throttling (HTTP 429) is
        retried a few times honouring Retry-After; every other error is thrown for the caller to
        catch and record per environment (a run over hundreds of environments should not abort
        because one environment 403s or is mid-deletion).
    .PARAMETER EnvironmentId
        The environment ID (GUID form, as returned by the Inventory API `name` field for an
        environment record).
    .PARAMETER AccessToken
        Pre-acquired bearer token for https://api.powerplatform.com (see Get-PPXPowerPlatformToken).
    .PARAMETER TokenFactory
        Optional scriptblock returning a fresh bearer token, used to refresh once on an HTTP 401 (a
        long sweep over many environments can outlive the token).
    .PARAMETER CustomOnly
        Return only connectors where properties.isCustomApi is $true. Default: return all connectors
        in the environment.
    .PARAMETER MaxRetries
        Retry attempts on HTTP 429 before giving up. Default 4.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentId,

        [Parameter(Mandatory)] [string] $AccessToken,

        [scriptblock] $TokenFactory,

        [switch] $CustomOnly,

        [int] $MaxRetries = 4
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $tokenRefreshed = $false
    $filter  = [uri]::EscapeDataString("environment eq '$EnvironmentId'")
    $uri     = "$script:PPXConnectivityApiBaseUri/$EnvironmentId/connectors?`$filter=$filter&api-version=$script:PPXConnectivityApiVersion"

    $all      = [System.Collections.Generic.List[object]]::new()
    $pageGuard = 0

    while ($uri -and $pageGuard -lt 200) {
        $pageGuard++
        $attempt = 0
        $response = $null

        while ($true) {
            $attempt++
            try {
                $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
                break
            }
            catch {
                $status = $null
                try { $status = [int] $_.Exception.Response.StatusCode } catch { }

                if ($status -eq 429 -and $attempt -le $MaxRetries) {
                    $retryAfter = 5
                    try {
                        $ra = $_.Exception.Response.Headers['Retry-After']
                        if ($ra) { $retryAfter = [int] $ra }
                    }
                    catch { }
                    Write-Verbose "429 from connectivity API for $EnvironmentId; retry $attempt/$MaxRetries after ${retryAfter}s."
                    Start-Sleep -Seconds $retryAfter
                    continue
                }

                if ($status -eq 401 -and $TokenFactory -and -not $tokenRefreshed) {
                    $tokenRefreshed = $true
                    Write-Verbose "401 from connectivity API for $EnvironmentId; refreshing token and retrying."
                    $headers['Authorization'] = "Bearer $(& $TokenFactory)"
                    continue
                }

                $detail = $_.ErrorDetails.Message
                if (-not $detail -and $_.Exception.Response) {
                    try {
                        $stream = $_.Exception.Response.GetResponseStream()
                        $reader = [System.IO.StreamReader]::new($stream)
                        $detail = $reader.ReadToEnd()
                    }
                    catch { }
                }
                throw "Connectivity API request failed for environment $EnvironmentId ($($_.Exception.Message)).`n$detail"
            }
        }

        foreach ($c in @($response.value)) { $all.Add($c) }

        # The list response documents only `value`; follow a continuation link if the service ever
        # returns one (nextLink / @odata.nextLink).
        $uri = $response.nextLink
        if (-not $uri -and $response.PSObject.Properties['@odata.nextLink']) { $uri = $response.'@odata.nextLink' }
    }

    # isCustomApi may deserialise as a JSON boolean ($true) or, defensively, as the string "true"/
    # "True" -- accept both so a string form doesn't silently drop every custom connector.
    $isCustom = {
        param($c)
        $v = $c.properties.isCustomApi
        ($v -is [bool] -and $v) -or ("$v" -match '^(?i:true|1)$')
    }

    $customCount = @($all | Where-Object { & $isCustom $_ }).Count
    Write-Verbose "Connectivity API: environment $EnvironmentId returned $($all.Count) connector(s), $customCount custom."

    $result = if ($CustomOnly) { $all | Where-Object { & $isCustom $_ } } else { $all }
    return @($result)
}
