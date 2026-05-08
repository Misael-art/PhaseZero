#Requires -Version 5.1
<#
.SYNOPSIS
    PhaseZero Bootstrap - instalador CLI.
.DESCRIPTION
    Lista perfis, valida selecao via dry-run e executa instalacao real.
    Modo interativo (default): pede confirmacao do usuario.
    Modo nao-interativo: passe -Profile e -NonInteractive para uso em CI/scripts.
.EXAMPLE
    .\install-cli.ps1
    .\install-cli.ps1 -Profile base -NonInteractive
    .\install-cli.ps1 -Profile full -SkipDryRun -NonInteractive
#>

param(
    [string]$Profile,
    [switch]$NonInteractive,
    [switch]$SkipDryRun,
    [switch]$ListProfiles
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [Console]::OutputEncoding
try { [Console]::Title = 'PhaseZero Bootstrap - CLI Installer' } catch { }

$ToolsPs1 = Join-Path $PSScriptRoot 'bootstrap-tools.ps1'

if (-not (Test-Path -LiteralPath $ToolsPs1)) {
    Write-Host '[ERRO] Nao encontrado:' -ForegroundColor Red
    Write-Host "  $ToolsPs1" -ForegroundColor Yellow
    Write-Host 'Execute a partir da pasta do repositorio.' -ForegroundColor Red
    if (-not $NonInteractive) { Pause }
    exit 1
}

function Write-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host ''
}

function Read-HostOrDefault {
    param([string]$Prompt, [string]$Default = '')
    if ($NonInteractive) { return $Default }
    $reply = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
    return $reply
}

Write-Header 'PhaseZero Bootstrap - instalador CLI'

# 1. Listar perfis
Write-Host '[1/3] Carregando perfis disponiveis...' -ForegroundColor Green
Write-Host ''

$profilesOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { . '$ToolsPs1' -BootstrapUiLibraryMode; Show-BootstrapProfiles }" 2>&1
$exitCode = $LASTEXITCODE
Write-Host $profilesOutput
if ($exitCode -ne 0) {
    Write-Host "[ERRO] Falha ao listar perfis (codigo $exitCode)." -ForegroundColor Red
    if (-not $NonInteractive) { Pause }
    exit $exitCode
}

if ($ListProfiles) { exit 0 }

# 2. Escolher perfil
$profileChoice = $Profile
if ([string]::IsNullOrWhiteSpace($profileChoice)) {
    if ($NonInteractive) {
        Write-Host '[ERRO] -Profile e obrigatorio em modo nao-interativo.' -ForegroundColor Red
        Write-Host 'Uso: .\install-cli.ps1 -Profile <nome> -NonInteractive' -ForegroundColor Yellow
        exit 2
    }
    Write-Host ''
    $profileChoice = Read-HostOrDefault -Prompt 'Digite o nome do perfil que deseja instalar (ex: base, full, ai)'
    if ([string]::IsNullOrWhiteSpace($profileChoice)) {
        Write-Host '[AVISO] Nenhum perfil selecionado. Saindo.' -ForegroundColor Yellow
        if (-not $NonInteractive) { Pause }
        exit 0
    }
}

# 2b. Dry-run
if (-not $SkipDryRun) {
    Write-Host ''
    Write-Host "[2/3] Validando selecao: $profileChoice" -ForegroundColor Green
    Write-Host ''

    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ToolsPs1,
        '-Profile', $profileChoice,
        '-DryRun', '-NonInteractive', '-SkipManualRequirements'
    ) -NoNewWindow -PassThru -Wait
    $dryExit = $process.ExitCode

    if ($dryExit -ne 0) {
        Write-Host "[ERRO] Dry-run falhou (codigo $dryExit). Verifique o log em %TEMP%." -ForegroundColor Red
        if (-not $NonInteractive) { Pause }
        exit $dryExit
    }
}

# 3. Confirmar e instalar
if (-not $NonInteractive) {
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

$installProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $ToolsPs1,
    '-Profile', $profileChoice,
    '-NonInteractive', '-SkipManualRequirements'
) -NoNewWindow -PassThru -Wait
$installExit = $installProcess.ExitCode

Write-Host ''
if ($installExit -eq 0) {
    Write-Header 'SUCESSO: Instalacao concluida!'
} else {
    Write-Host "[ERRO] A instalacao falhou ou foi interrompida (ExitCode: $installExit)." -ForegroundColor Red
    Write-Host 'Verifique o log gerado em seu diretorio TEMP.' -ForegroundColor Yellow
}

if (-not $NonInteractive) { Pause }
exit $installExit
