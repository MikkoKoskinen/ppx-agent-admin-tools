# Copilot Credit — Tenant Pool Draw

Sets the Copilot Credit **"Draw from the available capacity in my tenant"** option — the `TenantPool`
enforcement rule on each environment's `MCSMessages` (Copilot Credits) currency allocation — to
`$true` or `$false` for **all** or **selected** Power Platform environments. Part of the
[PPX](../../README.md) tool collection, and the first one that **writes**.

Solution and high-level technical description:
[PPXCopilotCreditTenantPool.md](PPXCopilotCreditTenantPool.md).

**Status: Experimental.** The read → plan → PATCH pipeline is implemented and wired end-to-end
against `https://api.powerplatform.com/licensing/allocationsByEnvironment` (api-version `2024-10-01`),
following the same delegated-token + Inventory-API pattern as the other PPX tools. The
`TenantPoolLockedByPolicy` handling is coded from Microsoft's documented behaviour; confirm the exact
error surface against a locked environment on first use.

## What it does

- **`TenantPool` enabled** — the environment keeps drawing from your tenant's *unallocated* Copilot
  Credit capacity after its own allocation is exhausted (or when it has no allocation).
- **`TenantPool` disabled** — the environment is capped at its own allocation and stops consuming
  prepaid capacity when that runs out (a linked pay-as-you-go plan, if any, still works).

This is the checkbox at **Power Platform admin center → Licensing → Copilot Studio → Manage Copilot
Credits → *select an environment* → Capacity overages → "Draw from the available capacity in my
tenant"**.

Per environment the tool: **GET**s the current `MCSMessages` allocation → works out the minimal
change → (with `-Apply`) **PATCH**es it back with **only** the `TenantPool` rule changed. The
allocated credit amount and every other enforcement rule (`Alert` / `PayGo` / `Deny`) are read and
written back unchanged.

## What it does *not* do (by design)

- Change the allocated credit amount, or the `Alert` / `PayGo` / `Deny` rules — those pass through
  untouched.
- Manage agent-level monthly limits, pay-as-you-go billing plans, or environment-group rules.
- Override a **published environment-group rule** for this setting — the API rejects that
  (`TenantPoolLockedByPolicy`); such environments are reported as `Skipped (locked by policy)`.
- Anything for environments with no Copilot Credit allocation surface (licensing `GET` → HTTP 404) —
  reported as `N/A (no allocation surface)`.

## Prerequisites

