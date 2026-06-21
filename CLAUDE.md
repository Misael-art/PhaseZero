# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project shape

PhaseZero is a Windows / Steam Deck post-install bootstrap orchestrator written in Windows PowerShell 5.1. It is **not** a multi-module application — almost the entire runtime lives in two large monolith scripts plus PowerShell asset scripts and a Pester test suite:

- `bootstrap-tools.ps1` (~16k lines, ~430 functions) — CLI orchestrator. Profiles, components, AppTuning catalog, secrets manifest, managed MCPs, audit/repair, rollback, checkpoint/resume.
- `bootstrap-ui.ps1` (~5.8k lines, ~100 functions) — WPF UI. Reads a JSON contract from `bootstrap-tools.ps1 -UiContractJson` and dispatches selections back to it.
- `bootstrap-ui.bat` / `install-cli.bat` / `install-cli.ps1` — Windows launchers. They re-spawn `powershell.exe -NoProfile -ExecutionPolicy Bypass` against the two `.ps1` files.
- `assets/steamdeck/{automation,maintenance}/*.ps1` — standalone Steam Deck mode scripts (`Apply-Handheld`, `Apply-DockedTv`, `Apply-DockedMonitor`, `Apply-SteamDeckTweaks`, `Start-ConsoleSession`, `ModeWatcher`, etc.) sharing `SteamDeck.Common.ps1`.
- `tests/*.tests.ps1` — Pester 3.4 suite. Most tests load the orchestrator via `. .\bootstrap-tools.ps1 -BootstrapUiLibraryMode`, which dot-sources function definitions without running the bootstrap pipeline.

Local state (never committed) lives under `.bootstrap-tools/`: `bootstrap-secrets.json`, `bootstrap-mcp-state.json`, `vscode-extension-state.json`, `agent-skill-state.json`, checkpoints, change manifests for rollback.

## Commands you will actually run

Always run from repo root in a Windows shell. The Bash tool here uses Unix-style paths but PowerShell commands themselves use Windows conventions.

```powershell
# parse-only sanity check (matches CI's Parse step)
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\bootstrap-tools.ps1), [ref]$tokens, [ref]$errors); $errors | Format-List
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\bootstrap-ui.ps1),    [ref]$tokens, [ref]$errors); $errors | Format-List

# full Pester suite (CI uses Pester 3.4.0 exactly — newer versions can pass tests CI fails)
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester -Path .\tests -EnableExit

# single test file
Invoke-Pester -Path .\tests\resilience.tests.ps1 -EnableExit

# diagnostic / dry runs (safe, no host mutation)
.\bootstrap-tools.ps1 -Doctor -DryRun -NonInteractive
.\bootstrap-tools.ps1 -Profile base -DryRun -NonInteractive
.\bootstrap-tools.ps1 -Audit  -DryRun -NonInteractive
.\bootstrap-tools.ps1 -ListProfiles
.\bootstrap-tools.ps1 -ListApps
.\bootstrap-tools.ps1 -ListComponents

# UI contract used by bootstrap-ui.ps1 (must produce valid JSON, no stderr)
.\bootstrap-tools.ps1 -UiContractJson -NonInteractive | ConvertFrom-Json | Out-Null

# WPF launcher smoke test (no window) — MUST emit JSON only, no stderr
cmd /c bootstrap-ui.bat -SmokeTest

# rollback recorded mutations
.\bootstrap-tools.ps1 -Rollback -NonInteractive
```

CI (`.github/workflows/ci.yml`, `windows-latest`) runs three steps in order: install Pester 3.4.0, recursively `Parser::ParseFile` every `*.ps1`, then `Invoke-Pester -Path .\tests -EnableExit`. Match locally before pushing.

## Architecture notes (the things you can't see from one file)

### Library mode vs. execution mode

`bootstrap-tools.ps1` has a special `-BootstrapUiLibraryMode` switch. When set, the script defines all functions then short-circuits the main pipeline. Tests and `bootstrap-ui.ps1` rely on this to load functions without provisioning the host. When adding a new top-level function, make sure it is defined *before* the main run-guard so library mode picks it up; when adding new execution side-effects, make sure they are inside the run-guard so library mode doesn't trigger them.

### UI ↔ orchestrator contract

The UI does not import functions from the orchestrator. They communicate via:
1. `bootstrap-tools.ps1 -UiContractJson` → JSON describing pages, profiles, components, app catalog, languages, state path. The UI consumes this on startup. Anything you add to the UI must first be exposed through the contract.
2. The UI re-spawns `bootstrap-tools.ps1` with selection flags (`-Profile`, `-App`, `-Component`, `-AppTuningItem`, etc.) to actually do work. There is no in-process function call across the boundary.
Breaking either side without updating the other will silently degrade the UI even if both files parse fine.

### Resilience layer (cross-cutting)

