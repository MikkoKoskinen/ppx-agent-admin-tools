# 0002 — Authentication via Az.Accounts instead of MSAL.PS

**Status:** Resolved · **First landed:** 0.1.0

## Context

The scaffold authenticated with MSAL.PS using client id `8578e004-a5c6-46e7-913e-12f58912df43` and
scope `https://api.powerplatform.com/.default`.

## What we found

That client id is the Power Platform API's **resource** application, not a client. Requesting a
token for that scope while authenticating *as* the same app produces:

```
AADSTS90009: Application '…' is requesting a token for itself
```

Microsoft publishes no sample public client for this API, so registering a dedicated Entra app was
the only "correct" alternative — but that requires every user of the tool to register and consent
their own app.

## Decision

`Connect-PPXInventoryApi` uses **`Az.Accounts`** instead: `Connect-AzAccount` +
`Get-AzAccessToken -ResourceUrl https://api.powerplatform.com`, borrowing the already-consented Az
PowerShell first-party client. This avoids requiring an app registration for the common case.

- `Connect-AzAccount` only runs when `Get-AzContext` is empty or bound to a different tenant;
  otherwise the cached context is reused with no prompt.
- `Get-AzAccessToken` returns `Token` as a `SecureString` on Az.Accounts 5.x and a plain string on
  earlier versions — the connect script unwraps both.
- `-UseDeviceAuthentication` (and `Common.UseDeviceAuthentication`) was added because the
  interactive WAM browser prompt hangs inside the VS Code PowerShell Integrated
  Console/debugger — the native dialog can't attach to the embedded console. Device-code flow works
  there.
- A tenant id is required (`-TenantId` or the settings file); `Get-PPXAgentGovernanceBaseline`
  throws with setup instructions if none resolves. No tenant id is committed to the repo.

## Consequences

The Entra app-registration route still exists as an alternative for environments that can't or
won't use the Az PowerShell client — documented as "Option B" in `SETTINGS.md`.
