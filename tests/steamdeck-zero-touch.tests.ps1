$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Steam Deck zero-touch provisioning' {
    It 'adds epic-games and msi-afterburner components with expected winget ids' {
        $catalog = Get-BootstrapComponentCatalog

        [string]$catalog['epic-games'].Kind | Should Be 'winget'
        [string]$catalog['epic-games'].Id | Should Be 'EpicGames.EpicGamesLauncher'
        [string]$catalog['msi-afterburner'].Kind | Should Be 'winget'
        [string]$catalog['msi-afterburner'].Id | Should Be 'Guru3D.Afterburner'
    }

    It 'keeps mem-reduct with corrected winget id casing' {
        $catalog = Get-BootstrapComponentCatalog

        [string]$catalog['mem-reduct'].Id | Should Be 'Henry++.MemReduct'
    }

    It 'includes zero-touch payload in steamdeck full profile and keeps lossless manual blocker' {
        $profiles = Get-BootstrapProfileCatalog
        $catalog = Get-BootstrapComponentCatalog
        $items = @($profiles['steamdeck-full'].Items | ForEach-Object { [string]$_ })

        ($items -contains 'epic-games') | Should Be $true
        ($items -contains 'msi-afterburner') | Should Be $true
        [string]$catalog['lossless-scaling'].Kind | Should Be 'manual-required'
    }

    It 'does not invoke winget during zero-touch dry-run' {
        $result = Invoke-BootstrapSteamDeckZeroTouchProvisioning -State @{
            Winget = 'missing-winget-for-dry-run.exe'
            IsDryRun = $true
        }

        @($result.results).Count | Should BeGreaterThan 0
        @($result.results | Where-Object { [string]$_.status -ne 'planned' }).Count | Should Be 0
    }
}
