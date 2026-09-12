# 0005 — Custom Connector Usage: data sources and paging bring-up

**Status:** Resolved · **First landed:** post-0.1.0

## Context

`Get-PPXCustomConnectorUsage` reports, per `(environment × custom connector)`, both connectors an
app/flow/agent *references* and connectors that merely *exist* in an environment (created/imported
but unused).

## Decision — three data pulls, not one

1. **Inventory API** — every environment + basic details.
2. **Inventory API** — every connector-emitting resource (canvas apps, model-driven apps, cloud
   flows, agent flows, M365 agent flows, Copilot Studio agents) with its
   `properties.powerPlatformConnectors` array.
3. **Connectivity API**
   (`GET /connectivity/environments/{id}/connectors?$filter=environment eq '{id}'&api-version=2024-10-01`),
   once per environment — the connectors that **exist** there, the authoritative
   `properties.isCustomApi` flag, and display name/publisher/tier/created time.

**Why not just the Inventory connector catalogue:** the Inventory
`microsoft.powerplatformconnector/connectors` type is tenant-level with no environment association,
and the per-resource usage array only shows connectors something *references* — neither can answer
"which custom connectors exist in this environment." The connectivity API is environment-scoped,
hence the per-environment loop (with 429 retry honouring `Retry-After`, and per-environment errors
recorded rather than aborting the run).

Connector IDs differ in shape between the two APIs (`shared_x-<hex>` in Inventory usage vs.
`shared_x.<hex>.<hex>` in connectivity) — `Get-PPXNormalizedConnectorKey.ps1` normalises both to
match; base-name collisions within one environment are merged and noted in the sidecar.
`isCustomApi` truthiness is matched tolerantly (`$true` or the string forms) so a string value from
the API doesn't silently drop a real custom connector.

**Known open item:** the connectivity `$filter=environment eq '{id}'` contract is from community
reports, not an official Microsoft sample (their docs omit the request body). Capped test runs
returned HTTP 200; a full-coverage run confirming authoritative `IsCustomApi = True` rows is still
pending.

## Bring-up fixes (first real-tenant run)

- **Runaway `skipToken` paging.** The connector-usage query used a `project` clause with aliased
  columns (including the dynamic `connectors = properties.powerPlatformConnectors` array) and
  ordered by the projected aliases. Against a live tenant, Azure Resource Graph never stopped
  paging — near-zero rows per page, observed at page 2,798, by which point the delegated token had
  expired (`AADSTS500133: Assertion is not within its valid time range`). **Fix:** both queries now
  match the Agent Governance Baseline tool's proven shape — no `project`,
  `orderby tostring(properties.createdAt) desc, name asc` on materialised columns — and rows are
  built by reading raw fields (`name`/`type`/`properties.*`/`location`) instead of projected
  aliases. This query/pagination combination is the same one investigated in
  [ADR-0003](0003-pagination-strategy.md); a `project` clause with aliased ordering appears to be
  what breaks `skipToken` convergence specifically.
- **No non-progress guard.** `Connect-PPXInventoryApi.ps1` now stops (marking `resultTruncated`)
  after three consecutive empty pages with a continuation token still pending; the hard page cap was
  lowered from 5000 to 1000; progress prints every 10 pages.
- **Token expiry on long runs.** This tool had its own copy of `Connect-PPXInventoryApi.ps1` that
  hadn't received the token-refresh-on-401 fix from [ADR-0003](0003-pagination-strategy.md) — a
  reminder that the shared logic is currently duplicated per tool
  (`tools/_shared/` extraction is a tracked follow-up). Fixed here via a shared `-TokenFactory`
  scriptblock, refreshed once on HTTP 401. The factory must be a **plain** scriptblock — an initial
  `.GetNewClosure()` rebound it to a module scope where the dot-sourced token function wasn't
  visible, cascading into an empty `Bearer` header and a 401.

## Consequences

Until `tools/_shared/` extraction happens, any bug fixed in one tool's copy of
`Connect-PPXInventoryApi.ps1` (or the token-refresh pattern) needs to be checked against the other
tools' copies — this tool shipped without a fix that had already landed elsewhere.
