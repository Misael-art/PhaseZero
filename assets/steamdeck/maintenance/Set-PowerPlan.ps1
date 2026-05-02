param(
    [ValidateSet('SCHEME_MIN', 'SCHEME_BALANCED', 'SCHEME_MAX')][string]$Plan = 'SCHEME_BALANCED'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (-not (Test-Path $powercfg)) { $powercfg = 'powercfg.exe' }
    & $powercfg /setactive $Plan | Out-Null
    [ordered]@{ status = 'applied'; action = 'set-power-plan'; plan = $Plan } | ConvertTo-Json -Depth 6
} catch {
    throw "Falha ao aplicar plano de energia ${Plan}: $($_.Exception.Message)"
}
