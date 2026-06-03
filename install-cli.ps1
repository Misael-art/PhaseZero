#Requires -Version 5.1
<#
.SYNOPSIS
    PhaseZero Bootstrap - instalador CLI.
.DESCRIPTION
    Fluxo legado de perfis continua. Fluxo AI tools aceita flags GNU-style:
    --tool, --all-ai-tools, --validate, --configure, --start, --uninstall, --dry-run,
    --yes, --no-admin, --install-root, --result-path e --log-path.
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [Console]::OutputEncoding
try { [Console]::Title = 'PhaseZero Bootstrap - CLI Installer' } catch { }

function Write-CliOut {
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Text,
        [Parameter(Position = 1)][System.ConsoleColor]$ForegroundColor
    )
    if ($ForegroundColor -ne $null) {
        try {
            $prev = [Console]::ForegroundColor
            [Console]::ForegroundColor = $ForegroundColor
            [Console]::WriteLine($Text)
            [Console]::ForegroundColor = $prev
            return
        } catch {
        }
    }
    [Console]::WriteLine($Text)
}

$ToolsPs1 = Join-Path $PSScriptRoot 'bootstrap-tools.ps1'

function New-CliOptions {
    return [ordered]@{
        Profile        = ''
        NonInteractive = $false
        SkipDryRun     = $false
        ListProfiles   = $false
        Tool           = @()
        AllAiTools     = $false
        Validate       = $false
        Configure      = $false
        Start          = $false
        Uninstall      = $false
        DryRun         = $false
        Yes            = $false
        NoAdmin        = $false
        InstallRoot    = ''
        ResultPath     = ''
        LogPath        = ''
        Help           = $false
    }
}

function ConvertTo-CliKey {
    param([Parameter(Mandatory = $true)][string]$Token)
    return (($Token.TrimStart('-','/')) -replace '-', '').ToLowerInvariant()
}

function Read-CliArgs {
    param([string[]]$Tokens)
    $opts = New-CliOptions
    for ($i = 0; $i -lt @($Tokens).Count; $i++) {
        $token = [string]$Tokens[$i]
        if ([string]::IsNullOrWhiteSpace($token)) { continue }

        if ($token -match '^(--?[^=]+)=(.*)$') {
            $key = ConvertTo-CliKey -Token $matches[1]
            $value = [string]$matches[2]
        } else {
            $key = if ($token -match '^[-/]') { ConvertTo-CliKey -Token $token } else { '' }
            $value = $null
        }

        switch ($key) {
            'profile' {
                if ($null -eq $value) { $i++; $value = [string]$Tokens[$i] }
                $opts.Profile = $value
            }
            'noninteractive' { $opts.NonInteractive = $true }
            'skipdryrun' { $opts.SkipDryRun = $true }
            'listprofiles' { $opts.ListProfiles = $true }
            'tool' {
                if ($null -eq $value) { $i++; $value = [string]$Tokens[$i] }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.Tool += @($value) }
            }
            'allaitools' { $opts.AllAiTools = $true }
            'validate' { $opts.Validate = $true }
            'configure' { $opts.Configure = $true }
            'start' { $opts.Start = $true }
            'uninstall' { $opts.Uninstall = $true }
            'dryrun' { $opts.DryRun = $true }
            'yes' { $opts.Yes = $true }
            'y' { $opts.Yes = $true }
            'noadmin' { $opts.NoAdmin = $true }
            'installroot' {
                if ($null -eq $value) { $i++; $value = [string]$Tokens[$i] }
                $opts.InstallRoot = $value
            }
            'resultpath' {
                if ($null -eq $value) { $i++; $value = [string]$Tokens[$i] }
                $opts.ResultPath = $value
            }
            'logpath' {
                if ($null -eq $value) { $i++; $value = [string]$Tokens[$i] }
                $opts.LogPath = $value
            }
            'help' { $opts.Help = $true }
            'h' { $opts.Help = $true }
            '' {
                if ([string]::IsNullOrWhiteSpace([string]$opts.Profile)) { $opts.Profile = $token }
            }
            default {
                throw "Argumento desconhecido: $token"
            }
        }
    }
    return $opts
}

function Write-Header {
    param([string]$Text)
    Write-CliOut ''
    Write-CliOut ('=' * 60) Cyan
    Write-CliOut "  $Text"
    Write-CliOut ('=' * 60) Cyan
    Write-CliOut ''
}

