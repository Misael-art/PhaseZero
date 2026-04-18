param(
    [string]$UiStatePath = (Join-Path (Join-Path $env:USERPROFILE '.bootstrap-tools') 'ui-state.json'),
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$backendScriptPath = Join-Path $PSScriptRoot 'bootstrap-tools.ps1'
if (-not (Test-Path $backendScriptPath)) {
    throw "bootstrap-tools.ps1 not found at $backendScriptPath"
}

. $backendScriptPath -BootstrapUiLibraryMode

function Get-UiLanguages {
    return @('pt-BR', 'en-US')
}

function Get-UiPageIds {
    return @('welcome', 'selection', 'host-setup', 'steamdeck-control', 'review', 'run')
}

function Get-UiStrings {
    param([Parameter(Mandatory = $true)][string]$Language)

    switch ($Language) {
        'en-US' {
            return @{
                WindowTitle = 'Bootstrap Tools Control Center'
                WelcomeTitle = 'Bootstrap Tools + Steam Deck'
                WelcomeSubtitle = 'Simple host setup, Steam Deck control and post-install maintenance.'
                Language = 'Language'
                QuickPresets = 'Quick presets'
                CustomPresets = 'Custom presets'
                PresetName = 'Preset name'
                SavePreset = 'Save current preset'
                LoadPreset = 'Load preset'
                DeletePreset = 'Delete preset'
                SelectionTitle = 'Profiles and components'
                Filter = 'Filter'
                Profiles = 'Profiles'
                Components = 'Components'
                Excludes = 'Optional excludes'
                SelectionDetails = 'Selection details'
                HostSetupTitle = 'Host setup'
                HostHealth = 'HostHealth'
                SteamDeckVersion = 'Steam Deck version'
                WorkspaceRoot = 'Workspace root'
                CloneBaseDir = 'Clone base dir'
                Browse = 'Browse...'
                AdminNeeds = 'Admin review'
                SteamDeckCenterTitle = 'Steam Deck control center'
                MonitorProfiles = 'Monitor profiles'
                MonitorFamilies = 'Monitor families'
                GenericExternal = 'Generic external fallback'
                SessionProfiles = 'Session profiles'
                WatcherStatus = 'Watcher status'
                SaveSettings = 'Save settings'
                ReloadSettings = 'Reload settings'
                UnknownMonitorHint = 'Unknown external monitors always fall back to genericExternal.'
                ReviewTitle = 'Review'
                RefreshReview = 'Refresh review'
                ReviewSummary = 'Preview equivalent to dry-run'
                RunTitle = 'Run'
                StartRun = 'Start execution'
                OpenLog = 'Open log'
                OpenResult = 'Open result'
                OpenSettings = 'Open settings'
                OpenReports = 'Open reports'
                IdleStatus = 'Ready.'
                SavingSettings = 'Settings saved.'
                RunStarted = 'Execution started.'
                RunCompleted = 'Execution completed.'
                RunFailed = 'Execution failed.'
                UserCanceledElevation = 'Execution canceled or elevation denied.'
                Back = 'Back'
                Next = 'Next'
                Finish = 'Close'
                Welcome = 'Welcome'
                Selection = 'Selection'
                HostSetup = 'Host setup'
                SteamDeckControl = 'Steam Deck control'
                Review = 'Review'
                Run = 'Run'
                GenericMode = 'Mode'
                GenericLayout = 'Layout'
                GenericResolution = 'Resolution policy'
                SessionHandheld = 'HANDHELD'
                SessionDockedTv = 'DOCKED_TV'
                SessionDockedMonitor = 'DOCKED_MONITOR'
            }
        }
        default {
            return @{
                WindowTitle = 'Central Bootstrap Tools'
                WelcomeTitle = 'Bootstrap Tools + Steam Deck'
                WelcomeSubtitle = 'Setup simples do host, controle do Steam Deck e manutencao pos-instalacao.'
                Language = 'Idioma'
                QuickPresets = 'Presets rapidos'
                CustomPresets = 'Presets personalizados'
                PresetName = 'Nome do preset'
                SavePreset = 'Salvar preset atual'
                LoadPreset = 'Carregar preset'
                DeletePreset = 'Excluir preset'
                SelectionTitle = 'Perfis e componentes'
                Filter = 'Filtro'
                Profiles = 'Perfis'
                Components = 'Componentes'
                Excludes = 'Exclusoes opcionais'
                SelectionDetails = 'Detalhes da selecao'
                HostSetupTitle = 'Configuracao do host'
                HostHealth = 'HostHealth'
                SteamDeckVersion = 'Versao do Steam Deck'
                WorkspaceRoot = 'Workspace root'
                CloneBaseDir = 'Diretorio base de clones'
                Browse = 'Selecionar...'
                AdminNeeds = 'Revisao de admin'
                SteamDeckCenterTitle = 'Central Steam Deck'
                MonitorProfiles = 'Monitor profiles'
                MonitorFamilies = 'Monitor families'
                GenericExternal = 'Fallback genericExternal'
                SessionProfiles = 'Session profiles'
                WatcherStatus = 'Status do watcher'
                SaveSettings = 'Salvar settings'
                ReloadSettings = 'Recarregar settings'
                UnknownMonitorHint = 'Monitores externos desconhecidos sempre caem em genericExternal.'
                ReviewTitle = 'Revisao'
                RefreshReview = 'Atualizar revisao'
                ReviewSummary = 'Preview equivalente ao dry-run'
                RunTitle = 'Execucao'
                StartRun = 'Iniciar execucao'
                OpenLog = 'Abrir log'
                OpenResult = 'Abrir resultado'
                OpenSettings = 'Abrir settings'
                OpenReports = 'Abrir relatorios'
                IdleStatus = 'Pronto.'
                SavingSettings = 'Settings salvos.'
                RunStarted = 'Execucao iniciada.'
                RunCompleted = 'Execucao concluida.'
                RunFailed = 'Execucao falhou.'
                UserCanceledElevation = 'Execucao cancelada ou elevacao negada.'
                Back = 'Voltar'
                Next = 'Avancar'
                Finish = 'Fechar'
                Welcome = 'Inicio'
                Selection = 'Selecao'
                HostSetup = 'Host setup'
                SteamDeckControl = 'Central Steam Deck'
                Review = 'Revisao'
                Run = 'Execucao'
                GenericMode = 'Modo'
                GenericLayout = 'Layout'
                GenericResolution = 'Politica de resolucao'
                SessionHandheld = 'HANDHELD'
                SessionDockedTv = 'DOCKED_TV'
                SessionDockedMonitor = 'DOCKED_MONITOR'
            }
        }
    }
}

function Get-UiStateDefaults {
    param($Contract)

    return [ordered]@{
        language = 'pt-BR'
        selectedProfiles = @('recommended')
        selectedComponents = @()
        excludedComponents = @()
        hostHealth = 'conservador'
        steamDeckVersion = 'Auto'
        workspaceRoot = [string]$Contract.defaults.workspaceRoot
        cloneBaseDir = (Get-Location).Path
        customPresets = @{}
        lastLogPath = $null
        lastResultPath = $null
        lastReportPath = $null
        lastSettingsPath = Get-BootstrapSteamDeckSettingsPath
    }
}

function Normalize-UiState {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)]$Contract
    )

    $defaults = Get-UiStateDefaults -Contract $Contract
    $normalized = Merge-BootstrapData -Defaults $defaults -Current $State
    $normalized = ConvertTo-BootstrapHashtable -InputObject $normalized
    $normalized['selectedProfiles'] = @(Normalize-BootstrapNames -Names @($normalized['selectedProfiles']))
    $normalized['selectedComponents'] = @(Normalize-BootstrapNames -Names @($normalized['selectedComponents']))
    $normalized['excludedComponents'] = @(Normalize-BootstrapNames -Names @($normalized['excludedComponents']))

    $language = [string]$normalized['language']
    if ((Get-UiLanguages) -notcontains $language) {
        $normalized['language'] = 'pt-BR'
    }

    if ([string]::IsNullOrWhiteSpace([string]$normalized['hostHealth'])) {
        $normalized['hostHealth'] = 'conservador'
    } else {
        $normalized['hostHealth'] = Normalize-BootstrapHostHealthMode -Mode ([string]$normalized['hostHealth'])
    }

    if ([string]::IsNullOrWhiteSpace([string]$normalized['steamDeckVersion'])) {
        $normalized['steamDeckVersion'] = 'Auto'
    }

    if (-not $normalized.ContainsKey('customPresets') -or -not ($normalized['customPresets'] -is [hashtable])) {
        $normalized['customPresets'] = @{}
    }

    return $normalized
}

function Read-UiState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Contract
    )

    $current = $null
    if (Test-Path $Path) {
        try {
            $current = Get-Content -Path $Path -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $current = $null
        }
    }

    return (Normalize-UiState -State $current -Contract $Contract)
}

function Save-UiState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Write-BootstrapJsonFile -Path $Path -Value (ConvertTo-BootstrapHashtable -InputObject $State)
}

$contract = Get-BootstrapUiContract
$state = Read-UiState -Path $UiStatePath -Contract $contract

