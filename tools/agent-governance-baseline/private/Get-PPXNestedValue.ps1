function Get-PPXNestedValue {
    <#
    .SYNOPSIS
        Safely reads a dotted property path (e.g. 'properties.createdAt') off an object.
    .DESCRIPTION
        Returns -Default instead of throwing when a segment is missing, $null, or itself a
        collection — the last case matters here specifically because some of the paths this is
        used with (in ConvertTo-PPXGovernanceRow) are unverified guesses against a Preview API;
        if a guessed segment turns out to be an array, PowerShell's member-enumeration-on-collections
        behaviour would otherwise silently return a collection instead of the intended scalar.
    #>
    [CmdletBinding()]
    param(
        # AllowNull is required: PowerShell rejects an explicit $null bound to a Mandatory parameter
        # otherwise, and callers legitimately pass $null here (e.g. a sub-object like
        # properties.componentsCounts that doesn't exist on every agent record).
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
