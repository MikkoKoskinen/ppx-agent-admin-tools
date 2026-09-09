# Settings

All PPX tools read their user-tweakable values from **one shared settings file** at the repo root,
so you configure things like your tenant ID once instead of editing scripts or retyping parameters.

## Files

| File | What it is | Committed to git? |
| --- | --- | --- |
| [`ppx.settings.example.psd1`](ppx.settings.example.psd1) | Template. Every supported key, documented, with safe defaults. | Yes |
| `ppx.settings.psd1` | **Your** copy with real values. Created by you. | No — git-ignored |
| [`tools/_shared/Get-PPXSettings.ps1`](tools/_shared/Get-PPXSettings.ps1) | Loader that every tool dot-sources. You don't edit this. | Yes |

The settings file is a PowerShell **data file** (`.psd1`): values only, no commands. It is parsed with
`Import-PowerShellDataFile`, which never executes code — so it is safe to share and safe to accept
from someone else.

## First-time setup (required)

The repo ships with **no tenant configured** — the example file's `TenantId` is blank, and tools
**refuse to run** until you set your own. After cloning:

```powershell
# from the repo root
Copy-Item ppx.settings.example.psd1 ppx.settings.psd1
```

Then open `ppx.settings.psd1` and set at least `Common.TenantId` to your Entra tenant ID. Tools pick
the file up automatically on the next run. `ppx.settings.psd1` is git-ignored, so your tenant ID
never gets committed or shared.

If you skip this, the tools fall back to `ppx.settings.example.psd1` (blank tenant) and fail fast
with a message telling you to do the copy. You can also bypass the file entirely for a one-off:
`Get-PPXAgentGovernanceBaseline -TenantId <guid>`.

## File structure

```powershell
@{
    # Applies to every tool.
    Common = @{
        TenantId = '00000000-0000-0000-0000-000000000000'
    }

    # Applies only to tools/agent-governance-baseline.
    AgentGovernanceBaseline = @{
        # TenantId = '...'   # uncomment to override Common for just this tool
        Top = 250
    }
}
```

- **`Common`** — keys shared by all tools.
- **One section per tool** — named in PascalCase after the tool folder
  (`tools/agent-governance-baseline` → `AgentGovernanceBaseline`). A key here overrides the same key
  in `Common` **for that tool only**.
- Leave a value as `''` (empty string) or `0` to mean *"not set — use the default"*. The loader drops
  those, so a tool treats them as absent. `$false` is **not** dropped — it's a real value, which
  matters for a boolean setting whose default is `$true` (e.g. `ExportReport` below): setting it to
  `$false` genuinely turns the behavior off, rather than being read as "unset."

## How a value is resolved

For any given parameter, the first source that has a real value wins:

```
1. Parameter passed explicitly on the command line
2. ppx.settings.psd1  →  tool section  (e.g. AgentGovernanceBaseline.Top)
3. ppx.settings.psd1  →  Common        (e.g. Common.TenantId)
4. The tool's / API's own built-in default
```

Example — with the file above:

```powershell
Get-PPXAgentGovernanceBaseline                 # TenantId + Top come from the settings file
Get-PPXAgentGovernanceBaseline -Top 50         # Top = 50 (override); TenantId still from the file
```

## Current keys

