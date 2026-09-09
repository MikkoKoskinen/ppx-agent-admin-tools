# PPX Custom Connector Usage — Solution Description

Solution and high-level technical description for the **Custom Connector Usage** tool. For how to
run it, see [tools/custom-connector-usage/README.md](tools/custom-connector-usage/README.md); for
settings and authentication, [SETTINGS.md](SETTINGS.md); for the technical change history,
[CHANGELOG.md](CHANGELOG.md).

**Status:** experimental. Both Inventory API pulls (environments, connector-emitting resources) and
the per-environment connectivity-API connector lookup are implemented and wired end-to-end. The
connectivity `$filter` contract (`environment eq '{id}'`) is taken from community reports rather than
an official Microsoft example and should be confirmed against a live tenant on first run — the
`.limitations.txt` sidecar calls this out automatically if every row comes back heuristic.

---

## 1. Purpose

Give a Power Platform governance engagement a single, exportable table of **which environments have
custom connectors**, tenant-wide — covering both custom connectors that an app / flow / agent
references and custom connectors that merely exist in an environment (created or imported but not yet
used). This is scattered across per-environment maker screens today and is not surfaced tenant-wide
in the Power Platform admin center.

It is a point-in-time, **read-only** report. It performs no write or remediation actions.

## 2. Audience and scenarios

- **Governance leads** scoping DLP and connector policy — a custom connector is an
  organisation-authored egress path that tenant-level connector catalogues don't describe.
- **Platform admins** finding environments that need a custom-connector review, orphaned custom
  connectors (exist, nothing uses them), or premium custom connectors driving licensing.

## 3. Goals

- One command produces one flat, exportable table (CSV / Excel), tenant-wide.
- One row per **(environment × custom connector)** so the result filters and pivots per connector,
  per environment, or per environment group with no post-processing.
- Cover custom connectors that exist but are unreferenced, not just ones in active use.
- State every known data limitation **in the report output**, not as a silent gap.

## 4. Scope

### In scope

- Every environment in the tenant, with basic details (name, type, managed flag, environment group,
  region).
- Custom connectors that **exist** in each environment (`properties.isCustomApi = true` from the
  connectivity API), with display name, publisher, tier, and created time.
- Custom connectors **referenced** by a connector-emitting resource (canvas app, model-driven app,
  cloud flow, agent flow, workflow agent flow, Copilot Studio agent), with the consuming resources
  and a per-type breakdown.
- A per-row signal for how "custom" was determined (authoritative vs inferred) and whether the
  environment's connector list was actually retrieved.

### Out of scope (by design, this phase)

| Not included | Why / where it lives |
| --- | --- |
| First-party / certified connector usage | This tool is custom-connector-focused; a broader connector inventory is a separate tool |
| Connection-level detail (who authorised, run recency) | `properties.powerPlatformConnectors` and the connector list describe definitions and catalogue membership, not connection instances |
| Operation-level (which actions of the connector are called) | The Inventory usage array carries operation IDs, but they are not a governance signal at the environment level |
| Custom connectors used only by code apps / vibe apps / App Builder apps | Those resource types do not emit `powerPlatformConnectors`; such a connector still appears via the connectivity API but shows `IsReferencedByResource = False` |
| DLP classification of each custom connector | Referenced only indirectly; full DLP reporting is separate |
| Any write / remediation | Read-only by design |

## 5. Report schema

One row per **(environment × custom connector)**. By default only environments with at least one
custom connector produce rows; `-IncludeAllEnvironments` adds one placeholder row per clean
environment (blank `ConnectorId`, `DetectionSource = (none)`).

### Environment (basic details)

| Column | Source | Notes |
| --- | --- | --- |
| `EnvironmentName` | Inventory environments query, `properties.displayName` | |
| `EnvironmentId` | Inventory environments query, `name` | GUID |
| `EnvironmentType` | Inventory, `properties.environmentType` | Production / Sandbox / Trial / Developer / Default / Dataverse for Teams |
| `IsManagedEnvironment` | Inventory, `properties.isManaged` | |
| `EnvironmentGroup` | Inventory, `properties.environmentGroup` | Blank if not assigned |
| `EnvironmentGroupId` | Inventory, `properties.environmentGroupId` | |
| `EnvironmentRegion` | Inventory, `location` | |

### Connector

| Column | Source | Notes |
| --- | --- | --- |
| `ConnectorId` | Connectivity API `name`, else the raw `connectorId` from the usage array | Blank only on an `-IncludeAllEnvironments` placeholder row |
| `ConnectorName` | Connectivity API `properties.displayName` | Blank on `Inferred` rows |
| `ConnectorPublisher` | Connectivity API `properties.publisher` | Blank on `Inferred` rows |
| `ConnectorTier` | Connectivity API `properties.tier` | `Standard` / `Premium`; blank on `Inferred` rows |
| `ConnectorCreatedTime` | Connectivity API `properties.createdTime` | ISO 8601; blank on `Inferred` rows |

