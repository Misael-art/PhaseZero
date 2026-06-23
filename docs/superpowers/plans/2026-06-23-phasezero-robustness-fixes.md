# PhaseZero Robustness Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix CLI/CX robustness gaps found after MCP repair commit `b1a3136`: scope-safe apply commands, reliable result artifacts, safer rollback for file edits, clearer argument errors, and stronger process supervision.

**Architecture:** Keep changes inside the existing PowerShell surfaces. `install-cli.ps1` owns CLI argument parsing, result envelopes, apply-command rendering, and child process launching. `bootstrap-tools.ps1` owns stateful file rollback registration and MCP/lifecycle backend behavior. Tests stay in existing Pester suites and should prove each bug before implementation.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4, existing PhaseZero helpers (`Write-CliJsonResult`, `Write-BootstrapJsonFile`, `Register-BootstrapChange`, `Invoke-BootstrapMcpConfigRepair`), `rtk` command prefix.

---

## Context

Use caveman mode and `rtk` for shell commands. Do not revert unrelated work. Current audit note: `notes/phasezero-robustness-opportunity-audit-2026-06-23.md` in ai-memory.

Confirmed issues:

- `Format-CliApplyCommand` drops `--exclude-config`; dry-run preview may apply broader scope.
- `--repair-mcp` does not write `result.json` or log even when paths are supplied.
- `Read-CliArgs` consumes the next flag as a value when a value is missing.
- `Register-BootstrapChange -Type File` is used without backup paths for existing files; rollback can remove repaired configs.
- CLI child processes use raw `Start-Process -Wait` without timeout/stdout/stderr fallback.
- lifecycle and drift CLI modes bypass the common result envelope.
- UI MCP repair runs synchronously on the WPF thread and leaves no artifact.

## File Map

- Modify: `F:\Projects\PhaseZero\install-cli.ps1`
  - argument parsing guards
  - apply command rendering
  - MCP repair result envelope
  - lifecycle/drift result envelope
  - backend process helper
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`
  - file rollback backup helper
  - replace unsafe direct `Register-BootstrapChange -Type File` calls
- Modify: `F:\Projects\PhaseZero\bootstrap-ui.ps1`
  - route MCP repair through existing run/artifact path or add non-blocking artifact-producing handler
- Modify: `F:\Projects\PhaseZero\tests\bootstrap-cli-ui-coherence.tests.ps1`
  - CLI scope/CX tests
- Modify: `F:\Projects\PhaseZero\tests\bootstrap-mcp-repair.tests.ps1`
  - MCP repair rollback/artifact tests
- Modify: `F:\Projects\PhaseZero\tests\resilience.tests.ps1`
  - file rollback helper tests
- Modify: `F:\Projects\PhaseZero\tests\bootstrap-ui-launcher.tests.ps1`
  - UI MCP handler static/contract test

---

### Task 1: Preserve Exact Scope In Apply Command

**Files:**
- Modify: `F:\Projects\PhaseZero\install-cli.ps1:1308`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-cli-ui-coherence.tests.ps1`

- [ ] **Step 1: Write failing test**

Append this test inside `Describe 'CLI and UI coherence'`:

```powershell
    It 'preserves excluded configs in the printed apply command' {
        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-exclude-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--config-category browser-startup --exclude-config zen-browser-privacy-prefs --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath)

            $run.ExitCode | Should Be 0
            $applyLine = [regex]::Match($run.Stdout, '(?m)^Aplicar:\s*(?<cmd>.+)$')
            $applyLine.Success | Should Be $true
            [string]$applyLine.Groups['cmd'].Value | Should Match '--config-category\s+browser-startup'
            [string]$applyLine.Groups['cmd'].Value | Should Match '--exclude-config\s+zen-browser-privacy-prefs'
            [string]$applyLine.Groups['cmd'].Value | Should Match '--yes'
            [string]$applyLine.Groups['cmd'].Value | Should Not Match '--dry-run'
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-cli-ui-coherence.tests.ps1
```

Expected: new test fails because `--exclude-config` is missing from `Aplicar:`.