function Write-CliUsage {
    Write-CliOut ''
    Write-CliOut ''
    Write-CliOut ''
    Write-CliOut ''
    Write-CliOut ''
    Write-CliOut ''
    Write-Host '  install-cli.bat --tool opencode --install-root "%TEMP%\PhaseZero AI" --yes'
    Write-Host '  install-cli.bat --tool opencode --uninstall --install-root "%TEMP%\PhaseZero AI" --yes'
    Write-Host '  install-cli.bat --tool ai-proxy-suite --start --yes --no-admin'
}

function Read-HostOrDefault {
    param([string]$Prompt, [string]$Default = '')
    if ([bool]$script:Options.NonInteractive) { return $Default }
    $reply = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
    return $reply
}

function Write-CliLine {
    param([AllowNull()][string]$Text = '')
    Write-Output ([string]$Text)
}

function Get-CliOutputWidth {
    try {
        $width = [int][Console]::WindowWidth
    } catch {
        $width = 100
    }

    if ($width -lt 80) { return 80 }
    if ($width -gt 118) { return 118 }
    return $width
}

function Split-CliTextLine {
    param(
        [AllowNull()][string]$Text,
        [ValidateRange(20, 200)][int]$Width
    )

    $normalized = ([string]$Text -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return @('') }

    $lines = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($word in @($normalized -split ' ')) {
        $remaining = [string]$word
        while ($remaining.Length -gt $Width) {
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                $lines.Add($current) | Out-Null
                $current = ''
            }
            $lines.Add($remaining.Substring(0, $Width)) | Out-Null
            $remaining = $remaining.Substring($Width)
        }

        if ([string]::IsNullOrWhiteSpace($current)) {
            $current = $remaining
        } elseif (($current.Length + 1 + $remaining.Length) -le $Width) {
            $current = "$current $remaining"
        } else {
            $lines.Add($current) | Out-Null
            $current = $remaining
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $lines.Add($current) | Out-Null
    }
    return @($lines.ToArray())
}

function Write-CliProfileRow {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Description,
        [ValidateRange(80, 118)][int]$Width
    )

    $nameWidth = 28
    $prefixWidth = 2 + $nameWidth + 2
    $descriptionWidth = [Math]::Max(30, ($Width - $prefixWidth))
    $wrapped = @(Split-CliTextLine -Text $Description -Width $descriptionWidth)
    Write-CliLine -Text ('  {0,-28}  {1}' -f $Name, $wrapped[0])
    for ($i = 1; $i -lt $wrapped.Count; $i++) {
        Write-CliLine -Text ('  {0,-28}  {1}' -f '', $wrapped[$i])
    }
}

function Get-CliProfileGroupMap {
    $groups = [ordered]@{}
    $groups['Perfis recomendados'] = @('recommended', 'safe-base', 'public-beta', 'base', 'full-workstation', 'full')
    $groups['Steam Deck'] = @(
        'steamdeck-recommended', 'steamdeck-full', 'steamdeck-essentials', 'steamdeck-input',
        'steamdeck-input-advanced', 'steamdeck-power', 'steamdeck-dock', 'steamdeck-storage',
        'steamdeck-connectivity', 'steamdeck-qol', 'steamdeck-capture', 'steamdeck-backup'
    )
    $groups['Categorias opcionais'] = @(
        'containers', 'ai', 'dev-ai', 'support-tools', 'security', 'utilities', 'creator',
        'game-dev', 'gaming', 'automation', 'social', 'workspace', 'legacy'
    )
    return $groups
}

function Write-CliProfileCatalog {
    param([Parameter(Mandatory = $true)][hashtable]$Profiles)

    $width = Get-CliOutputWidth
    $written = @{}
    Write-CliLine -Text ('Nome'.PadRight(30) + 'Descricao')
    Write-CliLine -Text ('-' * $width)

    $groups = Get-CliProfileGroupMap
    foreach ($groupName in $groups.Keys) {
        Write-CliLine
        Write-CliLine -Text $groupName
        foreach ($profileName in @($groups[$groupName])) {
            if (-not $Profiles.Contains($profileName)) { continue }
            $profileDef = $Profiles[$profileName]
            Write-CliProfileRow -Name ([string]$profileDef.Name) -Description ([string]$profileDef.Description) -Width $width
            $written[$profileName] = $true
        }
    }

    $remaining = @($Profiles.Keys | Where-Object { -not $written.ContainsKey([string]$_) } | Sort-Object)
    if ($remaining.Count -gt 0) {
        Write-CliLine
        Write-CliLine -Text 'Outros'
        foreach ($profileName in $remaining) {
            $profileDef = $Profiles[$profileName]
            Write-CliProfileRow -Name ([string]$profileDef.Name) -Description ([string]$profileDef.Description) -Width $width
        }
    }
}

