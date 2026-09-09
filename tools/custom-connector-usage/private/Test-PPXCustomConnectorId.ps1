function Test-PPXCustomConnectorId {
    <#
    .SYNOPSIS
        Best-effort test for whether a connector ID (from properties.powerPlatformConnectors[].connectorId)
        refers to a CUSTOM connector rather than a first-party / certified one.
    .DESCRIPTION
        The Power Platform Inventory API exposes connector IDs only -- there is no authoritative
        "isCustom" field on the connector-usage array or (per the schema reference) on the
        `microsoft.powerplatformconnector/connectors` catalog record. This function therefore infers
        the answer from the ID's shape:

          - First-party / certified connectors have stable, human-readable IDs:
            `shared_sharepointonline`, `shared_office365users`, `shared_sql`, ...
          - Environment-scoped CUSTOM connectors carry a trailing `-<hex>` unique suffix derived
            from the connector's resource ID, e.g.
            `shared_contosocrmapi-5f2e8a9b1c3d4e5f6a7b8c9d`.

        So: strip a leading `shared_`, and if what remains ends in `-` followed by a run of hex
        characters, treat it as custom.

        This is an INFERRED signal (see the tool's known limitations). Known imperfections:
          - False positive: a first-party connector whose ID legitimately ends in `-<hex-looking>`.
          - False negative: a custom connector surfaced without the suffix (e.g. an
            independent-publisher connector that has been certified and promoted to `shared_<name>`).
        Resolve-PPXConnectorCatalog (not implemented yet) will cross-check against the tenant
        connector catalog and make this authoritative.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $ConnectorId
    )

    if ([string]::IsNullOrWhiteSpace($ConnectorId)) { return $false }

    # connectorId is sometimes a bare id ('shared_foo') and sometimes an ARM-ish path
    # ('/providers/Microsoft.PowerApps/apis/shared_foo-<hex>') -- take the last segment.
    $id = (($ConnectorId -split '/')[-1]).Trim().ToLowerInvariant()
    if ($id.StartsWith('shared_')) { $id = $id.Substring(7) }

    return [bool]($id -match '-[0-9a-f]{6,}$')
}