- [ ] **Step 3: Implement minimal fix**

In `install-cli.ps1`, add a small helper near `Format-CliApplyCommand`:

```powershell
function Add-CliCommandOptionValues {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Parts,
        [Parameter(Mandatory = $true)][string]$OptionName,
        [AllowNull()]$Values
    )

    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $Parts.Add($OptionName) | Out-Null
        $Parts.Add((Format-CliCommandToken -Value ([string]$value))) | Out-Null
    }
}
```

Replace the repeated loops in `Format-CliApplyCommand` with:

```powershell
    Add-CliCommandOptionValues -Parts $parts -OptionName '--app' -Values $Options.App
    Add-CliCommandOptionValues -Parts $parts -OptionName '--component' -Values $Options.Component
    Add-CliCommandOptionValues -Parts $parts -OptionName '--config' -Values $Options.Config
    Add-CliCommandOptionValues -Parts $parts -OptionName '--config-category' -Values $Options.ConfigCategory
    Add-CliCommandOptionValues -Parts $parts -OptionName '--exclude-config' -Values $Options.ExcludeConfig
    $parts.Add('--yes') | Out-Null
```

Do not include `--dry-run`. Do not drop any selection/exclusion values.

- [ ] **Step 4: Run test to verify pass**

Run same Pester command. Expected: all tests pass.

- [ ] **Step 5: Commit**

```powershell
rtk git add -- install-cli.ps1 tests/bootstrap-cli-ui-coherence.tests.ps1
rtk git commit -m "Preserve CLI apply scope exclusions"
```

---

### Task 2: Reject Missing CLI Values Before Consuming Flags

