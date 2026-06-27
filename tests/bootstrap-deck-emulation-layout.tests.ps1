$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Deck emulation layout (EmuDeck/shortname)' {
    It 'models bios/tools/roms/saves/states/media under the given root' {
        $layout = Get-BootstrapDeckEmulationLayout -Root 'Z:\@\deck\Emulation'
        [string]$layout.bios.path | Should Be 'Z:\@\deck\Emulation\bios'
        [string]$layout.roms.path | Should Be 'Z:\@\deck\Emulation\roms'
        [string]$layout.media.path | Should Be 'Z:\@\deck\Emulation\storage\downloaded_media'
        [string]$layout.saves.path | Should Be 'Z:\@\deck\Emulation\saves'
        [string]$layout.states.path | Should Be 'Z:\@\deck\Emulation\states'
    }

    It 'classifies read-shared vs write-gated access' {
        $layout = Get-BootstrapDeckEmulationLayout -Root 'Z:\Emulation'
        [string]$layout.roms.access | Should Be 'read-shared'
        [string]$layout.bios.access | Should Be 'read-shared'
        [string]$layout.saves.access | Should Be 'write-gated'
        [string]$layout.cache.access | Should Be 'write-gated'
    }

    It 'exposes shortnames and media compat map' {
        $layout = Get-BootstrapDeckEmulationLayout -Root 'Z:\Emulation'
        @($layout.shortnames) -contains 'snes' | Should Be $true
        @($layout.shortnames) -contains 'ps2' | Should Be $true
        [string]$layout.mediaCompat.compat['cover'] | Should Be 'box2dfront'
        @($layout.mediaCompat.canonical) -contains 'box2dfront' | Should Be $true
    }
}

Describe 'Emulation roots resolver' {
    $windowsRoot = Join-Path $env:USERPROFILE 'Games\Emulation'

    It 'uses the Deck for read and write when write-opt-in' {
        $deck = [ordered]@{ found = $true; emulationRoot = 'Z:\@\deck\Emulation'; readable = $true; writable = $true; accessLevel = 'write-opt-in' }
        $roots = Resolve-BootstrapEmulationRoots -DeckInfo $deck
        $roots.roms | Should Be 'Z:\@\deck\Emulation\roms'
        $roots.saves | Should Be 'Z:\@\deck\Emulation\saves'
        $roots.deckWritable | Should Be $true
    }

    It 'reads from Deck but writes locally when read-only' {
        $deck = [ordered]@{ found = $true; emulationRoot = 'Z:\@\deck\Emulation'; readable = $true; writable = $false; accessLevel = 'read-only-ok' }
        $roots = Resolve-BootstrapEmulationRoots -DeckInfo $deck
        $roots.roms | Should Be 'Z:\@\deck\Emulation\roms'
        $roots.saves | Should Be (Join-Path $windowsRoot 'saves')
        $roots.cache | Should Be (Join-Path $windowsRoot 'storage\cache')
    }

    It 'falls back fully to Windows when no Deck home found' {
        $deck = [ordered]@{ found = $false; emulationRoot = ''; readable = $false; writable = $false; accessLevel = 'unknown' }
        $roots = Resolve-BootstrapEmulationRoots -DeckInfo $deck
        $roots.roms | Should Be (Join-Path $windowsRoot 'roms')
        $roots.saves | Should Be (Join-Path $windowsRoot 'saves')
        $roots.deckFound | Should Be $false
    }
}
