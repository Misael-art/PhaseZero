param(
    [string]$UiStatePath,
    [string]$UiLogPath,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

function Repair-UiWindowsEnvironment {
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot) -and -not [string]::IsNullOrWhiteSpace($env:WINDIR)) {
        $env:SystemRoot = $env:WINDIR
    }
    if ([string]::IsNullOrWhiteSpace($env:WINDIR) -and -not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $env:WINDIR = $env:SystemRoot
    }
}

Repair-UiWindowsEnvironment

function Get-UiStorageRootCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:USERPROFILE) {
        $candidates.Add((Join-Path $env:USERPROFILE '.bootstrap-tools'))
    }
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'bootstrap-tools'))
    }
    if ($env:TEMP) {
        $candidates.Add((Join-Path $env:TEMP 'bootstrap-tools'))
    }

    $cwdRoot = Join-Path (Get-Location).Path 'bootstrap-tools'
    $candidates.Add($cwdRoot)

    return @($candidates | Select-Object -Unique)
}

function Test-UiParentPathWritable {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $parent = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($parent)) { return $false }

    try {
        [void][System.IO.Directory]::CreateDirectory($parent)
        $probePath = Join-Path $parent ('.bootstrap-ui-write-probe-{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes('probe')
            $stream = [System.IO.File]::Open($probePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            } finally {
                $stream.Dispose()
            }
            [System.IO.File]::Delete($probePath)
            return $true
        } catch {
            try {
                if ([System.IO.File]::Exists($probePath)) {
                    [System.IO.File]::Delete($probePath)
                }
            } catch {
            }
            return $false
        }
    } catch {
        return $false
    }
}

function Resolve-UiStorageRoot {
    foreach ($candidate in @(Get-UiStorageRootCandidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $probeFile = Join-Path $candidate 'ui-state.probe.json'
        if (Test-UiParentPathWritable -Path $probeFile) {
            return $candidate
        }
    }

    throw 'Bootstrap UI não encontrou um diretório gravável para logs e estado local.'
}

function Resolve-UiWritablePath {
    param(
        [string]$RequestedPath,
        [Parameter(Mandatory = $true)][string]$FallbackRelativePath
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (Test-UiParentPathWritable -Path $RequestedPath) {
            return $RequestedPath
        }
    }

    return (Join-Path $script:UiStorageRoot $FallbackRelativePath)
}

$script:UiStorageRoot = Resolve-UiStorageRoot
$UiStatePath = Resolve-UiWritablePath -RequestedPath $UiStatePath -FallbackRelativePath 'ui-state.json'
$script:UiLogPath = Resolve-UiWritablePath -RequestedPath $UiLogPath -FallbackRelativePath (Join-Path 'logs' ("bootstrap-ui_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date)))

if (-not [string]::IsNullOrWhiteSpace($UiLogPath) -and ($script:UiLogPath -ne $UiLogPath)) {
    try {
        Write-Host ("[bootstrap-ui] UiLogPath fallback ativado: {0}" -f $script:UiLogPath)
    } catch {
    }
}
$uiLogParent = Split-Path -Path $script:UiLogPath -Parent
if ($uiLogParent) { $null = New-Item -Path $uiLogParent -ItemType Directory -Force }

function Write-UiLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    try {
        $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
        Add-Content -Path $script:UiLogPath -Value $line -Encoding utf8
    } catch {
    }
}

trap {
    try { Write-UiLog -Level 'ERROR' -Message (($_ | Out-String).Trim()) } catch { }
    throw
}

function Get-WindowsPowerShellExePath {
    $systemRoot = if ($env:SystemRoot) { $env:SystemRoot } else { $env:WINDIR }
    $system32 = Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $sysnative = Join-Path $systemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path $sysnative) { return $sysnative }
    }
    return $system32
}

function ConvertTo-ArgumentString {
    param([string[]]$Tokens)
    return [string]::Join(' ', @($Tokens | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }))
}

function Restart-InWindowsPowerShell {
    $powershellExe = Get-WindowsPowerShellExePath
    if (-not (Test-Path $powershellExe)) {
        throw "Windows PowerShell 5.1 não encontrado em $powershellExe"
    }

    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if (-not $SmokeTest) { $argumentList += '-STA' }
    $argumentList += @('-File', $PSCommandPath, '-UiStatePath', $UiStatePath, '-UiLogPath', $script:UiLogPath)
    if ($SmokeTest) { $argumentList += '-SmokeTest' }

    Write-UiLog -Message ("Relaunching in Windows PowerShell. Exe={0}  Args={1}" -f $powershellExe, (ConvertTo-Json $argumentList -Compress))

    if ($SmokeTest) {
        & $powershellExe @argumentList
        exit $LASTEXITCODE
    }

    Start-Process -FilePath $powershellExe -ArgumentList (ConvertTo-ArgumentString -Tokens $argumentList) | Out-Null
    exit 0
}

function Test-UiEnvironment {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Bootstrap UI requer Windows com interface desktop.'
    }

    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        Restart-InWindowsPowerShell
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "Bootstrap UI requer Windows PowerShell 5.1+. Versão atual: $($PSVersionTable.PSVersion)"
    }

    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw "Bootstrap UI requer FullLanguage. Modo atual: $($ExecutionContext.SessionState.LanguageMode)"
    }

    if (-not $SmokeTest -and -not [Environment]::UserInteractive) {
        throw 'Bootstrap UI requer uma sessão de usuário interativa.'
    }
}

Write-UiLog -Message ("Start. PSEdition={0}  PSVersion={1}  OS64={2}  Proc64={3}  User={4}  LangMode={5}  Interactive={6}  UiStatePath={7}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, [Environment]::Is64BitOperatingSystem, [Environment]::Is64BitProcess, $env:USERNAME, $ExecutionContext.SessionState.LanguageMode, [Environment]::UserInteractive, $UiStatePath)
Test-UiEnvironment

$backendScriptPath = Join-Path $PSScriptRoot 'bootstrap-tools.ps1'
if (-not (Test-Path $backendScriptPath)) {
    Write-UiLog -Level 'ERROR' -Message "bootstrap-tools.ps1 not found at $backendScriptPath"
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
    return @('welcome', 'selection', 'host-setup', 'app-tuning', 'api-center', 'api-catalog', 'steamdeck-control', 'dual-boot', 'review', 'run')
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
                SelectionTitle     = 'Guided Profile Selection'
                Filter             = 'Filter'
                Profiles           = 'Ready-made profiles'
                Components         = 'Tools to install'
                Excludes           = 'Do not install'
                SelectionDetails   = 'What this option does'
                QuickOptions       = 'Quick options'
                OptClaudePlugins   = 'Claude Code: plugins'
                OptClaudeProjectMcps = 'Claude Code: project MCP sync'
                OptOpenWebUI       = 'Local AI: Open WebUI (Docker)'
                HostSetupTitle     = 'Prepare this PC'
                AppTuningTitle      = 'Optimize Apps'
                AppTuningSubtitle   = 'Pre-configure installed tools by category and profile, with safe defaults.'
                AppTuningMode       = 'App tuning'
                AppTuningCategories = 'Categories'
                AppTuningItems      = 'Items'
                AppTuningRecommended = 'Mark recommended'
                AppTuningMarkCategory = 'Mark category'
                AppTuningClearCategory = 'Clear category'
                AppTuningAudit      = 'Audit now'
                AppTuningInstall    = 'Install'
                AppTuningConfigure  = 'Configure/Optimize'
                AppTuningUpdate     = 'Update'
                AppTuningStatus     = 'Safe and reversible app tuning. Category app-install lists individual apps for on-demand installs.'
                ApiCenterTitle      = 'API Keys Center'
                ApiProviderSummary  = 'Providers overview'
                ApiCredentials      = 'Saved keys (masked)'
                ApiUsage            = 'Where keys are used'
                ApiCreate           = 'Create new keys'
                ApiRefresh          = 'Refresh inventory'
                ApiSave             = 'Save credential'
                ApiValidate         = 'Test selected key'
                ApiValidateAll      = 'Test all keys'
                ApiActivate         = 'Use this key now'
                ApiImport           = 'Import raw file'
                ApiApply            = 'Configure apps'
                ApiCatalog          = 'Full catalog'
                ApiCatalogTitle     = 'Full Key Catalog'
                ApiCatalogSubtitle  = 'Researched provider list with possession, configured state, purpose, requirements and official links.'
                ApiCatalogBack      = '<- API Center'
                HostHealth         = 'Maintenance level'
                SteamDeckVersion   = 'Steam Deck model'
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
                UnknownMonitorHint = 'Unknown external monitors stay unclassified until you choose Monitor/Dev or TV/Game. Safe fallback: Desktop/Dev.'
                PendingExternal    = 'Pending unknown external display'
                ClassifyMonitor    = 'Monitor/Dev'
                ClassifyTv         = 'TV/Game'
                ReviewTitle        = 'Review'
                RefreshReview      = 'Refresh Review'
                ReviewSummary      = 'Preview equivalent to dry-run'
                ReviewSideEffects  = 'Side effects'
                RunTitle           = 'Run'
                StartRun           = '>  Start Execution'
                OpenLog            = 'Open Log'
                OpenResult         = 'Open Result'
                OpenSettings       = 'Open Settings'
                OpenReports        = 'Open Reports'
                IdleStatus         = 'Ready.'
                SavingSettings     = 'Settings saved.'
                RunStarted         = 'Execution started.'
                RunCompleted       = 'Execution completed.'
                RunFailed          = 'Execution failed.'
                UserCanceledElevation = 'Execution canceled or elevation denied.'
                Back               = '<- Back'
                Next               = 'Next ->'
                Finish             = 'Close'
                Welcome            = 'Welcome'
                Selection          = 'Selection'
                HostSetup          = 'Host Setup'
                AppTuning          = 'Optimize Apps'
                ApiCenter          = 'API Keys'
                SteamDeckControl   = 'Steam Deck Center'
                DualBoot           = 'Windows + Linux'
                Review             = 'Review'
                Run                = 'Run'
                GenericMode        = 'Mode'
                GenericLayout      = 'Layout'
                GenericResolution  = 'Resolution'
                DisplayMode        = 'Windows display mode'
                SessionHandheld    = 'HANDHELD'
                SessionDockedTv    = 'DOCKED_TV'
                SessionDockedMonitor = 'DOCKED_MONITOR'
            }
        }
        default {
            return @{
                WindowTitle        = 'Central Bootstrap Tools'
                WelcomeTitle       = 'Bootstrap Tools + Steam Deck'
                WelcomeSubtitle    = 'Setup simples do host, controle do Steam Deck e manutencao pos-instalacao.'
                Language           = 'Idioma'
                QuickPresets       = 'Presets Rapidos'
                CustomPresets      = 'Presets Personalizados'
                PresetName         = 'Nome do preset'
                SavePreset         = 'Salvar preset'
                LoadPreset         = 'Carregar preset'
                DeletePreset       = 'Excluir preset'
                SelectionTitle     = 'Escolha guiada de perfis'
                Filter             = 'Filtro'
                Profiles           = 'Perfis prontos'
                Components         = 'Ferramentas para instalar'
                Excludes           = 'Nao instalar'
                SelectionDetails   = 'O que esta opcao faz'
                QuickOptions       = 'Opcoes rapidas'
                OptClaudePlugins   = 'Claude Code: plugins'
                OptClaudeProjectMcps = 'Claude Code: sync MCP no projeto'
                OptOpenWebUI       = 'IA local: Open WebUI (Docker)'
                OptSkipManualRequirements = 'Pular requisitos manuais (bloqueantes)'
                OptIgnoreManualRequirements = 'Ignorar requisitos manuais (apenas log)'
                HostSetupTitle     = 'Preparacao deste PC'
                AppTuningTitle      = 'Otimizar Apps'
                AppTuningSubtitle   = 'Pre-configure ferramentas instaladas por categoria e perfil, com defaults seguros.'
                AppTuningMode       = 'AppTuning'
                AppTuningCategories = 'Categorias'
                AppTuningItems      = 'Itens'
                AppTuningRecommended = 'Marcar recomendados'
                AppTuningMarkCategory = 'Marcar categoria'
                AppTuningClearCategory = 'Limpar categoria'
                AppTuningAudit      = 'Auditar agora'
                AppTuningInstall    = 'Instalar'
                AppTuningConfigure  = 'Configurar/Otimizar'
                AppTuningUpdate     = 'Atualizar'
                AppTuningStatus     = 'Otimização segura e reversível dos apps. Categoria app-install lista apps individuais sob demanda.'
                ApiCenterTitle      = 'Central de Chaves e APIs'
                ApiProviderSummary  = 'Resumo dos provedores'
                ApiCredentials      = 'Chaves salvas (mascaradas)'
                ApiUsage            = 'Onde cada API sera usada'
                ApiCreate           = 'Criar novas chaves'
                ApiRefresh          = 'Atualizar inventario'
                ApiSave             = 'Salvar ou atualizar chave'
                ApiValidate         = 'Testar chave selecionada'
                ApiValidateAll      = 'Testar todas'
                ApiActivate         = 'Usar esta chave agora'
                ApiImport           = 'Importar arquivo bruto'
                ApiApply            = 'Configurar apps'
                ApiCatalog          = 'Catalogo completo'
                ApiCatalogTitle     = 'Catalogo completo de chaves'
                ApiCatalogSubtitle  = 'Lista pesquisada de provedores com posse, uso configurado, finalidade, requisitos e links oficiais.'
                ApiCatalogBack      = '<- Central de APIs'
                HostHealth         = 'Nivel de manutencao'
                SteamDeckVersion   = 'Modelo do Steam Deck'
                WorkspaceRoot      = 'Workspace Root'
                CloneBaseDir       = 'Diretorio Base de Clones'
                Browse             = 'Selecionar'
                AdminNeeds         = 'Revisao de Admin'
                SteamDeckCenterTitle = 'Central do Steam Deck'
                MonitorProfiles    = 'Monitores especificos'
                MonitorFamilies    = 'Familias de monitores'
                GenericExternal    = 'Regra padrao para monitor externo'
                SessionProfiles    = 'Perfis de uso'
                WatcherStatus      = 'Status do Watcher'
                SaveSettings       = 'Salvar Settings'
                ReloadSettings     = 'Recarregar Settings'
                UnknownMonitorHint = 'Monitores externos desconhecidos ficam pendentes ate voce escolher Monitor/Dev ou TV/Game. Fallback seguro: Desktop/Dev.'
                PendingExternal    = 'Monitor externo desconhecido pendente'
                ClassifyMonitor    = 'Monitor/Dev'
                ClassifyTv         = 'TV/Game'
                ReviewTitle        = 'Revisao'
                RefreshReview      = 'Atualizar Revisao'
                ReviewSummary      = 'Preview equivalente ao dry-run'
                ReviewSideEffects  = 'Efeitos colaterais'
                RunTitle           = 'Execucao'
                StartRun           = '>  Iniciar Execucao'
                OpenLog            = 'Abrir Log'
                OpenResult         = 'Abrir Resultado'
                OpenSettings       = 'Abrir Settings'
                OpenReports        = 'Abrir Relatorios'
                IdleStatus         = 'Pronto.'
                SavingSettings     = 'Settings salvos.'
                RunStarted         = 'Execucao iniciada.'
                RunCompleted       = 'Execucao concluida.'
                RunFailed          = 'Execucao falhou.'
                UserCanceledElevation = 'Execucao cancelada ou elevacao negada.'
                Back               = '<- Voltar'
                Next               = 'Avancar ->'
                Finish             = 'Fechar'
                Welcome            = 'Inicio'
                Selection          = 'Escolher'
                HostSetup          = 'Configurar PC'
                AppTuning          = 'Otimizar Apps'
                ApiCenter          = 'Chaves (APIs)'
                SteamDeckControl   = 'Steam Deck'
                DualBoot           = 'Windows e Linux'
                Review             = 'Revisar'
                Run                = 'Executar'
                GenericMode        = 'Modo'
                GenericLayout      = 'Layout'
                GenericResolution  = 'Resolucao'
                DisplayMode        = 'Modo de exibicao'
                SessionHandheld    = 'HANDHELD'
                SessionDockedTv    = 'DOCKED_TV'
                SessionDockedMonitor = 'DOCKED_MONITOR'
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
        enableClaudeCodeProjectMcps = $false
        hostHealth         = 'conservador'
        appTuningMode      = 'recommended'
        selectedAppTuningCategories = @()
        selectedAppTuningItems = @()
        excludedAppTuningItems = @()
        skipManualRequirements = $false
        ignoreManualRequirements = $false
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
    $normalized['selectedAppTuningCategories'] = @(Normalize-BootstrapNames -Names @($normalized['selectedAppTuningCategories']))
    $normalized['selectedAppTuningItems'] = @(Normalize-BootstrapNames -Names @($normalized['selectedAppTuningItems']))
    $normalized['excludedAppTuningItems'] = @(Normalize-BootstrapNames -Names @($normalized['excludedAppTuningItems']))
    $normalized['enableClaudeCodeProjectMcps'] = [bool]$normalized['enableClaudeCodeProjectMcps']
    $language = [string]$normalized['language']
    if ((Get-UiLanguages) -notcontains $language) { $normalized['language'] = 'pt-BR' }
    if ([string]::IsNullOrWhiteSpace([string]$normalized['hostHealth'])) {
        $normalized['hostHealth'] = 'conservador'
    } else {
        $normalized['hostHealth'] = Normalize-BootstrapHostHealthMode -Mode ([string]$normalized['hostHealth'])
    }
    if ([string]::IsNullOrWhiteSpace([string]$normalized['appTuningMode'])) {
        $normalized['appTuningMode'] = 'recommended'
    } else {
        $normalized['appTuningMode'] = Normalize-BootstrapAppTuningMode -Mode ([string]$normalized['appTuningMode'])
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

function Save-UiState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )
    Write-BootstrapJsonFile -Path $Path -Value (ConvertTo-BootstrapHashtable -InputObject $State)
}

# 
# Bootstrap / SmokeTest
# 

$contract = Get-BootstrapUiContract
$state    = Read-UiState -Path $UiStatePath -Contract $contract

if ($SmokeTest) {
    Save-UiState -State $state -Path $UiStatePath
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
    $powershellExe = Get-WindowsPowerShellExePath
    $argumentList  = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath, '-UiStatePath', $UiStatePath, '-UiLogPath', $script:UiLogPath)
    Write-UiLog -Message ("Relaunching STA. Exe={0}  Args={1}" -f $powershellExe, (ConvertTo-Json $argumentList -Compress))
    Start-Process -FilePath $powershellExe -ArgumentList (ConvertTo-ArgumentString -Tokens $argumentList) | Out-Null
    exit 0
}

# 
# WPF Assemblies
# 

try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms   # still needed for FolderBrowserDialog
    Add-Type -AssemblyName System.Drawing
    Write-UiLog -Message 'WPF assemblies loaded.'
} catch {
    Write-UiLog -Level 'ERROR' -Message ("Failed to load WPF assemblies: {0}" -f (($_ | Out-String).Trim()))
    throw
}

function Get-UiBrush {
    param([Parameter(Mandatory = $true)][string]$Color)

    $converter = New-Object System.Windows.Media.BrushConverter
    return $converter.ConvertFromString($Color)
}

