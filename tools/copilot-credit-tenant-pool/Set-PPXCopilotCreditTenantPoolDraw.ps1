function Set-PPXCopilotCreditTenantPoolDraw {
    <#
    .SYNOPSIS
        Sets the Copilot Credit "Draw from the available capacity in my tenant" option (the TenantPool
        enforcement rule on the MCSMessages currency allocation) to $true or $false for all or
        selected Power Platform environments. Dry run by default; -Apply writes.
    .DESCRIPTION
        Third tool in the PPX collection and the first that writes. Same shape and approach as the
        other tools: delegated Az token -> Power Platform API -> shape -> CSV plus a .limitations.txt
        sidecar. See PPXCopilotCreditTenantPool.md (repo root) for the full design.

        Per environment:
          1. GET  https://api.powerplatform.com/licensing/allocationsByEnvironment/{id}
             -- the current MCSMessages allocation + enforcement rules.
          2. Resolve the minimal change: flip ONLY the TenantPool rule to -DrawFromTenantCapacity,
             carrying `allocated` and every other rule (Alert / PayGo / Deny) through unchanged. If
             the environment is already at the desired value, it is left alone (unless -Force).
          3. If -Apply: PATCH https://api.powerplatform.com/licensing/allocationsByEnvironment with
             that read-modify-write body. Without -Apply nothing is written -- the run is a dry run
             that still produces the full before/after report.

        An environment governed by a published environment-group rule for this setting cannot be
        changed (the API returns TenantPoolLockedByPolicy); it is recorded as
        "Skipped (locked by policy)" and the run continues. An environment with no allocation surface
        (HTTP 404) is recorded as "N/A (no allocation surface)" and never written.

        Runtime values default from the shared settings file (ppx.settings.psd1, section
        'CopilotCreditTenantPool', falling back to 'Common'); an explicit parameter overrides the
        file. The change intent -- -DrawFromTenantCapacity, -EnvironmentId / -AllEnvironments /
        -InputCsv, -Apply -- is never taken from the settings file.

        Review-then-apply workflow: run once as a dry run (e.g. -AllEnvironments) to get the
        CopilotCreditTenantPool_<timestamp>.csv, delete every row you do NOT want changed (in Excel
        or any editor), then feed that trimmed file back with -InputCsv <file> -Apply. Only the
        environments still listed are touched. If you also want different values per environment,
        edit the DesiredValue column (TRUE / FALSE) and omit -DrawFromTenantCapacity.
    .PARAMETER DrawFromTenantCapacity
        The value to set. $true = the environment keeps drawing from unallocated tenant capacity
        after its own allocation is exhausted (or when it has none). $false = the environment is
        capped at its own allocation.

        Required UNLESS -InputCsv is given and every row in that file has a DesiredValue cell. When
        both are supplied, this parameter wins and is applied to every listed environment.
    .PARAMETER EnvironmentId
        One or more environment GUIDs to change. Exactly one of -EnvironmentId / -AllEnvironments /
        -InputCsv must be given -- this tool never changes every environment implicitly.
    .PARAMETER AllEnvironments
        Target every environment in the tenant (from the Inventory API environment list).
    .PARAMETER InputCsv
        Path to a CSV whose 'EnvironmentId' column lists the environments to target -- typically a
        dry-run report (CopilotCreditTenantPool_<timestamp>.csv) trimmed to just the rows you want
        applied. Any other columns are ignored except an optional 'DesiredValue' column (TRUE /
        FALSE), which is used as the per-environment target value when -DrawFromTenantCapacity is
        omitted. Blank EnvironmentId rows are skipped; duplicates are de-duplicated (first wins).
        Mutually exclusive with -EnvironmentId / -AllEnvironments.
    .PARAMETER Apply
        Actually write the change. Without it the run is a DRY RUN: every environment is read and the
        report is produced with WouldChange / WouldCreateAllocation / NoChange actions, but nothing
        is PATCHed.
    .PARAMETER Force
        Also PATCH environments already at the desired value (re-assert it). Default: such
        environments are reported as NoChange and skipped.
    .PARAMETER TenantId
        Entra tenant ID. Required -- here, or Common.TenantId / CopilotCreditTenantPool.TenantId in
        ppx.settings.psd1. No tenant is ever baked into the repo.
    .PARAMETER Top
        Inventory API page size for the environment list (rows per request, 1-1000). Does not cap the
        total -- skipToken paging retrieves everything. Only relevant with -AllEnvironments.
    .PARAMETER MaxPages
        Cap on Inventory API pages for the environment list. 0 (default) = retrieve everything. A
        small value gives a quick partial pull while testing; the environment list is then flagged
        INCOMPLETE.
    .PARAMETER UseDeviceAuthentication
        Device-code sign-in instead of the interactive browser prompt (needed under the VS Code
        debugger).
    .PARAMETER OutputPath
        Folder to auto-name a timestamped CSV into, or a full path ending in .csv. Defaults to the
        settings file, then the repo-root reports\ folder (git-ignored).
    .PARAMETER ExportReport
        Whether to write the CSV + sidecar. Defaults to $true; $false returns the rows in memory only.
    .EXAMPLE
        Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments
        DRY RUN across every environment: reports which environments would have tenant-pool draw
        turned off. Nothing is written.
    .EXAMPLE
        Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments -Apply
        Turns OFF "Draw from the available capacity in my tenant" for every environment in the tenant.
    .EXAMPLE
        Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $true -EnvironmentId 11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222 -Apply
        Turns the option back ON for two named environments.
    .EXAMPLE
        Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments -Apply -Confirm
        Same as the tenant-wide apply, but prompts for confirmation per environment.
    .EXAMPLE
        # 1. dry run -> review -> trim the CSV to the rows you want, then:
        Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -InputCsv .\reports\CopilotCreditTenantPool_20260909-140000.csv -Apply
        Applies the change only to the environments still listed in the (edited) dry-run report.
    .EXAMPLE
        Set-PPXCopilotCreditTenantPoolDraw -InputCsv .\targets.csv -Apply
        Per-environment values taken from each row's DesiredValue column (TRUE / FALSE).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [bool] $DrawFromTenantCapacity,

        [string[]] $EnvironmentId,

        [switch] $AllEnvironments,

        [string] $InputCsv,

        [switch] $Apply,

        [switch] $Force,

        [string] $TenantId,

        [int] $Top,

        [int] $MaxPages,

        [switch] $UseDeviceAuthentication,

        [string] $OutputPath,

        [bool] $ExportReport = $true
    )

    . (Join-Path $PSScriptRoot '..\_shared\Get-PPXSettings.ps1')

    $privatePath = Join-Path $PSScriptRoot 'private'
    Get-ChildItem -Path $privatePath -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    # Fall back to the shared settings file for any parameter not passed explicitly.
    $settings = Get-PPXSettings -Section 'CopilotCreditTenantPool'
    if (-not $PSBoundParameters.ContainsKey('TenantId') -and $settings.TenantId) { $TenantId = $settings.TenantId }
    if (-not $PSBoundParameters.ContainsKey('Top') -and $settings.Top) { $Top = $settings.Top }
    if (-not $PSBoundParameters.ContainsKey('MaxPages') -and $settings.MaxPages) { $MaxPages = $settings.MaxPages }
    if (-not $PSBoundParameters.ContainsKey('UseDeviceAuthentication') -and $settings.UseDeviceAuthentication) {
        $UseDeviceAuthentication = [bool] $settings.UseDeviceAuthentication
    }
    if (-not $PSBoundParameters.ContainsKey('OutputPath') -and $settings.OutputPath) { $OutputPath = $settings.OutputPath }
    # ExportReport defaults to $true, so an explicit $false in settings must win over that default.
    if (-not $PSBoundParameters.ContainsKey('ExportReport') -and $settings.ContainsKey('ExportReport')) {
        $ExportReport = [bool] $settings.ExportReport
    }

    # --- target selection guard ---------------------------------------------------------------
    $targetModes = @()
    if ($AllEnvironments)          { $targetModes += '-AllEnvironments' }
    if ($EnvironmentId)            { $targetModes += '-EnvironmentId' }
    if ($PSBoundParameters.ContainsKey('InputCsv') -and $InputCsv) { $targetModes += '-InputCsv' }

    if ($targetModes.Count -gt 1) {
        throw "Specify exactly one of -EnvironmentId, -AllEnvironments, or -InputCsv (got: $($targetModes -join ', '))."
    }
    if ($targetModes.Count -eq 0) {
        throw @'
No target environments. This tool never changes every environment implicitly -- choose one:

  -EnvironmentId <guid>[,<guid>...]   change only the listed environment(s)
  -AllEnvironments                    change every environment in the tenant
  -InputCsv <path>                    change only the environments listed in a CSV
                                      (e.g. a dry-run report trimmed to the rows you want)

Add -Apply to actually write. Without -Apply the run is a DRY RUN (reads + report only).
'@
    }

    # -DrawFromTenantCapacity is required unless -InputCsv supplies a per-row DesiredValue for
    # every target (validated below, after the CSV is read).
    $desiredBound = $PSBoundParameters.ContainsKey('DrawFromTenantCapacity')
    if (-not $desiredBound -and $targetModes -notcontains '-InputCsv') {
        throw 'Specify -DrawFromTenantCapacity $true or $false (only optional when -InputCsv provides a DesiredValue column for every row).'
    }

    if (-not $TenantId) {
        throw @'
No tenant ID configured. This tool never ships with a tenant baked in -- set your own:

  1. Copy  ppx.settings.example.psd1  to  ppx.settings.psd1  (repo root; git-ignored), then
     set  Common.TenantId  to your Entra tenant ID.
  -- or --
  2. Pass it explicitly:  Set-PPXCopilotCreditTenantPoolDraw ... -TenantId <guid>
'@
    }

    $mode = if ($Apply) { 'Apply' } else { 'DryRun' }

    # Per-environment desired value. When -DrawFromTenantCapacity is bound it applies to every
    # target; otherwise each value comes from the input CSV's DesiredValue column ($perRowDesired,
    # populated below).
    $perRowDesired = @{}
    $desiredLabel  = if ($desiredBound) { "$([bool] $DrawFromTenantCapacity)" } else { "per-environment (input CSV 'DesiredValue' column)" }

    Write-Host ("Mode: {0}. Desired 'Draw from the available capacity in my tenant' (MCSMessages TenantPool rule): {1}." -f $mode, $desiredLabel)
    if (-not $Apply) {
        Write-Warning 'DRY RUN -- no changes will be written. Re-run the same command with -Apply to make changes.'
    }

    # One delegated token for every call below; the factory is passed down so a long multi-environment
    # run can refresh on a 401. It must stay a plain scriptblock (NOT .GetNewClosure()) so it can
    # still see the dot-sourced Get-PPXPowerPlatformToken; $TenantId / $UseDeviceAuthentication
    # resolve by dynamic scope when it is invoked from a sub-function of this one.
    $tokenFactory = { Get-PPXPowerPlatformToken -TenantId $TenantId -UseDeviceAuthentication:$UseDeviceAuthentication }
    $token = & $tokenFactory

    # --- environment list (Inventory API) -- names/detail + the -AllEnvironments target set ---
    $paging = @{}
    if ($Top) { $paging['Top'] = $Top }
    if ($MaxPages) { $paging['MaxPages'] = $MaxPages }

    Write-Host '..listing environments (Inventory API).'
    $orderby = [ordered]@{ '$type' = 'orderby'; FieldNamesAscDesc = [ordered]@{ 'tostring(properties.createdAt)' = 'desc'; 'name' = 'asc' } }
    $envClauses = @(
        [ordered]@{ '$type' = 'where'; FieldName = 'type'; Operator = '=='; Values = @("'microsoft.powerplatform/environments'") }
        $orderby
    )
    $envInventory = Connect-PPXInventoryApi -Clauses $envClauses -AccessToken $token -TokenFactory $tokenFactory @paging
    $environments = @($envInventory.data)
    Write-Host "  $($environments.Count) environment(s) in tenant."

    $detailById = @{}
    foreach ($e in $environments) {
        $id = [string] (Get-PPXNestedValue $e 'name' -Default '')
        if ($id) { $detailById[$id] = $e }
    }

    # --- resolve the target list -----------------------------------------------------------------
    $targetsSource = ''
    if ($AllEnvironments) {
        $targets = @($detailById.Keys)
        $targetsSource = '-AllEnvironments (tenant inventory)'
        if ($envInventory.resultTruncated) {
            Write-Warning 'Environment list is INCOMPLETE (Inventory paging truncated). Some environments will be missed. Re-run without -MaxPages.'
        }
    }
    elseif ($targetModes -contains '-InputCsv') {
        if (-not (Test-Path -LiteralPath $InputCsv)) { throw "Input CSV not found: $InputCsv" }
        $csvTargets = @(Import-PPXTargetCsv -Path $InputCsv)
        $targets = @($csvTargets | ForEach-Object { $_.EnvironmentId })
        foreach ($ct in $csvTargets) {
            if ($null -ne $ct.DesiredValue) { $perRowDesired[$ct.EnvironmentId] = [bool] $ct.DesiredValue }
        }
        $targetsSource = "-InputCsv $InputCsv"
        Write-Host "  $($targets.Count) environment(s) listed in $InputCsv$(if ($perRowDesired.Count) { "; $($perRowDesired.Count) with a per-row DesiredValue" })."
        foreach ($t in $targets) {
            if (-not $detailById.ContainsKey($t)) {
                Write-Warning "Environment $t (from CSV) not found in the tenant inventory; the licensing call will still be attempted."
            }
        }
    }
    else {
        $targets = @($EnvironmentId | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $targetsSource = '-EnvironmentId'
        foreach ($t in $targets) {
            if (-not $detailById.ContainsKey($t)) {
                Write-Warning "Environment $t not found in the tenant inventory; the licensing call will still be attempted."
            }
        }
    }

    # Now that any CSV is read, finish the "desired value is required" check.
    if (-not $desiredBound) {
        $missingDesired = @($targets | Where-Object { -not $perRowDesired.ContainsKey($_) })
        if ($missingDesired.Count -gt 0) {
            throw ("-DrawFromTenantCapacity was not given and the input CSV has no usable DesiredValue (TRUE/FALSE) for {0} of {1} environment(s), e.g. {2}. Add -DrawFromTenantCapacity `$true|`$false, or fill the DesiredValue column for every row." -f `
                $missingDesired.Count, $targets.Count, ($missingDesired | Select-Object -First 3) -join ', ')
        }
    }

    Write-Host "..$($targets.Count) target environment(s); $mode."
    if ($targets.Count -eq 0) {
        Write-Warning 'No target environments resolved. Nothing to do.'
        return @()
    }

    # --- per-environment: read -> plan -> (apply) ---------------------------------------------
    $rows   = [System.Collections.Generic.List[object]]::new()
    $errors = @{}
    $i = 0
    foreach ($envId in $targets) {
        $i++
        $detail  = if ($detailById.ContainsKey($envId)) { $detailById[$envId] } else { $null }
        $envName = [string] (Get-PPXNestedValue $detail 'properties.displayName' -Default $envId)
        $rowDesired = if ($desiredBound) { [bool] $DrawFromTenantCapacity } else { [bool] $perRowDesired[$envId] }
        Write-Progress -Activity "Copilot Credit tenant-pool draw ($mode)" -Status "$i / $($targets.Count) : $envName" -PercentComplete (($i / [Math]::Max($targets.Count, 1)) * 100)

        try {
            $current = Get-PPXEnvironmentCreditAllocation -EnvironmentId $envId -AccessToken $token -TokenFactory $tokenFactory
        }
        catch {
            $errors[$envId] = $_.Exception.Message
            $rows.Add((ConvertTo-PPXTenantPoolRow -EnvironmentId $envId -EnvironmentDetail $detail -Plan $null `
                        -Action 'Error (read)' -Detail $_.Exception.Message -Mode $mode -DesiredValue $rowDesired))
            Write-Warning "  $envName : read failed -- $($_.Exception.Message)"
            continue
        }

        if ($null -eq $current) {
            $rows.Add((ConvertTo-PPXTenantPoolRow -EnvironmentId $envId -EnvironmentDetail $detail -Plan $null `
                        -Action 'N/A (no allocation surface)' `
                        -Detail 'Licensing GET returned HTTP 404 -- no Copilot Credit allocation surface for this environment.' `
                        -Mode $mode -DesiredValue $rowDesired))
            continue
        }

        $plan = Resolve-PPXTenantPoolChange -CurrentAllocation $current -EnvironmentId $envId -DesiredValue $rowDesired -Force:$Force

        if ($plan.Action -eq 'NoChange') {
            $rows.Add((ConvertTo-PPXTenantPoolRow -EnvironmentId $envId -EnvironmentDetail $detail -Plan $plan `
                        -Action 'NoChange' -Detail 'Already at the desired value.' -Mode $mode -DesiredValue $rowDesired))
            continue
        }

        if (-not $Apply) {
            $would = if ($plan.Action -eq 'Create') { 'WouldCreateAllocation' } else { 'WouldChange' }
            $note  = if ($plan.Action -eq 'Create') {
                "No MCSMessages allocation exists; -Apply would create one with allocated=0 and TenantPool=$rowDesired."
            } else { '' }
            $rows.Add((ConvertTo-PPXTenantPoolRow -EnvironmentId $envId -EnvironmentDetail $detail -Plan $plan `
                        -Action $would -Detail $note -Mode $mode -DesiredValue $rowDesired))
            continue
        }

        $target = "environment '$envName' ($envId): 'Draw from tenant capacity' $($plan.BeforeValue) -> $rowDesired (allocated + Alert/PayGo/Deny unchanged)"
        if (-not $PSCmdlet.ShouldProcess($target, 'PATCH licensing/allocationsByEnvironment')) {
            $rows.Add((ConvertTo-PPXTenantPoolRow -EnvironmentId $envId -EnvironmentDetail $detail -Plan $plan `
                        -Action 'Skipped (declined)' -Detail '-WhatIf / declined at the confirmation prompt.' `
                        -Mode $mode -DesiredValue $rowDesired))
            continue
        }

        try {
            $null = Set-PPXEnvironmentCreditAllocation -Body $plan.PatchBody -AccessToken $token -TokenFactory $tokenFactory
            $done = if ($plan.Action -eq 'Create') { 'CreatedAllocation' } else { 'Changed' }
            $rows.Add((ConvertTo-PPXTenantPoolRow -EnvironmentId $envId -EnvironmentDetail $detail -Plan $plan `
                        -Action $done -Detail '' -Mode $mode -DesiredValue $rowDesired))
            Write-Host "  $envName : $done -- TenantPool=$rowDesired"
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -like 'LOCKED_BY_POLICY:*') {
                $rows.Add((ConvertTo-PPXTenantPoolRow -EnvironmentId $envId -EnvironmentDetail $detail -Plan $plan `
                            -Action 'Skipped (locked by policy)' -Detail $msg -Mode $mode -DesiredValue $rowDesired))
                Write-Warning "  $envName : locked by an environment-group policy -- skipped."
            }
            else {
                $errors[$envId] = $msg
                $rows.Add((ConvertTo-PPXTenantPoolRow -EnvironmentId $envId -EnvironmentDetail $detail -Plan $plan `
                            -Action 'Error (write)' -Detail $msg -Mode $mode -DesiredValue $rowDesired))
                Write-Warning "  $envName : write failed -- $msg"
            }
        }
    }
    Write-Progress -Activity "Copilot Credit tenant-pool draw ($mode)" -Completed

    $rowArray = $rows.ToArray()
    $summary  = $rowArray | Group-Object Action | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host ("Done. {0} row(s): {1}" -f $rowArray.Count, ($summary -join ', '))

    if ($ExportReport) {
        $exportParams = @{
            Rows                 = $rowArray
            Mode                 = $mode
            DesiredValue         = $desiredLabel
            TargetsSource        = $targetsSource
            EnvironmentsTargeted = $targets.Count
            EnvironmentsTotal    = $environments.Count
            Errors               = $errors
        }
        if ($OutputPath) { $exportParams['Path'] = $OutputPath }

        $result = Export-PPXReport @exportParams
        Write-Host "Report: $($result.CsvPath) ($($result.RowCount) row(s))."
        Write-Host "Run summary + known limitations: $($result.LimitationsPath)"
        if (-not $Apply) { Write-Warning 'This was a DRY RUN. Re-run with -Apply to write the changes listed as WouldChange / WouldCreateAllocation.' }
        return $result.Rows
    }

    Write-Host "ExportReport is `$false -- nothing written to disk. Returning $($rowArray.Count) row(s)."
    return $rowArray
}
