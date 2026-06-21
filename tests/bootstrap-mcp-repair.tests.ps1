$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

function New-McpRepairTempConfig {
    param([Parameter(Mandatory = $true)][string]$Json)
    $p = Join-Path $env:TEMP ("pz-mcprepair-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
    Set-Content -Path $p -Value $Json -Encoding UTF8
    return $p
}

Describe 'MCP config repair (npx -> cmd /c npx)' {
    It 'rewrites bare npx stdio servers to cmd /c npx and preserves other entries' {
        . $scriptPath -BootstrapUiLibraryMode
        if (-not (Test-BootstrapHostIsWindows)) { return }
        $cfg = New-McpRepairTempConfig -Json '{"mcpServers":{"playwright":{"command":"npx","args":["-y","@playwright/mcp@latest","--isolated"]},"context7":{"command":"npx","args":["-y","mcp-remote@latest","https://mcp.context7.com/mcp"]},"serena":{"command":"serena","args":["start-mcp-server"]},"box":{"url":"https://mcp.box.com","type":"http"}}}'
        try {
            $r = Invoke-BootstrapMcpConfigRepair -ConfigPaths @($cfg)
            [int]$r.totalFixed | Should Be 2
            [string]@($r.targets)[0].status | Should Be 'fixed'
            $after = Get-Content $cfg -Raw | ConvertFrom-Json
            [string]$after.mcpServers.playwright.command | Should Be 'cmd'
            @($after.mcpServers.playwright.args)[0] | Should Be '/c'
            @($after.mcpServers.playwright.args)[1] | Should Be 'npx'
            [string]$after.mcpServers.serena.command | Should Be 'serena'
            [string]$after.mcpServers.box.url | Should Be 'https://mcp.box.com'
            (Test-Path ($cfg + '.bak')) | Should Be $true
        } finally { Remove-Item -LiteralPath $cfg, ($cfg + '.bak') -Force -ErrorAction SilentlyContinue }
    }

    It 'is idempotent (second pass changes nothing)' {
        . $scriptPath -BootstrapUiLibraryMode
        if (-not (Test-BootstrapHostIsWindows)) { return }
        $cfg = New-McpRepairTempConfig -Json '{"mcpServers":{"playwright":{"command":"npx","args":["-y","@playwright/mcp@latest"]}}}'
        try {
            $r1 = Invoke-BootstrapMcpConfigRepair -ConfigPaths @($cfg)
            [int]$r1.totalFixed | Should Be 1
            $r2 = Invoke-BootstrapMcpConfigRepair -ConfigPaths @($cfg)
            [int]$r2.totalFixed | Should Be 0
            [string]@($r2.targets)[0].status | Should Be 'ok'
        } finally { Remove-Item -LiteralPath $cfg, ($cfg + '.bak') -Force -ErrorAction SilentlyContinue }
    }

    It 'dry-run reports would-fix without mutating the file' {
        . $scriptPath -BootstrapUiLibraryMode
        if (-not (Test-BootstrapHostIsWindows)) { return }
        $cfg = New-McpRepairTempConfig -Json '{"mcpServers":{"pw":{"command":"npx","args":["-y","x"]}}}'
        try {
            $before = Get-Content $cfg -Raw
            $r = Invoke-BootstrapMcpConfigRepair -ConfigPaths @($cfg) -DryRun
            [string]@($r.targets)[0].status | Should Be 'would-fix'
            [int]$r.totalFixed | Should Be 1
            (Get-Content $cfg -Raw) | Should Be $before
            (Test-Path ($cfg + '.bak')) | Should Be $false
        } finally { Remove-Item -LiteralPath $cfg, ($cfg + '.bak') -Force -ErrorAction SilentlyContinue }
    }

    It 'reports absent for missing config paths' {
        . $scriptPath -BootstrapUiLibraryMode
        $missing = Join-Path $env:TEMP ("pz-mcprepair-missing-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $r = Invoke-BootstrapMcpConfigRepair -ConfigPaths @($missing)
        [string]@($r.targets)[0].status | Should Be 'absent'
    }

    It 'handles the vscode-style servers container' {
        . $scriptPath -BootstrapUiLibraryMode
        if (-not (Test-BootstrapHostIsWindows)) { return }
        $cfg = New-McpRepairTempConfig -Json '{"servers":{"pw":{"command":"npx","args":["-y","x"]}}}'
        try {
            $r = Invoke-BootstrapMcpConfigRepair -ConfigPaths @($cfg)
            [int]$r.totalFixed | Should Be 1
            $after = Get-Content $cfg -Raw | ConvertFrom-Json
            [string]$after.servers.pw.command | Should Be 'cmd'
        } finally { Remove-Item -LiteralPath $cfg, ($cfg + '.bak') -Force -ErrorAction SilentlyContinue }
    }
}