# 
# XAML Definition
# 

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Bootstrap Tools" Width="1180" Height="800"
        Background="#0F1117" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" Foreground="#E2E8F0"
        ResizeMode="CanResize">

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
        <SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#252840"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#E2E8F0"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#252840"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.ControlTextBrushKey}" Color="#E2E8F0"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#7C3AED"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.GrayTextBrushKey}" Color="#94A3B8"/>

        <x:Array x:Key="SteamDeckExternalModes" Type="{x:Type sys:String}">
            <sys:String>HANDHELD</sys:String>
            <sys:String>DOCKED_MONITOR</sys:String>
            <sys:String>DOCKED_TV</sys:String>
        </x:Array>

        <x:Array x:Key="SteamDeckDisplayModes" Type="{x:Type sys:String}">
            <sys:String>extend</sys:String>
            <sys:String>internal</sys:String>
            <sys:String>external</sys:String>
            <sys:String>clone</sys:String>
        </x:Array>

        <!-- Base TextBox style -->
        <Style x:Key="DarkInput" TargetType="TextBox">
            <Setter Property="Background"       Value="#252840"/>
            <Setter Property="Foreground"       Value="#E2E8F0"/>
            <Setter Property="BorderBrush"      Value="#2D3148"/>
            <Setter Property="BorderThickness"  Value="1"/>
            <Setter Property="Padding"          Value="8,5"/>
            <Setter Property="CaretBrush"       Value="#7C3AED"/>
            <Setter Property="SelectionBrush"   Value="#7C3AED"/>
            <Setter Property="SelectionTextBrush" Value="#FFFFFF"/>
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
            <Setter Property="FontSize"        Value="13"/>
            <Setter Property="TextElement.Foreground" Value="#E2E8F0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ComboToggle"
                                          Focusable="False"
                                          ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="ComboBorder"
                                                Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                BorderThickness="{Binding BorderThickness, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                CornerRadius="6">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="30"/>
                                                </Grid.ColumnDefinitions>
                                                <ContentPresenter Grid.Column="0"
                                                                  Margin="10,0,6,0"
                                                                  VerticalAlignment="Center"
                                                                  HorizontalAlignment="Left"
                                                                  IsHitTestVisible="False"
                                                                  Content="{Binding SelectionBoxItem, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                                  ContentTemplate="{Binding SelectionBoxItemTemplate, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                                  ContentTemplateSelector="{Binding ItemTemplateSelector, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                                  TextElement.Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ComboBox}}"/>
                                                <Border Grid.Column="1" Background="#1A1D2E" CornerRadius="0,6,6,0" IsHitTestVisible="False">
                                                    <Path Data="M 0 0 L 4 4 L 8 0 Z"
                                                          Fill="#CBD5E1"
                                                          Width="8"
                                                          Height="4"
                                                          HorizontalAlignment="Center"
                                                          VerticalAlignment="Center"/>
                                                </Border>
                                            </Grid>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#7C3AED"/>
                                            </Trigger>
                                            <Trigger Property="IsChecked" Value="True">
                                                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#9D5CF5"/>
                                            </Trigger>
                                            <Trigger Property="IsEnabled" Value="False">
                                                <Setter TargetName="ComboBorder" Property="Background" Value="#1E293B"/>
                                                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#334155"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>

                            <Popup x:Name="PART_Popup"
                                   Placement="Bottom"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True"
                                   Focusable="False"
                                   PopupAnimation="Fade">
                                <Border Background="#1A1D2E"
                                        BorderBrush="#2D3148"
                                        BorderThickness="1"
                                        CornerRadius="6"
                                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                                    <ScrollViewer Margin="2" SnapsToDevicePixels="True">
                                        <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="HasItems" Value="False">
                                <Setter TargetName="PART_Popup" Property="MinHeight" Value="20"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter Property="BorderBrush" Value="#9D5CF5"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#64748B"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DarkComboItem" TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#1A1D2E"/>
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="Padding" Value="8,6"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="#2D1B69"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#312E81"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="ComboBoxItem" BasedOn="{StaticResource DarkComboItem}"/>

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
                                <Setter Property="Foreground" Value="#94A3B8"/>
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
                                <Setter Property="Foreground" Value="#94A3B8"/>
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
            <Setter Property="Foreground" Value="#94A3B8"/>
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

        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#252840"/>
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="BorderBrush" Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="Padding" Value="8,0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>

        <Style TargetType="DataGridCell">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{Binding Foreground, RelativeSource={RelativeSource AncestorType=DataGridRow}}"/>
            <Setter Property="BorderBrush" Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="Padding" Value="6,0"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#2D1B69"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- CheckBox style -->
        <Style x:Key="DarkCheck" TargetType="CheckBox">
            <Setter Property="Foreground"   Value="#CBD5E1"/>
            <Setter Property="Margin"       Value="0,3"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="TextElement.Foreground" Value="#CBD5E1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <BulletDecorator Background="Transparent">
                            <BulletDecorator.Bullet>
                                <Border x:Name="CheckBorder"
                                        Width="16"
                                        Height="16"
                                        Margin="0,0,8,0"
                                        VerticalAlignment="Center"
                                        BorderThickness="1.5"
                                        CornerRadius="3"
                                        Background="#11162A"
                                        BorderBrush="#64748B">
                                    <Path x:Name="CheckMark"
                                          StrokeThickness="2.2"
                                          Stroke="#FFFFFF"
                                          Stretch="Uniform"
                                          Data="M 1 7 L 5 11 L 13 2"
                                          Visibility="Collapsed"/>
                                </Border>
                            </BulletDecorator.Bullet>
                            <ContentPresenter VerticalAlignment="Center"
                                              TextElement.Foreground="{TemplateBinding Foreground}"/>
                        </BulletDecorator>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CheckBorder" Property="BorderBrush" Value="#A78BFA"/>
                                <Setter TargetName="CheckBorder" Property="Background" Value="#1A2140"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckBorder" Property="Background" Value="#7C3AED"/>
                                <Setter TargetName="CheckBorder" Property="BorderBrush" Value="#C4B5FD"/>
                                <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#64748B"/>
                                <Setter TargetName="CheckBorder" Property="Background" Value="#1E293B"/>
                                <Setter TargetName="CheckBorder" Property="BorderBrush" Value="#475569"/>
                                <Setter TargetName="CheckMark" Property="Stroke" Value="#94A3B8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DarkGridCheckBoxElement" TargetType="CheckBox" BasedOn="{StaticResource DarkCheck}">
            <Setter Property="HorizontalAlignment" Value="Center"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="ToolTip" Value="Marque para incluir a otimização; desmarque para excluir."/>
            <Setter Property="Focusable" Value="False"/>
        </Style>

        <Style x:Key="DarkGridCheckBoxEditing" TargetType="CheckBox" BasedOn="{StaticResource DarkCheck}">
            <Setter Property="HorizontalAlignment" Value="Center"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="ToolTip" Value="Marque para incluir a otimização; desmarque para excluir."/>
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
        <Style TargetType="ListBoxItem" BasedOn="{StaticResource DarkListItem}"/>

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
                               Foreground="#94A3B8" Margin="0,2,0,0"/>
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
                            <TextBlock x:Name="NavSelectionText" Text="Escolher" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavHostSetup"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavHostSetupText" Text="Configurar PC" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavAppTuning"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavAppTuningText" Text="Otimizar Apps" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavApiCenter"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavApiCenterText" Text="Chaves (APIs)" VerticalAlignment="Center"/>
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
                            <TextBlock x:Name="NavReviewText" Text="Revisar" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavRun"          Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text=">" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavRunText" Text="Executar" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                </StackPanel>

                <!-- Bottom nav actions -->
                <StackPanel DockPanel.Dock="Bottom" Margin="12,16">
                    <Button x:Name="BackButton"   Style="{StaticResource GhostBtn}" Content="&lt;- Voltar"  Margin="0,4" Height="34"/>
                    <Button x:Name="NextButton"   Style="{StaticResource PrimaryBtn}" Content="Avancar ->" Margin="0,4" Height="34"/>
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
                    <TextBlock x:Name="WelcomeSubtitleLabel" Style="{StaticResource PageSubtitle}" Text="Setup simples do host, controle do Steam Deck e manutencao pos-instalacao."
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
                            <TextBlock Grid.Column="0" Text="" FontSize="16" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#94A3B8"/>
                        <TextBox x:Name="FilterTextBox" Grid.Column="1" Style="{StaticResource DarkInput}" Height="34" ToolTip="Busque por perfil, componente ou descrição para filtrar rapidamente."/>
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
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="12"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="12"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Border Grid.Row="0" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="QuickOptionsLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="OPCOES RAPIDAS"/>
                                <StackPanel Margin="0,6,0,0">
                                    <CheckBox x:Name="OptClaudePluginsCheckBox" Style="{StaticResource DarkCheck}" Content="Claude Code: plugins"/>
                                    <CheckBox x:Name="OptClaudeProjectMcpsCheckBox" Style="{StaticResource DarkCheck}" Content="Claude Code: sync MCP no projeto"/>
                                    <CheckBox x:Name="OptOpenWebUICheckBox" Style="{StaticResource DarkCheck}" Content="IA local: Open WebUI (Docker)"/>
                                    <CheckBox x:Name="OptSkipManualRequirementsCheckBox" Style="{StaticResource DarkCheck}" Content="Pular requisitos manuais (bloqueantes)"/>
                                    <CheckBox x:Name="OptIgnoreManualRequirementsCheckBox" Style="{StaticResource DarkCheck}" Content="Ignorar requisitos manuais (apenas log)"/>
                                </StackPanel>
                            </DockPanel>
                        </Border>
                        <Border Grid.Row="2" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="ExcludeLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="EXCLUSES OPCIONAIS"/>
                                <ListBox x:Name="ExcludeList" Background="Transparent" BorderThickness="0"
                                         Foreground="#CBD5E1" Margin="0,4,0,0"/>
                            </DockPanel>
                        </Border>
                        <Border Grid.Row="4" Style="{StaticResource Card}">
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
                    <TextBlock x:Name="HostTitleLabel" Style="{StaticResource PageTitle}" Text="Configurao do Host"/>
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
                            <TextBlock x:Name="SteamDeckVersionLabel" Grid.Row="2" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Verso Steam Deck"/>
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
                            <TextBlock x:Name="AdminNeedsTitleLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="REVISAO DE ADMIN"/>
                            <TextBox   x:Name="AdminNeedsTextBox" Style="{StaticResource DarkReadonly}"
                                       Height="160" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" Margin="0,4,0,0"/>
                        </DockPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  APP TUNING PAGE  -->
            <ScrollViewer x:Name="PageAppTuning" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="AppTuningTitleLabel" Style="{StaticResource PageTitle}" Text="Otimizar Apps"/>
                    <TextBlock x:Name="AppTuningSubtitleLabel" Style="{StaticResource PageSubtitle}" Text="Pre-configure ferramentas instaladas por categoria e perfil, com defaults seguros." TextWrapping="Wrap"/>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="140"/>
                            <ColumnDefinition Width="230"/>
                            <ColumnDefinition Width="90"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="100"/>
                            <ColumnDefinition Width="180"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="10"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock x:Name="AppTuningModeLabel" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="AppTuning"/>
                        <ComboBox x:Name="AppTuningModeCombo" Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkCombo}" Margin="0,0,12,0"/>
                        <TextBlock Grid.Row="0" Grid.Column="2" Foreground="#94A3B8" VerticalAlignment="Center" Text="Busca" ToolTip="Filtre por categoria, app, ID, nome da otimização, descrição ou componente."/>
                        <TextBox x:Name="AppTuningSearchBox" Grid.Row="0" Grid.Column="3" Style="{StaticResource DarkInput}" Height="34" Margin="0,0,12,0" ToolTip="Digite parte do nome do app, categoria, item ou componente para buscar."/>
                        <TextBlock Grid.Row="0" Grid.Column="4" Foreground="#94A3B8" VerticalAlignment="Center" Text="Status" ToolTip="All: tudo | installed: instalado | missing: ausente | planned: planejado | not-configured: não configurado | update-check: requer verificação."/>
                        <ComboBox x:Name="AppTuningStatusFilterCombo" Grid.Row="0" Grid.Column="5" Style="{StaticResource DarkCombo}" ToolTip="Filtre os itens pelo estado atual para focar na ação necessária."/>

                        <TextBlock x:Name="AppTuningStatusLabel" Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="3" Foreground="#94A3B8" VerticalAlignment="Center" TextWrapping="Wrap"/>
                        <StackPanel Grid.Row="2" Grid.Column="3" Grid.ColumnSpan="3" Orientation="Horizontal" HorizontalAlignment="Right">
                            <Button x:Name="AppTuningRecommendedButton" Style="{StaticResource GhostBtn}" Content="Marcar recomendados" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningMarkCategoryButton" Style="{StaticResource GhostBtn}" Content="Marcar categoria" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningClearCategoryButton" Style="{StaticResource GhostBtn}" Content="Limpar categoria" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningAuditButton" Style="{StaticResource GhostBtn}" Content="Auditar agora" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningInstallButton" Style="{StaticResource GhostBtn}" Content="Instalar" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningConfigureButton" Style="{StaticResource PrimaryBtn}" Content="Configurar/Otimizar" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningUpdateButton" Style="{StaticResource GhostBtn}" Content="Atualizar" Height="32"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <Grid Height="470">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="300"/>
                        <ColumnDefinition Width="14"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <Border Grid.Column="0" Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="AppTuningCategoriesLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="CATEGORIAS"/>
                            <ListBox x:Name="AppTuningCategoryList" Background="Transparent" BorderThickness="0" Foreground="#CBD5E1" Margin="0,4,0,0"/>
                        </DockPanel>
                    </Border>

                    <Border Grid.Column="2" Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="AppTuningItemsLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="ITENS"/>
                            <DataGrid x:Name="AppTuningItemsGrid" Style="{StaticResource DarkGrid}" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False" SelectionMode="Extended">
                                <DataGrid.Columns>
                                    <DataGridCheckBoxColumn Header="Ativo" Binding="{Binding active, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="70" ElementStyle="{StaticResource DarkGridCheckBoxElement}" EditingElementStyle="{StaticResource DarkGridCheckBoxEditing}"/>
                                    <DataGridTextColumn Header="Id" Binding="{Binding id}" Width="0" Visibility="Collapsed"/>
                                    <DataGridTextColumn Header="Componentes" Binding="{Binding installComponents}" Width="0" Visibility="Collapsed"/>
                                    <DataGridTextColumn Header="Categoria" Binding="{Binding category}" Width="1.1*"/>
                                    <DataGridTextColumn Header="App" Binding="{Binding app}" Width="1.2*"/>
                                    <DataGridTextColumn Header="Otimizacao" Binding="{Binding optimization}" Width="1.8*"/>
                                    <DataGridTextColumn Header="Perfil" Binding="{Binding profile}" Width="1.2*"/>
                                    <DataGridTextColumn Header="Risco" Binding="{Binding risk}" Width="0.8*"/>
                                    <DataGridTextColumn Header="Instalado" Binding="{Binding installed}" Width="0.8*"/>
                                    <DataGridTextColumn Header="Configurado" Binding="{Binding configured}" Width="0.9*"/>
                                    <DataGridTextColumn Header="Atualizado" Binding="{Binding updated}" Width="0.8*"/>
                                    <DataGridTextColumn Header="Admin" Binding="{Binding admin}" Width="0.7*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>
                </Grid>

                <Border Background="#1A1D2E" CornerRadius="8" Padding="12,8" Margin="0,10,0,0">
                    <TextBlock x:Name="AppTuningHintLabel" Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap"/>
                </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  API CENTER PAGE  -->
            <ScrollViewer x:Name="PageApiCenter" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="ApiCenterTitleLabel" Style="{StaticResource PageTitle}" Text="Central de APIs"/>
                    <TextBlock Style="{StaticResource PageSubtitle}" Text="Inventario seguro de chaves, validacao, rotacao e uso por app. Segredos ficam mascarados por padrao." TextWrapping="Wrap"/>

                    <Border Background="#1A1D2E" CornerRadius="10" Padding="14,10" Margin="0,0,0,14">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                <Button x:Name="ApiRefreshButton" Style="{StaticResource GhostBtn}" Content="Atualizar APIs" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="ApiValidateAllButton" Style="{StaticResource GhostBtn}" Content="Validar tudo" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="ApiImportButton" Style="{StaticResource GhostBtn}" Content="Importar arquivo bruto" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="ApiCatalogButton" Style="{StaticResource GhostBtn}" Content="Catalogo completo" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="ApiApplyButton" Style="{StaticResource PrimaryBtn}" Content="Aplicar nos apps" Height="32"/>
                            </StackPanel>
                            <StackPanel>
                                <TextBlock x:Name="ApiStatusLabel" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
                                <TextBlock x:Name="ApiStatusLinksLabel" Foreground="#94A3B8" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap" Visibility="Collapsed">
                                    <Hyperlink x:Name="ApiSignupLink"><Run Text="Criar chave"/></Hyperlink>
                                    <Run Text="  |  "/>
                                    <Hyperlink x:Name="ApiDocsLink"><Run Text="Docs"/></Hyperlink>
                                    <Run Text="  |  "/>
                                    <Hyperlink x:Name="ApiPricingLink"><Run Text="Precos"/></Hyperlink>
                                </TextBlock>
                                <TextBlock x:Name="ApiSecretsLinksLabel" Foreground="#94A3B8" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap" Visibility="Collapsed">
                                    <Hyperlink x:Name="ApiSecretsFileLink"><Run Text="Abrir arquivo"/></Hyperlink>
                                    <Run Text="  |  "/>
                                    <Hyperlink x:Name="ApiSecretsFolderLink"><Run Text="Abrir pasta"/></Hyperlink>
                                </TextBlock>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                        <DockPanel>
                            <TextBlock x:Name="ApiProviderSummaryLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="RESUMO POR PROVEDOR"/>
                            <DataGrid x:Name="ApiProviderSummaryGrid" Style="{StaticResource DarkGrid}" Height="170" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Provedor" Binding="{Binding provider}" Width="1.1*"/>
                                    <DataGridTextColumn Header="Chaves" Binding="{Binding total}" Width="0.6*"/>
                                    <DataGridTextColumn Header="Em uso agora" Binding="{Binding active}" Width="1.1*"/>
                                    <DataGridTextColumn Header="Teste" Binding="{Binding state}" Width="0.8*"/>
                                    <DataGridTextColumn Header="Apps automaticos" Binding="{Binding autoApps}" Width="1.5*"/>
                                    <DataGridTextColumn Header="Apps manuais" Binding="{Binding manualApps}" Width="1.2*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>

                    <Grid Margin="0,0,0,14">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="1.1*"/>
                            <ColumnDefinition Width="14"/>
                            <ColumnDefinition Width="0.9*"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="0" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock x:Name="ApiCredentialsLabel" Style="{StaticResource SectionLabel}" Text="CREDENCIAIS"/>
                                <DataGrid x:Name="ApiCredentialGrid" Style="{StaticResource DarkGrid}" Height="220" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Provedor" Binding="{Binding provider}" Width="0.9*"/>
                                        <DataGridTextColumn Header="Identificacao segura" Binding="{Binding id}" Width="1.6*"/>
                                        <DataGridTextColumn Header="Nome amigavel" Binding="{Binding display}" Width="1.1*"/>
                                        <DataGridTextColumn Header="Ativa" Binding="{Binding active}" Width="0.6*"/>
                                        <DataGridTextColumn Header="Teste" Binding="{Binding state}" Width="0.8*"/>
                                        <DataGridTextColumn Header="Mascara" Binding="{Binding preview}" Width="0.8*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </StackPanel>
                        </Border>

                        <Border Grid.Column="2" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="ADICIONAR / EDITAR"/>
                                <TextBlock Foreground="#94A3B8" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,8" Text="Selecione provedor e credencial. O campo segredo fica vazio ao editar; preencha apenas para criar ou trocar a chave."/>
                                <TextBlock Foreground="#94A3B8" Text="Provedor"/>
                                <ComboBox x:Name="ApiProviderCombo" Style="{StaticResource DarkCombo}" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Chave cadastrada"/>
                                <ComboBox x:Name="ApiCredentialCombo" Style="{StaticResource DarkCombo}" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Nome para voce reconhecer"/>
                                <TextBox x:Name="ApiDisplayNameTextBox" Style="{StaticResource DarkInput}" Height="32" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Segredo / API key"/>
                                <PasswordBox x:Name="ApiSecretBox" Background="#252840" Foreground="#E2E8F0" BorderBrush="#2D3148" BorderThickness="1" Height="32" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Base URL"/>
                                <TextBox x:Name="ApiBaseUrlTextBox" Style="{StaticResource DarkInput}" Height="32" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Organizacao"/>
                                <TextBox x:Name="ApiOrganizationTextBox" Style="{StaticResource DarkInput}" Height="32" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Project Ref"/>
                                <TextBox x:Name="ApiProjectRefTextBox" Style="{StaticResource DarkInput}" Height="32" Margin="0,2,0,12"/>
                                <StackPanel Orientation="Horizontal">
                                    <Button x:Name="ApiSaveButton" Style="{StaticResource PrimaryBtn}" Content="Salvar credencial" Margin="0,0,8,0" Height="32"/>
                                    <Button x:Name="ApiValidateButton" Style="{StaticResource GhostBtn}" Content="Validar" Margin="0,0,8,0" Height="32"/>
                                    <Button x:Name="ApiActivateButton" Style="{StaticResource GhostBtn}" Content="Ativar" Height="32"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="14"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="0" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="ApiUsageLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="USO NOS APPS"/>
                                <DataGrid x:Name="ApiUsageGrid" Style="{StaticResource DarkGrid}" Height="190" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Sistema" Binding="{Binding app}" Width="0.8*"/>
                                        <DataGridTextColumn Header="Configurado sozinho" Binding="{Binding autoApplied}" Width="1.4*"/>
                                        <DataGridTextColumn Header="Manual" Binding="{Binding manualOnly}" Width="1.1*"/>
                                        <DataGridTextColumn Header="Disponivel" Binding="{Binding available}" Width="1.6*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </DockPanel>
                        </Border>

                        <Border Grid.Column="2" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="ApiCreateLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="CRIAR OU ASSINAR"/>
                                <DataGrid x:Name="ApiCreateGrid" Style="{StaticResource DarkGrid}" Height="190" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Provedor" Binding="{Binding provider}" Width="0.9*"/>
                                        <DataGridTextColumn Header="Voce vai precisar" Binding="{Binding fields}" Width="1.2*"/>
                                        <DataGridTemplateColumn Header="Criar chave" Width="1.2*">
                                            <DataGridTemplateColumn.CellTemplate>
                                                <DataTemplate>
                                                    <TextBlock ToolTip="{Binding signup}">
                                                        <Hyperlink NavigateUri="{Binding signup}">
                                                            <Run Text="Abrir"/>
                                                        </Hyperlink>
                                                    </TextBlock>
                                                </DataTemplate>
                                            </DataGridTemplateColumn.CellTemplate>
                                        </DataGridTemplateColumn>
                                        <DataGridTemplateColumn Header="Ajuda" Width="1.2*">
                                            <DataGridTemplateColumn.CellTemplate>
                                                <DataTemplate>
                                                    <TextBlock ToolTip="{Binding docs}">
                                                        <Hyperlink NavigateUri="{Binding docs}">
                                                            <Run Text="Abrir"/>
                                                        </Hyperlink>
                                                    </TextBlock>
                                                </DataTemplate>
                                            </DataGridTemplateColumn.CellTemplate>
                                        </DataGridTemplateColumn>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </DockPanel>
                        </Border>
                    </Grid>
                </StackPanel>
            </ScrollViewer>

            <!--  API CATALOG PAGE  -->
            <ScrollViewer x:Name="PageApiCatalog" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="ApiCatalogTitleLabel" Style="{StaticResource PageTitle}" Text="Catalogo completo de chaves"/>
                    <TextBlock x:Name="ApiCatalogSubtitleLabel" Style="{StaticResource PageSubtitle}" Text="Lista pesquisada de provedores com posse, uso configurado, finalidade, requisitos e links oficiais." TextWrapping="Wrap"/>

                    <Border Background="#1A1D2E" CornerRadius="10" Padding="14,10" Margin="0,0,0,14">
                        <DockPanel>
                            <Button x:Name="ApiCatalogBackButton" DockPanel.Dock="Right" Style="{StaticResource GhostBtn}" Content="&lt;- Central de APIs" Height="32"/>
                            <TextBlock x:Name="ApiCatalogStatusLabel" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
                        </DockPanel>
                    </Border>

                    <Border Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="ApiFullCatalogLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="TODAS AS CHAVES POSSIVEIS"/>
                            <DataGrid x:Name="ApiFullCatalogGrid" Style="{StaticResource DarkGrid}" Height="520" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Ja possui" Binding="{Binding hasCredential}" Width="0.7*"/>
                                    <DataGridTextColumn Header="Quantidade" Binding="{Binding quantity}" Width="0.7*"/>
                                    <DataGridTextColumn Header="Configuradas" Binding="{Binding configured}" Width="0.8*"/>
                                    <DataGridTextColumn Header="Provedor" Binding="{Binding provider}" Width="1.1*"/>
                                    <DataGridTextColumn Header="O que faz" Binding="{Binding description}" Width="2.2*"/>
                                    <DataGridTextColumn Header="Voce vai precisar" Binding="{Binding fields}" Width="1.2*"/>
                                    <DataGridTemplateColumn Header="Criar Chave" Width="1.0*">
                                        <DataGridTemplateColumn.CellTemplate>
                                            <DataTemplate>
                                                <TextBlock ToolTip="{Binding signup}">
                                                    <Hyperlink NavigateUri="{Binding signup}">
                                                        <Run Text="Abrir"/>
                                                    </Hyperlink>
                                                </TextBlock>
                                            </DataTemplate>
                                        </DataGridTemplateColumn.CellTemplate>
                                    </DataGridTemplateColumn>
                                    <DataGridTemplateColumn Header="Ajuda" Width="1.0*">
                                        <DataGridTemplateColumn.CellTemplate>
                                            <DataTemplate>
                                                <TextBlock ToolTip="{Binding docs}">
                                                    <Hyperlink NavigateUri="{Binding docs}">
                                                        <Run Text="Abrir"/>
                                                    </Hyperlink>
                                                </TextBlock>
                                            </DataTemplate>
                                        </DataGridTemplateColumn.CellTemplate>
                                    </DataGridTemplateColumn>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  STEAM DECK CONTROL PAGE  -->
            <ScrollViewer x:Name="PageSteamDeck" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="SteamDeckTitleLabel" Style="{StaticResource PageTitle}" Text="Central Steam Deck"/>
                    <TextBlock Style="{StaticResource PageSubtitle}" Text="Configure perfis de monitor, sessoes e o fallback generico." TextWrapping="Wrap"/>

                    <!-- Monitor Profiles -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                        <StackPanel>
                            <TextBlock x:Name="MonitorProfilesLabel" Style="{StaticResource SectionLabel}" Text="MONITOR PROFILES"/>
                            <DataGrid  x:Name="MonitorProfilesGrid"  Style="{StaticResource DarkGrid}" Height="160" Margin="0,4,0,0">
                                <DataGrid.Columns>
                                    <DataGridCheckBoxColumn Header="Principal"     Binding="{Binding primary, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="80"/>
                                    <DataGridTextColumn Header="Alvo"              Binding="{Binding target}"            Width="90" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Status"            Binding="{Binding status}"            Width="130" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Fabricante"        Binding="{Binding manufacturer}"      Width="*"/>
                                    <DataGridTextColumn Header="Modelo"            Binding="{Binding product}"           Width="*"/>
                                    <DataGridTextColumn Header="Serial"            Binding="{Binding serial}"            Width="*"/>
                                    <DataGridComboBoxColumn Header="Perfil"        SelectedItemBinding="{Binding mode, UpdateSourceTrigger=PropertyChanged}" ItemsSource="{StaticResource SteamDeckExternalModes}" Width="*"/>
                                    <DataGridTextColumn Header="Layout"            Binding="{Binding layout}"            Width="*"/>
                                    <DataGridTextColumn Header="Resolucao"         Binding="{Binding resolutionPolicy}"  Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                                <TextBlock Foreground="#94A3B8" FontSize="11" Margin="0,8,0,0" TextWrapping="Wrap"
                                       Text="Se esta lista estiver vazia, tudo bem: o Steam Deck ainda usa as familias conhecidas e a regra padrao para monitor externo."/>
                        </StackPanel>
                    </Border>

                    <!-- Monitor Families -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                        <StackPanel>
                            <TextBlock x:Name="MonitorFamiliesLabel" Style="{StaticResource SectionLabel}" Text="MONITOR FAMILIES"/>
                            <DataGrid  x:Name="MonitorFamiliesGrid"  Style="{StaticResource DarkGrid}" Height="160" Margin="0,4,0,0">
                                <DataGrid.Columns>
                                    <DataGridCheckBoxColumn Header="Principal"     Binding="{Binding primary, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="80"/>
                                    <DataGridTextColumn Header="Status"            Binding="{Binding status}"            Width="120" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Fabricante"        Binding="{Binding manufacturer}"      Width="*"/>
                                    <DataGridTextColumn Header="Modelo"            Binding="{Binding product}"           Width="*"/>
                                    <DataGridTextColumn Header="Padrao do nome"    Binding="{Binding namePattern}"       Width="*"/>
                                    <DataGridComboBoxColumn Header="Perfil"        SelectedItemBinding="{Binding mode, UpdateSourceTrigger=PropertyChanged}" ItemsSource="{StaticResource SteamDeckExternalModes}" Width="*"/>
                                    <DataGridTextColumn Header="Layout"            Binding="{Binding layout}"            Width="*"/>
                                    <DataGridTextColumn Header="Resolucao"         Binding="{Binding resolutionPolicy}"  Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                                <TextBlock Foreground="#94A3B8" FontSize="11" Margin="0,8,0,0" TextWrapping="Wrap"
                                       Text="Familias permitem reconhecer monitores parecidos sem cadastrar serial por serial."/>
                        </StackPanel>
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
                                <TextBlock x:Name="GenericGroupLabel" Style="{StaticResource SectionLabel}" Text="FALLBACK GENERICO"/>
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
                                        <RowDefinition Height="8"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <TextBlock x:Name="GenericModeLabel"       Grid.Row="0" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Modo"/>
                                    <ComboBox  x:Name="GenericModeCombo"       Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkCombo}"/>
                                    <TextBlock x:Name="GenericLayoutLabel"     Grid.Row="2" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Layout"/>
                                    <TextBox   x:Name="GenericLayoutTextBox"   Grid.Row="2" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                    <TextBlock x:Name="GenericResolutionLabel" Grid.Row="4" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Resolucao"/>
                                    <TextBox   x:Name="GenericResolutionTextBox" Grid.Row="4" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                    <TextBlock x:Name="DisplayModeLabel"       Grid.Row="6" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Display"/>
                                    <ComboBox  x:Name="DisplayModeCombo"       Grid.Row="6" Grid.Column="1" Style="{StaticResource DarkCombo}" ItemsSource="{StaticResource SteamDeckDisplayModes}"/>
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

                    <!-- Unknown external classifier -->
                    <Border Style="{StaticResource Card}" Margin="0,14,0,0" BorderBrush="{StaticResource WarnBrush}">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                <Button x:Name="ClassifyMonitorButton" Style="{StaticResource PrimaryBtn}" Content=" Monitor/Dev" Margin="0,0,8,0" Width="140" Height="34"/>
                                <Button x:Name="ClassifyTvButton"      Style="{StaticResource GhostBtn}"   Content=" TV/Game" Width="120" Height="34"/>
                            </StackPanel>
                            <StackPanel>
                                <TextBlock x:Name="PendingExternalLabel" Style="{StaticResource SectionLabel}" Text="MONITOR EXTERNO DESCONHECIDO"/>
                                <TextBlock x:Name="PendingExternalStatusLabel" Foreground="#CBD5E1" FontSize="12" TextWrapping="Wrap" Margin="0,4,12,0"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <!-- Watcher status + save buttons -->
                    <Border Background="#1A1D2E" CornerRadius="8" Padding="14,10" Margin="0,14,0,0">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                <Button x:Name="ReloadSettingsButton" Style="{StaticResource GhostBtn}"   Content=" Recarregar" Margin="0,0,8,0" Height="34"/>
                                <Button x:Name="SaveSettingsButton"   Style="{StaticResource PrimaryBtn}" Content=" Salvar Settings" Height="34"/>
                            </StackPanel>
                            <StackPanel>
                    <TextBlock x:Name="WatcherStatusLabel"  Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap"/>
                    <TextBlock x:Name="UnknownMonitorHintLabel" Foreground="#94A3B8" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  DUAL BOOT PAGE  -->
            <ScrollViewer x:Name="PageDualBoot" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="DualBootTitleLabel" Style="{StaticResource PageTitle}" Text="Windows e Linux"/>
                    <TextBlock Style="{StaticResource PageSubtitle}" Text="Validacao de guardrails e gerenciamento do cenario Windows + Linux." TextWrapping="Wrap"/>

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

                    <!-- Windows Boot Manager -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="WINDOWS BOOT MANAGER (BCD)"/>
                            <StackPanel Margin="0,8,0,0">
                                <TextBlock x:Name="WindowsBootStatusText" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,8"/>
                                <DataGrid x:Name="WindowsBootEntriesGrid" Style="{StaticResource DarkGrid}" Height="190" Margin="0,0,0,10" CanUserAddRows="False" CanUserDeleteRows="False">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Padrao" Binding="{Binding isDefault}" Width="0.6*"/>
                                        <DataGridTextColumn Header="Atual" Binding="{Binding isCurrent}" Width="0.6*"/>
                                        <DataGridTextColumn Header="Menu" Binding="{Binding inDisplayOrder}" Width="0.6*"/>
                                        <DataGridTextColumn Header="Id" Binding="{Binding id}" Width="1.5*"/>
                                        <DataGridTextColumn Header="Descricao" Binding="{Binding description}" Width="1.6*"/>
                                        <DataGridTextColumn Header="Device" Binding="{Binding device}" Width="1.3*"/>
                                        <DataGridTextColumn Header="OSDevice" Binding="{Binding osdevice}" Width="1.3*"/>
                                        <DataGridTextColumn Header="Orfa" Binding="{Binding isPhantom}" Width="0.6*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="110"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="80"/>
                                        <ColumnDefinition Width="120"/>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Padrao"/>
                                    <ComboBox x:Name="WindowsBootDefaultCombo" Grid.Column="1" Style="{StaticResource DarkCombo}" Margin="0,0,12,0"/>
                                    <TextBlock Grid.Column="2" Foreground="#94A3B8" VerticalAlignment="Center" Text="Timeout"/>
                                    <TextBox x:Name="WindowsBootTimeoutTextBox" Grid.Column="3" Style="{StaticResource DarkInput}" Height="34" Margin="0,0,12,0"/>
                                    <Button x:Name="BackupWindowsBootButton" Grid.Column="4" Style="{StaticResource GhostBtn}" Content="Backup BCD" Height="34" Margin="0,0,8,0"/>
                                    <Button x:Name="ApplyWindowsBootButton" Grid.Column="5" Style="{StaticResource PrimaryBtn}" Content="Aplicar BCD" Height="34"/>
                                </Grid>
                            </StackPanel>
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
                    <TextBlock x:Name="ReviewTitleLabel" Style="{StaticResource PageTitle}" Text="Revisao"/>
                </StackPanel>

                <Border Grid.Row="1" Background="#1A1D2E" CornerRadius="8" Padding="14,10" Margin="0,0,0,14">
                    <DockPanel>
                        <Button x:Name="RefreshReviewButton" DockPanel.Dock="Right" Style="{StaticResource GhostBtn}" Content=" Atualizar" Height="32"/>
                        <StackPanel>
                            <TextBlock x:Name="ReviewMetaLabel" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
                            <TextBlock x:Name="ReviewLinksLabel" Foreground="#94A3B8" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap" Visibility="Collapsed">
                                <Hyperlink x:Name="ReviewSettingsLink"><Run Text="Abrir Settings"/></Hyperlink>
                                <Run Text="  |  "/>
                                <Hyperlink x:Name="ReviewUiStateLink"><Run Text="Abrir UI state"/></Hyperlink>
                            </TextBlock>
                        </StackPanel>
                    </DockPanel>
                </Border>

                <Border Grid.Row="2" Style="{StaticResource Card}">
                    <DockPanel>
                        <TextBlock x:Name="ReviewSummaryLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="PREVIEW DO PLAN (DRY-RUN)"/>
                        <TextBlock x:Name="ReviewSideEffectsLabel" Foreground="#94A3B8" FontSize="12" Margin="0,6,0,0" Text="Efeitos colaterais"/>
                        <TextBox x:Name="ReviewSideEffectsTextBox" Style="{StaticResource DarkReadonly}"
                                 AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                                 FontFamily="Consolas" FontSize="12" Height="86" Margin="0,6,0,10"/>
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

                <TextBlock Grid.Row="0" x:Name="RunTitleLabel" Style="{StaticResource PageTitle}" Text="Execucao"/>

                <!-- Action bar -->
                <Border Grid.Row="1" Background="#1A1D2E" CornerRadius="10" Padding="16,12" Margin="0,0,0,16">
                    <DockPanel>
                        <Button x:Name="StartRunButton" DockPanel.Dock="Right" Style="{StaticResource PrimaryBtn}"
                                Content=">  Iniciar Execucao" FontSize="15" Height="40"/>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Button x:Name="OpenLogButton"     Style="{StaticResource GhostBtn}" Content=" Log"        Margin="0,0,8,0" Height="34"/>
                            <Button x:Name="OpenResultButton"  Style="{StaticResource GhostBtn}" Content=" Resultado"  Margin="0,0,8,0" Height="34"/>
                            <Button x:Name="OpenSettingsButton" Style="{StaticResource GhostBtn}" Content="[gear] Settings"   Margin="0,0,8,0" Height="34"/>
                            <Button x:Name="OpenReportsButton" Style="{StaticResource GhostBtn}" Content=" Relatorios" Height="34"/>
                        </StackPanel>
                    </DockPanel>
                </Border>

                <!-- Log area -->
                <Border Grid.Row="2" Style="{StaticResource Card}">
                    <DockPanel>
                        <TextBlock x:Name="RunStatusLabel" DockPanel.Dock="Top" Foreground="#94A3B8" FontSize="12" Margin="0,0,0,8"/>
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
                <TextBlock x:Name="StepLabel"   DockPanel.Dock="Right" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="StatusLabel" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center"/>
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

