# Emulation Shared Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a resilient, opt-in emulation runtime for Steam/Hydra that covers PCSX2/PS2, RPCS3/PS3, and Nintendo Switch emulator candidates without duplicating emulator installs or unsafe shared state.

**Architecture:** Treat emulators as canonical shared runtime entries, and treat launchers such as Hydra, Steam ROM Manager, EmuDeck, Playnite, and Steam Big Picture as consumers. One host gets one canonical emulator install/config root per emulator; launchers receive pointers, never duplicate binaries. Firmware, keys, saves, cache, mods, and ROM roots are classified by safety before sharing; Nintendo Switch candidates require explicit source trust and user-provided console dumps before any config is applied.

**Tech Stack:** Windows PowerShell 5.1, existing PhaseZero component/profile catalog in `bootstrap-tools.ps1`, Pester 3.4, JSON/YAML/INI config writers, `rtk` command prefix.

---

## Context

Inputs already analyzed:

- PS3/RPCS3 via Hydra transcript: Hydra config JSON, RPCS3 firmware install, RPCS3 `global_config.yml`, storage/watchdog ideas.
- PS2/PCSX2 via Hydra transcript: Hydra config JSON, PCSX2 Qt CLI flags, PS2 BIOS folder, PCSX2 INI profile, CHD/chdman optimization, watchdog idea.
- User correction: Nintendo Switch emulator options and friendly fixes must be covered. The current attached file for this correction is Umbrel/Homelab, not Switch, so Switch implementation stays source-gated and safety-first until exact emulator material is supplied.
- Current repo coverage: Steam/Steam Deck/EmuDeck guided flow exists; Hydra, PCSX2, RPCS3, Nuovo, CHD, Nintendo Switch emulator candidates, firmware/key gates, and shared emulation runtime do not exist.

Hard constraints:

- Do not download PS2 BIOS. User-provided only.
- Do not download Nintendo Switch prod.keys, title.keys, firmware, NAND, games, updates, DLC, or mods. User-provided own-console dumps only.
- Do not download ROMs, DLC, mods, keys, save files, or copyrighted game content.
- Do not duplicate emulator binaries/config roots per launcher.
- Do not share shader caches across emulator versions, GPU driver families, or different emulator engines.
- Do not share Nintendo Switch save/NAND writes across emulator families by default; use backup/export/import flows.
- Do not auto-install Nintendo Switch emulator forks. Use source-trust intake, user selection, and manual-required defaults.
- Do not write Hydra/RPCS3/PCSX2 configs while the target process is running unless dry-run only.
- Do not force-kill emulators by default. Watchdog is report-first; destructive cleanup is explicit opt-in.
- Nuovo has no supplied technical source yet. Add intake status only, no install/config behavior.

## File Map

- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`
  - component catalog: shared runtime, Hydra launcher, PCSX2, RPCS3, CHD tools
  - profile catalog: opt-in emulation profile for Steam/Hydra
  - host capability helpers
  - shared path layout helpers
  - config plan helpers
- Create: `F:\Projects\PhaseZero\tests\bootstrap-emulation-shared-runtime.tests.ps1`
  - catalog/profile coverage
  - no duplicate install roots
  - firmware safety gates
  - host capability recommendations
- Create: `F:\Projects\PhaseZero\tests\bootstrap-hydra-emulation-config.tests.ps1`
  - Hydra JSON merge safety
  - process lock guards
  - preservation of unknown config keys
- Create: `F:\Projects\PhaseZero\tests\bootstrap-emulation-host-profile.tests.ps1`
  - host profile classification
  - per-emulator tuning recommendations
- Create: `F:\Projects\PhaseZero\tests\bootstrap-switch-emulation-runtime.tests.ps1`
  - Nintendo Switch emulator candidate registry
  - keys/firmware/game-content safety gates
  - shared path matrix for keys, NAND, saves, shader cache, mods and metadata
- Create: `F:\Projects\PhaseZero\tests\bootstrap-emulation-friendly-fixes.tests.ps1`
  - user-friendly repair/action catalog for common emulator issues
  - non-destructive defaults and blocked unsafe actions

---

### Task 1: Add Catalog Tests For Shared Runtime

**Files:**
- Create: `F:\Projects\PhaseZero\tests\bootstrap-emulation-shared-runtime.tests.ps1`
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`

- [ ] **Step 1: Write failing catalog test**

Create `tests\bootstrap-emulation-shared-runtime.tests.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Shared emulation runtime catalog' {
    It 'declares one canonical shared runtime and launcher consumers' {
        $catalog = Get-BootstrapComponentCatalog

        foreach ($id in @(
            'emulation-shared-runtime',
            'hydra-launcher',
            'pcsx2',
            'rpcs3',
            'chdman-tools',
            'hydra-pcsx2-integration',
            'hydra-rpcs3-integration',
            'nuovo-emulation-intake'
        )) {
            $catalog.Contains($id) | Should Be $true
        }

        [string]$catalog['pcsx2'].sharedRuntimeKey | Should Be 'pcsx2'
        [string]$catalog['rpcs3'].sharedRuntimeKey | Should Be 'rpcs3'
        [string]$catalog['hydra-pcsx2-integration'].Kind | Should Be 'alias'
        [string]$catalog['hydra-rpcs3-integration'].Kind | Should Be 'alias'
        [string]$catalog['nuovo-emulation-intake'].Kind | Should Be 'manual-required'
    }

    It 'keeps firmware and game content behind legal/manual gates' {
        $catalog = Get-BootstrapComponentCatalog

        [string]$catalog['pcsx2'].firmwarePolicy | Should Be 'user-provided-only'
        [string]$catalog['rpcs3'].firmwarePolicy | Should Be 'official-or-user-provided'
        [string]$catalog['pcsx2'].romPolicy | Should Be 'user-owned-paths-only'
        [string]$catalog['rpcs3'].romPolicy | Should Be 'user-owned-paths-only'
        [string]$catalog['pcsx2'].Instructions | Should Match 'BIOS'
        [string]$catalog['pcsx2'].Instructions | Should Not Match 'Invoke-WebRequest.*scph'
    }

    It 'exposes opt-in profiles without adding emulators to steamdeck recommended' {
        $profiles = Get-BootstrapProfileCatalog

        $profiles.Contains('emulation-shared') | Should Be $true
        $profiles.Contains('emulation-hydra-ps2-ps3') | Should Be $true

        @($profiles['emulation-hydra-ps2-ps3'].Items) -contains 'emulation-shared-runtime' | Should Be $true
        @($profiles['emulation-hydra-ps2-ps3'].Items) -contains 'hydra-pcsx2-integration' | Should Be $true
        @($profiles['emulation-hydra-ps2-ps3'].Items) -contains 'hydra-rpcs3-integration' | Should Be $true

        @($profiles['steamdeck-recommended'].Items) -contains 'emulation-hydra-ps2-ps3' | Should Be $false
        @($profiles['steamdeck-full'].Items) -contains 'emulation-hydra-ps2-ps3' | Should Be $false
    }
}
```

