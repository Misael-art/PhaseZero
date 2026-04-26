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

# 
# UI Helpers / Strings
# 

function Get-UiLanguages {
    return @('pt-BR', 'en-US')
}

function Get-UiPageIds {
    return @('welcome', 'selection', 'host-setup', 'steamdeck-control', 'dual-boot', 'review', 'run')
}

function Get-UiStrings {
    param([Parameter(Mandatory = $true)][string]$Language)
    switch ($Language) {
        'en-US' {
            return @{
                WindowTitle        = 'Bootstrap Tools Control Center'
                WelcomeTitle       = 'Bootstrap Tools + Steam Deck'
                WelcomeSubtitle    = 'Simple host setup, Steam Deck control and post-install maintenance.'
                Language           = 'Language'
                QuickPresets       = 'Quick Presets'
                CustomPresets      = 'Custom Presets'
                PresetName         = 'Preset name'
                SavePreset         = 'Save preset'
                LoadPreset         = 'Load preset'
                DeletePreset       = 'Delete preset'
                SelectionTitle     = 'Profiles and Components'
                Filter             = 'Filter'
                Profiles           = 'Profiles'
                Components         = 'Components'
                Excludes           = 'Optional Excludes'
                SelectionDetails   = 'Selection Details'
                HostSetupTitle     = 'Host Setup'
                HostHealth         = 'HostHealth'
                SteamDeckVersion   = 'Steam Deck Version'
                WorkspaceRoot      = 'Workspace Root'
                CloneBaseDir       = 'Clone Base Dir'
                Browse             = 'Browse'
                AdminNeeds         = 'Admin Review'
                SteamDeckCenterTitle = 'Steam Deck Control Center'
                MonitorProfiles    = 'Monitor Profiles'
                MonitorFamilies    = 'Monitor Families'
                GenericExternal    = 'Generic External Fallback'
                SessionProfiles    = 'Session Profiles'
                WatcherStatus      = 'Watcher Status'
                SaveSettings       = 'Save Settings'
                ReloadSettings     = 'Reload Settings'
                UnknownMonitorHint = 'Unknown external monitors always fall back to genericExternal.'
                ReviewTitle        = 'Review'
                RefreshReview      = 'Refresh Review'
                ReviewSummary      = 'Preview equivalent to dry-run'
                RunTitle           = 'Run'
                StartRun           = '▶  Start Execution'
                CancelRun          = '⏹  Cancel Execution'
                OpenLog            = 'Open Log'
                OpenResult         = 'Open Result'
                OpenSettings       = 'Open Settings'
                OpenReports        = 'Open Reports'
                IdleStatus         = 'Ready.'
                SavingSettings     = 'Settings saved.'
                RunStarted         = 'Execution started.'
                RunCompleted       = 'Execution completed.'
                RunFailed          = 'Execution failed.'
                RunCanceled        = 'Execution canceled by user.'
                UserCanceledElevation = 'Execution canceled or elevation denied.'
                Back               = '← Back'
                Next               = 'Next →'
                Finish             = 'Close'
                Welcome            = 'Welcome'
                Selection          = 'Selection'
                HostSetup          = 'Host Setup'
                SteamDeckControl   = 'Steam Deck'
                DualBoot           = 'Dual Boot'
                Review             = 'Review'
                Run                = 'Run'
                GenericMode        = 'Mode'
                GenericLayout      = 'Layout'
                GenericResolution  = 'Resolution'
                SessionHandheld    = 'HANDHELD'
                SessionDockedTv    = 'DOCKED_TV'
                SessionDockedMonitor = 'DOCKED_MONITOR'
                DryRun             = 'Dry-run (preview only)'
                EtaLabel           = 'Estimated time'
                DiskFreeLabel      = 'Free disk'
                AdminLabel         = 'Privileges'
                AdminElevated      = 'Administrator'
                AdminNotElevated   = 'Not elevated'
                Progress           = 'Progress'
                StepOf             = 'Step {0} of {1}'
            }
        }
        default {
            return @{
                WindowTitle        = 'Central Bootstrap Tools'
                WelcomeTitle       = 'Bootstrap Tools + Steam Deck'
                WelcomeSubtitle    = 'Setup simples do host, controle do Steam Deck e manutenção pós-instalação.'
                Language           = 'Idioma'
                QuickPresets       = 'Presets Rápidos'
                CustomPresets      = 'Presets Personalizados'
                PresetName         = 'Nome do preset'
                SavePreset         = 'Salvar preset'
                LoadPreset         = 'Carregar preset'
                DeletePreset       = 'Excluir preset'
                SelectionTitle     = 'Perfis e Componentes'
                Filter             = 'Filtro'
                Profiles           = 'Perfis'
                Components         = 'Componentes'
                Excludes           = 'Exclusões Opcionais'
                SelectionDetails   = 'Detalhes da Seleção'
                HostSetupTitle     = 'Configuração do Host'
                HostHealth         = 'HostHealth'
                SteamDeckVersion   = 'Versão do Steam Deck'
                WorkspaceRoot      = 'Workspace Root'
                CloneBaseDir       = 'Diretório Base de Clones'
                Browse             = 'Selecionar'
                AdminNeeds         = 'Revisão de Admin'
                SteamDeckCenterTitle = 'Central Steam Deck'
                MonitorProfiles    = 'Monitor Profiles'
                MonitorFamilies    = 'Monitor Families'
                GenericExternal    = 'Fallback genericExternal'
                SessionProfiles    = 'Session Profiles'
                WatcherStatus      = 'Status do Watcher'
                SaveSettings       = 'Salvar Settings'
                ReloadSettings     = 'Recarregar Settings'
                UnknownMonitorHint = 'Monitores externos desconhecidos sempre caem em genericExternal.'
                ReviewTitle        = 'Revisão'
                RefreshReview      = 'Atualizar Revisão'
                ReviewSummary      = 'Preview equivalente ao dry-run'
                RunTitle           = 'Execução'
                StartRun           = '▶  Iniciar Execução'
                CancelRun          = '⏹  Cancelar Execução'
                OpenLog            = 'Abrir Log'
                OpenResult         = 'Abrir Resultado'
                OpenSettings       = 'Abrir Settings'
                OpenReports        = 'Abrir Relatórios'
                IdleStatus         = 'Pronto.'
                SavingSettings     = 'Settings salvos.'
                RunStarted         = 'Execução iniciada.'
                RunCompleted       = 'Execução concluída.'
                RunFailed          = 'Execução falhou.'
                RunCanceled        = 'Execução cancelada pelo usuário.'
                UserCanceledElevation = 'Execução cancelada ou elevação negada.'
                Back               = '← Voltar'
                Next               = 'Avançar →'
                Finish             = 'Fechar'
                Welcome            = 'Início'
                Selection          = 'Seleção'
                HostSetup          = 'Host Setup'
                SteamDeckControl   = 'Steam Deck'
                DualBoot           = 'Dual Boot'
                Review             = 'Revisão'
                Run                = 'Execução'
                GenericMode        = 'Modo'
                GenericLayout      = 'Layout'
                GenericResolution  = 'Resolução'
                SessionHandheld    = 'HANDHELD'
                SessionDockedTv    = 'DOCKED_TV'
                SessionDockedMonitor = 'DOCKED_MONITOR'
                DryRun             = 'Dry-run (somente preview)'
                EtaLabel           = 'Tempo estimado'
                DiskFreeLabel      = 'Espaço livre'
                AdminLabel         = 'Privilégios'
                AdminElevated      = 'Administrador'
                AdminNotElevated   = 'Sem elevação'
                Progress           = 'Progresso'
                StepOf             = 'Etapa {0} de {1}'
            }
        }
    }
}

function Get-UiStateDefaults {
    param($Contract)
    return [ordered]@{
        language           = 'pt-BR'
        selectedProfiles   = @('recommended')
        selectedComponents = @()
        excludedComponents = @()
        hostHealth         = 'conservador'
        steamDeckVersion   = 'Auto'
        workspaceRoot      = [string]$Contract.defaults.workspaceRoot
        cloneBaseDir       = (Get-Location).Path
        customPresets      = @{}
        lastLogPath        = $null
        lastResultPath     = $null
        lastReportPath     = $null
        lastSettingsPath   = Get-BootstrapSteamDeckSettingsPath
    }
}

function Normalize-UiState {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)]$Contract
    )
    $defaults   = Get-UiStateDefaults -Contract $Contract
    $normalized = Merge-BootstrapData -Defaults $defaults -Current $State
    $normalized = ConvertTo-BootstrapHashtable -InputObject $normalized
    $normalized['selectedProfiles']   = @(Normalize-BootstrapNames -Names @($normalized['selectedProfiles']))
    $normalized['selectedComponents'] = @(Normalize-BootstrapNames -Names @($normalized['selectedComponents']))
    $normalized['excludedComponents'] = @(Normalize-BootstrapNames -Names @($normalized['excludedComponents']))
    $language = [string]$normalized['language']
    if ((Get-UiLanguages) -notcontains $language) { $normalized['language'] = 'pt-BR' }
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
        try { $current = Get-Content -Path $Path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $current = $null }
    }
    return (Normalize-UiState -State $current -Contract $Contract)
}

$script:UiSaveStateTimer = $null
$script:UiSaveStateState  = $null
$script:UiSaveStatePath   = $null

function Save-UiStateImmediate {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )
    Write-BootstrapJsonFile -Path $Path -Value (ConvertTo-BootstrapHashtable -InputObject $State)
}

function Save-UiState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $script:UiSaveStateState = $State
    $script:UiSaveStatePath  = $Path
    if (-not $script:UiSaveStateTimer) {
        $script:UiSaveStateTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:UiSaveStateTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:UiSaveStateTimer.Add_Tick({
            $script:UiSaveStateTimer.Stop()
            if ($script:UiSaveStateState -and $script:UiSaveStatePath) {
                try {
                    Save-UiStateImmediate -State $script:UiSaveStateState -Path $script:UiSaveStatePath
                } catch { }
            }
        })
    }
    $script:UiSaveStateTimer.Stop()
    $script:UiSaveStateTimer.Start()
}

function Flush-UiState {
    if ($script:UiSaveStateTimer -and $script:UiSaveStateTimer.IsEnabled) {
        $script:UiSaveStateTimer.Stop()
        if ($script:UiSaveStateState -and $script:UiSaveStatePath) {
            Save-UiStateImmediate -State $script:UiSaveStateState -Path $script:UiSaveStatePath
        }
    }
}

# 
# Bootstrap / SmokeTest
# 

$contract = Get-BootstrapUiContract
$state    = Read-UiState -Path $UiStatePath -Contract $contract

if ($SmokeTest) {
    Save-UiStateImmediate -State $state -Path $UiStatePath
    [ordered]@{
        pages    = @(Get-UiPageIds)
        languages = @(Get-UiLanguages)
        statePath = $UiStatePath
        backend  = $backendScriptPath
    } | ConvertTo-Json -Depth 8
    return
}

# 
# Ensure STA thread
# 

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentList  = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath, '-UiStatePath', $UiStatePath)
    Start-Process -FilePath $powershellExe -ArgumentList ([string]::Join(' ', @($argumentList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }))) | Out-Null
    exit 0
}

# 
# WPF Assemblies
# 

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms   # still needed for FolderBrowserDialog
Add-Type -AssemblyName System.Drawing