$window.AddHandler([System.Windows.Documents.Hyperlink]::RequestNavigateEvent, [System.Windows.Navigation.RequestNavigateEventHandler]{
    param($sender, $e)
    try {
        if ($e.Uri -and -not [string]::IsNullOrWhiteSpace([string]$e.Uri.OriginalString)) {
            Start-Process ([string]$e.Uri.OriginalString)
        }
    } catch {
    }
    $e.Handled = $true
})

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
    SuppressApiEvents     = $false
    SuppressAppTuningEvents = $false
    LogOffset             = 0
    CurrentLogPath        = $null
    CurrentResultPath     = $null
    RunProcess            = $null

    # Window
    Window                = $window

    # Nav
    NavWelcome            = (Get-Control 'NavWelcome')
    NavSelection          = (Get-Control 'NavSelection')
    NavHostSetup          = (Get-Control 'NavHostSetup')
    NavAppTuning          = (Get-Control 'NavAppTuning')
    NavApiCenter          = (Get-Control 'NavApiCenter')
    NavSteamDeck          = (Get-Control 'NavSteamDeck')
    NavDualBoot           = (Get-Control 'NavDualBoot')
    NavReview             = (Get-Control 'NavReview')
    NavRun                = (Get-Control 'NavRun')
    NavWelcomeText        = (Get-Control 'NavWelcomeText')
    NavSelectionText      = (Get-Control 'NavSelectionText')
    NavHostSetupText      = (Get-Control 'NavHostSetupText')
    NavAppTuningText      = (Get-Control 'NavAppTuningText')
    NavApiCenterText      = (Get-Control 'NavApiCenterText')
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
    QuickOptionsLabel     = (Get-Control 'QuickOptionsLabel')
    OptClaudePluginsCheckBox = (Get-Control 'OptClaudePluginsCheckBox')
    OptClaudeProjectMcpsCheckBox = (Get-Control 'OptClaudeProjectMcpsCheckBox')
    OptOpenWebUICheckBox  = (Get-Control 'OptOpenWebUICheckBox')
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

    # App Tuning
    AppTuningTitleLabel   = (Get-Control 'AppTuningTitleLabel')
    AppTuningSubtitleLabel = (Get-Control 'AppTuningSubtitleLabel')
    AppTuningModeLabel    = (Get-Control 'AppTuningModeLabel')
    AppTuningModeCombo    = (Get-Control 'AppTuningModeCombo')
    AppTuningSearchBox    = (Get-Control 'AppTuningSearchBox')
    AppTuningStatusFilterCombo = (Get-Control 'AppTuningStatusFilterCombo')
    AppTuningStatusLabel  = (Get-Control 'AppTuningStatusLabel')
    AppTuningRecommendedButton = (Get-Control 'AppTuningRecommendedButton')
    AppTuningMarkCategoryButton = (Get-Control 'AppTuningMarkCategoryButton')
    AppTuningClearCategoryButton = (Get-Control 'AppTuningClearCategoryButton')
    AppTuningAuditButton  = (Get-Control 'AppTuningAuditButton')
    AppTuningInstallButton = (Get-Control 'AppTuningInstallButton')
    AppTuningConfigureButton = (Get-Control 'AppTuningConfigureButton')
    AppTuningUpdateButton = (Get-Control 'AppTuningUpdateButton')
    AppTuningCategoriesLabel = (Get-Control 'AppTuningCategoriesLabel')
    AppTuningCategoryList = (Get-Control 'AppTuningCategoryList')
    AppTuningItemsLabel   = (Get-Control 'AppTuningItemsLabel')
    AppTuningItemsGrid    = (Get-Control 'AppTuningItemsGrid')
    AppTuningHintLabel    = (Get-Control 'AppTuningHintLabel')

    # API Center
    ApiCenterTitleLabel   = (Get-Control 'ApiCenterTitleLabel')
    ApiProviderSummaryLabel = (Get-Control 'ApiProviderSummaryLabel')
    ApiCredentialsLabel   = (Get-Control 'ApiCredentialsLabel')
    ApiUsageLabel         = (Get-Control 'ApiUsageLabel')
    ApiCreateLabel        = (Get-Control 'ApiCreateLabel')
    ApiStatusLabel        = (Get-Control 'ApiStatusLabel')
    ApiStatusLinksLabel   = (Get-Control 'ApiStatusLinksLabel')
    ApiSignupLink         = (Get-Control 'ApiSignupLink')
    ApiDocsLink           = (Get-Control 'ApiDocsLink')
    ApiPricingLink        = (Get-Control 'ApiPricingLink')
    ApiSecretsLinksLabel  = (Get-Control 'ApiSecretsLinksLabel')
    ApiSecretsFileLink    = (Get-Control 'ApiSecretsFileLink')
    ApiSecretsFolderLink  = (Get-Control 'ApiSecretsFolderLink')
    ApiRefreshButton      = (Get-Control 'ApiRefreshButton')
    ApiValidateAllButton  = (Get-Control 'ApiValidateAllButton')
    ApiImportButton       = (Get-Control 'ApiImportButton')
    ApiCatalogButton      = (Get-Control 'ApiCatalogButton')
    ApiApplyButton        = (Get-Control 'ApiApplyButton')
    ApiSaveButton         = (Get-Control 'ApiSaveButton')
    ApiValidateButton     = (Get-Control 'ApiValidateButton')
    ApiActivateButton     = (Get-Control 'ApiActivateButton')
    ApiProviderSummaryGrid = (Get-Control 'ApiProviderSummaryGrid')
    ApiCredentialGrid     = (Get-Control 'ApiCredentialGrid')
    ApiUsageGrid          = (Get-Control 'ApiUsageGrid')
    ApiCreateGrid         = (Get-Control 'ApiCreateGrid')
    ApiProviderCombo      = (Get-Control 'ApiProviderCombo')
    ApiCredentialCombo    = (Get-Control 'ApiCredentialCombo')
    ApiDisplayNameTextBox = (Get-Control 'ApiDisplayNameTextBox')
    ApiSecretBox          = (Get-Control 'ApiSecretBox')
    ApiBaseUrlTextBox     = (Get-Control 'ApiBaseUrlTextBox')
    ApiOrganizationTextBox = (Get-Control 'ApiOrganizationTextBox')
    ApiProjectRefTextBox  = (Get-Control 'ApiProjectRefTextBox')
    ApiCatalogTitleLabel  = (Get-Control 'ApiCatalogTitleLabel')
    ApiCatalogSubtitleLabel = (Get-Control 'ApiCatalogSubtitleLabel')
    ApiCatalogBackButton  = (Get-Control 'ApiCatalogBackButton')
    ApiCatalogStatusLabel = (Get-Control 'ApiCatalogStatusLabel')
    ApiFullCatalogLabel   = (Get-Control 'ApiFullCatalogLabel')
    ApiFullCatalogGrid    = (Get-Control 'ApiFullCatalogGrid')

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
    DisplayModeLabel     = (Get-Control 'DisplayModeLabel')
    DisplayModeCombo     = (Get-Control 'DisplayModeCombo')
    SessionGroupLabel     = (Get-Control 'SessionGroupLabel')
    HandheldSessionLabel  = (Get-Control 'HandheldSessionLabel')
    HandheldSessionTextBox = (Get-Control 'HandheldSessionTextBox')
    DockTvSessionLabel    = (Get-Control 'DockTvSessionLabel')
    DockTvSessionTextBox  = (Get-Control 'DockTvSessionTextBox')
    DockMonitorSessionLabel = (Get-Control 'DockMonitorSessionLabel')
    DockMonitorSessionTextBox = (Get-Control 'DockMonitorSessionTextBox')
    PendingExternalLabel  = (Get-Control 'PendingExternalLabel')
    PendingExternalStatusLabel = (Get-Control 'PendingExternalStatusLabel')
    ClassifyMonitorButton = (Get-Control 'ClassifyMonitorButton')
    ClassifyTvButton      = (Get-Control 'ClassifyTvButton')
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
    WindowsBootStatusText = (Get-Control 'WindowsBootStatusText')
    WindowsBootEntriesGrid = (Get-Control 'WindowsBootEntriesGrid')
    WindowsBootDefaultCombo = (Get-Control 'WindowsBootDefaultCombo')
    WindowsBootTimeoutTextBox = (Get-Control 'WindowsBootTimeoutTextBox')
    BackupWindowsBootButton = (Get-Control 'BackupWindowsBootButton')
    ApplyWindowsBootButton = (Get-Control 'ApplyWindowsBootButton')
    BcdCleanupStatusText  = (Get-Control 'BcdCleanupStatusText')
    BcdCleanupButton      = (Get-Control 'BcdCleanupButton')
    RefreshDualBootButton = (Get-Control 'RefreshDualBootButton')

    # Review
    ReviewTitleLabel      = (Get-Control 'ReviewTitleLabel')
    ReviewSummaryLabel    = (Get-Control 'ReviewSummaryLabel')
    ReviewSideEffectsLabel = (Get-Control 'ReviewSideEffectsLabel')
    ReviewSideEffectsTextBox = (Get-Control 'ReviewSideEffectsTextBox')
    RefreshReviewButton   = (Get-Control 'RefreshReviewButton')
    ReviewMetaLabel       = (Get-Control 'ReviewMetaLabel')
    ReviewLinksLabel      = (Get-Control 'ReviewLinksLabel')
    ReviewSettingsLink    = (Get-Control 'ReviewSettingsLink')
    ReviewUiStateLink     = (Get-Control 'ReviewUiStateLink')
    ReviewTextBox         = (Get-Control 'ReviewTextBox')

    # Run
    RunTitleLabel         = (Get-Control 'RunTitleLabel')
    RunStatusLabel        = (Get-Control 'RunStatusLabel')
    StartRunButton        = (Get-Control 'StartRunButton')
    OpenLogButton         = (Get-Control 'OpenLogButton')
    OpenResultButton      = (Get-Control 'OpenResultButton')
    OpenSettingsButton    = (Get-Control 'OpenSettingsButton')
    OpenReportsButton     = (Get-Control 'OpenReportsButton')
    RunLogTextBox         = (Get-Control 'RunLogTextBox')

    # Pages (panels identified by WPF name)
    PageNames             = @('PageWelcome', 'PageSelection', 'PageHostSetup', 'PageAppTuning', 'PageApiCenter', 'PageApiCatalog', 'PageSteamDeck', 'PageDualBoot', 'PageReview', 'PageRun')
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