function Resolve-CliLogPath {
    param([string]$RequestedPath)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) { return [System.IO.Path]::GetFullPath($RequestedPath) }
    $root = if ($env:TEMP) { $env:TEMP } else { $PSScriptRoot }
    return (Join-Path $root ("phasezero-install-cli-ai-tools-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)))
}

function Get-CliGuidedProfileEntry {
    return @(
        [ordered]@{ key = '1'; name = 'safe-base';             label = 'Base segura para maquina limpa.' },
        [ordered]@{ key = '2'; name = 'public-beta';           label = 'Beta publico confiavel.' },
        [ordered]@{ key = '3'; name = 'steamdeck-recommended'; label = 'Steam Deck recomendado.' },
        [ordered]@{ key = '4'; name = 'full-workstation';      label = 'Workstation ampla, opt-in.' },
        [ordered]@{ key = '5'; name = '';                      label = 'Outro: digite nome ou alias.' }
    )
}

function Show-CliMainMenu {
    Write-CliOut ''
    Write-CliOut 'PhaseZero Bootstrap - menu rapido' Cyan
    Write-CliOut ''
    Write-CliOut '  1) Doctor (diagnostico, dry-run sem alteracoes)' Cyan
    Write-CliOut '  2) Exportar SupportBundle (dry-run, sem alteracoes)' Cyan
    Write-CliOut '  3) Dry-run perfil safe-base' Cyan
    Write-CliOut '  4) Dry-run perfil public-beta' Cyan
    Write-CliOut '  5) Listar perfis disponiveis' Cyan
    Write-CliOut '  6) Instalacao guiada (perfil recomendado)' Cyan
    Write-CliOut '  0) Sair' Cyan
    Write-CliOut ''
    $reply = Read-Host 'Selecione [1-6, 0=sair]'
    if ($null -eq $reply) { return '' }
    return ([string]$reply).Trim()
}

function Show-CliGuidedProfilePicker {
    Write-CliOut ''
    Write-CliOut 'Instalacao guiada: escolha um perfil base.' Cyan
    Write-CliOut ''
    foreach ($entry in (Get-CliGuidedProfileEntries)) {
        $displayName = if ([string]::IsNullOrWhiteSpace([string]$entry.name)) { '(digitar)' } else { [string]$entry.name }
        Write-CliOut ('  {0}  {1,-26} {2}' -f [string]$entry.key, $displayName, [string]$entry.label)
    }
    Write-CliOut ''
    $pick = ([string](Read-Host 'Numero do perfil [1-5]')).Trim()
    $entries = Get-CliGuidedProfileEntries
    $match = $entries | Where-Object { [string]$_.key -eq $pick } | Select-Object -First 1
    if ($null -eq $match) { return '' }
    if (-not [string]::IsNullOrWhiteSpace([string]$match.name)) { return [string]$match.name }
    return ([string](Read-Host 'Nome do perfil (ex: base, ai, full)')).Trim()
}

function Invoke-CliMenuBackendIntent {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Doctor','SupportBundle','RepairPlan')][string]$Intent
    )
    Write-CliOut ''
    Write-CliOut ("[atalho] Executando -{0} (dry-run, sem alteracoes)..." -f $Intent) Green
    Write-CliOut ''
    $argsList = Add-CliBackendArtifactArg -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass',
        '-File', $ToolsPs1,
        ("-{0}" -f $Intent),
        '-DryRun','-NonInteractive'
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -NoNewWindow -PassThru -Wait
    $exit = [int]$process.ExitCode
    if ($exit -ne 0) {
        Write-CliOut ''
        Write-CliOut ("[ERRO] Atalho {0} falhou (codigo {1})." -f $Intent, $exit) Red
        Write-CliOut ("Log:    {0}" -f [string]$script:Options.LogPath) Yellow
        Write-CliOut ("Result: {0}" -f [string]$script:Options.ResultPath) Yellow
        Write-CliOut ("Retome com: .\bootstrap-tools.ps1 -{0} -DryRun -NonInteractive" -f $Intent) Yellow
    }
    return $exit
}