- [ ] **Step 2: Run test to verify failure**

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-emulation-shared-runtime.tests.ps1
```

Expected: fails because catalog entries do not exist.

- [ ] **Step 3: Add catalog entries**

In `bootstrap-tools.ps1`, inside `Get-BootstrapComponentCatalog`, add near gaming/Steam Deck entries:

```powershell
    $catalog['emulation-shared-runtime'] = New-BootstrapComponentDefinition -Name 'emulation-shared-runtime' -Description 'Shared emulation runtime roots for canonical emulator binaries, configs, firmware, saves, cache and mods.' -Optional $true -DependsOn @('system-core') -Kind 'builtin' -Data @{ Stage = 'config'; Provisioning = 'builtin'; ValueReason = 'Prevents duplicate emulator installs across Hydra, Steam ROM Manager, EmuDeck, Playnite and Steam Big Picture.'; sharedRootDefault = '$env:USERPROFILE\Games\Emulation'; sharingPolicy = 'single-emulator-root'; riskLevel = 'safe' }
    $catalog['hydra-launcher'] = New-BootstrapComponentDefinition -Name 'hydra-launcher' -Description 'Hydra Launcher consumer for shared emulator runtime.' -Optional $true -DependsOn @('emulation-shared-runtime') -Kind 'manual-required' -Data @{ DisplayName = 'Hydra Launcher'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Acts as one frontend over existing canonical emulator installs.'; ProbePaths = @('$env:LOCALAPPDATA\Programs\Hydra\Hydra.exe', '$env:APPDATA\hydra'); Instructions = 'Install Hydra from its official project source, then close Hydra before applying emulator config merges.'; riskLevel = 'experimental'; requiresInteractiveLogin = $true }
    $catalog['pcsx2'] = New-BootstrapComponentDefinition -Name 'pcsx2' -Description 'PCSX2 Qt canonical PS2 emulator runtime.' -Optional $true -DependsOn @('emulation-shared-runtime', 'vcpp-redist', 'directx-runtime') -Kind 'manual-required' -Data @{ DisplayName = 'PCSX2 Qt'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Recommended PS2 engine; launchers should point to this single install instead of installing their own copies.'; ProbePaths = @('$env:ProgramFiles\PCSX2\pcsx2-qt.exe', '$env:LOCALAPPDATA\Programs\PCSX2\pcsx2-qt.exe', '$env:USERPROFILE\Games\Emulation\emulators\pcsx2\pcsx2-qt.exe'); Instructions = 'Install PCSX2 from the official project. Provide your own legally dumped PS2 BIOS in the shared firmware path. Do not download BIOS through PhaseZero.'; officialSource = 'https://pcsx2.net/downloads/'; sharedRuntimeKey = 'pcsx2'; firmwarePolicy = 'user-provided-only'; romPolicy = 'user-owned-paths-only'; preferredFrontend = 'standalone'; avoidLibretroForSystem = 'ps2'; riskLevel = 'manual' }
    $catalog['rpcs3'] = New-BootstrapComponentDefinition -Name 'rpcs3' -Description 'RPCS3 canonical PS3 emulator runtime.' -Optional $true -DependsOn @('emulation-shared-runtime', 'vcpp-redist', 'directx-runtime') -Kind 'manual-required' -Data @{ DisplayName = 'RPCS3'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Recommended PS3 engine; launchers should point to this single install/config root.'; ProbePaths = @('$env:ProgramFiles\RPCS3\rpcs3.exe', '$env:LOCALAPPDATA\Programs\RPCS3\rpcs3.exe', '$env:USERPROFILE\Games\Emulation\emulators\rpcs3\rpcs3.exe'); Instructions = 'Install RPCS3 from the official project. Install official PS3 firmware through RPCS3 or provide a verified PS3UPDAT.PUP. Do not automate game/DLC downloads.'; officialSource = 'https://rpcs3.net/download'; sharedRuntimeKey = 'rpcs3'; firmwarePolicy = 'official-or-user-provided'; romPolicy = 'user-owned-paths-only'; preferredFrontend = 'standalone'; riskLevel = 'manual' }
    $catalog['chdman-tools'] = New-BootstrapComponentDefinition -Name 'chdman-tools' -Description 'CHD conversion tools for user-owned PS2 disc images.' -Optional $true -DependsOn @('emulation-shared-runtime') -Kind 'manual-required' -Data @{ DisplayName = 'chdman'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Allows opt-in conversion of user-owned PS2 ISO/CSO images to CHD to reduce disk I/O and storage.'; ProbePaths = @('$env:ProgramFiles\MAME\chdman.exe', '$env:USERPROFILE\Games\Emulation\tools\chdman\chdman.exe'); Instructions = 'Install chdman from an official MAME distribution. Use only with user-owned disc images and keep originals until verification passes.'; contentPolicy = 'user-owned-input-only'; riskLevel = 'manual' }
    $catalog['hydra-pcsx2-integration'] = New-BootstrapComponentDefinition -Name 'hydra-pcsx2-integration' -Description 'Hydra Classic pointer to canonical PCSX2 runtime.' -Optional $true -DependsOn @('hydra-launcher', 'pcsx2') -Kind 'alias' -Data @{ Stage = 'config'; Provisioning = 'builtin'; ValueReason = 'Writes only launcher pointers to PCSX2; does not install a duplicate emulator.'; configTarget = '$env:APPDATA\hydra\emulators_config.json'; systemKey = 'playstation2'; launcherMode = 'pointer-only' }
    $catalog['hydra-rpcs3-integration'] = New-BootstrapComponentDefinition -Name 'hydra-rpcs3-integration' -Description 'Hydra Classic pointer to canonical RPCS3 runtime.' -Optional $true -DependsOn @('hydra-launcher', 'rpcs3') -Kind 'alias' -Data @{ Stage = 'config'; Provisioning = 'builtin'; ValueReason = 'Writes only launcher pointers to RPCS3; does not install a duplicate emulator.'; configTarget = '$env:APPDATA\hydra\emulators_config.json'; systemKey = 'playstation3'; launcherMode = 'pointer-only' }
    $catalog['nuovo-emulation-intake'] = New-BootstrapComponentDefinition -Name 'nuovo-emulation-intake' -Description 'Nuovo emulator/front-end intake placeholder until technical source is provided.' -Optional $true -DependsOn @('emulation-shared-runtime') -Kind 'manual-required' -Data @{ DisplayName = 'Nuovo'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Tracks user request without guessing install/config behavior.'; Instructions = 'Provide Nuovo technical source, config paths, supported systems and CLI flags before implementation.'; intakeStatus = 'blocked-missing-source'; riskLevel = 'blocked' }
```

Inside `Get-BootstrapProfileCatalog`, add near gaming profiles:

```powershell
    $catalog['emulation-shared'] = New-BootstrapProfileDefinition -Name 'emulation-shared' -Description 'Shared emulator runtime without launcher-specific duplication.' -Items @('emulation-shared-runtime', 'pcsx2', 'rpcs3', 'chdman-tools', 'nuovo-emulation-intake')
    $catalog['emulation-hydra-ps2-ps3'] = New-BootstrapProfileDefinition -Name 'emulation-hydra-ps2-ps3' -Description 'Opt-in Hydra pointers to canonical PCSX2 and RPCS3 runtimes.' -Items @('emulation-shared', 'hydra-launcher', 'hydra-pcsx2-integration', 'hydra-rpcs3-integration')
```

- [ ] **Step 4: Run test to verify pass**

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-emulation-shared-runtime.tests.ps1
```

Expected: pass.

- [ ] **Step 5: Commit**

```powershell
rtk git add -- bootstrap-tools.ps1 tests/bootstrap-emulation-shared-runtime.tests.ps1
rtk git commit -m "Add shared emulation runtime catalog"
```

---

### Task 2: Add Shared Path Layout And Safety Matrix

**Files:**
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-emulation-shared-runtime.tests.ps1`

- [ ] **Step 1: Add failing layout test**

Append:

```powershell
Describe 'Shared emulation runtime layout' {
    It 'classifies shareable and isolated paths by emulator and data kind' {
        $layout = Get-BootstrapEmulationSharedLayout -Root 'X:\Emulation'

        [string]$layout.root | Should Be 'X:\Emulation'
        [string]$layout.systems.ps2.emulatorKey | Should Be 'pcsx2'
        [string]$layout.systems.ps3.emulatorKey | Should Be 'rpcs3'

        [string]$layout.systems.ps2.firmware.policy | Should Be 'user-provided-only'
        [bool]$layout.systems.ps2.cache.shareAcrossVersions | Should Be $false
        [bool]$layout.systems.ps3.cache.shareAcrossVersions | Should Be $false
        [bool]$layout.systems.ps2.saves.shareWithLaunchers | Should Be $true
        [bool]$layout.systems.ps3.saves.shareWithLaunchers | Should Be $true
        [string]$layout.systems.ps3.storage.policy | Should Be 'single-rpcs3-dev_hdd0-root'
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Expected: `Get-BootstrapEmulationSharedLayout` missing.

- [ ] **Step 3: Implement layout helper**

Add near Steam Deck helper functions:

```powershell
function Get-BootstrapEmulationSharedLayout {
    param([string]$Root = '')

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Join-Path $env:USERPROFILE 'Games\Emulation'
    }

    return [ordered]@{
        root = $Root
        emulators = Join-Path $Root 'emulators'
        tools = Join-Path $Root 'tools'
        roms = Join-Path $Root 'roms'
        firmware = Join-Path $Root 'firmware'
        saves = Join-Path $Root 'saves'
        cache = Join-Path $Root 'cache'
        mods = Join-Path $Root 'mods'
        systems = [ordered]@{
            ps2 = [ordered]@{
                emulatorKey = 'pcsx2'
                executable = Join-Path $Root 'emulators\pcsx2\pcsx2-qt.exe'
                roms = Join-Path $Root 'roms\ps2'
                firmware = [ordered]@{ path = Join-Path $Root 'firmware\ps2\bios'; policy = 'user-provided-only'; shareWithLaunchers = $true }
                saves = [ordered]@{ path = Join-Path $Root 'saves\ps2\memcards'; policy = 'canonical-pcsx2-memory-cards'; shareWithLaunchers = $true }
                cache = [ordered]@{ path = Join-Path $Root 'cache\pcsx2'; policy = 'per-emulator-version-and-gpu'; shareAcrossVersions = $false }
                mods = [ordered]@{ path = Join-Path $Root 'mods\ps2'; policy = 'game-specific-user-managed'; shareWithLaunchers = $true }
            }
            ps3 = [ordered]@{
                emulatorKey = 'rpcs3'
                executable = Join-Path $Root 'emulators\rpcs3\rpcs3.exe'
                roms = Join-Path $Root 'roms\ps3'
                firmware = [ordered]@{ path = Join-Path $Root 'firmware\ps3\PS3UPDAT.PUP'; policy = 'official-or-user-provided'; shareWithLaunchers = $true }
                saves = [ordered]@{ path = Join-Path $Root 'emulators\rpcs3\dev_hdd0\home\00000001\savedata'; policy = 'single-rpcs3-dev_hdd0-root'; shareWithLaunchers = $true }
                storage = [ordered]@{ path = Join-Path $Root 'emulators\rpcs3\dev_hdd0'; policy = 'single-rpcs3-dev_hdd0-root'; destructiveWrites = $false }
                cache = [ordered]@{ path = Join-Path $Root 'cache\rpcs3'; policy = 'per-rpcs3-version-and-gpu'; shareAcrossVersions = $false }
                mods = [ordered]@{ path = Join-Path $Root 'mods\ps3'; policy = 'game-specific-user-managed'; shareWithLaunchers = $true }
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify pass**

Expected: pass.

- [ ] **Step 5: Commit**

```powershell
rtk git add -- bootstrap-tools.ps1 tests/bootstrap-emulation-shared-runtime.tests.ps1
rtk git commit -m "Define shared emulation runtime layout"
```

---

### Task 3: Add Host Capability Recommendations

**Files:**
- Create: `F:\Projects\PhaseZero\tests\bootstrap-emulation-host-profile.tests.ps1`
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`

- [ ] **Step 1: Write failing recommendation tests**

Create:

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Emulation host capability recommendations' {
    It 'recommends conservative Steam Deck tuning without hardcoded RPCS3 SPU threads' {
        $hostProfile = [pscustomobject]@{
            IsSteamDeck = $true
            LogicalProcessors = 8
            MemoryGB = 16
            GpuVendor = 'AMD'
            SupportsVulkan = $true
            PowerMode = 'battery'
            StorageClass = 'sd-or-usb'
        }

        $plan = Get-BootstrapEmulationTuningRecommendation -HostProfile $hostProfile

        [string]$plan.profile | Should Be 'handheld-balanced'
        [string]$plan.ps2.renderer | Should Be 'Vulkan'
        [string]$plan.ps2.mediaFormatRecommendation | Should Be 'prefer-chd-after-verification'
        [string]$plan.ps3.renderer | Should Be 'Vulkan'
        [string]$plan.ps3.spuThreads | Should Be 'auto'
        [bool]$plan.watchdog.forceKillDefault | Should Be $false
    }

    It 'uses compatibility profile when Vulkan is unavailable' {
        $hostProfile = [pscustomobject]@{
            IsSteamDeck = $false
            LogicalProcessors = 4
            MemoryGB = 8
            GpuVendor = 'Intel'
            SupportsVulkan = $false
            PowerMode = 'ac'
            StorageClass = 'ssd'
        }

        $plan = Get-BootstrapEmulationTuningRecommendation -HostProfile $hostProfile

        [string]$plan.profile | Should Be 'compatibility'
        [string]$plan.ps2.renderer | Should Be 'Direct3D12'
        [string]$plan.ps3.mode | Should Be 'manual-compatibility-review'
    }
}
```

- [ ] **Step 2: Run test to verify failure**

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-emulation-host-profile.tests.ps1
```

Expected: helper missing.

- [ ] **Step 3: Implement recommendation helper**

Add:

```powershell
function Get-BootstrapEmulationTuningRecommendation {
    param([Parameter(Mandatory = $true)]$HostProfile)

    $supportsVulkan = [bool]$HostProfile.SupportsVulkan
    $isDeck = [bool]$HostProfile.IsSteamDeck
    $logicalProcessors = [int]$HostProfile.LogicalProcessors
    $memoryGb = [int]$HostProfile.MemoryGB
    $storageClass = [string]$HostProfile.StorageClass

    $profile = 'desktop-balanced'
    if (-not $supportsVulkan) {
        $profile = 'compatibility'
    } elseif ($isDeck) {
        $profile = 'handheld-balanced'
    } elseif ($logicalProcessors -ge 12 -and $memoryGb -ge 32) {
        $profile = 'desktop-performance'
    }

    $ps2Renderer = if ($supportsVulkan) { 'Vulkan' } else { 'Direct3D12' }
    $media = if ($storageClass -match 'sd|usb|hdd') { 'prefer-chd-after-verification' } else { 'iso-or-chd-user-choice' }
    $ps3Mode = if ($supportsVulkan -and $memoryGb -ge 16) { 'standard' } else { 'manual-compatibility-review' }

    return [ordered]@{
        profile = $profile
        ps2 = [ordered]@{
            frontend = 'PCSX2-Qt'
            renderer = $ps2Renderer
            fastBoot = $true
            mediaFormatRecommendation = $media
            libretroRecommended = $false
        }
        ps3 = [ordered]@{
            frontend = 'RPCS3'
            renderer = $(if ($supportsVulkan) { 'Vulkan' } else { 'manual' })
            ppuDecoder = 'LLVM'
            spuDecoder = 'LLVM'
            spuThreads = 'auto'
            mode = $ps3Mode
        }
        watchdog = [ordered]@{
            reportFirst = $true
            forceKillDefault = $false
            resetHydraStateOnlyWhenApiProbePasses = $true
        }
    }
}
```

- [ ] **Step 4: Run tests**

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-emulation-host-profile.tests.ps1
```

Expected: pass.

- [ ] **Step 5: Commit**

```powershell
rtk git add -- bootstrap-tools.ps1 tests/bootstrap-emulation-host-profile.tests.ps1
rtk git commit -m "Recommend emulation tuning from host capacity"
```

---

### Task 4: Add Hydra Config Merge Contract

**Files:**
- Create: `F:\Projects\PhaseZero\tests\bootstrap-hydra-emulation-config.tests.ps1`
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`

- [ ] **Step 1: Write failing merge tests**

Create:

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Hydra shared emulator config merge' {
    It 'merges PS2 and PS3 pointers while preserving unknown keys' {
        $root = Join-Path $env:TEMP ('pz-hydra-config-' + [Guid]::NewGuid().ToString('N'))
        $cfg = Join-Path $root 'emulators_config.json'
        New-Item -Path $root -ItemType Directory -Force | Out-Null
        try {
            '{"custom":{"enabled":true,"note":"keep"}}' | Set-Content -LiteralPath $cfg -Encoding UTF8

            $result = Merge-BootstrapHydraEmulatorConfig -ConfigPath $cfg -Entries @(
                @{ systemKey = 'playstation2'; emulatorName = 'PCSX2-Qt'; executablePath = 'X:\Emulation\emulators\pcsx2\pcsx2-qt.exe'; romsDirectory = 'X:\Emulation\roms\ps2'; defaultFlags = '--fullscreen --nogui' },
                @{ systemKey = 'playstation3'; emulatorName = 'RPCS3'; executablePath = 'X:\Emulation\emulators\rpcs3\rpcs3.exe'; romsDirectory = 'X:\Emulation\roms\ps3'; defaultFlags = '--no-gui --fullscreen' }
            )

            [bool]$result.changed | Should Be $true
            $json = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
            [string]$json.custom.note | Should Be 'keep'
            [string]$json.playstation2.emulator_name | Should Be 'PCSX2-Qt'
            [string]$json.playstation3.emulator_name | Should Be 'RPCS3'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not write when Hydra is running unless force is explicit' {
        $root = Join-Path $env:TEMP ('pz-hydra-lock-' + [Guid]::NewGuid().ToString('N'))
        $cfg = Join-Path $root 'emulators_config.json'
        New-Item -Path $root -ItemType Directory -Force | Out-Null
        try {
            '{}' | Set-Content -LiteralPath $cfg -Encoding UTF8
            $result = Merge-BootstrapHydraEmulatorConfig -ConfigPath $cfg -Entries @() -HydraProcessRunning:$true

            [bool]$result.changed | Should Be $false
            [string]$result.status | Should Be 'blocked-process-running'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Expected: function missing.

- [ ] **Step 3: Implement merge helper**

Add:

```powershell
function Merge-BootstrapHydraEmulatorConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [switch]$HydraProcessRunning,
        [switch]$Force
    )

    if ($HydraProcessRunning -and -not $Force) {
        return [pscustomobject]@{ status = 'blocked-process-running'; changed = $false; path = $ConfigPath }
    }

    $parent = Split-Path -Path $ConfigPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $data = [ordered]@{}
    if (Test-Path -LiteralPath $ConfigPath) {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            foreach ($prop in $parsed.PSObject.Properties) {
                $data[$prop.Name] = $prop.Value
            }
        }
    }

    foreach ($entry in @($Entries)) {
        $systemKey = [string]$entry.systemKey
        if ([string]::IsNullOrWhiteSpace($systemKey)) { continue }
        $data[$systemKey] = [ordered]@{
            enabled = $true
            emulator_name = [string]$entry.emulatorName
            executable_path = [string]$entry.executablePath
            roms_directory = [string]$entry.romsDirectory
            default_flags = [string]$entry.defaultFlags
        }
    }

    $json = $data | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($ConfigPath, $json, [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ status = 'updated'; changed = $true; path = $ConfigPath }
}
```

- [ ] **Step 4: Run test**

Expected: pass.

- [ ] **Step 5: Commit**

```powershell
rtk git add -- bootstrap-tools.ps1 tests/bootstrap-hydra-emulation-config.tests.ps1
rtk git commit -m "Merge Hydra emulator pointers safely"
```

---

### Task 5: Add RPCS3/PCSX2 Config Planning Without Destructive Writes

**Files:**
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`
- Test: `F:\Projects\PhaseZero\tests\bootstrap-emulation-shared-runtime.tests.ps1`

- [ ] **Step 1: Add failing config plan test**

Append:

```powershell
Describe 'Emulator config plan safety' {
    It 'plans PS2 and PS3 config writes without sharing unsafe caches' {
        $layout = Get-BootstrapEmulationSharedLayout -Root 'X:\Emulation'
        $tuning = Get-BootstrapEmulationTuningRecommendation -HostProfile ([pscustomobject]@{
            IsSteamDeck = $true
            LogicalProcessors = 8
            MemoryGB = 16
            GpuVendor = 'AMD'
            SupportsVulkan = $true
            PowerMode = 'battery'
            StorageClass = 'sd-or-usb'
        })

        $plan = New-BootstrapEmulationConfigPlan -Layout $layout -Tuning $tuning

        [string]$plan.pcsx2.iniPath | Should Match 'PCSX2\.ini$'
        [string]$plan.pcsx2.values.Graphics.Renderer | Should Be 'Vulkan'
        [string]$plan.rpcs3.yamlPath | Should Match 'global_config\.yml$'
        [string]$plan.rpcs3.values.Core.PPU_Decoder | Should Be 'LLVM'
        [string]$plan.rpcs3.values.Core.SPU_Threads | Should Be 'auto'
        [bool]$plan.pcsx2.cacheSharedAcrossVersions | Should Be $false
        [bool]$plan.rpcs3.cacheSharedAcrossVersions | Should Be $false
        [bool]$plan.destructiveStorageWrites | Should Be $false
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Expected: helper missing.

- [ ] **Step 3: Implement config plan helper**

Add:

```powershell
function New-BootstrapEmulationConfigPlan {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$Tuning
    )

    return [ordered]@{
        destructiveStorageWrites = $false
        pcsx2 = [ordered]@{
            iniPath = Join-Path ([string]$Layout.systems.ps2.emulatorKey) 'inis\PCSX2.ini'
            values = [ordered]@{
                EmuCore = [ordered]@{ CdvdFastBoot = [bool]$Tuning.ps2.fastBoot }
                Graphics = [ordered]@{
                    Renderer = [string]$Tuning.ps2.renderer
                    AspectRatio = '16:9'
                    AnisotropicFiltering = '4x'
                }
            }
            cacheSharedAcrossVersions = [bool]$Layout.systems.ps2.cache.shareAcrossVersions
        }
        rpcs3 = [ordered]@{
            yamlPath = Join-Path ([string]$Layout.systems.ps3.emulatorKey) 'config\global_config.yml'
            values = [ordered]@{
                Core = [ordered]@{
                    PPU_Decoder = [string]$Tuning.ps3.ppuDecoder
                    SPU_Decoder = [string]$Tuning.ps3.spuDecoder
                    SPU_Threads = [string]$Tuning.ps3.spuThreads
                }
                Video = [ordered]@{
                    Renderer = [string]$Tuning.ps3.renderer
                    Shader_Compilation_Mode = 'AsyncWithPrecompiler'
                }
            }
            cacheSharedAcrossVersions = [bool]$Layout.systems.ps3.cache.shareAcrossVersions
        }
    }
}
```

- [ ] **Step 4: Run tests**

Expected: pass.

- [ ] **Step 5: Commit**

```powershell
rtk git add -- bootstrap-tools.ps1 tests/bootstrap-emulation-shared-runtime.tests.ps1
rtk git commit -m "Plan emulator configs safely"
```

---

### Task 6: Add Nintendo Switch Runtime Candidate Registry

**Files:**
- Create: `F:\Projects\PhaseZero\tests\bootstrap-switch-emulation-runtime.tests.ps1`
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`

- [ ] **Step 1: Write failing Switch catalog and safety tests**

Create `tests\bootstrap-switch-emulation-runtime.tests.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Nintendo Switch emulation runtime registry' {
    It 'declares Switch runtime as manual source-gated and content-safe' {
        $catalog = Get-BootstrapComponentCatalog

        foreach ($id in @(
            'switch-emulation-runtime',
            'switch-emulator-ryujinx-family',
            'switch-emulator-yuzu-family',
            'switch-emulator-suyu-family',
            'switch-emulator-sudachi-family',
            'switch-emulator-torzu-family',
            'switch-emulator-citron-family',
            'switch-emulator-eden-family',
            'hydra-switch-integration'
        )) {
            $catalog.Contains($id) | Should Be $true
        }

        [string]$catalog['switch-emulation-runtime'].Kind | Should Be 'manual-required'
        [string]$catalog['switch-emulation-runtime'].keysPolicy | Should Be 'user-provided-own-console-only'
        [string]$catalog['switch-emulation-runtime'].firmwarePolicy | Should Be 'user-provided-own-console-only'
        [string]$catalog['switch-emulation-runtime'].romPolicy | Should Be 'user-owned-paths-only'
        [bool]$catalog['switch-emulation-runtime'].autoInstallAllowed | Should Be $false
        [string]$catalog['hydra-switch-integration'].launcherMode | Should Be 'pointer-only'
    }

    It 'keeps risky Switch emulator families blocked until source trust is selected' {
        $candidates = Get-BootstrapSwitchEmulatorCandidateCatalog
        @($candidates).Count | Should BeGreaterThan 4

        foreach ($candidate in @($candidates)) {
            [string]$candidate.systemKey | Should Be 'nintendo-switch'
            [bool]$candidate.autoInstallAllowed | Should Be $false
            [string]$candidate.keysPolicy | Should Be 'user-provided-own-console-only'
            [string]$candidate.contentPolicy | Should Be 'user-owned-paths-only'
            [string]$candidate.defaultStatus | Should Match 'manual-review|reference-only|blocked'
        }

        $yuzu = $candidates | Where-Object { $_.id -eq 'yuzu-family' } | Select-Object -First 1
        [string]$yuzu.defaultStatus | Should Be 'reference-only'
    }

    It 'extends shared layout with Switch paths and avoids unsafe cache/save sharing' {
        $layout = Get-BootstrapEmulationSharedLayout -Root 'X:\Emulation'

        [string]$layout.systems.switch.emulatorKey | Should Be 'switch'
        [string]$layout.systems.switch.keys.policy | Should Be 'user-provided-own-console-only'
        [string]$layout.systems.switch.firmware.policy | Should Be 'user-provided-own-console-only'
        [bool]$layout.systems.switch.cache.shareAcrossEmulatorFamilies | Should Be $false
        [bool]$layout.systems.switch.saves.shareAcrossEmulatorFamilies | Should Be $false
        [bool]$layout.systems.switch.mods.shareAcrossEmulatorFamilies | Should Be $false
        [bool]$layout.systems.switch.metadata.shareWithLaunchers | Should Be $true
    }

    It 'adds opt-in Switch profile without entering Steam Deck recommended defaults' {
        $profiles = Get-BootstrapProfileCatalog

        $profiles.Contains('emulation-switch-safe-intake') | Should Be $true
        $profiles.Contains('emulation-hydra-switch') | Should Be $true
        @($profiles['emulation-switch-safe-intake'].Items) -contains 'switch-emulation-runtime' | Should Be $true
        @($profiles['emulation-hydra-switch'].Items) -contains 'hydra-switch-integration' | Should Be $true
        @($profiles['steamdeck-recommended'].Items) -contains 'emulation-hydra-switch' | Should Be $false
    }
}
```

- [ ] **Step 2: Run test to verify failure**

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-switch-emulation-runtime.tests.ps1
```

Expected: fails because Switch registry is missing.

- [ ] **Step 3: Add Switch candidate helper**

Add to `bootstrap-tools.ps1` near emulation helpers:

```powershell
function Get-BootstrapSwitchEmulatorCandidateCatalog {
    function New-BootstrapSwitchEmulatorCandidate {
        param(
            [Parameter(Mandatory = $true)][string]$Id,
            [Parameter(Mandatory = $true)][string]$DisplayName,
            [Parameter(Mandatory = $true)][string]$Language,
            [Parameter(Mandatory = $true)][string]$DefaultStatus,
            [Parameter(Mandatory = $true)][string]$SourceTrust,
            [Parameter(Mandatory = $true)][string]$SharedRuntimeKey
        )

        return [pscustomobject][ordered]@{
            id = $Id
            displayName = $DisplayName
            language = $Language
            defaultStatus = $DefaultStatus
            sourceTrust = $SourceTrust
            sharedRuntimeKey = $SharedRuntimeKey
            systemKey = 'nintendo-switch'
            keysPolicy = 'user-provided-own-console-only'
            firmwarePolicy = 'user-provided-own-console-only'
            contentPolicy = 'user-owned-paths-only'
            autoInstallAllowed = $false
        }
    }

    return @(
        New-BootstrapSwitchEmulatorCandidate -Id 'ryujinx-family' -DisplayName 'Ryujinx family' -Language 'C#' -DefaultStatus 'manual-review' -SourceTrust 'verify-current-source-before-use' -SharedRuntimeKey 'switch-ryujinx-family'
        New-BootstrapSwitchEmulatorCandidate -Id 'yuzu-family' -DisplayName 'Yuzu family' -Language 'C++' -DefaultStatus 'reference-only' -SourceTrust 'discontinued-or-legacy-reference' -SharedRuntimeKey 'switch-yuzu-family'
        New-BootstrapSwitchEmulatorCandidate -Id 'suyu-family' -DisplayName 'Suyu family' -Language 'C++' -DefaultStatus 'manual-review' -SourceTrust 'verify-current-source-before-use' -SharedRuntimeKey 'switch-suyu-family'
        New-BootstrapSwitchEmulatorCandidate -Id 'sudachi-family' -DisplayName 'Sudachi family' -Language 'C++' -DefaultStatus 'manual-review' -SourceTrust 'verify-current-source-before-use' -SharedRuntimeKey 'switch-sudachi-family'
        New-BootstrapSwitchEmulatorCandidate -Id 'torzu-family' -DisplayName 'Torzu family' -Language 'C++' -DefaultStatus 'manual-review' -SourceTrust 'verify-current-source-before-use' -SharedRuntimeKey 'switch-torzu-family'
        New-BootstrapSwitchEmulatorCandidate -Id 'citron-family' -DisplayName 'Citron family' -Language 'C++' -DefaultStatus 'manual-review' -SourceTrust 'verify-current-source-before-use' -SharedRuntimeKey 'switch-citron-family'
        New-BootstrapSwitchEmulatorCandidate -Id 'eden-family' -DisplayName 'Eden family' -Language 'C++' -DefaultStatus 'manual-review' -SourceTrust 'verify-current-source-before-use' -SharedRuntimeKey 'switch-eden-family'
    )
}
```

- [ ] **Step 4: Add Switch components**

In `Get-BootstrapComponentCatalog`, add after `chdman-tools`:

```powershell
    $catalog['switch-emulation-runtime'] = New-BootstrapComponentDefinition -Name 'switch-emulation-runtime' -Description 'Nintendo Switch emulator runtime intake with source trust and user-owned content gates.' -Optional $true -DependsOn @('emulation-shared-runtime', 'vcpp-redist', 'directx-runtime') -Kind 'manual-required' -Data @{ DisplayName = 'Nintendo Switch emulation runtime'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Centralizes Switch emulator selection without duplicating binaries across Hydra, Steam ROM Manager, EmuDeck or Playnite.'; Instructions = 'Select one source-verified emulator family. Provide only your own console-derived keys, firmware and game dumps. PhaseZero never downloads keys, firmware, updates, DLC or games.'; sharedRuntimeKey = 'switch'; keysPolicy = 'user-provided-own-console-only'; firmwarePolicy = 'user-provided-own-console-only'; romPolicy = 'user-owned-paths-only'; autoInstallAllowed = $false; riskLevel = 'manual' }
    foreach ($candidate in Get-BootstrapSwitchEmulatorCandidateCatalog) {
        $componentId = 'switch-emulator-{0}' -f [string]$candidate.id
        $catalog[$componentId] = New-BootstrapComponentDefinition -Name $componentId -Description ("Nintendo Switch emulator candidate: {0}." -f [string]$candidate.displayName) -Optional $true -DependsOn @('switch-emulation-runtime') -Kind 'manual-required' -Data @{ DisplayName = [string]$candidate.displayName; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Candidate is tracked for user choice and diagnostics only; no automatic install.'; Instructions = 'Verify current source, license, release integrity and project status before use. Provide only user-owned keys, firmware and game dumps.'; systemKey = [string]$candidate.systemKey; sharedRuntimeKey = [string]$candidate.sharedRuntimeKey; keysPolicy = [string]$candidate.keysPolicy; firmwarePolicy = [string]$candidate.firmwarePolicy; contentPolicy = [string]$candidate.contentPolicy; autoInstallAllowed = $false; defaultStatus = [string]$candidate.defaultStatus; sourceTrust = [string]$candidate.sourceTrust; riskLevel = 'manual' }
    }
    $catalog['hydra-switch-integration'] = New-BootstrapComponentDefinition -Name 'hydra-switch-integration' -Description 'Hydra Classic pointer to the selected canonical Nintendo Switch emulator runtime.' -Optional $true -DependsOn @('hydra-launcher', 'switch-emulation-runtime') -Kind 'alias' -Data @{ Stage = 'config'; Provisioning = 'builtin'; ValueReason = 'Writes only launcher pointers after one Switch emulator family is selected and source-verified.'; configTarget = '$env:APPDATA\hydra\emulators_config.json'; systemKey = 'nintendoswitch'; launcherMode = 'pointer-only'; requiresSelectedRuntime = $true }
```

In `Get-BootstrapProfileCatalog`, add near emulation profiles:

```powershell
    $catalog['emulation-switch-safe-intake'] = New-BootstrapProfileDefinition -Name 'emulation-switch-safe-intake' -Description 'Opt-in Nintendo Switch emulator intake with legal/content gates and no auto-install.' -Items @('emulation-shared-runtime', 'switch-emulation-runtime', 'switch-emulator-ryujinx-family', 'switch-emulator-yuzu-family', 'switch-emulator-suyu-family', 'switch-emulator-sudachi-family', 'switch-emulator-torzu-family', 'switch-emulator-citron-family', 'switch-emulator-eden-family')
    $catalog['emulation-hydra-switch'] = New-BootstrapProfileDefinition -Name 'emulation-hydra-switch' -Description 'Hydra pointer integration for one selected canonical Nintendo Switch emulator.' -Items @('emulation-switch-safe-intake', 'hydra-launcher', 'hydra-switch-integration')
```

- [ ] **Step 5: Extend shared layout**

Inside `Get-BootstrapEmulationSharedLayout`, add `switch` under `systems`:

```powershell
            switch = [ordered]@{
                emulatorKey = 'switch'
                selectedRuntimePolicy = 'user-selects-one-source-verified-family'
                roms = Join-Path $Root 'roms\switch'
                keys = [ordered]@{ path = Join-Path $Root 'firmware\switch\keys'; policy = 'user-provided-own-console-only'; maskInLogs = $true; shareWithLaunchers = $false }
                firmware = [ordered]@{ path = Join-Path $Root 'firmware\switch\firmware'; policy = 'user-provided-own-console-only'; shareWithLaunchers = $false }
                nand = [ordered]@{ path = Join-Path $Root 'state\switch\nand'; policy = 'per-emulator-family'; shareAcrossEmulatorFamilies = $false }
                saves = [ordered]@{ path = Join-Path $Root 'saves\switch'; policy = 'backup-export-import-only'; shareAcrossEmulatorFamilies = $false; shareWithLaunchers = $true }
                cache = [ordered]@{ path = Join-Path $Root 'cache\switch'; policy = 'per-emulator-version-and-gpu'; shareAcrossEmulatorFamilies = $false }
                mods = [ordered]@{ path = Join-Path $Root 'mods\switch'; policy = 'per-title-and-engine-family'; shareAcrossEmulatorFamilies = $false }
                metadata = [ordered]@{ path = Join-Path $Root 'metadata\switch'; policy = 'frontend-safe-artwork-and-library-data'; shareWithLaunchers = $true }
            }
```

- [ ] **Step 6: Run tests**

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-switch-emulation-runtime.tests.ps1
```

Expected: pass.

- [ ] **Step 7: Commit**

```powershell
rtk git add -- bootstrap-tools.ps1 tests/bootstrap-switch-emulation-runtime.tests.ps1
rtk git commit -m "Add Switch emulation runtime intake"
```

---

### Task 7: Add Friendly Common-Fix Catalog For Emulation

**Files:**
- Create: `F:\Projects\PhaseZero\tests\bootstrap-emulation-friendly-fixes.tests.ps1`
- Modify: `F:\Projects\PhaseZero\bootstrap-tools.ps1`

- [ ] **Step 1: Write failing fix catalog tests**

Create `tests\bootstrap-emulation-friendly-fixes.tests.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Friendly emulation fix catalog' {
    It 'exposes user-friendly Switch diagnostics without unsafe downloads' {
        $fixes = Get-BootstrapEmulationFriendlyFixCatalog
        $ids = @($fixes | ForEach-Object { [string]$_.id })

        foreach ($id in @(
            'switch-missing-keys',
            'switch-firmware-mismatch',
            'switch-black-screen',
            'switch-controller-not-working',
            'switch-stutter-shader-cache',
            'switch-low-fps-host-capacity',
            'switch-mod-conflict',
            'switch-duplicate-runtime',
            'switch-save-backup',
            'switch-vulkan-driver'
        )) {
            ($ids -contains $id) | Should Be $true
        }

        foreach ($fix in @($fixes | Where-Object { [string]$_.system -eq 'switch' })) {
            [bool]$fix.destructiveDefault | Should Be $false
            [string]$fix.safeAction | Should Not Match 'download-keys|download-firmware|download-rom|bypass'
            [string]$fix.userMessage | Should Match 'usuario|console|propr'
        }
    }

    It 'marks destructive or data-changing fixes as opt-in backup-first' {
        $fixes = Get-BootstrapEmulationFriendlyFixCatalog
        $cache = $fixes | Where-Object { $_.id -eq 'switch-stutter-shader-cache' } | Select-Object -First 1
        $save = $fixes | Where-Object { $_.id -eq 'switch-save-backup' } | Select-Object -First 1
        $duplicate = $fixes | Where-Object { $_.id -eq 'switch-duplicate-runtime' } | Select-Object -First 1

        [string]$cache.mode | Should Be 'guided-cleanup'
        [bool]$cache.requiresBackup | Should Be $true
        [string]$save.mode | Should Be 'backup-only'
        [bool]$save.requiresBackup | Should Be $true
        [string]$duplicate.mode | Should Be 'audit-only'
    }
}
```

- [ ] **Step 2: Run test to verify failure**

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-emulation-friendly-fixes.tests.ps1
```

Expected: helper missing.

- [ ] **Step 3: Implement fix catalog helper**

Add to `bootstrap-tools.ps1`:

```powershell
function Get-BootstrapEmulationFriendlyFixCatalog {
    $switchMessage = 'Use apenas arquivos do usuario, extraidos do proprio console e jogos proprios. PhaseZero nao baixa keys, firmware, jogos, updates, DLC ou mods.'

    return @(
        [pscustomobject][ordered]@{ id = 'switch-missing-keys'; system = 'switch'; title = 'Switch: keys ausentes'; mode = 'guided-user-content'; safeAction = 'open-shared-switch-keys-folder'; destructiveDefault = $false; requiresBackup = $false; userMessage = $switchMessage; blockedActions = @('download-keys','bypass-decryption') }
        [pscustomobject][ordered]@{ id = 'switch-firmware-mismatch'; system = 'switch'; title = 'Switch: firmware incompativel'; mode = 'guided-user-content'; safeAction = 'open-shared-switch-firmware-folder'; destructiveDefault = $false; requiresBackup = $false; userMessage = $switchMessage; blockedActions = @('download-firmware') }
        [pscustomobject][ordered]@{ id = 'switch-black-screen'; system = 'switch'; title = 'Switch: tela preta'; mode = 'diagnose-renderer'; safeAction = 'recommend-renderer-and-driver-check'; destructiveDefault = $false; requiresBackup = $false; userMessage = 'Verifica Vulkan/GPU/driver, perfil handheld/docked e mods do usuario antes de alterar configs.'; blockedActions = @('delete-user-data') }
        [pscustomobject][ordered]@{ id = 'switch-controller-not-working'; system = 'switch'; title = 'Switch: controle nao detectado'; mode = 'guided-input-profile'; safeAction = 'show-input-stack-conflicts'; destructiveDefault = $false; requiresBackup = $false; userMessage = 'Audita Steam Input, ViGEm, Handheld Companion, GlosSI e mapeamento por emulador antes de gravar perfil.'; blockedActions = @('disable-input-drivers') }
        [pscustomobject][ordered]@{ id = 'switch-stutter-shader-cache'; system = 'switch'; title = 'Switch: stutter/cache shader'; mode = 'guided-cleanup'; safeAction = 'backup-then-clear-selected-cache'; destructiveDefault = $false; requiresBackup = $true; userMessage = 'Cache shader fica por emulador, versao e GPU. Limpeza exige backup e selecao do usuario.'; blockedActions = @('clear-all-caches') }
        [pscustomobject][ordered]@{ id = 'switch-low-fps-host-capacity'; system = 'switch'; title = 'Switch: FPS baixo'; mode = 'host-capacity-profile'; safeAction = 'recommend-resolution-mode-and-power-profile'; destructiveDefault = $false; requiresBackup = $false; userMessage = 'Escolhe perfil por CPU, RAM, GPU, Vulkan, bateria e storage do usuario.'; blockedActions = @('force-overclock') }
        [pscustomobject][ordered]@{ id = 'switch-mod-conflict'; system = 'switch'; title = 'Switch: conflito de mods'; mode = 'audit-only'; safeAction = 'list-mods-per-title-and-engine'; destructiveDefault = $false; requiresBackup = $false; userMessage = 'Mods do usuario ficam por titulo e familia de emulador; PhaseZero so audita e permite desativacao guiada.'; blockedActions = @('delete-mods') }
        [pscustomobject][ordered]@{ id = 'switch-duplicate-runtime'; system = 'switch'; title = 'Switch: runtimes duplicados'; mode = 'audit-only'; safeAction = 'report-duplicate-emulator-roots'; destructiveDefault = $false; requiresBackup = $false; userMessage = 'Detecta duplicacao entre Hydra, EmuDeck, Playnite e Steam ROM Manager; nao remove nada automaticamente.'; blockedActions = @('uninstall-runtime') }
        [pscustomobject][ordered]@{ id = 'switch-save-backup'; system = 'switch'; title = 'Switch: backup de saves'; mode = 'backup-only'; safeAction = 'snapshot-selected-save-roots'; destructiveDefault = $false; requiresBackup = $true; userMessage = 'Saves do usuario nao sao compartilhados entre familias por escrita direta; use backup, exportacao e importacao guiada.'; blockedActions = @('overwrite-saves') }
        [pscustomobject][ordered]@{ id = 'switch-vulkan-driver'; system = 'switch'; title = 'Switch: Vulkan/driver'; mode = 'readiness-check'; safeAction = 'run-gpu-vulkan-readiness'; destructiveDefault = $false; requiresBackup = $false; userMessage = 'Verifica driver e suporte Vulkan antes de recomendar renderer. Usuario escolhe aplicar.'; blockedActions = @('install-unverified-driver') }
    )
}
```

- [ ] **Step 4: Add Switch tuning recommendation tests**

Append to `tests\bootstrap-switch-emulation-runtime.tests.ps1`:

```powershell
Describe 'Nintendo Switch host tuning recommendations' {
    It 'recommends handheld-balanced tuning for Steam Deck class hosts' {
        $plan = Get-BootstrapSwitchEmulationTuningRecommendation -HostProfile ([pscustomobject]@{
            IsSteamDeck = $true
            LogicalProcessors = 8
            MemoryGB = 16
            GpuVendor = 'AMD'
            SupportsVulkan = $true
            PowerMode = 'battery'
            StorageClass = 'sd-or-usb'
        })

        [string]$plan.profile | Should Be 'handheld-balanced'
        [string]$plan.renderer | Should Be 'Vulkan'
        [string]$plan.consoleMode | Should Be 'handheld'
        [double]$plan.resolutionScale | Should Be 1.0
        [bool]$plan.asyncShadersWhenSupported | Should Be $true
        [bool]$plan.autoApply | Should Be $false
    }

    It 'falls back to compatibility review when Vulkan is unavailable' {
        $plan = Get-BootstrapSwitchEmulationTuningRecommendation -HostProfile ([pscustomobject]@{
            IsSteamDeck = $false
            LogicalProcessors = 4
            MemoryGB = 8
            GpuVendor = 'Intel'
            SupportsVulkan = $false
            PowerMode = 'ac'
            StorageClass = 'ssd'
        })

        [string]$plan.profile | Should Be 'compatibility-review'
        [string]$plan.renderer | Should Be 'manual'
        [bool]$plan.autoApply | Should Be $false
    }
}
```

- [ ] **Step 5: Implement Switch tuning helper**

Add:

```powershell
function Get-BootstrapSwitchEmulationTuningRecommendation {
    param([Parameter(Mandatory = $true)]$HostProfile)

    $supportsVulkan = [bool]$HostProfile.SupportsVulkan
    $isDeck = [bool]$HostProfile.IsSteamDeck
    $memoryGb = [int]$HostProfile.MemoryGB
    $logicalProcessors = [int]$HostProfile.LogicalProcessors

    if (-not $supportsVulkan) {
        return [ordered]@{
            profile = 'compatibility-review'
            renderer = 'manual'
            consoleMode = 'handheld'
            resolutionScale = 1.0
            asyncShadersWhenSupported = $false
            autoApply = $false
            reason = 'Vulkan unavailable; user should review GPU driver and emulator compatibility.'
        }
    }

    if ($isDeck -or $memoryGb -lt 16 -or $logicalProcessors -lt 8) {
        return [ordered]@{
            profile = 'handheld-balanced'
            renderer = 'Vulkan'
            consoleMode = 'handheld'
            resolutionScale = 1.0
            asyncShadersWhenSupported = $true
            autoApply = $false
            reason = 'Conservative handheld profile for battery, thermals and shader stutter control.'
        }
    }

    return [ordered]@{
        profile = 'docked-balanced'
        renderer = 'Vulkan'
        consoleMode = 'docked'
        resolutionScale = 2.0
        asyncShadersWhenSupported = $true
        autoApply = $false
        reason = 'Desktop-capable host; still requires user review before applying.'
    }
}
```

- [ ] **Step 6: Run tests**

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-emulation-friendly-fixes.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-switch-emulation-runtime.tests.ps1
```

Expected: pass.

- [ ] **Step 7: Commit**

```powershell
rtk git add -- bootstrap-tools.ps1 tests/bootstrap-emulation-friendly-fixes.tests.ps1 tests/bootstrap-switch-emulation-runtime.tests.ps1
rtk git commit -m "Add friendly Switch emulation fixes"
```

---

### Task 8: Final Verification

- [ ] Run targeted suites:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-emulation-shared-runtime.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-hydra-emulation-config.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-emulation-host-profile.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-switch-emulation-runtime.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-emulation-friendly-fixes.tests.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-pester.ps1 -Path .\tests\bootstrap-emudeck.tests.ps1
```

- [ ] Run parser check:

```powershell
rtk powershell -NoProfile -Command "$tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'bootstrap-tools.ps1'), [ref]$tokens, [ref]$errors) > $null; if($errors){ $errors | Format-List; exit 1 }"
```

- [ ] Run whitespace check:

```powershell
rtk git diff --check
```

- [ ] Run status:

```powershell
rtk git status --short
```

Expected: only intended emulation files before final commit.

## Self-Review

Spec coverage:

- PS2/PCSX2 included: catalog, shared layout, Hydra pointer, INI plan, CHD tool gate.
- PS3/RPCS3 included: catalog, shared layout, Hydra pointer, YAML plan, firmware policy.
- Nintendo Switch included: source-gated emulator candidate families, legal key/firmware/content gates, shared path matrix, host tuning and friendly fixes.
- No host duplication: canonical `sharedRuntimeKey` and pointer-only launcher integrations.
- Shared saves/cache/firmware/keys/mods: layout marks shareable vs isolated classes.
- Host-capacity tuning: helper maps Steam Deck/Vulkan/storage/memory into safe recommendations.
- Nuovo: tracked as blocked intake, not guessed.

Placeholder scan:

- No deferred placeholder markers.
- Blocked Nuovo is intentional because source is absent.

Type consistency:

- Component names, profile names, helper names, and test expectations match across tasks.