function ConvertTo-UiBoolean {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    return @('1', 'true', 'yes', 'y', 'sim', 'on') -contains $text
}

function Load-WpfGridRows {
    param(
        [Parameter(Mandatory=$true)]$Grid,
        [Parameter(Mandatory=$true)]$Items,
        [Parameter(Mandatory=$true)][string[]]$Columns
    )
    $table = New-Object System.Data.DataTable
    foreach ($col in $Columns) {
        if (@('primary', 'active') -contains $col) {
            [void]$table.Columns.Add($col, [bool])
        } else {
            [void]$table.Columns.Add($col)
        }
    }
    foreach ($item in @($Items)) {
        $row = $table.NewRow()
        foreach ($col in $Columns) {
            $value = if ($item -is [System.Collections.IDictionary] -and $item.Contains($col)) { $item[$col] }
                     elseif ($item.PSObject.Properties[$col]) { $item.$col }
                     else { $null }
            if (@('primary', 'active') -contains $col) {
                $row[$col] = ConvertTo-UiBoolean -Value $value
            } else {
                $row[$col] = if ($null -eq $value) { '' } else { [string]$value }
            }
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
            if ((@('primary', 'active', 'status') -notcontains $col) -and -not [string]::IsNullOrWhiteSpace($val)) { $hasData = $true }
            $item[$col] = $val
        }
        if ($hasData) { $rows += @($item) }
    }
    return @($rows)
}

function Get-SteamDeckEditableModes {
    return @('DOCKED_MONITOR', 'DOCKED_TV')
}

function Validate-SteamDeckGridModeRows {
    param(
        [Parameter(Mandatory=$true)]$Rows,
        [Parameter(Mandatory=$true)][string]$GridName
    )
    $validModes = @(Get-SteamDeckEditableModes)
    $index = 0
    foreach ($row in @($Rows)) {
        $index++
        $rowData = ConvertTo-BootstrapHashtable -InputObject $row
        $mode = ([string]$rowData['mode']).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($mode)) {
            throw "$GridName linha $index sem modo. Use DOCKED_MONITOR ou DOCKED_TV."
        }
        if ($validModes -notcontains $mode) {
            throw "$GridName linha $index com modo invalido: $mode. Use DOCKED_MONITOR ou DOCKED_TV."
        }
        $row['mode'] = $mode
    }
}

function Get-UiObjectValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory=$true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-UiObjectArray {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IDictionary]) {
        if (@($Value.Keys).Count -eq 0) { return @() }
        return @($Value)
    }
    if ($Value -is [pscustomobject]) {
        if (@($Value.PSObject.Properties).Count -eq 0) { return @() }
        return @($Value)
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        return @($Value)
    }
    return @($Value)
}

function Normalize-UiDisplayValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value) -replace "`0", ''
    $text = [regex]::Replace($text.Trim(), '\s+', ' ')
    return $text.ToLowerInvariant()
}

function Test-UiDisplayMatch {
    param(
        [AllowNull()]$Display,
        [AllowNull()]$Matcher,
        [switch]$RequireSerial
    )

    if ($null -eq $Display -or $null -eq $Matcher) { return $false }
    $displayManufacturer = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Display -Name 'manufacturer')
    $displayProduct = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Display -Name 'product')
    $matcherManufacturer = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Matcher -Name 'manufacturer')
    $matcherProduct = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Matcher -Name 'product')
    if ($displayManufacturer -ne $matcherManufacturer -or $displayProduct -ne $matcherProduct) { return $false }

    if ($RequireSerial) {
        $matcherSerial = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Matcher -Name 'serial')
        if (-not [string]::IsNullOrWhiteSpace($matcherSerial)) {
            $displaySerial = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Display -Name 'serial')
            if ($displaySerial -ne $matcherSerial) { return $false }
        }
    }

    return $true
}

function Get-UiSteamDeckLiveDetectionData {
    param([Parameter(Mandatory=$true)]$Settings)

    $automationRoot = Get-BootstrapSteamDeckAutomationRoot
    $detectScript = Join-Path $automationRoot 'Detect-Mode.ps1'
    if (-not (Test-Path $detectScript)) {
        return (ConvertTo-BootstrapHashtable -InputObject (Get-BootstrapSteamDeckCurrentDetectionData).Data)
    }

    $tempPath = Join-Path $env:TEMP ("steamdeck-ui-detect-settings_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        $jsonSettings = $Settings | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($tempPath, $jsonSettings, [System.Text.UTF8Encoding]::new($false))
        $json = & $detectScript -SettingsPath $tempPath 2>$null
        $text = (@($json) -join [Environment]::NewLine).Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return (ConvertTo-BootstrapHashtable -InputObject ($text | ConvertFrom-Json -ErrorAction Stop))
        }
    } catch {
        try { Write-UiLog -Level 'WARN' -Message "Steam Deck live detection failed: $($_.Exception.Message)" } catch { }
    } finally {
        if (Test-Path $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }

    return (ConvertTo-BootstrapHashtable -InputObject (Get-BootstrapSteamDeckCurrentDetectionData).Data)
}

function Get-UiSteamDeckDisplayStatus {
    param(
        [AllowNull()]$Detection,
        [Parameter(Mandatory=$true)]$Matcher,
        [switch]$Internal,
        [switch]$Family
    )

    if (-not ($Detection -is [hashtable])) { return 'status desconhecido' }

    if ($Internal) {
        $internal = Get-UiObjectValue -Object $Detection -Name 'internalDisplay'
        if ($internal) {
            $suffix = if (ConvertTo-UiBoolean (Get-UiObjectValue -Object $internal -Name 'isPrimary')) { ' / principal no Windows' } else { '' }
            return "ativo$suffix"
        }
        $externalCount = [int](Get-UiObjectValue -Object $Detection -Name 'externalDisplayCount' -Default 0)
        if ($externalCount -gt 0) { return 'desativado: so desktop externo' }
        return 'nao detectado'
    }

    $selected = Get-UiObjectValue -Object $Detection -Name 'selectedDisplay'
    if (Test-UiDisplayMatch -Display $selected -Matcher $Matcher -RequireSerial:(-not $Family)) {
        $suffix = if (ConvertTo-UiBoolean (Get-UiObjectValue -Object $selected -Name 'isPrimary')) { ' / principal no Windows' } else { '' }
        return "ativo$suffix"
    }

    foreach ($display in @(Get-UiObjectArray -Value (Get-UiObjectValue -Object $Detection -Name 'externalDisplays'))) {
        if (Test-UiDisplayMatch -Display $display -Matcher $Matcher -RequireSerial:(-not $Family)) {
            return 'ativo'
        }
    }

    return 'cadastrado'
}

function Get-UiSteamDeckProfileRows {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Settings,
        [AllowNull()]$Detection
    )

    $internal = ConvertTo-BootstrapHashtable -InputObject (Get-UiObjectValue -Object $Settings -Name 'internalDisplay' -Default @{})
    if (-not ($internal -is [hashtable])) { $internal = @{} }

    $rows = @()
    $rows += @([ordered]@{
        primary = ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $internal -Name 'primary' -Default $false)
        target = 'internal'
        status = Get-UiSteamDeckDisplayStatus -Detection $Detection -Matcher $internal -Internal
        manufacturer = [string](Get-UiObjectValue -Object $internal -Name 'manufacturer' -Default 'VLV')
        product = [string](Get-UiObjectValue -Object $internal -Name 'product' -Default 'ANX7530 U')
        serial = [string](Get-UiObjectValue -Object $internal -Name 'serial' -Default '')
        mode = 'HANDHELD'
        layout = [string](Get-UiObjectValue -Object $internal -Name 'layout' -Default 'internal-panel')
        resolutionPolicy = [string](Get-UiObjectValue -Object $internal -Name 'resolutionPolicy' -Default '1280x800')
    })

    foreach ($profile in @(Get-UiObjectArray -Value (Get-UiObjectValue -Object $Settings -Name 'monitorProfiles'))) {
        $profileMap = ConvertTo-BootstrapHashtable -InputObject $profile
        $rows += @([ordered]@{
            primary = ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $profileMap -Name 'primary' -Default $false)
            target = 'profile'
            status = Get-UiSteamDeckDisplayStatus -Detection $Detection -Matcher $profileMap
            manufacturer = [string](Get-UiObjectValue -Object $profileMap -Name 'manufacturer')
            product = [string](Get-UiObjectValue -Object $profileMap -Name 'product')
            serial = [string](Get-UiObjectValue -Object $profileMap -Name 'serial')
            mode = [string](Get-UiObjectValue -Object $profileMap -Name 'mode' -Default 'DOCKED_MONITOR')
            layout = [string](Get-UiObjectValue -Object $profileMap -Name 'layout')
            resolutionPolicy = [string](Get-UiObjectValue -Object $profileMap -Name 'resolutionPolicy')
        })
    }

    return @($rows)
}

function Get-UiSteamDeckFamilyRows {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Settings,
        [AllowNull()]$Detection
    )

    $rows = @()
    foreach ($family in @(Get-UiObjectArray -Value (Get-UiObjectValue -Object $Settings -Name 'monitorFamilies'))) {
        $familyMap = ConvertTo-BootstrapHashtable -InputObject $family
        $rows += @([ordered]@{
            primary = ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $familyMap -Name 'primary' -Default $false)
            status = Get-UiSteamDeckDisplayStatus -Detection $Detection -Matcher $familyMap -Family
            manufacturer = [string](Get-UiObjectValue -Object $familyMap -Name 'manufacturer')
            product = [string](Get-UiObjectValue -Object $familyMap -Name 'product')
            namePattern = [string](Get-UiObjectValue -Object $familyMap -Name 'namePattern')
            mode = [string](Get-UiObjectValue -Object $familyMap -Name 'mode' -Default 'DOCKED_MONITOR')
            layout = [string](Get-UiObjectValue -Object $familyMap -Name 'layout')
            resolutionPolicy = [string](Get-UiObjectValue -Object $familyMap -Name 'resolutionPolicy')
        })
    }

    return @($rows)
}

function Remove-UiGridRuntimeColumns {
    param(
        [Parameter(Mandatory=$true)]$Rows,
        [string[]]$RuntimeColumns = @('target', 'status')
    )

    $result = @()
    foreach ($row in @($Rows)) {
        $map = [ordered]@{}
        foreach ($key in @($row.Keys)) {
            if ($RuntimeColumns -contains [string]$key) { continue }
            $map[$key] = $row[$key]
        }
        $result += @($map)
    }
    return @($result)
}

#
# Helpers (same logic, updated control references)
#

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
    $ui.State.appTuningMode      = if ($PresetName -eq 'legacy') { 'off' } else { 'recommended' }
    $ui.State.selectedAppTuningCategories = @()
    $ui.State.selectedAppTuningItems = @()
    $ui.State.excludedAppTuningItems = @()
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
    $ui.QuickOptionsLabel.Text         = $ui.Strings.QuickOptions.ToUpper()
    $ui.OptClaudePluginsCheckBox.Content = $ui.Strings.OptClaudePlugins
    $ui.OptClaudeProjectMcpsCheckBox.Content = $ui.Strings.OptClaudeProjectMcps
    $ui.OptOpenWebUICheckBox.Content   = $ui.Strings.OptOpenWebUI
    $ui.ExcludeLabel.Text              = $ui.Strings.Excludes.ToUpper()
    $ui.DetailsLabel.Text              = $ui.Strings.SelectionDetails.ToUpper()
    $ui.HostTitleLabel.Text            = $ui.Strings.HostSetupTitle
    $ui.AppTuningTitleLabel.Text       = $ui.Strings.AppTuningTitle
    $ui.AppTuningSubtitleLabel.Text    = $ui.Strings.AppTuningSubtitle
    $ui.AppTuningModeLabel.Text        = $ui.Strings.AppTuningMode
    $ui.AppTuningCategoriesLabel.Text  = $ui.Strings.AppTuningCategories.ToUpper()
    $ui.AppTuningItemsLabel.Text       = $ui.Strings.AppTuningItems.ToUpper()
    $ui.AppTuningRecommendedButton.Content = $ui.Strings.AppTuningRecommended
    $ui.AppTuningMarkCategoryButton.Content = $ui.Strings.AppTuningMarkCategory
    $ui.AppTuningClearCategoryButton.Content = $ui.Strings.AppTuningClearCategory
    $ui.AppTuningAuditButton.Content   = $ui.Strings.AppTuningAudit
    $ui.AppTuningInstallButton.Content = $ui.Strings.AppTuningInstall
    $ui.AppTuningConfigureButton.Content = $ui.Strings.AppTuningConfigure
    $ui.AppTuningUpdateButton.Content  = $ui.Strings.AppTuningUpdate
    $ui.AppTuningHintLabel.Text        = $ui.Strings.AppTuningStatus
    $ui.ApiCenterTitleLabel.Text       = $ui.Strings.ApiCenterTitle
    $ui.ApiProviderSummaryLabel.Text   = $ui.Strings.ApiProviderSummary.ToUpper()
    $ui.ApiCredentialsLabel.Text       = $ui.Strings.ApiCredentials.ToUpper()
    $ui.ApiUsageLabel.Text             = $ui.Strings.ApiUsage.ToUpper()
    $ui.ApiCreateLabel.Text            = $ui.Strings.ApiCreate.ToUpper()
    $ui.ApiRefreshButton.Content       = $ui.Strings.ApiRefresh
    $ui.ApiValidateAllButton.Content   = $ui.Strings.ApiValidateAll
    $ui.ApiImportButton.Content        = $ui.Strings.ApiImport
    $ui.ApiCatalogButton.Content       = $ui.Strings.ApiCatalog
    $ui.ApiApplyButton.Content         = $ui.Strings.ApiApply
    $ui.ApiSaveButton.Content          = $ui.Strings.ApiSave
    $ui.ApiValidateButton.Content      = $ui.Strings.ApiValidate
    $ui.ApiActivateButton.Content      = $ui.Strings.ApiActivate
    $ui.ApiCatalogTitleLabel.Text      = $ui.Strings.ApiCatalogTitle
    $ui.ApiCatalogSubtitleLabel.Text   = $ui.Strings.ApiCatalogSubtitle
    $ui.ApiCatalogBackButton.Content   = $ui.Strings.ApiCatalogBack
    $ui.ApiFullCatalogLabel.Text       = $ui.Strings.ApiCatalogTitle.ToUpper()
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
    $ui.DisplayModeLabel.Text          = $ui.Strings.DisplayMode
    $ui.SessionGroupLabel.Text         = $ui.Strings.SessionProfiles.ToUpper()
    $ui.HandheldSessionLabel.Text      = $ui.Strings.SessionHandheld
    $ui.DockTvSessionLabel.Text        = $ui.Strings.SessionDockedTv
    $ui.DockMonitorSessionLabel.Text   = $ui.Strings.SessionDockedMonitor
    $ui.PendingExternalLabel.Text      = $ui.Strings.PendingExternal.ToUpper()
    $ui.ClassifyMonitorButton.Content  = " $($ui.Strings.ClassifyMonitor)"
    $ui.ClassifyTvButton.Content       = " $($ui.Strings.ClassifyTv)"
    $ui.UnknownMonitorHintLabel.Text   = $ui.Strings.UnknownMonitorHint
    $ui.SaveSettingsButton.Content     = " $($ui.Strings.SaveSettings)"
    $ui.ReloadSettingsButton.Content   = " $($ui.Strings.ReloadSettings)"
    $ui.ReviewTitleLabel.Text          = $ui.Strings.ReviewTitle
    $ui.ReviewSummaryLabel.Text        = "$($ui.Strings.ReviewSummary)"
    $ui.ReviewSideEffectsLabel.Text    = $ui.Strings.ReviewSideEffects
    $ui.RefreshReviewButton.Content    = " $($ui.Strings.RefreshReview)"
    $ui.RunTitleLabel.Text             = $ui.Strings.RunTitle
    $ui.StartRunButton.Content         = $ui.Strings.StartRun
    $ui.OpenLogButton.Content          = " $($ui.Strings.OpenLog)"
    $ui.OpenResultButton.Content       = " $($ui.Strings.OpenResult)"
    $ui.OpenSettingsButton.Content     = "[gear] $($ui.Strings.OpenSettings)"
    $ui.OpenReportsButton.Content      = " $($ui.Strings.OpenReports)"
    $ui.BackButton.Content             = $ui.Strings.Back
    $ui.NextButton.Content             = $ui.Strings.Next
    $ui.FinishButton.Content           = $ui.Strings.Finish
    $ui.StatusLabel.Text               = $ui.Strings.IdleStatus
    # Sidebar nav text
    $ui.NavWelcomeText.Text    = $ui.Strings.Welcome
    $ui.NavSelectionText.Text  = $ui.Strings.Selection
    $ui.NavHostSetupText.Text  = $ui.Strings.HostSetup
    $ui.NavAppTuningText.Text  = $ui.Strings.AppTuning
    $ui.NavApiCenterText.Text  = $ui.Strings.ApiCenter
    $ui.NavSteamDeckText.Text  = $ui.Strings.SteamDeckControl
    $ui.NavDualBootText.Text   = $ui.Strings.DualBoot
    $ui.DualBootTitleLabel.Text = $ui.Strings.DualBoot
    $ui.NavReviewText.Text     = $ui.Strings.Review
    $ui.NavRunText.Text        = $ui.Strings.Run
}

function Get-UiResolvedComponentNameSet {
    $lookup = @{}
    try {
        $selection = New-BootstrapSelectionObject -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents @() -SelectedHostHealth $ui.State.hostHealth
        $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents @()
        foreach ($componentName in @($resolution.ResolvedComponents)) {
            if ([string]::IsNullOrWhiteSpace([string]$componentName)) { continue }
            if (@($ui.State.excludedComponents) -contains [string]$componentName) { continue }
            $lookup[[string]$componentName] = $true
        }
    } catch {
    }
    return $lookup
}

