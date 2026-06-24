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
