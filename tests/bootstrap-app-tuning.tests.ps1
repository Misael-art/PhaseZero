$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

function New-AppTuningInventoryFixture {
    param([string[]]$InstalledApps = @())

    $apps = @{}
    foreach ($name in @($InstalledApps)) {
        $apps[$name.ToLowerInvariant()] = $true
    }
    return [ordered]@{
        apps = $apps
        paths = @{}
        generatedAt = '2026-04-22T00:00:00Z'
    }
}

Describe 'Bootstrap AppTuning catalog and selection' {
    It 'exposes categories and item metadata required by the UI' {
        $catalog = Get-BootstrapAppTuningCatalog
        $categoryIds = @($catalog.categories | ForEach-Object { [string]$_.id })
        $steamItem = $catalog.items | Where-Object { $_.id -eq 'steam-big-picture-session' } | Select-Object -First 1

        foreach ($expected in @('gaming-console','steamdeck-control','dev-ai','local-ai-containers','browser-startup','connectivity','capture-creator','storage-backup','windows-qol')) {
            ($categoryIds -contains $expected) | Should Be $true
        }

        $steamItem.category | Should Be 'gaming-console'
        $steamItem.defaultMode | Should Be 'recommended'
        (@($steamItem.actions) -contains 'session') | Should Be $true
        (@($steamItem.rollback) -contains 'manual') | Should Be $true
    }

    It 'defaults legacy to off and modern profiles to recommended' {
        $legacySelection = New-BootstrapSelectionObject -SelectedProfiles @('legacy')
        $legacyResolution = Resolve-BootstrapComponents -SelectedProfiles $legacySelection.Profiles
        $modernSelection = New-BootstrapSelectionObject -SelectedProfiles @('recommended')
        $modernResolution = Resolve-BootstrapComponents -SelectedProfiles $modernSelection.Profiles

        (Get-BootstrapDefaultAppTuningMode -Selection $legacySelection -Resolution $legacyResolution) | Should Be 'off'
        (Get-BootstrapDefaultAppTuningMode -Selection $modernSelection -Resolution $modernResolution) | Should Be 'recommended'
    }

    It 'selects safe category items and preserves explicit exclusions' {
        $selection = New-BootstrapSelectionObject -SelectedProfiles @('steamdeck-recommended')
        $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles
        $plan = Resolve-BootstrapAppTuningSelection -Mode 'custom' -Categories @('gaming-console') -Items @() -ExcludedItems @('rtss-frame-presets') -Selection $selection -Resolution $resolution -InstalledInventory (New-AppTuningInventoryFixture -InstalledApps @('steam'))
        $ids = @($plan.items | ForEach-Object { [string]$_.id })

        ($ids -contains 'steam-big-picture-session') | Should Be $true
        ($ids -contains 'playnite-fullscreen') | Should Be $true
        ($ids -contains 'rtss-frame-presets') | Should Be $false
        ($ids -contains 'specialk-global-injection') | Should Be $false
    }

    It 'marks absent apps as skipped without failing selection' {
        $selection = New-BootstrapSelectionObject -SelectedProfiles @('recommended')
        $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles
        $plan = Resolve-BootstrapAppTuningSelection -Mode 'custom' -Items @('steam-big-picture-session') -Selection $selection -Resolution $resolution -InstalledInventory (New-AppTuningInventoryFixture)
        $item = $plan.items | Where-Object { $_.id -eq 'steam-big-picture-session' } | Select-Object -First 1

        $item.installed | Should Be $false
        $item.status | Should Be 'skipped'
    }

    It 'surfaces admin reasons for selected tuning items that require elevation' {
        $selection = New-BootstrapSelectionObject -SelectedProfiles @('steamdeck-recommended')
        $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles
        $plan = Resolve-BootstrapAppTuningSelection -Mode 'custom' -Items @('displayfusion-layouts') -Selection $selection -Resolution $resolution -InstalledInventory (New-AppTuningInventoryFixture -InstalledApps @('displayfusion'))
        $reasons = Get-BootstrapAdminReasons -Resolution $resolution -ResolvedHostHealthMode 'off' -UsesSteamDeckFlow:$true -AppTuningPlan $plan

        (@($reasons) -join "`n") | Should Match 'AppTuning'
        (@($reasons) -join "`n") | Should Match 'displayfusion-layouts'
    }

    It 'builds app status rows for install configure and update management' {
        $selection = New-BootstrapSelectionObject -SelectedProfiles @('steamdeck-recommended')
        $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles
        $plan = Resolve-BootstrapAppTuningSelection -Mode 'custom' -Items @('steam-big-picture-session') -Selection $selection -Resolution $resolution -InstalledInventory (New-AppTuningInventoryFixture -InstalledApps @('steam'))

        $rows = Get-BootstrapAppTuningStatusRows -Plan $plan -InstalledInventory (New-AppTuningInventoryFixture -InstalledApps @('steam'))
        $steamRow = $rows | Where-Object { $_.id -eq 'steam-big-picture-session' } | Select-Object -First 1

        $steamRow.installedState | Should Be 'installed'
        $steamRow.configuredState | Should Be 'planned'
        $steamRow.updatedState | Should Be 'check'
        (@($steamRow.installComponents) -contains 'steam') | Should Be $true
        $steamRow.canInstall | Should Be $true
        $steamRow.canConfigure | Should Be $true
        $steamRow.canUpdate | Should Be $true
    }

    It 'resolves OpenAI-compatible provider with fallback diagnostics' {
        $fixture = @{
            metadata = @{ version = 2 }
            providers = @{
                mimo = @{
                    defaults = @{ baseUrl = '' }
                    activeCredential = 'mimo-main-01'
                    rotationOrder = @('mimo-main-01')
                    credentials = @{
                        'mimo-main-01' = @{
                            displayName = 'Main'
                            secret = 'test-mimo-key'
                            secretKind = 'apiKey'
                            validation = @{ state = 'passed'; checkedAt = '2026-04-29T00:00:00Z'; message = 'ok' }
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
                            secret = 'test-openrouter-key'
                            secretKind = 'apiKey'
                            validation = @{ state = 'passed'; checkedAt = '2026-04-29T00:00:00Z'; message = 'ok' }
                        }
                    }
                }
            }
            targets = (Get-BootstrapSecretsTemplate).targets
        }

        $candidate = Resolve-BootstrapOpenAiCompatibleProviderCandidate -PreferredProviders @('mimo', 'openrouter') -SecretsData $fixture

        $candidate.status | Should Be 'selected'
        $candidate.provider | Should Be 'openrouter'
        $candidate.stage | Should Be 'validated-active'
        @($candidate.attempts | Where-Object { $_.provider -eq 'mimo' })[0].reason | Should Be 'baseurl-missing'
    }

    It 'returns skipped diagnostics when no OpenAI-compatible provider is usable' {
        $fixture = @{
            metadata = @{ version = 2 }
            providers = @{
                mimo = @{
                    defaults = @{ baseUrl = '' }
                    activeCredential = 'mimo-main-01'
                    rotationOrder = @('mimo-main-01')
                    credentials = @{
                        'mimo-main-01' = @{
                            displayName = 'Main'
                            secret = 'test-mimo-key'
                            secretKind = 'apiKey'
                            validation = @{ state = 'failed'; checkedAt = '2026-04-29T00:00:00Z'; message = '401' }
                        }
                    }
                }
            }
            targets = (Get-BootstrapSecretsTemplate).targets
        }

        $candidate = Resolve-BootstrapOpenAiCompatibleProviderCandidate -PreferredProviders @('mimo') -SecretsData $fixture

        $candidate.status | Should Be 'no-compatible-provider'
        @($candidate.attempts).Count | Should Be 1
        $candidate.attempts[0].reason | Should Be 'baseurl-missing'
        $candidate.attempts[0].stage | Should Be 'active-fallback'
    }

    It 'handles ordered OpenAI-compatible resolver results without ContainsKey failures' {
        Mock Resolve-BootstrapOpenAiCompatibleProviderCandidate {
            return [ordered]@{
                status = 'no-compatible-provider'
                attempts = @([ordered]@{
                    provider = 'mimo'
                    stage = 'active-fallback'
                    selected = $false
                    reason = 'baseurl-missing'
                    validationState = 'failed'
                })
            }
        }

        $result = Ensure-BootstrapOpenAiCompatibleUserEnv -PreferredProviders @('mimo')

        [string]$result.status | Should Be 'skipped'
        [string]$result.reason | Should Be 'no-openai-compatible-provider'
        @($result.attempts).Count | Should Be 1
    }

    It 'classifies dev-ai API failures as non-blocking warnings' {
        $item = [ordered]@{
            id = 'antigravity-settings'
            category = 'dev-ai'
        }

        $classification = Get-BootstrapAppTuningFailureClassification -Item $item -ErrorMessage 'OpenAI-compatible: nenhum provider utilizavel foi encontrado.' -ExceptionType 'System.Exception'

        $classification.severity | Should Be 'warning'
        $classification.classification | Should Be 'api-non-blocking'
        $classification.blocking | Should Be $false
    }

    It 'classifies local execution failures as blocking' {
        $item = [ordered]@{
            id = 'notepadpp-defaults'
            category = 'dev-ai'
        }

        $classification = Get-BootstrapAppTuningFailureClassification -Item $item -ErrorMessage 'Falha ao instalar plugin local.' -ExceptionType 'System.Exception'

        $classification.severity | Should Be 'blocking'
        $classification.classification | Should Be 'execution-failure'
        $classification.blocking | Should Be $true
    }

    It 'applies notepad++ tuning without depending on OpenAI-compatible provider selection' {
        Mock Ensure-BootstrapNotepadPlusPlusDefaults {
            return [ordered]@{
                status = 'partial'
                results = [ordered]@{
                    plugins = @()
                    assets = @()
                }
            }
        }
        Mock Ensure-BootstrapOpenAiCompatibleUserEnv {
            throw 'Nao deveria ser chamado neste teste.'
        }

        $result = Apply-DevAiTuning -Item ([ordered]@{ id = 'notepadpp-defaults'; category = 'dev-ai' })

        $result.id | Should Be 'notepadpp-defaults'
        $result.status | Should Be 'partial'
        Assert-MockCalled Ensure-BootstrapNotepadPlusPlusDefaults -Times 1 -Exactly
        Assert-MockCalled Ensure-BootstrapOpenAiCompatibleUserEnv -Times 0 -Exactly
    }
}
