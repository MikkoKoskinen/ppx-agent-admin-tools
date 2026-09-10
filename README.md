# PPX – Agent Admin Tools for Power Platform

Independent open-source tools, scripts, and small apps that extend Power Platform agent
administration and governance capabilities, built on Power Platform's programmability and
extensibility APIs.

Each tool is self-contained under `tools/<name>/`, with its own usage README and a solution/technical
description. This root README is the landing page — status, quick start, and shared configuration.

## Tools

| Tool | Status | What it does | Docs |
|---|---|---|---|
| **[Agent Governance Baseline](tools/agent-governance-baseline)** | 🧪 Production tested | Tenant-wide inventory: one row per published Copilot Studio (V2) agent, 43 governance columns (ownership, environment, auth posture, build origin, connector/channel counts, sharing exposure, staleness). Read-only. | [Usage](tools/agent-governance-baseline/README.md) · [Solution](tools/agent-governance-baseline/PPXAgentGovernanceBaseline.md) |
| **[Custom Connector Usage](tools/custom-connector-usage)** | 🧪 Experimental | Tenant-wide view of custom connectors: one row per `(environment × connector)`, covering both connectors in active use and ones merely present in an environment. Read-only. | [Usage](tools/custom-connector-usage/README.md) · [Solution](tools/custom-connector-usage/PPXCustomConnectorUsage.md) |
| **[Copilot Credit — Tenant Pool Draw](tools/copilot-credit-tenant-pool)** | 🧪 Dev in Progress | Sets the "draw from tenant pool" Copilot Credit enforcement rule on/off, per environment or tenant-wide. Dry-run by default; a target must be chosen explicitly. | [Usage](tools/copilot-credit-tenant-pool/README.md) · [Solution](tools/copilot-credit-tenant-pool/PPXCopilotCreditTenantPool.md) |

Each tool's known data gaps and limitations are also written into its own CSV output as a
`.limitations.txt` sidecar at run time — not just documented here.

### Agent Governance Baseline

The opening artifact for a governance engagement: `Get-PPXAgentGovernanceBaseline` produces one flat,
exportable CSV that assembles data the admin center either doesn't show at all or requires manual
cross-screen navigation to piece together. Inventory API connectivity, schema assembly, and CSV export
work end-to-end; connector-tier resolution, owner resolution, and the DLP-coverage flag are not built
yet, so those columns are blank in every row for now. Point-in-time, read-only.

→ [Full usage & setup](tools/agent-governance-baseline/README.md) · [Solution & technical description](tools/agent-governance-baseline/PPXAgentGovernanceBaseline.md)

### Custom Connector Usage

`Get-PPXCustomConnectorUsage` pulls environments and connector-emitting resources from the Inventory
API, then queries the per-environment connectivity API to resolve which custom connectors actually
exist where and what consumes them. Both API pulls are implemented and wired end-to-end. The
connectivity `$filter` contract is based on community reports rather than an official Microsoft
example — worth confirming on your first full run. Point-in-time, read-only.

→ [Full usage & setup](tools/custom-connector-usage/README.md) · [Solution & technical description](tools/custom-connector-usage/PPXCustomConnectorUsage.md)

### Copilot Credit — Tenant Pool Draw

The first PPX tool that **writes**. `Set-PPXCopilotCreditTenantPoolDraw` flips the `TenantPool`
enforcement rule on an environment's Copilot Credits allocation, via read-modify-write — every other
enforcement rule and the allocated amount are sent back unchanged. It's dry-run by default: without
`-Apply` it only writes a before/after CSV of what would change. A target is always explicit
(`-EnvironmentId`, `-AllEnvironments`, or `-InputCsv`, the latter typically a trimmed dry-run report).
Policy-locked and allocation-less environments are recorded and skipped, not fatal.

→ [Full usage & setup](tools/copilot-credit-tenant-pool/README.md) · [Solution & technical description](tools/copilot-credit-tenant-pool/PPXCopilotCreditTenantPool.md)

## Quick start

```powershell
git clone <this-repo>
cd ppx-agent-admin-tools

Install-Module Az.Accounts -Scope CurrentUser        # one-time

Copy-Item ppx.settings.example.psd1 ppx.settings.psd1 # git-ignored
# edit ppx.settings.psd1 → Common.TenantId = '<your Entra tenant id>'

. .\tools\agent-governance-baseline\Get-PPXAgentGovernanceBaseline.ps1
Get-PPXAgentGovernanceBaseline
```

