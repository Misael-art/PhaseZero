$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$steamdeckRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $steamdeckRoot 'automation') 'SteamDeck.Common.ps1')

try {
    $compactExe = Join-SteamDeckSystemChild -RelativeChild 'System32\compact.exe'
    if (-not (Test-Path $compactExe)) { $compactExe = 'compact.exe' }
    & $compactExe /CompactOS:always | Out-Null
    [ordered]@{ status = 'applied'; action = 'enable-compact-os'; mode = 'always' } | ConvertTo-Json -Depth 6
} catch {
    throw "Falha ao habilitar CompactOS: $($_.Exception.Message)"
}
