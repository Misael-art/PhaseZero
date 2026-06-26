# Agent Compat Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe compatibility runtime so Caveman, RTK, ai-memory, and Ponytail project rules can coexist across supported IDEs and CLIs without hard failures when optional tools are absent.

**Architecture:** Keep each integration in its own lane: Caveman controls response style, RTK wraps shell output only when installed, ai-memory handles memory/MCP/hooks only when installed, and Ponytail rules activate only for matching workspaces. A new builtin component writes an auditable compatibility state file and updates marked rule blocks idempotently.

**Tech Stack:** PowerShell 5.1, existing PhaseZero bootstrap helpers, Pester 3.4.

---

### Task 1: Compatibility Contract

**Files:**
- Modify: `bootstrap-tools.ps1`
- Modify: `assets/agent-skills/phasezero-tools-always-on.md`
- Test: `tests/bootstrap-agent-skills.tests.ps1`

- [ ] **Step 1: Write failing tests**

Add tests proving the PhaseZero tools rule degrades when RTK or ai-memory is absent, and proving `agent-compat-runtime` appears after `agent-skills` in the `ai` profile.

- [ ] **Step 2: Run tests and verify RED**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path tests\bootstrap-agent-skills.tests.ps1`

Expected: fails because compatibility functions/component do not exist yet.

- [ ] **Step 3: Implement minimal contract**

Add `Get-BootstrapAgentCompatPlan`, `Ensure-BootstrapAgentCompatRuntime`, component catalog entry, and profile wiring. Update the rule asset to say RTK/ai-memory are required only in ready mode and must degrade cleanly when absent.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path tests\bootstrap-agent-skills.tests.ps1 -PassThru`

Expected: all tests in file pass.

### Task 2: Ponytail Workspace Rules

**Files:**
- Create: `assets/agent-skills/ponytail-architecture-runtime.md`
- Modify: `bootstrap-tools.ps1`
- Test: `tests/bootstrap-agent-skills.tests.ps1`

- [ ] **Step 1: Write failing tests**

Add tests proving Ponytail rules are skipped in a normal workspace and applied only when a workspace has Tauri/Rust plus SGDK/Ponytail signals.

- [ ] **Step 2: Run tests and verify RED**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path tests\bootstrap-agent-skills.tests.ps1`

Expected: fails because Ponytail detector and rule writer do not exist yet.

- [ ] **Step 3: Implement minimal Ponytail support**

Add `Test-BootstrapPonytailWorkspace`, `Get-BootstrapPonytailRuleBody`, and `Ensure-BootstrapPonytailRuleFiles` with marked blocks and Cursor/Windsurf front matter.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path tests\bootstrap-agent-skills.tests.ps1 -PassThru`

Expected: all tests in file pass.

### Task 3: Host Verification and Publish

**Files:**
- Verify only after Tasks 1-2 pass.

- [ ] **Step 1: Run targeted tests**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path tests\bootstrap-agent-skills.tests.ps1,tests\ai-tools.tests.ps1,tests\bootstrap-tools.profiles.tests.ps1 -PassThru`

Expected: pass.

- [ ] **Step 2: Run real host dry-run**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -Component agent-compat-runtime -DryRun -NonInteractive -ResultPath <temp.json> -LogPath <temp.log>`

Expected: status success and state shows degraded RTK/ai-memory when missing.

- [ ] **Step 3: Run real host apply**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -Component agent-compat-runtime -NonInteractive -AllowPendingReboot -ResultPath <temp.json> -LogPath <temp.log>`

Expected: status success; rules updated idempotently; Ponytail skipped unless detected.

- [ ] **Step 4: Commit and push**

Stage only files changed for this work, commit with `Add agent compatibility runtime`, push `main`.