First run opens an interactive sign-in (`Connect-AzAccount`); later runs reuse the cached Az context.
If the browser prompt doesn't complete (common inside the VS Code debugger), set
`Common.UseDeviceAuthentication = $true` in `ppx.settings.psd1` — see
[SETTINGS.md](SETTINGS.md#authentication).

The command above writes a CSV report (plus a `.limitations.txt` sidecar) to `reports\` at the repo
root (git-ignored) and returns the shaped rows. Set `AgentGovernanceBaseline.OutputPath` to choose
where it lands, or `AgentGovernanceBaseline.ExportReport = $false` to skip the file and just get rows
back — see [SETTINGS.md](SETTINGS.md#current-keys).

## Prerequisites

- **PowerShell** 5.1+ (Windows PowerShell) or 7.x
- **[`Az.Accounts`](https://www.powershellgallery.com/packages/Az.Accounts)** for interactive sign-in
  and token acquisition against the Power Platform API:
  ```powershell
  Install-Module Az.Accounts -Scope CurrentUser
  ```
- A **Power Platform Administrator** or **Dynamics 365 Service Administrator** role, having signed
  into the Power Platform admin center at least once
- Some tools need extra modules (Microsoft Graph PowerShell SDK, the classic
  `Microsoft.PowerApps.Administration.PowerShell` module, …) — see each tool's own README

Authentication details, tenant selection, and the alternative Entra app-registration approach are in
[SETTINGS.md](SETTINGS.md#authentication).

## Configuration

All tools share one settings file at the repo root. The repo ships with **no tenant configured** —
after cloning, create your own settings file and set your Entra tenant ID; the tools refuse to run
otherwise:

```powershell
Copy-Item ppx.settings.example.psd1 ppx.settings.psd1
# then edit ppx.settings.psd1 → Common.TenantId
```

`ppx.settings.psd1` is git-ignored, so your tenant ID is never committed. Full reference:
[SETTINGS.md](SETTINGS.md).

## Repository layout

```
ppx-agent-admin-tools/
├─ ppx.settings.example.psd1   Settings template (committed). Copy to ppx.settings.psd1.
├─ SETTINGS.md                 Settings + authentication reference.
├─ CHANGELOG.md                Technical change history.
├─ LICENSE
├─ reports/                    Generated CSV reports + .limitations.txt sidecars (git-ignored).
└─ tools/
   ├─ _shared/                 Helpers shared by every tool (e.g. Get-PPXSettings.ps1).
   ├─ agent-governance-baseline/
   │  ├─ README.md                          Usage instructions.
   │  ├─ PPXAgentGovernanceBaseline.md      Solution + technical description.
   │  ├─ Get-PPXAgentGovernanceBaseline.ps1 Entry-point function.
   │  └─ private/                            Internal step scripts, dot-sourced at run time.
   ├─ custom-connector-usage/
   │  ├─ README.md                          Usage instructions.
   │  ├─ PPXCustomConnectorUsage.md         Solution + technical description.
   │  ├─ Get-PPXCustomConnectorUsage.ps1    Entry-point function.
   │  └─ private/
   └─ copilot-credit-tenant-pool/
      ├─ README.md                          Usage instructions.
      ├─ PPXCopilotCreditTenantPool.md      Solution + technical description.
      ├─ Set-PPXCopilotCreditTenantPoolDraw.ps1  Entry-point function (WRITE; dry run unless -Apply).
      └─ private/
```

Each `private/` folder holds that tool's internal step scripts — see the tool's own README for what
each script does; several are copied rather than shared across tools by design (see
[SETTINGS.md](SETTINGS.md) contributor notes for why).

## Development

- **Debugging in VS Code**: open Run and Debug, pick **PPX: Debug Governance Baseline**,
  **PPX: Debug Custom Connector Usage**, or **PPX: Debug Copilot Credit Tenant Pool**, and press F5.
  Each runs a small harness (`Debug-*.ps1`, git-ignored) that dot-sources the entry-point function and
  calls it, so breakpoints in the function and its `private/*.ps1` are hit. The Copilot Credit harness
  defaults to a dry run (no `-Apply`) so F5 never writes.
- **Adding a setting or a new tool**: see the contributor sections in [SETTINGS.md](SETTINGS.md).
- **Change history**: [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
