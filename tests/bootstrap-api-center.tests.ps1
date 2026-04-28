Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath
Reset-BootstrapFileCmdlets

function New-ApiCenterTestRoot {
    return (Join-Path $env:TEMP ("bootstrap_api_center_{0}" -f ([Guid]::NewGuid().ToString('N'))))
}

function Reset-ApiCenterTestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $env:BOOTSTRAP_DATA_ROOT = $Path
    Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
}

function Remove-ApiCenterTestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-ApiCenterSecretsFixture {
    return @{
        metadata = @{ version = 2 }
        providers = @{
            openai = @{
                defaults = @{ baseUrl = 'https://api.openai.com/v1'; organizationId = 'org-test' }
                activeCredential = 'openai-main-01'
                rotationOrder = @('openai-main-01', 'openai-backup-01')
                credentials = @{
                    'openai-main-01' = @{
                        displayName = 'Main'
                        secret = 'sk-proj-openai-secret'
                        secretKind = 'apiKey'
                        validation = @{ state = 'passed'; checkedAt = '2026-04-21T00:00:00Z'; message = 'ok' }
                    }
                    'openai-backup-01' = @{
                        displayName = 'Backup'
                        secret = 'sk-proj-openai-backup-secret'
                        secretKind = 'apiKey'
                        validation = @{ state = 'unknown'; checkedAt = ''; message = '' }
                    }
                }
            }
            openrouter = @{
                defaults = @{ baseUrl = 'https://openrouter.ai/api/v1' }
                activeCredential = 'openrouter-main-01'
                rotationOrder = @('openrouter-main-01')
                credentials = @{
                    'openrouter-main-01' = @{
                        displayName = 'Main'
                        secret = 'sk-or-v1-openroutersecret'
                        secretKind = 'apiKey'
                        validation = @{ state = 'passed'; checkedAt = '2026-04-21T00:01:00Z'; message = 'ok' }
                    }
                }
            }
            deepseek = @{
                defaults = @{ baseUrl = 'https://api.deepseek.com' }
                activeCredential = 'deepseek-main-01'
                rotationOrder = @('deepseek-main-01')
                credentials = @{
                    'deepseek-main-01' = @{
                        displayName = 'Main'
                        secret = 'sk-deepseek-secret'
                        secretKind = 'apiKey'
                        validation = @{ state = 'failed'; checkedAt = '2026-04-21T00:02:00Z'; message = '401' }
                    }
                }
            }
        }
        targets = (Get-BootstrapSecretsTemplate).targets
    }
}

