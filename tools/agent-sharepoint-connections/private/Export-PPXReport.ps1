function Export-PPXReport {
    <#
    .SYNOPSIS
        Writes the report rows to a timestamped CSV plus a .limitations.txt sidecar.
    .DESCRIPTION
        Same conventions as the other PPX tools: UTF-8 (BOM on PS 6+/UTF8 on 5.1), default folder is
        the repo-root reports\ folder (git-ignored), -Path may be a folder or a path ending in .csv.
        The sidecar carries the run summary, INCOMPLETE flags, per-environment errors and the
        standing caveats for this tool.
    .PARAMETER Rows
        Shaped report rows.
    .PARAMETER Summary
        Run-summary lines.
    .PARAMETER Errors
        Per-environment / per-step error strings collected during the run.
    .PARAMETER IncompleteReasons
        Reasons the result may be incomplete (truncated inventory pulls, skipped environments...).
    .PARAMETER Path
        Optional folder or .csv path.
    .OUTPUTS
        [PSCustomObject] CsvPath, LimitationsPath, RowCount, Rows.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Rows = @(),

        [string[]] $Summary = @(),

        [string[]] $Errors = @(),

        [string[]] $IncompleteReasons = @(),

        [string] $Path
    )

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $defaultFolder = Join-Path $PSScriptRoot '..\..\..\reports'

    if (-not $Path) {
        $folder = $defaultFolder
        $csvPath = Join-Path $folder "AgentSharePointConnections_$stamp.csv"
    }
    elseif ($Path -match '\.csv$') {
        $csvPath = $Path
        $folder = Split-Path -Path $csvPath -Parent
        if (-not $folder) { $folder = '.' }
    }
    else {
        $folder = $Path
        $csvPath = Join-Path $folder "AgentSharePointConnections_$stamp.csv"
    }

    if (-not (Test-Path -LiteralPath $folder)) {
        $null = New-Item -ItemType Directory -Path $folder -Force
    }
    $csvPath = [System.IO.Path]::GetFullPath($csvPath)
    $limitationsPath = [System.IO.Path]::ChangeExtension($csvPath, '.limitations.txt')

    $encoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

    if (@($Rows).Count) {
        @($Rows) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding $encoding
    }
    else {
        # Keep a valid, header-only file so downstream tooling does not choke on a missing file.
        Set-Content -LiteralPath $csvPath -Value '' -Encoding $encoding
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('PPX Agent SharePoint Connections -- run notes')
    $lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add('')
    if ($IncompleteReasons.Count) {
        $lines.Add('*** INCOMPLETE ***')
        foreach ($r in $IncompleteReasons) { $lines.Add("  - $r") }
        $lines.Add('')
    }
    $lines.Add('Run summary')
    foreach ($s in $Summary) { $lines.Add("  $s") }
    $lines.Add('')
    if ($Errors.Count) {
        $lines.Add("Errors ($($Errors.Count))")
        foreach ($e in $Errors) { $lines.Add("  - $e") }
        $lines.Add('')
    }
    $lines.Add('Known limitations')
    $lines.Add('  - Knowledge-source detail is NOT available from the Power Platform Inventory API (counts only).')
    $lines.Add('    URLs come from the Dataverse botcomponents table, which is unofficial/undocumented for this use;')
    $lines.Add('    the schema can change without notice.')
    $lines.Add('  - Requires read access to botcomponents in every scanned environment; environments without')
    $lines.Add('    access appear as Status = "Error (...)" rows, not as "no SharePoint knowledge".')
    $lines.Add('  - Only the published agent is reflected in Inventory (about 20 minutes lag); Dataverse shows')
    $lines.Add('    the current draft components, so a draft-only knowledge source may appear before publish.')
    $lines.Add('  - V1 / classic (Power Virtual Agents) bots are not in Inventory and are not scanned.')
    $lines.Add('  - Agents whose Inventory knowledge count is 0 are skipped (use -ScanAllAgents to override).')
    $lines.Add('  - Uploaded files, Dataverse tables and other non-URL sources have no SharePoint URL; they only')
    $lines.Add('    appear with -IncludeAllKnowledge.')
    Set-Content -LiteralPath $limitationsPath -Value $lines -Encoding $encoding

    return [PSCustomObject]@{
        CsvPath         = $csvPath
        LimitationsPath = $limitationsPath
        RowCount        = @($Rows).Count
        Rows            = @($Rows)
    }
}
