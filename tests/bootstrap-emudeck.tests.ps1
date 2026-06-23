$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'EmuDeck for Windows incorporation' {
    It 'declares the emudeck component as guided (manual-required) with real prerequisites' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('emudeck') | Should Be $true
        $def = $catalog['emudeck']
        [string]$def.Kind | Should Be 'manual-required'
        foreach ($dep in @('steam','sevenzip','vcpp-redist')) {
            (@($def.DependsOn) -contains $dep) | Should Be $true
        }
        [bool]$def.Optional | Should Be $true
        [string]$def.officialSource | Should Match 'emudeck\.com'
        ([string]$def.Instructions) | Should Match 'emudeck\.com'
    }

    It 'exposes the EmuDeck Big Picture (Steam ROM Manager) AppTuning item under gaming-console' {
        $catalog = Get-BootstrapAppTuningCatalog
        $item = @($catalog.items | Where-Object { [string]$_.id -eq 'emudeck-bigpicture-srm' } | Select-Object -First 1)
        @($item).Count | Should Be 1
        [string]$item[0].category | Should Be 'gaming-console'
        (@($item[0].profiles) -contains 'game-docked') | Should Be $true
    }

    It 'keeps the existing Steam Big Picture session item for game modes' {
        $catalog = Get-BootstrapAppTuningCatalog
        @($catalog.items | Where-Object { [string]$_.id -eq 'steam-big-picture-session' }).Count | Should Be 1
    }
}
