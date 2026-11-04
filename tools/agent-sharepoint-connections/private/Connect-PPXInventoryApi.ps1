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
# tenant with more agents than that is only fully retrieved by following Skip-offset paging (see
# Connect-PPXInventoryApi's .DESCRIPTION for why Options.SkipToken isn't used for this).
$script:PPXInventoryApiMaxPageSize = 1000

# Safety net: stop paging after this many requests even if every page keeps coming back full, so a
# pathological query (or a tenant that's simply enormous) can't spin this function forever. At 1000
# rows/page this is 5,000,000 agent records — far beyond any real tenant.
$script:PPXInventoryApiHardPageCap = 5000

function Connect-PPXInventoryApi {
    <#
    .SYNOPSIS
        Acquires a delegated token for the Power Platform Inventory API and queries Copilot Studio
        (V2) agent resources (by default) or a caller-supplied resource query, following Skip-offset
        paging until every record has been retrieved.
    .DESCRIPTION
        Wraps POST https://api.powerplatform.com/resourcequery/resources/query.

        Auth is interactive delegated, obtained through Az PowerShell: if there is no current Az
        context (or it is for a different tenant) Connect-AzAccount runs interactively, then
        Get-AzAccessToken issues a token for https://api.powerplatform.com. Requires the Az.Accounts
        module. Unattended/service-principal auth against this endpoint is a known platform
        limitation (the request is forwarded to Azure Resource Graph, which currently expects an
        On-Behalf-Of flow) — not implemented here, see PPXAgentGovernanceBaseline.md § 6.3.

        Paging: Azure Resource Graph returns at most 1000 rows per request. This function loops,
        incrementing Options.Skip by the page size each time, until a page comes back with fewer
        rows than requested (or -MaxPages / the hard safety cap is hit). The returned envelope is
        synthesised from all pages: `data` holds every record, `count` is the full retrieved total,
        and `resultTruncated` is $true only if the loop stopped before the service said it was done.

        **`Options.SkipToken` is not used for continuation** -- see the paging-loop comment below for
        why: against this tenant/query it proved non-functional (echoing it back always re-returned
        page 1), confirmed by a live A/B/C/D diagnostic pull. `Options.Skip` (plain offset paging)
        was confirmed live to advance correctly and is what's used instead.

        **Known trade-off of offset paging:** unlike a real continuation token, `Options.Skip` is a
        position, not a snapshot boundary. If an agent is created (or reordered ahead of the current
        offset by the `name` sort) while a run is still paging, a later page can shift and one record
        can be skipped without `resultTruncated` ever being set -- the loop only detects a page coming
        back short, not a page that silently omitted a row because the underlying set moved under it.
        Accepted here because `SkipToken` (the alternative) doesn't work at all against this API/query
        (above), and rows change orders of magnitude more slowly than a single run's paging window.

        Returns the raw deserialized resource records. No shaping or column calculation is performed
        here — that happens in the assembly step of the caller.

        The query no longer joins agents to environments server-side. Against a large tenant a run
        with the join returned 758,000+ rows for 5,530 real agents before failing on token expiry;
        the join was the first suspect, but removing it alone did **not** fix the symptom (a
        follow-up run with no join still hit 397,000+ rows at page 397, identical growth pattern),
        nor did switching the sort key from the volatile `createdAt` to the immutable `name` (still
        100% duplicate pages). The join's removal is kept anyway: it's still a real
        efficiency/robustness improvement (one row per agent per page instead of a join evaluated on
        every page), and Resolve-PPXEnvironmentLookup.ps1 now pulls environments as its own
        independent query, joined client-side by the entry point — matching the no-server-join
        pattern already used by the custom-connector-usage and copilot-credit-tenant-pool tools.
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
    .PARAMETER Clauses
        Optional. Overrides the baked-in Copilot Studio (V2) agents query with a caller-supplied
        KQLOM clause array (typed `$type` clause objects, each an [ordered] hashtable so the
        discriminator serialises first). Used by Resolve-PPXEnvironmentLookup.ps1 to run the
        environment-list query through the same paging/auth machinery.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [int] $Top,

        [int] $MaxPages,

        [object[]] $Clauses,

        [switch] $UseDeviceAuthentication
    )

    # Acquired once up front and again (via $acquireToken) whenever a long run outlives the token --
    # see the retry-on-failure handling in the paging loop below.
    $acquireToken = {
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
        if ($tokenResponse.Token -is [System.Security.SecureString]) {
            [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
        }
        else {
            $tokenResponse.Token
        }
    }

    $headers = @{
        Authorization = "Bearer $(& $acquireToken)"
        'Content-Type' = 'application/json'
    }

    $pageSize = if ($Top -and $Top -gt 0) { [Math]::Min($Top, $script:PPXInventoryApiMaxPageSize) } else { $script:PPXInventoryApiMaxPageSize }
    if ($Top -and $Top -gt $script:PPXInventoryApiMaxPageSize) {
        Write-Verbose "Requested -Top $Top exceeds the API's $($script:PPXInventoryApiMaxPageSize)-row page cap; using $pageSize per page and following Skip-offset paging for the rest."
    }

    # Query request per the inventory API contract (typed clauses, not a KQL/SQL string):
    #   https://learn.microsoft.com/en-us/power-platform/admin/inventory-api
    #   https://learn.microsoft.com/en-us/power-platform/admin/inventory-schema
    #
    # Every clause object is [ordered] so that '$type' serialises as the FIRST property. The service
    # deserialises Clauses polymorphically (System.Text.Json), which requires the type discriminator
    # to lead the object; a plain @{} hashtable has no key order and yields
    # "KQLOM format is wrong or it cannot be null".
    #
    # No server-side join to environments here (see .DESCRIPTION): filter to Copilot Studio (V2)
    # agents only, one row per agent. Agent-side fields are returned whole (no project clause) —
    # column selection / §5 shaping is a later build step.
    #
    # orderby `name` (the agent's immutable GUID resource id) alone -- NOT createdAt. An earlier
    # version ordered `tostring(properties.createdAt) desc, name asc` (newest first, matching PPAC's
    # own UI default) on a theory that a volatile sort key (this tenant creates agents continuously)
    # was breaking pagination; switching to `name` alone did NOT fix it either (paging turned out to
    # be broken regardless of sort key -- see the Options.Skip comment below for the actual root
    # cause). `name asc` is kept anyway: paging is now plain Skip-offset based, which requires a
    # deterministic sort for consecutive pages to line up correctly, and an immutable GUID is the
    # safest choice (a new agent created mid-run can't shift already-fetched pages the way a
    # createdAt-desc sort could).
    $defaultClauses = @(
        [ordered]@{
            '$type'   = 'where'
            FieldName = 'type'
            Operator  = 'in~'
            Values    = @("'microsoft.copilotstudio/agents'")
        }
        [ordered]@{
            '$type'           = 'orderby'
            FieldNamesAscDesc = [ordered]@{
                'name' = 'asc'
            }
        }
    )

    # Options.SkipToken is deliberately left '' and never populated from the response: a live A/B/C/D
    # diagnostic against this API proved it non-functional for this query -- echoing the server's own
    # skipToken back (Skip=0, SkipToken=<token>) returned page 1 again byte-for-byte (0 rows different
    # across 2,000+ record(s)/3 pages), while plain Options.Skip=1000 (SkipToken='') returned a fully
    # disjoint page (2,000 rows different from page 1). Skip-offset paging is what actually works here.
    $options = [ordered]@{
        Top       = $pageSize
        Skip      = 0
        SkipToken = ''
    }
    $query = [ordered]@{
        TableName = 'PowerPlatformResources'
        Options   = $options
        Clauses   = if ($Clauses) { $Clauses } else { $defaultClauses }
    }

    $uri = "${script:PPXInventoryApiBaseUri}?api-version=${script:PPXInventoryApiVersion}"

    $allRecords      = [System.Collections.Generic.List[object]]::new()
    $page            = 0
    $lastTotalRecords = 0
    $morePagesLikely  = $false

    do {
        $page++
        $body = $query | ConvertTo-Json -Depth 20

        # Reset per page (not once for the whole run): a large-tenant pull can span tens of minutes
        # and outlive more than one token lifetime, so each page gets its own one-retry allowance
        # instead of only the first expiry in the entire run being recoverable.
        $tokenRefreshed = $false

        $response = $null
        while ($true) {
            try {
                $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
                break
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

                $status = $null
                try { $status = [int] $_.Exception.Response.StatusCode } catch { }

                # A run against a large tenant can span tens of minutes and outlive the delegated
                # token: the service then fails the request while trying to exchange it
                # on-behalf-of the caller (401, or 400 with an OBO/AADSTS complaint in the body).
                # Refresh once and retry before giving up.
                $isAuthFailure = ($status -eq 401) -or ($detail -match 'OBO token|AADSTS')
                if ($isAuthFailure -and -not $tokenRefreshed) {
                    $tokenRefreshed = $true
                    Write-Verbose "Auth failure from Inventory API on page $page (status $status); refreshing token and retrying."
                    $headers['Authorization'] = "Bearer $(& $acquireToken)"
                    continue
                }

                throw "Power Platform Inventory API request failed on page $page ($($_.Exception.Message)).`n$detail"
            }
        }

        $pageRecords = @($response.data)
        if ($pageRecords.Count) { $allRecords.AddRange($pageRecords) }

        if ($null -ne $response.totalRecords) { $lastTotalRecords = [int64] $response.totalRecords }

        # A full page (row count == the requested page size) means there's likely more; a short page
        # (fewer rows than requested, including zero) means we've reached the real end of the data --
        # the standard offset-paging termination condition. (response.skipToken is intentionally
        # ignored here -- see the .DESCRIPTION and the comment above $options.)
        $morePagesLikely = $pageRecords.Count -ge $pageSize

        Write-Verbose "Inventory API page ${page}: +$($pageRecords.Count) record(s); running total $($allRecords.Count) of $lastTotalRecords; more pages: $morePagesLikely."
        if ($page % 10 -eq 0) { Write-Host "    ...page $page, $($allRecords.Count) record(s) so far." }

        if (-not $morePagesLikely) { break }

        if ($MaxPages -gt 0 -and $page -ge $MaxPages) {
            Write-Warning "Stopped after $page page(s): -MaxPages $MaxPages reached with $($allRecords.Count) of $lastTotalRecords record(s) retrieved. The report will be marked INCOMPLETE."
            break
        }
        if ($page -ge $script:PPXInventoryApiHardPageCap) {
            Write-Warning "Stopped after the $($script:PPXInventoryApiHardPageCap)-page safety cap with $($allRecords.Count) of $lastTotalRecords record(s) retrieved. The report will be marked INCOMPLETE."
            break
        }

        $query.Options.Skip = $page * $pageSize
    } while ($true)

    $data = $allRecords.ToArray()

    # Defensive de-dup: deterministic ordering plus Skip-offset paging should never repeat a row
    # across pages, but if the service ever does, one row per agent still holds. Key on `id`,
    # falling back to `name`.
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

    # resultTruncated is true only if we bailed out while a page was still full (-MaxPages or the
    # hard cap, with more likely remaining), or the service reported more records than we actually
    # got back.
    $incomplete = $morePagesLikely -or ($lastTotalRecords -gt 0 -and $data.Count -lt $lastTotalRecords)

    return [PSCustomObject]@{
        totalRecords    = $lastTotalRecords
        count           = $data.Count
        resultTruncated = $incomplete
        skipToken       = $null
        pagesRetrieved  = $page
        data            = $data
    }
}
