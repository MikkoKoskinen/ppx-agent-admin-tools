function Resolve-PPXOwnerIdentity {
    <#
    .SYNOPSIS
        Batch-resolves agent ownerId GUIDs to a display name / UPN / account status via Microsoft
        Graph's directoryObjects/getByIds endpoint.
    .DESCRIPTION
        Feeds OwnerName / OwnerUPN / OwnerAccountStatus in the report schema (§5 of the solution
        description; see PPXAgentGovernanceBaseline.md). Takes the distinct set of `ownerId` GUIDs
        already read off the Inventory API records (`properties.ownerId`) and resolves them in
        batches of up to 1000 -- the documented cap for `POST /v1.0/directoryObjects/getByIds`
        (https://learn.microsoft.com/en-us/graph/api/directoryobject-getbyids) -- rather than one
        Graph call per agent, or the 20-request-per-batch cap of the generic `$batch` endpoint.

        `getByIds` also sidesteps having to know in advance whether an owner is a user or a service
        principal (an agent can be owned by either): `types` is passed as `['user',
        'servicePrincipal']` and the response's `@odata.type` says which one each result is.

        Auth reuses the same delegated Az PowerShell token pattern as Connect-PPXInventoryApi.ps1
        (see that file's header comment and PPXAgentGovernanceBaseline.md §6.3) -- a token for
        https://graph.microsoft.com via Get-AzAccessToken, piggybacking on the already-consented Az
        PowerShell first-party client instead of requiring a separate Microsoft Graph SDK sign-in.
        This assumes the signed-in user/tenant has already consented the scopes that client needs to
        read directory objects (typically true for any account that can also enumerate users in
        Entra); if not, every lookup in the run falls back to OwnerAccountStatus = 'GraphError' and a
        single warning is emitted (not one per agent).

        An id with no matching directory object (deleted user/SP, cross-tenant owner, or a bad guid)
        resolves to OwnerAccountStatus = 'NotFound' with blank name/UPN -- this is itself a leaver/
        orphan signal, so it's a real result, not an error.
    .PARAMETER OwnerId
        One or more ownerId GUIDs (pipeline-friendly). Blanks are skipped and duplicates are
        collapsed automatically, so callers can pipe the raw (possibly blank, possibly repeated)
        per-agent ownerId values straight through without pre-filtering.
    .PARAMETER TenantId
        Forwarded to Connect-AzAccount if a new interactive sign-in is needed.
    .PARAMETER UseDeviceAuthentication
        Forwarded to Connect-AzAccount if a new interactive sign-in is needed.
    .OUTPUTS
        A case-insensitive dictionary keyed by the ownerId GUID (as passed in) -> { OwnerName,
        OwnerUPN, OwnerAccountStatus }. OwnerAccountStatus is one of 'Active', 'Disabled',
        'NotFound', or 'GraphError'. Every id passed in is guaranteed a key in the result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [AllowEmptyString()] [string[]] $OwnerId,

        [string] $TenantId,

        [switch] $UseDeviceAuthentication
    )

    begin {
        $ids = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    process {
        foreach ($id in $OwnerId) {
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if ($seen.Add($id)) { $ids.Add($id) }
        }
    }

    end {
        $lookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($ids.Count -eq 0) { return $lookup }

        # Same delegated-token pattern as Connect-PPXInventoryApi.ps1, but against Graph's resource
        # URL instead of the Power Platform API. Reuses whatever Az context is already active (the
        # entry point has always already signed in for the Inventory API pull by the time this runs).
        $context = Get-AzContext
        if (-not $context -or ($TenantId -and $context.Tenant.Id -ne $TenantId)) {
            $connectParams = @{ ErrorAction = 'Stop' }
            if ($TenantId) { $connectParams['TenantId'] = $TenantId }
            if ($UseDeviceAuthentication) { $connectParams['UseDeviceAuthentication'] = $true }

            Write-Verbose 'No usable Az context; signing in with Connect-AzAccount.'
            $null = Connect-AzAccount @connectParams
        }

        $acquireGraphToken = {
            $tokenResponse = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -ErrorAction Stop
            if ($tokenResponse.Token -is [System.Security.SecureString]) {
                [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
            }
            else {
                $tokenResponse.Token
            }
        }

        $token = $null
        try {
            $token = & $acquireGraphToken
        }
        catch {
            Write-Warning "Could not acquire a Microsoft Graph token ($($_.Exception.Message)) -- owner identities will not be resolved this run. OwnerId (raw GUID) is still populated."
            foreach ($id in $ids) {
                $lookup[$id] = [PSCustomObject]@{ OwnerName = ''; OwnerUPN = ''; OwnerAccountStatus = 'GraphError' }
            }
            return $lookup
        }

        $headers = @{
            Authorization  = "Bearer $token"
            'Content-Type' = 'application/json'
        }
        $uri = 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds'

        # https://learn.microsoft.com/en-us/graph/api/directoryobject-getbyids -- 1000 ids/request max.
        $batchSize = 1000
        # Failed ids are tracked per chunk (not one run-wide flag): a batch that fails must not cause
        # unresolved ids from a *different, successful* batch to be mislabeled GraphError instead of
        # the correct NotFound, which would corrupt the leaver/orphan signal that status feeds.
        $failedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        # A request-level Graph failure is warned about once per run (matching the .DESCRIPTION's "a
        # single warning is emitted"), not once per failed 1000-id batch -- a large tenant with Graph
        # down entirely would otherwise flood the run with a near-duplicate warning per batch.
        $warnedGraphFailure = $false
        for ($i = 0; $i -lt $ids.Count; $i += $batchSize) {
            $chunk = $ids.GetRange($i, [Math]::Min($batchSize, $ids.Count - $i))
            $body = @{ ids = @($chunk); types = @('user', 'servicePrincipal') } | ConvertTo-Json -Depth 5

            $response = $null
            $tokenRefreshed = $false
            while ($true) {
                try {
                    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
                    break
                }
                catch {
                    $status = $null
                    try { $status = [int] $_.Exception.Response.StatusCode } catch { }

                    if ($status -eq 401 -and -not $tokenRefreshed) {
                        $tokenRefreshed = $true
                        try {
                            Write-Verbose 'Graph token expired mid-run; refreshing and retrying once.'
                            $headers['Authorization'] = "Bearer $(& $acquireGraphToken)"
                            continue
                        }
                        catch {
                            if (-not $warnedGraphFailure) {
                                $warnedGraphFailure = $true
                                Write-Warning "Microsoft Graph token refresh failed mid-run ($($_.Exception.Message)) -- treating unresolved owner id(s) from this and any later failing batch as GraphError."
                            }
                            foreach ($failedId in $chunk) { $null = $failedIds.Add($failedId) }
                            break
                        }
                    }

                    if (-not $warnedGraphFailure) {
                        $warnedGraphFailure = $true
                        $detail = $_.ErrorDetails.Message
                        Write-Warning "Microsoft Graph getByIds request failed for a batch of $($chunk.Count) owner id(s) ($($_.Exception.Message)). $detail"
                    }
                    foreach ($failedId in $chunk) { $null = $failedIds.Add($failedId) }
                    break
                }
            }
            if (-not $response) { continue }

            foreach ($obj in @($response.value)) {
                $id = [string] $obj.id
                if ([string]::IsNullOrEmpty($id)) { continue }

                $odataType = [string] $obj.'@odata.type'
                $isServicePrincipal = $odataType -match 'servicePrincipal'
                $accountEnabled = $obj.accountEnabled
                $status =
                    if ($null -eq $accountEnabled) { 'Unknown' }
                    elseif ($accountEnabled) { 'Active' }
                    else { 'Disabled' }

                $lookup[$id] = [PSCustomObject]@{
                    OwnerName          = if ($obj.displayName) { [string] $obj.displayName } else { '' }
                    OwnerUPN           = if ($isServicePrincipal) { '' } else { [string] $obj.userPrincipalName }
                    OwnerAccountStatus = $status
                }
            }
        }

        # Every requested id gets a result: one not returned by getByIds genuinely doesn't resolve to
        # a directory object (deleted, cross-tenant, or a bad guid) -- distinct from a request-level
        # Graph failure, which is tracked per chunk in $failedIds so only ids from a failed batch are
        # labeled GraphError; ids from other, successful batches still get the correct NotFound.
        foreach ($id in $ids) {
            if (-not $lookup.ContainsKey($id)) {
                $lookup[$id] = [PSCustomObject]@{
                    OwnerName          = ''
                    OwnerUPN           = ''
                    OwnerAccountStatus = if ($failedIds.Contains($id)) { 'GraphError' } else { 'NotFound' }
                }
            }
        }

        return $lookup
    }
}
