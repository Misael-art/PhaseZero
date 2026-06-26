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

Describe 'Unified emulation host profile and launcher cohesion' {
    It 'marks Playnite (frontend) runtime source policy like other launchers' {
        $catalog = Get-BootstrapComponentCatalog
        [string]$catalog['playnite'].runtimeSourcePolicy | Should Be 'points-to-canonical-or-audited-duplicate'
    }

    It 'declares a single emulation-complete host profile that pulls every canonical item and dependency' {
        $profiles = Get-BootstrapProfileCatalog
        $profiles.Contains('emulation-complete') | Should Be $true

        $resolved = @((Resolve-BootstrapComponents -SelectedProfiles @('emulation-complete')).ResolvedComponents)
        foreach ($item in @(
            'emulation-shared-runtime', 'duckstation', 'pcsx2', 'rpcs3', 'chdman-tools',
            'hydra-launcher', 'hydra-duckstation-integration', 'hydra-pcsx2-integration',
            'hydra-rpcs3-integration', 'hydra-switch-integration', 'switch-emulation-runtime'
        )) {
            $resolved -contains $item | Should Be $true
        }
        foreach ($dep in @('system-core', 'vcpp-redist', 'directx-runtime')) {
            $resolved -contains $dep | Should Be $true
        }
    }

    It 'does not leak the emulation host profile into steamdeck recommended/full' {
        $profiles = Get-BootstrapProfileCatalog
        @($profiles['steamdeck-recommended'].Items) -contains 'emulation-complete' | Should Be $false
        @($profiles['steamdeck-full'].Items) -contains 'emulation-complete' | Should Be $false
    }

    It 'groups emulation profiles under a single UI family' {
        (Get-BootstrapProfileFamily -Name 'emulation-complete') | Should Be 'Emulacao'
        (Get-BootstrapProfileFamily -Name 'emulation-hydra-ps2-ps3') | Should Be 'Emulacao'

        $contract = Get-BootstrapUiContract
        $entry = @($contract.profiles | Where-Object { [string]$_.name -eq 'emulation-complete' })[0]
        $entry | Should Not BeNullOrEmpty
        [string]$entry.family | Should Be 'Emulacao'
    }
}

Describe 'Unified emulation metadata and save policy' {
    It 'exposes a single top-level metadata root' {
        $layout = Get-BootstrapEmulationSharedLayout -Root 'X:\Emulation'
        [string]$layout.metadata | Should Match 'metadata$'
    }
    It 'gives every Sony system a single metadata (artwork/images/videos) source shared with launchers' {
        $layout = Get-BootstrapEmulationSharedLayout -Root 'X:\Emulation'
        foreach ($sys in @('ps1', 'ps2', 'ps3')) {
            [string]$layout.systems.$sys.metadata.policy | Should Be 'frontend-safe-artwork-and-library-data'
            [bool]$layout.systems.$sys.metadata.shareWithLaunchers | Should Be $true
        }
    }
    It 'documents the PS3 save location as a conscious single-root exception' {
        $layout = Get-BootstrapEmulationSharedLayout -Root 'X:\Emulation'
        [string]$layout.systems.ps3.saves.policy | Should Be 'single-rpcs3-dev_hdd0-root'
        [bool]$layout.systems.ps3.saves.outsideSharedSavesRoot | Should Be $true
    }
}

Describe 'DuckStation PS1 shared runtime (Hydra Classic v4)' {
    It 'declares canonical DuckStation runtime and pointer-only Hydra integration' {
        $catalog = Get-BootstrapComponentCatalog

        $catalog.Contains('duckstation') | Should Be $true
        $catalog.Contains('hydra-duckstation-integration') | Should Be $true

        [string]$catalog['duckstation'].sharedRuntimeKey | Should Be 'duckstation'
        [string]$catalog['duckstation'].firmwarePolicy | Should Be 'user-provided-only'
        [string]$catalog['duckstation'].romPolicy | Should Be 'user-owned-paths-only'
        [string]$catalog['duckstation'].Instructions | Should Match 'BIOS'
        [string]$catalog['duckstation'].Instructions | Should Not Match 'Invoke-WebRequest.*scph'

        [string]$catalog['hydra-duckstation-integration'].Kind | Should Be 'alias'
        [string]$catalog['hydra-duckstation-integration'].systemKey | Should Be 'playstation1'
        [string]$catalog['hydra-duckstation-integration'].launcherMode | Should Be 'pointer-only'
    }

    It 'extends shared layout with PS1 paths and isolated cache' {
        $layout = Get-BootstrapEmulationSharedLayout -Root 'X:\Emulation'

        [string]$layout.systems.ps1.emulatorKey | Should Be 'duckstation'
        [string]$layout.systems.ps1.firmware.policy | Should Be 'user-provided-only'
        [bool]$layout.systems.ps1.cache.shareAcrossVersions | Should Be $false
        [bool]$layout.systems.ps1.saves.shareWithLaunchers | Should Be $true
    }

    It 'adds DuckStation to shared profile and Hydra pointer to the Hydra profile' {
        $profiles = Get-BootstrapProfileCatalog

        @($profiles['emulation-shared'].Items) -contains 'duckstation' | Should Be $true
        @($profiles['emulation-hydra-ps2-ps3'].Items) -contains 'hydra-duckstation-integration' | Should Be $true
        @($profiles['steamdeck-recommended'].Items) -contains 'duckstation' | Should Be $false
    }
}

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

    It 'executes emulation-shared-runtime builtin and creates canonical empty roots' {
        $root = Join-Path $env:TEMP ("pz-emulation-runtime-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $previousUserProfile = $env:USERPROFILE
        try {
            $env:USERPROFILE = $root
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot $root -ResolvedCloneBaseDir $root -IsDryRun:$false

            { Invoke-BootstrapComponent -Name 'emulation-shared-runtime' -State $state } | Should Not Throw

            $sharedRoot = Join-Path $root 'Games\Emulation'
            foreach ($relative in @(
                '',
                'emulators',
                'roms\ps1',
                'roms\ps2',
                'roms\ps3',
                'roms\switch',
                'firmware\ps2\bios',
                'firmware\switch\keys',
                'saves\ps1\memcards',
                'cache\rpcs3',
                'metadata\switch'
            )) {
                $path = if ([string]::IsNullOrWhiteSpace($relative)) { $sharedRoot } else { Join-Path $sharedRoot $relative }
                Test-Path -LiteralPath $path -PathType Container | Should Be $true
            }
            $state.Completed.ContainsKey('emulation-shared-runtime') | Should Be $true
        } finally {
            $env:USERPROFILE = $previousUserProfile
            if (Test-Path -LiteralPath $root) {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

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
