$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

function New-MimoTempConfig {
    return (Join-Path $env:TEMP ("mimocode-{0}.json" -f ([Guid]::NewGuid().ToString('N'))))
}

Describe 'MiMo Code integration' {
    It 'declares mimo-code as an npm component in the ai profile' {
        . $scriptPath -BootstrapUiLibraryMode
        $c = (Get-BootstrapComponentCatalog)['mimo-code']
        $c | Should Not Be $null
        [string]$c.Kind | Should Be 'npm'
        [string]$c.Package | Should Be '@mimo-ai/cli'
        (@($c.CommandNames) -contains 'mimo') | Should Be $true
        (@((Get-BootstrapProfileCatalog)['ai'].Items) -contains 'mimo-code') | Should Be $true
    }

    It 'resolves the global config path under the user profile' {
        . $scriptPath -BootstrapUiLibraryMode
        (Get-BootstrapMimoCodeConfigPath) | Should Match 'mimocode\\mimocode\.json$'
    }

    It 'keeps MiMo Auto (free) and writes nothing when no validated provider exists' {
        . $scriptPath -BootstrapUiLibraryMode
        $tmp = New-MimoTempConfig
        $r = Ensure-BootstrapMimoCodeConfig -State @{ DryRun = $false } -Candidate ([ordered]@{ status = 'none' }) -ConfigPath $tmp
        [string]$r.status | Should Be 'skipped'
        (Test-Path $tmp) | Should Be $false
    }

    It 'does not write the config in dry-run even with a validated provider' {
        . $scriptPath -BootstrapUiLibraryMode
        $tmp = New-MimoTempConfig
        $cand = [ordered]@{ status = 'selected'; provider = 'mimo'; baseUrl = 'https://x/v1'; apiKey = 'sk-dry' }
        $r = Ensure-BootstrapMimoCodeConfig -State @{ DryRun = $true } -Candidate $cand -ConfigPath $tmp
        [string]$r.status | Should Be 'planned'
        (Test-Path $tmp) | Should Be $false
    }

    It 'writes an OpenAI-compatible provider block from a validated candidate and is idempotent' {
        . $scriptPath -BootstrapUiLibraryMode
        $tmp = New-MimoTempConfig
        $cand = [ordered]@{ status = 'selected'; provider = 'openrouter'; baseUrl = 'https://openrouter.ai/api/v1'; apiKey = 'sk-test-123' }
        try {
            $r = Ensure-BootstrapMimoCodeConfig -State @{ DryRun = $false } -Candidate $cand -ConfigPath $tmp
            [string]$r.status | Should Be 'configured'
            (Test-Path $tmp) | Should Be $true
            $cfg = Get-Content $tmp -Raw | ConvertFrom-Json
            [string]$cfg.provider.internal.options.baseURL | Should Be 'https://openrouter.ai/api/v1'
            [string]$cfg.provider.internal.options.apiKey | Should Be 'sk-test-123'
            $r2 = Ensure-BootstrapMimoCodeConfig -State @{ DryRun = $false } -Candidate $cand -ConfigPath $tmp
            [string]$r2.status | Should Be 'unchanged'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($tmp + '.bak') -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves unknown fields and writes a backup before overwriting' {
        . $scriptPath -BootstrapUiLibraryMode
        $tmp = New-MimoTempConfig
        Set-Content -Path $tmp -Value '{"theme":"dark","provider":{"internal":{"options":{"baseURL":"old-url"}}}}' -Encoding UTF8
        $cand = [ordered]@{ status = 'selected'; provider = 'mimo'; baseUrl = 'https://new/v1'; apiKey = 'sk-x' }
        try {
            $r = Ensure-BootstrapMimoCodeConfig -State @{ DryRun = $false } -Candidate $cand -ConfigPath $tmp
            [string]$r.status | Should Be 'configured'
            $cfg = Get-Content $tmp -Raw | ConvertFrom-Json
            [string]$cfg.theme | Should Be 'dark'
            [string]$cfg.provider.internal.options.baseURL | Should Be 'https://new/v1'
            (Test-Path ($tmp + '.bak')) | Should Be $true
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($tmp + '.bak') -Force -ErrorAction SilentlyContinue
        }
    }
}