# 
# XAML Definition
# 

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Bootstrap Tools" Width="1180" Height="800"
        Background="#0F1117" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" Foreground="#E2E8F0"
        ResizeMode="CanMinimize">

    <Window.Resources>
        <!-- Colors -->
        <SolidColorBrush x:Key="BgBrush"       Color="#0F1117"/>
        <SolidColorBrush x:Key="SurfaceBrush"  Color="#1A1D2E"/>
        <SolidColorBrush x:Key="BorderBrush"   Color="#2D3148"/>
        <SolidColorBrush x:Key="AccentBrush"   Color="#7C3AED"/>
        <SolidColorBrush x:Key="AccentHover"   Color="#9D5CF5"/>
        <SolidColorBrush x:Key="AccentActive"  Color="#6D28D9"/>
        <SolidColorBrush x:Key="TextPrimary"   Color="#E2E8F0"/>
        <SolidColorBrush x:Key="TextSecondary" Color="#94A3B8"/>
        <SolidColorBrush x:Key="InputBg"       Color="#252840"/>
        <SolidColorBrush x:Key="SuccessBrush"  Color="#10B981"/>
        <SolidColorBrush x:Key="ErrorBrush"    Color="#EF4444"/>
        <SolidColorBrush x:Key="WarnBrush"     Color="#F59E0B"/>
        <SolidColorBrush x:Key="SidebarBg"     Color="#13162B"/>
        <SolidColorBrush x:Key="NavHoverBg"    Color="#1E2240"/>
        <SolidColorBrush x:Key="NavActiveBg"   Color="#2D1B69"/>

        <!-- Base TextBox style -->
        <Style x:Key="DarkInput" TargetType="TextBox">
            <Setter Property="Background"       Value="#252840"/>
            <Setter Property="Foreground"       Value="#E2E8F0"/>
            <Setter Property="BorderBrush"      Value="#2D3148"/>
            <Setter Property="BorderThickness"  Value="1"/>
            <Setter Property="Padding"          Value="8,5"/>
            <Setter Property="CaretBrush"       Value="#7C3AED"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost"
                                          Margin="{TemplateBinding Padding}"
                                          VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Readonly TextBox -->
        <Style x:Key="DarkReadonly" TargetType="TextBox" BasedOn="{StaticResource DarkInput}">
            <Setter Property="IsReadOnly"  Value="True"/>
            <Setter Property="Background" Value="#1A1D2E"/>
            <Setter Property="Foreground" Value="#94A3B8"/>
        </Style>

        <!-- ComboBox style -->
        <Style x:Key="DarkCombo" TargetType="ComboBox">
            <Setter Property="Background"      Value="#252840"/>
            <Setter Property="Foreground"      Value="#E2E8F0"/>
            <Setter Property="BorderBrush"     Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="8,5"/>
            <Setter Property="Height"          Value="34"/>
        </Style>

        <!-- Primary button -->
        <Style x:Key="PrimaryBtn" TargetType="Button">
            <Setter Property="Background"   Value="#7C3AED"/>
            <Setter Property="Foreground"   Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"      Value="18,9"/>
            <Setter Property="FontWeight"   Value="SemiBold"/>
            <Setter Property="Cursor"       Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="8"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#9D5CF5"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#6D28D9"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#374151"/>
                                <Setter Property="Foreground" Value="#6B7280"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Ghost / secondary button -->
        <Style x:Key="GhostBtn" TargetType="Button">
            <Setter Property="Background"   Value="Transparent"/>
            <Setter Property="Foreground"   Value="#94A3B8"/>
            <Setter Property="BorderBrush"  Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"      Value="14,7"/>
            <Setter Property="Cursor"       Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="7"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1E2240"/>
                                <Setter Property="Foreground" Value="#E2E8F0"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#252840"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#374151"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Preset quick-select button -->
        <Style x:Key="PresetBtn" TargetType="Button">
            <Setter Property="Background"   Value="#1A1D2E"/>
            <Setter Property="Foreground"   Value="#CBD5E1"/>
            <Setter Property="BorderBrush"  Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding"      Value="14,9"/>
            <Setter Property="Margin"       Value="0,4"/>
            <Setter Property="Cursor"       Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="7"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#252A44"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#7C3AED"/>
                                <Setter Property="Foreground" Value="#E2E8F0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Sidebar nav button -->
        <Style x:Key="NavBtn" TargetType="ToggleButton">
            <Setter Property="Background"            Value="Transparent"/>
            <Setter Property="Foreground"            Value="#94A3B8"/>
            <Setter Property="BorderThickness"       Value="0"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding"               Value="16,12"/>
            <Setter Property="Cursor"                Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="8"
                                Margin="8,2"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2D1B69"/>
                                <Setter Property="Foreground" Value="#E2E8F0"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1E2240"/>
                                <Setter Property="Foreground" Value="#E2E8F0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Card border style for GroupBox replacement -->
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background"      Value="#1A1D2E"/>
            <Setter Property="BorderBrush"     Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius"    Value="12"/>
            <Setter Property="Padding"         Value="16"/>
        </Style>

        <!-- Section label -->
        <Style x:Key="SectionLabel" TargetType="TextBlock">
            <Setter Property="Foreground"  Value="#94A3B8"/>
            <Setter Property="FontSize"    Value="11"/>
            <Setter Property="FontWeight"  Value="SemiBold"/>
            <Setter Property="Margin"      Value="0,0,0,6"/>
        </Style>

        <!-- Page title -->
        <Style x:Key="PageTitle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="FontSize"   Value="22"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Margin"     Value="0,0,0,4"/>
        </Style>

        <!-- Page subtitle -->
        <Style x:Key="PageSubtitle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#64748B"/>
            <Setter Property="FontSize"   Value="13"/>
            <Setter Property="Margin"     Value="0,0,0,24"/>
        </Style>

        <!-- DataGrid style -->
        <Style x:Key="DarkGrid" TargetType="DataGrid">
            <Setter Property="Background"            Value="#1A1D2E"/>
            <Setter Property="Foreground"            Value="#CBD5E1"/>
            <Setter Property="BorderBrush"           Value="#2D3148"/>
            <Setter Property="BorderThickness"       Value="1"/>
            <Setter Property="RowBackground"         Value="#1A1D2E"/>
            <Setter Property="AlternatingRowBackground" Value="#1E2240"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#2D3148"/>
            <Setter Property="VerticalGridLinesBrush"   Value="#2D3148"/>
            <Setter Property="ColumnHeaderHeight"    Value="32"/>
            <Setter Property="RowHeight"             Value="28"/>
            <Setter Property="SelectionMode"         Value="Single"/>
            <Setter Property="AutoGenerateColumns"   Value="False"/>
            <Setter Property="RowHeaderWidth"        Value="0"/>
            <Setter Property="CanUserAddRows"        Value="True"/>
            <Setter Property="CanUserDeleteRows"     Value="True"/>
        </Style>

        <!-- CheckBox style -->
        <Style x:Key="DarkCheck" TargetType="CheckBox">
            <Setter Property="Foreground"   Value="#CBD5E1"/>
            <Setter Property="Margin"       Value="0,3"/>
        </Style>

        <!-- ListBox item style -->
        <Style x:Key="DarkListItem" TargetType="ListBoxItem">
            <Setter Property="Foreground"  Value="#CBD5E1"/>
            <Setter Property="Padding"     Value="8,4"/>
            <Setter Property="Background"  Value="Transparent"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#2D1B69"/>
                </Trigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#1E2240"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- TreeView item -->
        <Style x:Key="DarkTreeItem" TargetType="TreeViewItem">
            <Setter Property="Foreground"  Value="#CBD5E1"/>
            <Setter Property="Padding"     Value="4,3"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#2D1B69"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="220"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="44"/>
        </Grid.RowDefinitions>

        <!--  SIDEBAR  -->
        <Border Grid.Column="0" Grid.Row="0" Grid.RowSpan="2"
                Background="#13162B"
                BorderBrush="#2D3148" BorderThickness="0,0,1,0">
            <DockPanel>
                <!-- Logo / app name -->
                <StackPanel DockPanel.Dock="Top" Margin="20,24,20,28">
                    <TextBlock Text="Z Bootstrap" FontSize="16" FontWeight="Bold"
                               Foreground="#7C3AED"/>
                    <TextBlock Text="Tools Control Center" FontSize="11"
                               Foreground="#475569" Margin="0,2,0,0"/>
                </StackPanel>

                <!-- Nav items -->
                <StackPanel x:Name="NavPanel" DockPanel.Dock="Top" Margin="0,0,0,0">
                    <ToggleButton x:Name="NavWelcome"      Style="{StaticResource NavBtn}" IsChecked="True">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavWelcomeText" Text="Início" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavSelection"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavSelectionText" Text="Seleção" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavHostSetup"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="⚙" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavHostSetupText" Text="Host Setup" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavSteamDeck"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavSteamDeckText" Text="Steam Deck" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavDualBoot"       Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavDualBootText" Text="Dual Boot" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavReview"       Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavReviewText" Text="Revisão" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavRun"          Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text=">" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavRunText" Text="Execução" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                </StackPanel>

                <!-- Bottom nav actions -->
                <StackPanel DockPanel.Dock="Bottom" Margin="12,16">
                    <Button x:Name="BackButton"   Style="{StaticResource GhostBtn}" Content="<- Voltar"  Margin="0,4" Height="34"/>
                    <Button x:Name="NextButton"   Style="{StaticResource PrimaryBtn}" Content="Avançar →" Margin="0,4" Height="34"/>
                    <Button x:Name="FinishButton" Style="{StaticResource GhostBtn}" Content="Fechar"     Margin="0,4" Height="34"/>
                </StackPanel>
            </DockPanel>
        </Border>

        <!--  CONTENT AREA  -->
        <Grid Grid.Column="1" Grid.Row="0">

            <!--  WELCOME PAGE  -->
            <ScrollViewer x:Name="PageWelcome" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="WelcomeTitleLabel"    Style="{StaticResource PageTitle}"    Text="Bootstrap Tools + Steam Deck"/>
                    <TextBlock x:Name="WelcomeSubtitleLabel" Style="{StaticResource PageSubtitle}" Text="Setup simples do host, controle do Steam Deck e manutenção pós-instalação."
                               TextWrapping="Wrap"/>

                    <!-- Language selector -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <StackPanel>
                            <TextBlock Style="{StaticResource SectionLabel}" Text="IDIOMA / LANGUAGE"/>
                            <ComboBox x:Name="LanguageCombo" Style="{StaticResource DarkCombo}" Width="200" HorizontalAlignment="Left"/>
                        </StackPanel>
                    </Border>

                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="16"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>

                        <!-- Quick Presets -->
                        <Border Grid.Column="0" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock x:Name="QuickPresetsLabel" Style="{StaticResource SectionLabel}" Text="PRESETS RPIDOS"/>
                                <Button x:Name="PresetRecommended"      Style="{StaticResource PresetBtn}" Tag="recommended"      Content="*  recommended"/>
                                <Button x:Name="PresetLegacy"           Style="{StaticResource PresetBtn}" Tag="legacy"           Content="  legacy"/>
                                <Button x:Name="PresetFull"             Style="{StaticResource PresetBtn}" Tag="full"             Content="  full"/>
                                <Button x:Name="PresetSteamdeckRec"     Style="{StaticResource PresetBtn}" Tag="steamdeck-recommended" Content="  steamdeck-recommended"/>
                                <Button x:Name="PresetSteamdeckFull"    Style="{StaticResource PresetBtn}" Tag="steamdeck-full"   Content="  steamdeck-full"/>
                            </StackPanel>
                        </Border>

                        <!-- Custom Presets -->
                        <Border Grid.Column="2" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock x:Name="CustomPresetsLabel" Style="{StaticResource SectionLabel}" Text="PRESETS PERSONALIZADOS"/>
                                <TextBlock x:Name="PresetNameLabel" Foreground="#94A3B8" FontSize="12" Text="Nome do preset" Margin="0,0,0,4"/>
                                <TextBox x:Name="PresetNameTextBox" Style="{StaticResource DarkInput}" Margin="0,0,0,8" Height="32"/>
                                <Button x:Name="SavePresetButton" Style="{StaticResource GhostBtn}" Margin="0,0,0,12" Height="32" HorizontalAlignment="Stretch" Content="  Salvar preset atual"/>
                                <Separator Background="#2D3148" Margin="0,0,0,12"/>
                                <ComboBox x:Name="CustomPresetCombo" Style="{StaticResource DarkCombo}" Margin="0,0,0,8"/>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition/>
                                        <ColumnDefinition Width="8"/>
                                        <ColumnDefinition/>
                                    </Grid.ColumnDefinitions>
                                    <Button x:Name="LoadPresetButton"   Grid.Column="0" Style="{StaticResource GhostBtn}" Content=" Carregar" Height="32"/>
                                    <Button x:Name="DeletePresetButton" Grid.Column="2" Style="{StaticResource GhostBtn}" Content=" Excluir"  Height="32"/>
                                </Grid>
                            </StackPanel>
                        </Border>
                    </Grid>
                </StackPanel>
            </ScrollViewer>

            <!--  SELECTION PAGE  -->
            <Grid x:Name="PageSelection" Visibility="Collapsed" Margin="32,28">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <StackPanel Grid.Row="0">
                    <TextBlock x:Name="SelectionTitleLabel" Style="{StaticResource PageTitle}" Text="Perfis e Componentes"/>
                    <!-- Filter bar -->
                    <Grid Margin="0,0,0,16">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="" FontSize="16" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#64748B"/>
                        <TextBox x:Name="FilterTextBox" Grid.Column="1" Style="{StaticResource DarkInput}" Height="34"/>
                    </Grid>
                </StackPanel>

                <Grid Grid.Row="2">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="12"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="12"/>
                        <ColumnDefinition Width="260"/>
                    </Grid.ColumnDefinitions>

                    <!-- Profiles Tree -->
                    <Border Grid.Column="0" Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="ProfilesLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="PERFIS"/>
                            <TreeView x:Name="ProfilesTree" Background="Transparent" BorderThickness="0"
                                      Foreground="#CBD5E1" Margin="0,4,0,0"/>
                        </DockPanel>
                    </Border>

                    <!-- Components Tree -->
                    <Border Grid.Column="2" Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="ComponentsLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="COMPONENTES"/>
                            <TreeView x:Name="ComponentsTree" Background="Transparent" BorderThickness="0"
                                      Foreground="#CBD5E1" Margin="0,4,0,0"/>
                        </DockPanel>
                    </Border>

                    <!-- Excludes + Details -->
                    <Grid Grid.Column="4">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="12"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Border Grid.Row="0" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="ExcludeLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="EXCLUSES OPCIONAIS"/>
                                <ListBox x:Name="ExcludeList" Background="Transparent" BorderThickness="0"
                                         Foreground="#CBD5E1" Margin="0,4,0,0"/>
                            </DockPanel>
                        </Border>
                        <Border Grid.Row="2" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="DetailsLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="DETALHES"/>
                                <TextBox x:Name="DetailsTextBox" Style="{StaticResource DarkReadonly}"
                                         TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AcceptsReturn="True"/>
                            </DockPanel>
                        </Border>
                    </Grid>
                </Grid>

                <!-- Summary -->
                <Border Grid.Row="3" Background="#1A1D2E" CornerRadius="8" Padding="12,8" Margin="0,10,0,0">
                    <StackPanel>
                        <TextBlock x:Name="SelectionSummaryLabel" Foreground="#94A3B8" FontSize="12"/>
                        <TextBlock x:Name="SelectionErrorLabel"   Foreground="#EF4444" FontSize="12" TextWrapping="Wrap"/>
                    </StackPanel>
                </Border>
            </Grid>

            <!--  HOST SETUP PAGE  -->
            <ScrollViewer x:Name="PageHostSetup" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="HostTitleLabel" Style="{StaticResource PageTitle}" Text="Configuração do Host"/>
                    <TextBlock Style="{StaticResource PageSubtitle}" Text="Configuraes de ambiente e sade do sistema." TextWrapping="Wrap"/>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="200"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="12"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <TextBlock x:Name="HostHealthLabel"       Grid.Row="0" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="HostHealth"/>
                            <ComboBox  x:Name="HostHealthCombo"       Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkCombo}"/>
                            <TextBlock x:Name="SteamDeckVersionLabel" Grid.Row="2" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Versão Steam Deck"/>
                            <ComboBox  x:Name="SteamDeckVersionCombo" Grid.Row="2" Grid.Column="1" Style="{StaticResource DarkCombo}"/>
                        </Grid>
                    </Border>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="200"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="110"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="12"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <TextBlock x:Name="WorkspaceRootLabel"  Grid.Row="0" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Workspace Root"/>
                            <TextBox   x:Name="WorkspaceRootTextBox" Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                            <Button    x:Name="WorkspaceBrowseButton" Grid.Row="0" Grid.Column="2" Style="{StaticResource GhostBtn}" Content=" Selecionar" Margin="8,0,0,0" Height="32"/>
                            <TextBlock x:Name="CloneBaseDirLabel"   Grid.Row="2" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Clone Base Dir"/>
                            <TextBox   x:Name="CloneBaseDirTextBox"  Grid.Row="2" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                            <Button    x:Name="CloneBrowseButton"    Grid.Row="2" Grid.Column="2" Style="{StaticResource GhostBtn}" Content=" Selecionar" Margin="8,0,0,0" Height="32"/>
                        </Grid>
                    </Border>

                    <Border Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="AdminNeedsTitleLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="REVISO DE ADMIN"/>
                            <TextBox   x:Name="AdminNeedsTextBox" Style="{StaticResource DarkReadonly}"
                                       Height="160" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" Margin="0,4,0,0"/>
                        </DockPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  STEAM DECK CONTROL PAGE  -->
            <ScrollViewer x:Name="PageSteamDeck" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="SteamDeckTitleLabel" Style="{StaticResource PageTitle}" Text="Central Steam Deck"/>
                    <TextBlock Style="{StaticResource PageSubtitle}" Text="Configure perfis de monitor, sesses e o fallback genrico." TextWrapping="Wrap"/>

                    <!-- Monitor Profiles -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                        <DockPanel>
                            <TextBlock x:Name="MonitorProfilesLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="MONITOR PROFILES"/>
                            <DataGrid  x:Name="MonitorProfilesGrid"  Style="{StaticResource DarkGrid}" Height="160" Margin="0,4,0,0">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="manufacturer"     Binding="{Binding manufacturer}"     Width="*"/>
                                    <DataGridTextColumn Header="product"           Binding="{Binding product}"           Width="*"/>
                                    <DataGridTextColumn Header="serial"            Binding="{Binding serial}"            Width="*"/>
                                    <DataGridTextColumn Header="mode"              Binding="{Binding mode}"              Width="*"/>
                                    <DataGridTextColumn Header="layout"            Binding="{Binding layout}"            Width="*"/>
                                    <DataGridTextColumn Header="resolutionPolicy"  Binding="{Binding resolutionPolicy}"  Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>

                    <!-- Monitor Families -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                        <DockPanel>
                            <TextBlock x:Name="MonitorFamiliesLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="MONITOR FAMILIES"/>
                            <DataGrid  x:Name="MonitorFamiliesGrid"  Style="{StaticResource DarkGrid}" Height="160" Margin="0,4,0,0">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="manufacturer"     Binding="{Binding manufacturer}"     Width="*"/>
                                    <DataGridTextColumn Header="product"           Binding="{Binding product}"           Width="*"/>
                                    <DataGridTextColumn Header="namePattern"       Binding="{Binding namePattern}"       Width="*"/>
                                    <DataGridTextColumn Header="mode"              Binding="{Binding mode}"              Width="*"/>
                                    <DataGridTextColumn Header="layout"            Binding="{Binding layout}"            Width="*"/>
                                    <DataGridTextColumn Header="resolutionPolicy"  Binding="{Binding resolutionPolicy}"  Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>

                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="16"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>

                        <!-- Generic External -->
                        <Border Grid.Column="0" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock x:Name="GenericGroupLabel" Style="{StaticResource SectionLabel}" Text="FALLBACK GENRICO"/>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="130"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="8"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="8"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <TextBlock x:Name="GenericModeLabel"       Grid.Row="0" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Modo"/>
                                    <ComboBox  x:Name="GenericModeCombo"       Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkCombo}"/>
                                    <TextBlock x:Name="GenericLayoutLabel"     Grid.Row="2" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Layout"/>
                                    <TextBox   x:Name="GenericLayoutTextBox"   Grid.Row="2" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                    <TextBlock x:Name="GenericResolutionLabel" Grid.Row="4" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Resolução"/>
                                    <TextBox   x:Name="GenericResolutionTextBox" Grid.Row="4" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                </Grid>
                            </StackPanel>
                        </Border>

                        <!-- Session Profiles -->
                        <Border Grid.Column="2" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock x:Name="SessionGroupLabel" Style="{StaticResource SectionLabel}" Text="SESSION PROFILES"/>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="160"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="8"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="8"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <TextBlock x:Name="HandheldSessionLabel"      Grid.Row="0" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="HANDHELD"/>
                                    <TextBox   x:Name="HandheldSessionTextBox"    Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                    <TextBlock x:Name="DockTvSessionLabel"        Grid.Row="2" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="DOCKED_TV"/>
                                    <TextBox   x:Name="DockTvSessionTextBox"      Grid.Row="2" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                    <TextBlock x:Name="DockMonitorSessionLabel"   Grid.Row="4" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="DOCKED_MONITOR"/>
                                    <TextBox   x:Name="DockMonitorSessionTextBox" Grid.Row="4" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                </Grid>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <!-- Watcher status + save buttons -->
                    <Border Background="#1A1D2E" CornerRadius="8" Padding="14,10" Margin="0,14,0,0">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                <Button x:Name="ReloadSettingsButton" Style="{StaticResource GhostBtn}"   Content=" Recarregar" Margin="0,0,8,0" Height="34"/>
                                <Button x:Name="SaveSettingsButton"   Style="{StaticResource PrimaryBtn}" Content=" Salvar Settings" Height="34"/>
                            </StackPanel>
                            <StackPanel>
                                <TextBlock x:Name="WatcherStatusLabel"  Foreground="#64748B" FontSize="12" TextWrapping="Wrap"/>
                                <TextBlock x:Name="UnknownMonitorHintLabel" Foreground="#475569" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  DUAL BOOT PAGE  -->
            <ScrollViewer x:Name="PageDualBoot" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="DualBootTitleLabel" Style="{StaticResource PageTitle}" Text="Dual Boot"/>
                    <TextBlock Style="{StaticResource PageSubtitle}" Text="Validao de guardrails e gerenciamento do cenrio Windows + Linux." TextWrapping="Wrap"/>

                    <!-- Status -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="STATUS DO SISTEMA"/>
                            <TextBlock x:Name="DualBootStatusText" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,8,0,0"/>
                        </DockPanel>
                    </Border>

                    <!-- Pre-reqs -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="PR-REQUISITOS (WINDOWS)"/>
                            <StackPanel Margin="0,8,0,0">
                                <TextBlock x:Name="DualBootPrereqsText" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,12"/>
                                <Button x:Name="FixFastStartupButton" Style="{StaticResource PrimaryBtn}" Content=" Desabilitar Fast Startup" Width="220" HorizontalAlignment="Left" Height="34"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <!-- Reboot to Linux -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="REBOOT SEGURO (ONE-TIME BOOT)"/>
                            <Grid Margin="0,8,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <ComboBox x:Name="DualBootTargetCombo" Grid.Column="0" Style="{StaticResource DarkCombo}" Margin="0,0,12,0"/>
                                <Button x:Name="RebootToLinuxButton" Grid.Column="1" Style="{StaticResource PrimaryBtn}" Background="#EF4444" Content=" Reiniciar para Linux" Width="200" Height="34"/>
                            </Grid>
                        </DockPanel>
                    </Border>

                    <!-- BCD Cleanup -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16" BorderBrush="{StaticResource WarnBrush}">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="LIMPEZA DE BCD (MENU DO WINDOWS)"/>
                            <StackPanel Margin="0,8,0,0">
                                <TextBlock x:Name="BcdCleanupStatusText" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,12"/>
                                <Button x:Name="BcdCleanupButton" Style="{StaticResource PrimaryBtn}" Background="#F59E0B" Foreground="Black" Content=" Auditar e Limpar Menu Falso" Width="230" HorizontalAlignment="Left" Height="34"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>
                    
                    <Button x:Name="RefreshDualBootButton" Style="{StaticResource GhostBtn}" Content=" Recarregar Status" Width="180" HorizontalAlignment="Left" Height="34"/>
                </StackPanel>
            </ScrollViewer>

            <!--  REVIEW PAGE  -->
            <Grid x:Name="PageReview" Visibility="Collapsed" Margin="32,28">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <StackPanel Grid.Row="0">
                    <TextBlock x:Name="ReviewTitleLabel" Style="{StaticResource PageTitle}" Text="Revisão"/>
                </StackPanel>

                <Border Grid.Row="1" Background="#1A1D2E" CornerRadius="8" Padding="14,10" Margin="0,0,0,14">
                    <DockPanel>
                        <Button x:Name="RefreshReviewButton" DockPanel.Dock="Right" Style="{StaticResource GhostBtn}" Content=" Atualizar" Height="32"/>
                        <TextBlock x:Name="ReviewMetaLabel" Foreground="#64748B" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
                    </DockPanel>
                </Border>

                <Border Grid.Row="2" Style="{StaticResource Card}">
                    <DockPanel>
                        <TextBlock x:Name="ReviewSummaryLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="PREVIEW DO PLAN (DRY-RUN)"/>
                        <TextBox x:Name="ReviewTextBox" Style="{StaticResource DarkReadonly}"
                                 AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                                 FontFamily="Consolas" FontSize="12" Margin="0,4,0,0"/>
                    </DockPanel>
                </Border>
            </Grid>

            <!--  RUN PAGE  -->
            <Grid x:Name="PageRun" Visibility="Collapsed" Margin="32,28">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" x:Name="RunTitleLabel" Style="{StaticResource PageTitle}" Text="Execução"/>

                <!-- Action bar -->
                <Border Grid.Row="1" Background="#1A1D2E" CornerRadius="10" Padding="16,12" Margin="0,0,0,16">
                    <DockPanel>
                        <Button x:Name="CancelRunButton" DockPanel.Dock="Right" Style="{StaticResource GhostBtn}"
                                Content="⏹ Cancelar" Height="40" Margin="8,0,0,0" IsEnabled="False"/>
                        <Button x:Name="StartRunButton" DockPanel.Dock="Right" Style="{StaticResource PrimaryBtn}"
                                Content="▶  Iniciar Execução" FontSize="15" Height="40"/>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <CheckBox x:Name="DryRunCheckBox" Content="Dry-run" Foreground="#94A3B8" Margin="0,0,12,0" VerticalAlignment="Center"/>
                            <Button x:Name="OpenLogButton"     Style="{StaticResource GhostBtn}" Content=" Log"        Margin="0,0,8,0" Height="34"/>
                            <Button x:Name="OpenResultButton"  Style="{StaticResource GhostBtn}" Content=" Resultado"  Margin="0,0,8,0" Height="34"/>
                            <Button x:Name="OpenSettingsButton" Style="{StaticResource GhostBtn}" Content="⚙ Settings"   Margin="0,0,8,0" Height="34"/>
                            <Button x:Name="OpenReportsButton" Style="{StaticResource GhostBtn}" Content=" Relatórios" Height="34"/>
                        </StackPanel>
                    </DockPanel>
                </Border>

                <!-- Log area -->
                <Border Grid.Row="2" Style="{StaticResource Card}">
                    <DockPanel>
                        <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" x:Name="RunStatusLabel" Foreground="#94A3B8" FontSize="12"/>
                            <TextBlock Grid.Column="1" x:Name="RunEtaLabel" Foreground="#7C3AED" FontSize="12" FontWeight="SemiBold"/>
                        </Grid>
                        <ProgressBar DockPanel.Dock="Top" x:Name="RunProgressBar" Height="6" Minimum="0" Maximum="100" Value="0"
                                     Foreground="#7C3AED" Background="#252840" BorderThickness="0" Margin="0,0,0,8"/>
                        <TextBox x:Name="RunLogTextBox" Style="{StaticResource DarkReadonly}"
                                 AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                                 FontFamily="Consolas" FontSize="12"/>
                    </DockPanel>
                </Border>
            </Grid>
        </Grid>

        <!--  STATUS BAR  -->
        <Border Grid.Column="1" Grid.Row="1"
                Background="#13162B" BorderBrush="#2D3148" BorderThickness="0,1,0,0"
                Padding="24,0">
            <DockPanel VerticalAlignment="Center">
                <TextBlock x:Name="StepLabel"   DockPanel.Dock="Right" Foreground="#475569" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="StatusLabel" Foreground="#64748B" FontSize="12" VerticalAlignment="Center"/>
            </DockPanel>
        </Border>
    </Grid>