### Classification / provenance

| Column | Values | Meaning |
| --- | --- | --- |
| `IsCustomApi` | `True` / `Inferred` / *(blank)* | `True` = authoritative, from the connectivity API `properties.isCustomApi`. `Inferred` = from the ID-shape heuristic (`Test-PPXCustomConnectorId`), used only when the connectivity lookup for that environment was skipped or failed. Blank on a placeholder row. |
| `ExistsInEnvironmentList` | `True` / `False` / `Unknown (lookup failed)` / `Unknown (lookup skipped)` / `n/a (no custom connectors)` | Whether the connector was returned by `GET /connectivity/environments/{id}/connectors`. `Unknown` when that call failed (403, mid-deletion, …) or was skipped (`-SkipEnvironmentConnectorLookup` / `-MaxEnvironments`). |
| `IsReferencedByResource` | `True` / `False` | Whether some app / flow / agent's `powerPlatformConnectors` array references this connector. |
| `DetectionSource` | `ConnectivityApi` / `UsageHeuristic` / `Both` / `(none)` | Which surface produced the row. `Both` = it exists in the environment *and* a resource references it. |

### Usage

| Column | Source | Notes |
| --- | --- | --- |
| `ConsumingResourceCount` | Calculated | Distinct resources referencing this connector in this environment |
| `ConsumingResourcesByType` | Calculated | e.g. `canvasapps=2; cloudflows=3; agents=1` |
| `ConsumingResources` | Calculated | `; `-joined `"<name> (<type>)"`, capped at 15 with a `...(+N more)` tail |

## 6. Technical design (high level)

### 6.1 Pipeline

```
Get-PPXCustomConnectorUsage                entry point (tools/custom-connector-usage/)
 ├─ Get-PPXPowerPlatformToken   Az context reuse + delegated token for api.powerplatform.com
 ├─ Connect-PPXInventoryApi     POST resourcequery — every environment + basic details
 ├─ Connect-PPXInventoryApi     POST resourcequery — every connector-emitting resource + its
 │                              powerPlatformConnectors array (both follow skipToken paging)
 ├─ Get-PPXEnvironmentConnector GET /connectivity/environments/{id}/connectors, once per
 │                              environment — connectors that EXIST there + isCustomApi + metadata
 ├─ ConvertTo-PPXConnectorUsageRow   merge existence + usage into one row per (env × custom connector)
 └─ Export-PPXReport            flat CSV + .limitations.txt sidecar
 helpers: Get-PPXNestedValue, Get-PPXNormalizedConnectorKey (matches the two APIs' differing id
          suffix formats), Test-PPXCustomConnectorId (ID-shape fallback), ConvertTo-PPXJoinedList
```

One delegated token is acquired once and reused for all three pulls. The whole run is idempotent and
read-only.

### 6.2 Data sources

| Source | Role |
| --- | --- |
| **Power Platform Inventory API** — `POST /resourcequery/resources/query` | Environment list + basic details; every connector-emitting resource's `properties.powerPlatformConnectors` array |
| **Power Platform connectivity API** — `GET /connectivity/environments/{id}/connectors` | Per environment: the connectors that exist there, the authoritative `properties.isCustomApi` flag, and connector display name / publisher / tier / created time |

The Inventory API alone cannot answer "which custom connectors exist here" — its connector *catalogue*
resource type (`microsoft.powerplatformconnector/connectors`) is tenant-level and carries no
environment association, and its per-resource usage array only shows connectors something references.
The connectivity API closes that gap; it is environment-scoped, hence the per-environment loop.

### 6.3 Authentication

Interactive **delegated** (user) authentication, obtained through **Az PowerShell**:
`Connect-AzAccount` (only when there is no usable Az context) then
`Get-AzAccessToken -ResourceUrl https://api.powerplatform.com`. Both APIs share that resource, so one
token serves the whole run. A device-code option (`UseDeviceAuthentication`) exists for environments
where the interactive browser prompt cannot render, such as the VS Code debugger.