- PowerShell 5.1+ or PowerShell 7.x
- [`Az.Accounts`](https://www.powershellgallery.com/packages/Az.Accounts) module
  (`Install-Module Az.Accounts -Scope CurrentUser`)

## Required permissions

- Power Platform Administrator or Global Administrator (a role that can manage licensing and
  capacity)
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
. .\Set-PPXCopilotCreditTenantPoolDraw.ps1

# DRY RUN (default): read every environment, write the before/after CSV, change nothing
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments

# APPLY: turn "Draw from the available capacity in my tenant" OFF for every environment
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments -Apply

# APPLY to selected environments only
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $true -EnvironmentId 1111...,2222... -Apply

# per-environment confirmation prompts while applying
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments -Apply -Confirm

# also re-assert the value on environments already set to it
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments -Apply -Force

# apply only to the environments listed in an (edited) dry-run report
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -InputCsv .\reports\CopilotCreditTenantPool_20260909-140000.csv -Apply

# just get the rows back, no CSV
Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments -ExportReport:$false
```

### Review-then-apply with `-InputCsv`

The intended workflow for a careful admin:

1. **Dry run** for the full picture:
   `Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -AllEnvironments`
2. **Open the report** (`reports\CopilotCreditTenantPool_<timestamp>.csv`) and **delete every row you
   do *not* want changed** — keep only the environments to act on. Save.
3. **Apply just those:**
   `Set-PPXCopilotCreditTenantPoolDraw -DrawFromTenantCapacity $false -InputCsv <that file> -Apply`

`-InputCsv` reads the **`EnvironmentId`** column as the target list; every other column is ignored
except an optional **`DesiredValue`** column. Leave `DesiredValue` in (the dry-run report writes it)
and **omit `-DrawFromTenantCapacity`** to give each environment its own row's value — so one file can
set some to `TRUE` and some to `FALSE`. Blank `EnvironmentId` rows are skipped; duplicates are
de-duplicated. The tool still re-reads each environment live before deciding, so a stale
`TenantPoolDraw_Before` in the edited CSV cannot cause a wrong write.

The reader also copes with a `;`- or TAB-delimited file, a BOM, an Excel `sep=` line, and the
"whole row wrapped in one quoted field" shape Excel produces when it saves a comma CSV under a
non-US list-separator locale — so editing the report in Excel and saving it back works even then.

> **Keeping vs. deleting rows.** `-InputCsv` uses the CSV purely as a target list — it always
> re-reads each environment live and re-decides. A row you keep that is *already* at the target
> value applies as `NoChange` (nothing is written). So to turn tenant-pool draw **on** for some
> environments and **off** for others in one pass, keep the rows for **both** and either run twice
> (once with `-DrawFromTenantCapacity $true`, once with `$false`) or set each row's `DesiredValue`
> cell (`TRUE` / `FALSE`) and omit `-DrawFromTenantCapacity`. Delete a row only when you want that
> environment left completely untouched.

> **Editing the CSV without Excel mangling it.** Excel under a non-US locale (list separator `;`)
> rewrites the comma report so every row becomes one quoted field — the reader now recovers from
> that, but you can avoid it entirely by trimming the file in a plain-text editor (VS Code,
> Notepad++) — just delete the unwanted lines — or, in Excel, opening it with **Data → From
> Text/CSV** and saving with **Save As → CSV UTF-8**.

**Targeting is explicit.** Exactly one of `-EnvironmentId <guid[,guid…]>`, `-AllEnvironments`, or
`-InputCsv <path>` must be given — the tool never changes every environment implicitly.
`-AllEnvironments` takes its target list from the Inventory API environment list (`-Top` /
`-MaxPages` tune that paging; a truncated list is flagged **INCOMPLETE**).

**Dry run vs apply.** Without `-Apply` the run is read-only: every target environment is `GET` and
the report shows `WouldChange` / `WouldCreateAllocation` / `NoChange`, but nothing is `PATCH`ed. Add
`-Apply` to write. `SupportsShouldProcess` is on, so `-WhatIf` previews and `-Confirm` prompts per
environment; the confirm impact is *Medium*, so `-Apply` on its own does not prompt (the dry run is
the review step).

**"CreatedAllocation" rows.** An environment with **no** `MCSMessages` allocation at all defaults to
`TenantPool = True`. The only way to persist `TenantPool = False` there is to write an allocation, so
the tool creates one with `allocated = 0` (no prepaid capacity reserved) and flags the row
`WouldCreateAllocation` / `CreatedAllocation`. Environments left at the default (`True`) with no
allocation are reported `NoChange` and never written.

The function signs in interactively via `Connect-AzAccount` (only when there is no usable Az
context), writes a CSV to `reports\` at the repo root (git-ignored; override with `-OutputPath` or
`CopilotCreditTenantPool.OutputPath`) plus a `.limitations.txt` sidecar that doubles as this run's
summary (mode, desired value, per-outcome tally, every per-environment error), and returns the shaped
rows.

Tenant selection and other knobs come from the shared settings file — see
[SETTINGS.md](../../SETTINGS.md), including the **Authentication** section.

## Report schema

One row per target environment.

| Column | Notes |
| --- | --- |
| `EnvironmentName` / `EnvironmentId` | From the Inventory environment list (`properties.displayName` / `name`) |
| `EnvironmentType` | Production / Sandbox / Trial / Developer / Default / Dataverse for Teams |
| `IsManagedEnvironment` | `properties.isManaged` |
| `EnvironmentGroup` / `EnvironmentGroupId` | Blank if the environment is not in a group — useful context for a `Skipped (locked by policy)` row |
| `CurrencyType` | Always `MCSMessages` |
| `AllocatedCredits` | The environment's current allocated Copilot Credits (preserved, not changed). Blank when no allocation exists |
| `TenantPoolDraw_Before` | `True` / `False`, or `Default (True) - …` when there is no allocation / no `TenantPool` rule |
| `DesiredValue` | The value requested for this run |
| `TenantPoolDraw_After` | The value in effect after this run (or after `-Apply` would run) |
| `OtherEnforcementRules` | e.g. `Alert=True; PayGo=False; Deny=False` — shown to prove they were not touched |
| `Action` | `NoChange` / `WouldChange` / `WouldCreateAllocation` / `Changed` / `CreatedAllocation` / `Skipped (locked by policy)` / `Skipped (declined)` / `N/A (no allocation surface)` / `Error (read)` / `Error (write)` |
| `Mode` | `DryRun` / `Apply` |
| `Detail` | Error text, policy note, or blank |

## Known limitations

- Only the `TenantPool` rule is written; `allocated`, `autoAllocated`, and the other enforcement
  rules are echoed back unchanged.
- Environments governed by a published environment-group rule for this setting cannot be changed
  here (`TenantPoolLockedByPolicy`) — `Skipped (locked by policy)`.
- Environments with no Copilot Credit allocation surface (HTTP 404) are never written —
  `N/A (no allocation surface)`.
- Up to ~15 minutes of replication latency: a read straight after a write may still show the old
  value. The CSV records the intended post-change value, not a re-read.
- Point-in-time: another admin, or a later environment-group rule publish, can change it again.
- API `licensing/allocationsByEnvironment`, api-version `2024-10-01`, currency `MCSMessages`. The
  enforcement-rule model is subject to change by Microsoft.
- Authentication is interactive delegated (Az PowerShell) only; unattended / service-principal auth
  is not supported against this endpoint.
- `-InputCsv` is a target **list** only — the tool re-reads and re-decides per environment, so a kept
  row already at the target value applies as `NoChange`. To change different environments to
  different values in one file, set each row's `DesiredValue` (`TRUE`/`FALSE`) and omit
  `-DrawFromTenantCapacity`; delete a row only to leave that environment untouched.
- Editing the report in Excel under a locale whose list separator is not a comma (e.g. `;`) rewrites
  every row as one quoted field. The reader recovers from that (and from `;`/TAB delimiters, a BOM,
  and an Excel `sep=` line), but trimming the file in a plain-text editor — or opening it in Excel
  with **Data → From Text/CSV** and saving as **CSV UTF-8** — avoids the reshuffle entirely.
- Every run's specific gaps are restated in the `.limitations.txt` file written alongside the CSV.

## Security considerations

- No secrets or credentials are stored; Az PowerShell handles interactive token acquisition and
  caching.
- **This tool writes.** It is dry-run by default and requires an explicit target
  (`-EnvironmentId` / `-AllEnvironments`) and an explicit `-Apply` to make any change. Every run —
  dry or applied — produces a before/after CSV audit trail.

## References

- [Blog: Adopting the GitHub Copilot Harness — Cost Control and Governance in Copilot Studio](https://microsoft.github.io/mcscatblog/posts/copilot-harness-cost-governance/)
- [Tutorial: Manage Copilot Credits allocations programmatically](https://learn.microsoft.com/en-us/power-platform/admin/programmability-tutorial-manage-copilot-credit-allocations)
- [REST API — Allocations By Environment — Get](https://learn.microsoft.com/en-us/rest/api/power-platform/licensing/allocations-by-environment/get-allocations-by-environment)
- [REST API — Allocations By Environment — Update](https://learn.microsoft.com/en-us/rest/api/power-platform/licensing/allocations-by-environment/update-allocations-by-environment)
- [Manage costs for agents powered by the GitHub Copilot harness](https://learn.microsoft.com/en-us/power-platform/admin/manage-usage-github-copilot-harness)
- [Programmability and extensibility — authentication (v2)](https://learn.microsoft.com/en-us/power-platform/admin/programmability-authentication-v2)
