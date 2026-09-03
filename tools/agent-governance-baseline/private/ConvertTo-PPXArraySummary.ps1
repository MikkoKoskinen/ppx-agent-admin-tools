function ConvertTo-PPXArraySummary {
    <#
    .SYNOPSIS
        Reduces an array field (e.g. properties.channels/.triggers/.flows) to a CSV-friendly
        Count + Summary pair.
    .DESCRIPTION
        Item shape for these arrays is not confirmed by any populated live example seen so far
        (channels/triggers/flows were all empty in the record used to build this) -- so item labels
        are extracted defensively: try common name-ish properties, fall back to a compact JSON dump
        of the whole item. Revisit the property-name list here once a populated example is seen.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [array] $Items = @(),
        [int] $MaxItems = 10
    )

    $count = $Items.Count
    if ($count -eq 0) {
        return [PSCustomObject]@{ Count = 0; Summary = '' }
    }

    $labels = $Items | ForEach-Object {
        if ($_ -is [string]) { $_ }
        elseif ($_.PSObject.Properties.Match('displayName').Count) { $_.displayName }
        elseif ($_.PSObject.Properties.Match('name').Count) { $_.name }
        elseif ($_.PSObject.Properties.Match('type').Count) { $_.type }
        elseif ($_.PSObject.Properties.Match('id').Count) { $_.id }
        else { $_ | ConvertTo-Json -Compress -Depth 5 }
    }

    $shown = @($labels | Select-Object -First $MaxItems)
    $summary = $shown -join '; '
    if ($count -gt $MaxItems) { $summary += "; ...(+$($count - $MaxItems) more)" }

    [PSCustomObject]@{ Count = $count; Summary = $summary }
}