if ($SmokeTest) {
    Save-UiState -State $state -Path $UiStatePath
    [ordered]@{
        pages = @(Get-UiPageIds)
        languages = @(Get-UiLanguages)
        statePath = $UiStatePath
        backend = $backendScriptPath
    } | ConvertTo-Json -Depth 8
    return
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-STA',
        '-File', $PSCommandPath,
        '-UiStatePath', $UiStatePath
    )
    Start-Process -FilePath $powershellExe -ArgumentList ([string]::Join(' ', @($argumentList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }))) | Out-Null
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Quote-CommandArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function ConvertTo-ArgumentString {
    param([string[]]$Tokens)
    return ([string]::Join(' ', @($Tokens | ForEach-Object { Quote-CommandArgument -Value $_ })))
}

function Open-ExistingPath {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path $Path)) {
        Start-Process -FilePath $Path | Out-Null
    }
}

function Read-GridRows {
    param(
        [Parameter(Mandatory = $true)]$Grid,
        [Parameter(Mandatory = $true)][string[]]$Columns
    )

    $rows = @()
    foreach ($row in @($Grid.Rows)) {
        if ($row.IsNewRow) { continue }
        $item = [ordered]@{}
        $hasData = $false
        foreach ($column in $Columns) {
            $value = $row.Cells[$column].Value
            $text = if ($null -eq $value) { '' } else { [string]$value }
            $text = $text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) { $hasData = $true }
            $item[$column] = $text
        }
        if ($hasData) {
            $rows += @($item)
        }
    }
    return @($rows)
}

function Load-GridRows {
    param(
        [Parameter(Mandatory = $true)]$Grid,
        [Parameter(Mandatory = $true)]$Items,
        [Parameter(Mandatory = $true)][string[]]$Columns
    )

    $Grid.Rows.Clear()
    foreach ($item in @($Items)) {
        $rowValues = foreach ($column in $Columns) {
            if ($item.Contains($column)) { [string]$item[$column] } else { '' }
        }
        [void]$Grid.Rows.Add($rowValues)
    }
}