</Window>
'@

# 
# Load WPF Window from XAML
# 

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

function Get-Control {
    param([Parameter(Mandatory=$true)][string]$Name)
    $ctrl = $window.FindName($Name)
    if (-not $ctrl) { throw "Control not found: $Name" }
    return $ctrl
}

# 
# Control references
# 

$ui = [ordered]@{
    Contract              = $contract
    State                 = $state
    Strings               = Get-UiStrings -Language ([string]$state.language)
    CurrentPageIndex      = 0
    Preview               = $null
    SettingsBundle        = Get-BootstrapSteamDeckSettingsData -RequestedSteamDeckVersion ([string]$state.steamDeckVersion) -ResolvedSteamDeckVersion 'lcd'
    SettingsBackupPath    = $null
    SuppressSelectionEvents = $false
    LogOffset             = 0
    CurrentLogPath        = $null
    CurrentResultPath     = $null
    RunProcess            = $null
    RunCanceled           = $false
    RunStartTime          = $null
    SaveStateTimer        = $null
    SaveStateDirty        = $false

    # Window
    Window                = $window

    # Nav
    NavWelcome            = (Get-Control 'NavWelcome')
    NavSelection          = (Get-Control 'NavSelection')
    NavHostSetup          = (Get-Control 'NavHostSetup')
    NavSteamDeck          = (Get-Control 'NavSteamDeck')
    NavDualBoot           = (Get-Control 'NavDualBoot')
    NavReview             = (Get-Control 'NavReview')
    NavRun                = (Get-Control 'NavRun')
    NavWelcomeText        = (Get-Control 'NavWelcomeText')
    NavSelectionText      = (Get-Control 'NavSelectionText')
    NavHostSetupText      = (Get-Control 'NavHostSetupText')
    NavSteamDeckText      = (Get-Control 'NavSteamDeckText')
    NavDualBootText       = (Get-Control 'NavDualBootText')
    NavReviewText         = (Get-Control 'NavReviewText')
    NavRunText            = (Get-Control 'NavRunText')

    # Bottom nav
    BackButton            = (Get-Control 'BackButton')
    NextButton            = (Get-Control 'NextButton')
    FinishButton          = (Get-Control 'FinishButton')
    StatusLabel           = (Get-Control 'StatusLabel')
    StepLabel             = (Get-Control 'StepLabel')

    # Welcome
    WelcomeTitleLabel     = (Get-Control 'WelcomeTitleLabel')
    WelcomeSubtitleLabel  = (Get-Control 'WelcomeSubtitleLabel')
    LanguageCombo         = (Get-Control 'LanguageCombo')
    QuickPresetsLabel     = (Get-Control 'QuickPresetsLabel')
    CustomPresetsLabel    = (Get-Control 'CustomPresetsLabel')
    PresetNameLabel       = (Get-Control 'PresetNameLabel')
    PresetNameTextBox     = (Get-Control 'PresetNameTextBox')
    SavePresetButton      = (Get-Control 'SavePresetButton')
    CustomPresetCombo     = (Get-Control 'CustomPresetCombo')
    LoadPresetButton      = (Get-Control 'LoadPresetButton')
    DeletePresetButton    = (Get-Control 'DeletePresetButton')
    PresetButtons         = @{
        'recommended'          = (Get-Control 'PresetRecommended')
        'legacy'               = (Get-Control 'PresetLegacy')
        'full'                 = (Get-Control 'PresetFull')
        'steamdeck-recommended' = (Get-Control 'PresetSteamdeckRec')
        'steamdeck-full'       = (Get-Control 'PresetSteamdeckFull')
    }

    # Selection
    SelectionTitleLabel   = (Get-Control 'SelectionTitleLabel')
    FilterTextBox         = (Get-Control 'FilterTextBox')
    ProfilesLabel         = (Get-Control 'ProfilesLabel')
    ProfilesTree          = (Get-Control 'ProfilesTree')
    ComponentsLabel       = (Get-Control 'ComponentsLabel')
    ComponentsTree        = (Get-Control 'ComponentsTree')
    ExcludeLabel          = (Get-Control 'ExcludeLabel')
    ExcludeList           = (Get-Control 'ExcludeList')
    DetailsLabel          = (Get-Control 'DetailsLabel')
    DetailsTextBox        = (Get-Control 'DetailsTextBox')
    SelectionSummaryLabel = (Get-Control 'SelectionSummaryLabel')
    SelectionErrorLabel   = (Get-Control 'SelectionErrorLabel')

    # Host Setup
    HostTitleLabel        = (Get-Control 'HostTitleLabel')
    HostHealthLabel       = (Get-Control 'HostHealthLabel')
    HostHealthCombo       = (Get-Control 'HostHealthCombo')
    SteamDeckVersionLabel = (Get-Control 'SteamDeckVersionLabel')
    SteamDeckVersionCombo = (Get-Control 'SteamDeckVersionCombo')
    WorkspaceRootLabel    = (Get-Control 'WorkspaceRootLabel')
    WorkspaceRootTextBox  = (Get-Control 'WorkspaceRootTextBox')
    WorkspaceBrowseButton = (Get-Control 'WorkspaceBrowseButton')
    CloneBaseDirLabel     = (Get-Control 'CloneBaseDirLabel')
    CloneBaseDirTextBox   = (Get-Control 'CloneBaseDirTextBox')
    CloneBrowseButton     = (Get-Control 'CloneBrowseButton')
    AdminNeedsTitleLabel  = (Get-Control 'AdminNeedsTitleLabel')
    AdminNeedsTextBox     = (Get-Control 'AdminNeedsTextBox')

    # Steam Deck Control
    SteamDeckTitleLabel   = (Get-Control 'SteamDeckTitleLabel')
    MonitorProfilesLabel  = (Get-Control 'MonitorProfilesLabel')
    MonitorProfilesGrid   = (Get-Control 'MonitorProfilesGrid')
    MonitorFamiliesLabel  = (Get-Control 'MonitorFamiliesLabel')
    MonitorFamiliesGrid   = (Get-Control 'MonitorFamiliesGrid')
    GenericGroupLabel     = (Get-Control 'GenericGroupLabel')
    GenericModeLabel      = (Get-Control 'GenericModeLabel')
    GenericModeCombo      = (Get-Control 'GenericModeCombo')
    GenericLayoutLabel    = (Get-Control 'GenericLayoutLabel')
    GenericLayoutTextBox  = (Get-Control 'GenericLayoutTextBox')
    GenericResolutionLabel = (Get-Control 'GenericResolutionLabel')
    GenericResolutionTextBox = (Get-Control 'GenericResolutionTextBox')
    SessionGroupLabel     = (Get-Control 'SessionGroupLabel')
    HandheldSessionLabel  = (Get-Control 'HandheldSessionLabel')
    HandheldSessionTextBox = (Get-Control 'HandheldSessionTextBox')
    DockTvSessionLabel    = (Get-Control 'DockTvSessionLabel')
    DockTvSessionTextBox  = (Get-Control 'DockTvSessionTextBox')
    DockMonitorSessionLabel = (Get-Control 'DockMonitorSessionLabel')
    DockMonitorSessionTextBox = (Get-Control 'DockMonitorSessionTextBox')
    WatcherStatusLabel    = (Get-Control 'WatcherStatusLabel')
    UnknownMonitorHintLabel = (Get-Control 'UnknownMonitorHintLabel')
    ReloadSettingsButton  = (Get-Control 'ReloadSettingsButton')
    SaveSettingsButton    = (Get-Control 'SaveSettingsButton')

    # Dual Boot
    DualBootTitleLabel    = (Get-Control 'DualBootTitleLabel')
    DualBootStatusText    = (Get-Control 'DualBootStatusText')
    DualBootPrereqsText   = (Get-Control 'DualBootPrereqsText')
    FixFastStartupButton  = (Get-Control 'FixFastStartupButton')
    DualBootTargetCombo   = (Get-Control 'DualBootTargetCombo')
    RebootToLinuxButton   = (Get-Control 'RebootToLinuxButton')
    BcdCleanupStatusText  = (Get-Control 'BcdCleanupStatusText')
    BcdCleanupButton      = (Get-Control 'BcdCleanupButton')
    RefreshDualBootButton = (Get-Control 'RefreshDualBootButton')

    # Review
    ReviewTitleLabel      = (Get-Control 'ReviewTitleLabel')
    ReviewSummaryLabel    = (Get-Control 'ReviewSummaryLabel')
    RefreshReviewButton   = (Get-Control 'RefreshReviewButton')
    ReviewMetaLabel       = (Get-Control 'ReviewMetaLabel')
    ReviewTextBox         = (Get-Control 'ReviewTextBox')

    # Run
    RunTitleLabel         = (Get-Control 'RunTitleLabel')
    RunStatusLabel        = (Get-Control 'RunStatusLabel')
    RunEtaLabel           = (Get-Control 'RunEtaLabel')
    RunProgressBar        = (Get-Control 'RunProgressBar')
    StartRunButton        = (Get-Control 'StartRunButton')
    CancelRunButton       = (Get-Control 'CancelRunButton')
    DryRunCheckBox        = (Get-Control 'DryRunCheckBox')
    OpenLogButton         = (Get-Control 'OpenLogButton')
    OpenResultButton      = (Get-Control 'OpenResultButton')
    OpenSettingsButton    = (Get-Control 'OpenSettingsButton')
    OpenReportsButton     = (Get-Control 'OpenReportsButton')
    RunLogTextBox         = (Get-Control 'RunLogTextBox')

    # Pages (panels identified by WPF name)
    PageNames             = @('PageWelcome', 'PageSelection', 'PageHostSetup', 'PageSteamDeck', 'PageDualBoot', 'PageReview', 'PageRun')
}