function Write-CliLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    if ([string]::IsNullOrWhiteSpace([string]$script:CliLogPath)) { return }
    $parent = Split-Path -Path $script:CliLogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    $row = [ordered]@{
        time    = (Get-Date).ToString('o')
        level   = $Level
        message = $Message
    }
    Add-Content -LiteralPath $script:CliLogPath -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
}

function Complete-CliResultEnvelope {
    param([Parameter(Mandatory = $true)]$Payload)

    $result = [ordered]@{}
    if ($Payload -is [System.Collections.IDictionary]) {
        foreach ($key in $Payload.Keys) { $result[[string]$key] = $Payload[$key] }
    } else {
        foreach ($prop in @($Payload.PSObject.Properties)) { $result[[string]$prop.Name] = $prop.Value }
    }

    if (-not $result.Contains('generatedAt')) { $result['generatedAt'] = (Get-Date).ToString('o') }
    if (-not $result.Contains('logPath')) { $result['logPath'] = [string]$script:Options.LogPath }
    if (-not $result.Contains('resultPath')) { $result['resultPath'] = [System.IO.Path]::GetFullPath([string]$script:Options.ResultPath) }
    $result['logPath'] = [string](@($result['logPath'])[0])
    $result['resultPath'] = [string](@($result['resultPath'])[0])
    if (-not $result.Contains('exitCode')) {
        $status = if ($result.Contains('status')) { [string]$result['status'] } else { 'success' }
        $result['exitCode'] = if ($status -eq 'blocked') { 2 } elseif ($status -eq 'error') { 1 } else { 0 }
    }
    if (-not $result.Contains('artifactPaths')) {
        $result['artifactPaths'] = [ordered]@{
            logPath = [System.IO.Path]::GetFullPath([string]$script:Options.LogPath)
            resultPath = [System.IO.Path]::GetFullPath([string]$script:Options.ResultPath)
        }
    }
    if (-not $result.Contains('diagnostics')) {
        $message = ''
        if ($result.Contains('error')) { $message = [string]$result['error'] }
        if ([string]::IsNullOrWhiteSpace($message) -and $result.Contains('message')) { $message = [string]$result['message'] }
        $statusText = if ($result.Contains('status')) { [string]$result['status'] } else { 'success' }
        $diagnosticSeverity = switch ($statusText) {
            'blocked' { 'blocked'; break }
            'error' { 'error'; break }
            'warning' { 'warning'; break }
            default { '' }
        }
        if ([string]::IsNullOrWhiteSpace($message) -or [string]::IsNullOrWhiteSpace($diagnosticSeverity)) {
            $result['diagnostics'] = @()
        } else {
            $result['diagnostics'] = @([ordered]@{
                severity = $diagnosticSeverity
                message = $message
                howToFix = $(if ($result.Contains('howToFix')) { [string]$result['howToFix'] } else { '' })
            })
        }
    }
    if (-not $result.Contains('scope')) {
        $result['scope'] = [ordered]@{
            profile = [string]$script:Options.Profile
            tools = @($script:Options.Tool)
            allAiTools = [bool]$script:Options.AllAiTools
        }
    }
    if (-not $result.Contains('rollback')) {
        $result['rollback'] = [ordered]@{
            available = $false
            changesPath = ''
            summary = $null
        }
    }
    return $result
}

function Write-CliJsonResult {
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [string]$ResultPath
    )
    $Payload = Complete-CliResultEnvelope -Payload $Payload
    $json = $Payload | ConvertTo-Json -Depth 12
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $full = [System.IO.Path]::GetFullPath($ResultPath)
        $parent = Split-Path -Path $full -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::WriteAllText($full, $json, [System.Text.UTF8Encoding]::new($false))
    }
    Write-Host $json
}

function Add-CliBackendArtifactArg {
    param([string[]]$ArgumentList)

    $argsOut = @($ArgumentList)
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.LogPath)) {
        $argsOut += @('-LogPath', [System.IO.Path]::GetFullPath([string]$script:Options.LogPath))
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath)) {
        $argsOut += @('-ResultPath', [System.IO.Path]::GetFullPath([string]$script:Options.ResultPath))
    }
    return $argsOut
}

