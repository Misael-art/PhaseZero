# Drive Label UI CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** expose safe Windows/Linux/SteamOS drive diagnostics and label application in UI and CLI.

**Architecture:** `bootstrap-tools.ps1` owns detection, safety, CLI mode, and JSON output. `bootstrap-ui.ps1` owns Health-page UX: diagnose first, advanced apply second, double confirmation, no hidden drive mutation. Tests cover backend behavior and UI wiring.

**Tech Stack:** PowerShell 5.1, WPF/XAML in `bootstrap-ui.ps1`, Pester 3.4.0.

---

### Task 1: CLI Surface

**Files:**
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-os-install-safety.tests.ps1`

- [x] Add switches `-PartitionLabels` and `-ApplyPartitionLabels`.
- [x] Add `Invoke-BootstrapPartitionLabelsMode` returning result JSON with `status`, `mode`, `plan`, `result`, `apply`, and `exitCode`.
- [x] Keep default diagnose-only; application requires `-ApplyPartitionLabels` and `PHASEZERO_PARTITION_LABEL_APPLY=1`.
- [x] Add tests proving diagnose does not call `Set-BootstrapVolumeLabel`, apply without env is blocked/planned, and apply with env calls only safe volumes.

### Task 2: UI Wiring

**Files:**
- Modify: `F:\Projects\PhaseZero\bootstrap-ui.ps1`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-ui-launcher.tests.ps1`

- [x] Add Health buttons: `Diagnosticar drives`, `Modo avançado`, `Aplicar rótulos seguros`.
- [x] Add readonly grid/list showing identity, role, label atual, label sugerido, action, reasons.
- [x] Add helper functions to run backend with `-PartitionLabels` and optional `-ApplyPartitionLabels`.
- [x] Add double confirmation: advanced enabled plus exact typed phrase before apply.

### Task 3: Count/Null Robustness

**Files:**
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`
- Modify: `F:\Projects\PhaseZero\bootstrap-ui.ps1`
- Test: existing focused suites.

- [x] Materialize arrays with `@(...)` before `.Count`.
- [x] Make UI summary tolerate missing `entries`, `result`, or `changed` fields.
- [x] Verify no log path throws on empty plan.

### Task 4: Verification

**Commands:**
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\_parse-check.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -Command 'Import-Module Pester -RequiredVersion 3.4.0 -Force; Invoke-Pester -Script .\tests\bootstrap-os-install-safety.tests.ps1'`
- `powershell -NoProfile -ExecutionPolicy Bypass -Command 'Import-Module Pester -RequiredVersion 3.4.0 -Force; Invoke-Pester -Script .\tests\bootstrap-ui-launcher.tests.ps1'`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -PartitionLabels -DryRun -NonInteractive`
