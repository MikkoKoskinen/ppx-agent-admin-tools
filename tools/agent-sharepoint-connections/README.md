# Agent SharePoint Connections

Lists every Copilot Studio (V2) agent that uses **SharePoint as a knowledge source**, with the attached
SharePoint URLs — for the whole tenant or only selected environments. Read-only. **First version,
experimental** — see "Verify on first run".

## Why it needs more than the Inventory API

The Power Platform Inventory API exposes only knowledge **counts** per agent
(`componentsCounts.knowledge`), and no official Power Platform API returns an agent's definition or
knowledge sources (checked against the Power Platform REST reference, Nov 2026). So the tool:

1. Reads agents + environments from the Inventory API (all, or the `-EnvironmentId` selection).
2. Keeps agents with at least one knowledge source.
3. Per environment, reads the agents' Dataverse `botcomponents` rows (unofficial, read-only).
4. Parses each knowledge-source component's YAML (`source.kind: SharePointSearchSource`, `site: <url>`).
5. Writes one row per SharePoint source.

## Usage

```powershell
. .\tools\agent-sharepoint-connections\Get-PPXAgentSharePointConnections.ps1

Get-PPXAgentSharePointConnections                                   # all environments
Get-PPXAgentSharePointConnections -EnvironmentId <guid>             # one environment
Get-PPXAgentSharePointConnections -EnvironmentId <g1>,<g2>          # several
Get-PPXAgentSharePointConnections -MaxEnvironments 3 -Verbose       # quick test
Get-PPXAgentSharePointConnections -IncludeAllKnowledge              # also non-SharePoint sources
```

| Parameter | Meaning |
|---|---|
| `-TenantId` | Entra tenant (or `Common.TenantId` in `ppx.settings.psd1`). |
| `-EnvironmentId` | Optional GUID(s). Omit = all environments. Filtered server-side where the API accepts it, always again client-side. |
| `-MaxEnvironments` | Cap the Dataverse scan to N environments. |
| `-IncludeAllKnowledge` | Also emit public-website and other source kinds. |
| `-ScanAllAgents` | Also scan agents whose Inventory knowledge count is 0 (diagnostic). |
| `-KnowledgeComponentType` | Server-side `componenttype` filter once confirmed (see report column `ComponentType`). |
| `-Top`, `-MaxPages` | Inventory paging controls. |
| `-OutputPath`, `-ExportReport` | CSV location / return rows only. |
| `-UseDeviceAuthentication` | Device-code sign-in (VS Code debugger). |

Settings section: `AgentSharePointConnections` in `ppx.settings.psd1`.

## Prerequisites

- `Az.Accounts` module; a user who can read the Inventory API (Power Platform admin / equivalent).
- Read access to the Dataverse `botcomponents` table in each scanned environment (e.g. System
  Administrator). Environments without access appear as `Error (...)` rows.

## Report columns

`EnvironmentId, EnvironmentName, EnvironmentType, AgentId, AgentName, SchemaName, IsManagedAgent,
OwnerId, LastPublishedAt, KnowledgeCountInventory, KnowledgeSourceName, SourceKind, SharePointUrl,
SiteHost, ComponentType, ComponentId, Status`

`Status` is `Found` or `Error (<reason>)`. A `.limitations.txt` sidecar lists the run summary,
INCOMPLETE flags, per-environment errors and the standing caveats.

## Checks worth doing on a new tenant

The tool relies on unofficial behaviour (see `PPXAgentSharePointConnections.md` §8). It has run
successfully on a live tenant, but on a new one run against a single environment with a known
SharePoint-knowledge agent first (`-EnvironmentId <guid> -Verbose`) and check:

- The Dataverse org URL is found (Inventory environment record, else BAP fallback).
- Inventory `properties.botId` matches `botcomponents._parentbotid_value`.
- The YAML shape matches; the run summary prints the observed `componenttype` values.

## Known limitations

See the sidecar and `PPXAgentSharePointConnections.md`. Owner name/UPN resolution is not included yet
(only `OwnerId`).