function Get-SelectionDetailsText {
    param(
        [AllowNull()]$Item,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    if ($null -eq $Item) { return '' }

    if ($Kind -eq 'profile') {
        return @(
            "Name: $($Item.name)"
            "Description: $($Item.description)"
            "Items: $(@($Item.items) -join ', ')"
        ) -join [Environment]::NewLine
    }

    return @(
        "Name: $($Item.name)"
        "Description: $($Item.description)"
        "DependsOn: $(@($Item.dependsOn) -join ', ')"
        "Kind: $($Item.kind)"
        "Stage: $($Item.stage)"
        "Optional: $($Item.optional)"
        "Value: $($Item.valueReason)"
    ) -join [Environment]::NewLine
}

$ui = [ordered]@{
    Contract = $contract
    State = $state
    Strings = Get-UiStrings -Language ([string]$state.language)
    CurrentPageIndex = 0
    Preview = $null
    SettingsBundle = Get-BootstrapSteamDeckSettingsData -RequestedSteamDeckVersion ([string]$state.steamDeckVersion) -ResolvedSteamDeckVersion 'lcd'
    SettingsBackupPath = $null
    SuppressSelectionEvents = $false
    LogOffset = 0
    CurrentLogPath = $null
    CurrentResultPath = $null
    RunProcess = $null
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $ui.Strings.WindowTitle
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ClientSize = New-Object System.Drawing.Size(1100, 760)
$form.BackColor = [System.Drawing.SystemColors]::Window
$ui.Form = $form

$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Location = New-Object System.Drawing.Point(20, 12)
$headerLabel.Size = New-Object System.Drawing.Size(760, 28)
$headerLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($headerLabel)
$ui.HeaderLabel = $headerLabel

$stepLabel = New-Object System.Windows.Forms.Label
$stepLabel.Location = New-Object System.Drawing.Point(800, 16)
$stepLabel.Size = New-Object System.Drawing.Size(280, 24)
$stepLabel.TextAlign = 'MiddleRight'
$form.Controls.Add($stepLabel)
$ui.StepLabel = $stepLabel

$pageHost = New-Object System.Windows.Forms.Panel
$pageHost.Location = New-Object System.Drawing.Point(20, 50)
$pageHost.Size = New-Object System.Drawing.Size(1060, 650)
$pageHost.BorderStyle = 'FixedSingle'
$form.Controls.Add($pageHost)

$backButton = New-Object System.Windows.Forms.Button
$backButton.Location = New-Object System.Drawing.Point(780, 712)
$backButton.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($backButton)
$ui.BackButton = $backButton

$nextButton = New-Object System.Windows.Forms.Button
$nextButton.Location = New-Object System.Drawing.Point(880, 712)
$nextButton.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($nextButton)
$ui.NextButton = $nextButton

$finishButton = New-Object System.Windows.Forms.Button
$finishButton.Location = New-Object System.Drawing.Point(980, 712)
$finishButton.Size = New-Object System.Drawing.Size(100, 32)
$form.Controls.Add($finishButton)
$ui.FinishButton = $finishButton

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(20, 718)
$statusLabel.Size = New-Object System.Drawing.Size(740, 22)
$form.Controls.Add($statusLabel)
$ui.StatusLabel = $statusLabel

$pages = @{}
foreach ($pageId in (Get-UiPageIds)) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'
    $panel.Visible = $false
    $pageHost.Controls.Add($panel)
    $pages[$pageId] = $panel
}
$ui.Pages = $pages

$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 1200
$ui.LogTimer = $logTimer

# Welcome page
$welcomePanel = $pages['welcome']
$welcomeTitle = New-Object System.Windows.Forms.Label
$welcomeTitle.Location = New-Object System.Drawing.Point(20, 20)
$welcomeTitle.Size = New-Object System.Drawing.Size(700, 30)
$welcomeTitle.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$welcomePanel.Controls.Add($welcomeTitle)
$ui.WelcomeTitleLabel = $welcomeTitle

$welcomeSubtitle = New-Object System.Windows.Forms.Label
$welcomeSubtitle.Location = New-Object System.Drawing.Point(20, 58)
$welcomeSubtitle.Size = New-Object System.Drawing.Size(860, 38)
$welcomePanel.Controls.Add($welcomeSubtitle)
$ui.WelcomeSubtitleLabel = $welcomeSubtitle

$languageLabel = New-Object System.Windows.Forms.Label
$languageLabel.Location = New-Object System.Drawing.Point(20, 110)
$languageLabel.Size = New-Object System.Drawing.Size(120, 20)
$welcomePanel.Controls.Add($languageLabel)
$ui.LanguageLabel = $languageLabel

$languageCombo = New-Object System.Windows.Forms.ComboBox
$languageCombo.Location = New-Object System.Drawing.Point(150, 106)
$languageCombo.Size = New-Object System.Drawing.Size(160, 24)
$languageCombo.DropDownStyle = 'DropDownList'
[void]$languageCombo.Items.AddRange((Get-UiLanguages))
$languageCombo.SelectedItem = [string]$ui.State.language
$welcomePanel.Controls.Add($languageCombo)
$ui.LanguageCombo = $languageCombo

$quickPresetsGroup = New-Object System.Windows.Forms.GroupBox
$quickPresetsGroup.Location = New-Object System.Drawing.Point(20, 150)
$quickPresetsGroup.Size = New-Object System.Drawing.Size(500, 220)
$welcomePanel.Controls.Add($quickPresetsGroup)
$ui.QuickPresetsGroup = $quickPresetsGroup

$presetButtons = @{}
$presetNames = @('recommended', 'legacy', 'full', 'steamdeck-recommended', 'steamdeck-full')
for ($i = 0; $i -lt $presetNames.Count; $i++) {
    $button = New-Object System.Windows.Forms.Button
    $button.Location = New-Object System.Drawing.Point(20, (30 + ($i * 34)))
    $button.Size = New-Object System.Drawing.Size(440, 28)
    $button.Tag = $presetNames[$i]
    $button.Text = $presetNames[$i]
    $quickPresetsGroup.Controls.Add($button)
    $presetButtons[$presetNames[$i]] = $button
}
$ui.PresetButtons = $presetButtons

$customPresetGroup = New-Object System.Windows.Forms.GroupBox
$customPresetGroup.Location = New-Object System.Drawing.Point(550, 150)
$customPresetGroup.Size = New-Object System.Drawing.Size(470, 220)
$welcomePanel.Controls.Add($customPresetGroup)
$ui.CustomPresetGroup = $customPresetGroup

$presetNameLabel = New-Object System.Windows.Forms.Label
$presetNameLabel.Location = New-Object System.Drawing.Point(20, 30)
$presetNameLabel.Size = New-Object System.Drawing.Size(120, 20)
$customPresetGroup.Controls.Add($presetNameLabel)
$ui.PresetNameLabel = $presetNameLabel

$presetNameTextBox = New-Object System.Windows.Forms.TextBox
$presetNameTextBox.Location = New-Object System.Drawing.Point(150, 28)
$presetNameTextBox.Size = New-Object System.Drawing.Size(290, 24)
$customPresetGroup.Controls.Add($presetNameTextBox)
$ui.PresetNameTextBox = $presetNameTextBox

$savePresetButton = New-Object System.Windows.Forms.Button
$savePresetButton.Location = New-Object System.Drawing.Point(150, 62)
$savePresetButton.Size = New-Object System.Drawing.Size(290, 28)
$customPresetGroup.Controls.Add($savePresetButton)
$ui.SavePresetButton = $savePresetButton

$customPresetCombo = New-Object System.Windows.Forms.ComboBox
$customPresetCombo.Location = New-Object System.Drawing.Point(20, 118)
$customPresetCombo.Size = New-Object System.Drawing.Size(420, 24)
$customPresetCombo.DropDownStyle = 'DropDownList'
$customPresetGroup.Controls.Add($customPresetCombo)
$ui.CustomPresetCombo = $customPresetCombo

$loadPresetButton = New-Object System.Windows.Forms.Button
$loadPresetButton.Location = New-Object System.Drawing.Point(20, 154)
$loadPresetButton.Size = New-Object System.Drawing.Size(200, 28)
$customPresetGroup.Controls.Add($loadPresetButton)
$ui.LoadPresetButton = $loadPresetButton

$deletePresetButton = New-Object System.Windows.Forms.Button
$deletePresetButton.Location = New-Object System.Drawing.Point(240, 154)
$deletePresetButton.Size = New-Object System.Drawing.Size(200, 28)
$customPresetGroup.Controls.Add($deletePresetButton)
$ui.DeletePresetButton = $deletePresetButton

# Selection page
$selectionPanel = $pages['selection']
$selectionTitle = New-Object System.Windows.Forms.Label
$selectionTitle.Location = New-Object System.Drawing.Point(20, 20)
$selectionTitle.Size = New-Object System.Drawing.Size(500, 28)
$selectionTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$selectionPanel.Controls.Add($selectionTitle)
$ui.SelectionTitleLabel = $selectionTitle

$filterLabel = New-Object System.Windows.Forms.Label
$filterLabel.Location = New-Object System.Drawing.Point(20, 60)
$filterLabel.Size = New-Object System.Drawing.Size(80, 20)
$selectionPanel.Controls.Add($filterLabel)
$ui.FilterLabel = $filterLabel

$filterTextBox = New-Object System.Windows.Forms.TextBox
$filterTextBox.Location = New-Object System.Drawing.Point(100, 58)
$filterTextBox.Size = New-Object System.Drawing.Size(300, 24)
$selectionPanel.Controls.Add($filterTextBox)
$ui.FilterTextBox = $filterTextBox

$profilesLabel = New-Object System.Windows.Forms.Label
$profilesLabel.Location = New-Object System.Drawing.Point(20, 96)
$profilesLabel.Size = New-Object System.Drawing.Size(220, 20)
$selectionPanel.Controls.Add($profilesLabel)
$ui.ProfilesLabel = $profilesLabel

$profilesTree = New-Object System.Windows.Forms.TreeView
$profilesTree.Location = New-Object System.Drawing.Point(20, 120)
$profilesTree.Size = New-Object System.Drawing.Size(320, 340)
$profilesTree.CheckBoxes = $true
$selectionPanel.Controls.Add($profilesTree)
$ui.ProfilesTree = $profilesTree

$componentsLabel = New-Object System.Windows.Forms.Label
$componentsLabel.Location = New-Object System.Drawing.Point(360, 96)
$componentsLabel.Size = New-Object System.Drawing.Size(220, 20)
$selectionPanel.Controls.Add($componentsLabel)
$ui.ComponentsLabel = $componentsLabel

$componentsTree = New-Object System.Windows.Forms.TreeView
$componentsTree.Location = New-Object System.Drawing.Point(360, 120)
$componentsTree.Size = New-Object System.Drawing.Size(320, 340)
$componentsTree.CheckBoxes = $true
$selectionPanel.Controls.Add($componentsTree)
$ui.ComponentsTree = $componentsTree

$excludeLabel = New-Object System.Windows.Forms.Label
$excludeLabel.Location = New-Object System.Drawing.Point(700, 96)
$excludeLabel.Size = New-Object System.Drawing.Size(220, 20)
$selectionPanel.Controls.Add($excludeLabel)
$ui.ExcludeLabel = $excludeLabel

$excludeList = New-Object System.Windows.Forms.CheckedListBox
$excludeList.Location = New-Object System.Drawing.Point(700, 120)
$excludeList.Size = New-Object System.Drawing.Size(320, 214)
$selectionPanel.Controls.Add($excludeList)
$ui.ExcludeList = $excludeList

$detailsLabel = New-Object System.Windows.Forms.Label
$detailsLabel.Location = New-Object System.Drawing.Point(700, 350)
$detailsLabel.Size = New-Object System.Drawing.Size(220, 20)
$selectionPanel.Controls.Add($detailsLabel)
$ui.DetailsLabel = $detailsLabel

$detailsTextBox = New-Object System.Windows.Forms.TextBox
$detailsTextBox.Location = New-Object System.Drawing.Point(700, 374)
$detailsTextBox.Size = New-Object System.Drawing.Size(320, 160)
$detailsTextBox.Multiline = $true
$detailsTextBox.ReadOnly = $true
$detailsTextBox.ScrollBars = 'Vertical'
$selectionPanel.Controls.Add($detailsTextBox)
$ui.DetailsTextBox = $detailsTextBox

$selectionSummaryLabel = New-Object System.Windows.Forms.Label
$selectionSummaryLabel.Location = New-Object System.Drawing.Point(20, 480)
$selectionSummaryLabel.Size = New-Object System.Drawing.Size(1000, 24)
$selectionPanel.Controls.Add($selectionSummaryLabel)
$ui.SelectionSummaryLabel = $selectionSummaryLabel

$selectionErrorLabel = New-Object System.Windows.Forms.Label
$selectionErrorLabel.Location = New-Object System.Drawing.Point(20, 510)
$selectionErrorLabel.Size = New-Object System.Drawing.Size(1000, 50)
$selectionErrorLabel.ForeColor = [System.Drawing.Color]::Firebrick
$selectionPanel.Controls.Add($selectionErrorLabel)
$ui.SelectionErrorLabel = $selectionErrorLabel

# Host setup page
$hostPanel = $pages['host-setup']
$hostTitle = New-Object System.Windows.Forms.Label
$hostTitle.Location = New-Object System.Drawing.Point(20, 20)
$hostTitle.Size = New-Object System.Drawing.Size(500, 28)
$hostTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$hostPanel.Controls.Add($hostTitle)
$ui.HostTitleLabel = $hostTitle

$hostHealthLabel = New-Object System.Windows.Forms.Label
$hostHealthLabel.Location = New-Object System.Drawing.Point(20, 80)
$hostHealthLabel.Size = New-Object System.Drawing.Size(180, 20)
$hostPanel.Controls.Add($hostHealthLabel)
$ui.HostHealthLabel = $hostHealthLabel

$hostHealthCombo = New-Object System.Windows.Forms.ComboBox
$hostHealthCombo.Location = New-Object System.Drawing.Point(220, 76)
$hostHealthCombo.Size = New-Object System.Drawing.Size(220, 24)
$hostHealthCombo.DropDownStyle = 'DropDownList'
[void]$hostHealthCombo.Items.AddRange(@('off', 'conservador', 'equilibrado', 'agressivo'))
$hostPanel.Controls.Add($hostHealthCombo)
$ui.HostHealthCombo = $hostHealthCombo

$steamDeckVersionLabel = New-Object System.Windows.Forms.Label
$steamDeckVersionLabel.Location = New-Object System.Drawing.Point(20, 124)
$steamDeckVersionLabel.Size = New-Object System.Drawing.Size(180, 20)
$hostPanel.Controls.Add($steamDeckVersionLabel)
$ui.SteamDeckVersionLabel = $steamDeckVersionLabel

$steamDeckVersionCombo = New-Object System.Windows.Forms.ComboBox
$steamDeckVersionCombo.Location = New-Object System.Drawing.Point(220, 120)
$steamDeckVersionCombo.Size = New-Object System.Drawing.Size(220, 24)
$steamDeckVersionCombo.DropDownStyle = 'DropDownList'
[void]$steamDeckVersionCombo.Items.AddRange(@('Auto', 'LCD', 'OLED'))
$hostPanel.Controls.Add($steamDeckVersionCombo)
$ui.SteamDeckVersionCombo = $steamDeckVersionCombo

$workspaceRootLabel = New-Object System.Windows.Forms.Label
$workspaceRootLabel.Location = New-Object System.Drawing.Point(20, 168)
$workspaceRootLabel.Size = New-Object System.Drawing.Size(180, 20)
$hostPanel.Controls.Add($workspaceRootLabel)
$ui.WorkspaceRootLabel = $workspaceRootLabel

$workspaceRootTextBox = New-Object System.Windows.Forms.TextBox
$workspaceRootTextBox.Location = New-Object System.Drawing.Point(220, 164)
$workspaceRootTextBox.Size = New-Object System.Drawing.Size(620, 24)
$hostPanel.Controls.Add($workspaceRootTextBox)
$ui.WorkspaceRootTextBox = $workspaceRootTextBox

$workspaceBrowseButton = New-Object System.Windows.Forms.Button
$workspaceBrowseButton.Location = New-Object System.Drawing.Point(860, 162)
$workspaceBrowseButton.Size = New-Object System.Drawing.Size(120, 28)
$hostPanel.Controls.Add($workspaceBrowseButton)
$ui.WorkspaceBrowseButton = $workspaceBrowseButton

$cloneBaseDirLabel = New-Object System.Windows.Forms.Label
$cloneBaseDirLabel.Location = New-Object System.Drawing.Point(20, 212)
$cloneBaseDirLabel.Size = New-Object System.Drawing.Size(180, 20)
$hostPanel.Controls.Add($cloneBaseDirLabel)
$ui.CloneBaseDirLabel = $cloneBaseDirLabel

$cloneBaseDirTextBox = New-Object System.Windows.Forms.TextBox
$cloneBaseDirTextBox.Location = New-Object System.Drawing.Point(220, 208)
$cloneBaseDirTextBox.Size = New-Object System.Drawing.Size(620, 24)
$hostPanel.Controls.Add($cloneBaseDirTextBox)
$ui.CloneBaseDirTextBox = $cloneBaseDirTextBox

$cloneBrowseButton = New-Object System.Windows.Forms.Button
$cloneBrowseButton.Location = New-Object System.Drawing.Point(860, 206)
$cloneBrowseButton.Size = New-Object System.Drawing.Size(120, 28)
$hostPanel.Controls.Add($cloneBrowseButton)
$ui.CloneBrowseButton = $cloneBrowseButton

$adminNeedsLabel = New-Object System.Windows.Forms.Label
$adminNeedsLabel.Location = New-Object System.Drawing.Point(20, 270)
$adminNeedsLabel.Size = New-Object System.Drawing.Size(300, 20)
$hostPanel.Controls.Add($adminNeedsLabel)
$ui.AdminNeedsTitleLabel = $adminNeedsLabel

$adminNeedsTextBox = New-Object System.Windows.Forms.TextBox
$adminNeedsTextBox.Location = New-Object System.Drawing.Point(20, 298)
$adminNeedsTextBox.Size = New-Object System.Drawing.Size(960, 200)
$adminNeedsTextBox.Multiline = $true
$adminNeedsTextBox.ReadOnly = $true
$adminNeedsTextBox.ScrollBars = 'Vertical'
$hostPanel.Controls.Add($adminNeedsTextBox)
$ui.AdminNeedsTextBox = $adminNeedsTextBox

# Steam Deck control page
$steamDeckPanel = $pages['steamdeck-control']
$steamDeckTitle = New-Object System.Windows.Forms.Label
$steamDeckTitle.Location = New-Object System.Drawing.Point(20, 20)
$steamDeckTitle.Size = New-Object System.Drawing.Size(520, 28)
$steamDeckTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$steamDeckPanel.Controls.Add($steamDeckTitle)
$ui.SteamDeckTitleLabel = $steamDeckTitle

$monitorProfilesLabel = New-Object System.Windows.Forms.Label
$monitorProfilesLabel.Location = New-Object System.Drawing.Point(20, 64)
$monitorProfilesLabel.Size = New-Object System.Drawing.Size(220, 20)
$steamDeckPanel.Controls.Add($monitorProfilesLabel)
$ui.MonitorProfilesLabel = $monitorProfilesLabel

$monitorProfilesGrid = New-Object System.Windows.Forms.DataGridView
$monitorProfilesGrid.Location = New-Object System.Drawing.Point(20, 90)
$monitorProfilesGrid.Size = New-Object System.Drawing.Size(500, 180)
$monitorProfilesGrid.AllowUserToAddRows = $true
$monitorProfilesGrid.AllowUserToDeleteRows = $true
$monitorProfilesGrid.RowHeadersVisible = $false
[void]$monitorProfilesGrid.Columns.Add('manufacturer', 'manufacturer')
[void]$monitorProfilesGrid.Columns.Add('product', 'product')
[void]$monitorProfilesGrid.Columns.Add('serial', 'serial')
[void]$monitorProfilesGrid.Columns.Add('mode', 'mode')
[void]$monitorProfilesGrid.Columns.Add('layout', 'layout')
[void]$monitorProfilesGrid.Columns.Add('resolutionPolicy', 'resolutionPolicy')
$steamDeckPanel.Controls.Add($monitorProfilesGrid)
$ui.MonitorProfilesGrid = $monitorProfilesGrid

$monitorFamiliesLabel = New-Object System.Windows.Forms.Label
$monitorFamiliesLabel.Location = New-Object System.Drawing.Point(540, 64)
$monitorFamiliesLabel.Size = New-Object System.Drawing.Size(220, 20)
$steamDeckPanel.Controls.Add($monitorFamiliesLabel)
$ui.MonitorFamiliesLabel = $monitorFamiliesLabel

$monitorFamiliesGrid = New-Object System.Windows.Forms.DataGridView
$monitorFamiliesGrid.Location = New-Object System.Drawing.Point(540, 90)
$monitorFamiliesGrid.Size = New-Object System.Drawing.Size(500, 180)
$monitorFamiliesGrid.AllowUserToAddRows = $true
$monitorFamiliesGrid.AllowUserToDeleteRows = $true
$monitorFamiliesGrid.RowHeadersVisible = $false
[void]$monitorFamiliesGrid.Columns.Add('manufacturer', 'manufacturer')
[void]$monitorFamiliesGrid.Columns.Add('product', 'product')
[void]$monitorFamiliesGrid.Columns.Add('namePattern', 'namePattern')
[void]$monitorFamiliesGrid.Columns.Add('mode', 'mode')
[void]$monitorFamiliesGrid.Columns.Add('layout', 'layout')
[void]$monitorFamiliesGrid.Columns.Add('resolutionPolicy', 'resolutionPolicy')
$steamDeckPanel.Controls.Add($monitorFamiliesGrid)
$ui.MonitorFamiliesGrid = $monitorFamiliesGrid

$genericGroup = New-Object System.Windows.Forms.GroupBox
$genericGroup.Location = New-Object System.Drawing.Point(20, 290)
$genericGroup.Size = New-Object System.Drawing.Size(500, 150)
$steamDeckPanel.Controls.Add($genericGroup)
$ui.GenericGroup = $genericGroup

$genericModeLabel = New-Object System.Windows.Forms.Label
$genericModeLabel.Location = New-Object System.Drawing.Point(20, 30)
$genericModeLabel.Size = New-Object System.Drawing.Size(120, 20)
$genericGroup.Controls.Add($genericModeLabel)
$ui.GenericModeLabel = $genericModeLabel

$genericModeCombo = New-Object System.Windows.Forms.ComboBox
$genericModeCombo.Location = New-Object System.Drawing.Point(180, 26)
$genericModeCombo.Size = New-Object System.Drawing.Size(260, 24)
$genericModeCombo.DropDownStyle = 'DropDownList'
[void]$genericModeCombo.Items.AddRange(@('DOCKED_TV', 'DOCKED_MONITOR'))
$genericGroup.Controls.Add($genericModeCombo)
$ui.GenericModeCombo = $genericModeCombo

$genericLayoutLabel = New-Object System.Windows.Forms.Label
$genericLayoutLabel.Location = New-Object System.Drawing.Point(20, 66)
$genericLayoutLabel.Size = New-Object System.Drawing.Size(120, 20)
$genericGroup.Controls.Add($genericLayoutLabel)
$ui.GenericLayoutLabel = $genericLayoutLabel

$genericLayoutTextBox = New-Object System.Windows.Forms.TextBox
$genericLayoutTextBox.Location = New-Object System.Drawing.Point(180, 62)
$genericLayoutTextBox.Size = New-Object System.Drawing.Size(260, 24)
$genericGroup.Controls.Add($genericLayoutTextBox)
$ui.GenericLayoutTextBox = $genericLayoutTextBox

$genericResolutionLabel = New-Object System.Windows.Forms.Label
$genericResolutionLabel.Location = New-Object System.Drawing.Point(20, 102)
$genericResolutionLabel.Size = New-Object System.Drawing.Size(140, 20)
$genericGroup.Controls.Add($genericResolutionLabel)
$ui.GenericResolutionLabel = $genericResolutionLabel

$genericResolutionTextBox = New-Object System.Windows.Forms.TextBox
$genericResolutionTextBox.Location = New-Object System.Drawing.Point(180, 98)
$genericResolutionTextBox.Size = New-Object System.Drawing.Size(260, 24)
$genericGroup.Controls.Add($genericResolutionTextBox)
$ui.GenericResolutionTextBox = $genericResolutionTextBox

$sessionGroup = New-Object System.Windows.Forms.GroupBox
$sessionGroup.Location = New-Object System.Drawing.Point(540, 290)
$sessionGroup.Size = New-Object System.Drawing.Size(500, 150)
$steamDeckPanel.Controls.Add($sessionGroup)
$ui.SessionGroup = $sessionGroup

$handheldSessionLabel = New-Object System.Windows.Forms.Label
$handheldSessionLabel.Location = New-Object System.Drawing.Point(20, 30)
$handheldSessionLabel.Size = New-Object System.Drawing.Size(140, 20)
$sessionGroup.Controls.Add($handheldSessionLabel)
$ui.HandheldSessionLabel = $handheldSessionLabel

$handheldSessionTextBox = New-Object System.Windows.Forms.TextBox
$handheldSessionTextBox.Location = New-Object System.Drawing.Point(180, 26)
$handheldSessionTextBox.Size = New-Object System.Drawing.Size(260, 24)
$sessionGroup.Controls.Add($handheldSessionTextBox)
$ui.HandheldSessionTextBox = $handheldSessionTextBox

$dockTvSessionLabel = New-Object System.Windows.Forms.Label
$dockTvSessionLabel.Location = New-Object System.Drawing.Point(20, 66)
$dockTvSessionLabel.Size = New-Object System.Drawing.Size(140, 20)
$sessionGroup.Controls.Add($dockTvSessionLabel)
$ui.DockTvSessionLabel = $dockTvSessionLabel

$dockTvSessionTextBox = New-Object System.Windows.Forms.TextBox
$dockTvSessionTextBox.Location = New-Object System.Drawing.Point(180, 62)
$dockTvSessionTextBox.Size = New-Object System.Drawing.Size(260, 24)
$sessionGroup.Controls.Add($dockTvSessionTextBox)
$ui.DockTvSessionTextBox = $dockTvSessionTextBox

$dockMonitorSessionLabel = New-Object System.Windows.Forms.Label
$dockMonitorSessionLabel.Location = New-Object System.Drawing.Point(20, 102)
$dockMonitorSessionLabel.Size = New-Object System.Drawing.Size(140, 20)
$sessionGroup.Controls.Add($dockMonitorSessionLabel)
$ui.DockMonitorSessionLabel = $dockMonitorSessionLabel

$dockMonitorSessionTextBox = New-Object System.Windows.Forms.TextBox
$dockMonitorSessionTextBox.Location = New-Object System.Drawing.Point(180, 98)
$dockMonitorSessionTextBox.Size = New-Object System.Drawing.Size(260, 24)
$sessionGroup.Controls.Add($dockMonitorSessionTextBox)
$ui.DockMonitorSessionTextBox = $dockMonitorSessionTextBox

$watcherStatusLabel = New-Object System.Windows.Forms.Label
$watcherStatusLabel.Location = New-Object System.Drawing.Point(20, 462)
$watcherStatusLabel.Size = New-Object System.Drawing.Size(1020, 44)
$steamDeckPanel.Controls.Add($watcherStatusLabel)
$ui.WatcherStatusLabel = $watcherStatusLabel

$unknownMonitorHintLabel = New-Object System.Windows.Forms.Label
$unknownMonitorHintLabel.Location = New-Object System.Drawing.Point(20, 512)
$unknownMonitorHintLabel.Size = New-Object System.Drawing.Size(900, 20)
$steamDeckPanel.Controls.Add($unknownMonitorHintLabel)
$ui.UnknownMonitorHintLabel = $unknownMonitorHintLabel

$reloadSettingsButton = New-Object System.Windows.Forms.Button
$reloadSettingsButton.Location = New-Object System.Drawing.Point(700, 548)
$reloadSettingsButton.Size = New-Object System.Drawing.Size(160, 30)
$steamDeckPanel.Controls.Add($reloadSettingsButton)
$ui.ReloadSettingsButton = $reloadSettingsButton

$saveSettingsButton = New-Object System.Windows.Forms.Button
$saveSettingsButton.Location = New-Object System.Drawing.Point(880, 548)
$saveSettingsButton.Size = New-Object System.Drawing.Size(160, 30)
$steamDeckPanel.Controls.Add($saveSettingsButton)
$ui.SaveSettingsButton = $saveSettingsButton

# Review page
$reviewPanel = $pages['review']
$reviewTitle = New-Object System.Windows.Forms.Label
$reviewTitle.Location = New-Object System.Drawing.Point(20, 20)
$reviewTitle.Size = New-Object System.Drawing.Size(500, 28)
$reviewTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$reviewPanel.Controls.Add($reviewTitle)
$ui.ReviewTitleLabel = $reviewTitle

$reviewSummaryLabel = New-Object System.Windows.Forms.Label
$reviewSummaryLabel.Location = New-Object System.Drawing.Point(20, 56)
$reviewSummaryLabel.Size = New-Object System.Drawing.Size(760, 20)
$reviewPanel.Controls.Add($reviewSummaryLabel)
$ui.ReviewSummaryLabel = $reviewSummaryLabel

$refreshReviewButton = New-Object System.Windows.Forms.Button
$refreshReviewButton.Location = New-Object System.Drawing.Point(820, 50)
$refreshReviewButton.Size = New-Object System.Drawing.Size(200, 30)
$reviewPanel.Controls.Add($refreshReviewButton)
$ui.RefreshReviewButton = $refreshReviewButton

$reviewMetaLabel = New-Object System.Windows.Forms.Label
$reviewMetaLabel.Location = New-Object System.Drawing.Point(20, 92)
$reviewMetaLabel.Size = New-Object System.Drawing.Size(1000, 48)
$reviewPanel.Controls.Add($reviewMetaLabel)
$ui.ReviewMetaLabel = $reviewMetaLabel

$reviewTextBox = New-Object System.Windows.Forms.TextBox
$reviewTextBox.Location = New-Object System.Drawing.Point(20, 150)
$reviewTextBox.Size = New-Object System.Drawing.Size(1000, 430)
$reviewTextBox.Multiline = $true
$reviewTextBox.ReadOnly = $true
$reviewTextBox.ScrollBars = 'Vertical'
$reviewPanel.Controls.Add($reviewTextBox)
$ui.ReviewTextBox = $reviewTextBox

# Run page
$runPanel = $pages['run']
$runTitle = New-Object System.Windows.Forms.Label
$runTitle.Location = New-Object System.Drawing.Point(20, 20)
$runTitle.Size = New-Object System.Drawing.Size(500, 28)
$runTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$runPanel.Controls.Add($runTitle)
$ui.RunTitleLabel = $runTitle

$runStatusLabel = New-Object System.Windows.Forms.Label
$runStatusLabel.Location = New-Object System.Drawing.Point(20, 58)
$runStatusLabel.Size = New-Object System.Drawing.Size(760, 20)
$runPanel.Controls.Add($runStatusLabel)
$ui.RunStatusLabel = $runStatusLabel

$startRunButton = New-Object System.Windows.Forms.Button
$startRunButton.Location = New-Object System.Drawing.Point(800, 50)
$startRunButton.Size = New-Object System.Drawing.Size(220, 32)
$runPanel.Controls.Add($startRunButton)
$ui.StartRunButton = $startRunButton

$openLogButton = New-Object System.Windows.Forms.Button
$openLogButton.Location = New-Object System.Drawing.Point(20, 100)
$openLogButton.Size = New-Object System.Drawing.Size(120, 28)
$runPanel.Controls.Add($openLogButton)
$ui.OpenLogButton = $openLogButton

$openResultButton = New-Object System.Windows.Forms.Button
$openResultButton.Location = New-Object System.Drawing.Point(160, 100)
$openResultButton.Size = New-Object System.Drawing.Size(120, 28)
$runPanel.Controls.Add($openResultButton)
$ui.OpenResultButton = $openResultButton

$openSettingsButton = New-Object System.Windows.Forms.Button
$openSettingsButton.Location = New-Object System.Drawing.Point(300, 100)
$openSettingsButton.Size = New-Object System.Drawing.Size(120, 28)
$runPanel.Controls.Add($openSettingsButton)
$ui.OpenSettingsButton = $openSettingsButton

$openReportsButton = New-Object System.Windows.Forms.Button
$openReportsButton.Location = New-Object System.Drawing.Point(440, 100)
$openReportsButton.Size = New-Object System.Drawing.Size(120, 28)
$runPanel.Controls.Add($openReportsButton)
$ui.OpenReportsButton = $openReportsButton

$runLogTextBox = New-Object System.Windows.Forms.TextBox
$runLogTextBox.Location = New-Object System.Drawing.Point(20, 150)
$runLogTextBox.Size = New-Object System.Drawing.Size(1000, 470)
$runLogTextBox.Multiline = $true
$runLogTextBox.ReadOnly = $true
$runLogTextBox.ScrollBars = 'Vertical'
$runPanel.Controls.Add($runLogTextBox)
$ui.RunLogTextBox = $runLogTextBox

function Apply-QuickPreset {
    param([Parameter(Mandatory = $true)][string]$PresetName)

    $ui.State.selectedProfiles = @($PresetName)
    $ui.State.selectedComponents = @()
    $ui.State.excludedComponents = @()
    $ui.State.hostHealth = if ($PresetName -eq 'legacy') { 'off' } else { 'conservador' }
    $ui.State.steamDeckVersion = 'Auto'
}

function Refresh-CustomPresets {
    $ui.CustomPresetCombo.Items.Clear()
    foreach ($presetName in @($ui.State.customPresets.Keys | Sort-Object)) {
        [void]$ui.CustomPresetCombo.Items.Add($presetName)
    }
}

function Refresh-LocalizedText {
    $ui.Strings = Get-UiStrings -Language ([string]$ui.State.language)
    $form.Text = $ui.Strings.WindowTitle
    $ui.HeaderLabel.Text = $ui.Strings.WindowTitle
    $ui.WelcomeTitleLabel.Text = $ui.Strings.WelcomeTitle
    $ui.WelcomeSubtitleLabel.Text = $ui.Strings.WelcomeSubtitle
    $ui.LanguageLabel.Text = $ui.Strings.Language
    $ui.QuickPresetsGroup.Text = $ui.Strings.QuickPresets
    $ui.CustomPresetGroup.Text = $ui.Strings.CustomPresets
    $ui.PresetNameLabel.Text = $ui.Strings.PresetName
    $ui.SavePresetButton.Text = $ui.Strings.SavePreset
    $ui.LoadPresetButton.Text = $ui.Strings.LoadPreset
    $ui.DeletePresetButton.Text = $ui.Strings.DeletePreset
    $ui.SelectionTitleLabel.Text = $ui.Strings.SelectionTitle
    $ui.FilterLabel.Text = $ui.Strings.Filter
    $ui.ProfilesLabel.Text = $ui.Strings.Profiles
    $ui.ComponentsLabel.Text = $ui.Strings.Components
    $ui.ExcludeLabel.Text = $ui.Strings.Excludes
    $ui.DetailsLabel.Text = $ui.Strings.SelectionDetails
    $ui.HostTitleLabel.Text = $ui.Strings.HostSetupTitle
    $ui.HostHealthLabel.Text = $ui.Strings.HostHealth
    $ui.SteamDeckVersionLabel.Text = $ui.Strings.SteamDeckVersion
    $ui.WorkspaceRootLabel.Text = $ui.Strings.WorkspaceRoot
    $ui.CloneBaseDirLabel.Text = $ui.Strings.CloneBaseDir
    $ui.WorkspaceBrowseButton.Text = $ui.Strings.Browse
    $ui.CloneBrowseButton.Text = $ui.Strings.Browse
    $ui.AdminNeedsTitleLabel.Text = $ui.Strings.AdminNeeds
    $ui.SteamDeckTitleLabel.Text = $ui.Strings.SteamDeckCenterTitle
    $ui.MonitorProfilesLabel.Text = $ui.Strings.MonitorProfiles
    $ui.MonitorFamiliesLabel.Text = $ui.Strings.MonitorFamilies
    $ui.GenericGroup.Text = $ui.Strings.GenericExternal
    $ui.SessionGroup.Text = $ui.Strings.SessionProfiles
    $ui.UnknownMonitorHintLabel.Text = $ui.Strings.UnknownMonitorHint
    $ui.GenericModeLabel.Text = $ui.Strings.GenericMode
    $ui.GenericLayoutLabel.Text = $ui.Strings.GenericLayout
    $ui.GenericResolutionLabel.Text = $ui.Strings.GenericResolution
    $ui.HandheldSessionLabel.Text = $ui.Strings.SessionHandheld
    $ui.DockTvSessionLabel.Text = $ui.Strings.SessionDockedTv
    $ui.DockMonitorSessionLabel.Text = $ui.Strings.SessionDockedMonitor
    $ui.SaveSettingsButton.Text = $ui.Strings.SaveSettings
    $ui.ReloadSettingsButton.Text = $ui.Strings.ReloadSettings
    $ui.ReviewTitleLabel.Text = $ui.Strings.ReviewTitle
    $ui.ReviewSummaryLabel.Text = $ui.Strings.ReviewSummary
    $ui.RefreshReviewButton.Text = $ui.Strings.RefreshReview
    $ui.RunTitleLabel.Text = $ui.Strings.RunTitle
    $ui.StartRunButton.Text = $ui.Strings.StartRun
    $ui.OpenLogButton.Text = $ui.Strings.OpenLog
    $ui.OpenResultButton.Text = $ui.Strings.OpenResult
    $ui.OpenSettingsButton.Text = $ui.Strings.OpenSettings
    $ui.OpenReportsButton.Text = $ui.Strings.OpenReports
    $ui.BackButton.Text = $ui.Strings.Back
    $ui.NextButton.Text = $ui.Strings.Next
    $ui.FinishButton.Text = $ui.Strings.Finish
    $ui.StatusLabel.Text = $ui.Strings.IdleStatus
}

function Refresh-SelectionTrees {
    $filter = ($ui.FilterTextBox.Text).Trim().ToLowerInvariant()
    $ui.SuppressSelectionEvents = $true
    try {
        $ui.ProfilesTree.Nodes.Clear()
        foreach ($profile in @($ui.Contract.profiles | Where-Object {
            ($filter -eq '') -or ($_.name.ToLowerInvariant().Contains($filter)) -or ($_.description.ToLowerInvariant().Contains($filter))
        })) {
            $node = New-Object System.Windows.Forms.TreeNode($profile.name)
            $node.Name = $profile.name
            $node.Tag = @{ kind = 'profile'; item = $profile }
            $node.Checked = @($ui.State.selectedProfiles) -contains $profile.name
            [void]$ui.ProfilesTree.Nodes.Add($node)
        }

        $ui.ComponentsTree.Nodes.Clear()
        foreach ($component in @($ui.Contract.components | Where-Object {
            ($filter -eq '') -or ($_.name.ToLowerInvariant().Contains($filter)) -or ($_.description.ToLowerInvariant().Contains($filter))
        })) {
            $node = New-Object System.Windows.Forms.TreeNode($component.name)
            $node.Name = $component.name
            $node.Tag = @{ kind = 'component'; item = $component }
            $node.Checked = @($ui.State.selectedComponents) -contains $component.name
            [void]$ui.ComponentsTree.Nodes.Add($node)
        }
    } finally {
        $ui.SuppressSelectionEvents = $false
    }
}

function Refresh-ExcludeList {
    $ui.ExcludeList.Items.Clear()
    try {
        $selection = New-BootstrapSelectionObject -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents @() -SelectedHostHealth $ui.State.hostHealth
        $baseResolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents @()
        foreach ($componentName in @($baseResolution.ResolvedComponents)) {
            [void]$ui.ExcludeList.Items.Add($componentName, (@($ui.State.excludedComponents) -contains $componentName))
        }
    } catch {
    }
}

function Refresh-SelectionSummary {
    Refresh-ExcludeList
    try {
        $ui.Preview = Get-BootstrapPreviewData -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents $ui.State.excludedComponents -RequestedSteamDeckVersion $ui.State.steamDeckVersion -RequestedHostHealthMode $ui.State.hostHealth -RequestedWorkspaceRoot $ui.State.workspaceRoot -ExplicitCloneBaseDir $ui.State.cloneBaseDir
        $ui.SelectionSummaryLabel.Text = "Resolved components: $(@($ui.Preview.Resolution.ResolvedComponents).Count) | HostHealth: $($ui.Preview.ResolvedHostHealthMode)"
        $ui.SelectionErrorLabel.Text = ''
    } catch {
        $ui.Preview = $null
        $ui.SelectionSummaryLabel.Text = ''
        $ui.SelectionErrorLabel.Text = $_.Exception.Message
    }
}

function Refresh-HostSetupControls {
    $ui.HostHealthCombo.SelectedItem = [string]$ui.State.hostHealth
    $ui.SteamDeckVersionCombo.SelectedItem = [string]$ui.State.steamDeckVersion
    $ui.WorkspaceRootTextBox.Text = [string]$ui.State.workspaceRoot
    $ui.CloneBaseDirTextBox.Text = [string]$ui.State.cloneBaseDir
    $ui.AdminNeedsTextBox.Text = if ($ui.Preview -and @($ui.Preview.AdminReasons).Count -gt 0) { @($ui.Preview.AdminReasons) -join [Environment]::NewLine } else { '-' }
}

function Refresh-SteamDeckStatus {
    $automationRoot = Get-BootstrapSteamDeckAutomationRoot
    $taskStatus = 'not found'
    try {
        $task = Get-ScheduledTask -TaskName 'BootstrapTools-SteamDeckModeWatcher' -ErrorAction Stop
        if ($task) { $taskStatus = 'registered' }
    } catch {
        $taskStatus = 'not found'
    }
    $watcherExists = Test-Path (Join-Path $automationRoot 'ModeWatcher.ps1')
    $hotkeyExists = Test-Path (Join-Path $automationRoot 'SteamDeckHotkeys.ahk')
    $ui.WatcherStatusLabel.Text = "Task: $taskStatus | ModeWatcher: $watcherExists | Hotkeys: $hotkeyExists | Settings: $($ui.SettingsBundle.Path)"
}

function Refresh-SteamDeckControls {
    $ui.SettingsBundle = Get-BootstrapSteamDeckSettingsData -RequestedSteamDeckVersion ([string]$ui.State.steamDeckVersion) -ResolvedSteamDeckVersion 'lcd'
    $settings = ConvertTo-BootstrapHashtable -InputObject $ui.SettingsBundle.Data
    Load-GridRows -Grid $ui.MonitorProfilesGrid -Items @($settings.monitorProfiles) -Columns @('manufacturer', 'product', 'serial', 'mode', 'layout', 'resolutionPolicy')
    Load-GridRows -Grid $ui.MonitorFamiliesGrid -Items @($settings.monitorFamilies) -Columns @('manufacturer', 'product', 'namePattern', 'mode', 'layout', 'resolutionPolicy')
    $ui.GenericModeCombo.SelectedItem = [string]$settings.genericExternal.mode
    $ui.GenericLayoutTextBox.Text = [string]$settings.genericExternal.layout
    $ui.GenericResolutionTextBox.Text = [string]$settings.genericExternal.resolutionPolicy
    $ui.HandheldSessionTextBox.Text = [string]$settings.sessionProfiles.HANDHELD
    $ui.DockTvSessionTextBox.Text = [string]$settings.sessionProfiles.DOCKED_TV
    $ui.DockMonitorSessionTextBox.Text = [string]$settings.sessionProfiles.DOCKED_MONITOR
    Refresh-SteamDeckStatus
}

function Capture-SteamDeckSettingsFromControls {
    $settings = ConvertTo-BootstrapHashtable -InputObject $ui.SettingsBundle.Data
    $settings['monitorProfiles'] = @(Read-GridRows -Grid $ui.MonitorProfilesGrid -Columns @('manufacturer', 'product', 'serial', 'mode', 'layout', 'resolutionPolicy'))
    $settings['monitorFamilies'] = @(Read-GridRows -Grid $ui.MonitorFamiliesGrid -Columns @('manufacturer', 'product', 'namePattern', 'mode', 'layout', 'resolutionPolicy'))
    $settings['genericExternal'] = @{
        mode = if ($ui.GenericModeCombo.SelectedItem) { [string]$ui.GenericModeCombo.SelectedItem } else { 'DOCKED_TV' }
        layout = $ui.GenericLayoutTextBox.Text.Trim()
        resolutionPolicy = $ui.GenericResolutionTextBox.Text.Trim()
    }
    $settings['sessionProfiles'] = @{
        HANDHELD = $ui.HandheldSessionTextBox.Text.Trim()
        DOCKED_TV = $ui.DockTvSessionTextBox.Text.Trim()
        DOCKED_MONITOR = $ui.DockMonitorSessionTextBox.Text.Trim()
    }
    $settings['steamDeckVersion'] = [string]$ui.State.steamDeckVersion
    $ui.SettingsBundle = @{
        Path = $ui.SettingsBundle.Path
        Data = $settings
    }
}

function Save-SteamDeckSettingsInteractive {
    Capture-SteamDeckSettingsFromControls
    $saveResult = Save-BootstrapSteamDeckSettingsData -Settings $ui.SettingsBundle.Data -CreateBackup
    $ui.SettingsBackupPath = $saveResult.BackupPath
    $ui.State.lastSettingsPath = $saveResult.Path
    Save-UiState -State $ui.State -Path $UiStatePath
    $ui.StatusLabel.Text = $ui.Strings.SavingSettings
    Refresh-SteamDeckStatus
}

function Refresh-ReviewPage {
    Capture-SteamDeckSettingsFromControls
    $ui.Preview = Get-BootstrapPreviewData -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents $ui.State.excludedComponents -RequestedSteamDeckVersion $ui.State.steamDeckVersion -RequestedHostHealthMode $ui.State.hostHealth -RequestedWorkspaceRoot $ui.State.workspaceRoot -ExplicitCloneBaseDir $ui.State.cloneBaseDir
    $ui.ReviewTextBox.Text = $ui.Preview.PlanText
    $adminText = if (@($ui.Preview.AdminReasons).Count -gt 0) { @($ui.Preview.AdminReasons) -join '; ' } else { '-' }
    $ui.ReviewMetaLabel.Text = "Admin: $adminText`r`nSettings: $($ui.SettingsBundle.Path) | UI state: $UiStatePath"
}

function Update-PageVisibility {
    $pageIds = @(Get-UiPageIds)
    for ($i = 0; $i -lt $pageIds.Count; $i++) {
        $ui.Pages[$pageIds[$i]].Visible = ($i -eq $ui.CurrentPageIndex)
    }

    $currentPageId = $pageIds[$ui.CurrentPageIndex]
    $stepName = switch ($currentPageId) {
        'welcome' { $ui.Strings.Welcome }
        'selection' { $ui.Strings.Selection }
        'host-setup' { $ui.Strings.HostSetup }
        'steamdeck-control' { $ui.Strings.SteamDeckControl }
        'review' { $ui.Strings.Review }
        default { $ui.Strings.Run }
    }
    $ui.StepLabel.Text = "{0} / {1} - {2}" -f ($ui.CurrentPageIndex + 1), $pageIds.Count, $stepName
    $ui.BackButton.Enabled = ($ui.CurrentPageIndex -gt 0)
    $ui.NextButton.Enabled = ($ui.CurrentPageIndex -lt ($pageIds.Count - 1))
    $ui.FinishButton.Enabled = $true

    switch ($currentPageId) {
        'selection' {
            Refresh-SelectionTrees
            Refresh-SelectionSummary
        }
        'host-setup' {
            Refresh-SelectionSummary
            Refresh-HostSetupControls
        }
        'steamdeck-control' {
            Refresh-SteamDeckControls
        }
        'review' {
            Refresh-ReviewPage
            Refresh-HostSetupControls
        }
    }
}

function Build-BackendArguments {
    $tokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backendScriptPath)
    foreach ($profile in @($ui.State.selectedProfiles)) { $tokens += @('-Profile', [string]$profile) }
    foreach ($component in @($ui.State.selectedComponents)) { $tokens += @('-Component', [string]$component) }
    foreach ($excluded in @($ui.State.excludedComponents)) { $tokens += @('-Exclude', [string]$excluded) }
    $tokens += @('-SteamDeckVersion', [string]$ui.State.steamDeckVersion)
    $tokens += @('-HostHealth', [string]$ui.State.hostHealth)
    $tokens += @('-WorkspaceRoot', [string]$ui.State.workspaceRoot)
    $tokens += @('-CloneBaseDir', [string]$ui.State.cloneBaseDir)
    $tokens += @('-LogPath', [string]$ui.CurrentLogPath)
    $tokens += @('-ResultPath', [string]$ui.CurrentResultPath)
    return $tokens
}

