function Get-PPXNormalizedConnectorKey {
    <#
    .SYNOPSIS
        Normalises a connector identifier so a connector seen in the Inventory connector-usage array
        (properties.powerPlatformConnectors[].connectorId) can be matched to the same connector
        returned by the connectivity API (`name`), whose suffix formatting differs.
    .DESCRIPTION
        Observed forms:
          - Inventory usage:   shared_sharepointonline
                               shared_contosocrmapi-5f2e8a9b...          (hyphen suffix)
          - Connectivity API:  shared_customapi2.5f0629412a7d1fe83e.5f6f049093c9b7a698
                               (dot-separated, sometimes two suffixes)
          - Either may arrive as an ARM-ish path: /providers/Microsoft.PowerApps/apis/<id>

        Rule: take the last path segment, lowercase, drop a leading `shared_`, then drop everything
        from the first `.` or `-` onward (the environment-unique hex suffix on a custom connector).
        What remains is the connector's base name, which is stable across both surfaces.

        Caveat (documented in the report's .limitations.txt): two DIFFERENT custom connectors whose
        base names collide within one environment (e.g. two connectors both named "customapi") would
        normalise to the same key. Rare; the connectivity-API row still carries the full distinct id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $ConnectorId
    )

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) { return '' }

    $id = (($ConnectorId -split '/')[-1]).Trim().ToLowerInvariant()
    if ($id.StartsWith('shared_')) { $id = $id.Substring(7) }
    $id = ($id -split '[.\-]', 2)[0]
    return $id
}