Service-principal / unattended auth against the resource-query endpoint is a known platform
limitation and is not implemented. Full detail:
[SETTINGS.md § Authentication](SETTINGS.md#authentication).

### 6.4 Inventory API query approach

Two structured (KQLOM) queries against `POST /resourcequery/resources/query?api-version=2024-10-01`,
both in the same shape the Agent Governance Baseline tool uses:

- **Environments** — `where type == 'microsoft.powerplatform/environments'`.
- **Connector-emitting resources** —
  `where type in~ ('microsoft.powerapps/canvasapps', 'microsoft.powerapps/modeldrivenapps',
  'microsoft.powerautomate/cloudflows', 'microsoft.powerautomate/agentflows',
  'microsoft.powerautomate/m365agentflows', 'microsoft.copilotstudio/agents')`.

Both then `orderby tostring(properties.createdAt) desc, name asc` and **no `project` clause** — whole
records come back and every field is read off the raw shape (`name`, `type`, `properties.*`,
`location`) in `ConvertTo-PPXConnectorUsageRow`.

The `project`-less shape is deliberate. An earlier version projected aliased columns (`resourceId =
name`, …) including the dynamic `connectors = properties.powerPlatformConnectors` array and ordered
by the projected aliases; against a real tenant that made Azure Resource Graph's `skipToken` paging
**never terminate** — the service kept returning a continuation token with near-zero rows per page
(thousands of pages, long enough for the delegated token to expire mid-run). Matching the first
tool's proven pattern (no project, order by materialised columns) fixes it.

`Connect-PPXInventoryApi` follows the `skipToken` continuation until the service stops returning one,
concatenating all pages into one synthesised envelope
`{ totalRecords, count, resultTruncated, skipToken, pagesRetrieved, data[] }`. It also stops — and
marks `resultTruncated` — if `-MaxPages` is hit, a 1000-page hard cap is reached, **or three
consecutive pages come back empty with a continuation token still pending** (the non-terminating
case above, so a pathological query can no longer run the token to death). The KQLOM clause set has
**no `mv-expand`**, so the `powerPlatformConnectors` array is expanded client-side.

### 6.5 Connectivity API approach

`GET https://api.powerplatform.com/connectivity/environments/{environmentId}/connectors?$filter=environment eq '{environmentId}'&api-version=2024-10-01`

- One call per environment (capped by `-MaxEnvironments`, skipped entirely by
  `-SkipEnvironmentConnectorLookup`).
- Response: `{ value: [ { id, name, type, properties } ] }`. `properties.isCustomApi` is the
  authoritative custom flag; `properties.displayName / publisher / tier / createdTime` supply the
  metadata the Inventory usage array lacks.
- HTTP 429 is retried a few times honouring `Retry-After`. HTTP 401 triggers one token refresh
  (`Get-PPXPowerPlatformToken` again) and a retry — a sweep over hundreds of environments can outlive
  the first token. Any other error is recorded per environment and the run continues — it must not
  abort because one environment 403s or is mid-deletion. Failed environments get
  `ExistsInEnvironmentList = "Unknown (lookup failed)"` and are listed in the `.limitations.txt`
  sidecar.
- The `$filter` value (`environment eq '{id}'`) is documented by community reports, not an official
  Microsoft example. If every row comes back `Inferred` after a full-coverage run, that is the line
  to verify — the sidecar says so.

The same one-shot 401 refresh is wired into `Connect-PPXInventoryApi`; both APIs take a shared
`-TokenFactory` scriptblock from the entry point so a long run re-acquires the token rather than
failing.

### 6.6 Matching the two surfaces

A connector seen in the Inventory usage array and the same connector returned by the connectivity
API have **differently formatted suffixes** (`shared_contosocrm-5f2e…` vs
`shared_contosocrm.5f2e….9f9f`). `Get-PPXNormalizedConnectorKey` reduces both to the connector's
base name (lowercase, drop `shared_`, drop everything from the first `.`/`-`). Two *different* custom
connectors whose base names collide within one environment would merge into one row — rare, and
noted in the sidecar.

### 6.7 Output

A flat CSV, one row per (environment × custom connector), plus a sibling `<name>.limitations.txt`
carrying the static §8 limitations and this run's dynamic notes: Inventory paging completeness, how
many environments the connectivity lookup actually covered (with an explicit **PARTIAL** flag when
`-MaxEnvironments` capped it), every per-environment lookup failure, and whether the report is
authoritative or heuristic. Same two-file pattern, and the same reasoning, as the Agent Governance
Baseline tool (a plain CSV has no comment syntax).

### 6.8 Configuration

All runtime knobs come from the shared settings file (`ppx.settings.psd1`, section
`CustomConnectorUsage`, falling back to `Common`): tenant ID (required), Inventory page size (`Top`)
and paging cap (`MaxPages`), environment-scan cap (`MaxEnvironments`),
`SkipEnvironmentConnectorLookup`, auth mode, output path, `IncludeAllEnvironments`, and
`ExportReport`. Precedence is explicit parameter → settings file → tool/API default. See
[SETTINGS.md](SETTINGS.md).

## 7. Implementation status

| Component | State |
| --- | --- |
| Settings resolution, tenant enforcement, orchestration | Done |
| `Get-PPXPowerPlatformToken` — Az auth + delegated token | Done |
| `Connect-PPXInventoryApi` — query-agnostic wrapper + skipToken paging | Done (copied from the Agent Governance Baseline tool, parameterised by `-Clauses`); non-terminating-paging guard and one-shot 401 token refresh added during bring-up |
| Environments + connector-usage Inventory queries | Done (rewritten `project`-less to fix runaway `skipToken` paging — see §6.4) |
| `Get-PPXEnvironmentConnector` — connectivity API + 429/401 retry + per-env error capture | Done; `$filter` contract needs live confirmation |
| `ConvertTo-PPXConnectorUsageRow` — merge existence + usage, one row per (env × connector) | Done (reads the raw record shape) |
| `Export-PPXReport` — CSV + `.limitations.txt` sidecar | Done |
| Full-tenant run confirmation (authoritative `IsCustomApi = True` rows observed) | Pending — bring-up runs hit the paging bug (since fixed) and a token-factory scoping bug (since fixed); a clean full-coverage run has not completed yet |

## 8. Known limitations

Stated here and in every report run:

- `IsCustomApi = "True"` is authoritative (connectivity API `properties.isCustomApi`).
  `IsCustomApi = "Inferred"` comes from the ID-shape heuristic (`Test-PPXCustomConnectorId`) and
  appears only for environments whose connectivity lookup was skipped or failed. Heuristic risks: a
  first-party ID that happens to end in `-<hex>` is a false positive; a custom connector promoted to
  a suffix-less `shared_<name>` ID is a false negative.
- `IsReferencedByResource` / `ConsumingResources` come from `properties.powerPlatformConnectors`,
  emitted only by canvas apps, model-driven apps, cloud flows, agent flows, workflow agent flows,
  and Copilot Studio agents. A custom connector used **only** by a code app, vibe app, or App Builder
  app shows `IsReferencedByResource = False` even though it is in use.
- Built-in actions (HTTP, Control, Data Operations) are not connectors and never appear.
- Referenced-vs-existing matching is done on a normalised base name (§6.6); base-name collisions
  within one environment merge rows.
- "In use" here means referenced by a resource definition and/or present in the environment — not
  that a connection exists, is authorised, or has run recently.
- `ConnectorTier` / `ConnectorPublisher` / `ConnectorName` are blank on `Inferred` rows.
- Up to ~15 minutes of replication latency on the Inventory data.
- `powerPlatformConnectors` is Microsoft **Preview** status and may change shape without notice.
- The per-environment connectivity loop is N sequential calls; on a large tenant it dominates the
  run time. `-MaxEnvironments` caps it for testing (the report is then flagged PARTIAL).
- If an Inventory query's `skipToken` paging fails to converge (three consecutive empty pages, the
  1000-page hard cap, or `-MaxPages`), the run stops and the report is marked **INCOMPLETE** in the
  sidecar rather than looping until the token expires.