function Start-BackendWorker {
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentString = ConvertTo-ArgumentString -Tokens (Build-BackendArguments)
    $needsAdmin = ($ui.Preview -and @($ui.Preview.AdminReasons).Count -gt 0 -and -not (Test-IsAdmin))
    if ($needsAdmin) {
        return (Start-Process -FilePath $powershellExe -ArgumentList $argumentString -Verb RunAs -WindowStyle Hidden -PassThru)
    }
    return (Start-Process -FilePath $powershellExe -ArgumentList $argumentString -WindowStyle Hidden -PassThru)
}

function Append-RunLog {
    if ([string]::IsNullOrWhiteSpace($ui.CurrentLogPath) -or -not (Test-Path $ui.CurrentLogPath)) { return }
    $content = [IO.File]::ReadAllText($ui.CurrentLogPath)
    if ($content.Length -le $ui.LogOffset) { return }
    $ui.RunLogTextBox.AppendText($content.Substring($ui.LogOffset))
    $ui.LogOffset = $content.Length
}

function Finalize-RunFromResult {
    Append-RunLog
    if (-not (Test-Path $ui.CurrentResultPath)) { return }
    $result = Get-Content -Path $ui.CurrentResultPath -Raw | ConvertFrom-Json
    if ($result.status -eq 'success') {
        $ui.RunStatusLabel.Text = $ui.Strings.RunCompleted
        if ($result.hostHealthReportRoot) {
            $ui.State.lastReportPath = [string]$result.hostHealthReportRoot
        }
    } else {
        $ui.RunStatusLabel.Text = "{0} {1}" -f $ui.Strings.RunFailed, [string]$result.error
    }

    $ui.State.lastLogPath = $ui.CurrentLogPath
    $ui.State.lastResultPath = $ui.CurrentResultPath
    Save-UiState -State $ui.State -Path $UiStatePath
    $ui.RunProcess = $null
    $ui.LogTimer.Stop()
}

