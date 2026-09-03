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
- Environment context, ownership, authentication/identity posture, orchestration type, build origin
  (creation surface, harness, model, CLI/GitHub Copilot flags), a summary connector count with a
  premium sub-count, channel/trigger/flow counts, content composition (topics/tools/knowledge/
  connected-agent counts), tenant-wide sharing exposure, a zero-DLP-coverage flag, publish staleness,
  quarantine state.

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

One row per published V2 agent, 43 columns. Field paths marked **confirmed** were checked against a
live tenant response on 2026-09-03 (see `CHANGELOG.md`); **inferred** means no live example of that
branch/case has been seen yet.

An initial pass had 51 columns; 8 were cut as low-value-on-their-own after review: `EntraAgentBlueprintId`
and `CreatedByUserId` (both redundant — `IdentityModel`/`EntraAgentId` and `OwnerId` already carry the
useful signal), `ConnectorOperationsCount` (operation-level detail, not a governance signal by itself),
`EnvironmentRegion` (bonus column, not core governance data), and the four sharing sub-counts
`SharedViewerUserCount`/`SharedViewerGroupCount`/`SharedEditorUserCount`/`SharedEditorGroupCount`
(the actionable signal is `SharedWithEntireTenant`; per-count detail matters only for a specific
follow-up investigation, not a tenant-wide scan). `EntraAgentId` and `InstructionsCharactersCount` were
kept despite being in the same review groups.

### Identity / location

| Column | Source | Notes |
| --- | --- | --- |
| `AgentName` | Inventory `properties.displayName` | confirmed |
| `AgentId` | Inventory `name` | |
| `SchemaName` | Inventory `properties.schemaName` | confirmed |
| `EnvironmentName` | Inventory, environment join | |
| `EnvironmentId` | Inventory `properties.environmentId` | confirmed |
| `EnvironmentType` | Inventory, environment join | Production / Sandbox / Trial / Developer / Default / Dataverse-for-Teams |
| `IsManagedEnvironment` | Inventory, environment join | |
| `EnvironmentGroup` | Inventory, environment join | Blank — not currently projected by the query, see §8 |

### Ownership

| Column | Source | Notes |
| --- | --- | --- |
| `OwnerName` / `OwnerUPN` | Microsoft Graph lookup on `ownerId` | Blank — `Resolve-PPXOwnerIdentity` not implemented yet |
| `OwnerAccountStatus` | Microsoft Graph lookup | Blank — same as above. Active / Disabled / NotFound is the leaver/orphan signal once implemented |
| `OwnerId` | Inventory `properties.ownerId` | confirmed. Raw GUID, usable before Graph resolution exists |

### Lifecycle

| Column | Source | Notes |
| --- | --- | --- |
| `CreatedAt` | Inventory `properties.createdAt` | confirmed. Normalised to ISO 8601 |
| `LastPublishedAt` | Inventory `properties.lastPublishedAt` | confirmed (was guessed as `lastPublishedOn` before live verification — wrong) |
| `StalenessBucket` | Calculated from `LastPublishedAt` | `<6mo` / `6-12mo` / `12-24mo` / `>24mo` |
| `IsQuarantined` | Inventory `properties.isQuarantined` | confirmed |

### Authentication / identity

| Column | Source | Notes |
| --- | --- | --- |
| `AuthenticationMode` | Inventory `properties.authentication` | confirmed. Observed value: `"Microsoft Entra"` |
| `IdentityModel` | Derived | `"Entra Agent ID/Blueprint"` confirmed from `entraAgentId`/`entraAgentBlueprintId` presence; `"Legacy Entra app"` / `"None"` branches inferred from `AuthenticationMode` alone |
| `EntraAgentId` | Inventory `properties.entraAgentId` | confirmed |

### Build origin

| Column | Source | Notes |
| --- | --- | --- |
| `CreatedIn` | Inventory `properties.createdIn` | confirmed. Observed value: `"Copilot Studio"` |
| `Harness` | Inventory `properties.harness` | confirmed. Observed value: `"GitHub Copilot"` |
| `Model` | Inventory `properties.model` | confirmed. Observed value: `"GPT-5.6 Reasoning"` |
| `OrchestrationType` | Inventory `properties.orchestration` | confirmed. Observed value: `"Generative"` |
| `IsCLIAgent` | Inventory `properties.isCLIAgent` | confirmed |
| `IsGithubCopilotAgent` | Inventory `properties.isGithubCopilotAgent` | confirmed |
| `IsManagedAgent` | Inventory `properties.isManaged` | confirmed. Agent-level flag — distinct from `IsManagedEnvironment` (environment-level), both exist and mean different things |

### Connectivity / automation surface