- Authentication is interactive delegated only; unattended auth is not supported against these
  endpoints at time of writing.

## 9. Dependencies

- PowerShell 5.1+ (Windows PowerShell) or 7.x
- `Az.Accounts` — sign-in and token acquisition
- Permissions: Power Platform Administrator (or Dynamics 365 Service Administrator); must have signed
  into the Power Platform admin center at least once

## 10. Relationship to other tools

Independent and self-contained, like every PPX tool. The auth + skipToken-paging code in
`Connect-PPXInventoryApi.ps1` is a deliberate copy of the same file in the Agent Governance Baseline
tool (parameterised here by `-Clauses`); extracting the shared machinery to `tools/_shared/` is a
tracked follow-up for both. A future first-party / all-tier connector inventory would reuse this
tool's connectivity-API step.

## References

- [Power Platform inventory API](https://learn.microsoft.com/en-us/power-platform/admin/inventory-api)
- [Power Platform inventory schema reference](https://learn.microsoft.com/en-us/power-platform/admin/inventory-schema)
- [Power Platform REST API — Connectivity / Connectors — List Connectors](https://learn.microsoft.com/en-us/rest/api/power-platform/connectivity/connectors/list-connectors)
- [Custom connectors overview](https://learn.microsoft.com/en-us/connectors/custom-connectors/)
- [Programmability and extensibility — authentication (v2)](https://learn.microsoft.com/en-us/power-platform/admin/programmability-authentication-v2)
