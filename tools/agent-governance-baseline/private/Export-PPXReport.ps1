function Export-PPXReport {
    <#
    .SYNOPSIS
        Shapes the raw Inventory API response into the §5 governance-baseline schema and writes it
        to a CSV, plus a sidecar known-limitations text file.
    .DESCRIPTION
        Takes the whole Inventory API response envelope (not just .data) because totalRecords /
        resultTruncated feed the limitations file: if -Top capped the result and paging isn't
        implemented, the report would otherwise be silently incomplete.

        Writes two files rather than appending prose into the CSV: a plain CSV has no comment
        syntax, so non-tabular rows appended below the data would misalign under the real headers
        or force the user to delete rows before pivoting/filtering in Excel — against the tool's own
        goal of needing no post-processing. See PPXAgentGovernanceBaseline.md §6.5.
    .PARAMETER Inventory
        The raw response object returned by Connect-PPXInventoryApi
        ({ totalRecords, count, resultTruncated, skipToken, data[] }).
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

    # Columns that are either blank-by-design (pending a future enrichment step) or a best-guess
    # field path unverified against a live tenant. If one of the guessed/calculated columns is
    # blank/Unknown across every row, that's a strong signal the guessed path is wrong -- surface it
    # loudly rather than let it go unnoticed until someone reads the CSV closely.
    $sanityCheckColumns = @('SchemaName', 'LastPublishedAt', 'StalenessBucket', 'IsQuarantined', 'IdentityModel', 'DistinctConnectorCount')
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
        ''
    )
    if ($Inventory.resultTruncated) {
        $limitationsLines += "*** resultTruncated = true -- the Inventory API did not return every record for this query (see -Top / paging). This report is INCOMPLETE. ***"
        $limitationsLines += ''
    }

    $limitationsLines += @(
        'Documented limitations (PPXAgentGovernanceBaseline.md §8):'
        '- Reflects published agent state only; unpublished draft changes are invisible.'
        '- V1 / Classic (Power Virtual Agents) bots are excluded -- not present in the Inventory API.'
        '- Connector and capability arrays cap at 200 items per agent; CapabilitiesTruncated flags when the cap is hit.'
        '- Up to ~15 minutes of replication latency between a real-world change and inventory reflecting it.'
        '- HasZeroDlpCoverage (when populated) is a coverage boolean only, not policy detail.'
        '- Channel / publishing-surface data is not available through this report.'
        '- Several source fields are Microsoft Preview status and may change shape without notice.'
        '- Authentication is interactive delegated only; unattended auth is not supported against this endpoint.'
        ''
        'This report pass (Inventory-only, no Graph/DLP/connector-catalog enrichment):'
        '- OwnerName, OwnerUPN, OwnerAccountStatus are blank -- owner resolution (Resolve-PPXOwnerIdentity) is not implemented yet.'
        '- PremiumConnectorCount is blank -- connector-tier resolution (Resolve-PPXConnectorTier) is not implemented yet.'
        '- HasZeroDlpCoverage is blank -- DLP coverage resolution (Get-PPXDlpCoverageFlag) is not implemented yet.'
        '- EnvironmentGroup is blank -- not currently projected by the Inventory API query.'
        '- SchemaName, LastPublishedAt, IsQuarantined, and IdentityModel use unverified/best-guess source paths, not yet confirmed against a live tenant response.'
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
