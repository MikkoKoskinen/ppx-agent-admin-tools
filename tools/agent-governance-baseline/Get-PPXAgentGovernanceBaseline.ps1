function Get-PPXAgentGovernanceBaseline {
    <#
    .SYNOPSIS
        Tenant-wide, one-row-per-agent governance baseline report for published Copilot Studio (V2)
        agents.
    .DESCRIPTION
        Primary entry point for the PPX Agent Governance Baseline tool (Patch 1). See the companion
        solution description for the full schema and architecture:
        Internal-Docs/PPX-Solution-Description-Agent-Governance-Baseline.md

        Current state: only Inventory API connectivity (Connect-PPXInventoryApi) is implemented.
        Connector-tier resolution, owner resolution, DLP coverage flag, schema assembly, and export
        are not yet built — see the inline TODOs and the private/ script headers.
    .PARAMETER TenantId
        Optional Entra tenant ID to hint the interactive sign-in to a specific tenant.
    .PARAMETER Top
        Optional page size passed through to the Inventory API query.
    .EXAMPLE
        Get-PPXAgentGovernanceBaseline
        Signs in interactively and prints a summary of the raw agent/environment records returned by
        the Inventory API.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [int] $Top
    )

    $privatePath = Join-Path $PSScriptRoot 'private'
    Get-ChildItem -Path $privatePath -Filter '*.ps1' | ForEach-Object {
        . $_.FullName
    }

    $connectParams = @{}
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    if ($Top) { $connectParams['Top'] = $Top }

    $inventory = Connect-PPXInventoryApi @connectParams

    $records = @($inventory.value)
    Write-Host "Inventory API returned $($records.Count) resource record(s)."

    # TODO: Patch 1 step 2 — Resolve-PPXConnectorTier (connector catalog + premium count)
    # TODO: Patch 1 step 3 — Resolve-PPXOwnerIdentity (batched Graph lookups)
    # TODO: Patch 1 step 4 — Get-PPXDlpCoverageFlag (DLP coverage boolean)
    # TODO: Patch 1 step 5 — assemble records into the §5 flat schema, incl. calculated columns
    # TODO: Patch 1 step 6 — Export-PPXReport + appended known-limitations block (§7)

    return $inventory
}
