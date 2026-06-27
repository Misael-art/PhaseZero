$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'emulation-steamdeck-shared profile wiring' {
    It 'chains detection -> media -> frontends -> shortcuts with winbtrfs prerequisite' {
        $profiles = Get-BootstrapProfileCatalog
        $profiles.Contains('emulation-steamdeck-shared') | Should Be $true
        $items = @($profiles['emulation-steamdeck-shared'].Items)
        foreach ($expected in @('winbtrfs', 'steamdeck-home-detect', 'emulation-deck-shared-media', 'emulation-frontend-pointing', 'emulation-desktop-shortcuts')) {
            $items -contains $expected | Should Be $true
        }
    }

    It 'does not leak into steamdeck-recommended or steamdeck-full' {
        $profiles = Get-BootstrapProfileCatalog
        @($profiles['steamdeck-recommended'].Items) -contains 'emulation-steamdeck-shared' | Should Be $false
        @($profiles['steamdeck-full'].Items) -contains 'emulation-steamdeck-shared' | Should Be $false
    }

    It 'maps the new builtin components to executors (no missing-executor)' {
        $catalog = Get-BootstrapComponentCatalog
        foreach ($id in @('steamdeck-home-detect', 'emulation-deck-shared-media', 'emulation-frontend-pointing', 'emulation-desktop-shortcuts')) {
            [string]$catalog[$id].Kind | Should Be 'builtin'
        }
    }
}
