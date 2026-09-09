function Export-PPXReport {
    <#
    .SYNOPSIS
        Shapes the raw Inventory API response into the §5 governance-baseline schema and writes it
        to a CSV, plus a sidecar known-limitations text file.
    .DESCRIPTION
        Takes the whole Inventory API response envelope (not just .data) because totalRecords /
        resultTruncated / pagesRetrieved feed the limitations file: if skipToken paging was cut
        short (-MaxPages or the hard safety cap), the report would otherwise be silently incomplete.

        Writes two files rather than appending prose into the CSV: a plain CSV has no comment
        syntax, so non-tabular rows appended below the data would misalign under the real headers
        or force the user to delete rows before pivoting/filtering in Excel — against the tool's own
        goal of needing no post-processing. See PPXAgentGovernanceBaseline.md §6.5.
    .PARAMETER Inventory
        The response object returned by Connect-PPXInventoryApi, synthesised from all retrieved
        pages: { totalRecords, count, resultTruncated, skipToken, pagesRetrieved, data[] }.
    .PARAMETER Path
        Optional. A folder to auto-name a timestamped CSV into, or a full path ending in .csv.
        Defaults to the repo-root reports\ folder (git-ignored).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,

        [string] $Path
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    if ($Path -and $Path.ToLowerInvariant().EndsWith('.csv')) {
        $csvPath = $Path
        $outputFolder = Split-Path -Parent $csvPath
    }
    else {
        $outputFolder = if ($Path) { $Path } else { Join-Path $PSScriptRoot '..\..\..\reports' }
        $csvPath = Join-Path $outputFolder "AgentGovernanceBaseline_$timestamp.csv"
    }

    if ($outputFolder -and -not (Test-Path -Path $outputFolder)) {
        $null = New-Item -ItemType Directory -Path $outputFolder -Force
    }

    $limitationsPath = [System.IO.Path]::ChangeExtension($csvPath, $null).TrimEnd('.') + '.limitations.txt'

    $records = @($Inventory.data)
    $rows = @($records | ConvertTo-PPXGovernanceRow)

    # Columns still built on an inferred (not directly-confirmed) rule. Most field paths were
    # confirmed against a live tenant response on 2026-09-03 (see CHANGELOG.md) and were dropped
    # from this list; IdentityModel's "Legacy Entra app" / "None" branches are still inferred from
    # AuthenticationMode alone, since no live example of either case has been seen yet. If it comes
    # back blank/Unknown for every row, that's a signal to revisit the derivation.
    $sanityCheckColumns = @('IdentityModel')
    $sanityWarnings = @()
    if ($rows.Count -gt 0) {
        foreach ($column in $sanityCheckColumns) {
            $allBlank = -not ($rows | Where-Object {
                $value = $_.$column
                $value -and $value -ne 'Unknown' -and $value -ne 0
            })
            if ($allBlank) {
                $message = "$column was empty/zero/'Unknown' for all $($rows.Count) row(s) -- the guessed source path is likely wrong; confirm against a live record (`$raw.data[0] | ConvertTo-Json -Depth 10`)."
                $sanityWarnings += $message
                Write-Warning $message
            }
        }
    }

    $encoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding $encoding

    $limitationsLines = @(
        "PPX Agent Governance Baseline -- known limitations for this report"
        "Generated: $(Get-Date -Format 'o')"
        "Rows exported: $($rows.Count) of $($Inventory.totalRecords) total agent record(s) in the tenant."
    )
    if ($null -ne $Inventory.pagesRetrieved) {
        $limitationsLines += "Inventory API pages retrieved (skipToken paging): $($Inventory.pagesRetrieved)."
    }
    $limitationsLines += ''

    if ($Inventory.resultTruncated) {
        $limitationsLines += "*** resultTruncated = true -- the Inventory API did not return every record for this query. This report is INCOMPLETE. ***"
        if ($Inventory.skipToken) {
            $limitationsLines += "Paging stopped early with a continuation token still pending -- most likely -MaxPages / AgentGovernanceBaseline.MaxPages capped the run. Re-run without that cap for a complete report."
        }
        $limitationsLines += ''
    }
    elseif ($Inventory.totalRecords -and $rows.Count -lt [int64] $Inventory.totalRecords) {
        $limitationsLines += "NOTE: $($rows.Count) row(s) exported but the tenant reports $($Inventory.totalRecords) agent record(s). All pages were retrieved, so the difference is rows dropped during shaping (join/filter), not API truncation."
        $limitationsLines += ''
    }

    $limitationsLines += @(
        'Documented limitations (PPXAgentGovernanceBaseline.md §8):'
        '- Reflects published agent state only; unpublished draft changes are invisible.'
        '- V1 / Classic (Power Virtual Agents) bots are excluded -- not present in the Inventory API.'
        '- The reported distinct connector count (capabilitiesCounts) is compared against the actual powerPlatformConnectors array to flag truncation (CapabilitiesTruncated); the exact cap, if any, is not documented by Microsoft.'
        '- Up to ~15 minutes of replication latency between a real-world change and inventory reflecting it.'
        '- HasZeroDlpCoverage (when populated) is a coverage boolean only, not policy detail.'
        '- Channels/Triggers/Flows list basic identifiers only; full publishing-channel configuration detail is not available through this report.'
        '- Several source fields are Microsoft Preview status and may change shape without notice.'
        '- Authentication is interactive delegated only; unattended auth is not supported against this endpoint.'
        ''
        'This report pass (Inventory-only, no Graph/DLP/connector-catalog enrichment):'
        '- OwnerName, OwnerUPN, OwnerAccountStatus are blank -- owner resolution (Resolve-PPXOwnerIdentity) is not implemented yet. The raw OwnerId GUID is included instead.'
        '- PremiumConnectorCount is blank -- connector-tier resolution (Resolve-PPXConnectorTier) is not implemented yet.'
        '- HasZeroDlpCoverage is blank -- DLP coverage resolution (Get-PPXDlpCoverageFlag) is not implemented yet.'
        '- EnvironmentGroup is blank -- not currently projected by the Inventory API query.'
        '- Channels/Triggers/Flows item labels are extracted defensively (name/displayName/type/id, falling back to raw JSON) -- no populated example of any of the three has been seen yet, only empty arrays, so the extraction logic is unconfirmed for real items.'
        '- IdentityModel: "Entra Agent ID/Blueprint" is confirmed from entraAgentId/entraAgentBlueprintId presence; the "Legacy Entra app" / "None" branches are inferred from AuthenticationMode alone and not yet confirmed against a live example of either case.'
    )

    if ($sanityWarnings.Count -gt 0) {
        $limitationsLines += ''
        $limitationsLines += 'Automatic checks flagged the following this run:'
        $limitationsLines += ($sanityWarnings | ForEach-Object { "- $_" })
    }

    $limitationsLines -join [System.Environment]::NewLine | Set-Content -Path $limitationsPath -Encoding UTF8

    return [PSCustomObject]@{
        CsvPath         = $csvPath
        LimitationsPath = $limitationsPath
        RowCount        = $rows.Count
        Rows            = $rows
    }
}