function Refresh-SelectionTrees {
    $filter = ($ui.FilterTextBox.Text).Trim().ToLowerInvariant()
    $resolvedComponentLookup = Get-UiResolvedComponentNameSet
    $ui.SuppressSelectionEvents = $true
    try {
        $ui.ProfilesTree.Items.Clear()
        foreach ($profile in @($ui.Contract.profiles | Where-Object {
            ($filter -eq '') -or ($_.name.ToLowerInvariant().Contains($filter)) -or ($_.description.ToLowerInvariant().Contains($filter))
        })) {
            $item = New-Object System.Windows.Controls.TreeViewItem
            $item.Header   = $profile.name
            $item.Tag      = @{ kind = 'profile'; item = $profile }
            $item.Foreground = Get-UiBrush '#CBD5E1'
            # CheckBox inside item header
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content    = $profile.name
            $cb.IsChecked  = (@($ui.State.selectedProfiles) -contains $profile.name)
            $cb.Foreground = Get-UiBrush '#CBD5E1'
            $cb.Tag        = @{ kind = 'profile'; item = $profile; name = $profile.name }
            $cb.Style      = $window.FindResource('DarkCheck')
            $cb.ToolTip    = "Perfil: $([string]$profile.name)`nDescrição: $([string]$profile.description)`nInclui: $(@($profile.items) -join ', ')"
            $item.Header   = $cb
            $cb.Add_Checked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                if (-not (@($ui.State.selectedProfiles) -contains $name)) {
                    $ui.State.selectedProfiles = @(@($ui.State.selectedProfiles) + $name)
                    Save-UiState -State $ui.State -Path $UiStatePath
                    Refresh-SelectionTrees
                    Refresh-SelectionSummary
                }
            })
            $cb.Add_Unchecked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                $ui.State.selectedProfiles = @(@($ui.State.selectedProfiles) | Where-Object { $_ -ne $name })
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-SelectionTrees
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
            $componentName = [string]$component.name
            $isExplicitComponent = (@($ui.State.selectedComponents) -contains $componentName)
            $isResolvedComponent = $resolvedComponentLookup.ContainsKey($componentName)
            $isExcludedComponent = (@($ui.State.excludedComponents) -contains $componentName)
            $cb.Content   = $componentName
            $cb.IsChecked = (($isExplicitComponent -or $isResolvedComponent) -and -not $isExcludedComponent)
            $cb.Foreground = Get-UiBrush '#CBD5E1'
            $cb.Style = $window.FindResource('DarkCheck')
            $cb.Tag = @{ kind = 'component'; item = $component; name = $componentName; explicit = $isExplicitComponent; resolved = $isResolvedComponent; excluded = $isExcludedComponent }
            $cb.ToolTip = "Componente: $componentName`nDescrição: $([string]$component.description)`nTipo: $([string]$component.kind)`nEstágio: $([string]$component.stage)`nDepende de: $(@($component.dependsOn) -join ', ')"
            if ($isResolvedComponent -and -not $isExplicitComponent) {
                $cb.Opacity = 0.82
                $cb.ToolTip = 'Incluido pelo perfil selecionado. Desmarcar item vindo de perfil adiciona em Nao instalar.'
            }
            $item.Header = $cb
            $cb.Add_Checked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                if (@($ui.State.excludedComponents) -contains $name) {
                    $ui.State.excludedComponents = @(@($ui.State.excludedComponents) | Where-Object { $_ -ne $name })
                }
                if (-not [bool]$this.Tag.resolved -and -not (@($ui.State.selectedComponents) -contains $name)) {
                    $ui.State.selectedComponents = @(@($ui.State.selectedComponents) + $name)
                }
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-SelectionTrees
                Refresh-SelectionSummary
            })
            $cb.Add_Unchecked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                if ([bool]$this.Tag.resolved -and -not (@($ui.State.excludedComponents) -contains $name)) {
                    # Desmarcar item vindo de perfil adiciona em Nao instalar.
                    $ui.State.excludedComponents = @(@($ui.State.excludedComponents) + $name)
                }
                if ([bool]$this.Tag.explicit) {
                    $ui.State.selectedComponents = @(@($ui.State.selectedComponents) | Where-Object { $_ -ne $name })
                }
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-SelectionTrees
                Refresh-SelectionSummary
            })
            $item.Add_Selected({
                if ($this.Tag -and $this.Tag.item) {
                    $ui.DetailsTextBox.Text = Get-SelectionDetailsText -Item $this.Tag.item -Kind $this.Tag.kind
                }
            })
            [void]$ui.ComponentsTree.Items.Add($item)
        }

        $ui.OptClaudePluginsCheckBox.IsChecked = $resolvedComponentLookup.ContainsKey('claude-plugins')
        $ui.OptOpenWebUICheckBox.IsChecked     = $resolvedComponentLookup.ContainsKey('openwebui')
        $ui.OptClaudeProjectMcpsCheckBox.IsChecked = [bool]$ui.State.enableClaudeCodeProjectMcps
        $ui.OptSkipManualRequirementsCheckBox.IsChecked = [bool]$ui.State.skipManualRequirements
        $ui.OptIgnoreManualRequirementsCheckBox.IsChecked = [bool]$ui.State.ignoreManualRequirements
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
            $cb.Style     = $window.FindResource('DarkCheck')
            $cb.Foreground = Get-UiBrush '#CBD5E1'
            $tname = $componentName
            $cb.Add_Checked({
                if (-not (@($ui.State.excludedComponents) -contains $tname)) {
                    $ui.State.excludedComponents = @(@($ui.State.excludedComponents) + $tname)
                    Save-UiState -State $ui.State -Path $UiStatePath
                    Refresh-SelectionTrees
                    Refresh-SelectionSummary
                }
            })
            $cb.Add_Unchecked({
                $ui.State.excludedComponents = @(@($ui.State.excludedComponents) | Where-Object { $_ -ne $tname })
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-SelectionTrees
                Refresh-SelectionSummary
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
        $ui.Preview = Get-BootstrapPreviewData -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents $ui.State.excludedComponents -RequestedSteamDeckVersion $ui.State.steamDeckVersion -RequestedHostHealthMode $ui.State.hostHealth -RequestedAppTuningMode $ui.State.appTuningMode -RequestedAppTuningCategories $ui.State.selectedAppTuningCategories -RequestedAppTuningItems $ui.State.selectedAppTuningItems -ExcludedAppTuningItems $ui.State.excludedAppTuningItems -RequestedWorkspaceRoot $ui.State.workspaceRoot -ExplicitCloneBaseDir $ui.State.cloneBaseDir
        $ui.SelectionSummaryLabel.Text = "Resolved: $(@($ui.Preview.Resolution.ResolvedComponents).Count) components | HostHealth: $($ui.Preview.ResolvedHostHealthMode) | AppTuning: $($ui.Preview.ResolvedAppTuningMode)"
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

function Get-UiAppTuningPreview {
    $selection = New-BootstrapSelectionObject -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents $ui.State.excludedComponents -SelectedHostHealth $ui.State.hostHealth -SelectedAppTuning $ui.State.appTuningMode -SelectedAppTuningCategories $ui.State.selectedAppTuningCategories -SelectedAppTuningItems $ui.State.selectedAppTuningItems -ExcludedAppTuningItems $ui.State.excludedAppTuningItems
    $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents $selection.Excludes
    return Resolve-BootstrapAppTuningSelection -Mode $selection.AppTuning -Categories $selection.AppTuningCategories -Items $selection.AppTuningItems -ExcludedItems $selection.ExcludedAppTuningItems -Selection $selection -Resolution $resolution
}

function Get-UiAppTuningCategoryCounts {
    param([Parameter(Mandatory=$true)]$Plan)

    $catalog = Get-BootstrapAppTuningCatalog
    $selected = @{}
    foreach ($item in @($Plan.items)) { $selected[[string]$item.id] = $true }
    $counts = @{}
    foreach ($category in @($catalog.categories)) {
        $items = @($catalog.items | Where-Object { [string]$_.category -eq [string]$category.id })
        $active = @($items | Where-Object { $selected.ContainsKey([string]$_.id) }).Count
        $counts[[string]$category.id] = [ordered]@{ active = $active; total = $items.Count }
    }
    return $counts
}

function Repair-UiAppTuningState {
    $catalog = Get-BootstrapAppTuningCatalog
    $validCategories = @{}
    foreach ($category in @($catalog.categories)) {
        $validCategories[[string]$category.id] = $true
    }
    $validItems = @{}
    foreach ($item in @($catalog.items)) {
        $validItems[[string]$item.id] = $true
    }

    $normalizedCategories = @(Normalize-BootstrapNames -Names $ui.State.selectedAppTuningCategories)
    $normalizedItems = @(Normalize-BootstrapNames -Names $ui.State.selectedAppTuningItems)
    $normalizedExcludedItems = @(Normalize-BootstrapNames -Names $ui.State.excludedAppTuningItems)
    $modeWarning = ''
    try {
        $normalizedMode = Normalize-BootstrapAppTuningMode -Mode ([string]$ui.State.appTuningMode)
        if ([string]::IsNullOrWhiteSpace($normalizedMode)) {
            $normalizedMode = 'recommended'
        }
    } catch {
        $normalizedMode = 'recommended'
        $modeWarning = "Modo AppTuning inválido no estado atual. Ajustado para 'recommended'."
    }

    $keptCategories = @()
    $removedCategories = @()
    foreach ($categoryId in @($normalizedCategories)) {
        if ($validCategories.ContainsKey($categoryId)) {
            $keptCategories += @($categoryId)
        } else {
            $removedCategories += @($categoryId)
        }
    }

    $keptItems = @()
    $removedItems = @()
    foreach ($itemId in @($normalizedItems)) {
        if ($validItems.ContainsKey($itemId)) {
            $keptItems += @($itemId)
        } else {
            $removedItems += @($itemId)
        }
    }

    $keptExcludedItems = @()
    $removedExcludedItems = @()
    foreach ($itemId in @($normalizedExcludedItems)) {
        if ($validItems.ContainsKey($itemId)) {
            $keptExcludedItems += @($itemId)
        } else {
            $removedExcludedItems += @($itemId)
        }
    }

    $changed = $false
    if ((@($ui.State.selectedAppTuningCategories) -join '|') -ne (@($keptCategories) -join '|')) {
        $ui.State.selectedAppTuningCategories = @($keptCategories)
        $changed = $true
    }
    if ((@($ui.State.selectedAppTuningItems) -join '|') -ne (@($keptItems) -join '|')) {
        $ui.State.selectedAppTuningItems = @($keptItems)
        $changed = $true
    }
    if ((@($ui.State.excludedAppTuningItems) -join '|') -ne (@($keptExcludedItems) -join '|')) {
        $ui.State.excludedAppTuningItems = @($keptExcludedItems)
        $changed = $true
    }
    if ([string]$ui.State.appTuningMode -ne $normalizedMode) {
        $ui.State.appTuningMode = $normalizedMode
        $changed = $true
    }

    $warnings = @()
    if ($removedCategories.Count -gt 0) {
        $warnings += @("Categorias removidas por não existirem mais no catálogo: $(@($removedCategories) -join ', ').")
    }
    if ($removedItems.Count -gt 0) {
        $warnings += @("Itens removidos da seleção por não existirem mais no catálogo: $(@($removedItems) -join ', ').")
    }
    if ($removedExcludedItems.Count -gt 0) {
        $warnings += @("Itens removidos da lista de exclusão por não existirem mais no catálogo: $(@($removedExcludedItems) -join ', ').")
    }
    if (-not [string]::IsNullOrWhiteSpace($modeWarning)) {
        $warnings += @($modeWarning)
    }

    return [ordered]@{
        Changed = $changed
        Warnings = @($warnings)
    }
}

function Format-UiAppTuningState {
    param([AllowNull()][string]$State)

    switch ([string]$State) {
        'installed' { return '[x] instalado' }
        'missing' { return '[ ] ausente' }
        'configured' { return '[x] configurado' }
        'planned' { return '[~] planejado' }
        'not-configured' { return '[ ] nao' }
        'check' { return '[?] verificar' }
        'not-installed' { return '-' }
        default { return [string]$State }
    }
}

function Refresh-AppTuningControls {
    try {
        $repair = Repair-UiAppTuningState
        if ([bool]$repair.Changed) {
            Save-UiState -State $ui.State -Path $UiStatePath
        }

        $ui.AppTuningModeCombo.SelectedItem = [string]$ui.State.appTuningMode
        if (-not $ui.AppTuningStatusFilterCombo.SelectedItem) {
            $ui.AppTuningStatusFilterCombo.SelectedItem = 'all'
        }
        $planWarnings = @()
        try {
            $plan = Get-UiAppTuningPreview
        } catch {
            $plan = [ordered]@{
                mode = [string]$ui.State.appTuningMode
                categories = @()
                requestedCategories = @()
                requestedItems = @()
                excludedItems = @()
                items = @()
                skippedItems = @()
                installedInventory = $null
            }
            $planWarnings += @("Não foi possível resolver seleção completa do AppTuning: $($_.Exception.Message)")
        }
        $catalog = Get-BootstrapAppTuningCatalog
        $counts = Get-UiAppTuningCategoryCounts -Plan $plan
        $activeMap = @{}
        $itemStateMap = @{}
        foreach ($item in @($plan.items)) {
            $activeMap[[string]$item.id] = $true
            $itemStateMap[[string]$item.id] = $item
        }

        $ui.SuppressAppTuningEvents = $true
        try {
            $ui.AppTuningCategoryList.Items.Clear()
            foreach ($category in @($catalog.categories)) {
                $categoryId = [string]$category.id
                $categoryName = [string]$category.displayName
                $count = $counts[$categoryId]
                $cb = New-Object System.Windows.Controls.CheckBox
                if ([string]::IsNullOrWhiteSpace($categoryName)) {
                    $cb.Content = "{0} ({1}/{2})" -f $categoryId, [int]$count.active, [int]$count.total
                } else {
                    $cb.Content = "{0} ({1}/{2})" -f $categoryName, [int]$count.active, [int]$count.total
                }
                $cb.Tag = $categoryId
                $cb.Foreground = Get-UiBrush '#CBD5E1'
                $cb.Style = $window.FindResource('DarkCheck')
                $cb.IsChecked = (@($ui.State.selectedAppTuningCategories) -contains $categoryId)
                $cb.ToolTip = "Categoria: $categoryName`nId: $categoryId`nDescrição: $([string]$category.description)"
                $cb.Add_Checked({
                    if ($ui.SuppressAppTuningEvents) { return }
                    $id = [string]$this.Tag
                    if (-not (@($ui.State.selectedAppTuningCategories) -contains $id)) {
                        $ui.State.selectedAppTuningCategories = @(@($ui.State.selectedAppTuningCategories) + $id)
                    }
                    $ui.State.appTuningMode = 'custom'
                    Save-UiState -State $ui.State -Path $UiStatePath
                    Refresh-AppTuningControls
                })
                $cb.Add_Unchecked({
                    if ($ui.SuppressAppTuningEvents) { return }
                    $id = [string]$this.Tag
                    $ui.State.selectedAppTuningCategories = @(@($ui.State.selectedAppTuningCategories) | Where-Object { $_ -ne $id })
                    $ui.State.appTuningMode = 'custom'
                    Save-UiState -State $ui.State -Path $UiStatePath
                    Refresh-AppTuningControls
                })
                $li = New-Object System.Windows.Controls.ListBoxItem
                $li.Content = $cb
                $li.Tag = $categoryId
                $li.Background = [System.Windows.Media.Brushes]::Transparent
                [void]$ui.AppTuningCategoryList.Items.Add($li)
            }
        } finally {
            $ui.SuppressAppTuningEvents = $false
        }

        $rows = @()
        $filter = if ($ui.AppTuningSearchBox) { $ui.AppTuningSearchBox.Text.Trim().ToLowerInvariant() } else { '' }
        $statusFilter = if ($ui.AppTuningStatusFilterCombo -and $ui.AppTuningStatusFilterCombo.SelectedItem) { [string]$ui.AppTuningStatusFilterCombo.SelectedItem } else { 'all' }
        $statusRows = @(Get-BootstrapAppTuningStatusRows -Plan $plan)
        $filteredCount = 0
        foreach ($item in @($statusRows)) {
            $itemId = [string]$item.id
            $haystack = ("{0} {1} {2} {3} {4} {5}" -f $item.id, $item.category, $item.app, $item.displayName, $item.description, (@($item.installComponents) -join ' ')).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($filter) -and -not $haystack.Contains($filter)) { continue }
            if ($statusFilter -eq 'missing' -and [string]$item.installedState -ne 'missing') { continue }
            if ($statusFilter -eq 'installed' -and [string]$item.installedState -ne 'installed') { continue }
            if ($statusFilter -eq 'planned' -and [string]$item.configuredState -ne 'planned') { continue }
            if ($statusFilter -eq 'not-configured' -and [string]$item.configuredState -ne 'not-configured') { continue }
            if ($statusFilter -eq 'update-check' -and [string]$item.updatedState -ne 'check') { continue }
            $filteredCount++
            $rows += @([ordered]@{
                active = $activeMap.ContainsKey($itemId)
                id = $itemId
                category = [string]$item.category
                app = [string]$item.app
                optimization = [string]$item.displayName
                description = [string]$item.description
                profile = (@($item.profiles) -join ', ')
                risk = [string]$item.risk
                installed = Format-UiAppTuningState -State ([string]$item.installedState)
                configured = Format-UiAppTuningState -State ([string]$item.configuredState)
                updated = Format-UiAppTuningState -State ([string]$item.updatedState)
                installedStateRaw = [string]$item.installedState
                configuredStateRaw = [string]$item.configuredState
                updatedStateRaw = [string]$item.updatedState
                admin = [string]$item.requiresAdmin
                installComponents = (@($item.installComponents) -join ', ')
            })
        }
        Load-WpfGridRows -Grid $ui.AppTuningItemsGrid -Items $rows -Columns @('active','id','installComponents','category','app','optimization','description','profile','risk','installed','configured','updated','installedStateRaw','configuredStateRaw','updatedStateRaw','admin')
        $installedCount = @($statusRows | Where-Object { [string]$_.installedState -eq 'installed' }).Count
        $configuredCount = @($statusRows | Where-Object { [string]$_.configuredState -in @('configured','planned') }).Count
        $ui.AppTuningStatusLabel.Text = "AppTuning: $($plan.mode) | apps: $installedCount/$(@($statusRows).Count) instalados | config: $configuredCount | selecionados: $(@($plan.items).Count) | exibidos: $filteredCount/$(@($statusRows).Count) | status: $statusFilter"
        if (-not [string]::IsNullOrWhiteSpace($filter)) {
            $ui.AppTuningStatusLabel.Text += " | busca: '$filter'"
        }
        if ($filteredCount -eq 0) {
            $ui.AppTuningStatusLabel.Text += " | nenhum item corresponde aos filtros atuais."
        }
        if (@($repair.Warnings).Count -gt 0) {
            $ui.AppTuningStatusLabel.Text += " | " + (@($repair.Warnings) -join ' ')
        }
        if (@($planWarnings).Count -gt 0) {
            $ui.AppTuningStatusLabel.Text += " | " + (@($planWarnings) -join ' ')
        }
    } catch {
        $ui.AppTuningStatusLabel.Text = "AppTuning erro: $($_.Exception.Message)"
    }
}

function Capture-AppTuningStateFromControls {
    if ($ui.AppTuningModeCombo.SelectedItem) {
        $ui.State.appTuningMode = [string]$ui.AppTuningModeCombo.SelectedItem
    }
    if ([string]$ui.State.appTuningMode -ne 'custom') {
        Save-UiState -State $ui.State -Path $UiStatePath
        return
    }

    $rows = @(Read-WpfGridRows -Grid $ui.AppTuningItemsGrid -Columns @('active','id','installComponents','category','app','optimization','profile','risk','installed','configured','updated','admin'))
    if ($rows.Count -eq 0) {
        Save-UiState -State $ui.State -Path $UiStatePath
        return
    }

    $selectedItems = @()
    $excludedItems = @()
    foreach ($row in @($rows)) {
        $id = [string]$row['id']
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if (ConvertTo-UiBoolean -Value $row['active']) {
            $selectedItems += @($id)
        } else {
            $excludedItems += @($id)
        }
    }
    $ui.State.selectedAppTuningItems = @(Normalize-BootstrapNames -Names $selectedItems)
    $ui.State.excludedAppTuningItems = @(Normalize-BootstrapNames -Names $excludedItems)
    Save-UiState -State $ui.State -Path $UiStatePath
}

function Get-SelectedAppTuningRows {
    $rows = @()
    foreach ($selected in @($ui.AppTuningItemsGrid.SelectedItems)) {
        $rowData = $null
        if ($selected -and $selected.PSObject.Properties['Row']) {
            $rowData = $selected.Row
        } elseif ($selected -is [System.Collections.IDictionary]) {
            $rowData = $selected
        }
        if ($rowData) {
            $row = [ordered]@{}
            foreach ($column in @('active','id','installComponents','category','app','optimization','profile','risk','installed','configured','updated','admin')) {
                if ($rowData -is [System.Collections.IDictionary]) {
                    $row[$column] = if ($rowData.Contains($column)) { [string]$rowData[$column] } else { '' }
                } else {
                    $row[$column] = [string]$rowData[$column]
                }
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$row['id'])) {
                $rows += @($row)
            }
        }
    }
    if ($rows.Count -gt 0) { return @($rows) }
    return @(Read-WpfGridRows -Grid $ui.AppTuningItemsGrid -Columns @('active','id','installComponents','category','app','optimization','profile','risk','installed','configured','updated','admin') | Where-Object { ConvertTo-UiBoolean -Value $_['active'] })
}

