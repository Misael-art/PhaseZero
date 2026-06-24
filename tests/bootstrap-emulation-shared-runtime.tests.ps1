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
