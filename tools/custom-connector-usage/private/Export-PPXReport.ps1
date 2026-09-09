function Export-PPXReport {
    <#
    .SYNOPSIS
        Writes the shaped connector-usage rows to a CSV, plus a sidecar known-limitations text file.
    .DESCRIPTION
        Mirrors tools/agent-governance-baseline/private/Export-PPXReport.ps1: two files rather than
        prose appended into the CSV (a plain CSV has no comment syntax). The dynamic notes cover
        Inventory paging completeness, how many environments the connectivity lookup actually
        covered, and every per-environment lookup error.
    .PARAMETER EnvironmentInventory
        Envelope from the environments Inventory query.
    .PARAMETER UsageInventory
        Envelope from the connector-usage Inventory query.
    .PARAMETER Rows
        Shaped rows from ConvertTo-PPXConnectorUsageRow.
    .PARAMETER EnvironmentErrors
        Hashtable environmentId -> error string for environments whose connectivity lookup failed.
    .PARAMETER EnvironmentsScanned
        Count of environments the connectivity lookup succeeded for.
    .PARAMETER EnvironmentsTotal
        Count of environments in the tenant.
    .PARAMETER SkipLookup
        Whether the connectivity lookup was skipped entirely.
    .PARAMETER IncludeAllEnvironments
        Whether clean environments got a placeholder row.
    .PARAMETER Path
        Folder to auto-name a timestamped CSV into, or a full path ending in .csv. Defaults to the
        repo-root reports\ folder (git-ignored).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $EnvironmentInventory,
        [Parameter(Mandatory)] $UsageInventory,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [hashtable] $EnvironmentErrors,
        [int] $EnvironmentsScanned,
        [int] $EnvironmentsTargeted,
        [int] $EnvironmentsTotal,
        [bool] $SkipLookup,
        [bool] $IncludeAllEnvironments,
        [string] $Path
    )

    if (-not $EnvironmentErrors) { $EnvironmentErrors = @{} }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    if ($Path -and $Path.ToLowerInvariant().EndsWith('.csv')) {
        $csvPath = $Path
        $outputFolder = Split-Path -Parent $csvPath
    }
    else {
        $outputFolder = if ($Path) { $Path } else { Join-Path $PSScriptRoot '..\..\..\reports' }
        $csvPath = Join-Path $outputFolder "CustomConnectorUsage_$timestamp.csv"
    }

    if ($outputFolder -and -not (Test-Path -Path $outputFolder)) {
        $null = New-Item -ItemType Directory -Path $outputFolder -Force
    }

    $limitationsPath = [System.IO.Path]::ChangeExtension($csvPath, $null).TrimEnd('.') + '.limitations.txt'

    $rows = @($Rows)
    $encoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding $encoding

    $connectorRows = @($rows | Where-Object { $_.ConnectorId })
    $envWithCustom = @($connectorRows.EnvironmentId | Sort-Object -Unique)
    $inferredRows  = @($connectorRows | Where-Object { $_.IsCustomApi -eq 'Inferred' })

    $lines = @(
        'PPX Custom Connector Usage -- known limitations for this report'
        "Generated: $(Get-Date -Format 'o')"
        "Rows: $($rows.Count) total; $($connectorRows.Count) custom-connector row(s) across $($envWithCustom.Count) environment(s)."
        "Environments in tenant: $EnvironmentsTotal."
    )
    if ($SkipLookup) {
        $lines += 'Per-environment connector lookup: SKIPPED (-SkipEnvironmentConnectorLookup). Every row is from the Inventory usage heuristic only -- created-but-unreferenced custom connectors are NOT in this report, IsCustomApi is "Inferred", ExistsInEnvironmentList is "Unknown".'
    }
    else {
        $lines += "Per-environment connector lookup (connectivity API): succeeded for $EnvironmentsScanned of $EnvironmentsTotal environment(s); $($EnvironmentErrors.Count) failed."
        if ($EnvironmentsTargeted -gt 0 -and $EnvironmentsTargeted -lt $EnvironmentsTotal) {
            $lines += "*** Environment coverage PARTIAL: only $EnvironmentsTargeted of $EnvironmentsTotal environment(s) were scanned for connectors (-MaxEnvironments). Created-but-unreferenced custom connectors in the other $($EnvironmentsTotal - $EnvironmentsTargeted) environment(s) are NOT in this report. Re-run with -MaxEnvironments 0 for full coverage. ***"
        }
    }
    $lines += "Connector-emitting resources scanned: $($UsageInventory.count) of $($UsageInventory.totalRecords)."
    $lines += "Inventory API pages retrieved: environments $($EnvironmentInventory.pagesRetrieved), resources $($UsageInventory.pagesRetrieved)."
    $lines += if ($IncludeAllEnvironments) { 'Scope: -IncludeAllEnvironments -- clean environments get a placeholder row (blank ConnectorId).' }
              else { 'Scope: only environments with >= 1 custom connector produce rows.' }
    $lines += ''

    if ($EnvironmentInventory.resultTruncated -or $UsageInventory.resultTruncated) {
        $lines += '*** An Inventory API result is INCOMPLETE (resultTruncated = true) -- most likely -MaxPages capped the run. Re-run without it. ***'
        $lines += ''
    }

    if ($EnvironmentErrors.Count -gt 0) {
        $lines += "Per-environment connector-lookup failures ($($EnvironmentErrors.Count)) -- ExistsInEnvironmentList is 'Unknown (lookup failed)' for these, and a created-but-unreferenced custom connector in one of them is missing entirely:"
        foreach ($k in ($EnvironmentErrors.Keys | Sort-Object)) { $lines += "  - $k : $($EnvironmentErrors[$k])" }
        $lines += ''
    }

    $lines += @(
        'Documented limitations (PPXCustomConnectorUsage.md 8):'
        '- "Custom" is authoritative (properties.isCustomApi) ONLY for rows with IsCustomApi = "True",'
        '  which come from the per-environment connectivity API call. Rows with IsCustomApi ='
        '  "Inferred" come from the Inventory usage heuristic (Test-PPXCustomConnectorId, an ID-shape'
        '  guess) and appear only when the connectivity call for that environment was skipped or'
        '  failed.'
        '- IsReferencedByResource / ConsumingResources come from properties.powerPlatformConnectors,'
        '  emitted only by canvas apps, model-driven apps, cloud flows, agent flows, workflow agent'
        '  flows, and Copilot Studio agents. A custom connector used ONLY by a code app, vibe app, or'
        '  App Builder app shows IsReferencedByResource = False even though it is in use.'
        '- Built-in actions (HTTP, Control, Data Operations) are not connectors and never appear.'
        '- Matching a referenced connector to an environment connector is done on a normalised base'
        '  name (Get-PPXNormalizedConnectorKey) because the two APIs format the suffix differently.'
        '  Two different custom connectors whose base names collide within one environment would be'
        '  merged into one row.'
        '- "In use" here means referenced by a resource definition and/or present in the environment'
        '  -- not that a connection exists, is authorised, or has run recently.'
        '- ConnectorTier / publisher come from the connectivity API and are blank on "Inferred" rows.'
        '- Up to ~15 minutes of replication latency on the Inventory data.'
        '- powerPlatformConnectors is Microsoft Preview status and may change shape without notice.'
        '- Authentication is interactive delegated only; unattended auth is not supported.'
    )

    if ($connectorRows.Count -eq 0) {
        $lines += ''
        $lines += 'NOTE: no custom connectors found. If the connectivity lookup ran clean, no environment has one. If lookups failed above, re-run; or try -IncludeAllEnvironments to confirm which environments were checked.'
    }
    elseif ($inferredRows.Count -eq $connectorRows.Count -and -not $SkipLookup `
            -and $EnvironmentErrors.Count -eq 0 `
            -and ($EnvironmentsTargeted -le 0 -or $EnvironmentsTargeted -ge $EnvironmentsTotal)) {
        $lines += ''
        $lines += 'NOTE: every custom-connector row is "Inferred" even though the connectivity lookup ran clean across every environment -- it returned no isCustomApi connectors anywhere. Confirm the $filter contract and the isCustomApi field in Get-PPXEnvironmentConnector.ps1 against a live tenant if you expected authoritative rows.'
    }
    elseif ($inferredRows.Count -gt 0 -and -not $SkipLookup) {
        $lines += ''
        $lines += "NOTE: $($inferredRows.Count) of $($connectorRows.Count) custom-connector row(s) are `"Inferred`" -- from environments whose connectivity lookup was skipped (-MaxEnvironments) or failed. Re-run with full coverage to make them authoritative."
    }

    $lines -join [System.Environment]::NewLine | Set-Content -Path $limitationsPath -Encoding UTF8

    return [PSCustomObject]@{
        CsvPath         = $csvPath
        LimitationsPath = $limitationsPath
        RowCount        = $rows.Count
        Rows            = $rows
    }
}