function Add-UiSelectedComponents {
    param([string[]]$Components)

    $componentCatalog = Get-BootstrapComponentCatalog
    $added = @()
    foreach ($componentName in @(Normalize-BootstrapNames -Names $Components)) {
        if ([string]::IsNullOrWhiteSpace($componentName)) { continue }
        if (-not (Test-BootstrapMapContainsKey -Map $componentCatalog -Key $componentName)) { continue }
        if (@($ui.State.excludedComponents) -contains $componentName) {
            $ui.State.excludedComponents = @(@($ui.State.excludedComponents) | Where-Object { $_ -ne $componentName })
        }
        if (-not (@($ui.State.selectedComponents) -contains $componentName)) {
            $ui.State.selectedComponents = @(@($ui.State.selectedComponents) + $componentName)
            $added += @($componentName)
        }
    }
    Save-UiState -State $ui.State -Path $UiStatePath
    return @($added)
}

function Get-UiFriendlyActionError {
    param(
        [Parameter(Mandatory = $true)][string]$ActionLabel,
        [Parameter(Mandatory = $true)][System.Exception]$Exception
    )

    return ("Não foi possível concluir {0}. Tente novamente. Se persistir, consulte o log da UI." -f $ActionLabel)
}

function Queue-AppTuningInstallOrUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$ActionName,
        [AllowNull()][object[]]$Rows = $null
    )

    $components = @()
    $sourceRows = if ($Rows) { @($Rows) } else { @(Get-SelectedAppTuningRows) }
    foreach ($row in @($sourceRows)) {
        foreach ($component in (([string]$row['installComponents']) -split ',')) {
            if ([string]::IsNullOrWhiteSpace($component)) { continue }
            $components += @($component.Trim())
        }
    }
    $added = @(Add-UiSelectedComponents -Components $components)
    Refresh-SelectionSummary
    Refresh-AppTuningControls
    $ui.StatusLabel.Text = if ($added.Count -gt 0) {
        "$ActionName planejado: $(@($added) -join ', ')"
    } else {
        "${ActionName}: nenhum componente novo para marcar."
    }
}

function Queue-AppTuningConfigure {
    param([AllowNull()][object[]]$Rows = $null)

    $ids = @()
    $sourceRows = if ($Rows) { @($Rows) } else { @(Get-SelectedAppTuningRows) }
    foreach ($row in @($sourceRows)) {
        $id = [string]$row['id']
        if (-not [string]::IsNullOrWhiteSpace($id)) { $ids += @($id) }
    }
    if ($ids.Count -eq 0) { return }
    $ui.State.appTuningMode = 'custom'
    foreach ($id in @(Normalize-BootstrapNames -Names $ids)) {
        if (-not (@($ui.State.selectedAppTuningItems) -contains $id)) {
            $ui.State.selectedAppTuningItems = @(@($ui.State.selectedAppTuningItems) + $id)
        }
        if (@($ui.State.excludedAppTuningItems) -contains $id) {
            $ui.State.excludedAppTuningItems = @(@($ui.State.excludedAppTuningItems) | Where-Object { $_ -ne $id })
        }
    }
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-AppTuningControls
    $ui.StatusLabel.Text = "Config/Otimizacao planejada: $(@($ids) -join ', ')"
}

function Get-CurrentAppTuningRow {
    $selected = $ui.AppTuningItemsGrid.SelectedItem
    if ($null -eq $selected) { return $null }

    $rowData = $null
    if ($selected -and $selected.PSObject.Properties['Row']) {
        $rowData = $selected.Row
    } elseif ($selected -is [System.Collections.IDictionary]) {
        $rowData = $selected
    }
    if ($null -eq $rowData) { return $null }

    $row = [ordered]@{}
    foreach ($column in @('active','id','installComponents','category','app','optimization','profile','risk','installed','configured','updated','admin')) {
        if ($rowData -is [System.Collections.IDictionary]) {
            $row[$column] = if ($rowData.Contains($column)) { [string]$rowData[$column] } else { '' }
        } else {
            $row[$column] = [string]$rowData[$column]
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$row['id'])) { return $null }
    return $row
}

function Invoke-AppTuningSingleRowAction {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][ValidateSet('install', 'configure', 'update')][string]$Action
    )

    $rowId = [string]$Row['id']
    $rowName = [string]$Row['optimization']
    if ([string]::IsNullOrWhiteSpace($rowName)) { $rowName = [string]$Row['app'] }
    $ui.StatusLabel.Text = "Processando $Action para '$rowName'..."
    try {
        switch ($Action) {
            'install' { Queue-AppTuningInstallOrUpdate -ActionName 'Instalacao' -Rows @($Row) }
            'configure' { Queue-AppTuningConfigure -Rows @($Row) }
            'update' { Queue-AppTuningInstallOrUpdate -ActionName 'Atualizacao' -Rows @($Row) }
        }
        Refresh-AppTuningControls
        $ui.StatusLabel.Text = "Ação unitária concluída para '$rowId' ($Action)."
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("AppTuning ação unitária falhou | action={0} | id={1} | message={2}`n{3}" -f $Action, $rowId, $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = (Get-UiFriendlyActionError -ActionLabel "a ação '$Action' no item '$rowName'" -Exception $_.Exception)
    }
}

function Get-SelectedApiProviderId {
    if ($ui.ApiProviderCombo.SelectedItem) { return [string]$ui.ApiProviderCombo.SelectedItem }
    return ''
}

function Get-SelectedApiCredentialId {
    if ($ui.ApiCredentialCombo.SelectedItem) {
        $value = [string]$ui.ApiCredentialCombo.SelectedItem
        if ($value -eq '<new>') { return '' }
        return $value
    }
    return ''
}

function Get-ApiProviderInventory {
    param([string]$ProviderId)
    if ([string]::IsNullOrWhiteSpace($ProviderId) -or -not $ui.Contains('ApiInventory')) { return $null }
    return ($ui.ApiInventory.providers | Where-Object { $_.id -eq $ProviderId } | Select-Object -First 1)
}

function Get-ApiDiagnosticsSummaryText {
    param([AllowNull()]$Summary)

    if ($null -eq $Summary) { return '' }
    $parts = @()
    $summaryMap = ConvertTo-BootstrapHashtable -InputObject $Summary
    if ($summaryMap.Contains('openAiCompatible') -and ($summaryMap['openAiCompatible'] -is [System.Collections.IDictionary])) {
        $compat = ConvertTo-BootstrapHashtable -InputObject $summaryMap['openAiCompatible']
        $compatStatus = [string]$compat['status']
        if ($compatStatus -eq 'selected') {
            $parts += @("OpenAI-compatible: $([string]$compat['provider']) ($([string]$compat['baseUrl']))")
        } else {
            $parts += @("OpenAI-compatible: sem provider utilizável (status=$compatStatus)")
        }
    }
    if ($summaryMap.Contains('claudeDesktopAccess') -and ($summaryMap['claudeDesktopAccess'] -is [System.Collections.IDictionary])) {
        $claude = ConvertTo-BootstrapHashtable -InputObject $summaryMap['claudeDesktopAccess']
        $claudeStatus = [string]$claude['status']
        if ($claudeStatus -eq 'blocked') {
            $parts += @("Claude Desktop: $([string]$claude['message']) Ação: $([string]$claude['action'])")
        } elseif ($claudeStatus -eq 'warning') {
            $parts += @("Claude Desktop: $([string]$claude['message'])")
        }
    }
    if ($summaryMap.Contains('appCoverage') -and ($summaryMap['appCoverage'] -is [System.Collections.IDictionary])) {
        $coverage = ConvertTo-BootstrapHashtable -InputObject $summaryMap['appCoverage']
        $parts += @(
            "Cobertura apps: BYOK+MCP=$([string]$coverage['byokAndMcp'])"
            "BYOK=$([string]$coverage['byokOnly'])"
            "MCP=$([string]$coverage['mcpOnly'])"
            "Pulados=$([string]$coverage['skipped'])"
        ) -join ', '
        if ((Test-BootstrapMapContainsKey -Map $coverage -Key 'apps') -and ($coverage['apps'] -is [System.Collections.IEnumerable])) {
            $pending = @()
            foreach ($entryRaw in @($coverage['apps'])) {
                $entry = ConvertTo-BootstrapHashtable -InputObject $entryRaw
                if ([string]$entry['status'] -eq 'mcp-only' -or [string]$entry['status'] -eq 'skipped') {
                    $pending += @("$([string]$entry['displayName'])=$([string]$entry['status'])")
                }
            }
            if ($pending.Count -gt 0) {
                $parts += @("Pendências: $([string]::Join('; ', $pending))")
            }
        }
    }
    return (@($parts) -join ' | ')
}

function Set-ApiCenterStatusMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Channel,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()]$Diagnostics = $null,
        [switch]$IsError
    )

    $prefix = if ($IsError) { 'API Center erro' } else { "API Center [$Channel]" }
    $text = "${prefix}: $Message"
    $diagnosticSummary = Get-ApiDiagnosticsSummaryText -Summary $Diagnostics
    if (-not [string]::IsNullOrWhiteSpace($diagnosticSummary)) {
        $text += " | Diagnostico API: $diagnosticSummary"
    }
    $ui.ApiStatusLabel.Text = $text
}

function Refresh-ApiCredentialEditor {
    $providerId = Get-SelectedApiProviderId
    $provider = Get-ApiProviderInventory -ProviderId $providerId
    $credentialId = Get-SelectedApiCredentialId

    $ui.ApiDisplayNameTextBox.Text = ''
    $ui.ApiSecretBox.Password = ''
    $ui.ApiBaseUrlTextBox.Text = ''
    $ui.ApiOrganizationTextBox.Text = ''
    $ui.ApiProjectRefTextBox.Text = ''
    $ui.ApiStatusLinksLabel.Visibility = 'Collapsed'
    $ui.ApiSignupLink.IsEnabled = $false
    $ui.ApiDocsLink.IsEnabled = $false
    $ui.ApiPricingLink.IsEnabled = $false
    $ui.ApiSignupLink.NavigateUri = $null
    $ui.ApiDocsLink.NavigateUri = $null
    $ui.ApiPricingLink.NavigateUri = $null

    if (-not $provider) { return }
    $ui.ApiStatusLabel.Text = "Provider: $($provider.displayName)"
    $hasLink = $false
    $signupUrl = [string]$provider.signupUrl
    if (-not [string]::IsNullOrWhiteSpace($signupUrl)) {
        try { $ui.ApiSignupLink.NavigateUri = [Uri]$signupUrl; $ui.ApiSignupLink.IsEnabled = $true; $hasLink = $true } catch { }
    }
    $docsUrl = [string]$provider.docsUrl
    if (-not [string]::IsNullOrWhiteSpace($docsUrl)) {
        try { $ui.ApiDocsLink.NavigateUri = [Uri]$docsUrl; $ui.ApiDocsLink.IsEnabled = $true; $hasLink = $true } catch { }
    }
    $pricingUrl = [string]$provider.pricingUrl
    if (-not [string]::IsNullOrWhiteSpace($pricingUrl)) {
        try { $ui.ApiPricingLink.NavigateUri = [Uri]$pricingUrl; $ui.ApiPricingLink.IsEnabled = $true; $hasLink = $true } catch { }
    }
    if ($hasLink) { $ui.ApiStatusLinksLabel.Visibility = 'Visible' }

    if ([string]::IsNullOrWhiteSpace($credentialId)) { return }
    $credential = $provider.credentials | Where-Object { $_.id -eq $credentialId } | Select-Object -First 1
    if ($credential) {
        $credentialData = ConvertTo-BootstrapHashtable -InputObject $credential
        $ui.ApiDisplayNameTextBox.Text = [string]$credentialData['displayName']
        $ui.ApiBaseUrlTextBox.Text = [string]$credentialData['baseUrl']
        $ui.ApiOrganizationTextBox.Text = [string]$credentialData['organizationId']
        $ui.ApiProjectRefTextBox.Text = [string]$credentialData['projectRef']
    }
}

function Refresh-ApiProviderCombos {
    $selectedProvider = Get-SelectedApiProviderId
    $selectedCredential = Get-SelectedApiCredentialId

    $ui.SuppressApiEvents = $true
    try {
        $ui.ApiProviderCombo.Items.Clear()
        foreach ($provider in @($ui.ApiInventory.providers | Sort-Object displayName)) {
            [void]$ui.ApiProviderCombo.Items.Add([string]$provider.id)
        }
        if (-not [string]::IsNullOrWhiteSpace($selectedProvider) -and @($ui.ApiProviderCombo.Items) -contains $selectedProvider) {
            $ui.ApiProviderCombo.SelectedItem = $selectedProvider
        } elseif ($ui.ApiProviderCombo.Items.Count -gt 0) {
            $ui.ApiProviderCombo.SelectedIndex = 0
        }

        $providerId = Get-SelectedApiProviderId
        $provider = Get-ApiProviderInventory -ProviderId $providerId
        $ui.ApiCredentialCombo.Items.Clear()
        [void]$ui.ApiCredentialCombo.Items.Add('<new>')
        if ($provider) {
            foreach ($credential in @($provider.credentials)) {
                [void]$ui.ApiCredentialCombo.Items.Add([string]$credential.id)
            }
            if (-not [string]::IsNullOrWhiteSpace($selectedCredential) -and @($ui.ApiCredentialCombo.Items) -contains $selectedCredential) {
                $ui.ApiCredentialCombo.SelectedItem = $selectedCredential
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$provider.activeCredentialId) -and @($ui.ApiCredentialCombo.Items) -contains [string]$provider.activeCredentialId) {
                $ui.ApiCredentialCombo.SelectedItem = [string]$provider.activeCredentialId
            } else {
                $ui.ApiCredentialCombo.SelectedIndex = 0
            }
        } else {
            $ui.ApiCredentialCombo.SelectedIndex = 0
        }
    } finally {
        $ui.SuppressApiEvents = $false
    }
    Refresh-ApiCredentialEditor
}

function Refresh-ApiCenterControls {
    try {
        $bundle = Get-BootstrapSecretsData
        $ui['ApiInventory'] = Get-BootstrapApiInventory -SecretsData $bundle.Data

        $providerRows = @()
        $credentialRows = @()
        foreach ($provider in @($ui.ApiInventory.providers)) {
            $providerRows += @([ordered]@{
                provider = [string]$provider.displayName
                total = [string]$provider.totalCredentials
                active = [string]$provider.activeCredentialId
                state = [string]$provider.activeValidationState
                autoApps = (@($provider.autoAppliedApps) -join ', ')
                manualApps = (@($provider.manualOnlyApps) -join ', ')
            })
            foreach ($credential in @($provider.credentials)) {
                $credentialRows += @([ordered]@{
                    provider = [string]$provider.id
                    id = [string]$credential.id
                    display = [string]$credential.displayName
                    active = [string]$credential.active
                    state = [string]$credential.validationState
                    preview = [string]$credential.secretPreview
                })
            }
        }

        $appCatalog = Get-BootstrapAppCapabilityCatalog
        $usageRows = @()
        foreach ($appId in @($appCatalog.Keys | Sort-Object)) {
            $app = ConvertTo-BootstrapHashtable -InputObject $appCatalog[$appId]
            $appName = [string]$app['displayName']
            if ([string]::IsNullOrWhiteSpace($appName)) { continue }

            $autoProviders = @()
            $manualProviders = @()
            $availableProviders = @()
            foreach ($provider in @($ui.ApiInventory.providers)) {
                $providerName = [string]$provider.displayName
                if ([string]::IsNullOrWhiteSpace($providerName)) { $providerName = [string]$provider.id }
                if (@($provider.autoAppliedApps) -contains $appName) {
                    $autoProviders += @($providerName)
                }
                if ((@($provider.manualOnlyApps) -contains $appName) -and ([string]$provider.activeValidationState -eq 'passed')) {
                    $manualProviders += @($providerName)
                }
                if (@($provider.availableApps) -contains $appName) {
                    $availableProviders += @($providerName)
                }
            }

            $usageRows += @([ordered]@{
                app = $appName
                autoApplied = (@($autoProviders | Sort-Object -Unique) -join ', ')
                manualOnly = (@($manualProviders | Sort-Object -Unique) -join ', ')
                available = (@($availableProviders | Sort-Object -Unique) -join ', ')
            })
        }

        $createRows = @()
        foreach ($provider in @($ui.ApiInventory.availableToCreate)) {
            $createRows += @([ordered]@{
                provider = [string]$provider.displayName
                fields = (@($provider.requiredFields) -join ', ')
                signup = [string]$provider.signupUrl
                docs = [string]$provider.docsUrl
            })
        }

        Load-WpfGridRows -Grid $ui.ApiProviderSummaryGrid -Items $providerRows -Columns @('provider','total','active','state','autoApps','manualApps')
        Load-WpfGridRows -Grid $ui.ApiCredentialGrid -Items $credentialRows -Columns @('provider','id','display','active','state','preview')
        Load-WpfGridRows -Grid $ui.ApiUsageGrid -Items $usageRows -Columns @('app','autoApplied','manualOnly','available')
        Load-WpfGridRows -Grid $ui.ApiCreateGrid -Items $createRows -Columns @('provider','fields','signup','docs')
        Refresh-ApiProviderCombos

        $summary = $ui.ApiInventory.summary
        $secretsPath = Get-BootstrapSecretsPath
        if ([int]$summary.totalCredentials -eq 0) {
            Set-ApiCenterStatusMessage -Channel 'Inventario' -Message "Nenhuma chave cadastrada ainda. Use Importar arquivo bruto ou Salvar chave. Arquivo: $secretsPath" -Diagnostics $summary
        } else {
            Set-ApiCenterStatusMessage -Channel 'Inventario' -Message "Provedores com chaves: $($summary.configuredProviders)/$($summary.providers) | Chaves cadastradas: $($summary.totalCredentials) | Em uso e validadas: $($summary.validatedActiveProviders) | Arquivo: $secretsPath" -Diagnostics $summary
        }
        $ui.ApiStatusLinksLabel.Visibility = 'Collapsed'
        $ui.ApiSignupLink.IsEnabled = $false
        $ui.ApiDocsLink.IsEnabled = $false
        $ui.ApiPricingLink.IsEnabled = $false
        $ui.ApiSignupLink.NavigateUri = $null
        $ui.ApiDocsLink.NavigateUri = $null
        $ui.ApiPricingLink.NavigateUri = $null
        $ui.ApiSecretsLinksLabel.Visibility = 'Collapsed'
        $ui.ApiSecretsFileLink.IsEnabled = $false
        $ui.ApiSecretsFolderLink.IsEnabled = $false
        $ui.ApiSecretsFileLink.NavigateUri = $null
        $ui.ApiSecretsFolderLink.NavigateUri = $null
        $anySecretsLink = $false
        if (-not [string]::IsNullOrWhiteSpace($secretsPath) -and (Test-Path $secretsPath)) {
            try {
                $ui.ApiSecretsFileLink.NavigateUri = [Uri]("file:///" + ($secretsPath -replace '\\','/'))
                $ui.ApiSecretsFileLink.IsEnabled = $true
                $anySecretsLink = $true
            } catch { }
        }
        $secretsDir = if (-not [string]::IsNullOrWhiteSpace($secretsPath)) { Split-Path -Path $secretsPath -Parent } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($secretsDir) -and (Test-Path $secretsDir)) {
            try {
                $ui.ApiSecretsFolderLink.NavigateUri = [Uri]("file:///" + ($secretsDir -replace '\\','/'))
                $ui.ApiSecretsFolderLink.IsEnabled = $true
                $anySecretsLink = $true
            } catch { }
        }
        if ($anySecretsLink) { $ui.ApiSecretsLinksLabel.Visibility = 'Visible' }
    } catch {
        Set-ApiCenterStatusMessage -Channel 'Inventario' -Message $_.Exception.Message -IsError
    }
}

