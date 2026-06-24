#requires -Version 5.1
<#
.SYNOPSIS
    Launcher resiliente do llama.cpp (llama-server) para servidor LLM local no Windows.
.DESCRIPTION
    Inicia o llama-server expondo uma API compativel com OpenAI em :8080, com offload hibrido
    GPU/CPU. Se o servidor falhar (provavel estouro de VRAM), reduz --n-gpu-layers e tenta de novo,
    ate um piso. Parametros vem do plano calculado por Get-BootstrapLlamaOffloadPlan (PhaseZero),
    mas podem ser sobrescritos por argumento. NUNCA formata/particiona nada.
.NOTES
    Gerado/atualizado pelo componente 'llamacpp-server' do PhaseZero. Edite o asset-fonte, nao a copia.
#>
[CmdletBinding()]
param(
    [string]$ServerExe = (Join-Path $PSScriptRoot 'llama-server.exe'),
    [Parameter(Mandatory = $true)][string]$ModelPath,
    # Perfil de performance: 'speed' (mais t/s), 'capacity' (qualidade/contexto), 'moderate' (equilibrio).
    [ValidateSet('speed', 'capacity', 'moderate')][string]$PerfMode = 'moderate',
    [int]$GpuLayers = 22,
    [int]$Threads = [Math]::Max(2, [Environment]::ProcessorCount / 2),
    [int]$ContextSize = 0,
    [string]$CacheTypeK = '',
    [string]$CacheTypeV = '',
    [int]$Port = 8080,
    [int]$MinGpuLayers = 0,
    [int]$DecrementStep = 3
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ServerExe)) { throw "llama-server nao encontrado: $ServerExe" }
if (-not (Test-Path -LiteralPath $ModelPath)) { throw "Modelo GGUF nao encontrado: $ModelPath" }

# Defaults por perfil de performance (sobreponiveis por argumento). Espelha
# Get-BootstrapLlamaPerformanceProfile do PhaseZero.
$perf = switch ($PerfMode) {
    'speed'    { @{ ctx = 2048; ck = 'q4_0'; cv = 'q4_0' } }
    'capacity' { @{ ctx = 8192; ck = 'f16';  cv = 'f16'  } }
    default    { @{ ctx = 4096; ck = 'q8_0'; cv = 'q8_0' } }
}
if ($ContextSize -le 0) { $ContextSize = [int]$perf.ctx }
if ([string]::IsNullOrWhiteSpace($CacheTypeK)) { $CacheTypeK = [string]$perf.ck }
if ([string]::IsNullOrWhiteSpace($CacheTypeV)) { $CacheTypeV = [string]$perf.cv }

$layers = [int]$GpuLayers
while ($true) {
    Write-Host ("[llama.cpp] iniciando: perf={0} gpu-layers={1} threads={2} ctx={3} kv={4}/{5} porta={6}" -f $PerfMode, $layers, $Threads, $ContextSize, $CacheTypeK, $CacheTypeV, $Port)
    $serverArgs = @(
        '-m', $ModelPath,
        '--n-gpu-layers', $layers,
        '--threads', $Threads,
        '--ctx-size', $ContextSize,
        '--cache-type-k', $CacheTypeK,
        '--cache-type-v', $CacheTypeV,
        '--flash-attn',
        '--port', $Port,
        '--host', '127.0.0.1'
    )
    & $ServerExe @serverArgs
    $code = $LASTEXITCODE
    if ($code -eq 0) { break }

    if ($layers -le $MinGpuLayers) {
        Write-Host ("[llama.cpp] FALHA: servidor saiu com codigo {0} mesmo no piso de offload ({1})." -f $code, $MinGpuLayers) -ForegroundColor Red
        exit $code
    }
    $layers = [Math]::Max($MinGpuLayers, $layers - $DecrementStep)
    Write-Host ("[llama.cpp] provavel estouro de VRAM (exit={0}). Reduzindo --n-gpu-layers para {1} e tentando de novo..." -f $code, $layers) -ForegroundColor Yellow
}
