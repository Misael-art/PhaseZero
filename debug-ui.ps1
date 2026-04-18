$ErrorActionPreference = 'Stop'
$logFile = Join-Path $PSScriptRoot 'ui-debug.log'

try {
    "Starting bootstrap-ui.ps1 at $(Get-Date)" | Out-File -Force $logFile
    "ApartmentState: $([Threading.Thread]::CurrentThread.ApartmentState)" | Out-File -Append $logFile
    "PSCommandPath: $PSCommandPath" | Out-File -Append $logFile

    $uiScript = Join-Path $PSScriptRoot 'bootstrap-ui.ps1'
    "UI Script: $uiScript" | Out-File -Append $logFile
    "UI Script Exists: $(Test-Path $uiScript)" | Out-File -Append $logFile

    & $uiScript 2>&1 | Out-File -Append $logFile
    "Script completed normally" | Out-File -Append $logFile
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File -Append $logFile
    "STACK: $($_.ScriptStackTrace)" | Out-File -Append $logFile
}
