$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

function New-LifecycleTempDir {
    $d = Join-Path $env:TEMP ("pz-lifecycle-{0}" -f ([Guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

Describe 'Config lifecycle (configure/reset/export/import)' {
    It 'redacts secret-like keys recursively for export' {
        . $scriptPath -BootstrapUiLibraryMode
        $node = [ordered]@{ apiKey = 'sk-secret'; nested = [ordered]@{ token = 'tok'; keep = 'ok' }; list = @([ordered]@{ password = 'p' }) }
        $red = Protect-BootstrapExportedConfig -Node $node
        $red['apiKey'] | Should Be '***REDACTED***'
        $red['nested']['token'] | Should Be '***REDACTED***'
        $red['nested']['keep'] | Should Be 'ok'
        @($red['list'])[0]['password'] | Should Be '***REDACTED***'
    }

    It 'merges conservatively and never overwrites with a redacted placeholder' {
        . $scriptPath -BootstrapUiLibraryMode
        $target = [ordered]@{ apiKey = 'real-key'; theme = 'dark'; nested = [ordered]@{ a = 1 } }
        $source = [ordered]@{ apiKey = '***REDACTED***'; nested = [ordered]@{ b = 2 }; extra = 'new' }
        $merged = Merge-BootstrapConfigGraph -Target $target -Source $source
        $merged.apiKey | Should Be 'real-key'
        $merged.theme | Should Be 'dark'
        $merged.nested.a | Should Be 1
        $merged.nested.b | Should Be 2
        $merged.extra | Should Be 'new'
    }

    It 'declares config descriptors for config-bearing items only' {
        . $scriptPath -BootstrapUiLibraryMode
        (Get-BootstrapItemConfigDescriptor -Id 'mimo-code').managed | Should Be $true
        (Get-BootstrapItemConfigDescriptor -Id 'cursor').managed | Should Be $true
        (Get-BootstrapItemConfigDescriptor -Id 'steam').managed | Should Be $false
    }

    It 'exports managed config to a bundle redacting secrets by default' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = New-LifecycleTempDir
        try {
            $cfg = Join-Path $work 'app.json'
            Set-Content -Path $cfg -Value '{"apiKey":"sk-live","theme":"dark"}' -Encoding UTF8
            $dest = Join-Path $work 'bundle'
            $r = Export-BootstrapItemConfig -Id 'demo' -Destination $dest -ConfigPaths @($cfg)
            [string]$r.status | Should Be 'exported'
            $exported = Get-Content (Join-Path $dest 'demo\app.json') -Raw | ConvertFrom-Json
            [string]$exported.apiKey | Should Be '***REDACTED***'
            [string]$exported.theme | Should Be 'dark'
            (Test-Path (Join-Path $dest 'demo\phasezero-export.json')) | Should Be $true
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'imports config conservatively, backs up, and keeps the real secret over a redacted one' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = New-LifecycleTempDir
        try {
            $target = Join-Path $work 'app.json'
            Set-Content -Path $target -Value '{"apiKey":"real-key","userPref":"keep"}' -Encoding UTF8
            $bundle = Join-Path $work 'bundle\demo'
            New-Item -ItemType Directory -Path $bundle -Force | Out-Null
            Set-Content -Path (Join-Path $bundle 'app.json') -Value '{"apiKey":"***REDACTED***","newField":"added"}' -Encoding UTF8
            $r = Import-BootstrapItemConfig -Id 'demo' -Source (Join-Path $work 'bundle') -ConfigPaths @($target)
            [string]$r.status | Should Be 'imported'
            $after = Get-Content $target -Raw | ConvertFrom-Json
            [string]$after.apiKey | Should Be 'real-key'
            [string]$after.userPref | Should Be 'keep'
            [string]$after.newField | Should Be 'added'
            (Test-Path ($target + '.bak')) | Should Be $true
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'factory-reset restores from a .bak baseline and backs up the current state first' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = New-LifecycleTempDir
        try {
            $target = Join-Path $work 'app.json'
            Set-Content -Path $target -Value '{"state":"current"}' -Encoding UTF8
            Set-Content -Path ($target + '.bak') -Value '{"state":"factory"}' -Encoding UTF8
            $r = Invoke-BootstrapItemFactoryReset -Id 'demo' -ConfigPaths @($target)
            [string]$r.status | Should Be 'reverted'
            (Get-Content $target -Raw) | Should Match 'factory'
            (Test-Path ($target + '.pre-reset.bak')) | Should Be $true
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'factory-reset reports no-baseline when there is no backup' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = New-LifecycleTempDir
        try {
            $target = Join-Path $work 'app.json'
            Set-Content -Path $target -Value '{"state":"current"}' -Encoding UTF8
            $r = Invoke-BootstrapItemFactoryReset -Id 'demo' -ConfigPaths @($target)
            [string]$r.status | Should Be 'no-baseline'
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'batch action aggregates results and is non-blocking for non-config items' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = New-LifecycleTempDir
        try {
            $r = Invoke-BootstrapBatchAction -Action 'export' -Ids @('steam', 'git-core') -Path $work
            [string]$r.action | Should Be 'export'
            $r.count | Should Be 2
            @($r.results).Count | Should Be 2
            foreach ($entry in @($r.results)) { [string]$entry.status | Should Be 'skipped' }
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'dry-run export does not write a bundle' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = New-LifecycleTempDir
        try {
            $cfg = Join-Path $work 'app.json'
            Set-Content -Path $cfg -Value '{"a":1}' -Encoding UTF8
            $dest = Join-Path $work 'bundle'
            $r = Export-BootstrapItemConfig -Id 'demo' -Destination $dest -ConfigPaths @($cfg) -DryRun
            [string]$r.status | Should Be 'planned'
            (Test-Path $dest) | Should Be $false
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
