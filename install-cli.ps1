#Requires -Version 5.1
<#
.SYNOPSIS
    PhaseZero Bootstrap - instalador CLI.
.DESCRIPTION
    Fluxo legado de perfis continua. Fluxo AI tools aceita flags GNU-style:
    --tool, --all-ai-tools, --validate, --configure, --uninstall, --dry-run,
    --yes, --no-admin, --install-root, --result-path e --log-path.
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [Console]::OutputEncoding
try { [Console]::Title = 'PhaseZero Bootstrap - CLI Installer' } catch { }

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
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host ''
}

function Write-CliUsage {
    Write-Host 'Uso legado:'
    Write-Host '  install-cli.bat -ListProfiles'
    Write-Host '  install-cli.bat -Profile base -NonInteractive'
    Write-Host ''
    Write-Host 'AI tools:'
    Write-Host '  install-cli.bat --tool claude-code --validate --dry-run --yes'
    Write-Host '  install-cli.bat --tool opencode --install-root "%TEMP%\PhaseZero AI" --yes'
    Write-Host '  install-cli.bat --tool opencode --uninstall --install-root "%TEMP%\PhaseZero AI" --yes'
}

function Read-HostOrDefault {
    param([string]$Prompt, [string]$Default = '')
    if ([bool]$script:Options.NonInteractive) { return $Default }
    $reply = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
    return $reply
}

function Resolve-CliLogPath {
    param([string]$RequestedPath)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) { return [System.IO.Path]::GetFullPath($RequestedPath) }
    $root = if ($env:TEMP) { $env:TEMP } else { $PSScriptRoot }
    return (Join-Path $root ("phasezero-install-cli-ai-tools-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)))
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

function Add-CliBackendArtifactArgs {
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
            if ($action -in @('install','configure','uninstall') -and $status -in @('blocked','error')) { $exitCode = 3 }
        } catch {
            $exitCode = 2
            $message = $_.Exception.Message
            Write-CliLog -Level 'ERROR' -Message $message
            $results.Add([ordered]@{
                mode        = 'ai-tools'
                tool        = [string]$tool
                action      = $action
                status      = 'error'
                installRoot = $installRoot
                projectRoot = $PSScriptRoot
                message     = $message
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
        foreach ($key in @('tool','status','message','docs','commandPath','version')) {
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
    Write-Host '[ERRO] Nao encontrado:' -ForegroundColor Red
    Write-Host "  $ToolsPs1" -ForegroundColor Yellow
    Write-Host 'Execute a partir da pasta do repositorio.' -ForegroundColor Red
    if (-not [bool]$script:Options.NonInteractive) { Pause }
    exit 1
}

if ([bool]$script:Options.AllAiTools -or @($script:Options.Tool).Count -gt 0) {
    Invoke-CliAiToolsMode -Options $script:Options
}

Write-Header 'PhaseZero Bootstrap - instalador CLI'

Write-Host '[1/3] Carregando perfis disponiveis...' -ForegroundColor Green
Write-Host ''

$profilesOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { . '$ToolsPs1' -BootstrapUiLibraryMode; Show-BootstrapProfiles }" 2>&1
$exitCode = $LASTEXITCODE
Write-Host $profilesOutput
if ($exitCode -ne 0) {
    Write-Host "[ERRO] Falha ao listar perfis (codigo $exitCode)." -ForegroundColor Red
    if (-not [bool]$script:Options.NonInteractive) { Pause }
    exit $exitCode
}

if ([bool]$script:Options.ListProfiles) { exit 0 }

$profileChoice = [string]$script:Options.Profile
if ([string]::IsNullOrWhiteSpace($profileChoice)) {
    if ([bool]$script:Options.NonInteractive) {
        Write-Host '[ERRO] -Profile e obrigatorio em modo nao-interativo.' -ForegroundColor Red
        Write-Host 'Uso: .\install-cli.ps1 -Profile <nome> -NonInteractive' -ForegroundColor Yellow
        Write-CliLegacyFailureResult -Message '-Profile e obrigatorio em modo nao-interativo.' -ExitCode 2
        exit 2
    }
    Write-Host ''
    $profileChoice = Read-HostOrDefault -Prompt 'Digite o nome do perfil que deseja instalar (ex: base, full, ai)'
    if ([string]::IsNullOrWhiteSpace($profileChoice)) {
        Write-Host '[AVISO] Nenhum perfil selecionado. Saindo.' -ForegroundColor Yellow
        if (-not [bool]$script:Options.NonInteractive) { Pause }
        exit 0
    }
}

if ([bool]$script:Options.DryRun) { $script:Options.SkipDryRun = $false }

if (-not [bool]$script:Options.SkipDryRun) {
    Write-Host ''
    Write-Host "[2/3] Validando selecao: $profileChoice" -ForegroundColor Green
    Write-Host ''

    $dryArgs = Add-CliBackendArtifactArgs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ToolsPs1,
        '-Profile', $profileChoice,
        '-DryRun', '-NonInteractive', '-SkipManualRequirements'
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $dryArgs -NoNewWindow -PassThru -Wait
    $dryExit = $process.ExitCode

    if ($dryExit -ne 0) {
        Write-Host "[ERRO] Dry-run falhou (codigo $dryExit). Verifique o log em %TEMP%." -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath) -and -not (Test-Path -LiteralPath ([string]$script:Options.ResultPath))) {
            Write-CliLegacyFailureResult -Message "Dry-run falhou (codigo $dryExit) sem result.json do backend." -ExitCode $dryExit
        }
        if (-not [bool]$script:Options.NonInteractive) { Pause }
        exit $dryExit
    }
    if ([bool]$script:Options.DryRun) {
        Write-Header 'DRY-RUN: validacao concluida'
        exit 0
    }
}

if (-not [bool]$script:Options.NonInteractive) {
    Write-Host ''
    $confirm = Read-Host 'Deseja prosseguir com a instalacao real? (S/N)'
    if ($confirm -notmatch '^[Ss]$') {
        Write-Host '[AVISO] Instalacao cancelada pelo usuario.' -ForegroundColor Yellow
        Pause
        exit 0
    }
}

Write-Host ''
Write-Host "[3/3] Iniciando instalacao do perfil: $profileChoice" -ForegroundColor Green
Write-Host 'Isso pode levar varios minutos dependendo das dependencias...' -ForegroundColor Yellow
Write-Host ''

$installArgs = Add-CliBackendArtifactArgs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $ToolsPs1,
    '-Profile', $profileChoice,
    '-NonInteractive', '-SkipManualRequirements'
)
$installProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $installArgs -NoNewWindow -PassThru -Wait
$installExit = $installProcess.ExitCode

Write-Host ''
if ($installExit -eq 0) {
    Write-Header 'SUCESSO: Instalacao concluida!'
} else {
    Write-Host "[ERRO] A instalacao falhou ou foi interrompida (ExitCode: $installExit)." -ForegroundColor Red
    Write-Host 'Verifique o log gerado em seu diretorio TEMP.' -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath) -and -not (Test-Path -LiteralPath ([string]$script:Options.ResultPath))) {
        Write-CliLegacyFailureResult -Message "Instalacao falhou ou foi interrompida sem result.json do backend." -ExitCode $installExit
    }
}

if (-not [bool]$script:Options.NonInteractive) { Pause }
exit $installExit
