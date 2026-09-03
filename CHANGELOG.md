# Changelog

Technical change history for the PPX Agent Admin Tools repository. For usage and an overview, read
[README.md](README.md); for settings and authentication, [SETTINGS.md](SETTINGS.md).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Releases are not tagged yet —
**0.1.0** documents the initial development baseline.

---

## [Unreleased]

### Agent Governance Baseline — schema assembly and CSV export

`Get-PPXAgentGovernanceBaseline` now writes a governance-baseline CSV (plus a sidecar
`.limitations.txt` file) instead of returning the raw Inventory API response. This is an
**Inventory-only** pass: owner resolution, DLP coverage, and connector-tier resolution
(`Resolve-PPXOwnerIdentity`, `Get-PPXDlpCoverageFlag`, `Resolve-PPXConnectorTier`) remain
unimplemented, so `OwnerName`/`OwnerUPN`/`OwnerAccountStatus`, `PremiumConnectorCount`, and
`HasZeroDlpCoverage` are blank (`''`, never `$false`/`0`/`'Unknown'`, to avoid a blank being misread
as a real finding) in every row.

- **`tools/agent-governance-baseline/private/Get-PPXNestedValue.ps1`** — new. Safe dotted-path reader
  (`'properties.createdAt'`) used for every field lookup; returns a default instead of throwing or
  mis-shaping the result when an intermediate segment is missing or turns out to be a collection.
- **`tools/agent-governance-baseline/private/ConvertTo-PPXGovernanceRow.ps1`** — new. Maps one joined
  Inventory API record to a flat §5 row. `SchemaName`, `LastPublishedAt`, `IsQuarantined`, and
  `IdentityModel` use best-guess field paths — **no live Inventory API response has been captured and
  inspected in this repo**, so these are unverified; correct them here once confirmed against a real
  tenant. `EnvironmentGroup` is blank because the current `Connect-PPXInventoryApi` query doesn't
  project it (left as a follow-up rather than guessing at a change to the working query).
