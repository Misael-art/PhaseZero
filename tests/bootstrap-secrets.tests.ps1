$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath
Reset-BootstrapFileCmdlets

function New-TestDataRoot {
    return (Join-Path $env:TEMP ("bootstrap_secrets_{0}" -f ([Guid]::NewGuid().ToString('N'))))
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

function Invoke-BootstrapProcess {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string[]]$CommandArgs
    )

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $CommandArgs
    $quotedArgs = foreach ($arg in $allArgs) {
        if ($arg -match '[\s"]') {
            '"' + ($arg -replace '"', '\"') + '"'
        } else {
            $arg
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellExe
    $startInfo.Arguments = [string]::Join(' ', $quotedArgs)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['BOOTSTRAP_DATA_ROOT'] = $DataRoot

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw "Failed to start bootstrap process for args: $($CommandArgs -join ' ')"
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit(120000)) {
        try { $process.Kill() } catch { }
        throw "Bootstrap invocation timed out after 120000ms for args: $($CommandArgs -join ' ')"
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = @($stdoutTask.Result, $stderrTask.Result) -join [Environment]::NewLine
    }
}

Describe 'Bootstrap secrets manifest v2' {
    BeforeEach {
        $script:TestDataRoot = New-TestDataRoot
        Reset-TestDataRoot -Path $script:TestDataRoot
    }

    AfterEach {
        Remove-TestDataRoot -Path $script:TestDataRoot
        Remove-Variable -Scope Script -Name TestDataRoot -ErrorAction SilentlyContinue
    }

    It 'migrates a v1 manifest to v2 without losing targets' {
        $path = Join-Path $script:TestDataRoot 'bootstrap-secrets.json'
        Write-BootstrapJsonFile -Path $path -Value @{
            '$schema' = 'https://bootstrap.local/schemas/bootstrap-secrets.schema.json'
            metadata = @{
                version = 1
            }
            providers = @{
                openai = @{
                    apiKey = 'sk-proj-test-openai'
                    baseUrl = 'https://api.openai.com/v1'
                }
            }
            targets = @{
                userEnv = @{
                    OPENAI_API_KEY = '{{activeProviders.openai.apiKey}}'
                }
            }
        }

        $bundle = Get-BootstrapSecretsData

        $bundle.Data.metadata.version | Should Be 2
        $bundle.Data.providers.openai.activeCredential | Should Be 'openai-default-01'
        $bundle.Data.providers.openai.rotationOrder | Should Be @('openai-default-01')
        $bundle.Data.providers.openai.credentials['openai-default-01'].secret | Should Be 'sk-proj-test-openai'
        $bundle.Data.targets.userEnv.OPENAI_API_KEY | Should Be '{{activeProviders.openai.apiKey}}'
    }

    It 'imports multiple keys with stable ids, de-duplicates repeated secrets, and seeds rotation order' {
        $text = @'
### OpenRouter
| Serviço | Chave | Observação |
|---------|-------|------------|
| Gmail | `sk-or-v1-11111111111111111111111111111111` | principal |
| USA | `sk-or-v1-22222222222222222222222222222222` | reserva |
| Duplicada | `sk-or-v1-11111111111111111111111111111111` | repetida |
'@

        $imported = Import-BootstrapSecretsText -Text $text -SecretsData (Get-BootstrapSecretsTemplate)
        $provider = $imported.providers.openrouter

        @($provider.credentials.Keys).Count | Should Be 2
        $provider.rotationOrder | Should Be @('openrouter-gmail-01', 'openrouter-usa-01')
        $provider.credentials['openrouter-gmail-01'].displayName | Should Be 'Gmail'
        $provider.credentials['openrouter-usa-01'].displayName | Should Be 'USA'
    }

    It 'resolves the ai profile with vscode-insiders before bootstrap-secrets' {
        $resolution = Resolve-BootstrapComponents -SelectedProfiles @('ai') -SelectedComponents @() -ExcludedComponents @()
        $vscodeIndex = [array]::IndexOf(@($resolution.ResolvedComponents), 'vscode-insiders')
        $secretsIndex = [array]::IndexOf(@($resolution.ResolvedComponents), 'bootstrap-secrets')

        $vscodeIndex | Should BeGreaterThan -1
        $secretsIndex | Should BeGreaterThan -1
        $vscodeIndex | Should BeLessThan $secretsIndex
    }

    It 'lists credentials safely without printing the raw secret' {
        $path = Join-Path $script:TestDataRoot 'bootstrap-secrets.json'
        Write-BootstrapJsonFile -Path $path -Value @{
            '$schema' = 'https://bootstrap.local/schemas/bootstrap-secrets.schema.json'
            metadata = @{
                version = 2
            }
            providers = @{
                openrouter = @{
                    defaults = @{
                        baseUrl = 'https://openrouter.ai/api/v1'
                    }
                    activeCredential = 'openrouter-main-01'
                    rotationOrder = @('openrouter-main-01')
                    credentials = @{
                        'openrouter-main-01' = @{
                            displayName = 'Main'
                            secret = 'sk-or-v1-super-secret-value'
                            secretKind = 'apiKey'
                            validation = @{
                                state = 'passed'
                                checkedAt = '2026-04-18T00:00:00Z'
                                message = 'ok'
                            }
                        }
                    }
                }
            }
            targets = @{
                userEnv = @{
                    OPENROUTER_API_KEY = '{{activeProviders.openrouter.apiKey}}'
                }
            }
        }

        $result = Invoke-BootstrapProcess -DataRoot $script:TestDataRoot -CommandArgs @('-SecretsList')

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'openrouter'
        $result.Output | Should Match 'openrouter-main-01'
        $result.Output | Should Match 'passed'
        $result.Output | Should Not Match 'sk-or-v1-super-secret-value'
    }

    It 'resolves active provider placeholders into non-empty target values when validation passed' {
        $data = @{
            metadata = @{
                version = 2
            }
            providers = @{
                openrouter = @{
                    defaults = @{
                        baseUrl = 'https://openrouter.ai/api/v1'
                    }
                    activeCredential = 'openrouter-main-01'
                    rotationOrder = @('openrouter-main-01')
                    credentials = @{
                        'openrouter-main-01' = @{
                            displayName = 'Main'
                            secret = 'sk-or-v1-placeholder-check'
                            secretKind = 'apiKey'
                            validation = @{
                                state = 'passed'
                                checkedAt = '2026-04-18T00:00:00Z'
                                message = 'ok'
                            }
                        }
                    }
                }
            }
            targets = @{
                userEnv = @{
                    OPENROUTER_API_KEY = '{{activeProviders.openrouter.apiKey}}'
                    OPENROUTER_BASE_URL = '{{activeProviders.openrouter.baseUrl}}'
                }
            }
        }

        $resolved = Get-BootstrapResolvedSecretsTargets -SecretsData $data

        $resolved.userEnv.OPENROUTER_API_KEY | Should Be 'sk-or-v1-placeholder-check'
        $resolved.userEnv.OPENROUTER_BASE_URL | Should Be 'https://openrouter.ai/api/v1'
    }

    It 'keeps managed MCP servers opt-in when resolving ordinary secret targets' {
        $resolved = Get-BootstrapResolvedSecretsTargets -SecretsData (Get-BootstrapSecretsTemplate)

        $resolved.continue.mcpServers.Contains('markitdown') | Should Be $false
        $resolved.vsCode.mcpServers.Contains('notion') | Should Be $false
    }

    It 'enables the VS Code GitHub MCP only when there is an active validated github credential' {
        $withGithub = @{
            metadata = @{
                version = 2
            }
            providers = @{
                github = @{
                    defaults = @{}
                    activeCredential = 'github-main-01'
                    rotationOrder = @('github-main-01')
                    credentials = @{
                        'github-main-01' = @{
                            displayName = 'Main'
                            secret = 'ghp-valid-token'
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
                vsCode = @{
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
            metadata = @{
                version = 2
            }
            providers = @{
                github = @{
                    defaults = @{}
                    activeCredential = 'github-main-01'
                    rotationOrder = @('github-main-01')
                    credentials = @{
                        'github-main-01' = @{
                            displayName = 'Main'
                            secret = 'ghp-invalid-token'
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
                vsCode = @{
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

        (Get-BootstrapResolvedSecretsTargets -SecretsData $withGithub).vsCode.mcpServers.github.enabled | Should Be $true
        (Get-BootstrapResolvedSecretsTargets -SecretsData $withoutGithub).vsCode.mcpServers.github.enabled | Should Be $false
    }

    It 'prefers the Agents Insiders MCP path when insiders is installed even if stable Code folders already exist' {
        $originalAppData = $env:APPDATA
        $originalLocalAppData = $env:LOCALAPPDATA
        $originalUserProfile = $env:USERPROFILE

        $tempRoot = Join-Path $script:TestDataRoot 'vscode-paths'
        $env:APPDATA = Join-Path $tempRoot 'Roaming'
        $env:LOCALAPPDATA = Join-Path $tempRoot 'Local'
        $env:USERPROFILE = Join-Path $tempRoot 'User'

        $stableParent = Join-Path $env:APPDATA 'Code\User'
        $insidersExeParent = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders'
        $expectedPath = Join-Path $env:APPDATA 'Agents - Insiders\User\mcp.json'

        New-Item -Path $stableParent -ItemType Directory -Force | Out-Null
        New-Item -Path $insidersExeParent -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $insidersExeParent 'Code - Insiders.exe') -ItemType File -Force | Out-Null

        try {
            Get-BootstrapVsCodeMcpConfigPath | Should Be $expectedPath
        } finally {
            $env:APPDATA = $originalAppData
            $env:LOCALAPPDATA = $originalLocalAppData
            $env:USERPROFILE = $originalUserProfile
        }
    }

    It 'redacts sensitive env values in logs without hiding safe values' {
        (Get-BootstrapEnvValueForLog -Name 'OPENAI_API_KEY' -Value 'sk-secret') | Should Be '[redacted]'
        (Get-BootstrapEnvValueForLog -Name 'OPENAI_BASE_URL' -Value 'https://api.openai.com/v1') | Should Be 'https://api.openai.com/v1'
    }

    It 'prefers a populated project secrets manifest over an empty user manifest' {
        $originalBootstrapDataRoot = $env:BOOTSTRAP_DATA_ROOT
        $originalUserProfile = $env:USERPROFILE
        $originalLocalAppData = $env:LOCALAPPDATA
        $originalTemp = $env:TEMP
        $projectRoot = Join-Path $script:TestDataRoot 'Project'

        try {
            $env:BOOTSTRAP_DATA_ROOT = ''
            $env:USERPROFILE = Join-Path $script:TestDataRoot 'User'
            $env:LOCALAPPDATA = Join-Path $script:TestDataRoot 'LocalAppData'
            $env:TEMP = Join-Path $script:TestDataRoot 'Temp'
            New-Item -Path $env:USERPROFILE -ItemType Directory -Force | Out-Null
            New-Item -Path $env:LOCALAPPDATA -ItemType Directory -Force | Out-Null
            New-Item -Path $env:TEMP -ItemType Directory -Force | Out-Null
            New-Item -Path $projectRoot -ItemType Directory -Force | Out-Null

            $userSecretsPath = Join-Path (Join-Path $env:USERPROFILE '.bootstrap-tools') 'bootstrap-secrets.json'
            Write-BootstrapJsonFile -Path $userSecretsPath -Value (Get-BootstrapSecretsTemplate)

            $projectSecretsPath = Join-Path (Join-Path $projectRoot '.bootstrap-tools') 'bootstrap-secrets.json'
            Write-BootstrapJsonFile -Path $projectSecretsPath -Value @{
                metadata = @{ version = 2 }
                providers = @{
                    openrouter = @{
                        defaults = @{ baseUrl = 'https://openrouter.ai/api/v1' }
                        activeCredential = 'openrouter-main-01'
                        rotationOrder = @('openrouter-main-01')
                        credentials = @{
                            'openrouter-main-01' = @{
                                displayName = 'Main'
                                secret = 'sk-or-v1-project-secret'
                                secretKind = 'apiKey'
                                validation = @{ state = 'passed'; checkedAt = '2026-04-21T00:00:00Z'; message = 'ok' }
                            }
                        }
                    }
                }
                targets = @{}
            }

            Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
            Push-Location $projectRoot
            try {
                Get-BootstrapDataRoot | Should Be (Join-Path $projectRoot '.bootstrap-tools')
            } finally {
                Pop-Location
            }
        } finally {
            $env:BOOTSTRAP_DATA_ROOT = $originalBootstrapDataRoot
            $env:USERPROFILE = $originalUserProfile
            $env:LOCALAPPDATA = $originalLocalAppData
            $env:TEMP = $originalTemp
            Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
            Reset-TestDataRoot -Path $script:TestDataRoot
        }
    }

    It 'normalizes Claude Code permission arrays even when settings were loaded as hashtables' {
        $originalUserProfile = $env:USERPROFILE
        $env:USERPROFILE = Join-Path $script:TestDataRoot 'User'
        $settingsDir = Join-Path $env:USERPROFILE '.claude'
        $settingsPath = Join-Path $settingsDir 'settings.json'
        New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null
        Set-Content -Path $settingsPath -Encoding utf8 -Value @'
{
  "permissions": {
    "allow": "Bash",
    "deny": "Read(.env)"
  }
}
'@

        try {
            Ensure-ClaudeCodeDefaults
            $saved = Read-BootstrapJsonFile -Path $settingsPath
        } finally {
            $env:USERPROFILE = $originalUserProfile
        }

        @($saved.permissions.allow) | Should Be @('Bash')
        (@($saved.permissions.deny) -contains 'Read(**/secrets/**)') | Should Be $true
    }

    It 'returns stable grub entry fields when no Linux loader is detected' {
        Mock Test-IsAdmin { return $true }
        Mock Get-BootstrapEfiEntries { return @() }
        Mock Get-BootstrapLinuxPartitions { return @() }

        $grub = Get-BootstrapGrubPresence

        $hasEntryId = if ($grub -is [hashtable]) { $grub.ContainsKey('EntryId') } else { @($grub.PSObject.Properties.Name) -contains 'EntryId' }
        $hasEntryDesc = if ($grub -is [hashtable]) { $grub.ContainsKey('EntryDesc') } else { @($grub.PSObject.Properties.Name) -contains 'EntryDesc' }

        $hasEntryId | Should Be $true
        $hasEntryDesc | Should Be $true
        $grub.EntryId | Should Be ''
        $grub.EntryDesc | Should Be ''
    }

    It 'builds dual boot info even when grub optional fields are absent' {
        Mock Test-IsAdmin { return $false }
        Mock Get-BootstrapFastStartupStatus {
            return @{ Enabled = $false; Safe = $true; Value = 0; RegistryPath = '' }
        }
        Mock Get-BootstrapBitLockerStatus {
            return @{ CEnabled = $false; StatusText = 'Off'; ProtectionStatus = '' }
        }
        Mock Get-BootstrapLinuxPartitions { return @() }
        Mock Get-BootstrapEfiEntries { return @() }
        Mock Get-BootstrapGrubPresence {
            return [pscustomobject]@{ Detected = $false; Path = ''; Confidence = 'none' }
        }

        { Get-BootstrapDualBootInfo } | Should Not Throw
    }

    It 'does not apply an invalid active credential and persists the failed validation state' {
        $path = Join-Path $script:TestDataRoot 'bootstrap-secrets.json'
        Write-BootstrapJsonFile -Path $path -Value @{
            '$schema' = 'https://bootstrap.local/schemas/bootstrap-secrets.schema.json'
            metadata = @{
                version = 2
            }
            providers = @{
                openai = @{
                    defaults = @{
                        baseUrl = 'https://api.openai.com/v1'
                    }
                    activeCredential = 'openai-main-01'
                    rotationOrder = @('openai-main-01')
                    credentials = @{
                        'openai-main-01' = @{
                            displayName = 'Main'
                            secret = 'sk-proj-invalid'
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
            targets = @{
                userEnv = @{
                    OPENAI_API_KEY = '{{activeProviders.openai.apiKey}}'
                }
            }
        }

        Mock Test-BootstrapSecretsProviderCredential {
            return @{
                state = 'failed'
                checkedAt = '2026-04-18T01:00:00Z'
                message = '401 unauthorized'
            }
        }

        Mock Set-UserEnvVar { }

        $state = New-BootstrapState -ResolvedWorkspaceRoot $repoRoot -ResolvedCloneBaseDir $repoRoot -RequestedSteamDeckVersion 'Auto' -ResolvedSteamDeckVersion '' -HostHealthMode 'off' -UsesSteamDeckFlow:$false -IsDryRun:$false
        Ensure-BootstrapSecrets -State $state

        Assert-MockCalled Set-UserEnvVar -Times 0 -Scope It -ParameterFilter { $Name -eq 'OPENAI_API_KEY' }
        $saved = Read-BootstrapJsonFile -Path $path
        $saved.providers.openai.credentials['openai-main-01'].validation.state | Should Be 'failed'
    }

    It 'rotates a provider to the next valid credential only' {
        $data = @{
            metadata = @{
                version = 2
            }
            providers = @{
                openai = @{
                    defaults = @{
                        baseUrl = 'https://api.openai.com/v1'
                    }
                    activeCredential = 'openai-primary-01'
                    rotationOrder = @('openai-primary-01', 'openai-backup-01')
                    credentials = @{
                        'openai-primary-01' = @{
                            displayName = 'Primary'
                            secret = 'sk-proj-invalid'
                            secretKind = 'apiKey'
                            validation = @{
                                state = 'unknown'
                                checkedAt = ''
                                message = ''
                            }
                        }
                        'openai-backup-01' = @{
                            displayName = 'Backup'
                            secret = 'sk-proj-valid'
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
            targets = @{}
        }

        Mock Test-BootstrapSecretsProviderCredential {
            param(
                [string]$ProviderName,
                [hashtable]$ProviderDefinition,
                [string]$CredentialId,
                [hashtable]$Credential
            )

            if ($CredentialId -eq 'openai-primary-01') {
                return @{
                    state = 'failed'
                    checkedAt = '2026-04-18T02:00:00Z'
                    message = 'quota exceeded'
                }
            }

            return @{
                state = 'passed'
                checkedAt = '2026-04-18T02:01:00Z'
                message = 'ok'
            }
        }

        $rotated = Move-BootstrapSecretsToNextCredential -SecretsData $data -ProviderName 'openai'

        $rotated.providers.openai.activeCredential | Should Be 'openai-backup-01'
        $rotated.providers.openai.credentials['openai-primary-01'].validation.state | Should Be 'failed'
        $rotated.providers.openai.credentials['openai-backup-01'].validation.state | Should Be 'passed'
    }
}
