# 0004 — Owner identity resolution and the managed-agent placeholder

**Status:** Resolved (two follow-up corrections) · **First landed:** post-0.1.0

## Context

`OwnerName` / `OwnerUPN` / `OwnerAccountStatus` were blank stub columns. The design mirrors the
client-side-join pattern `Resolve-PPXEnvironmentLookup` established for
`EnvironmentName`/`EnvironmentType`.

## Decision — resolution design

`private/Resolve-PPXOwnerIdentity.ps1` batch-resolves the distinct `ownerId` GUIDs collected across
all agent records via Microsoft Graph's `POST /v1.0/directoryObjects/getByIds`, in chunks of up to
1000 ids (the endpoint's documented cap) — rather than one Graph call per agent, or the 20-request
cap of the generic `$batch` endpoint. `types: ['user', 'servicePrincipal']` covers both possible
owner kinds without needing to guess which one an id is first. Auth reuses the same delegated Az
PowerShell token pattern as `Connect-PPXInventoryApi.ps1` (a second
`Get-AzAccessToken -ResourceUrl https://graph.microsoft.com` call against the already-signed-in Az
context) — no separate sign-in or Graph module required.

`OwnerAccountStatus` resolves to:
- `Active` / `Disabled` — real directory object found.
- `NotFound` — id no longer resolves to a directory object; a leaver/orphan signal in its own right.
- `GraphError` — the Graph call itself failed this run, kept distinct from `NotFound` so a transient
  failure isn't misreported as a real finding.

Failures are tracked **per chunk** in a `$failedIds` set, so a failed batch only marks the ids that
actually belonged to it as `GraphError` — not every id still unresolved at the end of the run
(the original bug: a single run-wide `$graphErrorSeen` flag mislabeled unrelated, successfully
resolved ids). A 401 mid-run triggers one token refresh + retry, matching
[ADR-0003](0003-pagination-strategy.md)'s pattern; if the refresh itself throws, that's now caught
and routed to the same per-chunk `GraphError` path instead of aborting the whole report. A Graph
outage warns once per run (gated behind `$warnedGraphFailure`), not once per 1000-id batch.

## Decision — managed-agent placeholder (two iterations)

A live run showed Microsoft-shipped managed agents (e.g. `D365 Sales - Data Enrichment`) have no
individual owner. A blank `OwnerName` would be indistinguishable from a real data gap, so
`Get-PPXAgentGovernanceBaseline.ps1` gives these an explicit placeholder.

**First attempt (wrong):** keyed "no owner" off `ownerId` being blank. Live data showed managed
agents still carry a real-looking `ownerId` (e.g. an all-zero sentinel GUID) that
`Resolve-PPXOwnerIdentity` dutifully looked up and got back a genuine `NotFound` — so every managed
agent fell through to the "resolved" branch with a blank `OwnerName` and
`OwnerAccountStatus = 'NotFound'`, and the placeholder never appeared.

**Fix:** key the decision on `properties.isManaged` (`IsManagedAgent`, a confirmed field), not
`ownerId` content:
- Managed agents are excluded from the Graph batch entirely and get
  `OwnerName = "Microsoft (managed agent)"` / `OwnerAccountStatus = "NotApplicable"` directly.
- A non-managed agent with a genuinely blank `ownerId` gets `OwnerName = "(no owner)"` /
  `OwnerAccountStatus = "NotApplicable"`, same as before.
- `OwnerUPN` stays blank in both cases; `OwnerId` is unchanged.

## Consequences

Any future "is this a real gap or an expected non-value" distinction on agent data should check
`IsManagedAgent` (or an equivalently confirmed structural field) rather than inferring it from
whether a related lookup happened to succeed or fail.