All long-running mutations route through four cooperating subsystems, all defined in `bootstrap-tools.ps1`:
- **Checkpoint/Resume** — `Save-BootstrapCheckpoint` / `Load-BootstrapCheckpoint`. Pipeline writes per-component progress so `-Resume` can pick up.
- **Change manifest / rollback** — `Register-BootstrapChange`, `Save-BootstrapChangeManifest`, `Invoke-BootstrapRollback`, `Invoke-BootstrapAutoRollback`. Every registry write, env var, file mutation should call `Register-BootstrapChange` so `-Rollback` / `-AutoRollback` can reverse it.
- **JIT disk guard** — `Assert-BootstrapDiskSpace` / `Test-BootstrapDiskSpace` are called before heavy components, not just at startup.
- **Audit / Repair** — `Invoke-BootstrapAuditMode` (line ~568) inspects component health and, with `-Repair`, reinstalls degraded items.
When you add a component that mutates host state, wire it into Register-BootstrapChange and (if it has a recognizable installed signature) into the audit table — otherwise users get partial rollback and lying `-Audit` output.

### Component / profile model

Three entry points define the surface area surfaced to UI and CLI; touching one usually means touching all three:
- `New-BootstrapComponentDefinition` — declares the actual installer (`winget`, `chocolatey`, `npm`, `uvtool`, `manual-required`, `builtin`).
- `Get-BootstrapOnDemandAppDefinitions` — exposes apps for `-App` and the on-demand UI list.
- `Get-BootstrapAppTuningCatalog` — groups optimizations and per-app installs on the **Otimizar Apps** page.
Profiles (`base`, `ai`, `full`, `steamdeck-recommended`, `steamdeck-input-advanced`, `legacy`, …) are bundles over these definitions.

### Secrets manifest

`bootstrap-secrets` component manages `.bootstrap-tools/bootstrap-secrets.json`. Each provider (`openai`, `anthropic`, `google`, `openrouter`, `github`, `moonshot`, `deepseek`; `bonsai` = `unsupported/manual-review`) holds many named credentials, one active, plus a manual rotation queue. Downstream components (OpenCode, Continue, Cursor MCPs, Cline, Roo, …) **only apply** a credential when its `validation.state == passed`. Adding a provider means: writing a validator, wiring activation/rotation, and adding the provider to whichever consumers should auto-receive it. Never log raw secret values; the existing helpers mask them.

### Managed MCPs

`bootstrap-mcps` reapplies a curated MCP catalog (Markitdown, Context7, Playwright, GitHub MCP, Serena, Firecrawl, Desktop Commander, Notion, Supabase, Figma, Apify, Vercel, Box, Chrome DevTools, Netdata) across Claude Code, Claude Desktop, Cursor, Windsurf, Trae, OpenCode, VS Code, Roo, Cline, Continue, Zed, ZCode, OpenClaw. Local MCPs use `npx` / `uv tool`; remote MCPs use `mcp-remote@latest` to avoid scattering tokens. State: `.bootstrap-tools/bootstrap-mcp-state.json`. Provider gating uses the same `validation.state == passed` rule, except a small bypass list (`context7`, `firecrawl`, `apify`, `netdata`, `supabase`) used for OAuth/manual-token flows.

### Steam Deck modes

`assets/steamdeck/automation/Detect-Mode.ps1` + `ModeWatcher.ps1` classify the active display via `Classify-ExternalDisplay.ps1` and dispatch to the matching `Apply-*.ps1` (Handheld / DockedTv / DockedMonitor). All of those source `SteamDeck.Common.ps1` for shared helpers. `steamdeck-recommended` keeps the safe stack (Steam Deck Tools portable by ayufan + Playnite fallback). The advanced stack (Handheld Companion, GlosSI) is opt-in because it conflicts with Steam Input Desktop Layout — preserve that gate.

## House style

- `AGENTS.md`, `.cursor/rules/caveman.mdc`, `.windsurf/rules/caveman.md`, `.clinerules/caveman.md`, `.github/copilot-instructions.md` all enable **Caveman mode** for free-form replies (terse, no filler, fragments OK). It explicitly **does not** apply to code, commits, or PR descriptions — keep those normal.
- These caveman files are regenerated by the `agent-skills` component from `assets/agent-skills/caveman-always-on.md` between `<!-- BEGIN BOOTSTRAP CAVEMAN -->` / `<!-- END BOOTSTRAP CAVEMAN -->` markers. Edit the source asset, not the rendered copies.
- README.md is in Brazilian Portuguese; user-facing strings, log messages, and component descriptions in `bootstrap-tools.ps1` / `bootstrap-ui.ps1` follow suit. Code identifiers stay in English.
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` are set at the top of every script. Keep that contract — uninitialized variables and swallowed errors will surface immediately.
- Never commit: `.bootstrap-tools/`, `.mcp.json` (only `.mcp.example.json`), `gemini-cli/`, `.serena/`, `.claude/`, `Microsoft/`, ad-hoc helper scripts (`add-trap-handler.ps1`, `fix-backend-crash.ps1`) — all already in `.gitignore`.
