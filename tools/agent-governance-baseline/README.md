# Agent Governance Baseline

Tenant-wide, one-row-per-agent governance baseline report for published Copilot Studio (V2) agents
in Power Platform. Part of the [PPX](../../README.md) tool collection.

Solution and high-level technical description:
[PPXAgentGovernanceBaseline.md](PPXAgentGovernanceBaseline.md).

**Status: Experimental — partial implementation.** Inventory API connectivity, schema assembly, and
CSV export are built — 43 columns per agent, most field paths confirmed against a live tenant
response on 2026-09-03. Connector-tier resolution, owner resolution, and the DLP coverage flag are
not yet implemented (see inline `# TODO` markers in `private/*.ps1`), so `OwnerName`, `OwnerUPN`,
`OwnerAccountStatus`, `PremiumConnectorCount`, and `HasZeroDlpCoverage` are blank in every row.
`IdentityModel`'s "Legacy Entra app" / "None" branches, and the item shape of `Channels`/`Triggers`/
`Flows` for populated arrays, are still inferred rather than confirmed — see
[Known limitations](#known-limitations).

## Purpose

Produce a single, exportable report giving a tenant-wide, one-row-per-agent view of Copilot Studio
agents, enriched with information that exists in the Power Platform admin center but is scattered
across multiple screens or not surfaced in the UI at all.

## Supported scenarios

- Governance-lead intake report at the start of an agent governance engagement.
- Identifying agents with disabled/orphaned owners, zero DLP coverage, or no authentication.
- Identifying agents shared with the entire tenant, built via CLI/GitHub Copilot rather than Copilot
  Studio, or using an unexpected model.

Not yet supported (planned, see solution description): connector-tier detail, DLP policy detail,
V1/classic bots, full publishing-channel configuration detail (basic channel/trigger/flow counts and
identifiers are included), historical trend data, and any write/remediation actions — this tool is
read-only by design.

## Prerequisites

- PowerShell 5.1+ or PowerShell 7.x
- [`Az.Accounts`](https://www.powershellgallery.com/packages/Az.Accounts) module — used for
  interactive sign-in and token acquisition against the Power Platform API
  (`Install-Module Az.Accounts -Scope CurrentUser`)
- `Microsoft.PowerApps.Administration.PowerShell` module (needed once the DLP coverage flag is
  implemented; not required for the current Inventory API-only functionality)
- Microsoft Graph PowerShell SDK or Graph REST access (needed once owner resolution is implemented)

## Required permissions

- Power Platform Administrator or Dynamics 365 Service Administrator role
- Must have signed into the Power Platform admin center at least once (prerequisite of the classic
  admin module)

## Usage

First-run setup — the repo ships with no tenant, so set yours (once):

```powershell
# from the repo root
Copy-Item ppx.settings.example.psd1 ppx.settings.psd1   # git-ignored
# then edit ppx.settings.psd1 → Common.TenantId
```

Then:

```powershell
. .\Get-PPXAgentGovernanceBaseline.ps1
Get-PPXAgentGovernanceBaseline
# or, without a settings file:
Get-PPXAgentGovernanceBaseline -TenantId <your-tenant-guid>
# or, to control where the CSV lands:
Get-PPXAgentGovernanceBaseline -OutputPath C:\reports\my-tenant.csv
# or, to skip writing a CSV entirely and just get the shaped rows back:
Get-PPXAgentGovernanceBaseline -ExportReport:$false
# or, for a quick partial pull while testing (stops after N Inventory API pages):
Get-PPXAgentGovernanceBaseline -MaxPages 1
```

**Large tenants:** the Inventory API returns at most 1000 rows per request. The tool follows the
`skipToken` continuation automatically and retrieves every agent, however many there are — `-Top`
(or `AgentGovernanceBaseline.Top`) only sets the per-request page size, it does not cap the total.
`-MaxPages` / `AgentGovernanceBaseline.MaxPages` (default `0` = unlimited) can cap the paging loop;
when it does, the `.limitations.txt` sidecar marks the report **INCOMPLETE**.

The function throws with setup instructions if no tenant ID is resolved. It signs in interactively
via `Connect-AzAccount` (only when there is no usable Az context), writes a governance-baseline CSV
to `reports\` at the repo root (git-ignored; override with `-OutputPath` or
`AgentGovernanceBaseline.OutputPath` in settings) along with a `.limitations.txt` sidecar describing
this run's known gaps, and returns the shaped rows. See [Report schema](PPXAgentGovernanceBaseline.md#5-report-schema)
for the full column list and [Known limitations](#known-limitations) below for which columns are
still blank pending owner/DLP/connector-tier enrichment.

Tenant selection and other knobs come from the shared settings file — see
[SETTINGS.md](../../SETTINGS.md), including the **Authentication** section for how the token is
obtained and the alternative app-registration approach.

## Known limitations

- Reflects **published** agent state only; unpublished draft changes are invisible.
- V1/Classic (Power Virtual Agents) bots are excluded — not present in the Inventory API.
- Several source fields are Microsoft **Preview** status and may change shape without notice.
- Up to ~15 minutes of replication latency between a real-world change and inventory reflecting it.
- Auth is interactive delegated only; service-principal/unattended auth against this endpoint is not
  supported cleanly by the platform at time of writing (see solution description §10).
- `OwnerName`, `OwnerUPN`, `OwnerAccountStatus`, `PremiumConnectorCount`, and `HasZeroDlpCoverage` are
  blank in every row — the Graph owner lookup, connector-tier resolution, and DLP coverage flag are
  not implemented yet. The raw `OwnerId` GUID is included in the meantime.
- `EnvironmentGroup` is blank — not currently projected by the Inventory API query.
- `IdentityModel`'s `"Entra Agent ID/Blueprint"` value is confirmed (from `entraAgentId`/
  `entraAgentBlueprintId` presence); its `"Legacy Entra app"` / `"None"` branches are inferred from
  `AuthenticationMode` alone, since no live example of either case has been seen yet. If it comes back
  blank/`Unknown` for every row, the tool prints a `Write-Warning` calling that out.
- `Channels`, `Triggers`, and `Flows` list basic identifiers only; their item shape for **populated**
  arrays is unconfirmed — only an empty-array example has been seen for all three so far, so the
  label-extraction logic in `ConvertTo-PPXArraySummary.ps1` is a best-effort guess. If you see one with
  real entries, share it so the extraction can be tightened.
- `CapabilitiesTruncated` compares the actual `powerPlatformConnectors` array length against the
  reported distinct-connector count (`capabilitiesCounts.distinctPowerPlatformConnectors`) — Microsoft
  does not document an exact truncation cap, so this is a relative signal, not a fixed threshold.
- Every run's specific gaps (including the above) are restated in the `.limitations.txt` file written
  alongside the CSV, so the report is self-describing without needing this README.

## Security considerations

- No secrets or credentials are stored in this tool; Az PowerShell handles interactive token
  acquisition and caching (in the Az context token cache) only.
- Read-only: no write/remediation operations are performed anywhere in this tool.
