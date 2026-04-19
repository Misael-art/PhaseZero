$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath

function New-TestDataRoot {
    return (Join-Path $env:TEMP ("bootstrap_vscode_ext_{0}" -f ([Guid]::NewGuid().ToString('N'))))
}

function Reset-TestDataRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $env:BOOTSTRAP_DATA_ROOT = $Path
    Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
}

function Remove-TestDataRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Bootstrap VS Code extensions' {
    BeforeEach {
        $script:TestDataRoot = New-TestDataRoot
        Reset-TestDataRoot -Path $script:TestDataRoot
        $script:OriginalAppData = $env:APPDATA
        $script:OriginalLocalAppData = $env:LOCALAPPDATA
        $script:OriginalUserProfile = $env:USERPROFILE
    }

    AfterEach {
        $env:APPDATA = $script:OriginalAppData
        $env:LOCALAPPDATA = $script:OriginalLocalAppData
        $env:USERPROFILE = $script:OriginalUserProfile
        Remove-TestDataRoot -Path $script:TestDataRoot
        Remove-Variable -Scope Script -Name TestDataRoot -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalAppData -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalLocalAppData -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalUserProfile -ErrorAction SilentlyContinue
    }

    It 'resolves the ai profile with vscode and vscode-insiders before bootstrap-secrets and vscode-extensions' {
        $resolution = Resolve-BootstrapComponents -SelectedProfiles @('ai') -SelectedComponents @() -ExcludedComponents @()
        $resolved = @($resolution.ResolvedComponents)

        $stableIndex = [array]::IndexOf($resolved, 'vscode')
        $insidersIndex = [array]::IndexOf($resolved, 'vscode-insiders')
        $secretsIndex = [array]::IndexOf($resolved, 'bootstrap-secrets')
        $extensionsIndex = [array]::IndexOf($resolved, 'vscode-extensions')

        $stableIndex | Should BeGreaterThan -1
        $insidersIndex | Should BeGreaterThan -1
        $secretsIndex | Should BeGreaterThan -1
        $extensionsIndex | Should BeGreaterThan -1
        $stableIndex | Should BeLessThan $secretsIndex
        $insidersIndex | Should BeLessThan $secretsIndex
        $secretsIndex | Should BeLessThan $extensionsIndex
    }

    It 'reads JSONC files with comments and trailing commas before updating VS Code settings' {
        $settingsPath = Join-Path $script:TestDataRoot 'settings.json'
        New-Item -Path (Split-Path -Path $settingsPath -Parent) -ItemType Directory -Force | Out-Null
        @'
{
  // comment
  "editor.fontSize": 14,
  "files.autoSave": "off",
}
'@ | Set-Content -Path $settingsPath -Encoding utf8

        $changed = Ensure-BootstrapJsonPropertyFile -Path $settingsPath -Values @{
            'agentMemory.storageBackend' = 'secret'
            'agentMemory.autoSyncToFile' = ''
        } -Label 'VS Code settings'

        $changed | Should Be $true
        $saved = Read-BootstrapJsonFile -Path $settingsPath
        $saved['editor.fontSize'] | Should Be 14
        $saved['files.autoSave'] | Should Be 'off'
        $saved['agentMemory.storageBackend'] | Should Be 'secret'
        $saved['agentMemory.autoSyncToFile'] | Should Be ''
    }

    It 'auto-enables the Continue github MCP only when a validated github token exists' {
        $withGithub = @{
            metadata = @{ version = 2 }
            providers = @{
                github = @{
                    defaults = @{}
                    activeCredential = 'github-main-01'
                    rotationOrder = @('github-main-01')
                    credentials = @{
                        'github-main-01' = @{
                            displayName = 'Main'
                            secret = 'ghp-valid'
                            secretKind = 'token'
                            validation = @{
                                state = 'passed'
                                checkedAt = '2026-04-19T00:00:00Z'
                                message = 'ok'
                            }
                        }
                    }
                }
            }
            targets = @{
                continue = @{
                    env = @{
                        GITHUB_TOKEN = '{{activeProviders.github.token}}'
                    }
                    mcpServers = @{
                        github = @{
                            enabled = $false
                            command = 'npx'
                            args = @('-y', '@modelcontextprotocol/server-github')
                            env = @{
                                GITHUB_TOKEN = '{{activeProviders.github.token}}'
                            }
                        }
                    }
                }
            }
        }

        $withoutGithub = @{
            metadata = @{ version = 2 }
            providers = @{
                github = @{
                    defaults = @{}
                    activeCredential = 'github-main-01'
                    rotationOrder = @('github-main-01')
                    credentials = @{
                        'github-main-01' = @{
                            displayName = 'Main'
                            secret = 'ghp-invalid'
                            secretKind = 'token'
                            validation = @{
                                state = 'failed'
                                checkedAt = '2026-04-19T00:00:00Z'
                                message = '401'
                            }
                        }
                    }
                }
            }
            targets = @{
                continue = @{
                    env = @{
                        GITHUB_TOKEN = '{{activeProviders.github.token}}'
                    }
                    mcpServers = @{
                        github = @{
                            enabled = $false
                            command = 'npx'
                            args = @('-y', '@modelcontextprotocol/server-github')
                            env = @{
                                GITHUB_TOKEN = '{{activeProviders.github.token}}'
                            }
                        }
                    }
                }
            }
        }

        (Get-BootstrapResolvedSecretsTargets -SecretsData $withGithub).continue.mcpServers.github.enabled | Should Be $true
        (Get-BootstrapResolvedSecretsTargets -SecretsData $withoutGithub).continue.mcpServers.github.enabled | Should Be $false
    }

    It 'writes Continue local env and config files with MCP secret references' {
        $env:USERPROFILE = Join-Path $script:TestDataRoot 'User'
        $resolvedTargets = @{
            continue = @{
                env = @{
                    OPENROUTER_API_KEY = 'sk-or-v1-test'
                    OPENROUTER_BASE_URL = 'https://openrouter.ai/api/v1'
                }
                mcpServers = @{
                    github = @{
                        enabled = $true
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = @{
                            GITHUB_TOKEN = 'ghp-test'
                        }
                    }
                }
            }
        }

        $summary = Ensure-BootstrapContinueExtensionConfig -ResolvedTargets $resolvedTargets

        $summary.configured | Should Be $true
        (Test-Path $summary.envPath) | Should Be $true
        (Test-Path $summary.configPath) | Should Be $true
        (Get-Content -Raw -Path $summary.envPath) | Should Match 'OPENROUTER_API_KEY='
        (Get-Content -Raw -Path $summary.configPath) | Should Match 'mcpServers:'
        (Get-Content -Raw -Path $summary.configPath) | Should Match '\$\{\{\s*secrets\.GITHUB_TOKEN\s*\}\}'
    }

    It 'resolves VS Code and VS Code Insiders CLI paths from local installations' {
        $env:LOCALAPPDATA = Join-Path $script:TestDataRoot 'Local'
        $stableBin = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin'
        $insidersBin = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders\bin'
        New-Item -Path $stableBin -ItemType Directory -Force | Out-Null
        New-Item -Path $insidersBin -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $stableBin 'code.cmd') -ItemType File -Force | Out-Null
        New-Item -Path (Join-Path $insidersBin 'code-insiders.cmd') -ItemType File -Force | Out-Null

        (Resolve-BootstrapVsCodeCliPath -Channel 'stable') | Should Be (Join-Path $stableBin 'code.cmd')
        (Resolve-BootstrapVsCodeCliPath -Channel 'insiders') | Should Be (Join-Path $insidersBin 'code-insiders.cmd')
    }

    It 'forwards CLI arguments when capturing command output' {
        $result = Invoke-BootstrapCommandCapture -Exe 'cmd.exe' -Args @('/c', 'echo', 'bootstrap-cli-ok')

        $result.ExitCode | Should Be 0
        ((@($result.Output) -join ' ') -match 'bootstrap-cli-ok') | Should Be $true
    }

    It 'falls back to pre-release installs when the marketplace reports no release version' {
        $script:CapturedInstallArgs = @()
        $originalInvoker = ${function:Invoke-BootstrapCommandCapture}
        Set-Item -Path function:Invoke-BootstrapCommandCapture -Value {
            param([string]$Exe, [string[]]$Args)

            $commandArgs = [string[]]@($PSBoundParameters['Args'])
            $script:CapturedInstallArgs += ,$commandArgs
            if ($commandArgs -contains '--pre-release') {
                return [ordered]@{
                    ExitCode = 0
                    Output = @('Installed')
                }
            }

            return [ordered]@{
                ExitCode = 1
                Output = @("Can't install release version of 'Cline (Nightly)' extension because it has no release version.")
            }
        }

        try {
            $result = Ensure-BootstrapVsCodeExtensionInstalled -CliPath 'code.cmd' -ExtensionDefinition @{
                id = 'saoudrizwan.cline-nightly'
                displayName = 'Cline (Nightly)'
            } -InstalledExtensions @('placeholder.extension') -EditorLabel 'VS Code'
        } finally {
            Set-Item -Path function:Invoke-BootstrapCommandCapture -Value $originalInvoker
        }

        $result.installed | Should Be $true
        $result.changed | Should Be $true
        $script:CapturedInstallArgs.Count | Should Be 2
        ($script:CapturedInstallArgs[0] -contains '--pre-release') | Should Be $false
        ($script:CapturedInstallArgs[1] -contains '--pre-release') | Should Be $true
    }

    It 'uses pre-release installs immediately for extensions marked as nightly-only' {
        $script:CapturedInstallArgs = @()
        $originalInvoker = ${function:Invoke-BootstrapCommandCapture}
        Set-Item -Path function:Invoke-BootstrapCommandCapture -Value {
            param([string]$Exe, [string[]]$Args)

            $commandArgs = [string[]]@($PSBoundParameters['Args'])
            $script:CapturedInstallArgs += ,$commandArgs
            return [ordered]@{
                ExitCode = 0
                Output = @('Installed')
            }
        }

        try {
            $result = Ensure-BootstrapVsCodeExtensionInstalled -CliPath 'code.cmd' -ExtensionDefinition @{
                id = 'digitarald.agent-memory'
                displayName = 'Agent Memory'
                preferPreRelease = $true
            } -InstalledExtensions @('placeholder.extension') -EditorLabel 'VS Code'
        } finally {
            Set-Item -Path function:Invoke-BootstrapCommandCapture -Value $originalInvoker
        }

        $result.installed | Should Be $true
        $result.changed | Should Be $true
        $script:CapturedInstallArgs.Count | Should Be 1
        ($script:CapturedInstallArgs[0] -contains '--pre-release') | Should Be $true
    }
}
