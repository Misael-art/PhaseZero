$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Steam Deck shared VRAM launch options' {
    It 'exposes sharedVramFix defaults in steamdeck settings schema' {
        $defaults = Get-BootstrapSteamDeckSettingsDefaults -ResolvedSteamDeckVersion 'lcd'

        ($defaults.Contains('sharedVramFix')) | Should Be $true
        ($defaults['sharedVramFix'] -is [System.Collections.IDictionary]) | Should Be $true
        (@($defaults['sharedVramFix']['games']).Count -ge 0) | Should Be $true
    }

    It 'returns dry-run report without mutating files when steam config is absent' {
        $result = Apply-BootstrapSharedVramLaunchOptions -SteamRoot (Join-Path $env:TEMP ('steam-missing-' + [guid]::NewGuid().ToString('N'))) -Settings (Get-BootstrapSteamDeckSettingsDefaults) -DryRun

        [bool]$result.DryRun | Should Be $true
        [string]$result.Status | Should Be 'skipped'
        (([string]$result.Reason).Length -gt 0) | Should Be $true
    }

    It 'runs from copied maintenance folder with sibling bootstrap-tools.ps1' {
        $tempRoot = Join-Path $env:TEMP ('bootstrap-sharedvram-copy-' + [guid]::NewGuid().ToString('N'))
        $missingSteamRoot = Join-Path $env:TEMP ('steam-missing-' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
            Copy-Item -Path (Join-Path $repoRoot 'assets\steamdeck\maintenance\Apply-SharedVramLaunchOptions.ps1') -Destination $tempRoot -Force
            Copy-Item -Path $scriptPath -Destination (Join-Path $tempRoot 'bootstrap-tools.ps1') -Force

            $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $json = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tempRoot 'Apply-SharedVramLaunchOptions.ps1') -SteamRoot $missingSteamRoot -DryRun
            $result = $json | ConvertFrom-Json

            [string]$result.Status | Should Be 'skipped'
            [bool]$result.DryRun | Should Be $true
        } finally {
            if (Test-Path $tempRoot) { Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