function Start-RunExecution {
    Save-SteamDeckSettingsInteractive
    Refresh-ReviewPage

    $runRoot = Join-Path (Get-BootstrapDataRoot) 'ui-runs'
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $ui.CurrentLogPath = Join-Path $runRoot ("bootstrap-ui_{0}.log" -f $timestamp)
    $ui.CurrentResultPath = Join-Path $runRoot ("bootstrap-ui_{0}.result.json" -f $timestamp)
    $ui.LogOffset = 0
    $ui.RunLogTextBox.Clear()
    $ui.RunStatusLabel.Text = $ui.Strings.RunStarted

    try {
        $ui.RunProcess = Start-BackendWorker
    } catch {
        $ui.RunStatusLabel.Text = $ui.Strings.UserCanceledElevation
        return
    }

    Save-UiState -State $ui.State -Path $UiStatePath
    $ui.LogTimer.Start()
}

$logTimer.Add_Tick({
    Append-RunLog
    if ($ui.RunProcess -and $ui.RunProcess.HasExited -and (Test-Path $ui.CurrentResultPath)) {
        Finalize-RunFromResult
    }
})

$languageCombo.Add_SelectedIndexChanged({
    if ($ui.LanguageCombo.SelectedItem) {
        $ui.State.language = [string]$ui.LanguageCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-LocalizedText
        Update-PageVisibility
    }
})

