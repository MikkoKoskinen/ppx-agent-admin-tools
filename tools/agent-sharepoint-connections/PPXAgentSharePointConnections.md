# PPX Agent SharePoint Connections — solution description

## 1. Purpose
Answer "which agents use SharePoint as knowledge, and which sites/folders?" — a data-exposure and
governance question the admin center and Inventory API cannot answer directly.

## 2. Audience
Power Platform / M365 admins, security and governance teams, SharePoint owners.

## 3. Goals
One row per `(agent × SharePoint knowledge source)`; tenant-wide or limited to selected environments.

## 4. Scope
In: published/visible V2 Copilot Studio agents with knowledge count > 0. Out: V1/classic bots,
owner name resolution (later), writes of any kind.

## 5. Report schema
See README "Report columns".

## 6. Technical design
### 6.1 Pipeline
Inventory (environments, agents) → filter `componentsCounts.knowledge > 0` → group by environment →
Dataverse `botcomponents` read per environment → YAML parse → rows → CSV + sidecar.

### 6.2 API research outcome (Learn, 2026-11-04)
- Power Platform API `copilotstudio/bots` (2024-10-01): delete, reassign, quarantine, connector consent
  bypass, maker evaluation. No definition / knowledge operation. No read-definition permission scope.
- Inventory `microsoft.copilotstudio/agents`: `IsWebSearchEnabledForKnowledge` and counts only;
  `powerPlatformConnectors[].operations[].usedAs = Knowledge` exists but tabular connectors such as
  SharePoint report empty `operations`.
- Therefore Dataverse `botcomponents` is the only route to the URLs (unofficial for this use).

### 6.3 Environment selection
`-EnvironmentId` adds `name in~ (...)` to the environment query and `properties.environmentId in~ (...)`
to the agent query. If the Inventory API rejects the nested-field filter, the tool falls back to a
tenant-wide agent pull and filters client-side (noted in the sidecar). Client-side filtering is
always applied as well.

### 6.4 Authentication
Delegated Az PowerShell tokens (ADR-0002 pattern): Power Platform API, Dataverse org URL (per
environment), and BAP (`https://service.powerapps.com/`) only as an instance-URL fallback.

### 6.5 Dataverse read
`GET {org}/api/data/v9.2/botcomponents?$filter=(_parentbotid_value eq <id> or ...)` in chunks of 15
agents, `@odata.nextLink` followed, 429 retried, 401 refreshed once. No `$select`, no component-type
filter by default (value unconfirmed); knowledge components are recognised from content.

### 6.6 Parsing
Regex over `content`/`data`: `KnowledgeSourceConfiguration`, `kind: *Source`, `site:`; fallback to the
first `*.sharepoint.*` URL. No YAML library in Windows PowerShell 5.1.

## 7. Implementation status
First version. Offline smoke-tested with mocked APIs and run successfully against a live tenant
(single-tenant, small sample). Experimental until it has been run across more environments.

## 8. Assumptions to keep an eye on
The first live run worked end to end, but these were designed against unofficial or undocumented
behaviour and may differ in other tenants, clouds or agent types:
1. Inventory environment record carries the Dataverse URL (else BAP fallback is used).
2. Inventory `properties.botId` equals `botcomponents._parentbotid_value`.
3. Knowledge component YAML shape and `componenttype` value (printed in the run summary).
4. Server-side `properties.environmentId` filter accepted by the Inventory API.

## 9. Dependencies
`Az.Accounts`; Inventory API access; Dataverse read access per environment.

## 10. Relationship to other tools
Complements Agent Governance Baseline (which reports only `KnowledgeCount`). Helpers are copied per
tool per repo convention (`Connect-PPXInventoryApi`, `Get-PPXNestedValue`).
