$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot   = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
$snapshotPath = Join-Path $PSScriptRoot 'fixtures\ui-contract-v1-keys.json'

. $scriptPath
Reset-BootstrapFileCmdlets

Describe 'UI Contract structural snapshot' {
    BeforeEach {
        $script:Contract = Get-BootstrapUiContract
        $raw = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8
        $script:Snapshot = $raw | ConvertFrom-Json
    }

    It 'still emits the locked schemaVersion major.minor.patch' {
        $script:Contract.schemaVersion | Should Be $script:Snapshot.schemaVersion
    }

    It 'still has every top-level key recorded in the snapshot' {
        $current = @($script:Contract.Keys) | Sort-Object
        foreach ($expected in @($script:Snapshot.topLevelKeys)) {
            ($current -contains $expected) | Should Be $true
        }
    }

    It 'still has every defaults key recorded in the snapshot' {
        $current = @($script:Contract.defaults.Keys) | Sort-Object
        foreach ($expected in @($script:Snapshot.defaultsKeys)) {
            ($current -contains $expected) | Should Be $true
        }
    }

    It 'still has every secretsRotation key recorded in the snapshot' {
        $current = @($script:Contract.secretsRotation.Keys) | Sort-Object
        foreach ($expected in @($script:Snapshot.secretsRotationKeys)) {
            ($current -contains $expected) | Should Be $true
        }
    }
}