# 
# DispatcherTimer (replaces WinForms Timer)
# 

$logTimer = New-Object System.Windows.Threading.DispatcherTimer
$logTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$ui.LogTimer = $logTimer

# 
# Helper: WPF DataGrid population
# 

function Load-WpfGridRows {
    param(
        [Parameter(Mandatory=$true)]$Grid,
        [Parameter(Mandatory=$true)]$Items,
        [Parameter(Mandatory=$true)][string[]]$Columns
    )
    $table = New-Object System.Data.DataTable
    foreach ($col in $Columns) { [void]$table.Columns.Add($col) }
    foreach ($item in @($Items)) {
        $row = $table.NewRow()
        foreach ($col in $Columns) {
            $row[$col] = if ($item -is [hashtable] -and $item.ContainsKey($col)) { [string]$item[$col] }
                         elseif ($item.PSObject.Properties[$col]) { [string]$item.$col }
                         else { '' }
        }
        $table.Rows.Add($row)
    }
    $Grid.ItemsSource = $table.DefaultView
}

function Read-WpfGridRows {
    param(
        [Parameter(Mandatory=$true)]$Grid,
        [Parameter(Mandatory=$true)][string[]]$Columns
    )
    $rows = @()
    if ($null -eq $Grid.ItemsSource) { return $rows }
    foreach ($rowView in $Grid.ItemsSource) {
        $row = $rowView.Row
        $item = [ordered]@{}
        $hasData = $false
        foreach ($col in $Columns) {
            $val = [string]$row[$col]
            if (-not [string]::IsNullOrWhiteSpace($val)) { $hasData = $true }
            $item[$col] = $val
        }
        if ($hasData) { $rows += @($item) }
    }
    return @($rows)
}

