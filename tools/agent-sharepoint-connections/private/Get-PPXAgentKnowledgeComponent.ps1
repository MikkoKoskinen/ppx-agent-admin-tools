function Get-PPXAgentKnowledgeComponent {
    <#
    .SYNOPSIS
        Reads the Dataverse `botcomponents` rows (agent components) for a set of agents in one
        environment.
    .DESCRIPTION
        GET {InstanceUrl}/api/data/v9.2/botcomponents?$filter=(_parentbotid_value eq <id> or ...)
        [and componenttype eq N]

        UNOFFICIAL: no Microsoft documentation covers botcomponents for this purpose (see the tool's
        PPXAgentSharePointConnections.md, section 6). The component-type value for knowledge sources is
        not hardcoded; by default every component of the agent is returned and the caller detects
        knowledge sources from the content. Once the value is confirmed in your tenant (the report's
        ComponentType column shows it), pass -ComponentType to filter server-side and cut payload.

        No $select is used (a wrong column name would 400 the whole call); the full row is returned.
        Agents are queried in chunks of 15 ids per request, and @odata.nextLink is followed.
        HTTP 429 is retried (Retry-After), HTTP 401 refreshes the token once.
    .PARAMETER InstanceUrl
        Dataverse org URL, e.g. https://contoso.crm4.dynamics.com
    .PARAMETER BotId
        Agent (bot) GUIDs in this environment.
    .PARAMETER TokenFactory
        Scriptblock returning a Dataverse-scoped bearer token (called again after a 401).
    .PARAMETER ComponentType
        Optional botcomponent componenttype option value to filter server-side.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InstanceUrl,

        [Parameter(Mandatory)] [string[]] $BotId,

        [Parameter(Mandatory)] [scriptblock] $TokenFactory,

        [Nullable[int]] $ComponentType
    )

    $base = $InstanceUrl.TrimEnd('/')
    $headers = @{
        Authorization      = "Bearer $(& $TokenFactory)"
        Accept             = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
        Prefer             = 'odata.maxpagesize=500'
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $chunkSize = 15

    for ($i = 0; $i -lt $BotId.Count; $i += $chunkSize) {
        $chunk = @($BotId[$i..([Math]::Min($i + $chunkSize, $BotId.Count) - 1)])
        $botFilter = ($chunk | ForEach-Object { "_parentbotid_value eq $_" }) -join ' or '
        $filter = "($botFilter)"
        if ($null -ne $ComponentType) { $filter += " and componenttype eq $ComponentType" }

        $uri = "$base/api/data/v9.2/botcomponents?`$filter=" + [uri]::EscapeDataString($filter)

        while ($uri) {
            $response = $null
            $tokenRefreshed = $false
            $throttleRetries = 0
            while ($true) {
                try {
                    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
                    break
                }
                catch {
                    $status = $null
                    try { $status = [int] $_.Exception.Response.StatusCode } catch { }
                    $detail = $_.ErrorDetails.Message

                    if ($status -eq 401 -and -not $tokenRefreshed) {
                        $tokenRefreshed = $true
                        $headers['Authorization'] = "Bearer $(& $TokenFactory)"
                        continue
                    }
                    if ($status -eq 429 -and $throttleRetries -lt 4) {
                        $throttleRetries++
                        $wait = 5
                        try {
                            $ra = $_.Exception.Response.Headers['Retry-After']
                            if ($ra) { $wait = [Math]::Max(1, [int] ($ra | Select-Object -First 1)) }
                        }
                        catch { }
                        Start-Sleep -Seconds $wait
                        continue
                    }
                    throw "Dataverse botcomponents request failed (HTTP $status): $($_.Exception.Message) $detail"
                }
            }

            foreach ($row in @($response.value)) { $results.Add($row) }
            $uri = $response.'@odata.nextLink'
        }
    }

    return $results.ToArray()
}