foreach ($presetButton in @($ui.PresetButtons.Values)) {
    $presetButton.Add_Click({
        Apply-QuickPreset -PresetName ([string]$this.Tag)
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-SelectionTrees
        Refresh-SelectionSummary
        Refresh-HostSetupControls
        $ui.StatusLabel.Text = "Preset: $($this.Tag)"
    })
}

$savePresetButton.Add_Click({
    $presetName = $ui.PresetNameTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($presetName)) { return }
    $ui.State.customPresets[$presetName] = @{
        selectedProfiles = @($ui.State.selectedProfiles)
        selectedComponents = @($ui.State.selectedComponents)
        excludedComponents = @($ui.State.excludedComponents)
        hostHealth = [string]$ui.State.hostHealth
        steamDeckVersion = [string]$ui.State.steamDeckVersion
        workspaceRoot = [string]$ui.State.workspaceRoot
        cloneBaseDir = [string]$ui.State.cloneBaseDir
    }
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-CustomPresets
})

$loadPresetButton.Add_Click({
    $presetName = if ($ui.CustomPresetCombo.SelectedItem) { [string]$ui.CustomPresetCombo.SelectedItem } else { '' }
    if ([string]::IsNullOrWhiteSpace($presetName)) { return }
    $preset = $ui.State.customPresets[$presetName]
    if (-not $preset) { return }
    $ui.State.selectedProfiles = @(Normalize-BootstrapNames -Names @($preset.selectedProfiles))
    $ui.State.selectedComponents = @(Normalize-BootstrapNames -Names @($preset.selectedComponents))
    $ui.State.excludedComponents = @(Normalize-BootstrapNames -Names @($preset.excludedComponents))
    $ui.State.hostHealth = [string]$preset.hostHealth
    $ui.State.steamDeckVersion = [string]$preset.steamDeckVersion
    $ui.State.workspaceRoot = [string]$preset.workspaceRoot
    $ui.State.cloneBaseDir = [string]$preset.cloneBaseDir
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionTrees
    Refresh-SelectionSummary
    Refresh-HostSetupControls
})