- **`tools/agent-governance-baseline/private/Export-PPXReport.ps1`** — rewritten from a stub. Resolves
  an output path (folder → auto-named timestamped file, or an explicit `.csv` path), writes the CSV
  with `Export-Csv -Encoding utf8BOM` on PS7+ / `UTF8` on 5.1 (PS7's default `UTF8` omits the BOM,
  which makes Excel mis-render accented characters), and writes a `.limitations.txt` sidecar (static
  §8 items + this run's dynamic notes) rather than appending prose into the CSV, since a CSV has no
  comment syntax and stray rows would conflict with the "no post-processing" goal (§3). Also runs a
  same-run sanity check: if a best-guess/calculated column is blank/zero/`'Unknown'` across every row,
  it `Write-Warning`s and logs it in the sidecar, so a wrong guessed path surfaces automatically
  instead of requiring someone to notice.
- **`Get-PPXAgentGovernanceBaseline.ps1`** — new `-OutputPath` parameter (same
  parameter-then-settings-fallback pattern as `-TenantId`/`-Top`); now calls `Export-PPXReport` and
  returns the shaped rows instead of the raw inventory envelope.
- **`ppx.settings.example.psd1`** — added `AgentGovernanceBaseline.OutputPath` (blank = default
  `reports\` folder at the repo root).
- **`.gitignore`** — added `/reports/` (generated, tenant-specific CSV + limitations output).

### Agent Governance Baseline — `ExportReport` opt-out setting

- **`Get-PPXAgentGovernanceBaseline.ps1`** — new `-ExportReport` parameter (`[bool]`, default `$true`).
  When `$false`, the function still queries the Inventory API and shapes the rows, but skips writing
  the CSV / `.limitations.txt` sidecar entirely and just returns the rows in memory.
- **`ppx.settings.example.psd1`** / **`ppx.settings.psd1`** — added
  `AgentGovernanceBaseline.ExportReport = $true`.
- **`tools/_shared/Get-PPXSettings.ps1`** — fixed the "unset" drop logic. It previously dropped any
  setting value that compared equal to `0`, which in PowerShell also matches `$false`
  (`$false -eq 0` is `$true`) — so an explicit `ExportReport = $false` in the settings file would have
  been silently discarded and treated as "not set," defeating a default-`$true`-but-overridable-false
  setting. Now only `$null`, `''`, and genuinely numeric `0` are treated as unset; `$false` (and
  `$true`) always survive. The settings-file header comments in both `.psd1` files were updated to
  match. `Get-PPXAgentGovernanceBaseline.ps1`'s settings fallback for `ExportReport` uses
  `$settings.ContainsKey(...)` rather than truthiness, since truthiness alone still can't tell "unset"
  apart from "explicitly false."

## [0.1.0] — 2026-09-03

First working version of the **Agent Governance Baseline** tool (Inventory API connectivity only),
plus the shared settings, authentication, and developer-tooling scaffolding the rest of the tool
collection builds on.

### Agent Governance Baseline — Inventory API connectivity

`Get-PPXAgentGovernanceBaseline` (entry point) → `Connect-PPXInventoryApi` (private) now performs a
successful authenticated query and returns the raw agent + environment records. Connector-tier
resolution, owner resolution, the DLP coverage flag, §5 schema assembly, and export remain
unimplemented (`# TODO` markers in `private/*.ps1`).

#### Inventory API request contract

The initial scaffold posted an invented `{ select, from, where }` body to an URL with no
`api-version`, and never succeeded. Corrected to the documented Azure Resource Graph query-object
("KQLOM") contract:

- **Endpoint** — `POST https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01`.
  The `api-version` query parameter is mandatory; omitting it returns `HTTP 400 (Bad Request)`.
- **Body shape** — `{ TableName: 'PowerPlatformResources', Options: { Top, Skip }, Clauses: [ … ] }`.
  `Clauses` is an array of typed clause objects (`extend`, `join`, `where`, `project`, `orderby`).
- **`$type` discriminator must be the first property of every clause object.** The service
  deserialises `Clauses` polymorphically (System.Text.Json), which reads the type discriminator as
  the leading property. A PowerShell `@{}` hashtable has no guaranteed key order, so `ConvertTo-Json`
  emitted `$type` in arbitrary positions and the service returned
  `400 … KQLOM format is wrong or it cannot be null`. Every clause object is now built with
  `[ordered]@{ '$type' = …; … }`.
- **Resource type** — Copilot Studio V2 agents are `microsoft.copilotstudio/agents`. The scaffold
  used `microsoft.copilotstudio/bots`, which is not a valid inventory resource type.
- **Query** — mirrors the Power Platform admin center default pattern:
  `extend joinKey = tolower(tostring(properties.environmentId))` →
  `join kind=leftouter` to a `PowerPlatformResources` sub-query filtered to
  `microsoft.powerplatform/environments` and projecting
  `environmentName / environmentType / isManagedEnvironment / environmentRegion` →
  `where type in~ ('microsoft.copilotstudio/agents')` →
  `orderby tostring(properties.createdAt) desc`.
  Agent-side fields are returned whole (no `project` clause) pending the §5 shaping step.
- **Response envelope** — `{ totalRecords, count, resultTruncated, skipToken, data[] }`. Records are
  in `data`; the scaffold read `value`.
- **Paging** — `Options.Top` defaults to `1000`; `-Top` / `AgentGovernanceBaseline.Top` override it.
  `skipToken` continuation is not implemented yet.
- **Error surfacing** — `Invoke-RestMethod` on PowerShell 7 raises `HttpResponseException` with the
  response body in `$_.ErrorDetails.Message`; Windows PowerShell 5.1 exposes it via
  `$_.Exception.Response.GetResponseStream()`. The `catch` block now reads `ErrorDetails.Message`
  first and falls back to the stream, then rethrows with the API's specific message appended.

#### Authentication — switched from MSAL.PS to Az.Accounts

- `Connect-PPXInventoryApi` now depends on **`Az.Accounts`** and acquires the token with
  `Connect-AzAccount` + `Get-AzAccessToken -ResourceUrl https://api.powerplatform.com`.
- **Rationale.** The scaffold used MSAL.PS with client id
  `8578e004-a5c6-46e7-913e-12f58912df43`. That GUID is the Power Platform API *resource*
  application, not a client. Requesting scope `https://api.powerplatform.com/.default` while
  authenticating *as* that same app produces
  `AADSTS90009: Application '…' is requesting a token for itself`. Microsoft publishes no sample
  public client for this API, so the tool borrows the already-consented Az PowerShell first-party
  client and avoids requiring every user to register an Entra app. The app-registration route is
  documented as Option B in [SETTINGS.md](SETTINGS.md#authentication).
- **Context reuse.** `Connect-AzAccount` runs only when `Get-AzContext` is empty or bound to a
  different tenant; otherwise the cached Az context is reused with no prompt.
- **Token type.** `Get-AzAccessToken` returns `Token` as a `SecureString` on Az.Accounts 5.x and as
  a plain string on earlier versions; the connect script unwraps both.
- **Device-code sign-in.** Added `-UseDeviceAuthentication` (and `Common.UseDeviceAuthentication`).
  The interactive WAM browser prompt (`Please select the account you want to login with.`) hangs
  inside the VS Code PowerShell Integrated Console / debugger because the native dialog cannot
  attach to the embedded console; device-code flow works there.
- **Tenant is required.** `Get-PPXAgentGovernanceBaseline` throws with setup instructions when no
  tenant id resolves from `-TenantId` or the settings file. No tenant id is committed to the repo.

### Shared settings system

- **`ppx.settings.example.psd1`** — committed template documenting every key with safe defaults;
  `TenantId` ships blank.
- **`ppx.settings.psd1`** — per-user copy, git-ignored, holds real values.
- **`tools/_shared/Get-PPXSettings.ps1`** — `Get-PPXSettings [-Section <name>] [-Refresh]`:
  - walks up from its own folder to locate `ppx.settings.psd1` (falls back to
    `ppx.settings.example.psd1`);
  - parses with `Import-PowerShellDataFile` (data only — no code execution);
  - caches the parsed file per session (`-Refresh` re-reads);
  - returns `Common` merged with the requested tool section, section winning on key collisions;
  - drops keys whose value is `''`, `0`, `$false`, or `$null` so callers can use a plain truthiness
    check.
- **Precedence** — explicit parameter → tool section → `Common` → tool/API default. Tools apply
  settings only for parameters not present in `$PSBoundParameters`.
- **Keys this version** — `Common.TenantId` (required), `Common.UseDeviceAuthentication` (bool),
  `AgentGovernanceBaseline.TenantId` (optional per-tool override), `AgentGovernanceBaseline.Top`
  (int; `0` = API default).

### Developer tooling

- **`.vscode/launch.json`** — `PPX: Debug Governance Baseline` (primary), plus generic
  `PowerShell: Current File` and `PowerShell: Interactive Session` configurations.
- **`tools/agent-governance-baseline/Debug-GovernanceBaseline.ps1`** — debug harness (git-ignored
  via `Debug-*.ps1`). `Get-PPXAgentGovernanceBaseline.ps1` only *defines* the function, so pressing
  F5 on that file loads the function and exits without hitting breakpoints. The harness dot-sources
  the file and invokes the function; breakpoints in the function and in `private/*.ps1` are matched
  by path and hit.

### Repository hygiene

- **`.gitignore`** — added `/ppx.settings.psd1` (holds tenant-specific values) and `Debug-*.ps1`
  (local debug harnesses) alongside the existing `/Internal-Docs/` rule.

### Documentation

- **`README.md`** — reoriented as the general overview: tool description and status, quick start,
  prerequisites, configuration, repository layout, development pointers.
- **`SETTINGS.md`** — new. Settings file model, resolution order, key reference, an **Authentication**
  section (Az PowerShell flow, the AADSTS90009 explanation, the VS Code debugger sign-in options,
  and the Entra app-registration alternative), a troubleshooting table, and contributor guidance for
  adding a setting or a tool.
- **`tools/agent-governance-baseline/README.md`** — prerequisites updated to `Az.Accounts`; usage
  updated for the required-tenant first-run flow and `Connect-AzAccount` sign-in.
- **`CHANGELOG.md`** — this file.
