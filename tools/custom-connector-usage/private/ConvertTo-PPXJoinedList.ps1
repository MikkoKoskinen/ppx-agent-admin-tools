function ConvertTo-PPXJoinedList {
    <#
    .SYNOPSIS
        Reduces a list of strings to a single CSV-cell-friendly value: '; '-joined, capped, with a
        "...(+N more)" tail when it overflows the cap.
    .DESCRIPTION
        The connector-usage report keeps one row per environment, so multi-valued columns
        (CustomConnectorIds, ConsumingResources) have to collapse into one cell. This keeps them
        readable in Excel without a post-processing step (see the tool's §3 goal).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [string[]] $Items = @(),
        [int] $MaxItems = 15,
        [string] $Separator = '; '
    )

    $count = $Items.Count
    if ($count -eq 0) { return '' }

    $shown = @($Items | Select-Object -First $MaxItems)
    $joined = $shown -join $Separator
    if ($count -gt $MaxItems) { $joined += "$Separator...(+$($count - $MaxItems) more)" }
    return $joined
}