$deletePresetButton.Add_Click({
    $presetName = if ($ui.CustomPresetCombo.SelectedItem) { [string]$ui.CustomPresetCombo.SelectedItem } else { '' }
    if ([string]::IsNullOrWhiteSpace($presetName)) { return }
    $ui.State.customPresets.Remove($presetName)
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-CustomPresets
})

# --- Selection page event handlers ---

$filterTextBox.Add_TextChanged({
    Refresh-SelectionTrees
})

$profilesTree.Add_AfterCheck({
    if ($ui.SuppressSelectionEvents) { return }
    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($node in @($ui.ProfilesTree.Nodes)) {
        if ($node.Checked) { $selected.Add([string]$node.Name) }
    }
    $ui.State.selectedProfiles = @($selected.ToArray())
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

$componentsTree.Add_AfterCheck({
    if ($ui.SuppressSelectionEvents) { return }
    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($node in @($ui.ComponentsTree.Nodes)) {
        if ($node.Checked) { $selected.Add([string]$node.Name) }
    }
    $ui.State.selectedComponents = @($selected.ToArray())
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

$profilesTree.Add_AfterSelect({
    $node = $ui.ProfilesTree.SelectedNode
    if ($node -and $node.Tag) {
        $ui.DetailsTextBox.Text = Get-SelectionDetailsText -Item $node.Tag.item -Kind $node.Tag.kind
    }
})

$componentsTree.Add_AfterSelect({
    $node = $ui.ComponentsTree.SelectedNode
    if ($node -and $node.Tag) {
        $ui.DetailsTextBox.Text = Get-SelectionDetailsText -Item $node.Tag.item -Kind $node.Tag.kind
    }
})

$excludeList.Add_ItemCheck({
    param($sender, $e)
    $excludes = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ui.ExcludeList.Items.Count; $i++) {
        $isChecked = if ($i -eq $e.Index) { $e.NewValue -eq 'Checked' } else { $ui.ExcludeList.GetItemChecked($i) }
        if ($isChecked) { $excludes.Add([string]$ui.ExcludeList.Items[$i]) }
    }
    $ui.State.excludedComponents = @($excludes.ToArray())
    Save-UiState -State $ui.State -Path $UiStatePath
})

# --- Host setup event handlers ---

$hostHealthCombo.Add_SelectedIndexChanged({
    if ($ui.HostHealthCombo.SelectedItem) {
        $ui.State.hostHealth = [string]$ui.HostHealthCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-SelectionSummary
        Refresh-HostSetupControls
    }
})

$steamDeckVersionCombo.Add_SelectedIndexChanged({
    if ($ui.SteamDeckVersionCombo.SelectedItem) {
        $ui.State.steamDeckVersion = [string]$ui.SteamDeckVersionCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
    }
})

$workspaceBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $ui.Strings.WorkspaceRoot
    $dialog.SelectedPath = [string]$ui.State.workspaceRoot
    if ($dialog.ShowDialog() -eq 'OK') {
        $ui.WorkspaceRootTextBox.Text = $dialog.SelectedPath
        $ui.State.workspaceRoot = $dialog.SelectedPath
        Save-UiState -State $ui.State -Path $UiStatePath
    }
})

$cloneBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $ui.Strings.CloneBaseDir
    $dialog.SelectedPath = [string]$ui.State.cloneBaseDir
    if ($dialog.ShowDialog() -eq 'OK') {
        $ui.CloneBaseDirTextBox.Text = $dialog.SelectedPath
        $ui.State.cloneBaseDir = $dialog.SelectedPath
        Save-UiState -State $ui.State -Path $UiStatePath
    }
})

