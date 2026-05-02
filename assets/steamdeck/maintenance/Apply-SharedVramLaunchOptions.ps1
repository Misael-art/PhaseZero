param(
    [string]$SteamRoot = "${env:ProgramFiles(x86)}\Steam",
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$requestedDryRun = [bool]$DryRun

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$bootstrapCandidates = @(
    (Join-Path $scriptRoot 'bootstrap-tools.ps1'),
    (Join-Path $repoRoot 'bootstrap-tools.ps1')
)
$bootstrapPath = [string]($bootstrapCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($bootstrapPath)) {
    throw "bootstrap-tools.ps1 não encontrado. Candidatos: $($bootstrapCandidates -join '; ')"
}

. $bootstrapPath -BootstrapUiLibraryMode

try {
    $settings = (Get-BootstrapSteamDeckSettingsData).Data
    $result = Apply-BootstrapSharedVramLaunchOptions -SteamRoot $SteamRoot -Settings $settings -DryRun:$requestedDryRun
    $result | ConvertTo-Json -Depth 10
} catch {
    throw "Falha ao aplicar launch options -sharedvram: $($_.Exception.Message)"
}
