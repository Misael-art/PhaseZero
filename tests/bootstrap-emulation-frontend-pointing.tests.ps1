$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'ES-DE path pointing (merge-safe)' {
    $tmpProfile = ''
    $settingsPath = ''
    $origProfile = $env:USERPROFILE

    BeforeEach {
        $script:tmpProfile = Join-Path ([System.IO.Path]::GetTempPath()) ('pz-esde-' + [guid]::NewGuid().ToString('N'))
        $settingsDir = Join-Path $script:tmpProfile 'ES-DE\settings'
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        $script:settingsPath = Join-Path $settingsDir 'es_settings.xml'
        @'
<?xml version="1.0"?>
<config>
  <string name="ROMDirectory" value="C:\old\roms" />
  <int name="MaxVRAM" value="256" />
</config>
'@ | Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
        $env:USERPROFILE = $script:tmpProfile
    }
    AfterEach {
        $env:USERPROFILE = $origProfile
        if (Test-Path -LiteralPath $script:tmpProfile) { Remove-Item -LiteralPath $script:tmpProfile -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'updates ROMDirectory and adds MediaDirectory while preserving other keys' {
        $state = @{ DryRun = $false }
        $res = Set-BootstrapEsdePaths -State $state -RomDir 'Z:\Emulation\roms' -MediaDir 'Z:\Emulation\storage\downloaded_media'
        $res.status | Should Be 'updated'
        [xml]$xml = Get-Content -LiteralPath $script:settingsPath -Raw
        ($xml.SelectSingleNode("/config/string[@name='ROMDirectory']").value) | Should Be 'Z:\Emulation\roms'
        ($xml.SelectSingleNode("/config/string[@name='MediaDirectory']").value) | Should Be 'Z:\Emulation\storage\downloaded_media'
        # chave nao-relacionada preservada
        ($xml.SelectSingleNode("/config/int[@name='MaxVRAM']").value) | Should Be '256'
    }

    It 'is unchanged on a second run' {
        $state = @{ DryRun = $false }
        $null = Set-BootstrapEsdePaths -State $state -RomDir 'Z:\Emulation\roms' -MediaDir 'Z:\Emulation\storage\downloaded_media'
        $res2 = Set-BootstrapEsdePaths -State $state -RomDir 'Z:\Emulation\roms' -MediaDir 'Z:\Emulation\storage\downloaded_media'
        $res2.status | Should Be 'unchanged'
    }

    It 'plans only under dry-run (no file change)' {
        $state = @{ DryRun = $true }
        $before = Get-Content -LiteralPath $script:settingsPath -Raw
        $res = Set-BootstrapEsdePaths -State $state -RomDir 'Z:\Emulation\roms' -MediaDir 'Z:\Emulation\media'
        $res.status | Should Be 'planned'
        (Get-Content -LiteralPath $script:settingsPath -Raw) | Should Be $before
    }

    It 'skips when es_settings.xml is absent' {
        Remove-Item -LiteralPath $script:settingsPath -Force
        $state = @{ DryRun = $false }
        $res = Set-BootstrapEsdePaths -State $state -RomDir 'Z:\Emulation\roms' -MediaDir 'Z:\Emulation\media'
        $res.status | Should Be 'skipped'
    }
}
