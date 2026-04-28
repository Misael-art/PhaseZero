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
}
