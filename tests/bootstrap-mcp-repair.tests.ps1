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
    It 'includes Claude Code user settings in repair targets' {
        . $scriptPath -BootstrapUiLibraryMode
        $targets = @(Get-BootstrapMcpRepairTargets)

        (@($targets | Where-Object { [string]$_.id -eq 'claude-code' }).Count -gt 0) | Should Be $true
    }

    It 'wraps npx while preserving the complete argument list' {
        . $scriptPath -BootstrapUiLibraryMode
        if (-not (Test-BootstrapHostIsWindows)) { return }
        $wrap = Get-BootstrapWindowsNpxLaunch -Command 'npx' -CommandArgs @('-y', '@playwright/mcp@latest', '--isolated')

        [string]$wrap.command | Should Be 'cmd'
        @($wrap.args) | Should Be @('/c', 'npx', '-y', '@playwright/mcp@latest', '--isolated')
    }

    It 'serializes managed stdio servers with the full npx package arguments' {
        . $scriptPath -BootstrapUiLibraryMode
        if (-not (Test-BootstrapHostIsWindows)) { return }
        $server = New-BootstrapManagedMcpCommandServer -Command 'npx' -Args @('-y', 'chrome-devtools-mcp@latest', '--isolated')
        $entry = ConvertTo-BootstrapMcpServerEntry -ServerDefinition $server -Format 'standard'

        [string]$entry.command | Should Be 'cmd'
        @($entry.args) | Should Be @('/c', 'npx', '-y', 'chrome-devtools-mcp@latest', '--isolated')
    }

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
            @($after.mcpServers.playwright.args) | Should Be @('/c', 'npx', '-y', '@playwright/mcp@latest', '--isolated')
            @($after.mcpServers.context7.args) | Should Be @('/c', 'npx', '-y', 'mcp-remote@latest', 'https://mcp.context7.com/mcp')
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

    It 'repairs managed entries previously truncated to cmd /c npx only' {
        . $scriptPath -BootstrapUiLibraryMode
        if (-not (Test-BootstrapHostIsWindows)) { return }
        $cfg = New-McpRepairTempConfig -Json '{"mcpServers":{"desktop-commander":{"command":"cmd","args":["/c","npx"],"enabled":true},"chrome-devtools":{"command":"cmd","args":["/c","npx"],"enabled":true},"playwright":{"command":"cmd","args":["/c","npx"],"enabled":true},"serena":{"command":"serena","args":["start-mcp-server","--project-from-cwd"]}}}'
        try {
            $r = Invoke-BootstrapMcpConfigRepair -ConfigPaths @($cfg)
            [int]$r.totalFixed | Should Be 3
            $after = Get-Content $cfg -Raw | ConvertFrom-Json
            @($after.mcpServers.'desktop-commander'.args) | Should Be @('/c', 'npx', '-y', '@wonderwhy-er/desktop-commander@latest', '--no-onboarding')
            @($after.mcpServers.'chrome-devtools'.args) | Should Be @('/c', 'npx', '-y', 'chrome-devtools-mcp@latest', '--isolated')
            @($after.mcpServers.playwright.args) | Should Be @('/c', 'npx', '-y', '@playwright/mcp@latest', '--isolated')
            @($after.mcpServers.serena.args) | Should Be @('start-mcp-server', '--project-from-cwd')
        } finally { Remove-Item -LiteralPath $cfg, ($cfg + '.bak') -Force -ErrorAction SilentlyContinue }
    }

    It 'registers a file backup so rollback restores repaired MCP config instead of deleting it' {
        . $scriptPath -BootstrapUiLibraryMode
        if (-not (Test-BootstrapHostIsWindows)) { return }
        $root = Join-Path $env:TEMP ("pz-mcprepair-rollback-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $null = New-Item -Path $root -ItemType Directory -Force
        $cfg = Join-Path $root 'mcp.json'
        $original = '{"mcpServers":{"pw":{"command":"npx","args":["-y","x"]}}}'
        Set-Content -LiteralPath $cfg -Value $original -Encoding UTF8
        try {
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot $root -ResolvedCloneBaseDir $root
            $state.ChangeManifestPath = Join-Path $root 'changes.json'

            $r = Invoke-BootstrapMcpConfigRepair -ConfigPaths @($cfg) -State $state
            [int]$r.totalFixed | Should Be 1
            Test-Path -LiteralPath $state.ChangeManifestPath | Should Be $true
            $manifest = Get-Content -LiteralPath $state.ChangeManifestPath -Raw | ConvertFrom-Json
            [string]$manifest.changes[0].Type | Should Be 'File'
            [string]::IsNullOrWhiteSpace([string]$manifest.changes[0].OldValue) | Should Be $false
            Test-Path -LiteralPath ([string]$manifest.changes[0].OldValue) | Should Be $true

            Invoke-BootstrapRollback -ChangesPath $state.ChangeManifestPath | Out-Null
            Test-Path -LiteralPath $cfg | Should Be $true
            (Get-Content -LiteralPath $cfg -Raw) | Should Match '"command"\s*:\s*"npx"'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
