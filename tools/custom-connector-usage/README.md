# Custom Connector Usage

Tenant-wide report of which Power Platform environments have **custom connectors** — one row per
`(environment × custom connector)`, covering both custom connectors an app/flow/agent references and
custom connectors that merely exist in an environment. Part of the [PPX](../../README.md) tool
collection.

Solution and high-level technical description:
[PPXCustomConnectorUsage.md](../../PPXCustomConnectorUsage.md).

**Status: Experimental.** Both Inventory API pulls (environments, connector-emitting resources) and
the per-environment connectivity-API connector lookup are implemented and wired end-to-end. The
connectivity `$filter` contract (`environment eq '{id}'`) is from community reports, not an official
Microsoft example — confirm it on your first full run. If every row comes back `IsCustomApi =
"Inferred"` after a full-coverage run, the `.limitations.txt` sidecar tells you that's the line to
check.

## Purpose

Produce a single, exportable table showing which environments contain custom connectors, tenant-wide,
enriched with what consumes each one — information that today lives on per-environment maker screens
and is not surfaced tenant-wide in the Power Platform admin center.

## Supported scenarios

- Scoping DLP / connector policy at the start of a governance engagement.
- Finding environments that need a custom-connector review.
- Finding orphaned custom connectors (they exist, nothing references them).
- Spotting premium custom connectors that drive licensing.

Not supported (by design): first-party connector usage, connection-level detail (who authorised, run
recency), operation-level detail, DLP classification, and any write/remediation — this tool is
read-only.

## How it works

Three pulls, one delegated token, all against `https://api.powerplatform.com`:

1. **Inventory API** (`POST /resourcequery/resources/query`) — every environment in the tenant, with
   basic details.
2. **Inventory API** — every connector-emitting resource (canvas apps, model-driven apps, cloud
   flows, agent flows, workflow agent flows, Copilot Studio agents) and its
   `properties.powerPlatformConnectors` array. Both queries return whole records (no `project`
   clause) and follow `skipToken` paging; the loop also stops and marks the report **INCOMPLETE** if
   the service returns consecutive empty pages with a continuation token still pending.
3. **Connectivity API** — `GET /connectivity/environments/{id}/connectors`, once per environment, to
   list the connectors that *exist* there and read the authoritative `properties.isCustomApi` flag
   plus display name / publisher / tier. Per-environment failures (403, environment mid-deletion, …)
   are recorded, not fatal; HTTP 429 is retried, and HTTP 401 triggers one token refresh so a long
   sweep survives token expiry.

The three are merged into one row per `(environment × custom connector)`. See
[Report schema](../../PPXCustomConnectorUsage.md#5-report-schema) for the columns.

## Prerequisites

- PowerShell 5.1+ or PowerShell 7.x
- [`Az.Accounts`](https://www.powershellgallery.com/packages/Az.Accounts) module
  (`Install-Module Az.Accounts -Scope CurrentUser`)

## Required permissions

- Power Platform Administrator or Dynamics 365 Service Administrator role
- Must have signed into the Power Platform admin center at least once

## Usage

First-run setup — the repo ships with no tenant, so set yours (once):

```powershell
# from the repo root
Copy-Item ppx.settings.example.psd1 ppx.settings.psd1   # git-ignored
# then edit ppx.settings.psd1 → Common.TenantId
```

Then:

```powershell
. .\Get-PPXCustomConnectorUsage.ps1
Get-PPXCustomConnectorUsage
# quick partial pull while testing (caps Inventory pages and environments scanned):
Get-PPXCustomConnectorUsage -MaxPages 1 -MaxEnvironments 5 -Verbose
# fast, Inventory-only (no per-environment connectivity calls — heuristic classification only):
Get-PPXCustomConnectorUsage -SkipEnvironmentConnectorLookup
# also list environments that have NO custom connectors (one placeholder row each):
Get-PPXCustomConnectorUsage -IncludeAllEnvironments
# skip writing a CSV, just get the rows back:
Get-PPXCustomConnectorUsage -ExportReport:$false
# choose where the CSV lands:
Get-PPXCustomConnectorUsage -OutputPath C:\reports\my-tenant.csv
```

**Large tenants:** the Inventory queries follow `skipToken` paging automatically (`-Top` is the
per-request page size, not a total cap; `-MaxPages` / `CustomConnectorUsage.MaxPages` caps the loop
and marks the report INCOMPLETE when it bites, as does a 1000-page hard cap or a run of empty pages).
Long runs refresh the delegated token once on an HTTP 401. The per-environment connectivity loop is
**one call per environment** and dominates run time on a large tenant — `-MaxEnvironments` /
`CustomConnectorUsage.MaxEnvironments` caps it for testing; when it does, the `.limitations.txt`
sidecar flags coverage as **PARTIAL**.

The function throws with setup instructions if no tenant ID is resolved. It signs in interactively
via `Connect-AzAccount` (only when there is no usable Az context), writes a CSV to `reports\` at the
repo root (git-ignored; override with `-OutputPath` or `CustomConnectorUsage.OutputPath`) along with
a `.limitations.txt` sidecar describing this run's gaps, and returns the shaped rows.

Tenant selection and other knobs come from the shared settings file — see
[SETTINGS.md](../../SETTINGS.md), including the **Authentication** section.

## Known limitations

- `IsCustomApi = "True"` is authoritative (connectivity API `properties.isCustomApi`).
  `IsCustomApi = "Inferred"` comes from the connector-ID-shape heuristic
  (`Test-PPXCustomConnectorId.ps1`) and appears only for environments whose connectivity lookup was
  skipped or failed.
- `IsReferencedByResource` / `ConsumingResources` come from `properties.powerPlatformConnectors`,
  emitted only by canvas apps, model-driven apps, cloud flows, agent flows, workflow agent flows,
  and Copilot Studio agents. A custom connector used **only** by a code app, vibe app, or App
  Builder app shows `IsReferencedByResource = False` even though it is in use.
- Built-in actions (HTTP, Control, Data Operations) are not connectors and never appear.
- Referenced-vs-existing matching is done on a normalised connector base name
  (`Get-PPXNormalizedConnectorKey.ps1`) because the Inventory usage array and the connectivity API
  format the connector's suffix differently; two different custom connectors whose base names
  collide within one environment would merge into one row.
- "In use" means referenced by a resource definition and/or present in the environment — not that a
  connection exists, is authorised, or has run recently.
- `ConnectorTier` / `ConnectorPublisher` / `ConnectorName` are blank on `Inferred` rows.
- Up to ~15 minutes of replication latency on the Inventory data;
  `properties.powerPlatformConnectors` is Microsoft **Preview** status.
- Auth is interactive delegated only; unattended auth is not supported against these endpoints.
- Every run's specific gaps are restated in the `.limitations.txt` file written alongside the CSV.

## Security considerations

- No secrets or credentials are stored; Az PowerShell handles interactive token acquisition and
  caching.
- Read-only: no write/remediation operations anywhere in this tool.