function Write-CliLegacyFailureResult {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$ExitCode = 2
    )

    if ([string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath)) { return }
    $payload = [ordered]@{
        status = 'error'
        mode = 'legacy'
        generatedAt = (Get-Date).ToString('o')
        logPath = [string]$script:Options.LogPath
        resultPath = [System.IO.Path]::GetFullPath([string]$script:Options.ResultPath)
        exitCode = $ExitCode
        error = $Message
        howToFix = 'Revise o argumento informado, rode install-cli.bat -ListProfiles e execute novamente com -Profile <nome>.'
    }
    Write-CliJsonResult -Payload $payload -ResultPath ([string]$script:Options.ResultPath)
}

function Invoke-CliAiToolsMode {
    param([Parameter(Mandatory = $true)]$Options)

    . $ToolsPs1 -BootstrapUiLibraryMode
    $script:CliLogPath = Resolve-CliLogPath -RequestedPath ([string]$Options.LogPath)
    Write-CliLog -Message 'AI tools mode started.'

    $catalog = Get-BootstrapAiToolCatalog
    $tools = @()
    if ([bool]$Options.AllAiTools) {
        $tools = @($catalog.Keys)
    } else {
        $tools = @($Options.Tool)
    }
    if ($tools.Count -eq 0) { throw 'Informe --tool <name> ou --all-ai-tools.' }

    $action = 'install'
    if ([bool]$Options.Uninstall) { $action = 'uninstall' }
    elseif ([bool]$Options.Start) { $action = 'start' }
    elseif ([bool]$Options.Configure) { $action = 'configure' }
    elseif ([bool]$Options.Validate) { $action = 'validate' }

    $installRoot = Get-BootstrapAiInstallRoot -InstallRoot ([string]$Options.InstallRoot)
    $results = New-Object System.Collections.Generic.List[object]
    $exitCode = 0
    foreach ($tool in @($tools)) {
        Write-CliLog -Message ("{0} {1}" -f $action, $tool)
        try {
            $result = Invoke-BootstrapAiToolAction -ToolName ([string]$tool) -Action $action -InstallRoot $installRoot -ProjectRoot $PSScriptRoot -DryRun:([bool]$Options.DryRun) -Yes:([bool]$Options.Yes) -NoAdmin:([bool]$Options.NoAdmin)
            $results.Add($result) | Out-Null
            $status = [string]$result['status']
            if ($action -in @('install','configure','start','uninstall') -and $status -in @('blocked','error','auth-failed','unhealthy','login-required')) { $exitCode = 3 }
        } catch {
            $status = if ($_.Exception.Data.Contains('BootstrapStatus')) { [string]$_.Exception.Data['BootstrapStatus'] } else { 'error' }
            $kind = if ($_.Exception.Data.Contains('BootstrapBlockerKind')) { [string]$_.Exception.Data['BootstrapBlockerKind'] } else { '' }
            $actionHint = if ($_.Exception.Data.Contains('BootstrapAction')) { [string]$_.Exception.Data['BootstrapAction'] } else { '' }
            $exitCode = if ($status -eq 'blocked') { 3 } else { 2 }
            $message = $_.Exception.Message
            Write-CliLog -Level 'ERROR' -Message $message
            $results.Add([ordered]@{
                mode        = 'ai-tools'
                tool        = [string]$tool
                action      = $action
                status      = $status
                installRoot = $installRoot
                projectRoot = $PSScriptRoot
                message     = $message
                blockerKind = $kind
                howToFix    = $actionHint
            }) | Out-Null
        }
    }

    $payload = [ordered]@{
        mode        = 'ai-tools'
        action      = $action
        dryRun      = [bool]$Options.DryRun
        yes         = [bool]$Options.Yes
        noAdmin     = [bool]$Options.NoAdmin
        installRoot = $installRoot
        logPath     = $script:CliLogPath
        results     = @($results.ToArray())
    }
    if ($results.Count -eq 1) {
        $single = $results[0]
        foreach ($key in @('tool','status','message','docs','commandPath','version','blockerKind','howToFix')) {
            if ($single -is [System.Collections.IDictionary] -and $single.Contains($key)) { $payload[$key] = $single[$key] }
        }
    }
    Write-CliJsonResult -Payload $payload -ResultPath ([string]$Options.ResultPath)
    Write-CliLog -Message ("AI tools mode finished. ExitCode={0}" -f $exitCode)
    exit $exitCode
}

