# Agent Governance Baseline

Tenant-wide, one-row-per-agent governance baseline report for published Copilot Studio (V2) agents
in Power Platform. Part of the [PPX](../../README.md) tool collection.

Full design: `PPX-Solution-Description-Agent-Governance-Baseline.md` (internal planning doc, not
tracked in this repo).

**Status: Experimental — partial implementation.** Only Inventory API connectivity is built so far.
Connector-tier resolution, owner resolution, the DLP coverage flag, schema assembly, and export are
not yet implemented (see inline `# TODO` markers in `private/*.ps1`).

## Purpose

Produce a single, exportable report giving a tenant-wide, one-row-per-agent view of Copilot Studio
agents, enriched with information that exists in the Power Platform admin center but is scattered
across multiple screens or not surfaced in the UI at all.

## Supported scenarios

- Governance-lead intake report at the start of an agent governance engagement.
- Identifying agents with disabled/orphaned owners, zero DLP coverage, or no authentication.

Not yet supported (planned, see solution description): connector-tier detail, DLP policy detail,
V1/classic bots, publishing-channel detail, historical trend data, and any write/remediation
actions — this tool is read-only by design.

## Prerequisites

- PowerShell 5.1+ or PowerShell 7.x
- [`MSAL.PS`](https://www.powershellgallery.com/packages/MSAL.PS) module
- `Microsoft.PowerApps.Administration.PowerShell` module (needed once the DLP coverage flag is
  implemented; not required for the current Inventory API-only functionality)
- Microsoft Graph PowerShell SDK or Graph REST access (needed once owner resolution is implemented)

## Required permissions

- Power Platform Administrator or Dynamics 365 Service Administrator role
- Must have signed into the Power Platform admin center at least once (prerequisite of the classic
  admin module)

## Usage

```powershell
. .\Get-PPXAgentGovernanceBaseline.ps1
Get-PPXAgentGovernanceBaseline
```

This currently signs in interactively (MSAL) and returns the raw Inventory API response. It does not
yet produce the final flat report described in the solution description.

## Known limitations

- Reflects **published** agent state only; unpublished draft changes are invisible.
- V1/Classic (Power Virtual Agents) bots are excluded — not present in the Inventory API.
- Several source fields are Microsoft **Preview** status and may change shape without notice.
- Up to ~15 minutes of replication latency between a real-world change and inventory reflecting it.
- Auth is interactive delegated only; service-principal/unattended auth against this endpoint is not
  supported cleanly by the platform at time of writing (see solution description §10).

## Security considerations

- No secrets or credentials are stored in this tool; MSAL handles interactive token acquisition and
  caching in-memory for the run only.
- Read-only: no write/remediation operations are performed anywhere in this tool.
