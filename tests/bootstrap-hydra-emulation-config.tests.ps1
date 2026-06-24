$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Hydra shared emulator config merge' {
    It 'merges PS2 and PS3 pointers while preserving unknown keys' {
        $root = Join-Path $env:TEMP ('pz-hydra-config-' + [Guid]::NewGuid().ToString('N'))
        $cfg = Join-Path $root 'emulators_config.json'
        New-Item -Path $root -ItemType Directory -Force | Out-Null
        try {
            '{"custom":{"enabled":true,"note":"keep"}}' | Set-Content -LiteralPath $cfg -Encoding UTF8

            $result = Merge-BootstrapHydraEmulatorConfig -ConfigPath $cfg -Entries @(
                @{ systemKey = 'playstation2'; emulatorName = 'PCSX2-Qt'; executablePath = 'X:\Emulation\emulators\pcsx2\pcsx2-qt.exe'; romsDirectory = 'X:\Emulation\roms\ps2'; defaultFlags = '--fullscreen --nogui' },
                @{ systemKey = 'playstation3'; emulatorName = 'RPCS3'; executablePath = 'X:\Emulation\emulators\rpcs3\rpcs3.exe'; romsDirectory = 'X:\Emulation\roms\ps3'; defaultFlags = '--no-gui --fullscreen' }
            )

            [bool]$result.changed | Should Be $true
            $json = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
            [string]$json.custom.note | Should Be 'keep'
            [string]$json.playstation2.emulator_name | Should Be 'PCSX2-Qt'
            [string]$json.playstation3.emulator_name | Should Be 'RPCS3'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not write when Hydra is running unless force is explicit' {
        $root = Join-Path $env:TEMP ('pz-hydra-lock-' + [Guid]::NewGuid().ToString('N'))
        $cfg = Join-Path $root 'emulators_config.json'
        New-Item -Path $root -ItemType Directory -Force | Out-Null
        try {
            '{}' | Set-Content -LiteralPath $cfg -Encoding UTF8
            $result = Merge-BootstrapHydraEmulatorConfig -ConfigPath $cfg -Entries @() -HydraProcessRunning:$true

            [bool]$result.changed | Should Be $false
            [string]$result.status | Should Be 'blocked-process-running'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
