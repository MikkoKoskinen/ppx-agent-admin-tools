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

### [Custom Connector Usage](tools/custom-connector-usage) — *experimental*

Tenant-wide view of which Power Platform environments have **custom connectors** — one command
produces one flat, exportable table with a row per `(environment × custom connector)`. It covers
both custom connectors an app/flow/agent references *and* custom connectors that merely exist in an
environment (created or imported but not yet used), each row carrying environment basic details
(name, type, managed flag, environment group, region), connector display name / publisher / tier,
whether the classification is authoritative or inferred, whether the connector list for that
environment was actually retrieved, and which apps/flows/agents consume it. Read-only and
point-in-time.

**Status:** experimental. Both Inventory API pulls (environments, connector-emitting resources) and
the per-environment connectivity-API connector lookup (`Get-PPXCustomConnectorUsage`) are
implemented and wired end-to-end, writing a CSV plus a `.limitations.txt` sidecar. The connectivity
`$filter` contract is from community reports, not an official Microsoft example — confirm it on the
first full run. See the [tool README](tools/custom-connector-usage/README.md).

Solution and high-level technical description:
[PPXCustomConnectorUsage.md](PPXCustomConnectorUsage.md).

### [Copilot Credit — Tenant Pool Draw](tools/copilot-credit-tenant-pool) — *experimental*

The first PPX tool that **writes**. One command sets the Copilot Credit **"Draw from the available
capacity in my tenant"** option — the `TenantPool` enforcement rule on each environment's
`MCSMessages` (Copilot Credits) currency allocation — to `$true` or `$false` for **all** or
**selected** Power Platform environments. Every write is read-modify-write: the environment's current
allocation is read first, and the allocated credit amount plus every other enforcement rule
(`Alert` / `PayGo` / `Deny`) are sent back unchanged — only `TenantPool` moves.

It is **dry run by default**: without `-Apply` it reads every target environment and writes a
before/after CSV (plus a `.limitations.txt` run summary) showing exactly what *would* change, and
touches nothing. A target must be chosen explicitly — `-EnvironmentId <guid[,guid…]>`,
`-AllEnvironments`, or `-InputCsv <path>`; it never changes every environment implicitly.
`-InputCsv` reads the `EnvironmentId` column of a CSV — typically a **dry-run report trimmed to just
the rows you want applied** (an optional `DesiredValue` column can even set a different value per
environment). Environments locked by a published environment-group rule (`TenantPoolLockedByPolicy`)
and environments with no allocation surface are recorded and skipped, not fatal.

```powershell
. .\tools\copilot-credit-tenant-pool\Set-PPXCopilotCreditTenantPoolDraw.ps1

# dry run: what would turning tenant-pool draw OFF everywhere do?
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments

# review the CSV, delete the rows you don't want, then apply only those
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -InputCsv .\reports\CopilotCreditTenantPool_<timestamp>.csv -Apply

# or apply straight away, tenant-wide / to named environments
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments -Apply
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $true -EnvironmentId <guid>,<guid> -Apply
```

