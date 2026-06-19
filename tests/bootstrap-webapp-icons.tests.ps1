$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

Describe 'Web app identity icons' {
    It 'validates real .ico files by magic bytes and rejects non-ico content' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = Join-Path $env:TEMP ("pz-ico-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        try {
            $ico = Join-Path $work 'ok.ico'
            [System.IO.File]::WriteAllBytes($ico, [byte[]]@(0, 0, 1, 0, 1, 0, 16, 16))
            Test-BootstrapIcoFile -Path $ico | Should Be $true

            $html = Join-Path $work 'bad.ico'
            Set-Content -Path $html -Value '<!DOCTYPE html><html>404</html>' -Encoding UTF8
            Test-BootstrapIcoFile -Path $html | Should Be $false

            Test-BootstrapIcoFile -Path (Join-Path $work 'missing.ico') | Should Be $false
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns empty (no throw) for an unparseable URL without hitting the network' {
        . $scriptPath -BootstrapUiLibraryMode
        $r = Resolve-BootstrapWebAppIconLocation -Url 'not a url' -DisplayName 'Demo App'
        [string]$r | Should Be ''
    }

    It 'honours a curated icon asset when present' {
        . $scriptPath -BootstrapUiLibraryMode
        $assetDir = Join-Path $PSScriptRoot '..\assets\webapp-icons'
        $assetDir = [System.IO.Path]::GetFullPath($assetDir)
        New-Item -ItemType Directory -Path $assetDir -Force | Out-Null
        $slug = 'pz-icon-test-app'
        $asset = Join-Path $assetDir ("{0}.ico" -f $slug)
        $created = $false
        try {
            if (-not (Test-Path -LiteralPath $asset)) {
                [System.IO.File]::WriteAllBytes($asset, [byte[]]@(0, 0, 1, 0, 1, 0, 32, 32))
                $created = $true
            }
            $r = Resolve-BootstrapWebAppIconLocation -Url 'https://example.com/' -DisplayName 'PZ Icon Test App'
            $r | Should Match ([regex]::Escape($slug))
        } finally {
            if ($created -and (Test-Path -LiteralPath $asset)) { Remove-Item -LiteralPath $asset -Force -ErrorAction SilentlyContinue }
        }
    }
}