| Column | Source | Notes |
| --- | --- | --- |
| `DistinctConnectorCount` | Inventory `properties.capabilitiesCounts.distinctPowerPlatformConnectors` | confirmed. Authoritative; falls back to counting `powerPlatformConnectors` manually if `capabilitiesCounts` is absent |
| `PremiumConnectorCount` | Calculated, joined to connector catalog tier | Blank — `Resolve-PPXConnectorTier` not implemented yet |
| `CapabilitiesTruncated` | Calculated: actual `powerPlatformConnectors` array length vs. reported `distinctPowerPlatformConnectors` | Data-completeness warning; the exact cap (if any) isn't documented by Microsoft |
| `ChannelsCount` / `Channels` | Inventory `properties.channels` | Array; only an empty example seen so far, so item-label extraction is unconfirmed for populated arrays |
| `TriggersCount` / `Triggers` | Inventory `properties.triggers` | Same caveat as `Channels` |
| `FlowsCount` / `Flows` | Inventory `properties.flows` | Same caveat as `Channels` |

### Composition / content

| Column | Source | Notes |
| --- | --- | --- |
| `TopicsCount` | Inventory `properties.componentsCounts.topics` | confirmed |
| `ToolsCount` | Inventory `properties.componentsCounts.tools` | confirmed |
| `KnowledgeCount` | Inventory `properties.componentsCounts.knowledge` | confirmed |
| `ConnectedAgentsCount` | Inventory `properties.componentsCounts.connectedAgents` | confirmed |
| `InstructionsCharactersCount` | Inventory `properties.instructionsCharactersCount` | confirmed |
| `IsWebSearchEnabledForKnowledge` | Inventory `properties.isWebSearchEnabledForKnowledge` | confirmed |

### Sharing exposure

| Column | Source | Notes |
| --- | --- | --- |
| `SharedWithEntireTenant` | Inventory `properties.sharedWithViewers.entireTenant` | confirmed. Whether the agent is shared with everyone in the tenant |

### Governance flags pending future enrichment

| Column | Source | Notes |
| --- | --- | --- |
| `HasZeroDlpCoverage` | Calculated against DLP policy connector lists for the agent's environment | Blank — `Get-PPXDlpCoverageFlag` not implemented yet |

`ChannelDataAvailable` (previously a hardcoded `false` "documented gap" placeholder) has been removed:
live testing showed `properties.channels` genuinely exists and is queryable, so the placeholder was
factually wrong. `ChannelsCount`/`Channels` replace it.

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
| Schema assembly (§5) incl. calculated columns | Done for Inventory-sourced/calculated columns (37 of 43 columns populated); `EnvironmentGroup`, `OwnerName`/`OwnerUPN`/`OwnerAccountStatus`, `PremiumConnectorCount`, `HasZeroDlpCoverage` are blank pending the steps below |
| `Export-PPXReport` — CSV + `.limitations.txt` sidecar | Done |
| `Resolve-PPXConnectorTier` | Not started (stub) — feeds `PremiumConnectorCount` |
| `Resolve-PPXOwnerIdentity` | Not started (stub) — feeds `OwnerName`/`OwnerUPN`/`OwnerAccountStatus` (raw `OwnerId`/`CreatedByUserId` GUIDs are already included) |
| `Get-PPXDlpCoverageFlag` | Not started (stub) — feeds `HasZeroDlpCoverage` |

Build order so far: Inventory API connectivity → Inventory-only schema assembly and CSV export →
field-path confirmation against a live tenant. Remaining: connector catalog resolution → owner
resolution → DLP boolean, wired into the same `ConvertTo-PPXGovernanceRow` assembly step.

**Field-path confirmation (2026-09-03):** most of §5 was checked against a real tenant response and
corrected where wrong — `LastPublishedAt`'s guessed path (`lastPublishedOn`) was **wrong**, the real
field is `properties.lastPublishedAt`; `SchemaName` and `IsQuarantined` guesses were confirmed
correct; `IdentityModel` is now derived from confirmed `entraAgentId`/`entraAgentBlueprintId`
presence (though its "Legacy Entra app" / "None" branches are still inferred, no live example of
either seen yet); `CapabilitiesTruncated` was rebuilt around the real `capabilitiesCounts` shape
(three named counts, not a generic 200-item dictionary check) and now compares the actual returned
connector array length against the reported count instead of guessing at a hardcoded cap.
`EnvironmentGroup` remains blank — the current Inventory API query's environment `project` clause
(`Connect-PPXInventoryApi.ps1`) does not project it; adding it is a tracked follow-up rather than a
guess against the working query. `Channels`/`Triggers`/`Flows` item-shape (for populated arrays) is
still unconfirmed — only an empty-array example has been seen for all three so far.

## 8. Known limitations

Stated here and, once export exists, in every report run:

- Reflects **published** agent state only; unpublished draft changes are invisible.
- **V1 / Classic** agents are excluded — not present in the Inventory API.
- `CapabilitiesTruncated` flags when the actual `powerPlatformConnectors` array returned is shorter
  than the reported distinct-connector count; Microsoft does not document an exact cap.
- Up to ~15 minutes of replication latency between a real-world change and inventory reflecting it.
- `HasZeroDlpCoverage` is a coverage boolean, not policy detail — not a substitute for a DLP audit.
- `Channels`/`Triggers`/`Flows` list basic identifiers only (and their item shape is unconfirmed for
  populated arrays — only empty examples have been seen); full publishing-channel configuration
  detail is not available through this report.
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
