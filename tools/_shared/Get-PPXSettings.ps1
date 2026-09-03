#Requires -Version 5.1

$script:PPXSettingsCache = @{}

function Get-PPXSettings {
    <#
    .SYNOPSIS
        Loads shared user settings for the PPX tools from ppx.settings.psd1.

    .DESCRIPTION
        Walks up from this script's folder to find the solution root (the folder
        containing ppx.settings.psd1, or failing that ppx.settings.example.psd1)
        and imports it with Import-PowerShellDataFile (data only — no code runs).

        Returns a hashtable of the Common section merged with the requested tool
        section, where the tool section wins on key collisions. Keys whose value
        is '' or 0 are dropped, so a caller can treat "present" as "set".

        Callers should still let an explicit parameter override the returned
        value; this function only supplies the "no parameter given" fallback.

    .PARAMETER Section
        Name of the tool section to merge over Common, e.g. 'AgentGovernanceBaseline'.
        Omit to get just the Common section.

    .PARAMETER Refresh
        Re-read the file from disk instead of using the in-process cache.

    .EXAMPLE
        $s = Get-PPXSettings -Section 'AgentGovernanceBaseline'
        if (-not $PSBoundParameters.ContainsKey('Top') -and $s.Top) { $Top = $s.Top }
    #>
    [CmdletBinding()]
    param(
        [string] $Section,

        [switch] $Refresh
    )

    $path = Find-PPXSettingsFile
    if (-not $path) {
        Write-Verbose 'No ppx.settings.psd1 or ppx.settings.example.psd1 found; using defaults only.'
        return @{}
    }

    if ($Refresh -or -not $script:PPXSettingsCache.ContainsKey($path)) {
        Write-Verbose "Loading PPX settings from $path"
        $script:PPXSettingsCache[$path] = Import-PowerShellDataFile -Path $path
    }
    $raw = $script:PPXSettingsCache[$path]

    $merged = @{}
    foreach ($key in @($raw.Common.Keys)) { $merged[$key] = $raw.Common[$key] }
    if ($Section -and $raw.ContainsKey($Section) -and $raw[$Section]) {
        foreach ($key in @($raw[$Section].Keys)) { $merged[$key] = $raw[$Section][$key] }
    }

    # Drop "unset" placeholders so callers can test with a simple truthiness check.
    foreach ($key in @($merged.Keys)) {
        $value = $merged[$key]
        if ($null -eq $value -or $value -eq '' -or $value -eq 0) { $merged.Remove($key) }
    }

    return $merged
}

function Find-PPXSettingsFile {
    [CmdletBinding()]
    param()

    $dir = $PSScriptRoot
    for ($i = 0; $i -lt 6 -and $dir; $i++) {
        $real = Join-Path $dir 'ppx.settings.psd1'
        if (Test-Path -LiteralPath $real) { return $real }

        $example = Join-Path $dir 'ppx.settings.example.psd1'
        if (Test-Path -LiteralPath $example) { return $example }

        $parent = Split-Path -Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}
