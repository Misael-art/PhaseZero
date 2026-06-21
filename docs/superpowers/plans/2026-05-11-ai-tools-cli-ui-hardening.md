# AI Tools CLI/UI Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline because user requested autonomous execution without review pause. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe, optional AI coding tool detection/install/validate/uninstall flows and close launcher/CLI validation gaps.

**Architecture:** Keep risky installs opt-in. Put shared AI tool metadata and operations in `bootstrap-tools.ps1`; call them from `install-cli.ps1`; surface status/actions in `bootstrap-ui.ps1`. Use user/temp prefixes and manifest ownership so uninstall removes only project-managed artifacts.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4, npm prefix installs, GitHub release metadata, WPF XAML.

---

### Task 1: Tests First

**Files:**
- Modify: `tests/bootstrap-ui-launcher.tests.ps1`
- Create: `tests/ai-tools.tests.ps1`

- [ ] Add tests for AI tool catalog source URLs, CLI flags, XAML controls, no mojibake, dry-run, temp-prefix install/uninstall, path-with-spaces.
- [ ] Run focused tests and confirm failures before production changes.

### Task 2: Shared AI Tool Layer

**Files:**
- Modify: `bootstrap-tools.ps1`

- [ ] Add catalog for RTK, Claude Code, OpenCode, Hermes Agent, Hermes Desktop, OpenClaw, Aion UI, Antigravity workflows.
- [ ] Add detect/status/validate/install/uninstall functions with project-managed manifest and no secret writes.
- [ ] Use only official install methods; unsupported items return `manual` or `blocked` with official docs link.

### Task 3: CLI Flow

**Files:**
- Modify: `install-cli.ps1`
- Modify: `install-cli.bat`

- [ ] Add `-Tool`, `-AllAiTools`, `-Validate`, `-Uninstall`, `-DryRun`, `-Yes`, `-NoAdmin`, `-InstallRoot`, structured JSON logs/result.
- [ ] Preserve old profile flow.

### Task 4: UI Surface

**Files:**
- Modify: `bootstrap-ui.ps1`

- [ ] Add page/section “AI Coding Tools”.
- [ ] Show status rows and action buttons: install, validate, configure, uninstall, docs.
- [ ] Add destructive confirmation for uninstall and status text with manual/blocked states.

### Task 5: Verification

**Files:**
- Modify: `README.md`
- Create: `docs/ai-tools.md`

- [ ] Document official source decisions and limitations.
- [ ] Run parse, contract, UI smoke, install-cli smoke, focused Pester, controlled temp install/uninstall.
