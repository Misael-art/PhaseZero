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

        foreach ($expected in @('gaming-console','steamdeck-control','dev-ai','local-ai-containers','browser-startup','connectivity','capture-creator','storage-backup','windows-qol','ai-agent-performance','agent-config','knowledge-vault','workflow-automation')) {
            ($categoryIds -contains $expected) | Should Be $true
        }

        $steamItem.category | Should Be 'gaming-console'
        $steamItem.defaultMode | Should Be 'recommended'
        (@($steamItem.actions) -contains 'session') | Should Be $true
        (@($steamItem.rollback) -contains 'manual') | Should Be $true
    }

    It 'exposes transcript integration AppTuning templates as opt-in reversible/manual items' {
        $catalog = Get-BootstrapAppTuningCatalog
        $byId = @{}
        foreach ($item in @($catalog.items)) { $byId[[string]$item.id] = $item }

        foreach ($id in @('llamacpp-mtp-template','agent-config-claude-rtk-template','headroom-agent-context-compression','knowledge-vault-obsidian-template','n8n-youtube-workflow-template','zen-browser-privacy-prefs')) {
            $byId.ContainsKey($id) | Should Be $true
            [string]$byId[$id].defaultMode | Should Be 'opt-in'
            [string]$byId[$id].riskTier | Should Match '^(conservative|advanced|experimental|manual)$'
            [string]$byId[$id].rollbackScope | Should Not Be ''
            @($byId[$id].safetyNotes).Count | Should BeGreaterThan 0
        }

        [string]$byId['llamacpp-mtp-template'].category | Should Be 'dev-ai'
        (@($byId['llamacpp-mtp-template'].actions) -contains 'diagnostic') | Should Be $true
        (@($byId['llamacpp-mtp-template'].targetApps) -contains 'llama.cpp') | Should Be $true
        [string]$byId['agent-config-claude-rtk-template'].category | Should Be 'agent-config'
        [string]$byId['headroom-agent-context-compression'].category | Should Be 'agent-config'
        (@($byId['headroom-agent-context-compression'].actions) -contains 'config-template') | Should Be $true
        (@($byId['headroom-agent-context-compression'].actions) -contains 'wrapper-template') | Should Be $true
        (@($byId['headroom-agent-context-compression'].targetApps) -contains 'claude code') | Should Be $true
        (@($byId['headroom-agent-context-compression'].targetApps) -contains 'codex') | Should Be $true
        (@($byId['headroom-agent-context-compression'].targetApps) -contains 'aider') | Should Be $true
        (@($byId['headroom-agent-context-compression'].targetApps) -contains 'n8n') | Should Be $true
        (@($byId['headroom-agent-context-compression'].targetApps) -contains 'opencode') | Should Be $true
        (@($byId['headroom-agent-context-compression'].installComponents) -contains 'headroom-ai') | Should Be $true
        [string]$byId['knowledge-vault-obsidian-template'].category | Should Be 'knowledge-vault'
        [string]$byId['n8n-youtube-workflow-template'].category | Should Be 'workflow-automation'
        [bool]$byId['n8n-youtube-workflow-template'].requiresInteractiveLogin | Should Be $true
    }

    It 'generates Headroom integration helper for correlated agent apps' {
        $workspace = Join-Path $TestDrive 'headroom-workspace'
        $null = New-Item -Path $workspace -ItemType Directory -Force
        $item = [ordered]@{
            id = 'headroom-agent-context-compression'
            category = 'agent-config'
            installed = $true
        }

        $result = Invoke-BootstrapAppTuningItem -State @{ CloneBaseDir = $workspace } -Item $item

        [string]$result.status | Should Match '^(applied|configured)$'
        $docPath = Join-Path $workspace '.codex\context-packs\headroom-agent-integration.md'
        $scriptPath = Join-Path $workspace '.codex\scripts\headroom-agent.ps1'
        Test-Path -LiteralPath $docPath | Should Be $true
        Test-Path -LiteralPath $scriptPath | Should Be $true

        $doc = Get-Content -LiteralPath $docPath -Raw
        $script = Get-Content -LiteralPath $scriptPath -Raw
        foreach ($expected in @('headroom wrap claude --memory','headroom wrap codex --memory','headroom wrap aider','headroom wrap cursor','headroom wrap openclaw','n8n','OpenCode')) {
            $doc | Should Match ([regex]::Escape($expected))
        }
        $doc | Should Match 'OpenCode.+manual'
        foreach ($expectedAction in @('wrap-claude','wrap-codex','wrap-aider','wrap-cursor','wrap-copilot','wrap-gemini','wrap-openclaw','mcp-install','proxy','stats')) {
            $script | Should Match ([regex]::Escape($expectedAction))
        }
    }

    It 'exposes conservative AI agent performance items with safety metadata' {
        $catalog = Get-BootstrapAppTuningCatalog
        $byId = @{}
        foreach ($item in @($catalog.items)) { $byId[[string]$item.id] = $item }

        foreach ($id in @(
            'windows-ai-visual-performance',
            'windows-ai-delivery-optimization-http-only',
            'windows-ai-docker-high-priority',
            'windows-ai-security-posture-audit',
            'windows-ai-workspace-defender-exclusion',
            'windows-ai-node-python-defender-process-exclusion',
            'windows-ai-services-deep-tuning'
        )) {
            $byId.ContainsKey($id) | Should Be $true
            $byId[$id].category | Should Be 'ai-agent-performance'
            [string]$byId[$id].riskTier | Should Not Be ''
            [string]$byId[$id].rollbackScope | Should Not Be ''
            @($byId[$id].safetyNotes).Count | Should BeGreaterThan 0
        }

        $byId['windows-ai-visual-performance'].defaultMode | Should Be 'recommended'
        $byId['windows-ai-security-posture-audit'].defaultMode | Should Be 'recommended'
        $byId['windows-ai-workspace-defender-exclusion'].defaultMode | Should Be 'opt-in'
        $byId['windows-ai-node-python-defender-process-exclusion'].defaultMode | Should Be 'opt-in'
        $byId['windows-ai-services-deep-tuning'].defaultMode | Should Be 'opt-in'
        [bool]$byId['windows-ai-services-deep-tuning'].securityImpact | Should Be $true
    }

    It 'defaults profile aliases to off and applies recommended tuning only when explicitly requested' {
        $legacySelection = New-BootstrapSelectionObject -SelectedProfiles @('legacy')
        $legacyResolution = Resolve-BootstrapComponents -SelectedProfiles $legacySelection.Profiles
        $modernSelection = New-BootstrapSelectionObject -SelectedProfiles @('recommended')
        $modernResolution = Resolve-BootstrapComponents -SelectedProfiles $modernSelection.Profiles

        (Get-BootstrapDefaultAppTuningMode -Selection $legacySelection -Resolution $legacyResolution) | Should Be 'off'
        (Get-BootstrapDefaultAppTuningMode -Selection $modernSelection -Resolution $modernResolution) | Should Be 'off'

        $explicitPlan = Resolve-BootstrapAppTuningSelection -Mode 'recommended' -Selection $modernSelection -Resolution $modernResolution -InstalledInventory (New-AppTuningInventoryFixture -InstalledApps @('steam'))
        $explicitPlan.mode | Should Be 'recommended'
        @($explicitPlan.items).Count | Should BeGreaterThan 0
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

    It 'keeps AI performance recommended selection conservative and allows explicit risky opt-in' {
        $selection = New-BootstrapSelectionObject -SelectedProfiles @('recommended')
        $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles
        $plan = Resolve-BootstrapAppTuningSelection -Mode 'custom' -Categories @('ai-agent-performance') -Items @('windows-ai-services-deep-tuning') -Selection $selection -Resolution $resolution -InstalledInventory (New-AppTuningInventoryFixture)
        $ids = @($plan.items | ForEach-Object { [string]$_.id })

        ($ids -contains 'windows-ai-visual-performance') | Should Be $true
        ($ids -contains 'windows-ai-security-posture-audit') | Should Be $true
        ($ids -contains 'windows-ai-workspace-defender-exclusion') | Should Be $false
        ($ids -contains 'windows-ai-node-python-defender-process-exclusion') | Should Be $false
        ($ids -contains 'windows-ai-services-deep-tuning') | Should Be $true
        (@($plan.items | Where-Object { $_.id -eq 'windows-ai-services-deep-tuning' })[0].securityImpact) | Should Be $true
        (@($plan.items | Where-Object { $_.id -eq 'windows-ai-services-deep-tuning' })[0].riskTier) | Should Be 'aggressive'
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

    It 'surfaces AI performance risk metadata in status rows' {
        $selection = New-BootstrapSelectionObject -SelectedProfiles @('recommended')
        $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles
        $plan = Resolve-BootstrapAppTuningSelection -Mode 'custom' -Categories @('ai-agent-performance') -Selection $selection -Resolution $resolution -InstalledInventory (New-AppTuningInventoryFixture)
        $rows = Get-BootstrapAppTuningStatusRows -Plan $plan -InstalledInventory (New-AppTuningInventoryFixture)
        $visual = $rows | Where-Object { $_.id -eq 'windows-ai-visual-performance' } | Select-Object -First 1

        $visual.installedState | Should Be 'installed'
        (@('planned','configured') -contains $visual.configuredState) | Should Be $true
        $visual.risk | Should Be 'conservative'
        $visual.rollbackScope | Should Be 'registry-snapshot'
        @($visual.safetyNotes).Count | Should BeGreaterThan 0
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
        $candidate.attempts[0].reason | Should Be 'validation-failed'
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

    It 'exposes Codex Desktop repair as dev-ai recommended tuning' {
        $catalog = Get-BootstrapAppTuningCatalog
        $item = @($catalog.items | Where-Object { $_.id -eq 'codex-desktop-repair' })[0]

        $item.category | Should Be 'dev-ai'
        $item.defaultMode | Should Be 'recommended'
        (@($item.actions) -contains 'repair') | Should Be $true
        (@($item.rollback) -contains 'backup-file') | Should Be $true
    }

    It 'exposes AI agent BYOK config for requested agent apps' {
        $catalog = Get-BootstrapAppTuningCatalog
        $item = @($catalog.items | Where-Object { $_.id -eq 'ai-agent-byok-config' })[0]

        $item.category | Should Be 'dev-ai'
        $item.defaultMode | Should Be 'recommended'
        (@($item.targetApps) -contains 'openclaw') | Should Be $true
        (@($item.targetApps) -contains 'hermes') | Should Be $true
        (@($item.targetApps) -contains 'kilo') | Should Be $true
        (@($item.actions) -contains 'config-file') | Should Be $true
    }

    It 'exposes GitHub CLI agent auth as dev-ai recommended tuning' {
        $catalog = Get-BootstrapAppTuningCatalog
        $item = @($catalog.items | Where-Object { $_.id -eq 'github-cli-agent-auth' })[0]

        $item.category | Should Be 'dev-ai'
        $item.defaultMode | Should Be 'recommended'
        (@($item.targetApps) -contains 'github cli') | Should Be $true
        (@($item.actions) -contains 'config-file') | Should Be $true
        (@(Get-BootstrapAppTuningInstallComponents -Item $item) -contains 'github-cli') | Should Be $true
        (@(Get-BootstrapAppTuningInstallComponents -Item $item) -contains 'bootstrap-secrets') | Should Be $true
    }

    It 'applies GitHub CLI agent auth without touching userEnv directly' {
        Mock Set-BootstrapGithubCliAgentAuth {
            return [ordered]@{
                status = 'applied'
                userEnvApplied = 0
                tokenAvailable = $true
                targets = @{ claudeCodeUpdated = $true }
            }
        }

        $result = Apply-DevAiTuning -Item ([ordered]@{ id = 'github-cli-agent-auth'; category = 'dev-ai' })

        $result.id | Should Be 'github-cli-agent-auth'
        $result.status | Should Be 'applied'
        $result.summary.userEnvApplied | Should Be 0
        Assert-MockCalled Set-BootstrapGithubCliAgentAuth -Times 1 -Exactly
    }

    It 'repairs Codex Desktop WSL state with backup' {
        $root = Join-Path $env:TEMP ("phasezero_codex_state_{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -Path $root -ItemType Directory -Force | Out-Null
        $statePath = Join-Path $root '.codex-global-state.json'
        @{
            runCodexInWindowsSubsystemForLinux = $true
            integratedTerminalShell = 'wsl'
            keep = 'value'
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $statePath -Encoding UTF8

        $result = Repair-BootstrapCodexDesktopStateFile -Path $statePath -DisableWslFallback
        $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json

        $result.status | Should Be 'repaired'
        (Test-Path -LiteralPath ([string]$result.backup)) | Should Be $true
        [bool]$state.runCodexInWindowsSubsystemForLinux | Should Be $false
        [string]$state.integratedTerminalShell | Should Be 'powershell'
        [string]$state.keep | Should Be 'value'
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

    It 'itens tuning sem installComponents inline tem mapa (ou lista vazia intencional para sistema/app-free)' {
        $appTuning = Get-BootstrapAppTuningCatalog
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($appTuning.items)) {
            $id = [string]$item.id
            if ($id -match '^app-') { continue }
            if (Test-HasInlineInstallComponents -Item $item) { continue }
            $comps = @(Get-BootstrapAppTuningInstallComponents -Item $item)
            $itemMap = ConvertTo-BootstrapHashtable -InputObject $item
            $appFree = (($itemMap -is [hashtable]) -and $itemMap.ContainsKey('alwaysAvailable') -and [bool]$itemMap['alwaysAvailable'])
            if ($comps.Count -eq 0 -and $id -ne 'edge-background-off' -and -not $appFree) {
                [void]$missing.Add($id)
            }
        }
        $missing.Count | Should Be 0
    }

    It 'mapeia steam-input-desktop-layout-audit, codex-desktop-repair, ai-agent-byok-config, comet-manual e openwebui-dev-session para instalacao isolada/lote' {
        $app = Get-BootstrapAppTuningCatalog
        $by = @{}
        foreach ($x in @($app.items)) { $by[[string]$x.id] = $x }
        $a = @(Get-BootstrapAppTuningInstallComponents -Item $by['steam-input-desktop-layout-audit'])
        $a.Count | Should Be 1
        $a[0] | Should Be 'steam'
        $d = @(Get-BootstrapAppTuningInstallComponents -Item $by['codex-desktop-repair'])
        $d.Count | Should Be 3
        (@($d) -contains 'codex-installer') | Should Be $true
        (@($d) -contains 'codex-cli') | Should Be $true
        (@($d) -contains 'vcpp-redist') | Should Be $true
        $e = @(Get-BootstrapAppTuningInstallComponents -Item $by['ai-agent-byok-config'])
        (@($e) -contains 'bootstrap-secrets') | Should Be $true
        (@($e) -contains 'kilo-cli') | Should Be $true
        (@($e) -contains 'openclaw') | Should Be $true
        (@($e) -contains 'hermes') | Should Be $true
        $b = @(Get-BootstrapAppTuningInstallComponents -Item $by['comet-manual'])
        $b.Count | Should Be 1
        $b[0] | Should Be 'perplexity'
        $c = @(Get-BootstrapAppTuningInstallComponents -Item $by['openwebui-dev-session'])
        $c.Count | Should Be 1
        $c[0] | Should Be 'openwebui'
    }
}

Describe 'AI agent performance helpers' {
    It 'applies visual performance registry values through reversible registry helper' {
        Mock Apply-BootstrapRegistryDword {
            return [ordered]@{ path = $Path; name = $Name; value = $Value; status = 'applied' }
        }
        $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\Workspace' -ResolvedCloneBaseDir 'C:\Workspace'

        $result = Apply-AiAgentPerformanceTuning -State $state -Item ([ordered]@{ id = 'windows-ai-visual-performance'; category = 'ai-agent-performance' })

        $result.status | Should Be 'applied'
        Assert-MockCalled Apply-BootstrapRegistryDword -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -and $Name -eq 'VisualFXSetting' -and $Value -eq 2 } -Times 1
        Assert-MockCalled Apply-BootstrapRegistryDword -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -and $Name -eq 'EnableTransparency' -and $Value -eq 0 } -Times 1
    }

    It 'adds only workspace Defender exclusions and registers rollback' {
        Mock Test-IsAdmin { return $true }
        Mock Get-MpPreference { return [pscustomobject]@{ ExclusionPath = @('C:\Existing'); ExclusionProcess = @() } }
        Mock Add-MpPreference
        $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\Workspace' -ResolvedCloneBaseDir 'C:\Workspace'

        $result = Add-BootstrapDefenderExclusion -State $state -Kind 'ExclusionPath' -Value 'C:\Workspace'

        $result.status | Should Be 'applied'
        Assert-MockCalled Add-MpPreference -ParameterFilter { $ExclusionPath -eq 'C:\Workspace' } -Times 1
        $defenderChanges = @($state.Changes.ToArray() | Where-Object {
            $change = ConvertTo-BootstrapHashtable -InputObject $_
            ($change -is [hashtable]) -and [string]$change['Type'] -eq 'DefenderExclusion' -and [string]$change['Target'] -eq 'C:\Workspace'
        })
        $defenderChanges.Count | Should Be 1
    }

    It 'keeps Docker priority tuning non-blocking when Docker is absent' {
        Mock Get-Process { return @() }

        $result = Set-BootstrapDockerHighPriority

        $result.status | Should Be 'skipped'
        $result.blocking | Should Be $false
    }
}
