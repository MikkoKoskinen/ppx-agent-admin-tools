function Get-PPXNestedValue {
    <#
    .SYNOPSIS
        Safely reads a dotted property path (e.g. 'properties.environmentId') off an object.
    .DESCRIPTION
        Returns -Default instead of throwing when a segment is missing, $null, or itself a
        collection. Copied verbatim from tools/agent-governance-baseline/private -- the two tools are
        self-contained by design; this helper is a candidate for tools/_shared later.
    #>
    [CmdletBinding()]
    param(
        # AllowNull is required: PowerShell rejects an explicit $null bound to a Mandatory parameter
        # otherwise, and callers legitimately pass $null here.
        [Parameter(Mandatory)] [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Path,
        $Default = $null
    )

    $current = $InputObject
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IEnumerable] -and $current -isnot [string]) { return $Default }
        if (-not $current.PSObject.Properties.Match($segment).Count) { return $Default }
        $current = $current.$segment
    }

    if ($null -eq $current) { return $Default }
    return $current
}
