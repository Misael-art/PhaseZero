$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Emulation desktop shortcuts folder' {
    $tmpDesktop = ''
    $fakeExe = ''

    BeforeEach {
        $script:tmpDesktop = Join-Path ([System.IO.Path]::GetTempPath()) ('pz-desk-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpDesktop -Force | Out-Null
        $script:fakeExe = Join-Path $script:tmpDesktop 'FakePCSX2.exe'
        Set-Content -LiteralPath $script:fakeExe -Value 'stub'
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:tmpDesktop) { Remove-Item -LiteralPath $script:tmpDesktop -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'creates the emulation folder with shortcuts and a folder icon' {
        Mock Get-BootstrapDesktopPath { $script:tmpDesktop }
        Mock Get-BootstrapEmulationShortcutTargets { @([pscustomobject]@{ DisplayName = 'PCSX2'; Exe = $script:fakeExe }) }

        $res = Ensure-BootstrapEmulationDesktopShortcuts -State @{ DryRun = $false }
        $res.status | Should Be 'completed'
        $res.created | Should Be 1
        # Usa o folder retornado pela funcao (criado com a codificacao do proprio script) em vez
        # de reconstruir o literal acentuado aqui, para o teste ser independente de encoding/BOM.
        $folder = [string]$res.folder
        Test-Path -LiteralPath (Join-Path $folder 'PCSX2.lnk') | Should Be $true
        Test-Path -LiteralPath (Join-Path $folder 'desktop.ini') | Should Be $true
    }

    It 'plans only under dry-run (no folder created)' {
        Mock Get-BootstrapDesktopPath { $script:tmpDesktop }
        Mock Get-BootstrapEmulationShortcutTargets { @([pscustomobject]@{ DisplayName = 'PCSX2'; Exe = $script:fakeExe }) }

        $res = Ensure-BootstrapEmulationDesktopShortcuts -State @{ DryRun = $true }
        $res.planned | Should Be 1
        Test-Path -LiteralPath ([string]$res.folder) | Should Be $false
    }

    It 'completes with nothing to do when no emulator detected' {
        Mock Get-BootstrapDesktopPath { $script:tmpDesktop }
        Mock Get-BootstrapEmulationShortcutTargets { @() }

        $res = Ensure-BootstrapEmulationDesktopShortcuts -State @{ DryRun = $false }
        $res.status | Should Be 'completed'
        $res.targets | Should Be 0
    }
}
