function Get-PPXAgentGovernanceBaseline {
    <#
    .SYNOPSIS
        Tenant-wide, one-row-per-agent governance baseline report for published Copilot Studio (V2)
        agents.
    .DESCRIPTION
        Primary entry point for the PPX Agent Governance Baseline tool. See the solution and
        high-level technical description for the full schema and architecture:
        PPXAgentGovernanceBaseline.md (repo root).

        Current state: only Inventory API connectivity (Connect-PPXInventoryApi) is implemented.
        Connector-tier resolution, owner resolution, DLP coverage flag, schema assembly, and export
        are not yet built — see the inline TODOs and the private/ script headers.
        Runtime values default from the shared settings file (ppx.settings.psd1 at the repo root,
        section 'AgentGovernanceBaseline'); an explicit parameter here overrides that file.
    .PARAMETER TenantId
        Entra tenant ID to sign in against. Required — supply it here, or set Common.TenantId
        (or AgentGovernanceBaseline.TenantId) in ppx.settings.psd1. The function throws if neither
        is set; no tenant is ever baked into the repo.
    .PARAMETER Top
        Optional page size passed through to the Inventory API query.
        Defaults to the settings file (AgentGovernanceBaseline.Top).
    .PARAMETER UseDeviceAuthentication
        Sign in with device-code flow instead of the interactive browser prompt. Set this (or
        Common.UseDeviceAuthentication in the settings file) when running under the VS Code debugger,
        where the browser/WAM prompt hangs.
    .EXAMPLE
        Get-PPXAgentGovernanceBaseline
        Signs in interactively via Connect-AzAccount (only if there is no usable Az context) and
        prints a summary of the raw agent/environment records returned by the Inventory API.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId,

        [int] $Top,

        [switch] $UseDeviceAuthentication
    )

    . (Join-Path $PSScriptRoot '..\_shared\Get-PPXSettings.ps1')

    $privatePath = Join-Path $PSScriptRoot 'private'
    Get-ChildItem -Path $privatePath -Filter '*.ps1' | ForEach-Object {
        . $_.FullName
    }

    # Fall back to the shared settings file for any parameter not passed explicitly.
    $settings = Get-PPXSettings -Section 'AgentGovernanceBaseline'
    if (-not $PSBoundParameters.ContainsKey('TenantId') -and $settings.TenantId) { $TenantId = $settings.TenantId }
    if (-not $PSBoundParameters.ContainsKey('Top') -and $settings.Top) { $Top = $settings.Top }
    if (-not $PSBoundParameters.ContainsKey('UseDeviceAuthentication') -and $settings.UseDeviceAuthentication) {
        $UseDeviceAuthentication = [bool] $settings.UseDeviceAuthentication
    }

    if (-not $TenantId) {
        throw @'
No tenant ID configured. This tool never ships with a tenant baked in — set your own:

  1. Copy  ppx.settings.example.psd1  to  ppx.settings.psd1  (repo root; git-ignored), then
     set  Common.TenantId  to your Entra tenant ID.
  -- or --
  2. Pass it explicitly:  Get-PPXAgentGovernanceBaseline -TenantId <guid>
'@
    }

    $connectParams = @{}
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    if ($Top) { $connectParams['Top'] = $Top }
    if ($UseDeviceAuthentication) { $connectParams['UseDeviceAuthentication'] = $true }

    write-Host "..get base agent listing."

    $inventory = Connect-PPXInventoryApi @connectParams

    $records = @($inventory.data)
    Write-Host "Inventory API returned $($records.Count) of $($inventory.totalRecords) agent record(s)."

    # TODO: Patch 1 step 2 — Resolve-PPXConnectorTier (connector catalog + premium count)
    # TODO: Patch 1 step 3 — Resolve-PPXOwnerIdentity (batched Graph lookups)
    # TODO: Patch 1 step 4 — Get-PPXDlpCoverageFlag (DLP coverage boolean)
    # TODO: Patch 1 step 5 — assemble records into the §5 flat schema, incl. calculated columns
    # TODO: Patch 1 step 6 — Export-PPXReport + appended known-limitations block (§7)

    return $inventory
}
