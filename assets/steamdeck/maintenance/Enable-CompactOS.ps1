$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    $compactExe = Join-Path $env:SystemRoot 'System32\compact.exe'
    if (-not (Test-Path $compactExe)) { $compactExe = 'compact.exe' }
    & $compactExe /CompactOS:always | Out-Null
    [ordered]@{ status = 'applied'; action = 'enable-compact-os'; mode = 'always' } | ConvertTo-Json -Depth 6
} catch {
    throw "Falha ao habilitar CompactOS: $($_.Exception.Message)"
}