function Refresh-ApiCatalogControls {
    try {
        $bundle = Get-BootstrapSecretsData
        $rows = @(Get-BootstrapApiCatalogRows -SecretsData $bundle.Data)
        Load-WpfGridRows -Grid $ui.ApiFullCatalogGrid -Items $rows -Columns @('hasCredential','quantity','configured','provider','description','fields','signup','docs')
        $owned = @($rows | Where-Object { [string]$_['hasCredential'] -eq '[x]' }).Count
        $configured = 0
        foreach ($row in @($rows)) {
            $configured += [int]$row['configured']
        }
        $ui.ApiCatalogStatusLabel.Text = "Catalogo: $(@($rows).Count) provedores | Ja possui: $owned | Configuradas: $configured"
    } catch {
        $ui.ApiCatalogStatusLabel.Text = "Catalogo erro: $($_.Exception.Message)"
    }
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

function Refresh-PendingExternalClassification {
    try {
        $pending = Get-BootstrapSteamDeckPendingExternalDisplay
        if (-not $pending.Pending -or -not $pending.Display) {
            $ui.PendingExternalStatusLabel.Text = 'Nenhum monitor externo desconhecido pendente. Monitores conhecidos seguem suas familias/perfis.'
            $ui.ClassifyMonitorButton.IsEnabled = $false
            $ui.ClassifyTvButton.IsEnabled = $false
            return
        }

        $display = ConvertTo-BootstrapHashtable -InputObject $pending.Display
        $ui.PendingExternalStatusLabel.Text = "Pendente: $($display.manufacturer) / $($display.product) / serial $($display.serial). Escolha Monitor/Dev para bancada ou TV/Game para console."
        $ui.ClassifyMonitorButton.IsEnabled = $true
        $ui.ClassifyTvButton.IsEnabled = $true
    } catch {
        $ui.PendingExternalStatusLabel.Text = "Falha ao ler deteccao atual: $($_.Exception.Message)"
        $ui.ClassifyMonitorButton.IsEnabled = $false
        $ui.ClassifyTvButton.IsEnabled = $false
    }
}

function Refresh-SteamDeckControls {
    $ui.SettingsBundle = Get-BootstrapSteamDeckSettingsData -RequestedSteamDeckVersion ([string]$ui.State.steamDeckVersion) -ResolvedSteamDeckVersion 'lcd'
    $settings = ConvertTo-BootstrapHashtable -InputObject $ui.SettingsBundle.Data
    $detection = Get-UiSteamDeckLiveDetectionData -Settings $settings
    Load-WpfGridRows -Grid $ui.MonitorProfilesGrid -Items @(Get-UiSteamDeckProfileRows -Settings $settings -Detection $detection) -Columns @('primary','target','status','manufacturer','product','serial','mode','layout','resolutionPolicy')
    Load-WpfGridRows -Grid $ui.MonitorFamiliesGrid -Items @(Get-UiSteamDeckFamilyRows -Settings $settings -Detection $detection)  -Columns @('primary','status','manufacturer','product','namePattern','mode','layout','resolutionPolicy')
    $ui.GenericModeCombo.SelectedItem      = [string]$settings.genericExternal.mode
    $ui.GenericLayoutTextBox.Text          = [string]$settings.genericExternal.layout
    $ui.GenericResolutionTextBox.Text      = [string]$settings.genericExternal.resolutionPolicy
    $ui.DisplayModeCombo.SelectedItem      = if (Test-BootstrapMapContainsKey -Map $settings -Key 'displayMode') { [string]$settings.displayMode } else { 'extend' }
    $ui.HandheldSessionTextBox.Text        = [string]$settings.sessionProfiles.HANDHELD
    $ui.DockTvSessionTextBox.Text          = [string]$settings.sessionProfiles.DOCKED_TV
    $ui.DockMonitorSessionTextBox.Text     = [string]$settings.sessionProfiles.DOCKED_MONITOR
    Refresh-SteamDeckStatus
    Refresh-PendingExternalClassification
}

function Capture-SteamDeckSettingsFromControls {
    $settings = ConvertTo-BootstrapHashtable -InputObject $ui.SettingsBundle.Data
    $profileRows = @(Read-WpfGridRows -Grid $ui.MonitorProfilesGrid -Columns @('primary','target','status','manufacturer','product','serial','mode','layout','resolutionPolicy'))
    $internalRows = @($profileRows | Where-Object { ([string]$_['target']).Trim().ToLowerInvariant() -eq 'internal' })
    $externalProfileRows = @($profileRows | Where-Object { ([string]$_['target']).Trim().ToLowerInvariant() -ne 'internal' })
    $monitorProfiles = @(Remove-UiGridRuntimeColumns -Rows $externalProfileRows)
    $monitorFamilies = @(Remove-UiGridRuntimeColumns -Rows @(Read-WpfGridRows -Grid $ui.MonitorFamiliesGrid  -Columns @('primary','status','manufacturer','product','namePattern','mode','layout','resolutionPolicy')) -RuntimeColumns @('status'))
    Validate-SteamDeckGridModeRows -Rows $monitorProfiles -GridName 'MonitorProfiles'
    Validate-SteamDeckGridModeRows -Rows $monitorFamilies -GridName 'MonitorFamilies'

    $internalRow = if ($internalRows.Count -gt 0) { $internalRows[0] } else { $null }
    if ($internalRow) {
        $settings['internalDisplay'] = @{
            manufacturer = ([string]$internalRow['manufacturer']).Trim()
            product = ([string]$internalRow['product']).Trim()
            serial = ([string]$internalRow['serial']).Trim()
            primary = ConvertTo-UiBoolean -Value $internalRow['primary']
            layout = ([string]$internalRow['layout']).Trim()
            resolutionPolicy = ([string]$internalRow['resolutionPolicy']).Trim()
        }
    }

    $settings['monitorProfiles']  = @($monitorProfiles)
    $settings['monitorFamilies']  = @($monitorFamilies)
    $displayMode = if ($ui.DisplayModeCombo.SelectedItem) { [string]$ui.DisplayModeCombo.SelectedItem } else { 'extend' }
    if ((ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $settings['internalDisplay'] -Name 'primary' -Default $false)) -and $displayMode -eq 'external') {
        $displayMode = 'extend'
        $ui.DisplayModeCombo.SelectedItem = 'extend'
    }
    $settings['displayMode'] = $displayMode
    $settings['genericExternal']  = @{
        mode             = if ($ui.GenericModeCombo.SelectedItem) { [string]$ui.GenericModeCombo.SelectedItem } else { 'UNCLASSIFIED_EXTERNAL' }
        layout           = $ui.GenericLayoutTextBox.Text.Trim()
        resolutionPolicy = $ui.GenericResolutionTextBox.Text.Trim()
        primary          = ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $settings['genericExternal'] -Name 'primary' -Default $true)
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
    try {
        Capture-SteamDeckSettingsFromControls
        $saveResult = Save-BootstrapSteamDeckSettingsData -Settings $ui.SettingsBundle.Data -CreateBackup
        $ui.SettingsBackupPath         = $saveResult.BackupPath
        $ui.State.lastSettingsPath     = $saveResult.Path
        Save-UiState -State $ui.State -Path $UiStatePath
        $ui.StatusLabel.Text           = $ui.Strings.SavingSettings
        Refresh-SteamDeckStatus
        return $true
    } catch {
        $ui.StatusLabel.Text = "Settings invalidos: $($_.Exception.Message)"
        return $false
    }
}

function Classify-PendingExternalDisplay {
    param([ValidateSet('MonitorDev', 'TvGame')][string]$Choice)

    try {
        Capture-SteamDeckSettingsFromControls
        $null = Save-BootstrapSteamDeckSettingsData -Settings $ui.SettingsBundle.Data -CreateBackup
        $result = Add-BootstrapSteamDeckDisplayClassification -Choice $Choice -CreateBackup
        $ui.StatusLabel.Text = "Display classificado: $($result.Manufacturer) / $($result.Product) => $($result.Mode)"
        Refresh-SteamDeckControls
    } catch {
        $ui.StatusLabel.Text = "Falha ao classificar display: $($_.Exception.Message)"
    }
}

function Refresh-DualBootControls {
    $ui.DualBootStatusText.Text = 'Lendo UEFI firmware e gerenciador de disco...'
    $info = Get-BootstrapDualBootInfo
    $recs = Get-BootstrapDualBootRecommendations -DualBootInfo $info
    
    $statusLines = @()
    $statusLines += "Is Dual Boot: $($info.IsDualBoot) (Confidence: $($info.Confidence))"
    $statusLines += "Sistemas Detectados: $(($info.DetectedOS) -join ', ')"
    $statusLines += "GRUB Detectado: $($info.GrubDetected) ($($info.GrubEfiPath))"
    $statusLines += "Parties Linux: $($info.LinuxPartitions.Count)"
    $statusLines += ""
    $statusLines += ($recs -join [Environment]::NewLine)
    
    if (-not $info.IsAdmin) {
        $statusLines += ""
        $statusLines += "AVISO: executando sem privilegios de Administrador. Recursos avancados estao desabilitados."
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
        $ui.DualBootPrereqsText.Text = "Nenhum problema detectado. Todas as configuracoes do Windows estao seguras para o Linux."
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

    try {
        $bootState = Get-BootstrapWindowsBootManagerState
        Load-WpfGridRows -Grid $ui.WindowsBootEntriesGrid -Items @($bootState.Entries) -Columns @('isDefault','isCurrent','inDisplayOrder','id','description','device','osdevice','isPhantom')
        $ui.WindowsBootDefaultCombo.Items.Clear()
        foreach ($entry in @($bootState.Entries)) {
            $entryId = [string]$entry['id']
            if ([string]::IsNullOrWhiteSpace($entryId)) { continue }
            $label = "{0} - {1}" -f $entryId, [string]$entry['description']
            $cbi = New-Object System.Windows.Controls.ComboBoxItem
            $cbi.Content = $label
            $cbi.Tag = $entryId
            [void]$ui.WindowsBootDefaultCombo.Items.Add($cbi)
            if ($entryId -eq [string]$bootState.ResolvedDefault -or $entryId -eq [string]$bootState.Default) {
                $ui.WindowsBootDefaultCombo.SelectedItem = $cbi
            }
        }
        $ui.WindowsBootTimeoutTextBox.Text = if ($null -ne $bootState.Timeout) { [string]$bootState.Timeout } else { '' }
        $ui.WindowsBootStatusText.Text = "Default: $($bootState.Default) -> $($bootState.ResolvedDefault) | Atual: $($bootState.ResolvedCurrent) | Timeout: $($bootState.Timeout) | Entradas: $(@($bootState.Entries).Count) | Orfas: $(@($bootState.PhantomEntries).Count)"
        $ui.WindowsBootDefaultCombo.IsEnabled = [bool]$bootState.IsAdmin
        $ui.WindowsBootTimeoutTextBox.IsEnabled = [bool]$bootState.IsAdmin
        $ui.ApplyWindowsBootButton.IsEnabled = [bool]$bootState.IsAdmin
        $ui.BackupWindowsBootButton.IsEnabled = [bool]$bootState.IsAdmin
        if (-not [bool]$bootState.IsAdmin) {
            $ui.WindowsBootStatusText.Text += " | Execute como Administrador para alterar default/timeout ou gerar backup."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$bootState.CommandError)) {
            $ui.WindowsBootStatusText.Text += " | bcdedit: $($bootState.CommandError)"
        }
    } catch {
        $ui.WindowsBootStatusText.Text = "Falha ao auditar Windows Boot Manager: $($_.Exception.Message)"
        Load-WpfGridRows -Grid $ui.WindowsBootEntriesGrid -Items @() -Columns @('isDefault','isCurrent','inDisplayOrder','id','description','device','osdevice','isPhantom')
        $ui.WindowsBootDefaultCombo.Items.Clear()
        $ui.WindowsBootDefaultCombo.IsEnabled = $false
        $ui.WindowsBootTimeoutTextBox.IsEnabled = $false
        $ui.ApplyWindowsBootButton.IsEnabled = $false
        $ui.BackupWindowsBootButton.IsEnabled = $false
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
            $ui.BcdCleanupStatusText.Text = "Menu de Boot limpo! Nenhuma instação órfã do Windows detectada."
        }
    } else {
        $ui.BcdCleanupStatusText.Text = "Requer privilégios de Administrador para auditar o Boot Configuration Data."
    }
}

function Refresh-ReviewPage {
    Capture-SteamDeckSettingsFromControls
    Capture-AppTuningStateFromControls
    $ui.Preview = Get-BootstrapPreviewData -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents $ui.State.excludedComponents -RequestedSteamDeckVersion $ui.State.steamDeckVersion -RequestedHostHealthMode $ui.State.hostHealth -RequestedAppTuningMode $ui.State.appTuningMode -RequestedAppTuningCategories $ui.State.selectedAppTuningCategories -RequestedAppTuningItems $ui.State.selectedAppTuningItems -ExcludedAppTuningItems $ui.State.excludedAppTuningItems -RequestedWorkspaceRoot $ui.State.workspaceRoot -ExplicitCloneBaseDir $ui.State.cloneBaseDir
    $ui.ReviewTextBox.Text  = $ui.Preview.PlanText
    $resolved = @()
    try {
        $sel = New-BootstrapSelectionObject -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents $ui.State.excludedComponents -SelectedHostHealth $ui.State.hostHealth
        $res = Resolve-BootstrapComponents -SelectedProfiles $sel.Profiles -SelectedComponents $sel.Components -ExcludedComponents $sel.Excludes
        $resolved = @($res.ResolvedComponents)
    } catch { $resolved = @() }
    $effects = @()
    if ($resolved -contains 'bootstrap-secrets') { $effects += 'bootstrap-secrets: escreve manifests/settings (backup .bak) em pastas de usuario.' }
    if ($resolved -contains 'bootstrap-mcps') { $effects += 'bootstrap-mcps: escreve mcp.json / configs em apps (VS Code, Cursor, Windsurf, Trae, OpenCode, etc).' }
    if ($resolved -contains 'vscode-extensions') { $effects += 'vscode-extensions: instala extensoes + altera settings.json / configs de extensoes.' }
    if ($resolved -contains 'claude-config') { $effects += 'claude-config: atualiza ~/.claude/settings.json (backup).' }
    if ($resolved -contains 'claude-plugins') { $effects += 'claude-plugins: instala plugins via claude (rede).' }
    if ($resolved -contains 'hermes') { $effects += 'hermes: instala via npm + cria/atualiza .hermes/opencloud.json no projeto.' }
    if ([bool]$ui.State.enableClaudeCodeProjectMcps) { $effects += 'claude-code MCPs: adiciona MCPs no projeto via "claude mcp add".' }
    $ui.ReviewSideEffectsTextBox.Text = if ($effects.Count -gt 0) { $effects -join [Environment]::NewLine } else { '-' }
    $adminText = if (@($ui.Preview.AdminReasons).Count -gt 0) { @($ui.Preview.AdminReasons) -join '; ' } else { '-' }
    $ui.ReviewMetaLabel.Text = "Admin: $adminText  |  Settings: $($ui.SettingsBundle.Path)  |  UI state: $UiStatePath"
    $ui.ReviewLinksLabel.Visibility = 'Collapsed'
    $ui.ReviewSettingsLink.IsEnabled = $false
    $ui.ReviewUiStateLink.IsEnabled = $false
    $ui.ReviewSettingsLink.NavigateUri = $null
    $ui.ReviewUiStateLink.NavigateUri = $null
    $anyLink = $false
    $settingsPath = [string]$ui.SettingsBundle.Path
    if (-not [string]::IsNullOrWhiteSpace($settingsPath) -and (Test-Path $settingsPath)) {
        try {
            $ui.ReviewSettingsLink.NavigateUri = [Uri]("file:///" + ($settingsPath -replace '\\','/'))
            $ui.ReviewSettingsLink.IsEnabled = $true
            $anyLink = $true
        } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($UiStatePath) -and (Test-Path $UiStatePath)) {
        try {
            $ui.ReviewUiStateLink.NavigateUri = [Uri]("file:///" + ($UiStatePath -replace '\\','/'))
            $ui.ReviewUiStateLink.IsEnabled = $true
            $anyLink = $true
        } catch { }
    }
    if ($anyLink) { $ui.ReviewLinksLabel.Visibility = 'Visible' }
}

# 
# Navigation
# 

$navButtons = @(
    $ui.NavWelcome,
    $ui.NavSelection,
    $ui.NavHostSetup,
    $ui.NavAppTuning,
    $ui.NavApiCenter,
    $ui.NavSteamDeck,
    $ui.NavDualBoot,
    $ui.NavReview,
    $ui.NavRun
)
$navButtonTargets = @('welcome', 'selection', 'host-setup', 'app-tuning', 'api-center', 'steamdeck-control', 'dual-boot', 'review', 'run')

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
    $activePageId = [string]$pageIds[$Index]
    for ($i = 0; $i -lt $navButtons.Count; $i++) {
        $navButtons[$i].IsChecked = ([string]$navButtonTargets[$i] -eq $activePageId)
    }

    # Back/Next state
    $ui.BackButton.IsEnabled = ($Index -gt 0)
    $ui.NextButton.IsEnabled = ($Index -lt ($pageIds.Count - 1))

    $stepName = switch ($pageIds[$Index]) {
        'welcome'          { $ui.Strings.Welcome }
        'selection'        { $ui.Strings.Selection }
        'host-setup'       { $ui.Strings.HostSetup }
        'app-tuning'       { $ui.Strings.AppTuning }
        'api-center'       { $ui.Strings.ApiCenter }
        'api-catalog'      { $ui.Strings.ApiCatalogTitle }
        'steamdeck-control' { $ui.Strings.SteamDeckControl }
        'dual-boot'        { $ui.Strings.DualBoot }
        'review'           { $ui.Strings.Review }
        default            { $ui.Strings.Run }
    }
    $ui.StepLabel.Text = "{0} / {1}  -  {2}" -f ($Index + 1), $pageIds.Count, $stepName

    switch ($pageIds[$Index]) {
        'selection'         { Refresh-SelectionTrees; Refresh-SelectionSummary }
        'host-setup'        { Refresh-SelectionSummary; Refresh-HostSetupControls }
        'app-tuning'        { Refresh-AppTuningControls }
        'api-center'        { Refresh-ApiCenterControls }
        'api-catalog'       { Refresh-ApiCatalogControls }
        'steamdeck-control' { Refresh-SteamDeckControls }
        'dual-boot'         { Refresh-DualBootControls }
        'review'            { Refresh-ReviewPage; Refresh-HostSetupControls }
    }
}

# 
# Process helpers
# 

function Build-BackendArguments {
    $tokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backendScriptPath)
    foreach ($p in @($ui.State.selectedProfiles))   { $tokens += @('-Profile',   [string]$p) }
    foreach ($c in @($ui.State.selectedComponents)) { $tokens += @('-Component', [string]$c) }
    foreach ($e in @($ui.State.excludedComponents)) { $tokens += @('-Exclude',   [string]$e) }
    if ([bool]$ui.State.enableClaudeCodeProjectMcps) { $tokens += @('-ClaudeCodeProjectMcps') }
    if ([bool]$ui.State.skipManualRequirements) { $tokens += @('-SkipManualRequirements') }
    if ([bool]$ui.State.ignoreManualRequirements) { $tokens += @('-IgnoreManualRequirements') }
    $tokens += @('-SteamDeckVersion', [string]$ui.State.steamDeckVersion)
    $tokens += @('-HostHealth',       [string]$ui.State.hostHealth)
    $tokens += @('-AppTuning',        [string]$ui.State.appTuningMode)
    foreach ($category in @($ui.State.selectedAppTuningCategories)) { $tokens += @('-AppTuningCategory', [string]$category) }
    foreach ($item in @($ui.State.selectedAppTuningItems)) { $tokens += @('-AppTuningItem', [string]$item) }
    foreach ($item in @($ui.State.excludedAppTuningItems)) { $tokens += @('-ExcludeAppTuningItem', [string]$item) }
    $tokens += @('-WorkspaceRoot',    [string]$ui.State.workspaceRoot)
    $tokens += @('-CloneBaseDir',     [string]$ui.State.cloneBaseDir)
    $tokens += @('-LogPath',          [string]$ui.CurrentLogPath)
    $tokens += @('-ResultPath',       [string]$ui.CurrentResultPath)
    return $tokens
}

function Start-BackendWorker {
    $powershellExe   = Get-WindowsPowerShellExePath
    $argumentString  = ConvertTo-ArgumentString -Tokens (Build-BackendArguments)
    $needsAdmin = ($ui.Preview -and @($ui.Preview.AdminReasons).Count -gt 0 -and -not (Test-IsAdmin))
    Write-UiLog -Message ("Start-BackendWorker. NeedsAdmin={0}  Exe={1}  Args={2}" -f $needsAdmin, $powershellExe, $argumentString)
    if ($needsAdmin) { return (Start-Process -FilePath $powershellExe -ArgumentList $argumentString -Verb RunAs -WindowStyle Hidden -PassThru) }
    return (Start-Process -FilePath $powershellExe -ArgumentList $argumentString -WindowStyle Hidden -PassThru)
}

function Append-RunLog {
    if ([string]::IsNullOrWhiteSpace($ui.CurrentLogPath) -or -not (Test-Path $ui.CurrentLogPath)) { return }
    $content = [IO.File]::ReadAllText($ui.CurrentLogPath)
    if ($content.Length -le $ui.LogOffset) { return }
    $newText = $content.Substring($ui.LogOffset)
    $ui.RunLogTextBox.AppendText($newText)
    $ui.RunLogTextBox.ScrollToEnd()
    $ui.LogOffset = $content.Length
}

function Set-RunUiBusy {
    param([bool]$Busy)
    if ($Busy) {
        $ui.StartRunButton.IsEnabled = $false
    } else {
        $ui.StartRunButton.IsEnabled = $true
    }
}

function Complete-RunExecution {
    param([Parameter(Mandatory=$true)][string]$StatusText)
    $ui.RunStatusLabel.Text = $StatusText
    $ui.State.lastLogPath    = $ui.CurrentLogPath
    $ui.State.lastResultPath = $ui.CurrentResultPath
    Save-UiState -State $ui.State -Path $UiStatePath
    $ui.RunProcess = $null
    $ui.LogTimer.Stop()
    Set-RunUiBusy -Busy $false
}

function Complete-RunExecutionWithoutResult {
    Append-RunLog
    $exitCode = 'unknown'
    if ($ui.RunProcess) {
        try { $exitCode = [string]$ui.RunProcess.ExitCode } catch { $exitCode = 'unknown' }
    }
    $message = "{0}  Backend saiu sem result.json. ExitCode={1}. Verifique o log para detalhes." -f $ui.Strings.RunFailed, $exitCode
    try {
        if (-not [string]::IsNullOrWhiteSpace($ui.CurrentResultPath)) {
            $resultParent = Split-Path -Path $ui.CurrentResultPath -Parent
            if ($resultParent) { $null = New-Item -Path $resultParent -ItemType Directory -Force }
            $fallbackResult = [ordered]@{
                status = 'error'
                generatedAt = (Get-Date).ToString('o')
                logPath = $ui.CurrentLogPath
                resultPath = $ui.CurrentResultPath
                exitCode = $exitCode
                error = $message
            }
            $fallbackJson = $fallbackResult | ConvertTo-Json -Depth 8
            [System.IO.File]::WriteAllText($ui.CurrentResultPath, $fallbackJson, [System.Text.UTF8Encoding]::new($false))
        }
    } catch {
        Write-UiLog -Level 'WARN' -Message ("Falha ao escrever fallback result.json: {0}" -f $_.Exception.Message)
    }
    Write-UiLog -Level 'ERROR' -Message $message
    Complete-RunExecution -StatusText $message
}

