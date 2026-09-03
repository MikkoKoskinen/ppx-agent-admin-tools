# PPX – Agent Admin Tools for Power Platform
Independent open-source tools, scripts, and small apps that extend Power Platform agent administration and governance capabilities using Power Platform programmability and extensibility APIs.

## Tools

### [Agent Governance Baseline](tools/agent-governance-baseline) — *experimental*

The opening artifact for a Power Platform agent governance engagement: one command produces one
flat, exportable table (43 columns) with a row per published Copilot Studio (V2) agent, tenant-wide.
Every column is something the Power Platform admin center either doesn't show in its agent list at
all or requires manual cross-screen navigation to assemble — owner name and account status (the
leaver/orphan signal), environment and managed-environment context, authentication and identity
posture, orchestration type, build origin (creation surface, harness, model, CLI/GitHub Copilot
flags), distinct and premium connector counts, channel/trigger/flow counts, content composition,
tenant-wide sharing exposure, a zero-DLP-coverage flag, publish staleness, quarantine state — with
every known data limitation stated in the output itself. Read-only and point-in-time.

**Status:** partial implementation. Inventory API connectivity, schema assembly, and CSV export
(`Get-PPXAgentGovernanceBaseline`) work end-to-end and write a governance-baseline CSV plus a
`.limitations.txt` sidecar. Connector-tier resolution, owner resolution, and the DLP coverage flag are
not built yet, so `OwnerName`/`OwnerUPN`/`OwnerAccountStatus`, `PremiumConnectorCount`, and
`HasZeroDlpCoverage` are blank in every row. See the
[tool README](tools/agent-governance-baseline/README.md) and the `# TODO` markers in its
`private/*.ps1`.

Solution and high-level technical description:
[PPXAgentGovernanceBaseline.md](PPXAgentGovernanceBaseline.md).

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

First run opens an interactive sign-in (`Connect-AzAccount`); later runs reuse the cached Az
context. If the browser prompt doesn't complete (common inside the VS Code debugger), set
`Common.UseDeviceAuthentication = $true` in `ppx.settings.psd1` — see
[SETTINGS.md](SETTINGS.md#authentication).

The command above writes a CSV report (plus a `.limitations.txt` sidecar) to `reports\` at the repo
root (git-ignored) and returns the shaped rows. Set `AgentGovernanceBaseline.OutputPath` to choose
where it lands, or `AgentGovernanceBaseline.ExportReport = $false` to skip writing to disk entirely
and just get the rows back — see [SETTINGS.md](SETTINGS.md#current-keys).

## Prerequisites

- **PowerShell** 5.1+ (Windows PowerShell) or 7.x
- **[`Az.Accounts`](https://www.powershellgallery.com/packages/Az.Accounts)** — used for interactive
  sign-in and token acquisition against the Power Platform API:
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
after cloning you must create your own settings file and set your Entra tenant ID; the tools refuse
to run otherwise:

```powershell
Copy-Item ppx.settings.example.psd1 ppx.settings.psd1
# then edit ppx.settings.psd1 → Common.TenantId
```

`ppx.settings.psd1` is git-ignored, so your tenant ID is never committed. See
[SETTINGS.md](SETTINGS.md) for the full reference.

## Repository layout

```
ppx-agent-admin-tools/
├─ ppx.settings.example.psd1   Settings template (committed). Copy to ppx.settings.psd1.
├─ SETTINGS.md                 Settings + authentication reference.
├─ PPXAgentGovernanceBaseline.md   Solution + high-level technical description.
├─ CHANGELOG.md                Technical change history.
├─ reports/                    Generated CSV reports + .limitations.txt sidecars (git-ignored).
├─ tools/
│  ├─ _shared/                 Helpers shared by every tool (e.g. Get-PPXSettings.ps1).
│  └─ agent-governance-baseline/
│     ├─ Get-PPXAgentGovernanceBaseline.ps1   Entry-point function.
│     └─ private/                              Internal step scripts, dot-sourced at run time.
│        ├─ Connect-PPXInventoryApi.ps1        Auth + Inventory API query.
│        ├─ ConvertTo-PPXGovernanceRow.ps1     Shapes one record into a §5 report row.
│        ├─ ConvertTo-PPXArraySummary.ps1      Count + label summary for array fields (channels, etc.).
│        ├─ Get-PPXNestedValue.ps1             Safe dotted-path property reader.
│        └─ Export-PPXReport.ps1               Writes the CSV + limitations sidecar.
└─ .vscode/                    Debug configurations (see Development).
```

## Development

- Debugging in VS Code: open the Run and Debug panel, pick **PPX: Debug Governance Baseline**, and
  press F5. It runs a small harness (`Debug-*.ps1`, git-ignored) that dot-sources the entry-point
  function and calls it, so breakpoints in the function and `private/*.ps1` are hit.
- Adding a setting or a new tool: see the contributor sections in [SETTINGS.md](SETTINGS.md).
- Technical history of changes: [CHANGELOG.md](CHANGELOG.md).
