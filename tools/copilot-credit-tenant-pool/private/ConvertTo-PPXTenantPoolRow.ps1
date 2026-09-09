function ConvertTo-PPXTenantPoolRow {
    <#
    .SYNOPSIS
        Shapes one flat report row per (environment) from the environment detail record, the
        Resolve-PPXTenantPoolChange plan, and the run outcome.
    .DESCRIPTION
        See PPXCopilotCreditTenantPool.md 5 for the schema. One row per target environment. The
        `TenantPoolDraw_Before` / `TenantPoolDraw_After` pair plus `OtherEnforcementRules` make the
        change (and the fact that nothing else moved) auditable straight from the CSV.
    .PARAMETER EnvironmentId
        Environment GUID.
    .PARAMETER EnvironmentDetail
        The environment's Inventory record ($null if it was not found in the tenant inventory).
    .PARAMETER Plan
        The PSCustomObject from Resolve-PPXTenantPoolChange, or $null when the row is a read/lookup
        failure or an environment with no allocation surface.
    .PARAMETER Action
        The final per-environment outcome string (NoChange / WouldChange / WouldCreateAllocation /
        Changed / CreatedAllocation / Skipped (locked by policy) / Skipped (declined) /
        N/A (no allocation surface) / Error (read) / Error (write)).
    .PARAMETER Detail
        Free-text note (error message, policy note, ...). May be empty.
    .PARAMETER Mode
        'DryRun' or 'Apply'.
    .PARAMETER DesiredValue
        The requested TenantPool value for this run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentId,

        [AllowNull()] $EnvironmentDetail,

        [AllowNull()] $Plan,

        [Parameter(Mandatory)] [string] $Action,

        [string] $Detail = '',

        [Parameter(Mandatory)] [ValidateSet('DryRun', 'Apply')] [string] $Mode,

        [Parameter(Mandatory)] [bool] $DesiredValue
    )

    [PSCustomObject][ordered]@{
        EnvironmentName        = [string] (Get-PPXNestedValue $EnvironmentDetail 'properties.displayName' -Default '')
        EnvironmentId          = $EnvironmentId
        EnvironmentType        = [string] (Get-PPXNestedValue $EnvironmentDetail 'properties.environmentType' -Default '')
        IsManagedEnvironment   = Get-PPXNestedValue $EnvironmentDetail 'properties.isManaged' -Default ''
        EnvironmentGroup       = [string] (Get-PPXNestedValue $EnvironmentDetail 'properties.environmentGroup' -Default '')
        EnvironmentGroupId     = [string] (Get-PPXNestedValue $EnvironmentDetail 'properties.environmentGroupId' -Default '')
        CurrencyType           = if ($Plan) { $Plan.CurrencyType } else { 'MCSMessages' }
        AllocatedCredits       = if ($Plan -and $null -ne $Plan.AllocatedCredits) { $Plan.AllocatedCredits } else { '' }
        TenantPoolDraw_Before  = if ($Plan) { $Plan.BeforeLabel } else { '' }
        DesiredValue           = $DesiredValue
        TenantPoolDraw_After   = if ($Plan) { "$($Plan.AfterValue)" } else { '' }
        OtherEnforcementRules  = if ($Plan) { $Plan.OtherRules } else { '' }
        Action                 = $Action
        Mode                   = $Mode
        Detail                 = $Detail
    }
}