function Finalize-RunFromResult {
    Append-RunLog
    if (-not (Test-Path $ui.CurrentResultPath)) {
        Complete-RunExecutionWithoutResult
        return
    }
    try {
        $result = Get-Content -Path $ui.CurrentResultPath -Raw | ConvertFrom-Json
    } catch {
        Complete-RunExecution -StatusText ("{0}  result.json invalido: {1}" -f $ui.Strings.RunFailed, $_.Exception.Message)
        return
    }
    if ($result.status -eq 'success') {
        $statusText = $ui.Strings.RunCompleted
        if ($result.hostHealthReportRoot) { $ui.State.lastReportPath = [string]$result.hostHealthReportRoot }
        if ($result.appTuningReportRoot) { $ui.State.lastReportPath = [string]$result.appTuningReportRoot }
    } else {
        $statusText = "{0}  {1}" -f $ui.Strings.RunFailed, [string]$result.error
    }
    Complete-RunExecution -StatusText $statusText
}

function Start-RunExecution {
    if ($ui.RunProcess -and -not $ui.RunProcess.HasExited) {
        $ui.RunStatusLabel.Text = "$($ui.Strings.RunStarted) Aguarde a execucao atual finalizar."
        return
    }
    if (-not (Save-SteamDeckSettingsInteractive)) { return }
    Refresh-ReviewPage
    $runRoot             = Join-Path (Get-BootstrapDataRoot) 'ui-runs'
    $timestamp           = Get-Date -Format 'yyyyMMdd_HHmmss'
    $ui.CurrentLogPath   = Join-Path $runRoot ("bootstrap-ui_{0}.log" -f $timestamp)
    $ui.CurrentResultPath = Join-Path $runRoot ("bootstrap-ui_{0}.result.json" -f $timestamp)
    $ui.LogOffset        = 0
    $ui.RunLogTextBox.Clear()
    $ui.RunStatusLabel.Text = $ui.Strings.RunStarted
    Set-RunUiBusy -Busy $true
    try { $ui.RunProcess = Start-BackendWorker } catch {
        $ui.RunStatusLabel.Text = $ui.Strings.UserCanceledElevation
        Set-RunUiBusy -Busy $false
        return
    }
    Save-UiState -State $ui.State -Path $UiStatePath
    $ui.LogTimer.Start()
}

# 
# Event Handlers
# 

# Log timer
$logTimer.Add_Tick({
    Append-RunLog
    if ($ui.RunProcess -and $ui.RunProcess.HasExited) {
        if (Test-Path $ui.CurrentResultPath) {
            Finalize-RunFromResult
        } else {
            Complete-RunExecutionWithoutResult
        }
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

# API Center
$ui.ApiProviderCombo.Add_SelectionChanged({
    if ($ui.SuppressApiEvents) { return }
    if ($ui.ApiProviderCombo.SelectedItem) {
        Refresh-ApiProviderCombos
    }
})

$ui.ApiCredentialCombo.Add_SelectionChanged({
    if ($ui.SuppressApiEvents) { return }
    Refresh-ApiCredentialEditor
})

$ui.ApiCredentialGrid.Add_SelectionChanged({
    if ($ui.SuppressApiEvents) { return }
    if ($ui.ApiCredentialGrid.SelectedItem -and $ui.ApiCredentialGrid.SelectedItem.Row) {
        $row = $ui.ApiCredentialGrid.SelectedItem.Row
        $providerId = [string]$row['provider']
        $credentialId = [string]$row['id']
        if (-not [string]::IsNullOrWhiteSpace($providerId)) {
            $ui.ApiProviderCombo.SelectedItem = $providerId
        }
        if (-not [string]::IsNullOrWhiteSpace($credentialId)) {
            $ui.ApiCredentialCombo.SelectedItem = $credentialId
        }
        Refresh-ApiCredentialEditor
    }
})

$ui.ApiRefreshButton.Add_Click({
    Refresh-ApiCenterControls
})

$ui.ApiCatalogButton.Add_Click({
    $pageIds = @(Get-UiPageIds)
    $index = [Array]::IndexOf($pageIds, 'api-catalog')
    if ($index -ge 0) { Navigate-ToPage -Index $index }
})

$ui.ApiCatalogBackButton.Add_Click({
    $pageIds = @(Get-UiPageIds)
    $index = [Array]::IndexOf($pageIds, 'api-center')
    if ($index -ge 0) { Navigate-ToPage -Index $index }
})

$ui.ApiSaveButton.Add_Click({
    try {
        $providerId = Get-SelectedApiProviderId
        if ([string]::IsNullOrWhiteSpace($providerId)) { return }
        $fields = @{
            baseUrl = $ui.ApiBaseUrlTextBox.Text.Trim()
            organizationId = $ui.ApiOrganizationTextBox.Text.Trim()
            projectRef = $ui.ApiProjectRefTextBox.Text.Trim()
        }
        $result = Set-BootstrapApiCredential -ProviderName $providerId -CredentialId (Get-SelectedApiCredentialId) -DisplayName $ui.ApiDisplayNameTextBox.Text.Trim() -Secret $ui.ApiSecretBox.Password -Fields $fields
        $ui.ApiStatusLabel.Text = "Credencial salva: $($result.credentialId)"
        Refresh-ApiCenterControls
    } catch {
        $ui.ApiStatusLabel.Text = "Falha ao salvar credencial: $($_.Exception.Message)"
    }
})

$ui.ApiValidateButton.Add_Click({
    try {
        $providerId = Get-SelectedApiProviderId
        $credentialId = Get-SelectedApiCredentialId
        if ([string]::IsNullOrWhiteSpace($providerId) -or [string]::IsNullOrWhiteSpace($credentialId)) { return }
        $null = Invoke-BootstrapApiCredentialValidation -ProviderName $providerId -CredentialId $credentialId
        $ui.ApiStatusLabel.Text = "Credencial validada: $credentialId"
        Refresh-ApiCenterControls
    } catch {
        $ui.ApiStatusLabel.Text = "Falha ao validar: $($_.Exception.Message)"
    }
})

$ui.ApiValidateAllButton.Add_Click({
    try {
        $null = Invoke-BootstrapApiCredentialValidation -All
        $ui.ApiStatusLabel.Text = 'Validacao concluida.'
        Refresh-ApiCenterControls
    } catch {
        $ui.ApiStatusLabel.Text = "Falha ao validar tudo: $($_.Exception.Message)"
    }
})

$ui.ApiActivateButton.Add_Click({
    try {
        $providerId = Get-SelectedApiProviderId
        $credentialId = Get-SelectedApiCredentialId
        if ([string]::IsNullOrWhiteSpace($providerId) -or [string]::IsNullOrWhiteSpace($credentialId)) { return }
        $null = Set-BootstrapApiActiveCredential -ProviderName $providerId -CredentialId $credentialId
        $ui.ApiStatusLabel.Text = "Credencial ativa: $credentialId"
        Refresh-ApiCenterControls
    } catch {
        $ui.ApiStatusLabel.Text = "Falha ao ativar: $($_.Exception.Message)"
    }
})

$ui.ApiImportButton.Add_Click({
    try {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Importar arquivo bruto de credenciais'
        $dialog.Filter = 'Markdown/Text (*.md;*.txt)|*.md;*.txt|All files (*.*)|*.*'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $null = Import-BootstrapApiCredentialFile -Path $dialog.FileName
            $ui.ApiStatusLabel.Text = "Importado: $($dialog.FileName)"
            Refresh-ApiCenterControls
        }
    } catch {
        $ui.ApiStatusLabel.Text = "Falha ao importar: $($_.Exception.Message)"
    }
})

$ui.ApiApplyButton.Add_Click({
    try {
        $applyResult = Invoke-BootstrapApiApply
        $applyDiagnostics = if ($applyResult -and $applyResult.PSObject.Properties['diagnostics']) { $applyResult.diagnostics } else { $null }
        Set-ApiCenterStatusMessage -Channel 'Aplicacao APIs' -Message 'APIs aplicadas nos apps suportados.' -Diagnostics $applyDiagnostics
        Refresh-ApiCenterControls
    } catch {
        Set-ApiCenterStatusMessage -Channel 'Aplicacao APIs' -Message $_.Exception.Message -IsError
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
        enableClaudeCodeProjectMcps = [bool]$ui.State.enableClaudeCodeProjectMcps
        hostHealth         = [string]$ui.State.hostHealth
        appTuningMode      = [string]$ui.State.appTuningMode
        selectedAppTuningCategories = @($ui.State.selectedAppTuningCategories)
        selectedAppTuningItems = @($ui.State.selectedAppTuningItems)
        excludedAppTuningItems = @($ui.State.excludedAppTuningItems)
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
    $ui.State.enableClaudeCodeProjectMcps = [bool]$preset.enableClaudeCodeProjectMcps
    $ui.State.hostHealth         = [string]$preset.hostHealth
    $ui.State.appTuningMode      = if ($preset.appTuningMode) { [string]$preset.appTuningMode } else { 'recommended' }
    $ui.State.selectedAppTuningCategories = @(Normalize-BootstrapNames -Names @($preset.selectedAppTuningCategories))
    $ui.State.selectedAppTuningItems = @(Normalize-BootstrapNames -Names @($preset.selectedAppTuningItems))
    $ui.State.excludedAppTuningItems = @(Normalize-BootstrapNames -Names @($preset.excludedAppTuningItems))
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

function Set-UiComponentEnabled {
    param(
        [Parameter(Mandatory=$true)][string]$ComponentName,
        [Parameter(Mandatory=$true)][bool]$Enabled
    )
    $name = @(Normalize-BootstrapNames -Names @($ComponentName))[0]
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $selection = New-BootstrapSelectionObject -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents @() -SelectedHostHealth $ui.State.hostHealth
    $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents @()
    $isResolved = (@($resolution.ResolvedComponents) -contains $name)
    $isExplicit = (@($ui.State.selectedComponents) -contains $name)
    if ($Enabled) {
        if (@($ui.State.excludedComponents) -contains $name) {
            $ui.State.excludedComponents = @(@($ui.State.excludedComponents) | Where-Object { $_ -ne $name })
        }
        if (-not $isResolved -and -not $isExplicit) {
            $ui.State.selectedComponents = @(@($ui.State.selectedComponents) + $name)
        }
    } else {
        if ($isResolved -and -not (@($ui.State.excludedComponents) -contains $name)) {
            $ui.State.excludedComponents = @(@($ui.State.excludedComponents) + $name)
        }
        if ($isExplicit) {
            $ui.State.selectedComponents = @(@($ui.State.selectedComponents) | Where-Object { $_ -ne $name })
        }
    }
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionTrees
    Refresh-SelectionSummary
}

$ui.OptClaudePluginsCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    Set-UiComponentEnabled -ComponentName 'claude-plugins' -Enabled $true
})
$ui.OptClaudePluginsCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    Set-UiComponentEnabled -ComponentName 'claude-plugins' -Enabled $false
})
$ui.OptOpenWebUICheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    Set-UiComponentEnabled -ComponentName 'openwebui' -Enabled $true
})
$ui.OptOpenWebUICheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    Set-UiComponentEnabled -ComponentName 'openwebui' -Enabled $false
})
$ui.OptClaudeProjectMcpsCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.enableClaudeCodeProjectMcps = $true
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})
$ui.OptClaudeProjectMcpsCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.enableClaudeCodeProjectMcps = $false
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

$ui.OptSkipManualRequirementsCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.skipManualRequirements = $true
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})
$ui.OptSkipManualRequirementsCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.skipManualRequirements = $false
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

$ui.OptIgnoreManualRequirementsCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.ignoreManualRequirements = $true
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})
$ui.OptIgnoreManualRequirementsCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.ignoreManualRequirements = $false
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

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

# App Tuning
$ui.AppTuningModeCombo.Add_SelectionChanged({
    if ($ui.AppTuningModeCombo.SelectedItem) {
        $ui.State.appTuningMode = [string]$ui.AppTuningModeCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-AppTuningControls
        Refresh-SelectionSummary
    }
})

$ui.AppTuningRecommendedButton.Add_Click({
    $ui.State.appTuningMode = 'recommended'
    $ui.State.selectedAppTuningCategories = @()
    $ui.State.selectedAppTuningItems = @()
    $ui.State.excludedAppTuningItems = @()
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-AppTuningControls
})

$ui.AppTuningMarkCategoryButton.Add_Click({
    if ($ui.AppTuningCategoryList.SelectedItem -and $ui.AppTuningCategoryList.SelectedItem.Tag) {
        $id = [string]$ui.AppTuningCategoryList.SelectedItem.Tag
        if (-not (@($ui.State.selectedAppTuningCategories) -contains $id)) {
            $ui.State.selectedAppTuningCategories = @(@($ui.State.selectedAppTuningCategories) + $id)
        }
        $ui.State.appTuningMode = 'custom'
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-AppTuningControls
    }
})

$ui.AppTuningClearCategoryButton.Add_Click({
    if ($ui.AppTuningCategoryList.SelectedItem -and $ui.AppTuningCategoryList.SelectedItem.Tag) {
        $id = [string]$ui.AppTuningCategoryList.SelectedItem.Tag
        $ui.State.selectedAppTuningCategories = @(@($ui.State.selectedAppTuningCategories) | Where-Object { $_ -ne $id })
        $ui.State.appTuningMode = 'custom'
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-AppTuningControls
    }
})

$ui.AppTuningAuditButton.Add_Click({
    Capture-AppTuningStateFromControls
    Refresh-AppTuningControls
})

$ui.AppTuningSearchBox.Add_TextChanged({
    Refresh-AppTuningControls
})

$ui.AppTuningStatusFilterCombo.Add_SelectionChanged({
    Refresh-AppTuningControls
})

$ui.AppTuningItemsGrid.Add_LoadingRow({
    param($sender, $args)
    try {
        $row = $args.Row
        if ($null -eq $row -or $null -eq $row.Item) { return }
        $item = $row.Item
        $rowData = $null
        if ($item -and $item.PSObject.Properties['Row']) {
            $rowData = $item.Row
        } elseif ($item -is [System.Collections.IDictionary]) {
            $rowData = $item
        } else {
            return
        }
        $description = [string]$rowData['description']
        $appName = [string]$rowData['app']
        $optimization = [string]$rowData['optimization']
        if ([string]::IsNullOrWhiteSpace($description)) {
            $row.ToolTip = "$appName - $optimization"
        } else {
            $row.ToolTip = "$appName - $optimization`n$description"
        }

        $installedRaw = [string]$rowData['installedStateRaw']
        $configuredRaw = [string]$rowData['configuredStateRaw']
        $updatedRaw = [string]$rowData['updatedStateRaw']

        # Regra de cor por status:
        # 1) update -> laranja
        # 2) instalado + configurado -> verde
        # 3) instalado -> azul
        # 4) demais -> padrão
        if ($updatedRaw -in @('check', 'update-available', 'upgrade-available', 'outdated')) {
            $row.Foreground = Get-UiBrush '#F59E0B'
        } elseif ($installedRaw -eq 'installed' -and $configuredRaw -eq 'configured') {
            $row.Foreground = Get-UiBrush '#22C55E'
        } elseif ($installedRaw -eq 'installed') {
            $row.Foreground = Get-UiBrush '#60A5FA'
        } else {
            $row.Foreground = Get-UiBrush '#CBD5E1'
        }
    } catch {
        if ($args -and $args.Row) {
            $args.Row.ToolTip = $null
            $args.Row.Foreground = Get-UiBrush '#CBD5E1'
        }
    }
})

$ui.AppTuningItemsGrid.Add_MouseDoubleClick({
    try {
        if ($null -eq $ui.AppTuningItemsGrid.CurrentCell -or $null -eq $ui.AppTuningItemsGrid.CurrentCell.Column) { return }
        $header = [string]$ui.AppTuningItemsGrid.CurrentCell.Column.Header
        $row = Get-CurrentAppTuningRow
        if ($null -eq $row) { return }

        switch ($header) {
            'Instalado' { Invoke-AppTuningSingleRowAction -Row $row -Action 'install' }
            'Configurado' { Invoke-AppTuningSingleRowAction -Row $row -Action 'configure' }
            'Atualizado' { Invoke-AppTuningSingleRowAction -Row $row -Action 'update' }
            default { }
        }
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha no clique unitário AppTuning: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = (Get-UiFriendlyActionError -ActionLabel 'a ação unitária da tabela Otimizar Apps' -Exception $_.Exception)
    }
})

$ui.AppTuningInstallButton.Add_Click({
    try {
        Queue-AppTuningInstallOrUpdate -ActionName 'Instalacao'
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao planejar instalação AppTuning: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = (Get-UiFriendlyActionError -ActionLabel 'a instalação dos apps selecionados' -Exception $_.Exception)
    }
})

$ui.AppTuningConfigureButton.Add_Click({
    try {
        Queue-AppTuningConfigure
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao planejar configuração AppTuning: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = (Get-UiFriendlyActionError -ActionLabel 'a configuração/otimização dos apps selecionados' -Exception $_.Exception)
    }
})

$ui.AppTuningUpdateButton.Add_Click({
    try {
        Queue-AppTuningInstallOrUpdate -ActionName 'Atualizacao'
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao planejar atualização AppTuning: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = (Get-UiFriendlyActionError -ActionLabel 'a atualização dos apps selecionados' -Exception $_.Exception)
    }
})

# Steam Deck control
$ui.ReloadSettingsButton.Add_Click({ Refresh-SteamDeckControls; $ui.StatusLabel.Text = $ui.Strings.ReloadSettings })
$ui.SaveSettingsButton.Add_Click({ [void](Save-SteamDeckSettingsInteractive) })
$ui.ClassifyMonitorButton.Add_Click({ Classify-PendingExternalDisplay -Choice 'MonitorDev' })
$ui.ClassifyTvButton.Add_Click({ Classify-PendingExternalDisplay -Choice 'TvGame' })

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

$ui.BackupWindowsBootButton.Add_Click({
    try {
        $path = Backup-BootstrapWindowsBootManager
        $ui.StatusLabel.Text = "Backup BCD criado: $path"
        Refresh-DualBootControls
    } catch {
        $ui.StatusLabel.Text = "Erro no backup BCD: $_"
    }
})

$ui.ApplyWindowsBootButton.Add_Click({
    try {
        $defaultId = ''
        if ($ui.WindowsBootDefaultCombo.SelectedItem) {
            $defaultId = [string]$ui.WindowsBootDefaultCombo.SelectedItem.Tag
        }
        $timeout = $null
        $timeoutText = $ui.WindowsBootTimeoutTextBox.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($timeoutText)) {
            $parsedTimeout = 0
            if (-not [int]::TryParse($timeoutText, [ref]$parsedTimeout)) {
                throw 'Timeout precisa ser numero inteiro entre 0 e 600.'
            }
            $timeout = $parsedTimeout
        }
        $res = Set-BootstrapWindowsBootManager -DefaultId $defaultId -Timeout $timeout
        $ui.StatusLabel.Text = "BCD atualizado: $(@($res.Actions) -join ', ') | Backup: $($res.Backup)"
        Refresh-DualBootControls
    } catch {
        $ui.StatusLabel.Text = "Erro ao aplicar BCD: $_"
    }
})

$ui.BcdCleanupButton.Add_Click({
    try {
        $ui.BcdCleanupButton.IsEnabled = $false
        $ui.BcdCleanupStatusText.Text = "Realizando backup e limpando..."
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
    $targetPageId = [string]$navButtonTargets[$i]
    $navButtons[$i].Add_Click({
        $pageIds = @(Get-UiPageIds)
        $idx = [Array]::IndexOf($pageIds, $targetPageId)
        if ($idx -ge 0) { Navigate-ToPage -Index $idx }
    }.GetNewClosure())
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
    # Populate language combo
    [void]$ui.LanguageCombo.Items.Clear()
    foreach ($lang in (Get-UiLanguages)) { [void]$ui.LanguageCombo.Items.Add($lang) }
    $ui.LanguageCombo.SelectedItem = [string]$ui.State.language

    # Populate combos
    foreach ($item in @('off','conservador','equilibrado','agressivo')) { [void]$ui.HostHealthCombo.Items.Add($item) }
    foreach ($item in @(Get-BootstrapAppTuningModes)) { [void]$ui.AppTuningModeCombo.Items.Add($item) }
    foreach ($item in @('all','installed','missing','planned','not-configured','update-check')) { [void]$ui.AppTuningStatusFilterCombo.Items.Add($item) }
    $ui.AppTuningStatusFilterCombo.SelectedItem = 'all'
    foreach ($item in @('Auto','LCD','OLED')) { [void]$ui.SteamDeckVersionCombo.Items.Add($item) }
    foreach ($item in @('UNCLASSIFIED_EXTERNAL','DOCKED_TV','DOCKED_MONITOR')) { [void]$ui.GenericModeCombo.Items.Add($item) }

    Refresh-LocalizedText
    Refresh-CustomPresets
    Navigate-ToPage -Index 0
})

$window.Add_Closing({
    $ui.LogTimer.Stop()
    Save-UiState -State $ui.State -Path $UiStatePath
})

# 
# Run the WPF application
# 

$null = $window.ShowDialog()