**Files:**
- Modify: `F:\Projects\PhaseZero\install-cli.ps1:83`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-cli-ui-coherence.tests.ps1`

- [ ] **Step 1: Write failing test**

Append this test inside `Describe 'CLI and UI coherence'`:

```powershell
    It 'reports a missing option value without treating the next flag as a selection' {
        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-missing-value-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--config --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath)

            $run.ExitCode | Should Be 2
            Test-Path -LiteralPath $resultPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'argument-parse'
            [string]$json.error | Should Match 'Valor ausente.*--config'
            [string]$json.error | Should Not Match "configuracao encontrado para '--dry-run'"
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-cli-ui-coherence.tests.ps1
```

Expected: new test fails because current parser consumes `--dry-run` as a config value.

- [ ] **Step 3: Add parser helpers**

In `install-cli.ps1`, add before `Read-CliArgs`:

```powershell
function Get-CliRawOptionValue {
    param(
        [string[]]$Tokens,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $wanted = @{}
    foreach ($name in @($Names)) {
        $wanted[(ConvertTo-CliKey -Token $name)] = $true
    }

    for ($i = 0; $i -lt @($Tokens).Count; $i++) {
        $token = [string]$Tokens[$i]
        if ($token -match '^(--?[^=]+)=(.*)$') {
            $key = ConvertTo-CliKey -Token $matches[1]
            if ($wanted.ContainsKey($key)) { return [string]$matches[2] }
            continue
        }
        if ($token -match '^[-/]') {
            $key = ConvertTo-CliKey -Token $token
            if ($wanted.ContainsKey($key) -and (($i + 1) -lt @($Tokens).Count)) {
                $candidate = [string]$Tokens[$i + 1]
                if (-not (Test-CliTokenLooksLikeOption -Token $candidate)) { return $candidate }
            }
        }
    }
    return ''
}

function Test-CliTokenLooksLikeOption {
    param([AllowNull()][string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    return ([string]$Token -match '^[-/][A-Za-z][A-Za-z0-9-]*$')
}

function Read-CliRequiredOptionValue {
    param(
        [Parameter(Mandatory = $true)][string[]]$Tokens,
        [Parameter(Mandatory = $true)][ref]$Index,
        [Parameter(Mandatory = $true)][string]$OptionName
    )

    $next = [int]$Index.Value + 1
    if ($next -ge @($Tokens).Count) {
        throw "Valor ausente para $OptionName."
    }
    $candidate = [string]$Tokens[$next]
    if (Test-CliTokenLooksLikeOption -Token $candidate) {
        throw "Valor ausente para $OptionName."
    }
    $Index.Value = $next
    return $candidate
}
```

In every `if ($null -eq $value) { $i++; $value = [string]$Tokens[$i] }` branch for value options, replace with:

```powershell
if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
```

Apply to: `profile`, `tool`, `item`, `app`, `component`, `config`, `configuration`, `apptuningitem`, `configcategory`, `apptuningcategory`, `excludeconfig`, `excludeapptuningitem`, `exportconfig`, `importconfig`, `batch`, `installroot`, `resultpath`, `logpath`.

- [ ] **Step 4: Catch parse errors with result envelope**

Change the initial parse block from direct assignment to this version. It pre-scans artifact paths so parse errors still honor supplied `--result-path` and `--log-path`:

```powershell
$rawResultPath = Get-CliRawOptionValue -Tokens @($args) -Names @('--result-path', '-ResultPath')
$rawLogPath = Get-CliRawOptionValue -Tokens @($args) -Names @('--log-path', '-LogPath')
try {
    $script:Options = Read-CliArgs -Tokens @($args)
} catch {
    $script:Options = New-CliOptions
    $root = if ($env:TEMP) { $env:TEMP } else { $PSScriptRoot }
    $script:Options.LogPath = if ([string]::IsNullOrWhiteSpace($rawLogPath)) { Join-Path $root ("phasezero-install-cli-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)) } else { $rawLogPath }
    $script:Options.ResultPath = if ([string]::IsNullOrWhiteSpace($rawResultPath)) { Join-Path $root ("phasezero-install-cli-{0:yyyyMMdd-HHmmss}.result.json" -f (Get-Date)) } else { $rawResultPath }
    Write-CliLegacyFailureResult -Message $_.Exception.Message -ExitCode 2 -Mode 'argument-parse' -HowToFix 'Informe valor apos a opcao ou use --help para exemplos.'
    Write-CliOut ("Result: {0}" -f [string]$script:Options.ResultPath) Yellow
    Write-CliOut ("Log:    {0}" -f [string]$script:Options.LogPath) Yellow
    exit 2
}
```

- [ ] **Step 5: Run test to verify pass**

Run the coherence suite. Expected: all pass.

- [ ] **Step 6: Commit**

```powershell
rtk git add -- install-cli.ps1 tests/bootstrap-cli-ui-coherence.tests.ps1
rtk git commit -m "Validate CLI option values before parsing"
```

---

### Task 3: Emit Result Envelope For MCP Repair CLI

**Files:**
- Modify: `F:\Projects\PhaseZero\install-cli.ps1:1624`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-cli-ui-coherence.tests.ps1`

- [ ] **Step 1: Write failing test**

Append:

```powershell
    It 'writes result json for MCP repair dry-run' {
        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-mcp-repair-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--repair-mcp --dry-run --yes --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath)

            $run.ExitCode | Should Be 0
            Test-Path -LiteralPath $resultPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'mcp-repair'
            [bool]$json.dryRun | Should Be $true
            $json.PSObject.Properties.Name -contains 'targets' | Should Be $true
            $json.PSObject.Properties.Name -contains 'artifactPaths' | Should Be $true
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run coherence suite. Expected: result file missing.

- [ ] **Step 3: Implement envelope**

Modify `Invoke-CliMcpRepair` to return an exit code and always call `Write-CliJsonResult`:

```powershell
    $payload = [ordered]@{
        status = 'success'
        mode = 'mcp-repair'
        action = $(if ($apply) { 'apply' } else { 'dry-run' })
        dryRun = (-not $apply)
        totalFixed = [int]$preview.totalFixed
        targets = @($preview.targets)
        verification = $null
        message = ''
        nextSteps = @()
    }
```

When `totalFixed -eq 0`, set:

```powershell
        $payload['message'] = 'Nenhum comando npx puro encontrado nos configs MCP.'
        $payload['nextSteps'] = @('Nada a reparar.')
        Write-CliJsonResult -Payload $payload -ResultPath ([string]$Options.ResultPath)
        return 0
```

When dry-run would fix:

```powershell
        $payload['message'] = ("{0} entrada(s) seriam corrigidas." -f [int]$preview.totalFixed)
        $payload['nextSteps'] = @('.\install-cli.bat --repair-mcp --yes')
        Write-CliJsonResult -Payload $payload -ResultPath ([string]$Options.ResultPath)
        return 0
```

When apply runs:

```powershell
    $result = Invoke-BootstrapMcpConfigRepair
    $verify = Invoke-BootstrapMcpConfigRepair -DryRun
    $payload['dryRun'] = $false
    $payload['action'] = 'apply'
    $payload['totalFixed'] = [int]$result.totalFixed
    $payload['targets'] = @($result.targets)
    $payload['verification'] = $verify
    $payload['status'] = if ([int]$verify.totalFixed -eq 0) { 'success' } else { 'warning' }
    $payload['message'] = ("Reparo MCP corrigiu {0} entrada(s); restantes={1}." -f [int]$result.totalFixed, [int]$verify.totalFixed)
    $payload['nextSteps'] = @('Reinicie os apps MCP/IDE para reconectar.')
    Write-CliJsonResult -Payload $payload -ResultPath ([string]$Options.ResultPath)
    return $(if ([int]$verify.totalFixed -eq 0) { 0 } else { 1 })
```

Change caller:

```powershell
if ([bool]$script:Options.RepairMcp) {
    exit (Invoke-CliMcpRepair -Options $script:Options)
}
```

- [ ] **Step 4: Run test to verify pass**

Run coherence suite. Expected: all pass.

- [ ] **Step 5: Commit**

```powershell
rtk git add -- install-cli.ps1 tests/bootstrap-cli-ui-coherence.tests.ps1
rtk git commit -m "Write result envelope for MCP repair"
```

---

### Task 4: Safe File Rollback Backups

**Files:**
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1:587`
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1:20321`
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1:20499`
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1:20550`
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1:21691`
- Test: `F:\Projects\PhaseZero\tests\resilience.tests.ps1`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-mcp-repair.tests.ps1`

- [ ] **Step 1: Write failing rollback helper test**

Add under `Context 'Rollback'` in `resilience.tests.ps1`:

```powershell
        It 'restores an existing file from a registered rollback backup' {
            $tempDir = Join-Path $env:TEMP ('bootstrap-file-rollback-test-' + ([Guid]::NewGuid().ToString()))
            $null = New-Item -Path $tempDir -ItemType Directory -Force
            try {
                $target = Join-Path $tempDir 'config.json'
                [System.IO.File]::WriteAllText($target, 'before', [System.Text.UTF8Encoding]::new($false))
                $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot $tempDir -ResolvedCloneBaseDir $tempDir
                $state.ChangeManifestPath = Join-Path $tempDir 'changes.json'

                Register-BootstrapFileChange -State $state -Target $target -Operation 'test-file-update' -Component 'test'
                [System.IO.File]::WriteAllText($target, 'after', [System.Text.UTF8Encoding]::new($false))
                Invoke-BootstrapRollback -ChangesPath $state.ChangeManifestPath | Out-Null

                [string](Get-Content -LiteralPath $target -Raw) | Should Be 'before'
            } finally {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
```

- [ ] **Step 2: Write failing MCP rollback test**

Add to `bootstrap-mcp-repair.tests.ps1`:

```powershell
    It 'registers a file backup so rollback restores repaired MCP config instead of deleting it' {
        . $scriptPath -BootstrapUiLibraryMode
        if (-not (Test-BootstrapHostIsWindows)) { return }
        $root = Join-Path $env:TEMP ("pz-mcprepair-rollback-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $null = New-Item -Path $root -ItemType Directory -Force
        $cfg = Join-Path $root 'mcp.json'
        $original = '{"mcpServers":{"pw":{"command":"npx","args":["-y","x"]}}}'
        Set-Content -LiteralPath $cfg -Value $original -Encoding UTF8
        try {
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot $root -ResolvedCloneBaseDir $root
            $state.ChangeManifestPath = Join-Path $root 'changes.json'

            $r = Invoke-BootstrapMcpConfigRepair -ConfigPaths @($cfg) -State $state
            [int]$r.totalFixed | Should Be 1
            Test-Path -LiteralPath $state.ChangeManifestPath | Should Be $true
            $manifest = Get-Content -LiteralPath $state.ChangeManifestPath -Raw | ConvertFrom-Json
            [string]$manifest.changes[0].Type | Should Be 'File'
            [string]::IsNullOrWhiteSpace([string]$manifest.changes[0].OldValue) | Should Be $false
            Test-Path -LiteralPath ([string]$manifest.changes[0].OldValue) | Should Be $true

            Invoke-BootstrapRollback -ChangesPath $state.ChangeManifestPath | Out-Null
            Test-Path -LiteralPath $cfg | Should Be $true
            (Get-Content -LiteralPath $cfg -Raw) | Should Match '"command"\s*:\s*"npx"'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\resilience.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-mcp-repair.tests.ps1
```

Expected: first fails because helper missing. Second fails because manifest has blank `OldValue`.

- [ ] **Step 4: Add file helper**

Add after `Register-BootstrapChange` in `bootstrap-tools.ps1`:

```powershell
function Register-BootstrapFileChange {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Operation = 'file-update',
        [string]$Component = '',
        [AllowNull()]$NewValue = $null
    )

    $oldValue = $null
    if (Test-Path -LiteralPath $Target) {
        $manifestPath = Get-BootstrapChangeManifestPath -State $State
        $backupRoot = Join-Path (Split-Path -Path $manifestPath -Parent) 'file-backups'
        $null = New-Item -Path $backupRoot -ItemType Directory -Force
        $leaf = Split-Path -Path $Target -Leaf
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'file' }
        $backupPath = Join-Path $backupRoot ("{0}-{1}.bak" -f ([Guid]::NewGuid().ToString('N')), $leaf)
        Copy-Item -LiteralPath $Target -Destination $backupPath -Force -ErrorAction Stop
        $oldValue = $backupPath
    }

    Register-BootstrapChange -State $State -Type File -Target $Target -OldValue $oldValue -NewValue $NewValue -Operation $Operation -Component $Component -RollbackAction $(if ($oldValue) { 'restore-file-backup' } else { 'remove-created-file' }) -Reversible 'partial'
}
```

PowerShell parse note: if the inline conditional after `-RollbackAction` causes parsing trouble, assign `$rollbackAction` first:

```powershell
$rollbackAction = if ($oldValue) { 'restore-file-backup' } else { 'remove-created-file' }
Register-BootstrapChange ... -RollbackAction $rollbackAction ...
```

- [ ] **Step 5: Replace unsafe file registrations**

Replace these patterns:

```powershell
Register-BootstrapChange -State $State -Type File -Target $configPath -OldValue $null -NewValue 'mimocode-provider' -Operation 'configure-mimocode' -Component 'mimo-code'
Register-BootstrapChange -State $State -Type File -Target ([string]$targetPath) -Operation 'import-item-config' -Component $desc.id
Register-BootstrapChange -State $State -Type File -Target $path -Operation 'factory-reset' -Component $desc.id
Register-BootstrapChange -State $State -Type File -Target $path -Operation 'repair-mcp-npx' -Component ([string]$t.id)
```

With:

```powershell
Register-BootstrapFileChange -State $State -Target $configPath -NewValue 'mimocode-provider' -Operation 'configure-mimocode' -Component 'mimo-code'
Register-BootstrapFileChange -State $State -Target ([string]$targetPath) -Operation 'import-item-config' -Component $desc.id
Register-BootstrapFileChange -State $State -Target $path -Operation 'factory-reset' -Component $desc.id
Register-BootstrapFileChange -State $State -Target $path -Operation 'repair-mcp-npx' -Component ([string]$t.id)
```

- [ ] **Step 6: Run tests to verify pass**

Run both suites from Step 3. Expected: all pass.

- [ ] **Step 7: Commit**

```powershell
rtk git add -- bootstrap-tools.ps1 tests/resilience.tests.ps1 tests/bootstrap-mcp-repair.tests.ps1
rtk git commit -m "Back up files before rollback registration"
```

---

### Task 5: Add Timeout/Capture Helper For CLI Child Backend

**Files:**
- Modify: `F:\Projects\PhaseZero\install-cli.ps1:1432`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-cli-ui-coherence.tests.ps1`

- [ ] **Step 1: Add static failing test**

Add:

```powershell
    It 'uses a guarded backend process helper instead of raw Start-Process wait in CLI execution paths' {
        $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install-cli.ps1') -Raw

        $raw | Should Match 'function Invoke-CliBackendProcess'
        $raw | Should Match 'WaitForExit\(\$TimeoutMs\)'
        $raw | Should Match 'Write-CliLegacyFailureResult'
        $raw | Should Not Match '\$dryProcess\s*=\s*Start-Process -FilePath ''powershell\.exe'' -ArgumentList \$dryArgs -NoNewWindow -PassThru -Wait'
        $raw | Should Not Match '\$installProcess\s*=\s*Start-Process -FilePath ''powershell\.exe'' -ArgumentList \$installArgs -NoNewWindow -PassThru -Wait'
    }
```

- [ ] **Step 2: Run test to verify failure**

Run coherence suite. Expected: fails because helper missing/raw waits exist.

- [ ] **Step 3: Implement guarded helper**

Add near process helpers:

```powershell
function ConvertTo-CliCommandLineArgument {
    param([AllowNull()][string]$Token)

    if ($null -eq $Token) { return '""' }
    $text = [string]$Token
    if ($text.Length -eq 0) { return '""' }
    if ($text -notmatch '[\s"`&\(\)\^]') { return $text }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        if ($ch -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($ch -eq [char]'"') {
            if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
            [void]$builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-CliArgumentString {
    param([string[]]$Tokens)
    return [string]::Join(' ', @($Tokens | ForEach-Object { ConvertTo-CliCommandLineArgument -Token ([string]$_) }))
}

function Invoke-CliBackendProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [int]$TimeoutMs = 1800000
    )

    $stdoutPath = [System.IO.Path]::ChangeExtension([string]$script:Options.ResultPath, ".$OperationName.stdout.log")
    $stderrPath = [System.IO.Path]::ChangeExtension([string]$script:Options.ResultPath, ".$OperationName.stderr.log")
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = ConvertTo-CliArgumentString -Tokens $ArgumentList
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch { }
            $message = ("{0} excedeu timeout de {1}ms." -f $OperationName, $TimeoutMs)
            Write-CliLegacyFailureResult -Message $message -ExitCode 124 -Mode $OperationName -HowToFix 'Revise stdout/stderr/log e rode novamente com escopo menor ou Doctor.'
            return [pscustomobject]@{ ExitCode = 124; TimedOut = $true; StdoutPath = $stdoutPath; StderrPath = $stderrPath }
        }
        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        [System.IO.File]::WriteAllText($stdoutPath, $stdout, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($stderrPath, $stderr, [System.Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; TimedOut = $false; StdoutPath = $stdoutPath; StderrPath = $stderrPath }
    } finally {
        try { $process.Dispose() } catch { }
    }
}
```

- [ ] **Step 4: Replace raw waits in individual and profile paths**

Replace raw `Start-Process ... -Wait` calls in:

- `Invoke-CliMenuProfileFlow`
- `Invoke-CliMenuBackendIntent`
- `Invoke-CliBootstrapSelectionMode`
- profile dry-run/apply bottom section

Use:

```powershell
$dryRun = Invoke-CliBackendProcess -ArgumentList $dryArgs -OperationName 'dry-run'
$dryExit = [int]$dryRun.ExitCode
```

And:

```powershell
$installRun = Invoke-CliBackendProcess -ArgumentList $installArgs -OperationName 'apply'
$installExit = [int]$installRun.ExitCode
```

- [ ] **Step 5: Run coherence and profile tests**

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-cli-ui-coherence.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-tools.profiles.tests.ps1
```

Expected: all pass.

- [ ] **Step 6: Commit**

```powershell
rtk git add -- install-cli.ps1 tests/bootstrap-cli-ui-coherence.tests.ps1
rtk git commit -m "Guard CLI backend process waits"
```

---

### Task 6: Envelope Lifecycle And Drift CLI Modes

**Files:**
- Modify: `F:\Projects\PhaseZero\install-cli.ps1:1655`
- Modify: `F:\Projects\PhaseZero\install-cli.ps1:1753`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-cli-ui-coherence.tests.ps1`

- [ ] **Step 1: Write lifecycle result test**

Add:

```powershell
    It 'writes common envelope fields for lifecycle dry-run' {
        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-lifecycle-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        $exportDir = Join-Path $env:TEMP ("phasezero-export-{0}" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--item cursor --export-config "{0}" --dry-run --yes --result-path "{1}" --log-path "{2}"' -f $exportDir, $resultPath, $logPath)

            $run.ExitCode | Should Be 0
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'config-lifecycle'
            [bool]$json.dryRun | Should Be $true
            $json.PSObject.Properties.Name -contains 'artifactPaths' | Should Be $true
            $json.PSObject.Properties.Name -contains 'diagnostics' | Should Be $true
            $json.PSObject.Properties.Name -contains 'rollback' | Should Be $true
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $exportDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
```

- [ ] **Step 2: Run test to verify failure**

Expected: raw lifecycle JSON lacks common fields.

- [ ] **Step 3: Wrap lifecycle result**

At the end of `Invoke-CliLifecycleActions`, replace direct `Write-BootstrapJsonFile` with:

```powershell
    $payload = [ordered]@{
        status = 'success'
        mode = 'config-lifecycle'
        action = $action
        dryRun = $dry
        count = $(if ($result -is [System.Collections.IDictionary] -and $result.Contains('count')) { [int]$result['count'] } else { @($ids).Count })
        result = $result
        message = '[ciclo de vida] concluido.'
    }
    Write-CliJsonResult -Payload $payload -ResultPath ([string]$Options.ResultPath)
```

In `catch`, write:

```powershell
        Write-CliJsonResult -Payload ([ordered]@{
            status = 'error'
            mode = 'config-lifecycle'
            action = $action
            dryRun = $dry
            error = $_.Exception.Message
            howToFix = 'Revise item/path informado e rode --list-items para confirmar o alvo.'
        }) -ResultPath ([string]$Options.ResultPath)
        exit 1
```

- [ ] **Step 4: Wrap drift result**

In drift mode, after `$drift = Invoke-BootstrapDriftCheck`, write:

```powershell
    $payload = [ordered]@{
        status = $(if ([int]$drift.regressionCount -gt 0) { 'warning' } else { 'success' })
        mode = 'drift-check'
        dryRun = $true
        drift = $drift
        message = $(if (-not $drift.baselineExisted) { 'Baseline criado agora.' } elseif ([int]$drift.regressionCount -eq 0) { 'Nenhuma regressao desde o baseline.' } else { ("{0} regressao(oes)." -f [int]$drift.regressionCount) })
    }
    Write-CliJsonResult -Payload $payload -ResultPath ([string]$script:Options.ResultPath)
```

- [ ] **Step 5: Run coherence tests**

Expected: all pass.

- [ ] **Step 6: Commit**

```powershell
rtk git add -- install-cli.ps1 tests/bootstrap-cli-ui-coherence.tests.ps1
rtk git commit -m "Envelope lifecycle and drift CLI results"
```

---

### Task 7: Make UI MCP Repair Artifact-Producing

**Files:**
- Modify: `F:\Projects\PhaseZero\bootstrap-ui.ps1:7399`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-ui-launcher.tests.ps1`

- [ ] **Step 1: Add static contract test**

Add to `bootstrap-ui-launcher.tests.ps1`:

```powershell
    It 'routes MCP repair through an artifact-producing command instead of direct synchronous repair' {
        $raw = Get-Content -LiteralPath $uiScriptPath -Raw

        $raw | Should Match 'HealthRepairMcpButton\.Add_Click'
        $raw | Should Match '--repair-mcp'
        $raw | Should Match '--result-path'
        $raw | Should Match '--log-path'
        $raw | Should Not Match '\$result\s*=\s*Invoke-BootstrapMcpConfigRepair\s*\r?\n\s*\$verify\s*=\s*Invoke-BootstrapMcpConfigRepair -DryRun'
    }
```

- [ ] **Step 2: Run test to verify failure**

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-ui-launcher.tests.ps1
```

Expected: fails due direct synchronous repair.

- [ ] **Step 3: Implement UI route**

Prefer using existing artifact runner. Minimal version: spawn `install-cli.bat --repair-mcp --yes --result-path <path> --log-path <path>` with hidden process and update status with artifact paths.

Inside handler after confirmation:

```powershell
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $artifacts = New-UiRunArtifactSet -Timestamp $timestamp
        $ui.CurrentLogPath = [string]$artifacts.LogPath
        $ui.CurrentResultPath = [string]$artifacts.ResultPath
        $installCli = Join-Path $PSScriptRoot 'install-cli.bat'
        $args = @(
            '--repair-mcp',
            '--yes',
            '--result-path', [string]$ui.CurrentResultPath,
            '--log-path', [string]$ui.CurrentLogPath
        )
        Start-Process -FilePath $installCli -ArgumentList (ConvertTo-ArgumentString -Tokens $args) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
        $ui.StatusLabel.Text = ("Reparo MCP iniciado. Result: {0}" -f [string]$ui.CurrentResultPath)
        Update-RunArtifactButtons
```

Use this minimal artifact-spawn path in this task. Do not add a new maintenance intent in this pass; that can be a later UI refactor after the CLI result envelope is stable.

- [ ] **Step 4: Run UI launcher tests**

Expected: pass.

- [ ] **Step 5: Commit**

```powershell
rtk git add -- bootstrap-ui.ps1 tests/bootstrap-ui-launcher.tests.ps1
rtk git commit -m "Route UI MCP repair through artifacts"
```

---

## Final Verification

- [ ] Run targeted suites:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-cli-ui-coherence.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-mcp-repair.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\resilience.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-ui-launcher.tests.ps1
```

- [ ] Run parser check:

```powershell
rtk powershell -NoProfile -Command "$files='bootstrap-tools.ps1','bootstrap-ui.ps1','install-cli.ps1'; foreach($f in $files){ $tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$tokens, [ref]$errors) > $null; if($errors){ $errors | Format-List; exit 1 } }"
```

- [ ] Run whitespace check:

```powershell
rtk git diff --check
```

- [ ] Run status:

```powershell
rtk git status --short
```

Expected: only intended files before final commit; clean after final commit.

## Suggested Commit Order

1. `Preserve CLI apply scope exclusions`
2. `Validate CLI option values before parsing`
3. `Write result envelope for MCP repair`
4. `Back up files before rollback registration`
5. `Guard CLI backend process waits`
6. `Envelope lifecycle and drift CLI results`
7. `Route UI MCP repair through artifacts`

## Self-Review

Spec coverage:
- Scope-safe apply command: Task 1.
- MCP result artifacts: Task 3.
- Parser value robustness: Task 2.
- File rollback safety: Task 4.
- CLI process resiliency: Task 5.
- lifecycle/drift result envelope: Task 6.
- UI MCP CX/artifact handoff: Task 7.

Placeholder scan:
- No placeholder tokens, no unspecified tests, no empty "add error handling" steps.

Type consistency:
- `Options.ExcludeConfig`, `Invoke-CliMcpRepair`, `Write-CliJsonResult`, `Register-BootstrapFileChange`, `Invoke-BootstrapRollback` match existing naming style.
