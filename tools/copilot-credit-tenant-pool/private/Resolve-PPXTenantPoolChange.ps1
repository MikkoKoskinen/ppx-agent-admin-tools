function Resolve-PPXTenantPoolChange {
    <#
    .SYNOPSIS
        Pure planner (no network I/O). Given an environment's current AllocationByEnvironmentModel and
        the desired "Draw from the available capacity in my tenant" value, works out the minimal
        change and the exact PATCH body -- preserving allocated credits and every other enforcement
        rule.
    .DESCRIPTION
        "Draw from the available capacity in my tenant" is the TenantPool enforcement rule on the
        MCSMessages (Copilot Credits) currency allocation. This function:

          - locates the MCSMessages entry in currencyAllocations (if any),
          - reads the current TenantPool rule value. When there is no MCSMessages allocation at all,
            or the allocation exists but carries no TenantPool rule, the platform default applies
            (enabled = $true) and is reported as a 'Default (True) ...' label,
          - if the effective current value already equals -DesiredValue and -Force is not set,
            returns Action = 'NoChange' with no body,
          - otherwise returns a PATCH body containing ONLY the MCSMessages currency:
              * `allocated` is carried through unchanged (0 when no allocation existed -- the minimum
                needed to persist an enforcement rule),
              * `enforcementRules` = every existing rule copied verbatim, with the TenantPool rule set
                to -DesiredValue (added if it was absent). Alert / PayGo / Deny and any future rule
                are passed through untouched.

        autoAllocated and any other read-only computed field are deliberately NOT echoed into the
        body -- the write model documents only currencyType / allocated / enforcementRules.
    .PARAMETER CurrentAllocation
        The AllocationByEnvironmentModel from Get-PPXEnvironmentCreditAllocation, or $null when the
        GET returned HTTP 404 (no allocation surface). A 404 is handled by the caller before this
        function; $null here is treated as "no MCSMessages allocation".
    .PARAMETER EnvironmentId
        Environment GUID -- written into the PATCH body.
    .PARAMETER DesiredValue
        $true  = let the environment draw from unallocated tenant capacity after its allocation is
                 exhausted (or when it has none).
        $false = cap the environment at its own allocation.
    .PARAMETER Force
        Emit a PATCH body even when the effective current value already matches -DesiredValue.
    .OUTPUTS
        PSCustomObject: CurrencyType, AllocatedCredits (int or $null), BeforeValue (bool),
        BeforeLabel (string), DesiredValue (bool), AfterValue (bool), OtherRules (string),
        Action ('NoChange' | 'Change' | 'Create'), PatchBody (ordered dictionary or $null).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $CurrentAllocation,

        [Parameter(Mandatory)] [string] $EnvironmentId,

        [Parameter(Mandatory)] [bool] $DesiredValue,

        [switch] $Force
    )

    $currency = 'MCSMessages'
    $ruleType = 'TenantPool'

    $mcs = $null
    if ($null -ne $CurrentAllocation -and $CurrentAllocation.PSObject.Properties.Match('currencyAllocations').Count) {
        $mcs = @($CurrentAllocation.currencyAllocations | Where-Object { "$($_.currencyType)" -eq $currency })[0]
    }

    $allocated = $null
    if ($mcs -and $null -ne $mcs.allocated) { $allocated = [int] $mcs.allocated }

    $existingRules = @()
    if ($mcs -and $mcs.enforcementRules) { $existingRules = @($mcs.enforcementRules) }

    $tpRule = @($existingRules | Where-Object { "$($_.ruleType)" -eq $ruleType })[0]
    $before = if ($tpRule) { [bool] $tpRule.enabled } else { $true }   # platform default when no rule / no config

    $beforeLabel =
        if (-not $mcs)        { 'Default (True) - no MCSMessages allocation configured' }
        elseif (-not $tpRule) { 'Default (True) - no TenantPool rule on the allocation' }
        else                  { "$before" }

    $otherRules = @(
        $existingRules |
            Where-Object { "$($_.ruleType)" -ne $ruleType } |
            ForEach-Object { "$($_.ruleType)=$([bool] $_.enabled)" }
    ) -join '; '

    $needsChange = $Force.IsPresent -or ($before -ne $DesiredValue)

    if (-not $needsChange) {
        return [PSCustomObject]@{
            CurrencyType     = $currency
            AllocatedCredits = $allocated
            BeforeValue      = $before
            BeforeLabel      = $beforeLabel
            DesiredValue     = $DesiredValue
            AfterValue       = $before
            OtherRules       = $otherRules
            Action           = 'NoChange'
            PatchBody        = $null
        }
    }

    # Rebuild enforcementRules: keep every existing rule verbatim, set/add only TenantPool.
    $newRules = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $existingRules) {
        if ("$($r.ruleType)" -eq $ruleType) { continue }
        $newRules.Add([ordered]@{ ruleType = "$($r.ruleType)"; enabled = [bool] $r.enabled })
    }
    $newRules.Add([ordered]@{ ruleType = $ruleType; enabled = $DesiredValue })

    $currencyEntry = [ordered]@{
        currencyType     = $currency
        allocated        = $(if ($null -ne $allocated) { $allocated } else { 0 })
        enforcementRules = $newRules.ToArray()
    }

    $body = [ordered]@{
        environmentId       = $EnvironmentId
        currencyAllocations = @($currencyEntry)
    }

    [PSCustomObject]@{
        CurrencyType     = $currency
        AllocatedCredits = $allocated
        BeforeValue      = $before
        BeforeLabel      = $beforeLabel
        DesiredValue     = $DesiredValue
        AfterValue       = $DesiredValue
        OtherRules       = $otherRules
        Action           = $(if ($mcs) { 'Change' } else { 'Create' })
        PatchBody        = $body
    }
}