$script:Options = Read-CliArgs -Tokens @($args)

if ([string]::IsNullOrWhiteSpace([string]$script:Options.LogPath)) {
    $root = if ($env:TEMP) { $env:TEMP } else { $PSScriptRoot }
    $script:Options.LogPath = Join-Path $root ("phasezero-install-cli-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}
if ([string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath)) {
    $root = if ($env:TEMP) { $env:TEMP } else { $PSScriptRoot }
    $script:Options.ResultPath = Join-Path $root ("phasezero-install-cli-{0:yyyyMMdd-HHmmss}.result.json" -f (Get-Date))
}

if ([bool]$script:Options.Help) {
    Write-CliUsage
    exit 0
}

if (-not (Test-Path -LiteralPath $ToolsPs1)) {
    Write-CliOut '[ERRO] Nao encontrado:' Red
    Write-CliOut "  $ToolsPs1"
    Write-CliOut 'Execute a partir da pasta do repositorio.' Red
    if (-not [bool]$script:Options.NonInteractive) { Pause }
    exit 1
}

if ([bool]$script:Options.AllAiTools -or @($script:Options.Tool).Count -gt 0) {
    Invoke-CliAiToolsMode -Options $script:Options
}

Write-Header 'PhaseZero Bootstrap - instalador CLI'

try {
    . $ToolsPs1 -BootstrapUiLibraryMode
    $profiles = Get-BootstrapProfileCatalog
} catch {
    Write-CliOut "[ERRO] Falha ao carregar catalogo: $($_.Exception.Message)"
    if (-not [bool]$script:Options.NonInteractive) { Pause }
    exit 1
}

if ([bool]$script:Options.ListProfiles) {
    Write-CliOut '[1/3] Carregando perfis disponiveis...' Green
    Write-CliOut ''
    Write-CliProfileCatalog -Profiles $profiles
    exit 0
}

$profileChoice = [string]$script:Options.Profile
if ([string]::IsNullOrWhiteSpace($profileChoice)) {
    if ([bool]$script:Options.NonInteractive) {
        Write-CliOut '[ERRO] -Profile e obrigatorio em modo nao-interativo.' Red
        Write-CliOut 'Uso: .\install-cli.ps1 -Profile <nome> -NonInteractive' Yellow
        Write-CliOut 'Listar perfis: .\install-cli.ps1 -ListProfiles' Yellow
        Write-CliLegacyFailureResult -Message '-Profile e obrigatorio em modo nao-interativo.' -ExitCode 2
        exit 2
    }

    $menuChoice = Show-CliMainMenu
    switch ($menuChoice) {
        '1' {
            $exit = Invoke-CliMenuBackendIntent -Intent 'Doctor'
            if (-not [bool]$script:Options.NonInteractive) { Pause }
            exit $exit
        }
        '2' {
            $exit = Invoke-CliMenuBackendIntent -Intent 'SupportBundle'
            if (-not [bool]$script:Options.NonInteractive) { Pause }
            exit $exit
        }
        '3' {
            $profileChoice = 'safe-base'
            $script:Options.DryRun = $true
        }
        '4' {
            $profileChoice = 'public-beta'
            $script:Options.DryRun = $true
        }
        '5' {
            Write-CliOut ''
            Write-CliOut '[1/3] Carregando perfis disponiveis...' Green
            Write-CliOut ''
            Write-CliProfileCatalog -Profiles $profiles
            if (-not [bool]$script:Options.NonInteractive) { Pause }
            exit 0
        }
        '6' {
            $profileChoice = Show-CliGuidedProfilePicker
        }
        '0' { exit 0 }
        '' { exit 0 }
        default {
            Write-CliOut '[AVISO] Opcao invalida. Saindo.' Yellow
            if (-not [bool]$script:Options.NonInteractive) { Pause }
            exit 0
        }
    }

    if ([string]::IsNullOrWhiteSpace($profileChoice)) {
        Write-CliOut '[AVISO] Nenhum perfil selecionado. Saindo.' Yellow
        if (-not [bool]$script:Options.NonInteractive) { Pause }
        exit 0
    }
}

Write-CliOut ''
Write-CliOut ("[1/3] Perfil selecionado: {0}" -f $profileChoice) Green

if ([bool]$script:Options.DryRun) { $script:Options.SkipDryRun = $false }

if (-not [bool]$script:Options.SkipDryRun) {
    Write-CliOut ''
    Write-CliOut "[2/3] Validando selecao: $profileChoice"
    Write-CliOut ''

    $dryArgs = Add-CliBackendArtifactArg -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ToolsPs1,
        '-Profile', $profileChoice,
        '-DryRun', '-NonInteractive', '-SkipManualRequirements'
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $dryArgs -NoNewWindow -PassThru -Wait
    $dryExit = $process.ExitCode

    if ($dryExit -ne 0) {
        Write-CliOut ''
        Write-CliOut "[ERRO] Dry-run falhou (codigo $dryExit)."
        Write-CliOut ("Log:        {0}" -f [string]$script:Options.LogPath) Yellow
        Write-CliOut ("Result:     {0}" -f [string]$script:Options.ResultPath) Yellow
        Write-CliOut ("Retomar:    .\install-cli.bat -Profile {0} -DryRun" -f $profileChoice) Yellow
        Write-CliOut ("Diagnostico:.\bootstrap-ui.bat --doctor") Yellow
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath) -and -not (Test-Path -LiteralPath ([string]$script:Options.ResultPath))) {
            Write-CliLegacyFailureResult -Message "Dry-run falhou (codigo $dryExit) sem result.json do backend." -ExitCode $dryExit
        }
        if (-not [bool]$script:Options.NonInteractive) { Pause }
        exit $dryExit
    }
    if ([bool]$script:Options.DryRun) {
        Write-Header 'DRY-RUN: validacao concluida'
        Write-CliOut ("Result:    {0}" -f [string]$script:Options.ResultPath) Green
        Write-CliOut ("Log:       {0}" -f [string]$script:Options.LogPath) Green
        Write-CliOut ("Aplicar:   .\install-cli.bat -Profile {0}" -f $profileChoice) Cyan
        exit 0
    }
}