# 
# Helpers (same logic, updated control references)
# 

function Quote-CommandArgument {
    param([Parameter(Mandatory=$true)][string]$Value)
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
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

function Get-SelectionDetailsText {
    param(
        [AllowNull()]$Item,
        [Parameter(Mandatory=$true)][string]$Kind
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

function Apply-QuickPreset {
    param([Parameter(Mandatory=$true)][string]$PresetName)
    $ui.State.selectedProfiles   = @($PresetName)
    $ui.State.selectedComponents = @()
    $ui.State.excludedComponents = @()
    $ui.State.hostHealth         = if ($PresetName -eq 'legacy') { 'off' } else { 'conservador' }
    $ui.State.steamDeckVersion   = 'Auto'
}

function Refresh-CustomPresets {
    $ui.CustomPresetCombo.Items.Clear()
    foreach ($presetName in @($ui.State.customPresets.Keys | Sort-Object)) {
        [void]$ui.CustomPresetCombo.Items.Add($presetName)
    }
}

function Refresh-LocalizedText {
    $ui.Strings = Get-UiStrings -Language ([string]$ui.State.language)
    $ui.Window.Title                   = $ui.Strings.WindowTitle
    $ui.WelcomeTitleLabel.Text         = $ui.Strings.WelcomeTitle
    $ui.WelcomeSubtitleLabel.Text      = $ui.Strings.WelcomeSubtitle
    $ui.QuickPresetsLabel.Text         = $ui.Strings.QuickPresets.ToUpper()
    $ui.CustomPresetsLabel.Text        = $ui.Strings.CustomPresets.ToUpper()
    $ui.PresetNameLabel.Text           = $ui.Strings.PresetName
    $ui.SavePresetButton.Content       = "  $($ui.Strings.SavePreset)"
    $ui.LoadPresetButton.Content       = "  $($ui.Strings.LoadPreset)"
    $ui.DeletePresetButton.Content     = "  $($ui.Strings.DeletePreset)"
    $ui.SelectionTitleLabel.Text       = $ui.Strings.SelectionTitle
    $ui.ProfilesLabel.Text             = $ui.Strings.Profiles.ToUpper()
    $ui.ComponentsLabel.Text           = $ui.Strings.Components.ToUpper()
    $ui.ExcludeLabel.Text              = $ui.Strings.Excludes.ToUpper()
    $ui.DetailsLabel.Text              = $ui.Strings.SelectionDetails.ToUpper()
    $ui.HostTitleLabel.Text            = $ui.Strings.HostSetupTitle
    $ui.HostHealthLabel.Text           = $ui.Strings.HostHealth
    $ui.SteamDeckVersionLabel.Text     = $ui.Strings.SteamDeckVersion
    $ui.WorkspaceRootLabel.Text        = $ui.Strings.WorkspaceRoot
    $ui.CloneBaseDirLabel.Text         = $ui.Strings.CloneBaseDir
    $ui.WorkspaceBrowseButton.Content  = " $($ui.Strings.Browse)"
    $ui.CloneBrowseButton.Content      = " $($ui.Strings.Browse)"
    $ui.AdminNeedsTitleLabel.Text      = $ui.Strings.AdminNeeds.ToUpper()
    $ui.SteamDeckTitleLabel.Text       = $ui.Strings.SteamDeckCenterTitle
    $ui.MonitorProfilesLabel.Text      = $ui.Strings.MonitorProfiles.ToUpper()
    $ui.MonitorFamiliesLabel.Text      = $ui.Strings.MonitorFamilies.ToUpper()
    $ui.GenericGroupLabel.Text         = $ui.Strings.GenericExternal.ToUpper()
    $ui.GenericModeLabel.Text          = $ui.Strings.GenericMode
    $ui.GenericLayoutLabel.Text        = $ui.Strings.GenericLayout
    $ui.GenericResolutionLabel.Text    = $ui.Strings.GenericResolution
    $ui.SessionGroupLabel.Text         = $ui.Strings.SessionProfiles.ToUpper()
    $ui.HandheldSessionLabel.Text      = $ui.Strings.SessionHandheld
    $ui.DockTvSessionLabel.Text        = $ui.Strings.SessionDockedTv
    $ui.DockMonitorSessionLabel.Text   = $ui.Strings.SessionDockedMonitor
    $ui.UnknownMonitorHintLabel.Text   = $ui.Strings.UnknownMonitorHint
    $ui.SaveSettingsButton.Content     = " $($ui.Strings.SaveSettings)"
    $ui.ReloadSettingsButton.Content   = " $($ui.Strings.ReloadSettings)"
    $ui.ReviewTitleLabel.Text          = $ui.Strings.ReviewTitle
    $ui.ReviewSummaryLabel.Text        = "$($ui.Strings.ReviewSummary)"
    $ui.RefreshReviewButton.Content    = " $($ui.Strings.RefreshReview)"
    $ui.RunTitleLabel.Text             = $ui.Strings.RunTitle
    $ui.StartRunButton.Content         = $ui.Strings.StartRun
    $ui.OpenLogButton.Content          = " $($ui.Strings.OpenLog)"
    $ui.OpenResultButton.Content       = " $($ui.Strings.OpenResult)"
    $ui.OpenSettingsButton.Content     = "⚙ $($ui.Strings.OpenSettings)"
    $ui.OpenReportsButton.Content      = " $($ui.Strings.OpenReports)"
    $ui.BackButton.Content             = $ui.Strings.Back
    $ui.NextButton.Content             = $ui.Strings.Next
    $ui.FinishButton.Content           = $ui.Strings.Finish
    $ui.StatusLabel.Text               = $ui.Strings.IdleStatus
    # Sidebar nav text
    $ui.NavWelcomeText.Text    = $ui.Strings.Welcome
    $ui.NavSelectionText.Text  = $ui.Strings.Selection
    $ui.NavHostSetupText.Text  = $ui.Strings.HostSetup
    $ui.NavSteamDeckText.Text  = $ui.Strings.SteamDeckControl
    $ui.NavDualBootText.Text   = $ui.Strings.DualBoot
    $ui.NavReviewText.Text     = $ui.Strings.Review
    $ui.NavRunText.Text        = $ui.Strings.Run
}

function Refresh-SelectionTrees {
    $filter = ($ui.FilterTextBox.Text).Trim().ToLowerInvariant()
    $ui.SuppressSelectionEvents = $true
    try {
        $ui.ProfilesTree.Items.Clear()
        foreach ($profile in @($ui.Contract.profiles | Where-Object {
            ($filter -eq '') -or ($_.name.ToLowerInvariant().Contains($filter)) -or ($_.description.ToLowerInvariant().Contains($filter))
        })) {
            $item = New-Object System.Windows.Controls.TreeViewItem
            $item.Header   = $profile.name
            $item.Tag      = @{ kind = 'profile'; item = $profile }
            $item.Foreground = [System.Windows.Media.Brushes]::LightSlateGray
            # CheckBox inside item header
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content    = $profile.name
            $cb.IsChecked  = (@($ui.State.selectedProfiles) -contains $profile.name)
            $cb.Foreground = [System.Windows.Media.Brushes]::LightSlateGray
            $cb.Tag        = @{ kind = 'profile'; item = $profile; name = $profile.name }
            $item.Header   = $cb
            $cb.Add_Checked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                if (-not (@($ui.State.selectedProfiles) -contains $name)) {
                    $ui.State.selectedProfiles = @(@($ui.State.selectedProfiles) + $name)
                    Save-UiState -State $ui.State -Path $UiStatePath
                    Refresh-SelectionSummary
                }
            })
            $cb.Add_Unchecked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                $ui.State.selectedProfiles = @(@($ui.State.selectedProfiles) | Where-Object { $_ -ne $name })
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-SelectionSummary
            })
            $item.Add_Selected({
                if ($this.Tag -and $this.Tag.item) {
                    $ui.DetailsTextBox.Text = Get-SelectionDetailsText -Item $this.Tag.item -Kind $this.Tag.kind
                }
            })
            [void]$ui.ProfilesTree.Items.Add($item)
        }

        $ui.ComponentsTree.Items.Clear()
        foreach ($component in @($ui.Contract.components | Where-Object {
            ($filter -eq '') -or ($_.name.ToLowerInvariant().Contains($filter)) -or ($_.description.ToLowerInvariant().Contains($filter))
        })) {
            $item = New-Object System.Windows.Controls.TreeViewItem
            $item.Tag = @{ kind = 'component'; item = $component }
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content   = $component.name
            $cb.IsChecked = (@($ui.State.selectedComponents) -contains $component.name)
            $cb.Foreground = [System.Windows.Media.Brushes]::LightSlateGray
            $cb.Tag = @{ kind = 'component'; item = $component; name = $component.name }
            $item.Header = $cb
            $cb.Add_Checked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                if (-not (@($ui.State.selectedComponents) -contains $name)) {
                    $ui.State.selectedComponents = @(@($ui.State.selectedComponents) + $name)
                    Save-UiState -State $ui.State -Path $UiStatePath
                    Refresh-SelectionSummary
                }
            })
            $cb.Add_Unchecked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                $ui.State.selectedComponents = @(@($ui.State.selectedComponents) | Where-Object { $_ -ne $name })
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-SelectionSummary
            })
            $item.Add_Selected({
                if ($this.Tag -and $this.Tag.item) {
                    $ui.DetailsTextBox.Text = Get-SelectionDetailsText -Item $this.Tag.item -Kind $this.Tag.kind
                }
            })
            [void]$ui.ComponentsTree.Items.Add($item)
        }
    } finally {
        $ui.SuppressSelectionEvents = $false
    }
}

