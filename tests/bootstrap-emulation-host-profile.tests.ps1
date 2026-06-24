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
