function Export-PPXReport {
    <#
    .SYNOPSIS
        Writes the shaped tenant-pool rows to a CSV, plus a sidecar known-limitations / run-summary
        text file.
    .DESCRIPTION
        Mirrors tools/custom-connector-usage/private/Export-PPXReport.ps1: two files rather than prose
        appended into the CSV (a plain CSV has no comment syntax). The dynamic notes cover the run
        mode (dry run vs apply), the desired value, a per-Action tally, every per-environment error,
        and -- for a dry run -- an explicit "nothing was written" banner.
    .PARAMETER Rows
        Shaped rows from ConvertTo-PPXTenantPoolRow.
    .PARAMETER Mode
        'DryRun' or 'Apply'.
    .PARAMETER DesiredValue
        The requested TenantPool ("Draw from the available capacity in my tenant") value, as a label
        string -- "True" / "False", or a "per-environment ..." note when it came from an input CSV.
    .PARAMETER TargetsSource
        How the target environment list was chosen (-AllEnvironments / -EnvironmentId / -InputCsv <path>).
    .PARAMETER EnvironmentsTargeted
        Count of environments this run targeted.
    .PARAMETER EnvironmentsTotal
        Count of environments in the tenant (from the Inventory list).
    .PARAMETER Errors
        Hashtable environmentId -> error string for environments whose read or write threw.
    .PARAMETER Path
        Folder to auto-name a timestamped CSV into, or a full path ending in .csv. Defaults to the
        repo-root reports\ folder (git-ignored).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [Parameter(Mandatory)] [ValidateSet('DryRun', 'Apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $DesiredValue,
        [string] $TargetsSource,
        [int] $EnvironmentsTargeted,
        [int] $EnvironmentsTotal,
        [hashtable] $Errors,
        [string] $Path
    )

    if (-not $Errors) { $Errors = @{} }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    if ($Path -and $Path.ToLowerInvariant().EndsWith('.csv')) {
        $csvPath = $Path
        $outputFolder = Split-Path -Parent $csvPath
    }
    else {
        $outputFolder = if ($Path) { $Path } else { Join-Path $PSScriptRoot '..\..\..\reports' }
        $csvPath = Join-Path $outputFolder "CopilotCreditTenantPool_$timestamp.csv"
    }

    if ($outputFolder -and -not (Test-Path -Path $outputFolder)) {
        $null = New-Item -ItemType Directory -Path $outputFolder -Force
    }

    $limitationsPath = [System.IO.Path]::ChangeExtension($csvPath, $null).TrimEnd('.') + '.limitations.txt'

    $rows = @($Rows)
    $encoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding $encoding

    $byAction = $rows | Group-Object Action | Sort-Object Name
    $changed  = @($rows | Where-Object { $_.Action -in @('Changed', 'CreatedAllocation') }).Count
    $wouldChange = @($rows | Where-Object { $_.Action -in @('WouldChange', 'WouldCreateAllocation') }).Count
    $locked   = @($rows | Where-Object { $_.Action -eq 'Skipped (locked by policy)' }).Count

    $lines = @(
        'PPX Copilot Credit -- Tenant Pool Draw -- run summary and known limitations'
        "Generated: $(Get-Date -Format 'o')"
        "Mode: $Mode"
        "Desired 'Draw from the available capacity in my tenant' (TenantPool rule on MCSMessages): $DesiredValue"
        $(if ($TargetsSource) { "Targets: $TargetsSource" })
        "Environments targeted: $EnvironmentsTargeted of $EnvironmentsTotal in the tenant."
        ''
        'Outcome tally:'
    )
    foreach ($g in $byAction) { $lines += "  $($g.Name): $($g.Count)" }
    $lines += ''

    if ($Mode -eq 'DryRun') {
        $lines += "*** DRY RUN -- NOTHING WAS WRITTEN. $wouldChange environment(s) would be changed. Re-run the same command with -Apply to make the change. ***"
        $lines += ''
    }
    else {
        $lines += "$changed environment(s) were changed (PATCH accepted); $locked skipped as locked by an environment-group policy; $($Errors.Count) errored."
        $lines += ''
    }

    if ($Errors.Count -gt 0) {
        $lines += "Per-environment errors ($($Errors.Count)) -- these environments were NOT changed:"
        foreach ($k in ($Errors.Keys | Sort-Object)) { $lines += "  - $k : $($Errors[$k])" }
        $lines += ''
    }

    $lines += @(
        'What this tool changes (PPXCopilotCreditTenantPool.md 4):'
        '- ONLY the TenantPool enforcement rule on the MCSMessages (Copilot Credits) currency'
        '  allocation -- i.e. the "Draw from the available capacity in my tenant" checkbox in'
        '  Power Platform admin center > Licensing > Copilot Studio > Manage Copilot Credits.'
        '  TenantPool enabled  = the environment keeps drawing from unallocated tenant capacity after'
        '                        its own allocation is exhausted (or when it has none).'
        '  TenantPool disabled = the environment is capped at its own allocation.'
        '- Every write is read-modify-write: the current allocation is read first, and `allocated`'
        '  plus every other enforcement rule (Alert / PayGo / Deny) are sent back unchanged.'
        '- "CreatedAllocation" rows are environments that had NO MCSMessages allocation at all; the'
        '  only way to persist TenantPool = False there is to write an allocation, so one is created'
        '  with allocated = 0 (no prepaid capacity reserved). Environments left at the default'
        '  (TenantPool = True) with no allocation are reported as NoChange and never written.'
        ''
        'Known limitations:'
        '- Environments governed by a published environment-group rule for this setting cannot be'
        '  changed here (the API returns TenantPoolLockedByPolicy); they show as'
        '  "Skipped (locked by policy)". Change/republish the group rule, or remove the environment'
        '  from the group, then re-run.'
        '- Environments with no Copilot Credit allocation surface (licensing GET returns HTTP 404 --'
        '  not a Dataverse environment, or not eligible for Copilot Credits) show as'
        '  "N/A (no allocation surface)" and are never written.'
        '- Up to ~15 minutes of replication latency: a read taken immediately after a write may still'
        '  show the previous value. The CSV records the intended post-change value, not a re-read.'
        '- Point-in-time: another administrator, or a later environment-group rule publish, can change'
        '  the setting again after this run.'
        '- API: PATCH/GET https://api.powerplatform.com/licensing/allocationsByEnvironment,'
        '  api-version 2024-10-01, currency MCSMessages. The enforcement-rule model is subject to'
        '  change by Microsoft.'
        '- Authentication is interactive delegated (Az PowerShell) only; unattended / service'
        '  principal auth is not supported against this endpoint at time of writing.'
        '- With -AllEnvironments, the target set is the tenant environment list from the Inventory'
        '  API; if that list is flagged INCOMPLETE above (skipToken paging truncated), some'
        '  environments were not visited.'
    )

    $lines -join [System.Environment]::NewLine | Set-Content -Path $limitationsPath -Encoding UTF8

    return [PSCustomObject]@{
        CsvPath         = $csvPath
        LimitationsPath = $limitationsPath
        RowCount        = $rows.Count
        Rows            = $rows
    }
}
