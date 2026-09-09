# PPX Copilot Credit — Tenant Pool Draw — Solution Description

Solution and high-level technical description for the **Copilot Credit — Tenant Pool Draw** tool. For
how to run it, see
[tools/copilot-credit-tenant-pool/README.md](tools/copilot-credit-tenant-pool/README.md); for
settings and authentication, [SETTINGS.md](SETTINGS.md); for the technical change history,
[CHANGELOG.md](CHANGELOG.md).

**Status:** experimental. The read → plan → PATCH pipeline is implemented and wired end-to-end
against `https://api.powerplatform.com/licensing/allocationsByEnvironment` (api-version `2024-10-01`),
using the same delegated-token + Inventory-API pattern as the other two PPX tools. This is the first
PPX tool that **writes**. The `TenantPoolLockedByPolicy` classification is coded from Microsoft's
documented behaviour and should be confirmed against a genuinely locked environment on first use.

---

## 1. Purpose

Let a Power Platform administrator set the Copilot Credit **"Draw from the available capacity in my
tenant"** option — the `TenantPool` enforcement rule on an environment's `MCSMessages` (Copilot
Credits) currency allocation — to `true` or `false` across **all** or **selected** environments in
one command, without clicking through the Power Platform admin center environment by environment.

Motivating scenario (from the
[Copilot harness cost-governance guidance](https://microsoft.github.io/mcscatblog/posts/copilot-harness-cost-governance/)):
new environments can appear with tenant-pool draw **enabled**, and maker-development environments
usually want it **disabled** so exploration does not consume capacity reserved for funded production
work. Doing that at scale is an API job.

Unlike the other two PPX tools, this one is **not read-only** — but it is **dry run by default** and
every run produces a before/after CSV audit trail.

## 2. Audience and scenarios

- **Platform admins / governance leads** applying a consistent capacity boundary to maker-development
  environments, or re-enabling tenant-pool draw for a specific funded-production environment.
- **Environment provisioning / reconciliation processes** that periodically bring new or drifted
  environments back to an approved control state.

## 3. Goals

- One command sets the setting for all or selected environments.
- **Dry run by default** — nothing is written unless `-Apply` is passed; the dry run produces the
  full before/after report so the change can be reviewed first.
- **Targeting is always explicit** — exactly one of `-EnvironmentId` / `-AllEnvironments` /
  `-InputCsv`; the tool never changes every environment implicitly.
- **Review-then-apply** — the dry-run CSV can be trimmed to just the wanted rows and fed straight
  back with `-InputCsv <file> -Apply`; the same report format round-trips.
- **Minimal, auditable change** — read-modify-write that touches only the `TenantPool` rule and
  leaves the allocated amount and every other rule exactly as found; the CSV shows before, after, and
  the untouched rules.
- Per-environment failures (locked by policy, no allocation surface, 403, …) are recorded and the
  run continues.
- State every known limitation **in the report output**, not as a silent gap.

## 4. Scope

### In scope

- Every environment in the tenant (`-AllEnvironments`), a caller-supplied list (`-EnvironmentId`),
  or the `EnvironmentId` column of a CSV (`-InputCsv` — typically a trimmed dry-run report), each
  with basic details from the Inventory API (name, type, managed flag, environment group).
- Reading each environment's current `MCSMessages` allocation and enforcement rules.
- Setting **only** the `TenantPool` rule to the requested value, creating a zero-credit `MCSMessages`
  allocation only where none exists and the target value is `false` (the minimum needed to persist
  the rule).
- A before/after CSV plus a `.limitations.txt` run summary.

### Out of scope (by design)

| Not included | Why / where it lives |
| --- | --- |
| Changing the allocated Copilot Credit amount | Preserved as-is; allocation sizing is a separate decision |
| `Alert` / `PayGo` / `Deny` enforcement rules | Preserved as-is |
| Agent-level monthly credit limits | Separate API (`licensing/.../threshold`) and a separate concern |
| Pay-as-you-go billing plan link/unlink | Separate surface |
| Creating / editing environment-group rules | This tool is overridden by a published group rule, not a manager of one |
| First-party read-only reporting of current state across the tenant | This tool's dry-run CSV already shows current state for its targets; a broader report is a possible future tool |
| Unattended / service-principal execution | Platform limitation on this endpoint; interactive delegated only |

## 5. Report schema

One row per target environment. Written by `ConvertTo-PPXTenantPoolRow`.

### Environment (basic details)

| Column | Source | Notes |
| --- | --- | --- |
| `EnvironmentName` | Inventory environments query, `properties.displayName` | |
| `EnvironmentId` | Inventory environments query, `name` | GUID; the id used in the licensing calls |
| `EnvironmentType` | Inventory, `properties.environmentType` | Production / Sandbox / Trial / Developer / Default / Dataverse for Teams |
| `IsManagedEnvironment` | Inventory, `properties.isManaged` | |
| `EnvironmentGroup` | Inventory, `properties.environmentGroup` | Blank if not in a group; context for a `Skipped (locked by policy)` row |
| `EnvironmentGroupId` | Inventory, `properties.environmentGroupId` | |

### Setting / change

| Column | Values | Meaning |
| --- | --- | --- |
| `CurrencyType` | `MCSMessages` | The Copilot Credits currency; the only one this tool touches |
| `AllocatedCredits` | integer / *(blank)* | The environment's current allocated Copilot Credits, **preserved** unchanged. Blank when no `MCSMessages` allocation exists |
| `TenantPoolDraw_Before` | `True` / `False` / `Default (True) - no MCSMessages allocation configured` / `Default (True) - no TenantPool rule on the allocation` | Effective current value of "Draw from the available capacity in my tenant" |
| `DesiredValue` | `True` / `False` | The value requested for this run (`-DrawFromTenantCapacity`) |
| `TenantPoolDraw_After` | `True` / `False` | The value in effect after the run — after `-Apply`, or what `-Apply` *would* set |
| `OtherEnforcementRules` | e.g. `Alert=True; PayGo=False; Deny=False` | The non-`TenantPool` rules, shown so the CSV proves they were left alone |

### Outcome

| Column | Values | Meaning |
| --- | --- | --- |
| `Action` | see below | Per-environment result |
| `Mode` | `DryRun` / `Apply` | Whether `-Apply` was passed |
| `Detail` | free text | Error message, policy note, or blank |

`Action` values: `NoChange` (already at the desired value), `WouldChange` / `WouldCreateAllocation`
(dry run — a change is pending), `Changed` / `CreatedAllocation` (applied), `Skipped (locked by
policy)` (a published environment-group rule governs the setting — `TenantPoolLockedByPolicy`),
`Skipped (declined)` (`-WhatIf`, or declined at a `-Confirm` prompt), `N/A (no allocation surface)`
(licensing `GET` returned HTTP 404), `Error (read)` / `Error (write)` (any other failure — recorded,
run continues).

## 6. Technical design (high level)

### 6.1 Pipeline

```
Set-PPXCopilotCreditTenantPoolDraw            entry point (tools/copilot-credit-tenant-pool/)
 ├─ Get-PPXPowerPlatformToken          Az context reuse + delegated token for api.powerplatform.com
 ├─ Import-PPXTargetCsv                only with -InputCsv — read EnvironmentId (+ optional DesiredValue)
 ├─ Connect-PPXInventoryApi            POST resourcequery — every environment + basic details
 │                                     (target set for -AllEnvironments; display names for the report)
 │  for each target environment:
 ├─ Get-PPXEnvironmentCreditAllocation GET  licensing/allocationsByEnvironment/{id}  (HTTP 404 → $null)
 ├─ Resolve-PPXTenantPoolChange        pure planner — minimal read-modify-write PATCH body, or NoChange
 ├─ Set-PPXEnvironmentCreditAllocation PATCH licensing/allocationsByEnvironment   (only when -Apply and
 │                                     $PSCmdlet.ShouldProcess; detects TenantPoolLockedByPolicy)
 ├─ ConvertTo-PPXTenantPoolRow         one before/after row per environment
 └─ Export-PPXReport                   flat CSV + .limitations.txt run summary
 helper: Get-PPXNestedValue            safe dotted-path property reader
```

One delegated token is acquired once and reused for the Inventory query and every per-environment
licensing call, and handed down as a `-TokenFactory` scriptblock so a long sweep can refresh once on
an HTTP 401.

### 6.2 Data sources

| Source | Role |
| --- | --- |
| **Power Platform Inventory API** — `POST /resourcequery/resources/query` | Environment list + basic details (target set for `-AllEnvironments`; names / type / group for every row) |
| **Power Platform licensing API** — `GET /licensing/allocationsByEnvironment/{id}` | Per environment: the current `MCSMessages` allocation (`allocated`, `autoAllocated`) and its enforcement rules (`Alert` / `PayGo` / `TenantPool` / `Deny`) |
| **Power Platform licensing API** — `PATCH /licensing/allocationsByEnvironment` | Per environment (only with `-Apply`): write back the `MCSMessages` allocation with **only** the `TenantPool` rule changed |

### 6.3 Authentication

Interactive **delegated** (user) authentication via **Az PowerShell**: `Connect-AzAccount` (only when
there is no usable Az context) then `Get-AzAccessToken -ResourceUrl https://api.powerplatform.com`.
All three calls share that resource, so one token serves the whole run; a device-code option
(`-UseDeviceAuthentication` / `Common.UseDeviceAuthentication`) exists for the VS Code debugger.
Requires **Power Platform Administrator** / **Global Administrator** (a role that can manage licensing
and capacity). Service-principal / unattended auth against this endpoint is a known platform
limitation and is not implemented. Full detail:
[SETTINGS.md § Authentication](SETTINGS.md#authentication).

### 6.4 The setting

"Draw from the available capacity in my tenant" (Power Platform admin center → Licensing → Copilot
Studio → Manage Copilot Credits → *environment* → Capacity overages) is the `TenantPool` entry in
`currencyAllocations[currencyType == "MCSMessages"].enforcementRules`:

- `enabled = true` — after the environment's own allocation is exhausted (or when it has none) it
  keeps drawing from the tenant's **unallocated** prepaid Copilot Credit capacity.
- `enabled = false` — the environment is **capped** at its own allocation; a linked pay-as-you-go
  plan (if any) still works.

For an eligible Copilot Studio environment with **no** allocation configuration, the platform default
is `enabled = true`.

### 6.5 Read-modify-write (`Resolve-PPXTenantPoolChange`)

`PATCH /licensing/allocationsByEnvironment` **replaces** the currency allocation it is given, so the
body must be complete for that currency. The planner is a pure function (no I/O):

1. Find the `MCSMessages` entry in the `GET` response's `currencyAllocations`.
2. Read the current `TenantPool` rule. Absent rule, or absent `MCSMessages` allocation → effective
   value is the platform default `true`, labelled `Default (True) - …`.
3. If the effective value already equals `-DrawFromTenantCapacity` and `-Force` is not set →
   `Action = NoChange`, no body.
4. Otherwise build a body containing **only** the `MCSMessages` currency:
   - `allocated` carried through unchanged (`0` when no allocation existed);
   - `enforcementRules` = every existing rule copied verbatim, with the `TenantPool` rule set to the
     desired value (added if it was absent).
   `autoAllocated` and any other read-only computed field are deliberately **not** echoed back — the
   write model documents only `currencyType` / `allocated` / `enforcementRules`.
   - `Action = Change` when an `MCSMessages` allocation existed, `Create` when one is being written
     for the first time (only happens for `-DrawFromTenantCapacity $false` — the default already
     covers `$true`).

### 6.6 Write safety

- **Dry run by default.** Without `-Apply`, steps 1–2 run for every target and the report is
  produced with `WouldChange` / `WouldCreateAllocation` / `NoChange`; no `PATCH` is issued.
- **Explicit target.** Exactly one of `-EnvironmentId <guid[,guid…]>` / `-AllEnvironments` /
  `-InputCsv <path>`; the entry point throws if none or more than one is given.
- **Review-then-apply.** `-InputCsv` takes the target list from a CSV's `EnvironmentId` column —
  normally the dry-run report (`CopilotCreditTenantPool_<timestamp>.csv`) with the unwanted rows
  deleted. An optional `DesiredValue` column (TRUE/FALSE) supplies a per-environment target value
  when `-DrawFromTenantCapacity` is omitted, so a single file can set different values per
  environment. Blank `EnvironmentId` rows are skipped, duplicates de-duplicated (first wins), and an
  unparseable `DesiredValue` cell is a terminating error. Each environment is still re-read live
  before the plan is computed, so a stale `TenantPoolDraw_Before` in the edited CSV cannot cause a
  wrong write.
- **`SupportsShouldProcess`.** `-WhatIf` previews; `-Confirm` prompts per environment.
  `ConfirmImpact = 'Medium'`, so `-Apply` alone does not prompt — the dry run is the review gate.
- **Per-environment isolation.** A read failure, a write failure, a policy lock, or a missing
  allocation surface is recorded on that environment's row and the sweep continues.
- **Audit trail.** Every run — dry or applied — writes a before/after CSV and a `.limitations.txt`
  summary (mode, desired value, per-outcome tally, every per-environment error).

### 6.7 Environment-group policy lock

If a published **environment-group rule** governs "Draw from the available capacity in my tenant",
the `PATCH` is rejected with a `TenantPoolLockedByPolicy` error.
`Set-PPXEnvironmentCreditAllocation` detects that code in the response body and re-throws a
`LOCKED_BY_POLICY:` message; the entry point turns it into `Action = Skipped (locked by policy)` and
carries on. Fix: change and republish the group rule, or remove the environment from the group, then
re-run.

### 6.8 Output

A flat CSV, one row per target environment, plus a sibling `<name>.limitations.txt` that doubles as
the run summary: mode, desired value, targeted-vs-total environment count, a per-`Action` tally, an
explicit **DRY RUN — NOTHING WAS WRITTEN** banner when applicable, every per-environment error, and
the static limitations. Same two-file pattern, and reasoning, as the other PPX tools (a plain CSV has
no comment syntax).

### 6.9 Configuration

Runtime knobs come from the shared settings file (`ppx.settings.psd1`, section
`CopilotCreditTenantPool`, falling back to `Common`): tenant ID (required), environment-list paging
(`Top` / `MaxPages`), output path, and `ExportReport`. The **change intent** —
`-DrawFromTenantCapacity`, `-EnvironmentId` / `-AllEnvironments` / `-InputCsv`, `-Apply`, `-Force` —
is only ever a command-line parameter, never a setting. Precedence is explicit parameter → settings file → default.
See [SETTINGS.md](SETTINGS.md).

## 7. Implementation status

| Component | State |
| --- | --- |
| Settings resolution, tenant enforcement, target-selection guard, dry-run/apply orchestration | Done |
| `Get-PPXPowerPlatformToken` — Az auth + delegated token | Done (copy of the custom-connector-usage version) |
| `Connect-PPXInventoryApi` — environment list + skipToken paging | Done (copy; used for the one environments query) |
| `Import-PPXTargetCsv` — read `EnvironmentId` (+ optional `DesiredValue`) from a CSV | Done; unit-tested (trim / de-dup / blank-skip / bad-value + missing-column throws) |
| `Get-PPXEnvironmentCreditAllocation` — licensing GET + 404→$null + 429/401 retry | Done |
| `Resolve-PPXTenantPoolChange` — pure read-modify-write planner | Done; unit-tested against mock allocation shapes |
| `Set-PPXEnvironmentCreditAllocation` — licensing PATCH + policy-lock detection + 429/401 retry | Done; `TenantPoolLockedByPolicy` surface needs live confirmation |
| `ConvertTo-PPXTenantPoolRow` / `Export-PPXReport` — CSV + `.limitations.txt` | Done |
| Full-tenant apply run confirmation against a live tenant | Pending |

## 8. Known limitations

Stated here and in every report run:

- Only the `TenantPool` rule is written; `allocated`, `autoAllocated`, and the other enforcement
  rules (`Alert` / `PayGo` / `Deny`) are echoed back unchanged.
- `CreatedAllocation` rows write a new `MCSMessages` allocation with `allocated = 0` — the minimum
  needed to persist `TenantPool = false` on an environment that had no allocation at all.
  Environments left at the default (`TenantPool = true`) with no allocation are reported `NoChange`
  and never written.
- Environments governed by a published environment-group rule for this setting cannot be changed here
  (`TenantPoolLockedByPolicy`) — `Skipped (locked by policy)`.
- Environments with no Copilot Credit allocation surface (licensing `GET` → HTTP 404: not a Dataverse
  environment, or not eligible) — `N/A (no allocation surface)`, never written.
- Up to ~15 minutes of replication latency: a read immediately after a write may still show the old
  value. The CSV records the intended post-change value, not a re-read.
- Point-in-time: another administrator, or a later environment-group rule publish, can change the
  setting again after this run.
- API `licensing/allocationsByEnvironment`, api-version `2024-10-01`, currency `MCSMessages`. The
  enforcement-rule model is subject to change by Microsoft.
- With `-AllEnvironments`, the target set is the Inventory API environment list; if that list is
  flagged **INCOMPLETE** (skipToken paging truncated by `-MaxPages`, an empty-page streak, or the
  1000-page hard cap), some environments are not visited.
- Authentication is interactive delegated only; unattended auth is not supported against this
  endpoint at time of writing.

## 9. Dependencies

- PowerShell 5.1+ (Windows PowerShell) or 7.x
- `Az.Accounts` — sign-in and token acquisition
- Permissions: Power Platform Administrator / Global Administrator (a role that can manage licensing
  and capacity); must have signed into the Power Platform admin center at least once

## 10. Relationship to other tools

Independent and self-contained, like every PPX tool. `Get-PPXPowerPlatformToken.ps1`,
`Connect-PPXInventoryApi.ps1`, and `Get-PPXNestedValue.ps1` are deliberate copies of the
custom-connector-usage versions; extracting the shared machinery to `tools/_shared/` is a tracked
follow-up for all three tools. The dry-run before/after CSV is a lightweight point-in-time report of
the current `TenantPool` state for the targeted environments; a broader tenant-wide Copilot Credit
allocation report would be a separate tool.

## References

- [Adopting the GitHub Copilot Harness: Cost Control and Governance in Copilot Studio](https://microsoft.github.io/mcscatblog/posts/copilot-harness-cost-governance/)
- [Tutorial: Manage Copilot Credits allocations programmatically](https://learn.microsoft.com/en-us/power-platform/admin/programmability-tutorial-manage-copilot-credit-allocations)
- [Power Platform REST API — Licensing — Allocations By Environment — Get](https://learn.microsoft.com/en-us/rest/api/power-platform/licensing/allocations-by-environment/get-allocations-by-environment)
- [Power Platform REST API — Licensing — Allocations By Environment — Update](https://learn.microsoft.com/en-us/rest/api/power-platform/licensing/allocations-by-environment/update-allocations-by-environment)
- [Manage costs for agents powered by the GitHub Copilot harness](https://learn.microsoft.com/en-us/power-platform/admin/manage-usage-github-copilot-harness)
- [Power Platform inventory API](https://learn.microsoft.com/en-us/power-platform/admin/inventory-api)
- [Programmability and extensibility — authentication (v2)](https://learn.microsoft.com/en-us/power-platform/admin/programmability-authentication-v2)
