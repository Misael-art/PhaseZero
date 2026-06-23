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
    [int]$GpuLayers = 22,
    [int]$Threads = [Math]::Max(2, [Environment]::ProcessorCount / 2),
    [int]$ContextSize = 4096,
    [int]$Port = 8080,
    [int]$MinGpuLayers = 0,
    [int]$DecrementStep = 3
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ServerExe)) { throw "llama-server nao encontrado: $ServerExe" }
if (-not (Test-Path -LiteralPath $ModelPath)) { throw "Modelo GGUF nao encontrado: $ModelPath" }

$layers = [int]$GpuLayers
while ($true) {
    Write-Host ("[llama.cpp] iniciando: gpu-layers={0} threads={1} ctx={2} porta={3}" -f $layers, $Threads, $ContextSize, $Port)
    $serverArgs = @(
        '-m', $ModelPath,
        '--n-gpu-layers', $layers,
        '--threads', $Threads,
        '--ctx-size', $ContextSize,
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