function Refresh-ExcludeList {
    $ui.ExcludeList.Items.Clear()
    try {
        $selection     = New-BootstrapSelectionObject -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents @() -SelectedHostHealth $ui.State.hostHealth
        $baseResolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents @()
        foreach ($componentName in @($baseResolution.ResolvedComponents)) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content   = $componentName
            $cb.IsChecked = (@($ui.State.excludedComponents) -contains $componentName)
            $cb.Style     = $null
            $cb.Foreground = [System.Windows.Media.Brushes]::LightSlateGray
            $tname = $componentName
            $cb.Add_Checked({
                if (-not (@($ui.State.excludedComponents) -contains $tname)) {
                    $ui.State.excludedComponents = @(@($ui.State.excludedComponents) + $tname)
                    Save-UiState -State $ui.State -Path $UiStatePath
                }
            })
            $cb.Add_Unchecked({
                $ui.State.excludedComponents = @(@($ui.State.excludedComponents) | Where-Object { $_ -ne $tname })
                Save-UiState -State $ui.State -Path $UiStatePath
            })
            $li = New-Object System.Windows.Controls.ListBoxItem
            $li.Content = $cb
            $li.Background = [System.Windows.Media.Brushes]::Transparent
            [void]$ui.ExcludeList.Items.Add($li)
        }
    } catch { }
}

function Refresh-SelectionSummary {
    Refresh-ExcludeList
    try {
        $ui.Preview = Get-BootstrapPreviewData -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents $ui.State.excludedComponents -RequestedSteamDeckVersion $ui.State.steamDeckVersion -RequestedHostHealthMode $ui.State.hostHealth -RequestedWorkspaceRoot $ui.State.workspaceRoot -ExplicitCloneBaseDir $ui.State.cloneBaseDir
        $ui.SelectionSummaryLabel.Text = "Resolved: $(@($ui.Preview.Resolution.ResolvedComponents).Count) components | HostHealth: $($ui.Preview.ResolvedHostHealthMode)"
        $ui.SelectionErrorLabel.Text   = ''
    } catch {
        $ui.Preview = $null
        $ui.SelectionSummaryLabel.Text = ''
        $ui.SelectionErrorLabel.Text   = $_.Exception.Message
    }
}

function Refresh-HostSetupControls {
    $ui.HostHealthCombo.SelectedItem       = [string]$ui.State.hostHealth
    $ui.SteamDeckVersionCombo.SelectedItem = [string]$ui.State.steamDeckVersion
    $ui.WorkspaceRootTextBox.Text          = [string]$ui.State.workspaceRoot
    $ui.CloneBaseDirTextBox.Text           = [string]$ui.State.cloneBaseDir
    $ui.AdminNeedsTextBox.Text = if ($ui.Preview -and @($ui.Preview.AdminReasons).Count -gt 0) {
        @($ui.Preview.AdminReasons) -join [Environment]::NewLine
    } else { '-' }
}

function Refresh-SteamDeckStatus {
    $automationRoot = Get-BootstrapSteamDeckAutomationRoot
    $taskStatus = 'not found'
    try {
        $task = Get-ScheduledTask -TaskName 'BootstrapTools-SteamDeckModeWatcher' -ErrorAction Stop
        if ($task) { $taskStatus = 'registered' }
    } catch { $taskStatus = 'not found' }
    $watcherExists = Test-Path (Join-Path $automationRoot 'ModeWatcher.ps1')
    $hotkeyExists  = Test-Path (Join-Path $automationRoot 'SteamDeckHotkeys.ahk')
    $ui.WatcherStatusLabel.Text = "Task: $taskStatus  |  ModeWatcher: $watcherExists  |  Hotkeys: $hotkeyExists  |  Settings: $($ui.SettingsBundle.Path)"
}

function Refresh-SteamDeckControls {
    $ui.SettingsBundle = Get-BootstrapSteamDeckSettingsData -RequestedSteamDeckVersion ([string]$ui.State.steamDeckVersion) -ResolvedSteamDeckVersion 'lcd'
    $settings = ConvertTo-BootstrapHashtable -InputObject $ui.SettingsBundle.Data
    Load-WpfGridRows -Grid $ui.MonitorProfilesGrid -Items @($settings.monitorProfiles) -Columns @('manufacturer','product','serial','mode','layout','resolutionPolicy')
    Load-WpfGridRows -Grid $ui.MonitorFamiliesGrid -Items @($settings.monitorFamilies)  -Columns @('manufacturer','product','namePattern','mode','layout','resolutionPolicy')
    $ui.GenericModeCombo.SelectedItem      = [string]$settings.genericExternal.mode
    $ui.GenericLayoutTextBox.Text          = [string]$settings.genericExternal.layout
    $ui.GenericResolutionTextBox.Text      = [string]$settings.genericExternal.resolutionPolicy
    $ui.HandheldSessionTextBox.Text        = [string]$settings.sessionProfiles.HANDHELD
    $ui.DockTvSessionTextBox.Text          = [string]$settings.sessionProfiles.DOCKED_TV
    $ui.DockMonitorSessionTextBox.Text     = [string]$settings.sessionProfiles.DOCKED_MONITOR
    Refresh-SteamDeckStatus
}

function Capture-SteamDeckSettingsFromControls {
    $settings = ConvertTo-BootstrapHashtable -InputObject $ui.SettingsBundle.Data
    $settings['monitorProfiles']  = @(Read-WpfGridRows -Grid $ui.MonitorProfilesGrid -Columns @('manufacturer','product','serial','mode','layout','resolutionPolicy'))
    $settings['monitorFamilies']  = @(Read-WpfGridRows -Grid $ui.MonitorFamiliesGrid  -Columns @('manufacturer','product','namePattern','mode','layout','resolutionPolicy'))
    $settings['genericExternal']  = @{
        mode             = if ($ui.GenericModeCombo.SelectedItem) { [string]$ui.GenericModeCombo.SelectedItem } else { 'DOCKED_TV' }
        layout           = $ui.GenericLayoutTextBox.Text.Trim()
        resolutionPolicy = $ui.GenericResolutionTextBox.Text.Trim()
    }
    $settings['sessionProfiles']  = @{
        HANDHELD       = $ui.HandheldSessionTextBox.Text.Trim()
        DOCKED_TV      = $ui.DockTvSessionTextBox.Text.Trim()
        DOCKED_MONITOR = $ui.DockMonitorSessionTextBox.Text.Trim()
    }
    $settings['steamDeckVersion'] = [string]$ui.State.steamDeckVersion
    $ui.SettingsBundle = @{ Path = $ui.SettingsBundle.Path; Data = $settings }
}

function Save-SteamDeckSettingsInteractive {
    Capture-SteamDeckSettingsFromControls
    $saveResult = Save-BootstrapSteamDeckSettingsData -Settings $ui.SettingsBundle.Data -CreateBackup
    $ui.SettingsBackupPath         = $saveResult.BackupPath
    $ui.State.lastSettingsPath     = $saveResult.Path
    Save-UiState -State $ui.State -Path $UiStatePath
    $ui.StatusLabel.Text           = $ui.Strings.SavingSettings
    Refresh-SteamDeckStatus
}

function Refresh-DualBootControls {
    $ui.DualBootStatusText.Text = 'Lendo UEFI firmware e gerenciador de disco...'
    $info = Get-BootstrapDualBootInfo
    $recs = Get-BootstrapDualBootRecommendations -DualBootInfo $info
    
    $statusLines = @()
    $statusLines += "Is Dual Boot: $($info.IsDualBoot) (Confidence: $($info.Confidence))"
    $statusLines += "Sistemas Detectados: $(($info.DetectedOS) -join ', ')"
    $statusLines += "GRUB Detectado: $($info.GrubDetected) ($($info.GrubEfiPath))"
    $statusLines += "Partições Linux: $($info.LinuxPartitions.Count)"
    $statusLines += ""
    $statusLines += ($recs -join [Environment]::NewLine)
    
    if (-not $info.IsAdmin) {
        $statusLines += ""
        $statusLines += "⚠ AVISO: Executando sem privilégios de Administrador. Recursos avançados estão desabilitados."
        $ui.RebootToLinuxButton.IsEnabled = $false
        $ui.FixFastStartupButton.IsEnabled = $false
        $ui.DualBootTargetCombo.IsEnabled = $false
    } else {
        $ui.RebootToLinuxButton.IsEnabled = $info.IsDualBoot
        $ui.DualBootTargetCombo.IsEnabled = $true
    }
    $ui.DualBootStatusText.Text = ($statusLines -join [Environment]::NewLine)
    
    $prereqs = Test-BootstrapDualBootPrerequisites
    $fsIssue = $prereqs | Where-Object { $_.Id -eq 'fast-startup' } | Select-Object -First 1
    if ($prereqs.Count -eq 0 -or (-not $fsIssue)) {
        $ui.FixFastStartupButton.Visibility = 'Collapsed'
    } else {
        $ui.FixFastStartupButton.Visibility = 'Visible'
    }
    if ($prereqs.Count -gt 0) {
        $ui.DualBootPrereqsText.Text = ($prereqs | ForEach-Object { "[$($_.Severity.ToUpper())] $($_.Title): $($_.Description)" }) -join [Environment]::NewLine
    } else {
        $ui.DualBootPrereqsText.Text = "Nenhum problema detectado. Todas as configurações do Windows estão seguras para o Linux."
    }

    $alts = Get-BootstrapAlternateBootEntries
    $ui.DualBootTargetCombo.Items.Clear()
    foreach ($a in $alts) {
        $cbi = New-Object System.Windows.Controls.ComboBoxItem
        $cbi.Content = $a.Description
        $cbi.Tag = $a.Id
        [void]$ui.DualBootTargetCombo.Items.Add($cbi)
    }
    if ($ui.DualBootTargetCombo.Items.Count -gt 0) {
        $ui.DualBootTargetCombo.SelectedIndex = 0
    }

    $phantomCount = -1
    $ui.BcdCleanupButton.Visibility = 'Collapsed'
    if (Test-IsAdmin) {
        $phantoms = Get-BootstrapPhantomBootEntries
        $phantomCount = $phantoms.Count
        if ($phantomCount -gt 0) {
            $ui.BcdCleanupStatusText.Text = "Detectado lixo no BCD. Existem $phantomCount entradas 'fantasmas' no Menu do Windows concorrendo pelo loader."
            $ui.BcdCleanupButton.Visibility = 'Visible'
            $ui.BcdCleanupButton.IsEnabled = $true
        } else {
            $ui.BcdCleanupStatusText.Text = "Menu de Boot limpo! Nenhuma instalação órfã do Windows detectada."
        }
    } else {
        $ui.BcdCleanupStatusText.Text = "Requer privilégios de Administrador para auditar o Boot Configuration Data."
    }
}

