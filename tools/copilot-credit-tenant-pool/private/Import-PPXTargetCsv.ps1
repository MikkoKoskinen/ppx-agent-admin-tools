function Import-PPXTargetCsv {
    <#
    .SYNOPSIS
        Reads the target environment list from a CSV -- typically a trimmed dry-run report
        (CopilotCreditTenantPool_<timestamp>.csv) with only the rows the admin wants applied.
    .DESCRIPTION
        Consumes any CSV that has an 'EnvironmentId' column (case-insensitive). Every other column is
        ignored except an optional 'DesiredValue' column, whose per-row TRUE / FALSE is returned so
        the caller can use it as the target value when -DrawFromTenantCapacity is omitted.

        Tolerant of how the file comes back from a spreadsheet editor:
          - a leading UTF-8 BOM and an Excel `sep=` directive line are stripped,
          - `;` or TAB delimited files (Excel under a non-US list-separator locale) are detected,
          - the "every row collapsed into one doubled-quote-wrapped field" shape that Excel writes
            when it opened a comma CSV under such a locale ( "Name,""EnvironmentId"",..." ) is
            un-wrapped and re-parsed.

        Blank EnvironmentId rows are skipped. Duplicate EnvironmentId values are de-duplicated, first
        occurrence wins. An unparseable DesiredValue cell is a terminating error (rather than a silent
        wrong write). Throws if the file has no usable rows or no EnvironmentId column.
    .PARAMETER Path
        Path to the CSV file.
    .OUTPUTS
        Array of [PSCustomObject]@{ EnvironmentId = <string>; DesiredValue = <bool> or $null }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "Input CSV '$Path' is empty." }
    $raw = $raw.TrimStart([char]0xFEFF)            # strip a UTF-8 BOM if Get-Content kept it
    $raw = $raw -replace '(?m)^\s*sep=.\r?\n', ''  # drop an Excel 'sep=' directive line

    $rows = @($raw | ConvertFrom-Csv)

    # If a normal comma parse collapsed every row into one field, the file was re-saved by an
    # editor whose list separator is not a comma. Recover.
    if ($rows.Count -ge 1 -and @($rows[0].PSObject.Properties).Count -le 1) {
        $hdr = "$(@($rows[0].PSObject.Properties.Name)[0])"

        if ($hdr -match "`t") {
            $rows = @($raw | ConvertFrom-Csv -Delimiter "`t")
        }
        elseif ($hdr -match ';' -and $hdr -notmatch ',') {
            $rows = @($raw | ConvertFrom-Csv -Delimiter ';')
        }
        elseif ($hdr -match ',') {
            # Whole row wrapped in one pair of quotes with the original quotes doubled:
            #   "Name,""EnvironmentId"",""Type"""  ->  Name,"EnvironmentId","Type"
            $fixed = @(
                $raw -split '\r?\n' | Where-Object { $_.Trim() -ne '' } | ForEach-Object {
                    $s = $_.Trim()
                    if ($s.Length -ge 2 -and $s.StartsWith('"') -and $s.EndsWith('"')) {
                        $s = $s.Substring(1, $s.Length - 2)
                    }
                    $s -replace '""', '"'
                }
            ) -join "`n"
            $rows = @($fixed | ConvertFrom-Csv)
        }
    }

    if ($rows.Count -eq 0) { throw "Input CSV '$Path' has a header row but no data rows." }

    $envProp     = $rows[0].PSObject.Properties | Where-Object { $_.Name.Trim() -ieq 'EnvironmentId' } | Select-Object -First 1
    $desiredProp = $rows[0].PSObject.Properties | Where-Object { $_.Name.Trim() -ieq 'DesiredValue' }  | Select-Object -First 1
    if (-not $envProp) {
        throw "Input CSV '$Path' has no 'EnvironmentId' column. Columns found: $(@($rows[0].PSObject.Properties.Name) -join ', ')."
    }
    $envCol     = $envProp.Name
    $desiredCol = if ($desiredProp) { $desiredProp.Name } else { $null }

    $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $out    = [System.Collections.Generic.List[object]]::new()
    $rowNo  = 1   # header
    foreach ($r in $rows) {
        $rowNo++
        $id = "$($r.$envCol)".Trim().Trim('"')
        if (-not $id) { continue }
        if (-not $seen.Add($id)) { continue }

        $dv = $null
        if ($desiredCol) {
            $rawDv = "$($r.$desiredCol)".Trim().Trim('"')
            if ($rawDv) {
                if ($rawDv -match '^(?i:true|1|yes|y|on|enabled)$')       { $dv = $true }
                elseif ($rawDv -match '^(?i:false|0|no|n|off|disabled)$')  { $dv = $false }
                else {
                    throw "Input CSV '$Path' row ${rowNo}: DesiredValue '$rawDv' is not a boolean. Use TRUE or FALSE (or clear the cell and pass -DrawFromTenantCapacity)."
                }
            }
        }

        $out.Add([PSCustomObject]@{ EnvironmentId = $id; DesiredValue = $dv })
    }

    if ($out.Count -eq 0) {
        throw "Input CSV '$Path' has no rows with a non-empty EnvironmentId."
    }
    return $out.ToArray()
}