$workspaceRootTextBox.Add_Leave({
    $ui.State.workspaceRoot = $ui.WorkspaceRootTextBox.Text.Trim()
    Save-UiState -State $ui.State -Path $UiStatePath
})

$cloneBaseDirTextBox.Add_Leave({
    $ui.State.cloneBaseDir = $ui.CloneBaseDirTextBox.Text.Trim()
    Save-UiState -State $ui.State -Path $UiStatePath
})

# --- Steam Deck control event handlers ---

$reloadSettingsButton.Add_Click({
    Refresh-SteamDeckControls
    $ui.StatusLabel.Text = $ui.Strings.ReloadSettings
})

$saveSettingsButton.Add_Click({
    Save-SteamDeckSettingsInteractive
})

# --- Review event handlers ---

$refreshReviewButton.Add_Click({
    Refresh-ReviewPage
})

# --- Run event handlers ---

$startRunButton.Add_Click({
    Start-RunExecution
})

$openLogButton.Add_Click({
    $path = if (-not [string]::IsNullOrWhiteSpace($ui.CurrentLogPath)) { $ui.CurrentLogPath } else { [string]$ui.State.lastLogPath }
    Open-ExistingPath -Path $path
})

$openResultButton.Add_Click({
    $path = if (-not [string]::IsNullOrWhiteSpace($ui.CurrentResultPath)) { $ui.CurrentResultPath } else { [string]$ui.State.lastResultPath }
    Open-ExistingPath -Path $path
})

$openSettingsButton.Add_Click({
    Open-ExistingPath -Path ([string]$ui.State.lastSettingsPath)
})

$openReportsButton.Add_Click({
    Open-ExistingPath -Path ([string]$ui.State.lastReportPath)
})

# --- Navigation event handlers ---

$backButton.Add_Click({
    if ($ui.CurrentPageIndex -gt 0) {
        $ui.CurrentPageIndex--
        Update-PageVisibility
    }
})

$nextButton.Add_Click({
    $pageIds = @(Get-UiPageIds)
    if ($ui.CurrentPageIndex -lt ($pageIds.Count - 1)) {
        $ui.CurrentPageIndex++
        Update-PageVisibility
    }
})

$finishButton.Add_Click({
    Save-UiState -State $ui.State -Path $UiStatePath
    $form.Close()
})

# --- Form lifecycle ---

$form.Add_Shown({
    Refresh-LocalizedText
    Refresh-CustomPresets
    Update-PageVisibility
})

$form.Add_FormClosing({
    $ui.LogTimer.Stop()
    if ($ui.RunProcess -and -not $ui.RunProcess.HasExited) {
        # Do not kill the backend — let it finish in the background
    }
    Save-UiState -State $ui.State -Path $UiStatePath
})

[System.Windows.Forms.Application]::Run($form)
