# 0006 — Settings: distinguishing "unset" from an explicit `$false`

**Status:** Resolved · **First landed:** post-0.1.0

## Context

`Get-PPXSettings.ps1` drops keys whose value is `''`, `0`, `$false`, or `$null` so callers can use a
plain truthiness check against the merged settings. `AgentGovernanceBaseline.ExportReport` needed a
default of `$true` that a user could still override to `$false` in their settings file.

## What we found

The drop condition compared each value to `0`. In PowerShell, `$false -eq 0` is `$true` — so an
explicit `ExportReport = $false` in the settings file was silently discarded as "unset" and treated
as not-present, defeating the whole point of a default-true-but-overridable setting.

## Decision

- The drop condition now only treats `$null`, `''`, and a genuinely numeric `0` as unset; `$false`
  (and `$true`) always survive.
- `Get-PPXAgentGovernanceBaseline.ps1`'s fallback for `ExportReport` uses
  `$settings.ContainsKey(...)` rather than truthiness, since truthiness alone still can't
  distinguish "unset" from "explicitly false."

## Consequences

Any future boolean setting that needs a non-default value to be a valid override (not just a
non-default value to be "on") should use the same `ContainsKey` check at the call site rather than
relying on the merged value's truthiness.