function Refresh-ReviewPage {
    Capture-SteamDeckSettingsFromControls
    $ui.Preview = Get-BootstrapPreviewData -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents $ui.State.excludedComponents -RequestedSteamDeckVersion $ui.State.steamDeckVersion -RequestedHostHealthMode $ui.State.hostHealth -RequestedWorkspaceRoot $ui.State.workspaceRoot -ExplicitCloneBaseDir $ui.State.cloneBaseDir

    $preflightLines = @()
    if ($ui.Preview.Preflight) {
        $preflightLines += '--- Pré-flight ---'
        foreach ($chk in @($ui.Preview.Preflight)) {
            $sev = [string]$chk.Severity
            $marker = switch ($sev) { 'error' { '[X]' } 'warning' { '[!]' } 'ok' { '[v]' } default { '[i]' } }
            $preflightLines += ('{0} {1}' -f $marker, $chk.Title)
            if ($chk.Detail) { $preflightLines += ('     {0}' -f $chk.Detail) }
        }
        $preflightLines += ''
    }
    $ui.ReviewTextBox.Text  = (($preflightLines -join [Environment]::NewLine) + $ui.Preview.PlanText)

    $adminText = if (@($ui.Preview.AdminReasons).Count -gt 0) { @($ui.Preview.AdminReasons) -join '; ' } else { '-' }
    $ui.ReviewMetaLabel.Text = "Admin: $adminText  |  ETA: $($ui.Preview.EstimatedTime)  |  Settings: $($ui.SettingsBundle.Path)"
}

# 
# Navigation
# 

$navButtons = @(
    $ui.NavWelcome,
    $ui.NavSelection,
    $ui.NavHostSetup,
    $ui.NavSteamDeck,
    $ui.NavDualBoot,
    $ui.NavReview,
    $ui.NavRun
)

function Navigate-ToPage {
    param([int]$Index)
    $pageIds = @(Get-UiPageIds)
    if ($Index -lt 0 -or $Index -ge $pageIds.Count) { return }
    $ui.CurrentPageIndex = $Index

    # Show/hide pages
    foreach ($pageName in $ui.PageNames) {
        $ctrl = $window.FindName($pageName)
        if ($ctrl) { $ctrl.Visibility = 'Collapsed' }
    }
    $activePage = $window.FindName($ui.PageNames[$Index])
    if ($activePage) { $activePage.Visibility = 'Visible' }

    # Toggle nav buttons
    for ($i = 0; $i -lt $navButtons.Count; $i++) {
        $navButtons[$i].IsChecked = ($i -eq $Index)
    }

    # Back/Next state
    $ui.BackButton.IsEnabled = ($Index -gt 0)
    $ui.NextButton.IsEnabled = ($Index -lt ($pageIds.Count - 1))

    $stepName = switch ($pageIds[$Index]) {
        'welcome'          { $ui.Strings.Welcome }
        'selection'        { $ui.Strings.Selection }
        'host-setup'       { $ui.Strings.HostSetup }
        'steamdeck-control' { $ui.Strings.SteamDeckControl }
        'dual-boot'        { $ui.Strings.DualBoot }
        'review'           { $ui.Strings.Review }
        default            { $ui.Strings.Run }
    }
    $ui.StepLabel.Text = "{0} / {1}  -  {2}" -f ($Index + 1), $pageIds.Count, $stepName

    switch ($pageIds[$Index]) {
        'selection'         { Refresh-SelectionTrees; Refresh-SelectionSummary }
        'host-setup'        { Refresh-SelectionSummary; Refresh-HostSetupControls }
        'steamdeck-control' { Refresh-SteamDeckControls }
        'dual-boot'         { Refresh-DualBootControls }
        'review'            { Refresh-ReviewPage; Refresh-HostSetupControls }
    }
}

# 
# Process helpers
# 

function Build-BackendArguments {
    $tokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backendScriptPath, '-NonInteractive')
    foreach ($p in @($ui.State.selectedProfiles))   { $tokens += @('-ProfileName', [string]$p) }
    foreach ($c in @($ui.State.selectedComponents)) { $tokens += @('-Component', [string]$c) }
    foreach ($e in @($ui.State.excludedComponents)) { $tokens += @('-Exclude',   [string]$e) }
    $tokens += @('-SteamDeckVersion', [string]$ui.State.steamDeckVersion)
    $tokens += @('-HostHealth',       [string]$ui.State.hostHealth)
    $tokens += @('-WorkspaceRoot',    [string]$ui.State.workspaceRoot)
    $tokens += @('-CloneBaseDir',     [string]$ui.State.cloneBaseDir)
    $tokens += @('-LogPath',          [string]$ui.CurrentLogPath)
    $tokens += @('-ResultPath',       [string]$ui.CurrentResultPath)
    if ($ui.DryRunCheckBox.IsChecked -eq $true) { $tokens += '-DryRun' }
    return $tokens
}

function Start-BackendWorker {
    $powershellExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentString  = ConvertTo-ArgumentString -Tokens (Build-BackendArguments)
    $needsAdmin = ($ui.Preview -and @($ui.Preview.AdminReasons).Count -gt 0 -and -not (Test-IsAdmin))
    if ($needsAdmin) { return (Start-Process -FilePath $powershellExe -ArgumentList $argumentString -Verb RunAs -WindowStyle Hidden -PassThru) }
    return (Start-Process -FilePath $powershellExe -ArgumentList $argumentString -WindowStyle Hidden -PassThru)
}

function Update-RunProgressFromLog {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $total = 0
    if ($ui.Preview -and $ui.Preview.Resolution) {
        $total = @($ui.Preview.Resolution.ResolvedComponents).Count
    }
    if ($total -le 0) { return }
    $matches = [regex]::Matches($Text, '(?m)^\[[^\]]+\]\s+\[INFO\]\s+Executando componente:\s+(\S+)')
    if ($matches.Count -gt 0) {
        $current = $matches[$matches.Count - 1].Groups[1].Value
        $index = ([Array]::IndexOf(@($ui.Preview.Resolution.ResolvedComponents), $current))
        if ($index -lt 0) { $index = $matches.Count - 1 }
        $percent = [int](($index + 1) / $total * 100)
        if ($percent -gt 100) { $percent = 100 }
        $ui.RunProgressBar.Value = $percent
        $ui.RunStatusLabel.Text = ('{0}: {1}/{2}  -  {3}' -f $ui.Strings.Progress, ($index + 1), $total, $current)
        $elapsed = (Get-Date) - $ui.RunStartTime
        if ($percent -gt 0) {
            $estTotal = $elapsed.TotalSeconds * (100.0 / $percent)
            $remain = [TimeSpan]::FromSeconds([math]::Max(0, $estTotal - $elapsed.TotalSeconds))
            $ui.RunEtaLabel.Text = ('ETA ~ {0:mm\:ss}' -f $remain)
        }
    }
}

function Append-RunLog {
    if ([string]::IsNullOrWhiteSpace($ui.CurrentLogPath) -or -not (Test-Path $ui.CurrentLogPath)) { return }
    $content = [IO.File]::ReadAllText($ui.CurrentLogPath)
    if ($content.Length -le $ui.LogOffset) { return }
    $newText = $content.Substring($ui.LogOffset)
    $ui.RunLogTextBox.AppendText($newText)
    $ui.RunLogTextBox.ScrollToEnd()
    $ui.LogOffset = $content.Length
    Update-RunProgressFromLog -Text $content
}

function Finalize-RunFromResult {
    Append-RunLog
    $finalText = ''
    if (Test-Path $ui.CurrentResultPath) {
        $result = Get-Content -Path $ui.CurrentResultPath -Raw | ConvertFrom-Json
        if ($result.status -eq 'success') {
            $ui.RunStatusLabel.Text = $ui.Strings.RunCompleted
            $ui.RunProgressBar.Value = 100
            if ($result.hostHealthReportRoot) { $ui.State.lastReportPath = [string]$result.hostHealthReportRoot }
        } else {
            $ui.RunStatusLabel.Text = "{0}  {1}" -f $ui.Strings.RunFailed, [string]$result.error
        }
    } elseif ($ui.RunCanceled) {
        $ui.RunStatusLabel.Text = $ui.Strings.RunCanceled
    } else {
        $ui.RunStatusLabel.Text = $ui.Strings.RunFailed
    }
    $ui.State.lastLogPath    = $ui.CurrentLogPath
    $ui.State.lastResultPath = $ui.CurrentResultPath
    Save-UiState -State $ui.State -Path $UiStatePath
    $ui.RunProcess = $null
    $ui.LogTimer.Stop()
    $ui.StartRunButton.IsEnabled = $true
    $ui.CancelRunButton.IsEnabled = $false
}

function Start-RunExecution {
    Save-SteamDeckSettingsInteractive
    Refresh-ReviewPage
    $runRoot             = Join-Path (Get-BootstrapDataRoot) 'ui-runs'
    $timestamp           = Get-Date -Format 'yyyyMMdd_HHmmss'
    $ui.CurrentLogPath   = Join-Path $runRoot ("bootstrap-ui_{0}.log" -f $timestamp)
    $ui.CurrentResultPath = Join-Path $runRoot ("bootstrap-ui_{0}.result.json" -f $timestamp)
    $ui.LogOffset        = 0
    $ui.RunCanceled      = $false
    $ui.RunStartTime     = Get-Date
    $ui.RunLogTextBox.Clear()
    $ui.RunProgressBar.Value = 0
    $ui.RunStatusLabel.Text = $ui.Strings.RunStarted
    $ui.RunEtaLabel.Text = ''
    try { $ui.RunProcess = Start-BackendWorker } catch {
        $ui.RunStatusLabel.Text = $ui.Strings.UserCanceledElevation
        return
    }
    $ui.StartRunButton.IsEnabled = $false
    $ui.CancelRunButton.IsEnabled = $true
    Save-UiStateImmediate -State $ui.State -Path $UiStatePath
    $ui.LogTimer.Start()
}

function Stop-ProcessTreeById {
    param([Parameter(Mandatory = $true)][int]$Pid)
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    if (Test-Path $taskkill) {
        try { & $taskkill '/T' '/F' '/PID' $Pid 2>$null | Out-Null; return } catch { }
    }
    try {
        $children = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$Pid" -ErrorAction SilentlyContinue)
        foreach ($c in $children) { Stop-ProcessTreeById -Pid ([int]$c.ProcessId) }
    } catch { }
    try { Stop-Process -Id $Pid -Force -ErrorAction SilentlyContinue } catch { }
}

function Cancel-RunExecution {
    if (-not $ui.RunProcess) { return }
    if ($ui.RunProcess.HasExited) { return }
    try {
        Stop-ProcessTreeById -Pid ([int]$ui.RunProcess.Id)
    } catch {
        try { $ui.RunProcess.Kill() } catch { }
    }
    $ui.RunCanceled = $true
    $ui.RunStatusLabel.Text = $ui.Strings.RunCanceled
    $ui.CancelRunButton.IsEnabled = $false
    $ui.StartRunButton.IsEnabled = $true
}

