$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath

function New-ManagedMcpTestRoot {
    return (Join-Path $env:TEMP ("bootstrap_managed_mcp_{0}" -f ([Guid]::NewGuid().ToString('N'))))
}

function Reset-ManagedMcpTestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $env:BOOTSTRAP_DATA_ROOT = $Path
    Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
}

function Remove-ManagedMcpTestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Bootstrap managed MCPs' {
    BeforeEach {
        $script:TestDataRoot = New-ManagedMcpTestRoot
        Reset-ManagedMcpTestRoot -Path $script:TestDataRoot
        $script:OriginalUserProfile = $env:USERPROFILE
        $script:OriginalAppData = $env:APPDATA
        $script:OriginalLocalAppData = $env:LOCALAPPDATA
    }

    AfterEach {
        $env:USERPROFILE = $script:OriginalUserProfile
        $env:APPDATA = $script:OriginalAppData
        $env:LOCALAPPDATA = $script:OriginalLocalAppData
        Remove-ManagedMcpTestRoot -Path $script:TestDataRoot
        Remove-Variable -Scope Script -Name TestDataRoot -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalUserProfile -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalAppData -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalLocalAppData -ErrorAction SilentlyContinue
    }

    It 'resolves the ai profile with bootstrap-mcps between bootstrap-secrets and vscode-extensions' {
        $resolution = Resolve-BootstrapComponents -SelectedProfiles @('ai') -SelectedComponents @() -ExcludedComponents @()
        $resolved = @($resolution.ResolvedComponents)

        $secretsIndex = [array]::IndexOf($resolved, 'bootstrap-secrets')
        $mcpsIndex = [array]::IndexOf($resolved, 'bootstrap-mcps')
        $extensionsIndex = [array]::IndexOf($resolved, 'vscode-extensions')

        $secretsIndex | Should BeGreaterThan -1
        $mcpsIndex | Should BeGreaterThan -1
        $extensionsIndex | Should BeGreaterThan -1
        $secretsIndex | Should BeLessThan $mcpsIndex
        $mcpsIndex | Should BeLessThan $extensionsIndex
    }

    It 'merges managed MCP servers into VS Code targets without overriding explicit servers' {
        $template = Get-BootstrapSecretsTemplate
        $secretsData = @{
            metadata = @{ version = 2 }
            providers = @{}
            targets = @{
                vsCode = @{
                    mcpServers = @{
                        custom = @{
                            command = 'cmd'
                            args = @('/c', 'echo', 'custom')
                        }
                    }
                }
                continue = $template.targets.continue
            }
        }

        $resolved = Get-BootstrapResolvedSecretsTargets -SecretsData $secretsData -IncludeManagedMcps

        $resolved.vsCode.mcpServers.custom.command | Should Be 'cmd'
        $resolved.vsCode.mcpServers.markitdown.command | Should Be 'markitdown-mcp'
        $resolved.vsCode.mcpServers.notion.command | Should Be 'npx'
        (@($resolved.vsCode.mcpServers.notion.args) -contains 'mcp-remote@latest') | Should Be $true
    }

    It 'uses the remote Context7 bridge by default and enables local Firecrawl when a key is active' {
        $template = Get-BootstrapSecretsTemplate
        $secretsData = @{
            metadata = @{ version = 2 }
            providers = @{
                firecrawl = @{
                    defaults = @{}
                    activeCredential = 'firecrawl-main-01'
                    rotationOrder = @('firecrawl-main-01')
                    credentials = @{
                        'firecrawl-main-01' = @{
                            displayName = 'Main'
                            secret = 'fc-test-token'
                            secretKind = 'apiKey'
                            validation = @{
                                state = 'unknown'
                                checkedAt = ''
                                message = ''
                            }
                        }
                    }
                }
            }
            targets = $template.targets
        }

        $resolved = Get-BootstrapResolvedSecretsTargets -SecretsData $secretsData -IncludeManagedMcps

        $resolved.continue.mcpServers.context7.command | Should Be 'npx'
        (@($resolved.continue.mcpServers.context7.args) -contains 'mcp-remote@latest') | Should Be $true
        (@($resolved.continue.mcpServers.context7.args) -contains 'https://mcp.context7.com/mcp') | Should Be $true
        $resolved.continue.mcpServers.firecrawl.command | Should Be 'npx'
        (@($resolved.continue.mcpServers.firecrawl.args) -contains 'firecrawl-mcp') | Should Be $true
        $resolved.continue.mcpServers.firecrawl.env.FIRECRAWL_API_KEY | Should Be 'fc-test-token'
    }

    It 'builds the Netdata bridge only when token and URL are available' {
        $template = Get-BootstrapSecretsTemplate
        $withNetdata = @{
            metadata = @{ version = 2 }
            providers = @{
                netdata = @{
                    defaults = @{
                        baseUrl = 'http://127.0.0.1:19999/mcp'
                    }
                    activeCredential = 'netdata-main-01'
                    rotationOrder = @('netdata-main-01')
                    credentials = @{
                        'netdata-main-01' = @{
                            displayName = 'Main'
                            secret = 'netdata-token'
                            secretKind = 'token'
                            validation = @{
                                state = 'unknown'
                                checkedAt = ''
                                message = ''
                            }
                        }
                    }
                }
            }
            targets = $template.targets
        }

        $withoutNetdata = @{
            metadata = @{ version = 2 }
            providers = @{}
            targets = $template.targets
        }

        $withResolved = Get-BootstrapResolvedSecretsTargets -SecretsData $withNetdata -IncludeManagedMcps
        $withoutResolved = Get-BootstrapResolvedSecretsTargets -SecretsData $withoutNetdata -IncludeManagedMcps

        $withResolved.vsCode.mcpServers.netdata.command | Should Be 'npx'
        (@($withResolved.vsCode.mcpServers.netdata.args) -contains '--http') | Should Be $true
        (@($withResolved.vsCode.mcpServers.netdata.args) -contains 'http://127.0.0.1:19999/mcp') | Should Be $true
        (@($withResolved.vsCode.mcpServers.netdata.args) -contains '--header') | Should Be $true
        ($withResolved.vsCode.mcpServers.netdata.args -join ' ') | Should Match 'Authorization: Bearer netdata-token'
        $withoutResolved.vsCode.mcpServers.Contains('netdata') | Should Be $false
    }

    It 'writes Continue config with managed MCP entries' {
        $env:USERPROFILE = Join-Path $script:TestDataRoot 'User'
        $resolvedTargets = Get-BootstrapResolvedSecretsTargets -SecretsData (Get-BootstrapSecretsTemplate) -IncludeManagedMcps

        $summary = Ensure-BootstrapContinueExtensionConfig -ResolvedTargets $resolvedTargets

        $summary.configured | Should Be $true
        $summary.envUpdated | Should Be $false
        (Test-Path $summary.envPath) | Should Be $false
        (Get-Content -Raw -Path $summary.configPath) | Should Match 'markitdown'
        (Get-Content -Raw -Path $summary.configPath) | Should Match 'serena'
        (Get-Content -Raw -Path $summary.configPath) | Should Match 'mcp-remote@latest'
        (Get-Content -Raw -Path $summary.configPath) | Should Match 'https://mcp.notion.com/mcp'
    }

    It 'records managed MCP package installation state without writing secrets into the repo' {
        $env:USERPROFILE = Join-Path $script:TestDataRoot 'User'
        $env:APPDATA = Join-Path $script:TestDataRoot 'AppData\Roaming'
        $env:LOCALAPPDATA = Join-Path $script:TestDataRoot 'AppData\Local'
        New-Item -Path $env:USERPROFILE -ItemType Directory -Force | Out-Null
        New-Item -Path $env:APPDATA -ItemType Directory -Force | Out-Null
        New-Item -Path $env:LOCALAPPDATA -ItemType Directory -Force | Out-Null

        Mock Ensure-BootstrapNodeCore {}
        Mock Ensure-BootstrapPythonCore {}
        Mock Ensure-NpmGlobalPackage {}
        Mock Ensure-UvToolPackage {}

        $state = New-BootstrapState -ResolvedWorkspaceRoot $PWD.Path -ResolvedCloneBaseDir $PWD.Path -RequestedSteamDeckVersion 'Auto' -ResolvedSteamDeckVersion '' -HostHealthMode 'off' -UsesSteamDeckFlow:$false -IsDryRun:$false
        $state.NodeInfo = @{ NpmCmd = 'npm.cmd' }
        $state.PythonReady = $true

        $summary = Ensure-BootstrapManagedMcps -State $state

        (Test-Path $summary.path) | Should Be $true
        @($summary.packages).Count | Should Be 10
        @($summary.mcps).Count | Should Be 15
        $state.McpStatePath | Should Be $summary.path
    }

    It 'filters blank uv install args before invoking installers' {
        $filtered = Get-BootstrapNonEmptyStringArray -Values @('', '   ', '--prerelease=allow', $null, '-p', '3.13')

        $filtered | Should Be @('--prerelease=allow', '-p', '3.13')
    }

    It 'accepts uv tool installs when the executable is available after a noisy nonzero exit code' {
        $env:USERPROFILE = Join-Path $script:TestDataRoot 'User'
        New-Item -Path $env:USERPROFILE -ItemType Directory -Force | Out-Null

        $script:UvFallbackCommandName = 'phasezero-uv-fallback'
        $script:UvFallbackResolveCalls = 0
        Mock Resolve-CommandPath {
            param([string]$Name)
            if ($Name -eq $script:UvFallbackCommandName) {
                $script:UvFallbackResolveCalls += 1
                if ($script:UvFallbackResolveCalls -eq 1) {
                    return $null
                }
                return 'C:\Tools\phasezero-uv-fallback.exe'
            }
            return 'C:\Tools\other.exe'
        }
        Mock Ensure-Uv { return 'C:\Tools\uv.exe' }
        Mock Get-BootstrapUserHomePath { return $env:USERPROFILE }
        Mock Ensure-PathUserContains {}
        Mock Refresh-SessionPath {}
        Mock Invoke-NativeWithRetry { return -1 }
        Mock Invoke-NativeFirstLine { return 'phasezero 1.0.0' }

        { Ensure-UvToolPackage -Package 'phasezero-tool' -CommandName $script:UvFallbackCommandName -DisplayName 'PhaseZero Tool' } | Should Not Throw
    }

    It 'returns exit code zero for successful native commands that emit output' {
        $originalLogPath = $script:LogPath
        New-Item -Path $script:TestDataRoot -ItemType Directory -Force | Out-Null
        $script:LogPath = Join-Path $script:TestDataRoot 'invoke-native.log'
        $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'

        try {
            $exitCode = Invoke-NativeWithLog -Exe $cmdExe -Args @('/c', 'echo hello')
        } finally {
            $script:LogPath = $originalLogPath
        }

        $exitCode | Should Be 0
    }

    It 'renders Zed MCP entries with flat local commands and native remote URLs' {
        $local = ConvertTo-BootstrapMcpServerEntry -ServerDefinition ([ordered]@{
            command = 'npx'
            args = @('-y', 'chrome-devtools-mcp@latest', '--isolated')
        }) -Format 'zed'
        $remote = ConvertTo-BootstrapMcpServerEntry -ServerDefinition (New-BootstrapManagedMcpRemoteBridgeServer -Url 'https://mcp.context7.com/mcp') -Format 'zed'

        $local.command | Should Be 'npx'
        $local.args | Should Be @('-y', 'chrome-devtools-mcp@latest', '--isolated')
        $local.Contains('url') | Should Be $false
        $remote.url | Should Be 'https://mcp.context7.com/mcp'
        $remote.Contains('command') | Should Be $false
    }

    It 'renders VS Code remote bridge servers as native http definitions' {
        $remote = ConvertTo-BootstrapMcpServerEntry -ServerDefinition (New-BootstrapManagedMcpRemoteBridgeServer -Url 'https://mcp.context7.com/mcp') -Format 'vscode'

        $remote.type | Should Be 'http'
        $remote.url | Should Be 'https://mcp.context7.com/mcp'
        $remote.Contains('command') | Should Be $false
    }
}
