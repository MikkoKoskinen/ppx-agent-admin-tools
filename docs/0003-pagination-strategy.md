# 0003 — Pagination strategy: `skipToken` vs. `Options.Skip`

**Status:** Resolved (superseded an earlier fix) · **First landed:** post-0.1.0 · **Revised:** later
same cycle

## Context — v1: single-page truncation

The first working version fired one request with `Options.Top = 1000` and ignored continuation
entirely, so a tenant with (e.g.) 5,377 agents silently exported only 1,000 rows
(`resultTruncated = true` in the sidecar, easy to miss).

## v1 fix: implement `skipToken` paging

`Connect-PPXInventoryApi.ps1` looped on the response's `skipToken`, feeding it back into
`Options.SkipToken` until the service returned none, concatenating all pages. Azure Resource Graph
caps a page at 1000 rows, so `-Top` became a per-request page size, not a total cap. Added: an
`orderby ... name` tie-breaker (skipToken paging is only stable with a fully deterministic sort), a
defensive de-dup keyed on `id`/`name`, and a 5000-page safety cap.

This worked in initial testing and shipped.

## v2 — the bug came back at scale

A run against a large tenant (thousands of agents) hit `Failed to acquire OBO token` after ~30
minutes / 758 pages, having already returned 758,000+ rows for a tenant the PPAC UI confirmed has
5,530 real agents.

### Diagnosis

Three theories were chased and ruled out, in order:

1. **A server-side `leftouter` join to environments** — removed as a general robustness win, but a
   follow-up run with no join *still* hit 397,000+ rows at page 397. Not the cause (kept removed
   anyway — see "Decision" below).
2. **Volatile sort key** (`tostring(properties.createdAt) desc, name asc`, matching PPAC's own UI
   default) — switched to `name` alone (an immutable GUID). A further run *still* hit 142,000+ rows
   at page 142. Not the cause.
3. **`Options.SkipToken` itself never advances** — confirmed with a live A/B/C/D test: requesting
   "page 2" by echoing the server's own `skipToken` back (`Skip=0, SkipToken=<token from page 1>`)
   returned page 1 again byte-for-byte (0 of 1,000 rows different, reproduced across 3 consecutive
   pages). Requesting `Skip=1000` with an **empty** `SkipToken` returned a fully disjoint page (2,000
   of 2,000 rows different). `skipToken` makes zero real forward progress for this query/tenant,
   independent of sort key or join.

### Decision

- `Connect-PPXInventoryApi` no longer uses `skipToken` for continuation. It pages with plain
  `Options.Skip` offsets (`page * pageSize`, confirmed live to advance correctly), stopping when a
  page returns fewer rows than requested. The function's return envelope always reports
  `skipToken = $null` now (kept in the shape for compatibility).
- The server-side join to environments was kept removed even though it wasn't the root cause — it's
  a genuine efficiency win (one row per agent per page, no join evaluated every page).
  `Connect-PPXInventoryApi` now queries agents alone and gained a `-Clauses` override so other
  callers can reuse the same paging/auth machinery with a different query.
  `private/Resolve-PPXEnvironmentLookup.ps1` queries environments separately and
  `Get-PPXAgentGovernanceBaseline.ps1` joins the two client-side.
- **Token expiry on long runs**, surfaced as `400 Bad Request: Failed to acquire OBO token`: the
  same delegated token, acquired once at the start, became too stale after ~30 minutes for the
  backend's on-behalf-of exchange to Azure Resource Graph. Token acquisition is now a reusable
  scriptblock; on an HTTP 401, or an HTTP 400 whose body mentions `OBO token`/`AADSTS`, the token is
  refreshed and the request retried once before giving up. (This retry pattern was later found
  missing from other tools that had copied the older `Connect-PPXInventoryApi.ps1` — see
  [ADR-0005](0005-custom-connector-usage-data-sources.md).)

### Accepted limitation

Offset paging is a position, not a snapshot boundary: an agent inserted (or resorted ahead of the
current page by the `name` sort) while a run is still paging can shift a later page and be silently
skipped without `resultTruncated` ever being set. Accepted, because `skipToken` (the alternative)
doesn't work at all against this API/query, and the agent set changes far more slowly than one run's
paging window takes to complete. Called out in `Connect-PPXInventoryApi.ps1`'s help, the persisted
`.limitations.txt`, and `PPXAgentGovernanceBaseline.md` §8, so it reaches a report reader as well as
the source.

## Consequences

Any future tool paging this Inventory API/query combination should use `Options.Skip`, not
`skipToken`, from the start — and should build in the token-refresh-on-401 retry rather than
re-discovering the OBO-expiry failure independently (as Custom Connector Usage initially did).
