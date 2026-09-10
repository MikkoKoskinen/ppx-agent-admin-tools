# Contributing

## Git identity

Commit with your personal email, not a work address:

```
git config user.email you@example.com
git config user.name  "Your Name"
```

## Secret & internal-identifier scanning

This repo is scanned by [gitleaks](https://github.com/gitleaks/gitleaks). CI runs it on every
push and pull request (`.github/workflows/gitleaks.yml`, plus a weekly full-history sweep), and a
local pre-commit hook catches problems before they reach a commit.

### One-time setup per clone

1. Install gitleaks:
   - Windows: `winget install gitleaks`
   - macOS: `brew install gitleaks`
   - Or download from the [releases page](https://github.com/gitleaks/gitleaks/releases).
2. Enable the hook:

   ```
   git config core.hooksPath .githooks
   ```

The hook runs `gitleaks protect --staged` and blocks the commit on a finding.

### What is checked

- The default gitleaks ruleset — API keys, tokens, private keys, connection strings, and similar.
- A custom rule for internal user handles that must not appear in committed content.
- Shared config: [`.gitleaks.toml`](.gitleaks.toml) at the repo root. CI and the hook both use it.

### Handling a finding

- **Real secret** — remove it and rotate the credential. If it was already committed, tell the
  maintainer: history in a shared repo has to be rewritten (`git filter-repo`), not just fixed in
  a new commit.
- **False positive** — add an `allowlist` entry to `.gitleaks.toml` with a comment explaining why
  the value is safe. See the existing entry for the Power Platform API resource ID.

### Bypassing

`git commit --no-verify` skips the hook for one commit. CI still runs on push, so only use this
for changes you are certain are clean.

## Tenant-specific values

Real tenant IDs, environment IDs, and generated reports never get committed:

- Copy `ppx.settings.example.psd1` to `ppx.settings.psd1` (git-ignored) for your own values.
- Report output goes to `reports/` (git-ignored).
- VS Code debug harnesses are named `Debug-*.ps1` (git-ignored).
