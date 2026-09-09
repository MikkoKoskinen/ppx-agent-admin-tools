#Requires -Modules Az.Accounts

$script:PPXLicensingApiBaseUri = 'https://api.powerplatform.com/licensing/allocationsByEnvironment'
$script:PPXLicensingApiVersion = '2024-10-01'

function Get-PPXEnvironmentCreditAllocation {
    <#
    .SYNOPSIS
        Reads one environment's Copilot Credit currency allocation and enforcement rules via
        GET /licensing/allocationsByEnvironment/{environmentId}.
    .DESCRIPTION
        Returns the AllocationByEnvironmentModel exactly as the API gives it:

            {
              "environmentId": "...",
              "currencyAllocations": [
                {
                  "currencyType": "MCSMessages",
                  "allocated": 10000,
                  "autoAllocated": 0,
                  "enforcementRules": [
                    { "ruleType": "Alert",      "enabled": true  },
                    { "ruleType": "TenantPool", "enabled": false },
                    { "ruleType": "PayGo",      "enabled": true  },
                    { "ruleType": "Deny",       "enabled": false }
                  ]
                }
              ]
            }

        "Draw from the available capacity in my tenant" is the TenantPool enforcement rule on the
        MCSMessages (Copilot Credits) currency. Resolve-PPXTenantPoolChange consumes this model,
        preserves `allocated` and every non-TenantPool rule, and produces the minimal PATCH body.

        HTTP 404 -> returns $null (the environment has no Copilot Credit allocation surface: not a
        Dataverse environment, or not eligible). HTTP 429 is retried honouring Retry-After. HTTP 401
        triggers one token refresh via -TokenFactory. Every other error is thrown for the caller to
        record per environment -- a sweep over hundreds of environments must not abort because one
        403s or is mid-deletion.
    .PARAMETER EnvironmentId
        Environment GUID (the Inventory API `name` field for an environment record).
    .PARAMETER AccessToken
        Pre-acquired bearer token for https://api.powerplatform.com (see Get-PPXPowerPlatformToken).
    .PARAMETER TokenFactory
        Optional scriptblock returning a fresh bearer token, used to refresh once on HTTP 401.
    .PARAMETER MaxRetries
        Retry attempts on HTTP 429 before giving up. Default 4.
    .OUTPUTS
        The parsed AllocationByEnvironmentModel, or $null on HTTP 404.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentId,

        [Parameter(Mandatory)] [string] $AccessToken,

        [scriptblock] $TokenFactory,

        [int] $MaxRetries = 4
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $tokenRefreshed = $false
    $uri = "$script:PPXLicensingApiBaseUri/$EnvironmentId`?api-version=$script:PPXLicensingApiVersion"

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        }
        catch {
            $status = $null
            try { $status = [int] $_.Exception.Response.StatusCode } catch { }

            if ($status -eq 404) {
                Write-Verbose "No Copilot Credit allocation surface for environment $EnvironmentId (HTTP 404)."
                return $null
            }

            if ($status -eq 429 -and $attempt -le $MaxRetries) {
                $retryAfter = 5
                try {
                    $ra = $_.Exception.Response.Headers['Retry-After']
                    if ($ra) { $retryAfter = [int] $ra }
                }
                catch { }
                Write-Verbose "429 from licensing API for $EnvironmentId; retry $attempt/$MaxRetries after ${retryAfter}s."
                Start-Sleep -Seconds $retryAfter
                continue
            }

            if ($status -eq 401 -and $TokenFactory -and -not $tokenRefreshed) {
                $tokenRefreshed = $true
                Write-Verbose "401 from licensing API for $EnvironmentId; refreshing token and retrying."
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
            throw "Licensing API GET failed for environment $EnvironmentId ($($_.Exception.Message)).`n$detail"
        }
    }
}
