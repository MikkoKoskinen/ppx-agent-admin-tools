# 0001 — Inventory API request contract (KQLOM)

**Status:** Resolved · **First landed:** 0.1.0

## Context

The initial scaffold posted an invented `{ select, from, where }` body to an Inventory API URL with
no `api-version`, and never succeeded.

## What we found

- **Endpoint:** `POST https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01`.
  `api-version` is mandatory; omitting it returns `HTTP 400 (Bad Request)`.
- **Body shape** is the documented Azure Resource Graph query-object contract ("KQLOM"):
  `{ TableName: 'PowerPlatformResources', Options: { Top, Skip }, Clauses: [...] }`, where `Clauses`
  is an array of typed clause objects (`extend`, `join`, `where`, `project`, `orderby`).
- **`$type` must be the first property of every clause object.** The service deserialises `Clauses`
  polymorphically (System.Text.Json), which reads the type discriminator as the leading property. A
  plain PowerShell `@{}` hashtable has no guaranteed key order, so `ConvertTo-Json` emitted `$type`
  in arbitrary positions and the service returned `400 … KQLOM format is wrong or it cannot be null`.
- **Resource type:** Copilot Studio V2 agents are `microsoft.copilotstudio/agents`, not
  `microsoft.copilotstudio/bots` (the scaffold's guess — not a valid inventory resource type).
- **Response envelope:** `{ totalRecords, count, resultTruncated, skipToken, data[] }`. Records are
  in `data`, not `value`.
- **Error surfacing:** `Invoke-RestMethod` on PowerShell 7 raises `HttpResponseException` with the
  body in `$_.ErrorDetails.Message`; Windows PowerShell 5.1 exposes it via
  `$_.Exception.Response.GetResponseStream()` instead.

## Decision

- Every clause object is built with `[ordered]@{ '$type' = …; … }` so `$type` always serialises
  first.
- Queries use `microsoft.copilotstudio/agents`.
- The `catch` block reads `ErrorDetails.Message` first and falls back to the response stream on
  PS 5.1, then rethrows with the API's specific message appended.
- The default query mirrors the Power Platform admin center pattern: `extend` a lowercased join key
  → `join kind=leftouter` to environments → `where type in~ (...)` → `orderby`. (The server-side
  join was later removed for unrelated reasons — see [ADR-0003](0003-pagination-strategy.md).)

## Consequences

Any new Inventory API query in this repo should start from this contract (ordered clause hashtables,
`api-version=2024-10-01`, reading `data` not `value`) rather than re-deriving it from the API's
sparse public documentation.