### `Common`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `TenantId` | string | `''` | **Required.** Entra (Azure AD) tenant to sign in against. Blank in the repo; tools throw until you set it (here or via `-TenantId`). |
| `UseDeviceAuthentication` | bool | `$false` | Use device-code sign-in instead of the browser/WAM prompt. Set `$true` when the browser prompt hangs — e.g. inside the VS Code debugger. See [Signing in from the VS Code debugger](#signing-in-from-the-vs-code-debugger). |

### `AgentGovernanceBaseline` — [`tools/agent-governance-baseline`](tools/agent-governance-baseline)

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `TenantId` | string | *(inherits `Common`)* | Override the tenant for just this tool. |
| `Top` | int | `0` | Rows fetched **per Inventory API request** (1–1000; higher is clamped — the API returns at most 1000 per page). `0` = default (1000). Does **not** cap the total: the tool follows `skipToken` paging until every agent record is retrieved. |
| `MaxPages` | int | `0` | Safety cap on how many Inventory API pages (requests) to follow. `0` = no cap (retrieve everything). Set a small value for a quick partial pull while testing — the report is then flagged **INCOMPLETE** in its `.limitations.txt` sidecar. |
| `OutputPath` | string | `''` | Where the CSV report (+ `.limitations.txt` sidecar) is written. A folder path auto-names a timestamped file into it; a path ending in `.csv` is used as-is. `''` = the repo-root `reports\` folder (git-ignored). |
| `ExportReport` | bool | `$true` | Whether to write the CSV report to disk. `$false` = only build and return the shaped rows in memory, write nothing to disk. |

### `CustomConnectorUsage` — [`tools/custom-connector-usage`](tools/custom-connector-usage)

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `TenantId` | string | *(inherits `Common`)* | Override the tenant for just this tool. |
| `Top` | int | `0` | Rows fetched **per Inventory API request** (1–1000; higher is clamped). `0` = default (1000). Does **not** cap the total: `skipToken` paging retrieves every connector-emitting resource. |
| `MaxPages` | int | `0` | Safety cap on Inventory API pages **per query**. `0` = no cap. A small value gives a quick partial pull while testing — the report is then flagged **INCOMPLETE**. |
| `MaxEnvironments` | int | `0` | Cap on how many environments the per-environment connector lookup (connectivity API) runs against. `0` = all. A small value speeds up a test run; the report is then flagged **PARTIAL** in its `.limitations.txt` sidecar. |
| `SkipEnvironmentConnectorLookup` | bool | `$false` | `$true` = skip the per-environment connectivity calls entirely. Fast, but the report is then built from the Inventory usage heuristic alone: only custom connectors a resource references appear, `IsCustomApi` is `"Inferred"`, `ExistsInEnvironmentList` is `"Unknown"`. |
| `OutputPath` | string | `''` | Where the CSV report (+ `.limitations.txt` sidecar) is written. Folder path auto-names a timestamped file; a `.csv` path is used as-is. `''` = the repo-root `reports\` folder (git-ignored). |
| `ExportReport` | bool | `$true` | Whether to write the CSV report to disk. `$false` = only build and return the shaped rows in memory. |
| `IncludeAllEnvironments` | bool | `$false` | `$true` = also emit one placeholder row (blank `ConnectorId`) for every environment that has **no** custom connectors, so the CSV doubles as a "confirmed clean" list. `$false` = only rows for environments with ≥ 1 custom connector. |

## Authentication

The tools call the **Power Platform API** (`https://api.powerplatform.com`) with an interactive
**user (delegated)** token. The `TenantId` setting decides which tenant that sign-in targets.

### Option A — Az PowerShell (current default, no app registration)

`Connect-PPXInventoryApi` uses the **`Az.Accounts`** module:

1. `Get-AzContext` — if there is already a usable Az sign-in for the right tenant, it is reused and
   **no prompt appears**.
2. Otherwise `Connect-AzAccount` runs interactively (browser / device code). If `TenantId` is set and
   the current context is for a different tenant, a fresh sign-in is forced for that tenant.
3. `Get-AzAccessToken -ResourceUrl https://api.powerplatform.com` issues the token. Az refreshes and
   caches it in its own token cache; this tool keeps no token of its own.

One-time setup:

```powershell
Install-Module Az.Accounts -Scope CurrentUser
```

Why this instead of a bare client ID + MSAL: `8578e004-a5c6-46e7-913e-12f58912df43` is the Power
Platform API **resource**, not a client you can sign in as, and Microsoft publishes **no sample
public client** for it. Passing that GUID as the client ID produces:

```
AADSTS90009: Application '8578e004-…' is requesting a token for itself.
```

The Az PowerShell first-party client is already consented for this API, so borrowing it avoids an app
registration entirely.

### Signing in from the VS Code debugger

`Connect-AzAccount` run inside the VS Code debugger / PowerShell Integrated Console defaults to
**WAM** (the native Windows account broker). Its window can't attach to the embedded console, so the
sign-in prints `Please select the account you want to login with.` and then **hangs**. Pick one:

- **Sign in once outside the debugger** *(recommended for iterative debugging — no code path
  changes)*. In a normal terminal (or VS Code's integrated **terminal**, not the debug console):
  ```powershell
  Connect-AzAccount            # add -Tenant <id> to match your TenantId setting
  ```
  The Az context is shared, so every subsequent F5 reuses it and never prompts.

- **Use device-code sign-in.** Set `UseDeviceAuthentication = $true` under `Common` in
  `ppx.settings.psd1` (or pass `-UseDeviceAuthentication`). The run prints a code and
  `https://microsoft.com/devicelogin` to complete in any browser.

- **Turn WAM off globally.** `Update-AzConfig -EnableLoginByWam $false` — future
  `Connect-AzAccount` calls use the system browser, which does render from the debug console.

### Option B — your own Entra app registration (reference, not wired in)

Use this if you need a dedicated identity (e.g. a locked-down tenant, or to move toward unattended
auth later). It requires a small code change in `Connect-PPXInventoryApi.ps1` (swap the Az calls for
`MSAL.PS` `Get-MsalToken`, or `Get-AzAccessToken` against a custom context).

1. **App registrations → New registration** — single tenant is fine.
2. **Authentication → Add a platform → Mobile and desktop applications** — redirect URI
   `https://login.microsoftonline.com/common/oauth2/nativeclient`.
3. **API permissions → APIs my organization uses → Power Platform API**
   (`8578e004-a5c6-46e7-913e-12f58912df43`) → **Delegated permissions** → add the namespace
   permission(s) you need → **Grant admin consent**.
4. Add the new app's **client ID** to `ppx.settings.psd1` (e.g. a `Common.ClientId` key) and read it
   in the connect script; keep the scope `https://api.powerplatform.com/.default`.

### Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `AADSTS90009: … requesting a token for itself` | A resource GUID was used as the client ID. Use Option A (Az) or a real client app (Option B). |
| `Please select the account you want to login with.` then nothing (esp. under F5 / debugger) | WAM prompt can't render in the console. See [Signing in from the VS Code debugger](#signing-in-from-the-vs-code-debugger). |
| `Get-AzAccessToken` / `Connect-AzAccount` not recognized | `Install-Module Az.Accounts -Scope CurrentUser`. |
| Signed into the wrong tenant | Set `TenantId` in `ppx.settings.psd1`, or run `Disconnect-AzAccount` and retry. |
| `401` from the API after a good sign-in | The signed-in user lacks the Power Platform Admin / Dynamics 365 Service Admin role, or admin consent for the delegated permission is missing. |
| Token looks like `System.Security.SecureString` | Az.Accounts 5.x returns `Token` as a `SecureString`; the connect script already unwraps it. |

## Using settings from a tool (for contributors)

Dot-source the loader and fall back to it only when a parameter wasn't passed:

```powershell
. (Join-Path $PSScriptRoot '..\_shared\Get-PPXSettings.ps1')

$settings = Get-PPXSettings -Section 'AgentGovernanceBaseline'
if (-not $PSBoundParameters.ContainsKey('TenantId') -and $settings.TenantId) { $TenantId = $settings.TenantId }
if (-not $PSBoundParameters.ContainsKey('Top')      -and $settings.Top)      { $Top      = $settings.Top }
```

`Get-PPXSettings`:

- walks up from its own folder to find `ppx.settings.psd1` (or `ppx.settings.example.psd1` as a
  fallback),
- caches the parsed file for the session (`-Refresh` re-reads it),
- returns `Common` merged with the requested `-Section` (section wins on collisions),
- removes keys whose value is `''`, `0`, or `$null`, so `if ($settings.X)` is a safe presence check
  for most settings. `$false` is kept, **not** removed.

That last point matters for a boolean parameter whose *default* is `$true` (e.g. `-ExportReport`):
a plain truthiness check can't tell "not set in the file" apart from "explicitly set to `$false`," so
use `ContainsKey` instead of truthiness for those:

```powershell
if (-not $PSBoundParameters.ContainsKey('ExportReport') -and $settings.ContainsKey('ExportReport')) {
    $ExportReport = [bool] $settings.ExportReport
}
```

## Adding a setting

1. Add the key to the right section in **`ppx.settings.example.psd1`**, with a comment and a safe
   default.
2. In the tool, read it via `Get-PPXSettings` using the "parameter wins" pattern above. If it's a
   boolean whose default is `$true`, use `ContainsKey` instead of truthiness — see
   [Using settings from a tool](#using-settings-from-a-tool-for-contributors).
3. Document it in the **Current keys** tables here.

## Adding a new tool

1. Dot-source `..\_shared\Get-PPXSettings.ps1` from the tool.
2. Add a `PascalCase` section for it in `ppx.settings.example.psd1`.
3. Call `Get-PPXSettings -Section 'YourToolName'`.
4. Add its section to the **Current keys** tables here.

## Notes

- `ppx.settings.psd1` is git-ignored on purpose — it holds tenant-specific values. Never commit it.
- No secrets belong in this file. It is for identifiers and tuning knobs (tenant IDs, page sizes,
  output paths), not passwords or tokens — auth is handled interactively at run time (see
  [Authentication](#authentication)).
