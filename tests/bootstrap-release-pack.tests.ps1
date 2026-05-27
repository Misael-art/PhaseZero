$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

. $scriptPath
Reset-BootstrapFileCmdlets

Describe 'PhaseZero ReleasePack' {
    BeforeEach {
        $script:ReleasePackTestRoot = Join-Path $env:TEMP ("phasezero_release_{0}" -f ([Guid]::NewGuid().ToString('N')))
        $null = New-Item -Path $script:ReleasePackTestRoot -ItemType Directory -Force
    }

    AfterEach {
        Remove-Item -LiteralPath $script:ReleasePackTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name ReleasePackTestRoot -ErrorAction SilentlyContinue
    }

    It 'creates zip, checksums, changelog, version metadata and parseable upgrade script without secrets' {
        $pack = New-BootstrapReleasePack -Version '9.9.9' -DestinationRoot $script:ReleasePackTestRoot

        Test-Path -LiteralPath ([string]$pack.zipPath) | Should Be $true
        Test-Path -LiteralPath ([string]$pack.checksumsPath) | Should Be $true
        Test-Path -LiteralPath ([string]$pack.changelogPath) | Should Be $true
        Test-Path -LiteralPath ([string]$pack.versionJsonPath) | Should Be $true
        Test-Path -LiteralPath ([string]$pack.upgradePath) | Should Be $true

        $version = Get-Content -LiteralPath ([string]$pack.versionJsonPath) -Raw | ConvertFrom-Json
        [string]$version.commit | Should Not Be ''
        [string]$version.contractVersion | Should Not Be ''

        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile([string]$pack.upgradePath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should Be 0

        $checksumText = Get-Content -LiteralPath ([string]$pack.checksumsPath) -Raw
        $zipName = Split-Path -Leaf ([string]$pack.zipPath)
        $checksumText | Should Match ([regex]::Escape($zipName))
        $zipHash = Get-BootstrapFileSha256 -Path ([string]$pack.zipPath)
        $checksumText.ToLowerInvariant() | Should Match $zipHash

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $extractRoot = Join-Path $script:ReleasePackTestRoot 'extract'
        [System.IO.Compression.ZipFile]::ExtractToDirectory([string]$pack.zipPath, $extractRoot)
        $entries = @(Get-ChildItem -Path $extractRoot -Recurse -File)
        (@($entries | Where-Object { $_.Name -match 'bootstrap-secrets|\.env' }).Count) | Should Be 0
        $allText = ($entries | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue }) -join [Environment]::NewLine
        $allText | Should Not Match 'protectedData'
        $allText | Should Not Match 'ghp_'
        $allText | Should Not Match 'sk-'
        $allText | Should Not Match 'sk-or-'
    }
}
