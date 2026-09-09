#Requires -Modules Az.Accounts

$script:PPXLicensingPatchUri        = 'https://api.powerplatform.com/licensing/allocationsByEnvironment'
$script:PPXLicensingPatchApiVersion = '2024-10-01'

function Set-PPXEnvironmentCreditAllocation {
    <#
    .SYNOPSIS
        Writes one environment's currency allocation via PATCH /licensing/allocationsByEnvironment.
    .DESCRIPTION
        The caller passes the exact body built by Resolve-PPXTenantPoolChange -- which contains ONLY
        the MCSMessages currency, with `allocated` carried through unchanged and `enforcementRules`
        equal to the environment's existing rules with just the TenantPool rule flipped to the
        desired value. Nothing else about the environment's licensing is touched.

        PATCH replaces the currency allocation it is given, so the body must already be complete for
        that currency (read-modify-write). This function does no shaping; it only transports the body.

        HTTP 429 is retried honouring Retry-After. HTTP 401 triggers one token refresh via
        -TokenFactory. A response carrying the `TenantPoolLockedByPolicy` error code (a published
        environment-group rule governs this setting) is re-thrown as a distinct terminating error
        whose message starts 'LOCKED_BY_POLICY:' so the caller can classify it as a skip rather than
        a failure. Every other error is thrown verbatim.
    .PARAMETER Body
        The PATCH request body (ordered dictionary / hashtable) from Resolve-PPXTenantPoolChange.
    .PARAMETER AccessToken
        Bearer token for https://api.powerplatform.com (see Get-PPXPowerPlatformToken).
    .PARAMETER TokenFactory
        Optional scriptblock returning a fresh bearer token, used to refresh once on HTTP 401.
    .PARAMETER MaxRetries
        Retry attempts on HTTP 429 before giving up. Default 4.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Body,

        [Parameter(Mandatory)] [string] $AccessToken,

        [scriptblock] $TokenFactory,

        [int] $MaxRetries = 4
    )

    $headers = @{
        Authorization  = "Bearer $AccessToken"
        'Content-Type' = 'application/json'
    }
    $tokenRefreshed = $false
    $uri  = "${script:PPXLicensingPatchUri}?api-version=${script:PPXLicensingPatchApiVersion}"
    $json = $Body | ConvertTo-Json -Depth 10

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod -Uri $uri -Method Patch -Headers $headers -Body $json -ContentType 'application/json' -ErrorAction Stop
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
                Write-Verbose "429 from licensing PATCH; retry $attempt/$MaxRetries after ${retryAfter}s."
                Start-Sleep -Seconds $retryAfter
                continue
            }

            if ($status -eq 401 -and $TokenFactory -and -not $tokenRefreshed) {
                $tokenRefreshed = $true
                Write-Verbose '401 from licensing PATCH; refreshing token and retrying.'
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

            if ("$detail" -match 'TenantPoolLockedByPolicy') {
                throw "LOCKED_BY_POLICY: a published environment-group rule governs 'Draw from the available capacity in my tenant' for this environment. Change and republish the group rule, or remove the environment from the group, then retry. ($detail)"
            }
            throw "Licensing API PATCH failed ($($_.Exception.Message)).`n$detail"
        }
    }
}