# 
# Event Handlers
# 

# Log timer
$logTimer.Add_Tick({
    Append-RunLog
    if ($ui.RunProcess -and $ui.RunProcess.HasExited -and (Test-Path $ui.CurrentResultPath)) {
        Finalize-RunFromResult
    }
})

# Language
$ui.LanguageCombo.Add_SelectionChanged({
    if ($ui.LanguageCombo.SelectedItem) {
        $ui.State.language = [string]$ui.LanguageCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-LocalizedText
        Navigate-ToPage -Index $ui.CurrentPageIndex
    }
})

# Quick preset buttons
foreach ($presetEntry in $ui.PresetButtons.GetEnumerator()) {
    $btnRef     = $presetEntry.Value
    $presetName = $presetEntry.Key
    $btnRef.Add_Click({
        Apply-QuickPreset -PresetName $presetName
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-SelectionTrees
        Refresh-SelectionSummary
        Refresh-HostSetupControls
        $ui.StatusLabel.Text = "Preset: $presetName"
    }.GetNewClosure())
}

# Custom preset actions
$ui.SavePresetButton.Add_Click({
    $presetName = $ui.PresetNameTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($presetName)) { return }
    $ui.State.customPresets[$presetName] = @{
        selectedProfiles   = @($ui.State.selectedProfiles)
        selectedComponents = @($ui.State.selectedComponents)
        excludedComponents = @($ui.State.excludedComponents)
        hostHealth         = [string]$ui.State.hostHealth
        steamDeckVersion   = [string]$ui.State.steamDeckVersion
        workspaceRoot      = [string]$ui.State.workspaceRoot
        cloneBaseDir       = [string]$ui.State.cloneBaseDir
    }
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-CustomPresets
})

$ui.LoadPresetButton.Add_Click({
    $presetName = if ($ui.CustomPresetCombo.SelectedItem) { [string]$ui.CustomPresetCombo.SelectedItem } else { '' }
    if ([string]::IsNullOrWhiteSpace($presetName)) { return }
    $preset = $ui.State.customPresets[$presetName]
    if (-not $preset) { return }
    $ui.State.selectedProfiles   = @(Normalize-BootstrapNames -Names @($preset.selectedProfiles))
    $ui.State.selectedComponents = @(Normalize-BootstrapNames -Names @($preset.selectedComponents))
    $ui.State.excludedComponents = @(Normalize-BootstrapNames -Names @($preset.excludedComponents))
    $ui.State.hostHealth         = [string]$preset.hostHealth
    $ui.State.steamDeckVersion   = [string]$preset.steamDeckVersion
    $ui.State.workspaceRoot      = [string]$preset.workspaceRoot
    $ui.State.cloneBaseDir       = [string]$preset.cloneBaseDir
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionTrees
    Refresh-SelectionSummary
    Refresh-HostSetupControls
})

$ui.DeletePresetButton.Add_Click({
    $presetName = if ($ui.CustomPresetCombo.SelectedItem) { [string]$ui.CustomPresetCombo.SelectedItem } else { '' }
    if ([string]::IsNullOrWhiteSpace($presetName)) { return }
    $ui.State.customPresets.Remove($presetName)
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-CustomPresets
})

# Filter
$ui.FilterTextBox.Add_TextChanged({ Refresh-SelectionTrees })

# Host Health
$ui.HostHealthCombo.Add_SelectionChanged({
    if ($ui.HostHealthCombo.SelectedItem) {
        $ui.State.hostHealth = [string]$ui.HostHealthCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-SelectionSummary
        Refresh-HostSetupControls
    }
})

# Steam Deck version
$ui.SteamDeckVersionCombo.Add_SelectionChanged({
    if ($ui.SteamDeckVersionCombo.SelectedItem) {
        $ui.State.steamDeckVersion = [string]$ui.SteamDeckVersionCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
    }
})

# Browse buttons
$ui.WorkspaceBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description  = $ui.Strings.WorkspaceRoot
    $dialog.SelectedPath = [string]$ui.State.workspaceRoot
    if ($dialog.ShowDialog() -eq 'OK') {
        $ui.WorkspaceRootTextBox.Text = $dialog.SelectedPath
        $ui.State.workspaceRoot       = $dialog.SelectedPath
        Save-UiState -State $ui.State -Path $UiStatePath
    }
})

$ui.CloneBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description  = $ui.Strings.CloneBaseDir
    $dialog.SelectedPath = [string]$ui.State.cloneBaseDir
    if ($dialog.ShowDialog() -eq 'OK') {
        $ui.CloneBaseDirTextBox.Text = $dialog.SelectedPath
        $ui.State.cloneBaseDir       = $dialog.SelectedPath
        Save-UiState -State $ui.State -Path $UiStatePath
    }
})

$ui.WorkspaceRootTextBox.Add_LostFocus({
    $ui.State.workspaceRoot = $ui.WorkspaceRootTextBox.Text.Trim()
    Save-UiState -State $ui.State -Path $UiStatePath
})

$ui.CloneBaseDirTextBox.Add_LostFocus({
    $ui.State.cloneBaseDir = $ui.CloneBaseDirTextBox.Text.Trim()
    Save-UiState -State $ui.State -Path $UiStatePath
})

# Steam Deck control
$ui.ReloadSettingsButton.Add_Click({ Refresh-SteamDeckControls; $ui.StatusLabel.Text = $ui.Strings.ReloadSettings })
$ui.SaveSettingsButton.Add_Click({ Save-SteamDeckSettingsInteractive })

# Review
$ui.RefreshReviewButton.Add_Click({ Refresh-ReviewPage })

# Dual Boot
$ui.RefreshDualBootButton.Add_Click({ Refresh-DualBootControls })

$ui.FixFastStartupButton.Add_Click({
    try {
        $res = Repair-BootstrapFastStartup
        if ($res.Changed) {
            $ui.StatusLabel.Text = "Fast Startup desabilitado com sucesso."
        }
        Refresh-DualBootControls
    } catch {
        $ui.StatusLabel.Text = "Erro: $_"
    }
})

$ui.RebootToLinuxButton.Add_Click({
    if ($ui.DualBootTargetCombo.SelectedItem) {
        $guid = [string]$ui.DualBootTargetCombo.SelectedItem.Tag
        try {
            $res = Invoke-BootstrapRebootToLinux -PreferredEntryGuid $guid -Force
            if ($res.Rebooted) {
                # UI vai fechar logo logo pelo shutdown
            }
        } catch {
            $ui.StatusLabel.Text = "Erro: $_"
        }
    }
})

$ui.BcdCleanupButton.Add_Click({
    try {
        $preview = Get-BootstrapPhantomBootEntriesPreview
        if (-not $preview -or $preview.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Nenhuma entrada fantasma detectada.', 'BCD Cleanup', 'OK', 'Information') | Out-Null
            return
        }
        $msg = ($preview.Lines -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine + 'Confirmar remoção e backup do BCD?'
        $result = [System.Windows.MessageBox]::Show($msg, 'BCD Cleanup - Confirmação', 'YesNo', 'Warning')
        if ($result -ne 'Yes') {
            $ui.StatusLabel.Text = 'BCD cleanup cancelado pelo usuário.'
            return
        }

        $ui.BcdCleanupButton.IsEnabled = $false
        $ui.BcdCleanupStatusText.Text = 'Realizando backup e limpando...'
        $res = Repair-BootstrapPhantomEntries
        if ($res.Success) {
            $ui.StatusLabel.Text = "Removidas $($res.Removed) entradas fantasmas. Backup em: $($res.Backup)"
        }
        Refresh-DualBootControls
    } catch {
        $ui.StatusLabel.Text = "Erro na limpeza: $_"
        $ui.BcdCleanupButton.IsEnabled = $true
    }
})

# Run
$ui.StartRunButton.Add_Click({ Start-RunExecution })
$ui.CancelRunButton.Add_Click({ Cancel-RunExecution })

$ui.OpenLogButton.Add_Click({
    $path = if (-not [string]::IsNullOrWhiteSpace($ui.CurrentLogPath)) { $ui.CurrentLogPath } else { [string]$ui.State.lastLogPath }
    Open-ExistingPath -Path $path
})
$ui.OpenResultButton.Add_Click({
    $path = if (-not [string]::IsNullOrWhiteSpace($ui.CurrentResultPath)) { $ui.CurrentResultPath } else { [string]$ui.State.lastResultPath }
    Open-ExistingPath -Path $path
})
$ui.OpenSettingsButton.Add_Click({ Open-ExistingPath -Path ([string]$ui.State.lastSettingsPath) })
$ui.OpenReportsButton.Add_Click({  Open-ExistingPath -Path ([string]$ui.State.lastReportPath) })

# Sidebar nav
for ($i = 0; $i -lt $navButtons.Count; $i++) {
    $idx = $i
    $navButtons[$i].Add_Click({ Navigate-ToPage -Index $idx }.GetNewClosure())
}

# Back / Next / Finish
$ui.BackButton.Add_Click({
    if ($ui.CurrentPageIndex -gt 0) { Navigate-ToPage -Index ($ui.CurrentPageIndex - 1) }
})
$ui.NextButton.Add_Click({
    $pageCount = @(Get-UiPageIds).Count
    if ($ui.CurrentPageIndex -lt ($pageCount - 1)) { Navigate-ToPage -Index ($ui.CurrentPageIndex + 1) }
})
$ui.FinishButton.Add_Click({
    Save-UiState -State $ui.State -Path $UiStatePath
    $window.Close()
})

# 
# Window lifecycle
# 

$window.Add_Loaded({
    [void]$ui.LanguageCombo.Items.Clear()
    foreach ($lang in (Get-UiLanguages)) { [void]$ui.LanguageCombo.Items.Add($lang) }
    $ui.LanguageCombo.SelectedItem = [string]$ui.State.language

    foreach ($item in @('off','conservador','equilibrado','agressivo')) { [void]$ui.HostHealthCombo.Items.Add($item) }
    foreach ($item in @('Auto','LCD','OLED')) { [void]$ui.SteamDeckVersionCombo.Items.Add($item) }
    foreach ($item in @('DOCKED_TV','DOCKED_MONITOR')) { [void]$ui.GenericModeCombo.Items.Add($item) }

    $hhDescriptions = $null
    try { $hhDescriptions = $ui.Contract.hostHealthDescriptions } catch { $hhDescriptions = $null }
    if ($hhDescriptions) {
        $ttLines = @()
        foreach ($mode in @('off','conservador','equilibrado','agressivo')) {
            $desc = $null
            try { $desc = $hhDescriptions.$mode } catch { $desc = $null }
            if ($desc) { $ttLines += ("$mode -> $desc") }
        }
        if ($ttLines.Count -gt 0) {
            $ui.HostHealthCombo.ToolTip = ($ttLines -join [Environment]::NewLine)
        }
    }

    $isDeck = $false
    try { $isDeck = [bool]$ui.Contract.isSteamDeckHardware } catch { $isDeck = $false }
    if ($isDeck -and ($ui.State.selectedProfiles.Count -eq 1) -and ($ui.State.selectedProfiles[0] -eq 'recommended')) {
        Apply-QuickPreset -PresetName 'steamdeck-recommended'
        Save-UiStateImmediate -State $ui.State -Path $UiStatePath
        $ui.StatusLabel.Text = 'Hardware Steam Deck detectado: preset steamdeck-recommended aplicado.'
    }

    Refresh-LocalizedText
    Refresh-CustomPresets
    Navigate-ToPage -Index 0
})

$window.Add_Closing({
    $ui.LogTimer.Stop()
    if ($ui.RunProcess -and -not $ui.RunProcess.HasExited) {
        try { Stop-ProcessTreeById -Pid ([int]$ui.RunProcess.Id) } catch { }
    }
    Save-UiStateImmediate -State $ui.State -Path $UiStatePath
    Flush-UiState
})

# 
# Run the WPF application
# 

$null = $window.ShowDialog()

