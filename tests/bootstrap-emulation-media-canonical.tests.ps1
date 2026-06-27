$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Deck media canonicalization' {
    $tmp = ''
    $mediaSnes = ''

    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pz-media-' + [guid]::NewGuid().ToString('N'))
        $script:mediaSnes = Join-Path $script:tmp 'storage\downloaded_media\snes'
        New-Item -ItemType Directory -Path $script:mediaSnes -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'roms\snes') -Force | Out-Null
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:tmp) { Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    function New-WritableDeckState {
        param([string]$Root)
        return @{
            DryRun = $false
            DeckEmulation = [ordered]@{ found = $true; emulationRoot = $Root; readable = $true; writable = $true; accessLevel = 'write-opt-in' }
        }
    }

    It 'creates canonical dirs and compat junctions for an existing system' {
        $state = New-WritableDeckState -Root $script:tmp
        $res = Ensure-BootstrapDeckMediaCanonical -State $state
        $res.dirsCreated -gt 0 | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:mediaSnes 'box2dfront') -PathType Container | Should Be $true
        # compat: cover -> box2dfront
        $coverPath = Join-Path $script:mediaSnes 'cover'
        Test-Path -LiteralPath $coverPath | Should Be $true
        (Get-BootstrapDirectoryReparseTarget -Path $coverPath) | Should Match 'box2dfront'
    }

    It 'is idempotent on a second run (no new dirs/links, no warnings)' {
        $state = New-WritableDeckState -Root $script:tmp
        $null = Ensure-BootstrapDeckMediaCanonical -State $state
        $res2 = Ensure-BootstrapDeckMediaCanonical -State $state
        $res2.dirsCreated | Should Be 0
        $res2.linksCreated | Should Be 0
        $res2.warnings | Should Be 0
    }

    It 'never overwrites a real folder occupying an alias name (warns instead)' {
        New-Item -ItemType Directory -Path (Join-Path $script:mediaSnes 'cover') -Force | Out-Null
        $marker = Join-Path (Join-Path $script:mediaSnes 'cover') 'keep.txt'
        Set-Content -LiteralPath $marker -Value 'x'
        $state = New-WritableDeckState -Root $script:tmp
        $res = Ensure-BootstrapDeckMediaCanonical -State $state
        $res.warnings -gt 0 | Should Be $true
        Test-Path -LiteralPath $marker | Should Be $true
        (Get-BootstrapDirectoryReparseTarget -Path (Join-Path $script:mediaSnes 'cover')) | Should Be ''
    }

    It 'plans only (no writes) when the Deck media root is read-only' {
        $state = @{
            DryRun = $false
            DeckEmulation = [ordered]@{ found = $true; emulationRoot = $script:tmp; readable = $true; writable = $false; accessLevel = 'read-only-ok' }
        }
        $res = Ensure-BootstrapDeckMediaCanonical -State $state
        $res.dryRun | Should Be $true
        $res.dirsCreated | Should Be 0
        Test-Path -LiteralPath (Join-Path $script:mediaSnes 'box2dfront') -PathType Container | Should Be $false
    }
}