Describe 'Bootstrap API Center and app capability inventory' {
    BeforeEach {
        $script:TestDataRoot = New-ApiCenterTestRoot
        Reset-ApiCenterTestRoot -Path $script:TestDataRoot
        $script:OriginalUserProfile = $env:USERPROFILE
        $script:OriginalAppData = $env:APPDATA
        $script:OriginalLocalAppData = $env:LOCALAPPDATA
        $env:USERPROFILE = Join-Path $script:TestDataRoot 'User'
        $env:APPDATA = Join-Path $script:TestDataRoot 'AppData\Roaming'
        $env:LOCALAPPDATA = Join-Path $script:TestDataRoot 'AppData\Local'
        New-Item -Path $env:USERPROFILE -ItemType Directory -Force | Out-Null
        New-Item -Path $env:APPDATA -ItemType Directory -Force | Out-Null
        New-Item -Path $env:LOCALAPPDATA -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        $env:USERPROFILE = $script:OriginalUserProfile
        $env:APPDATA = $script:OriginalAppData
        $env:LOCALAPPDATA = $script:OriginalLocalAppData
        Remove-ApiCenterTestRoot -Path $script:TestDataRoot
        Remove-Variable -Scope Script -Name TestDataRoot -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalUserProfile -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalAppData -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalLocalAppData -ErrorAction SilentlyContinue
    }

    It 'exposes provider metadata and app capabilities in the UI contract' {
        $contract = Get-BootstrapUiContract

        $contract.apiCatalog.openai.displayName | Should Be 'OpenAI'
        $contract.apiCatalog.openrouter.signupUrl | Should Match '^https://'
        (@($contract.apiCatalog.openai.requiredFields) -contains 'apiKey') | Should Be $true
        $contract.appCatalog.openCode.authByFile | Should Be $true
        $contract.appCatalog.comet.manualOnly | Should Be $true
        ($contract | ConvertTo-Json -Depth 12) | Should Not Match 'sk-proj-'
        ($contract | ConvertTo-Json -Depth 12) | Should Not Match 'sk-or-v1-'
    }

    It 'builds a secret-safe API inventory with app usage states' {
        $inventory = Get-BootstrapApiInventory -SecretsData (New-ApiCenterSecretsFixture)
        $openai = $inventory.providers | Where-Object { $_.id -eq 'openai' } | Select-Object -First 1
        $deepseek = $inventory.providers | Where-Object { $_.id -eq 'deepseek' } | Select-Object -First 1

        $openai.totalCredentials | Should Be 2
        $openai.activeCredentialId | Should Be 'openai-main-01'
        $openai.activeValidationState | Should Be 'passed'
        $openai.credentials[0].secretPreview | Should Match '^sk-\*\*\*'
        ($openai | ConvertTo-Json -Depth 8) | Should Not Match 'sk-proj-openai-secret'
        (@($openai.autoAppliedApps) -contains 'OpenCode') | Should Be $true
        (@($openai.manualOnlyApps) -contains 'Comet') | Should Be $true
        $deepseek.activeValidationState | Should Be 'failed'
        (@($inventory.availableToCreate | ForEach-Object { $_.id }) -contains 'anthropic') | Should Be $true
    }

    It 'builds full researched key catalog rows with possession and configured counts' {
        $rows = Get-BootstrapApiCatalogRows -SecretsData (New-ApiCenterSecretsFixture)
        $ids = @($rows | ForEach-Object { [string]$_.id })
        $openai = $rows | Where-Object { $_.id -eq 'openai' } | Select-Object -First 1
        $mistral = $rows | Where-Object { $_.id -eq 'mistral' } | Select-Object -First 1

        $openai.hasCredential | Should Be '[x]'
        $openai.quantity | Should Be 2
        $openai.configured | Should Be 1
        $openai.description | Should Match 'IA'
        $openai.fields | Should Match 'apiKey'
        $openai.signup | Should Match '^https://'
        $openai.docs | Should Match '^https://'

        $mistral.hasCredential | Should Be '[ ]'
        $mistral.quantity | Should Be 0
        $mistral.description | Should Match 'IA'
        $mistral.fields | Should Match 'apiKey'

        foreach ($expected in @('groq','cohere','perplexity','tavily','bravesearch','vercel','netlify','stripe','resend','neon','upstash','clerk','notion','linear')) {
            ($ids -contains $expected) | Should Be $true
        }
    }

    It 'merges validated active providers into OpenCode auth without removing unrelated credentials' {
        $authPath = Get-BootstrapOpenCodeAuthPath
        Write-BootstrapJsonFile -Path $authPath -Value @{
            opencode = @{ type = 'api'; key = 'existing-opencode-key' }
            unrelated = @{ type = 'api'; key = 'keep-me' }
        }

        $summary = Ensure-BootstrapOpenCodeProviderAuth -SecretsData (New-ApiCenterSecretsFixture)
        $saved = Read-BootstrapJsonFile -Path $authPath

        $summary.updated | Should Be $true
        $saved.opencode.key | Should Be 'existing-opencode-key'
        $saved.unrelated.key | Should Be 'keep-me'
        $saved.openai.type | Should Be 'api'
        $saved.openai.key | Should Be 'sk-proj-openai-secret'
        $saved.openrouter.key | Should Be 'sk-or-v1-openroutersecret'
        $saved.Contains('deepseek') | Should Be $false
    }

    It 'merges only required OpenCode provider metadata and preserves model selection' {
        $fixture = New-ApiCenterSecretsFixture
        $fixture.providers.openai.defaults.baseUrl = 'https://proxy.example.test/v1'
        $configPath = Get-BootstrapOpenCodeConfigPath
        Write-BootstrapJsonFile -Path $configPath -Value @{
            '$schema' = 'https://opencode.ai/config.json'
            model = 'openai/gpt-5.2'
            small_model = 'openai/gpt-5.2-mini'
            theme = 'tokyo-night'
            provider = @{
                custom = @{ name = 'Custom'; models = @{ existing = @{} } }
            }
        }

        $summary = Ensure-BootstrapOpenCodeProviderConfig -SecretsData $fixture
        $saved = Read-BootstrapJsonFile -Path $configPath

        $summary.updated | Should Be $true
        $saved.model | Should Be 'openai/gpt-5.2'
        $saved.small_model | Should Be 'openai/gpt-5.2-mini'
        $saved.theme | Should Be 'tokyo-night'
        $saved.provider.custom.name | Should Be 'Custom'
        $saved.provider.openai.options.baseURL | Should Be 'https://proxy.example.test/v1'
        $saved.provider.Contains('openrouter') | Should Be $false
        $saved.provider.Contains('deepseek') | Should Be $false
    }

    It 'reports Comet as manual-only with provider readiness and links' {
        $guide = Get-BootstrapCometGuide -SecretsData (New-ApiCenterSecretsFixture)

        $guide.mode | Should Be 'manualOnly'
        $guide.installed | Should Be $false
        (@($guide.readyProviders | ForEach-Object { $_.id }) -contains 'openai') | Should Be $true
        (@($guide.readyProviders | ForEach-Object { $_.id }) -contains 'openrouter') | Should Be $true
        (@($guide.missingProviders | ForEach-Object { $_.id }) -contains 'anthropic') | Should Be $true
        ($guide | ConvertTo-Json -Depth 8) | Should Not Match 'sk-proj-openai-secret'
    }
}
