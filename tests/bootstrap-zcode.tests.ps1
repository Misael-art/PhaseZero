$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

Describe 'ZCode component and resilient secrets store' {
    It 'declares zcode as a manual-required component with probe paths' {
        . $scriptPath -BootstrapUiLibraryMode
        $c = (Get-BootstrapComponentCatalog)['zcode']
        $c | Should Not Be $null
        [string]$c.Name | Should Be 'zcode'
        [string]$c.Kind | Should Be 'manual-required'
        (@($c.ProbePaths).Count -ge 1) | Should Be $true
    }

    It 'exposes zcode as an on-demand app in the ia category' {
        . $scriptPath -BootstrapUiLibraryMode
        $od = @(Get-BootstrapOnDemandAppDefinitions | Where-Object { $_.id -eq 'zcode' -or $_.id -eq 'app-zcode' })
        $od.Count | Should Be 1
        [string]$od[0].category | Should Be 'ia'
    }

    It 'produces order-insensitive canonical JSON and still detects real changes (b3 core)' {
        . $scriptPath -BootstrapUiLibraryMode
        $a = ConvertTo-BootstrapStableJson -InputObject @{ b = 1; a = @{ y = 2; x = 1 } }
        $b = ConvertTo-BootstrapStableJson -InputObject @{ a = @{ x = 1; y = 2 }; b = 1 }
        $a | Should Be $b
        (ConvertTo-BootstrapStableJson -InputObject @{ a = 1 }) | Should Not Be (ConvertTo-BootstrapStableJson -InputObject @{ a = 2 })
    }

    It 'does not write when the zCode target has no applicable mcpServers (b2 self-guard)' {
        . $scriptPath -BootstrapUiLibraryMode
        (Ensure-BootstrapZCodeSecrets -ResolvedTargets @{}) | Should Be $false
        (Ensure-BootstrapZCodeSecrets -ResolvedTargets @{ zCode = @{} }) | Should Be $false
        (Ensure-BootstrapZCodeSecrets -ResolvedTargets @{ zCode = @{ mcpServers = @{} } }) | Should Be $false
    }

    It 'is idempotent and backs up before overwriting the store (b1/b3 end-to-end)' {
        . $scriptPath -BootstrapUiLibraryMode
        $tmp = Join-Path $env:TEMP ("zcode_test_{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $origAppData = $env:APPDATA
        try {
            $env:APPDATA = $tmp
            $storePath = Get-BootstrapZCodeStorePath
            $tgt = @{ zCode = @{ mcpServers = @{ context7 = @{ url = 'https://mcp.context7.com/mcp'; type = 'http' } } } }

            # Primeira aplicacao: escreve o store.
            (Ensure-BootstrapZCodeSecrets -ResolvedTargets $tgt) | Should Be $true
            (Test-Path $storePath) | Should Be $true

            # Reaplicacao identica: idempotente, sem churn (b3).
            (Ensure-BootstrapZCodeSecrets -ResolvedTargets $tgt) | Should Be $false

            # Mudanca real: grava de novo e produz backup recuperavel (b1).
            $tgt2 = @{ zCode = @{ mcpServers = @{ context7 = @{ url = 'https://mcp.context7.com/CHANGED'; type = 'http' } } } }
            (Ensure-BootstrapZCodeSecrets -ResolvedTargets $tgt2) | Should Be $true
            (Test-Path ($storePath + '.bak')) | Should Be $true
        } finally {
            $env:APPDATA = $origAppData
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
