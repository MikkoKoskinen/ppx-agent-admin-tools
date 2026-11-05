function ConvertFrom-PPXKnowledgeComponent {
    <#
    .SYNOPSIS
        Detects whether a Dataverse botcomponent is a knowledge source and, if so, extracts its
        source kind and SharePoint URL from the component's YAML.
    .DESCRIPTION
        Copilot Studio stores a knowledge source as a component whose YAML looks like:

            kind: KnowledgeSourceConfiguration
            source:
              kind: SharePointSearchSource
              site: https://contoso.sharepoint.com/sites/Hr/Shared%20Documents/Policies

        (shape taken from community Copilot Studio authoring references, NOT Microsoft docs -- the
        reason this parser is deliberately tolerant.) There is no YAML parser in Windows PowerShell
        5.1, so fields are pulled with regexes over the `content` and `data` text:
          - knowledge component  : text matches KnowledgeSourceConfiguration or a `kind: *Source` line
          - SourceKind           : the `kind:` value ending in 'Source'
          - SharePointUrl        : the `site:` value, else the first *.sharepoint.com URL in the text
          - IsSharePoint         : SourceKind contains 'SharePoint', or a SharePoint URL was found

        Returns $null when the component is not a knowledge source.
    .PARAMETER Component
        A botcomponents row as returned by Get-PPXAgentKnowledgeComponent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Component
    )

    $parts = foreach ($field in 'content', 'data') {
        $v = Get-PPXNestedValue $Component $field -Default ''
        if ($v -is [string] -and $v) { $v }
    }
    $text = @($parts) -join "`n"
    if (-not $text) { return $null }

    $kindMatches = [regex]::Matches($text, '(?mi)^\s*-?\s*kind:\s*["'']?(\w+)["'']?\s*$')
    $sourceKind = ''
    foreach ($km in $kindMatches) {
        if ($km.Groups[1].Value -match 'Source$' -and $km.Groups[1].Value -ne 'KnowledgeSourceConfiguration') {
            $sourceKind = $km.Groups[1].Value
            break
        }
    }

    $isKnowledge = ($text -match 'KnowledgeSourceConfiguration') -or ($sourceKind -ne '')
    if (-not $isKnowledge) { return $null }

    $url = ''
    $siteMatch = [regex]::Match($text, '(?mi)^\s*site:\s*["'']?([^"''\r\n]+?)["'']?\s*$')
    if ($siteMatch.Success) { $url = $siteMatch.Groups[1].Value.Trim() }
    if (-not $url) {
        $spMatch = [regex]::Match($text, 'https://[A-Za-z0-9.-]+\.sharepoint\.(?:com|us|de|cn)[^\s"''<>]*')
        if ($spMatch.Success) { $url = $spMatch.Value }
    }

    $isSharePoint = ($sourceKind -match 'SharePoint') -or ($url -match '\.sharepoint\.(com|us|de|cn)')

    $siteHost = ''
    if ($url) {
        try { $siteHost = ([uri] $url).Host } catch { }
    }

    return [PSCustomObject]@{
        SourceKind   = $sourceKind
        Url          = $url
        SiteHost     = $siteHost
        IsSharePoint = [bool] $isSharePoint
    }
}
