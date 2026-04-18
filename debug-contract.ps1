$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bootstrap-tools.ps1') -BootstrapUiLibraryMode

$c = Get-BootstrapUiContract
Write-Host "Contract type: $($c.GetType().FullName)"
Write-Host "defaults value type: $($c['defaults'].GetType().FullName)"
Write-Host "workspaceRoot via index: $($c['defaults']['workspaceRoot'])"
Write-Host "workspaceRoot via dot: $($c.defaults.workspaceRoot)"

Write-Host ""
Write-Host "--- Testing Get-UiStateDefaults ---"
try {
    $defaults = Get-UiStateDefaults -Contract $c
    Write-Host "defaults is null: $($null -eq $defaults)"
    if ($defaults) {
        Write-Host "defaults type: $($defaults.GetType().FullName)"
    }
} catch {
    Write-Host "ERROR in Get-UiStateDefaults: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "--- Testing full Read-UiState ---"
$statePath = Join-Path $env:TEMP ("test_ui_state_{0}.json" -f [guid]::NewGuid().ToString('N'))
try {
    $st = Read-UiState -Path $statePath -Contract $c
    Write-Host "Read-UiState OK, keys: $($st.Keys -join ', ')"
} catch {
    Write-Host "ERROR in Read-UiState: $($_.Exception.Message)"
    Write-Host "STACK: $($_.ScriptStackTrace)"
} finally {
    if (Test-Path $statePath) { Remove-Item $statePath -Force -ErrorAction SilentlyContinue }
}
