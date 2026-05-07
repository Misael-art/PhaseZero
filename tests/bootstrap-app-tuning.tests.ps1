$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

function New-AppTuningInventoryFixture {
    param([string[]]$InstalledApps = @(), [string[]]$InstalledPaths = @())

    $apps = @{}
    foreach ($name in @($InstalledApps)) {
        $apps[$name.ToLowerInvariant()] = $true
    }
    $paths = @{}
    foreach ($p in @($InstalledPaths)) {
        $paths[$p] = $true
    }
    return [ordered]@{
        apps = $apps
        paths = $paths
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
        $steamPath = ConvertTo-BootstrapExpandedPath -Path '$env:ProgramFiles(x86)\Steam\steam.exe'
        $plan = Resolve-BootstrapAppTuningSelection -Mode 'custom' -Items @('steam-big-picture-session') -Selection $selection -Resolution $resolution -InstalledInventory (New-AppTuningInventoryFixture -InstalledApps @('steam') -InstalledPaths @($steamPath))

        $rows = Get-BootstrapAppTuningStatusRows -Plan $plan -InstalledInventory (New-AppTuningInventoryFixture -InstalledApps @('steam') -InstalledPaths @($steamPath))
        $steamRow = $rows | Where-Object { $_.id -eq 'steam-big-picture-session' } | Select-Object -First 1

        $steamRow.installedState | Should Be 'installed'
        $steamRow.configuredState | Should Be 'planned'
        $steamRow.updatedState | Should Be 'check'
        (@($steamRow.installComponents) -contains 'steam') | Should Be $true
        $steamRow.canInstall | Should Be $true
        $steamRow.canConfigure | Should Be $true
        $steamRow.canUpdate | Should Be $true
    }

    It 'nao marca notepad++ instalado por substring acidental no DisplayName (itens com probePaths)' {
        $catalog = Get-BootstrapAppTuningCatalog
        $item = @($catalog.items | Where-Object { $_.id -eq 'notepadpp-defaults' })[0]
        $inv = New-AppTuningInventoryFixture -InstalledApps @('somethingnotepadplusplus ide')
        (Test-BootstrapAppTuningItemInstalled -Item $item -InstalledInventory $inv) | Should Be $false
    }

    It 'marca notepad++ instalado quando probePaths estao no inventory (itens com probePaths)' {
        $catalog = Get-BootstrapAppTuningCatalog
        $item = @($catalog.items | Where-Object { $_.id -eq 'notepadpp-defaults' })[0]
        $nppPath = ConvertTo-BootstrapExpandedPath -Path '$env:ProgramFiles\Notepad++\notepad++.exe'
        $inv = New-AppTuningInventoryFixture -InstalledApps @('notepad++ (64-bit x64)') -InstalledPaths @($nppPath)
        (Test-BootstrapAppTuningItemInstalled -Item $item -InstalledInventory $inv) | Should Be $true
    }

    It 'nao marca notepad++ instalado quando so registry sem probePaths (ghost install)' {
        $catalog = Get-BootstrapAppTuningCatalog
        $item = @($catalog.items | Where-Object { $_.id -eq 'notepadpp-defaults' })[0]
        $inv = New-AppTuningInventoryFixture -InstalledApps @('notepad++ (64-bit x64)')
        (Test-BootstrapAppTuningItemInstalled -Item $item -InstalledInventory $inv) | Should Be $false
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

Describe 'AppTuning installComponents e catalogo de componentes' {
    function Test-HasInlineInstallComponents {
        param($Item)
        if ($Item -is [System.Collections.IDictionary] -and $Item.Contains('installComponents')) {
            $ic = @($Item['installComponents'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            return ($ic.Count -gt 0)
        }
        $prop = $Item.PSObject.Properties['installComponents']
        if ($null -eq $prop) { return $false }
        $ic = @($prop.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        return ($ic.Count -gt 0)
    }

    It 'todo componente retornado por Get-BootstrapAppTuningInstallComponents existe em Get-BootstrapComponentCatalog' {
        $compCat = Get-BootstrapComponentCatalog
        $appTuning = Get-BootstrapAppTuningCatalog
        foreach ($item in @($appTuning.items)) {
            $comps = @(Get-BootstrapAppTuningInstallComponents -Item $item)
            foreach ($c in $comps) {
                $nm = [string]$c
                if ([string]::IsNullOrWhiteSpace($nm)) { continue }
                (Test-BootstrapMapContainsKey -Map $compCat -Key $nm) | Should Be $true
            }
        }
    }

    It 'itens tuning sem installComponents inline tem mapa (ou lista vazia intencional so edge-background-off)' {
        $appTuning = Get-BootstrapAppTuningCatalog
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($appTuning.items)) {
            $id = [string]$item.id
            if ($id -match '^app-') { continue }
            if (Test-HasInlineInstallComponents -Item $item) { continue }
            $comps = @(Get-BootstrapAppTuningInstallComponents -Item $item)
            if ($comps.Count -eq 0 -and $id -ne 'edge-background-off') {
                [void]$missing.Add($id)
            }
        }
        $missing.Count | Should Be 0
    }

    It 'mapeia steam-input-desktop-layout-audit, comet-manual e openwebui-dev-session para instalacao isolada/lote' {
        $app = Get-BootstrapAppTuningCatalog
        $by = @{}
        foreach ($x in @($app.items)) { $by[[string]$x.id] = $x }
        $a = @(Get-BootstrapAppTuningInstallComponents -Item $by['steam-input-desktop-layout-audit'])
        $a.Count | Should Be 1
        $a[0] | Should Be 'steam'
        $b = @(Get-BootstrapAppTuningInstallComponents -Item $by['comet-manual'])
        $b.Count | Should Be 1
        $b[0] | Should Be 'perplexity'
        $c = @(Get-BootstrapAppTuningInstallComponents -Item $by['openwebui-dev-session'])
        $c.Count | Should Be 1
        $c[0] | Should Be 'openwebui'
    }
}
