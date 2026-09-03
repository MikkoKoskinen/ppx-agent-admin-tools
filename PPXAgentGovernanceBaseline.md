# PPX Agent Governance Baseline — Solution Description

Solution and high-level technical description for the **Agent Governance Baseline** tool. For how to
run it, see [tools/agent-governance-baseline/README.md](tools/agent-governance-baseline/README.md);
for settings and authentication, [SETTINGS.md](SETTINGS.md); for the technical change history,
[CHANGELOG.md](CHANGELOG.md).

**Status:** experimental. Inventory API connectivity, schema assembly, and CSV export are implemented
and working. Owner resolution, DLP coverage, and connector-tier resolution are not built yet, so five
columns are blank in every row, and a few other columns use unverified best-guess field paths — see
[Implementation status](#implementation-status).

---

## 1. Purpose

Provide the opening artifact for a Power Platform agent governance engagement: a single, exportable
table giving a tenant-wide, **one row per published Copilot Studio (V2) agent** view, enriched with
information that exists in the Power Platform admin center (PPAC) but is scattered across multiple
screens, requires manual cross-referencing, or is not surfaced in the UI at all.

It is a point-in-time, **read-only** report. It performs no write or remediation actions.

## 2. Audience and scenarios

- **Governance leads** running an intake assessment at the start of an engagement — one command,
  one spreadsheet, no further processing.
- **Platform admins** identifying agents with disabled or orphaned owners, zero DLP coverage, no
  authentication, or long publish staleness.

## 3. Goals

- One command produces one flat, exportable table (CSV / Excel), tenant-wide.
- Every column is either absent from PPAC's agent list view or requires manual navigation and
  joining to assemble today.
- Output is usable directly in Excel on day one — no post-processing.
- Every known data limitation is stated **in the report output**, not left as a silent gap.

## 4. Scope

### In scope

- Published Copilot Studio **V2** agents, all environments in the tenant.
- Environment context, ownership, authentication/identity posture, orchestration type, a summary
  connector count with a premium sub-count, a zero-DLP-coverage flag, publish staleness, quarantine
  state.

### Out of scope (by design, this phase)

| Not included | Why / where it lives |
| --- | --- |
| Connector-level detail beyond a summary count | Later connector-focused tools reuse this tool's connector-tier resolution |
| DLP policy content | Referenced only as a boolean coverage flag; full DLP reporting is separate |
| V1 / Classic (Power Virtual Agents) bots | Not represented in the Inventory API |
| Publishing-channel detail | Channel manifest retrieval is a separate, narrower capability |
| Trend / historical snapshots | This tool is point-in-time only |
| Any write / remediation (quarantine, delete, reassignment) | Read-only by design |

## 5. Report schema

One row per published V2 agent.

| Column | Source | Notes |
| --- | --- | --- |
| `AgentName` | Inventory `properties.displayName` | |
| `AgentId` | Inventory `name` | |
| `SchemaName` | Inventory (Copilot Studio agent schema) | |
| `EnvironmentName` | Inventory, environment join | |
| `EnvironmentId` | Inventory `properties.environmentId` | |
| `EnvironmentType` | Inventory, environment join | Production / Sandbox / Trial / Developer / Default / Dataverse-for-Teams |
| `IsManagedEnvironment` | Inventory, environment join | |
| `EnvironmentGroup` | Inventory, environment join | Blank if unassigned |
| `OwnerName` / `OwnerUPN` | Microsoft Graph lookup on `ownerId` | |
| `OwnerAccountStatus` | Microsoft Graph lookup | Active / Disabled / NotFound — the leaver/orphan signal |
| `CreatedAt` | Inventory `properties.createdAt` | |
| `LastPublishedAt` | Inventory (agent-specific field) | |
| `StalenessBucket` | Calculated | `<6mo` / `6–12mo` / `12–24mo` / `>24mo` since last publish |
| `AuthenticationMode` | Inventory `properties.authentication` | Flagged separately when "none" |
| `IdentityModel` | Inventory | Entra Agent ID/Blueprint present vs. legacy Entra app only vs. neither |
| `OrchestrationType` | Inventory `properties.orchestration` | |
| `DistinctConnectorCount` | Calculated from `properties.powerPlatformConnectors` | |
| `PremiumConnectorCount` | Calculated, joined to connector catalog tier | |
| `HasZeroDlpCoverage` | Calculated against DLP policy connector lists for the agent's environment | Boolean flag only |
| `CapabilitiesTruncated` | Inventory `capabilitiesCounts` vs. the 200-item cap | Data-completeness warning |
| `IsQuarantined` | Inventory | |
| `ChannelDataAvailable` | Static `false` | Documented gap — see [Known limitations](#8-known-limitations) |

## 6. Technical design (high level)

### 6.1 Pipeline

```
Get-PPXAgentGovernanceBaseline            entry point (tools/agent-governance-baseline/)
 ├─ Connect-PPXInventoryApi     acquire token, POST resourcequery/resources/query
 │                              (agents + environments joined in one query)   [implemented]
 ├─ Resolve-PPXConnectorTier    connector catalog lookup, cached per run       [planned]
 ├─ Resolve-PPXOwnerIdentity    batched Microsoft Graph lookups, cached per run [planned]
 ├─ Get-PPXDlpCoverageFlag      wraps Get-AdminDlpPolicy / connector configs    [planned]
 └─ Export-PPXReport            flat table out (CSV / Excel), + limitations block [planned]
```

The entry point resolves runtime parameters (tenant, page size, auth mode) from the shared settings
file, dot-sources the `private/*.ps1` step scripts, and orchestrates the steps above. Owner and
connector-tier lookups are batched and cached once per execution to avoid redundant calls across
hundreds of agents. The whole run is idempotent and read-only.

### 6.2 Data sources

| Source | Role |
| --- | --- |
| **Power Platform Inventory API** — `POST /resourcequery/resources/query` | Primary: agent records, environment join, connector-usage array |
| **Connector catalog** — `microsoft.powerplatformconnector/connectors` via the same API | Resolves connector tier (Standard / Premium) for the premium sub-count |
| **Microsoft Graph** — user lookups | Resolves `ownerId` to display name / UPN and account status |
| **DLP policy data** — `Get-AdminDlpPolicy` / connector configuration cmdlets (classic admin module) | Computes the single "zero DLP coverage" boolean per agent |

### 6.3 Authentication

Interactive **delegated** (user) authentication, obtained through **Az PowerShell**:
`Connect-AzAccount` (only when there is no usable Az context) then
`Get-AzAccessToken -ResourceUrl https://api.powerplatform.com`.

The Power Platform API publishes no sample public client, and its resource application ID cannot be
used as a client ID (doing so yields `AADSTS90009`). The tool therefore borrows the already-consented
Az PowerShell first-party client rather than requiring each user to register an Entra app. A
device-code option (`UseDeviceAuthentication`) exists for environments where the interactive browser
prompt cannot render, such as the VS Code debugger. A dedicated Entra app registration is documented
as an alternative. Full detail: [SETTINGS.md § Authentication](SETTINGS.md#authentication).

Service-principal / unattended auth against the resource-query endpoint is a known platform
limitation (the request is forwarded to Azure Resource Graph, which currently expects an
On-Behalf-Of flow) and is not implemented.

### 6.4 Inventory API query approach

The endpoint takes a structured query object (not a KQL or SQL string) which the service translates
to Kusto and runs against Azure Resource Graph:

- `POST https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01`
- Body: `{ TableName: "PowerPlatformResources", Options: { Top, Skip }, Clauses: [ … ] }`.
- `Clauses` is an ordered list of typed operations (`extend`, `join`, `where`, `project`,
  `orderby`, …); the `$type` discriminator must be the first property of each clause object.
- The baseline query mirrors PPAC's own default pattern: derive a lowercased environment join key,
  `leftouter`-join every resource to its environment record, then filter to
  `microsoft.copilotstudio/agents`, ordered by creation date.
- Response envelope: `{ totalRecords, count, resultTruncated, skipToken, data[] }`.

Exact request/response mechanics and the pitfalls resolved during implementation are in
[CHANGELOG.md](CHANGELOG.md).

### 6.5 Output

A flat table exported as CSV, one row per agent. Rather than appending limitations prose into the CSV
itself (which would conflict with §3's "no post-processing" goal — a plain CSV has no comment syntax,
so stray non-tabular rows would misalign under the real headers or need manual deletion before
pivoting), each run writes **two files**: `<name>.csv` (pure tabular data) and a sibling
`<name>.limitations.txt` sidecar carrying the static §8 limitations plus this run's dynamic notes
(row count vs. `totalRecords`, `resultTruncated`, which columns are blank-by-design this pass, and any
automatic warnings about likely-wrong field-path guesses). The same summary is echoed to the console.
A formatted Excel workbook is not implemented (plain CSV opens directly in Excel with no extra
dependency).

### 6.6 Configuration

All runtime knobs come from the shared settings file (`ppx.settings.psd1`, section
`AgentGovernanceBaseline`, falling back to `Common`): tenant ID (required), page size, auth mode,
output path, and whether to export the report at all (`ExportReport`, default `$true` — set to
`$false` to only build and return the shaped rows in memory). Precedence is explicit parameter →
settings file → tool/API default. See [SETTINGS.md](SETTINGS.md).

Note: `ExportReport` is a boolean whose *default* is `$true`, so an explicit `$false` in the settings
file must be distinguishable from "not set." `Get-PPXSettings` therefore only drops `$null`, `''`, and
numeric `0` as "unset" placeholders — `$false` is kept as a real value.

## 7. Implementation status

| Component | State |
| --- | --- |
| Settings resolution, tenant enforcement, orchestration skeleton | Done |
| `Connect-PPXInventoryApi` — auth + agents/environments query | Done, returns raw `data[]` |
| Schema assembly (§5) incl. calculated columns | Done for Inventory-sourced/calculated columns (17 of 20 named columns, plus a bonus `EnvironmentRegion`); `EnvironmentGroup`, `OwnerName`/`OwnerUPN`/`OwnerAccountStatus`, `PremiumConnectorCount`, `HasZeroDlpCoverage` are blank pending the steps below |
| `Export-PPXReport` — CSV + `.limitations.txt` sidecar | Done |
| `Resolve-PPXConnectorTier` | Not started (stub) — feeds `PremiumConnectorCount` |
| `Resolve-PPXOwnerIdentity` | Not started (stub) — feeds `OwnerName`/`OwnerUPN`/`OwnerAccountStatus` |
| `Get-PPXDlpCoverageFlag` | Not started (stub) — feeds `HasZeroDlpCoverage` |

Build order so far: Inventory API connectivity → Inventory-only schema assembly and CSV export.
Remaining: connector catalog resolution → owner resolution → DLP boolean, wired into the same
`ConvertTo-PPXGovernanceRow` assembly step.

**Field-path caveat:** `SchemaName`, `LastPublishedAt`, `IsQuarantined`, and `IdentityModel` are
implemented against best-guess field paths — no live Inventory API response has yet been captured and
inspected to confirm them (see `tools\agent-governance-baseline\private\ConvertTo-PPXGovernanceRow.ps1`).
`Export-PPXReport` prints a `Write-Warning` if any of these come back blank/`Unknown` for every row in
a run, as a signal to confirm the real paths via `Connect-PPXInventoryApi` and
`$raw.data[0] | ConvertTo-Json -Depth 10` and correct the mapping. `EnvironmentGroup` is also blank —
the current Inventory API query's environment `project` clause (`Connect-PPXInventoryApi.ps1`) does
not project it; adding it is a tracked follow-up rather than a guess against the working query.

## 8. Known limitations

Stated here and, once export exists, in every report run:

- Reflects **published** agent state only; unpublished draft changes are invisible.
- **V1 / Classic** agents are excluded — not present in the Inventory API.
- Connector and capability arrays cap at 200 items per agent; `CapabilitiesTruncated` flags when the
  cap is hit.
- Up to ~15 minutes of replication latency between a real-world change and inventory reflecting it.
- `HasZeroDlpCoverage` is a coverage boolean, not policy detail — not a substitute for a DLP audit.
- Channel / publishing-surface data is not available through this report — explicitly marked, not
  silently omitted.
- Several source fields are Microsoft **Preview** status and may change shape without notice.
- Authentication is interactive delegated only; unattended auth is not supported against this
  endpoint at time of writing.

## 9. Dependencies

- PowerShell 5.1+ (Windows PowerShell) or 7.x
- `Az.Accounts` — Inventory API sign-in and token acquisition
- `Microsoft.PowerApps.Administration.PowerShell` — DLP coverage flag (once implemented)
- Microsoft Graph PowerShell SDK or direct Graph REST — owner resolution (once implemented)
- Permissions: Power Platform Administrator (or Dynamics 365 Service Administrator); must have signed
  into PPAC at least once

## 10. Relationship to future tools

This tool deliberately produces only summary connector counts per agent. Planned connector-focused
tools (a connector-usage readability report, and a connector-first tenant-wide inventory) reuse this
tool's connector-catalog resolution (`Resolve-PPXConnectorTier`) as a shared component rather than
duplicating it.

## References

- [Power Platform inventory API](https://learn.microsoft.com/en-us/power-platform/admin/inventory-api)
- [Power Platform inventory schema reference](https://learn.microsoft.com/en-us/power-platform/admin/inventory-schema)
- [Programmability and extensibility — authentication (v2)](https://learn.microsoft.com/en-us/power-platform/admin/programmability-authentication-v2)
