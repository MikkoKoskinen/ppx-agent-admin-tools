# Changelog

Technical change history for the PPX Agent Admin Tools repository. For usage and an overview, read
[README.md](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/README.md); for settings and authentication, [SETTINGS.md](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/SETTINGS.md). For the reasoning
behind non-obvious decisions and bug investigations, see [docs/decisions/](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/docs/decisions/README.md).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). This is the first tagged release.

---

## [Unreleased]

Nothing yet.

## [0.1.0] — 2026-09-13

First tagged release. This release officially covers **Agent Governance Baseline**, which is
production-tested. **Custom Connector Usage** and **Copilot Credit — Tenant Pool Draw** ship in the
same tag but are early-stage previews (Experimental and Dev in Progress respectively) — not part of
what this release considers ready for use. See the status table in [README.md](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/README.md#tools).

### Added

- `Get-PPXAgentGovernanceBaseline` / `Connect-PPXInventoryApi`: authenticated query against the Power
Platform Inventory API. See
[ADR-0001](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/docs/decisions/0001-inventory-api-request-contract.md).
- Authentication via `Az.Accounts` (`Connect-AzAccount` + `Get-AzAccessToken`), including
device-code sign-in for the VS Code debugger. See
[ADR-0002](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/docs/decisions/0002-authentication-az-accounts.md).
- Shared settings system (`ppx.settings.psd1`, `tools/_shared/Get-PPXSettings.ps1`) with
parameter → tool section → `Common` → default precedence.
- **Owner identity resolution** (`Resolve-PPXOwnerIdentity.ps1`): batch-resolves `ownerId` via
Microsoft Graph, populating `OwnerName` / `OwnerUPN` / `OwnerAccountStatus`. See
[ADR-0004](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/docs/decisions/0004-owner-resolution-and-managed-agent-placeholder.md).
- gitleaks secret scanning (CI workflow + pre-commit hook) and a new `CONTRIBUTING.md`.
- Agent Governance Baseline: `-MaxPages`, `-OutputPath`, `-ExportReport` parameters.
- Agent Governance Baseline schema expanded from 46 to 51 confirmed columns against a live tenant
response, then trimmed to 43 after reviewing for low-value/redundant columns.
- `.vscode/launch.json` debug configuration and `Debug-GovernanceBaseline.ps1` harness.
- `.gitignore` rules for local settings files and debug harnesses.
- `README.md`, `SETTINGS.md`, this `CHANGELOG.md`.

### Added — Experimental / preview tools (not production-tested)

- **Copilot Credit: Tenant Pool Draw** (`Set-PPXCopilotCreditTenantPoolDraw`) — *Dev in Progress*:
sets the `TenantPool` draw option per environment or in bulk. Dry-run by default, `-InputCsv`
review-then-apply workflow, policy-lock detection. First PPX tool that writes.
- **Custom Connector Usage** (`Get-PPXCustomConnectorUsage`) — *Experimental*: tenant-wide report of
custom connectors per environment. See
[ADR-0005](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/docs/decisions/0005-custom-connector-usage-data-sources.md).

### Changed

- Agent Governance Baseline: environment join moved from a server-side Inventory API join to a
client-side join against a separate environment lookup. See
[ADR-0003](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/docs/decisions/0003-pagination-strategy.md).
- Per-tool solution descriptions moved from the repo root into each tool's own folder (e.g.
`PPXAgentGovernanceBaseline.md` → `tools/agent-governance-baseline/`). Section anchors and
cross-links updated; historical changelog entries keep the old paths.

### Fixed

- Token refresh in `Connect-PPXInventoryApi.ps1` now retries per page instead of once per run, so a
large-tenant pull spanning multiple token lifetimes no longer aborts partway through.
- Owner resolution no longer mislabels ids from successful Graph batches as `GraphError` after an
unrelated batch fails; failures are now tracked per chunk.
- A failed token refresh inside owner resolution now degrades just that batch to `GraphError` instead
of aborting the whole report.
- A Graph outage now warns once per run instead of once per 1000-id batch.
- Environment-lookup truncation is now recorded in the `.limitations.txt` sidecar, not just printed
as a console warning.
- Agent Governance Baseline: Microsoft Graph errors during owner resolution (token acquisition
failure, a mid-run token refresh failure, a failed `getByIds` batch) are now recorded in the
`.limitations.txt` sidecar too, not just printed as a console warning. `Resolve-PPXOwnerIdentity` now
returns `{ Lookup; Errors }` instead of the lookup dictionary alone.
- Whitespace-only `ownerId` / `environmentId` values are now treated as blank
(`[string]::IsNullOrWhiteSpace`), consistent with the resolvers.
- `Get-PPXSettings.ps1` no longer discards an explicit `$false` setting as "unset" (PowerShell
treats `$false -eq 0` as true, which previously matched the drop condition).
- Managed agents (e.g. `D365 Sales - Data Enrichment`) now get an explicit owner placeholder instead
of a blank or a misleading `NotFound`. See
[ADR-0004](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/docs/decisions/0004-owner-resolution-and-managed-agent-placeholder.md).
- `Get-PPXNestedValue.ps1` no longer throws on a genuinely-missing nested object (`[AllowNull()]` was
missing on a mandatory parameter).
- Large-tenant runs no longer silently cap at 1,000 rows or crash on token expiry mid-run. See
[ADR-0003](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/docs/decisions/0003-pagination-strategy.md).
- Custom Connector Usage: fixed runaway paging, added a non-progress guard, and added 401 retry
handling. See [ADR-0005](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/docs/decisions/0005-custom-connector-usage-data-sources.md).

### Documentation

- `README.md` reoriented as a general overview; `SETTINGS.md` rewritten with the settings model,
precedence order, and an authentication troubleshooting table.
- Stale references to `skipToken` paging, un-implemented owner resolution, and outdated column
counts corrected across `.ps1` help text and `PPXAgentGovernanceBaseline.md`.

### Known limitations (documented, not changed)

- Connector-tier resolution and the DLP-coverage flag are not implemented yet; those columns are
blank in every Agent Governance Baseline row for now.
- Offset-paging can silently skip a record if the agent set changes mid-run — accepted, because
`skipToken` doesn't work for this API/query. See
[ADR-0003](https://github.com/MikkoKoskinen/ppx-agent-admin-tools/blob/main/docs/decisions/0003-pagination-strategy.md).
- The connectivity API `$filter=environment eq '{id}'` contract is based on community reports, not
an official Microsoft sample; a full-coverage confirming run is still pending.
- `tools/_shared/` extraction of duplicated auth/paging code (currently copied per tool) is a
tracked follow-up.