# PhaseZero Installation Errors - Analysis & Opportunities

## Project Understanding

**PhaseZero** is a Windows/Steam Deck post-install bootstrap hub that automates environment setup through profiles (base, containers, AI, Steam Deck, etc.). It provides:
- CLI (`bootstrap-tools.ps1`) and UI (`bootstrap-ui.ps1`) interfaces
- Profile-based installation (legacy, base, containers, ai, steamdeck-*)
- Component dependency resolution
- App tuning and host health checks
- MCP (Model Context Protocol) server management
- Agent skills installation (Caveman, etc.)

## Critical Errors Preventing Installation

### 1. Backend Crash on Startup (2026-05-01)
**Symptom**: Backend exits with code 1, no log file created, no result.json written.

**Root Cause**: `bootstrap-tools.ps1` line ~14108 invokes `Invoke-BootstrapProfileMode` which calls `Write-Log` at line 13638. However, if any error occurs BEFORE line 13638 (during parameter processing, preflight, or component resolution), the log file doesn't exist yet, and the catch block at 14112 tries to write to `$script:ResultPath` which may not be properly initialized.

**Specific Issue**: The `Build-BackendArguments` function (line 4017) passes `-LogPath` and `-ResultPath` to the backend, but if the backend crashes during argument parsing or early initialization, these paths aren't used to create error output.

### 2. Manual-Required Component Blocking
**Symptom**: Installation aborts with "Dependencia manual obrigatoria ausente: Google App Desktop"

**Root Cause**: `google-app-desktop` component (line 7813) has `-Kind 'manual-required'`. When `Ensure-BootstrapManualRequirement` (line 7729) detects it's not installed, it THROWS an error (line 7759) unless `Optional` property is true (line 7755).

**Problem**: This component is included in `base` profile (line 7956) and `recommended` expansion, making it impossible to install without manually installing Google App Desktop first.

**Affected Components** (all `manual-required`):
- `google-app-desktop` (line 7813)
- `amd-adrenalin` (line 7884)
- `cru` (line 7885)
- `lossless-scaling` (line 7921)
- `macrium-reflect` (line 7922)
- `joyshockmapper` (line 7923)
- `vibrancegui` (line 7924)
- `steamdeck-driver-pack` (line 7925)
- `obs-source-record-plugin` (line 7926)
- `pagefile-on-sd` (line 7928)

### 3. Log File Encoding Issues
**Symptom**: `ui-debug.log` shows UTF-16 LE BOM encoding (garbled characters when read)

**Root Cause**: `debug-ui.ps1` line 5 uses `Out-File` without specifying encoding. PowerShell's default is UTF-16 LE.

**Impact**: Makes log analysis difficult; `Append-RunLog` (line 4045) uses `[IO.File]::ReadAllText` which expects proper encoding.

### 4. Pester Test Failures
**Location**: `tests/bootstrap-ui-launcher.tests.ps1`

**Failing Tests** (from codex-pester-run/stdout.log lines 113-151):
- Line 76: Assertion failure in UI launcher test
- Line 210: Another assertion failure

**Root Cause**: UI logic bugs in `bootstrap-ui.ps1` related to grid loading and component resolution display.

## Opportunities for Improvement

### 1. Error Handling & Diagnostics
- **Add early try/catch in backend startup** (before line 13638) to catch initialization errors
- **Write fallback result.json immediately** when backend starts, even before log file creation
- **Add `-SkipManualRequirements` flag** to allow skipping manual-required components
- **Improve UI feedback** when backend crashes (show meaningful error instead of generic "Backend saiu sem result.json")

### 2. Installation Flow
- **Make manual-required components optional by default** in profiles, requiring explicit opt-in
- **Add UI checkbox** to skip manual-required dependencies
- **Separate `verify` stage** from `payload` stage so verification doesn't block installation
- **Allow partial profile installation** when some components fail

### 3. Code Quality
- **Fix log encoding**: Create `Write-BootstrapUtf8File` helper to replace all `Out-File`/`Add-Content` calls
- **Standardize error handling**: Ensure all code paths write result.json on failure
- **Fix Pester tests**: Address UI logic bugs causing test failures
- **Clean up warnings**: "runtime ausente" for optional agent skills fills logs unnecessarily

### 4. User Experience
- **Better preflight messages**: Instead of aborting, warn and continue when possible
- **Dry-run by default**: First run should be dry-run with clear "Apply" button
- **Progress reporting**: Show which component is being processed in UI
- **Log viewer**: Add ability to open log file directly from UI

## Recommended Action Plan

1. **Fix backend crash** - Add try/catch at `bootstrap-tools.ps1` startup to write error result before any operations
2. **Make manual-required skippable** - Add `-SkipManualRequirements` parameter and UI checkbox
3. **Fix log encoding** - Force UTF-8 without BOM for all file operations
4. **Fix Pester UI tests** - Debug and fix the failing test assertions
5. **Improve error messages** - Provide actionable guidance when installation fails

## Files Requiring Changes

| File | Changes Needed |
|------|----------------|
| `bootstrap-tools.ps1` | Early error handling, manual-required skip logic, UTF-8 helpers |
| `bootstrap-ui.ps1` | Skip checkbox, better crash feedback, UTF-8 fixes |
| `debug-ui.ps1` | Fix Out-File encoding |
| `tests/bootstrap-ui-launcher.tests.ps1` | Fix failing test assertions |
| Component definitions | Review manual-required vs optional classification |
