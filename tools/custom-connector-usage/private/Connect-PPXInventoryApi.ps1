#Requires -Modules Az.Accounts

# Deliberate copy of the skipToken-paging machinery from
# tools/agent-governance-baseline/private/Connect-PPXInventoryApi.ps1. The two tools are independent
# and self-contained by design. Differences here: the query is not baked in (the caller passes
# -Clauses), the delegated token is acquired by Get-PPXPowerPlatformToken (shared with
# Get-PPXEnvironmentConnector) or passed in, a -TokenFactory lets a long run refresh an expired
# token, and a non-progress guard stops a query whose skipToken never terminates. Extracting the
# shared code to tools/_shared is a tracked follow-up for both tools.
$script:PPXInventoryApiBaseUri = 'https://api.powerplatform.com/resourcequery/resources/query'
$script:PPXInventoryApiVersion = '2024-10-01'

# Azure Resource Graph caps a single page at 1000 rows regardless of a larger Options.Top.
$script:PPXInventoryApiMaxPageSize = 1000

# Stop after this many consecutive pages that returned zero rows while still handing back a
# skipToken -- the degenerate case where the service never signals "done".
$script:PPXInventoryApiEmptyStreakCap = 3

# Absolute safety net on total pages. 1000 pages x 1000 rows = 1,000,000 records -- beyond any real
# tenant, and low enough that a runaway loop can't run long enough to outlive the access token.
$script:PPXInventoryApiHardPageCap = 1000