if (-not [bool]$script:Options.NonInteractive) {
    Write-CliOut ''
    $confirm = Read-Host 'Deseja prosseguir com a instalacao real? (S/N)'
    if ($confirm -notmatch '^[Ss]$') {
        Write-CliOut '[AVISO] Instalacao cancelada pelo usuario.' Yellow
        Pause
        exit 0
    }
}

Write-CliOut ''
Write-CliOut "[3/3] Iniciando instalacao do perfil: $profileChoice"
Write-CliOut 'Isso pode levar varios minutos dependendo das dependencias...' Yellow
Write-CliOut ''

$installArgs = Add-CliBackendArtifactArg -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $ToolsPs1,
    '-Profile', $profileChoice,
    '-NonInteractive', '-SkipManualRequirements'
)
$installProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $installArgs -NoNewWindow -PassThru -Wait
$installExit = $installProcess.ExitCode

Write-CliOut ''
if ($installExit -eq 0) {
    Write-Header 'SUCESSO: Instalacao concluida!'
    Write-CliOut ("Result:    {0}" -f [string]$script:Options.ResultPath) Green
    Write-CliOut ("Log:       {0}" -f [string]$script:Options.LogPath) Green
} else {
    Write-CliOut ("[ERRO] A instalacao falhou ou foi interrompida (ExitCode: {0})." -f $installExit) Red
    Write-CliOut ("Log:          {0}" -f [string]$script:Options.LogPath) Yellow
    Write-CliOut ("Result:       {0}" -f [string]$script:Options.ResultPath) Yellow
    Write-CliOut ("Retomar:      .\install-cli.bat -Profile {0}" -f $profileChoice) Yellow
    Write-CliOut ("Diagnostico:  .\bootstrap-ui.bat --doctor") Yellow
    Write-CliOut ("Bundle:       .\bootstrap-ui.bat --support-bundle") Yellow
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath) -and -not (Test-Path -LiteralPath ([string]$script:Options.ResultPath))) {
        Write-CliLegacyFailureResult -Message "Instalacao falhou ou foi interrompida sem result.json do backend." -ExitCode $installExit
    }
}

if (-not [bool]$script:Options.NonInteractive) { Pause }
exit $installExit