Solution and high-level technical description:
[PPXCopilotCreditTenantPool.md](PPXCopilotCreditTenantPool.md).

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
├─ PPXAgentGovernanceBaseline.md   Solution + high-level technical description (Agent Governance Baseline).
├─ PPXCustomConnectorUsage.md      Solution + high-level technical description (Custom Connector Usage).
├─ PPXCopilotCreditTenantPool.md   Solution + high-level technical description (Copilot Credit — Tenant Pool Draw).
├─ CHANGELOG.md                Technical change history.
├─ reports/                    Generated CSV reports + .limitations.txt sidecars (git-ignored).
├─ tools/
│  ├─ _shared/                 Helpers shared by every tool (e.g. Get-PPXSettings.ps1).
│  ├─ agent-governance-baseline/
│  │  ├─ Get-PPXAgentGovernanceBaseline.ps1   Entry-point function.
│  │  └─ private/                              Internal step scripts, dot-sourced at run time.
│  │     ├─ Connect-PPXInventoryApi.ps1        Auth + Inventory API query.
│  │     ├─ ConvertTo-PPXGovernanceRow.ps1     Shapes one record into a §5 report row.
│  │     ├─ ConvertTo-PPXArraySummary.ps1      Count + label summary for array fields (channels, etc.).
│  │     ├─ Get-PPXNestedValue.ps1             Safe dotted-path property reader.
│  │     └─ Export-PPXReport.ps1               Writes the CSV + limitations sidecar.
│  ├─ custom-connector-usage/
│  │  ├─ Get-PPXCustomConnectorUsage.ps1      Entry-point function.
│  │  └─ private/                              Internal step scripts, dot-sourced at run time.
│  │     ├─ Get-PPXPowerPlatformToken.ps1     Az sign-in + delegated token (shared by the two APIs).
│  │     ├─ Connect-PPXInventoryApi.ps1       Query-agnostic Inventory API wrapper + skipToken paging.
│  │     ├─ Get-PPXEnvironmentConnector.ps1   Connectivity API: connectors that exist in one environment.
│  │     ├─ Get-PPXNormalizedConnectorKey.ps1 Normalises connector IDs so the two APIs' forms match.
│  │     ├─ Test-PPXCustomConnectorId.ps1     ID-shape custom-connector heuristic (fallback).
│  │     ├─ ConvertTo-PPXConnectorUsageRow.ps1  Merges existence + usage into one row per (env × connector).
│  │     ├─ Get-PPXNestedValue.ps1            Safe dotted-path property reader.
│  │     ├─ ConvertTo-PPXJoinedList.ps1       Caps a list into one '; '-joined CSV cell.
│  │     └─ Export-PPXReport.ps1              Writes the CSV + limitations sidecar.
│  └─ copilot-credit-tenant-pool/
│     ├─ Set-PPXCopilotCreditTenantPoolDraw.ps1   Entry-point function (WRITE; dry run unless -Apply).
│     └─ private/                              Internal step scripts, dot-sourced at run time.
│        ├─ Get-PPXPowerPlatformToken.ps1     Az sign-in + delegated token (copy).
│        ├─ Connect-PPXInventoryApi.ps1       Inventory API wrapper + skipToken paging (copy) — env list.
│        ├─ Import-PPXTargetCsv.ps1           -InputCsv reader: EnvironmentId (+ optional DesiredValue).
│        ├─ Get-PPXEnvironmentCreditAllocation.ps1  GET licensing/allocationsByEnvironment/{id}.
│        ├─ Resolve-PPXTenantPoolChange.ps1   Pure planner: minimal read-modify-write PATCH body.
│        ├─ Set-PPXEnvironmentCreditAllocation.ps1  PATCH licensing/allocationsByEnvironment (+policy-lock detect).
│        ├─ ConvertTo-PPXTenantPoolRow.ps1    Shapes one before/after report row per environment.
│        ├─ Get-PPXNestedValue.ps1            Safe dotted-path property reader (copy).
│        └─ Export-PPXReport.ps1              Writes the CSV + .limitations.txt run summary.
└─ .vscode/                    Debug configurations (see Development).
```

## Development

- Debugging in VS Code: open the Run and Debug panel, pick **PPX: Debug Governance Baseline**,
  **PPX: Debug Custom Connector Usage**, or **PPX: Debug Copilot Credit Tenant Pool**, and press F5.
  Each runs a small harness (`Debug-*.ps1`, git-ignored) that dot-sources the entry-point function
  and calls it, so breakpoints in the function and `private/*.ps1` are hit. The Copilot Credit
  harness defaults to a **dry run** (no `-Apply`) so F5 never writes.
- Adding a setting or a new tool: see the contributor sections in [SETTINGS.md](SETTINGS.md).
- Technical history of changes: [CHANGELOG.md](CHANGELOG.md).