function Connect-PPXInventoryApi {
    <#
    .SYNOPSIS
        Runs a caller-supplied resource query against the Power Platform Inventory API, following
        skipToken paging until every record has been retrieved.
    .DESCRIPTION
        Wraps POST https://api.powerplatform.com/resourcequery/resources/query. Auth is interactive
        delegated (Az PowerShell) -- see Get-PPXPowerPlatformToken.

        Paging: Azure Resource Graph returns at most 1000 rows per request and a `skipToken` when
        more remain. This function loops, feeding each response's skipToken back into
        Options.SkipToken, until the service stops returning one. It also stops if several
        consecutive pages come back empty with a skipToken still pending (a service-side paging
        quirk), or the -MaxPages / hard-cap limits are hit -- in any of those cases the returned
        envelope is marked resultTruncated = $true.
    .PARAMETER Clauses
        The KQLOM clause array (typed `$type` clause objects). Wrapped in the { TableName, Options,
        Clauses } envelope. Each clause must be [ordered]@{ '$type' = ...; ... } so the discriminator
        serialises first.
    .PARAMETER AccessToken
        Optional pre-acquired bearer token for https://api.powerplatform.com.
    .PARAMETER TokenFactory
        Optional scriptblock that returns a fresh bearer token. Used to acquire the first token when
        -AccessToken is omitted, and to refresh once on an HTTP 401 (a long multi-page run can
        outlive the token).
    .PARAMETER TenantId
        Forwarded to Get-PPXPowerPlatformToken when neither -AccessToken nor -TokenFactory is given.
    .PARAMETER Top
        Optional page size (1-1000, clamped). Does not cap the total.
    .PARAMETER MaxPages
        Optional cap on pages to follow. 0 (default) = no cap. Marks resultTruncated when it bites.
    .PARAMETER UseDeviceAuthentication
        Forwarded to Get-PPXPowerPlatformToken when acquiring the first token here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Clauses,

        [string] $AccessToken,

        [scriptblock] $TokenFactory,

        [string] $TenantId,

        [int] $Top,

        [int] $MaxPages,

        [switch] $UseDeviceAuthentication
    )

    if (-not $AccessToken) {
        $AccessToken = if ($TokenFactory) { & $TokenFactory }
                       else { Get-PPXPowerPlatformToken -TenantId $TenantId -UseDeviceAuthentication:$UseDeviceAuthentication }
    }

    $headers = @{
        Authorization  = "Bearer $AccessToken"
        'Content-Type' = 'application/json'
    }

    $pageSize = if ($Top -and $Top -gt 0) { [Math]::Min($Top, $script:PPXInventoryApiMaxPageSize) } else { $script:PPXInventoryApiMaxPageSize }
    if ($Top -and $Top -gt $script:PPXInventoryApiMaxPageSize) {
        Write-Verbose "Requested -Top $Top exceeds the API's $($script:PPXInventoryApiMaxPageSize)-row page cap; using $pageSize per page."
    }

    $options = [ordered]@{ Top = $pageSize; Skip = 0; SkipToken = '' }
    $query = [ordered]@{ TableName = 'PowerPlatformResources'; Options = $options; Clauses = $Clauses }

    $uri = "${script:PPXInventoryApiBaseUri}?api-version=${script:PPXInventoryApiVersion}"

    $allRecords       = [System.Collections.Generic.List[object]]::new()
    $page             = 0
    $lastTotalRecords = 0
    $pendingSkipToken = $null
    $emptyStreak      = 0
    $tokenRefreshed   = $false

    do {
        $page++
        $body = $query | ConvertTo-Json -Depth 20

        $response = $null
        while ($true) {
            try {
                $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
                break
            }
            catch {
                $status = $null
                try { $status = [int] $_.Exception.Response.StatusCode } catch { }

                if ($status -eq 401 -and $TokenFactory -and -not $tokenRefreshed) {
                    $tokenRefreshed = $true
                    Write-Verbose "401 from Inventory API on page $page; refreshing token and retrying."
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
                throw "Power Platform Inventory API request failed on page $page ($($_.Exception.Message)).`n$detail"
            }
        }

        $pageRecords = @($response.data)
        if ($pageRecords.Count) { $allRecords.AddRange($pageRecords) }

        if ($null -ne $response.totalRecords) { $lastTotalRecords = [int64] $response.totalRecords }

        $pendingSkipToken = if ([string]::IsNullOrEmpty([string] $response.skipToken)) { $null } else { [string] $response.skipToken }

        Write-Verbose "Inventory API page ${page}: +$($pageRecords.Count) record(s); running total $($allRecords.Count) of $lastTotalRecords; more pages: $([bool] $pendingSkipToken)."
        if ($page % 10 -eq 0) { Write-Host "    ...page $page, $($allRecords.Count) record(s) so far." }

        if (-not $pendingSkipToken) { break }

        # Non-progress guard: the service handed back a continuation token but no data. A few of
        # these in a row means paging is not converging -- stop rather than hammer the endpoint
        # until the token expires.
        if ($pageRecords.Count -eq 0) {
            $emptyStreak++
            if ($emptyStreak -ge $script:PPXInventoryApiEmptyStreakCap) {
                Write-Warning "Stopped at page $page after $emptyStreak consecutive empty page(s) with a skipToken still pending ($($allRecords.Count) of $lastTotalRecords record(s) retrieved). The report will be marked INCOMPLETE."
                break
            }
        }
        else { $emptyStreak = 0 }

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

    # Defensive de-dup: deterministic ordering + skipToken should never repeat a row, but if it does,
    # key on the first identifier the records actually carry.
    $dedupKey = @('id', 'name', 'resourceId', 'environmentId', 'connectorId') |
        Where-Object { $data.Count -and $data[0].PSObject.Properties[$_] } | Select-Object -First 1
    if ($dedupKey) {
        $seen    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $deduped = [System.Collections.Generic.List[object]]::new()
        foreach ($rec in $data) {
            $key = [string] $rec.$dedupKey
            if ([string]::IsNullOrEmpty($key) -or $seen.Add($key)) { $deduped.Add($rec) }
        }
        if ($deduped.Count -ne $data.Count) {
            Write-Verbose "Dropped $($data.Count - $deduped.Count) duplicate record(s) across pages (keyed on '$dedupKey')."
            $data = $deduped.ToArray()
        }
    }

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
