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
