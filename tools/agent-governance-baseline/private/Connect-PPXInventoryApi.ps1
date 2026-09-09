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

# Azure Resource Graph caps a single page at 1000 rows regardless of a larger Options.Top, so a
# tenant with more agents than that is only fully retrieved by following the skipToken continuation.
$script:PPXInventoryApiMaxPageSize = 1000

# Safety net: stop following skipToken after this many requests even if the service keeps handing
# one back, so a service-side paging bug can never spin this function forever. At 1000 rows/page
# this is 5,000,000 agent records — far beyond any real tenant.
$script:PPXInventoryApiHardPageCap = 5000

function Connect-PPXInventoryApi {
    <#
    .SYNOPSIS
        Acquires a delegated token for the Power Platform Inventory API and queries Copilot Studio
        (V2) agent resources joined with their environments, following skipToken paging until every
        record has been retrieved.
    .DESCRIPTION
        Wraps POST https://api.powerplatform.com/resourcequery/resources/query.

        Auth is interactive delegated, obtained through Az PowerShell: if there is no current Az
        context (or it is for a different tenant) Connect-AzAccount runs interactively, then
        Get-AzAccessToken issues a token for https://api.powerplatform.com. Requires the Az.Accounts
        module. Unattended/service-principal auth against this endpoint is a known platform
        limitation (the request is forwarded to Azure Resource Graph, which currently expects an
        On-Behalf-Of flow) — not implemented here, see PPXAgentGovernanceBaseline.md § 6.3.

        Paging: Azure Resource Graph returns at most 1000 rows per request and a `skipToken` when
        more remain. This function loops, feeding each response's skipToken back into
        Options.SkipToken, until the service stops returning one (or -MaxPages / the hard safety cap
        is hit). The returned envelope is synthesised from all pages: `data` holds every record,
        `count` is the full retrieved total, and `resultTruncated` is $true only if the loop stopped
        before the service said it was done.

        Returns the raw deserialized resource records (agents + environments). No shaping, joining,
        or column calculation is performed here — that happens in the assembly step of the caller.
    .PARAMETER TenantId
        Optional Entra tenant ID. If an Az context for a different tenant is already active, a new
        interactive Connect-AzAccount is forced for this tenant.
    .PARAMETER Top
        Optional page size for the resource query (rows per request), 1-1000. Values above 1000 are
        clamped, since Azure Resource Graph will not return more than that in one page. This no
        longer caps the total result — every page is followed. Defaults to 1000.
    .PARAMETER MaxPages
        Optional cap on how many pages (requests) to follow. 0 (default) means "no cap — retrieve
        everything". Set a small number for a quick partial pull while testing; the returned
        envelope is then marked resultTruncated = $true so the report records that it is incomplete.
    .PARAMETER UseDeviceAuthentication
        Sign in with device-code flow (a code + URL to complete in any browser) instead of the
        interactive browser/WAM prompt. Needed when the browser prompt cannot render — e.g. running
        inside the VS Code debugger / PowerShell Integrated Console, where WAM silently hangs.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [int] $Top,

        [int] $MaxPages,

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

    $pageSize = if ($Top -and $Top -gt 0) { [Math]::Min($Top, $script:PPXInventoryApiMaxPageSize) } else { $script:PPXInventoryApiMaxPageSize }
    if ($Top -and $Top -gt $script:PPXInventoryApiMaxPageSize) {
        Write-Verbose "Requested -Top $Top exceeds the API's $($script:PPXInventoryApiMaxPageSize)-row page cap; using $pageSize per page and following skipToken for the rest."
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
    #
    # The orderby carries a `name` tie-breaker after createdAt: skipToken paging in Azure Resource
    # Graph is only stable when the sort is fully deterministic. `name` is the resource's unique id,
    # so this guarantees no row is skipped or repeated between pages when many agents share a
    # createdAt value.
    $options = [ordered]@{
        Top       = $pageSize
        Skip      = 0
        SkipToken = ''
    }
    $query = [ordered]@{
        TableName = 'PowerPlatformResources'
        Options   = $options
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
                FieldNamesAscDesc = [ordered]@{
                    'tostring(properties.createdAt)' = 'desc'
                    'name'                           = 'asc'
                }
            }
        )
    }

    $uri = "${script:PPXInventoryApiBaseUri}?api-version=${script:PPXInventoryApiVersion}"

    $allRecords      = [System.Collections.Generic.List[object]]::new()
    $page            = 0
    $lastTotalRecords = 0
    $pendingSkipToken = $null

    do {
        $page++
        $body = $query | ConvertTo-Json -Depth 20

        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
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
            throw "Power Platform Inventory API request failed on page $page ($($_.Exception.Message)).`n$detail"
        }

        $pageRecords = @($response.data)
        if ($pageRecords.Count) { $allRecords.AddRange($pageRecords) }

        if ($null -ne $response.totalRecords) { $lastTotalRecords = [int64] $response.totalRecords }

        $pendingSkipToken = if ([string]::IsNullOrEmpty([string] $response.skipToken)) { $null } else { [string] $response.skipToken }

        Write-Verbose "Inventory API page ${page}: +$($pageRecords.Count) record(s); running total $($allRecords.Count) of $lastTotalRecords; more pages: $([bool] $pendingSkipToken)."

        if (-not $pendingSkipToken) { break }

        if ($MaxPages -gt 0 -and $page -ge $MaxPages) {
            Write-Warning "Stopped after $page page(s): -MaxPages $MaxPages reached with $($allRecords.Count) of $lastTotalRecords record(s) retrieved. The report will be marked INCOMPLETE."
            break
        }
        if ($page -ge $script:PPXInventoryApiHardPageCap) {
            Write-Warning "Stopped after the $($script:PPXInventoryApiHardPageCap)-page safety cap with $($allRecords.Count) of $lastTotalRecords record(s) retrieved. The report will be marked INCOMPLETE."
            break
        }

        $query.Options.SkipToken = $pendingSkipToken
    } while ($true)

    $data = $allRecords.ToArray()

    # Defensive de-dup: deterministic ordering plus skipToken should never repeat a row across pages,
    # but if the service ever does, one row per agent still holds. Key on `id`, falling back to `name`.
    $dedupKey = if ($data.Count -and $data[0].PSObject.Properties['id']) { 'id' }
                elseif ($data.Count -and $data[0].PSObject.Properties['name']) { 'name' }
                else { $null }
    if ($dedupKey) {
        $seen    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $deduped = [System.Collections.Generic.List[object]]::new()
        foreach ($rec in $data) {
            $key = [string] $rec.$dedupKey
            if ([string]::IsNullOrEmpty($key) -or $seen.Add($key)) { $deduped.Add($rec) }
        }
        if ($deduped.Count -ne $data.Count) {
            Write-Verbose "Dropped $($data.Count - $deduped.Count) duplicate record(s) returned across pages (keyed on '$dedupKey')."
            $data = $deduped.ToArray()
        }
    }

    # resultTruncated is true only if we bailed out with a continuation token still pending
    # (-MaxPages or the hard cap), or the service reported more records than we actually got back.
    $incomplete = [bool] $pendingSkipToken -or ($lastTotalRecords -gt 0 -and $data.Count -lt $lastTotalRecords)

    return [PSCustomObject]@{
        totalRecords    = $lastTotalRecords
        count           = $data.Count
        resultTruncated = $incomplete
        skipToken       = $pendingSkipToken
        pagesRetrieved  = $page
        data            = $data
    }
}
