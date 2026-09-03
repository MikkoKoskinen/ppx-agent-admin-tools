# Agent Governance Baseline

Tenant-wide, one-row-per-agent governance baseline report for published Copilot Studio (V2) agents
in Power Platform. Part of the [PPX](../../README.md) tool collection.

Solution and high-level technical description:
[PPXAgentGovernanceBaseline.md](../../PPXAgentGovernanceBaseline.md).

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
```

The function throws with setup instructions if no tenant ID is resolved. It currently signs in
interactively via `Connect-AzAccount` (only when there is no usable Az context) and returns the raw
Inventory API response. It does not yet produce the final flat report described in the solution
description.

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

## Security considerations

- No secrets or credentials are stored in this tool; Az PowerShell handles interactive token
  acquisition and caching (in the Az context token cache) only.
- Read-only: no write/remediation operations are performed anywhere in this tool.
