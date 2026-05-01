$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Steam Deck Windows input tooling catalog' {
    It 'exposes Handheld Companion through winget and GlosSI through Chocolatey' {
        $catalog = Get-BootstrapComponentCatalog

        [string]$catalog['handheld-companion'].Kind | Should Be 'winget'
        [string]$catalog['handheld-companion'].Id | Should Be 'BenjaminLSR.HandheldCompanion'
        [string]$catalog['handheld-companion'].DisplayName | Should Be 'Handheld Companion'

        [string]$catalog['glossi'].Kind | Should Be 'chocolatey'
        [string]$catalog['glossi'].Package | Should Be 'glossi'
        [string]$catalog['glossi'].DisplayName | Should Be 'GlosSI'

        [string]$catalog['steamdeck-input-conflict-audit'].Kind | Should Be 'alias'
    }

    It 'keeps advanced input stack opt-in and adds conflict audit to default Steam Deck input flow' {
        $profiles = Get-BootstrapProfileCatalog

        @($profiles['steamdeck-input'].Items) -contains 'steamdeck-input-conflict-audit' | Should Be $true
        @($profiles['steamdeck-input-advanced'].Items) -contains 'handheld-companion' | Should Be $true
        @($profiles['steamdeck-input-advanced'].Items) -contains 'glossi' | Should Be $true
        @($profiles['steamdeck-recommended'].Items) -contains 'steamdeck-input-advanced' | Should Be $false
    }

    It 'publishes Handheld Companion and GlosSI as apps installable on demand' {
        $apps = Get-BootstrapAppCatalog
        $handheld = @($apps) | Where-Object { $_.app -eq 'handheld-companion' } | Select-Object -First 1
        $glossi = @($apps) | Where-Object { $_.app -eq 'glossi' } | Select-Object -First 1

        $handheld.displayName | Should Be 'Handheld Companion'
        $handheld.component | Should Be 'handheld-companion'
        $handheld.wingetId | Should Be 'BenjaminLSR.HandheldCompanion'

        $glossi.displayName | Should Be 'GlosSI'
        $glossi.component | Should Be 'glossi'
        $glossi.provisioning | Should Be 'chocolatey'
    }

    It 'marks Chocolatey packages as network-required without requiring winget' {
        $requirements = Get-BootstrapPreflightRequirements -ResolvedComponents @('glossi')

        [bool]$requirements.RequiresNetwork | Should Be $true
        [bool]$requirements.RequiresWinget | Should Be $false
        @($requirements.ConnectivityGroups | ForEach-Object { $_.Name }) -contains 'chocolatey' | Should Be $true
    }
}
