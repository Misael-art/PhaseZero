$ErrorActionPreference = 'Stop'
$logFile = Join-Path $PSScriptRoot 'ui-debug.log'

try {
    "Starting bootstrap-ui.ps1 at $(Get-Date)" | Out-File -Encoding utf8 -Force $logFile
    "ApartmentState: $([Threading.Thread]::CurrentThread.ApartmentState)" | Out-File -Encoding utf8 -Append $logFile
    "PSCommandPath: $PSCommandPath" | Out-File -Encoding utf8 -Append $logFile

    $uiScript = Join-Path $PSScriptRoot 'bootstrap-ui.ps1'
    "UI Script: $uiScript" | Out-File -Encoding utf8 -Append $logFile
    "UI Script Exists: $(Test-Path $uiScript)" | Out-File -Encoding utf8 -Append $logFile

    & $uiScript 2>&1 | Out-File -Encoding utf8 -Append $logFile
    "Script completed normally" | Out-File -Encoding utf8 -Append $logFile
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File -Encoding utf8 -Append $logFile
    "STACK: $($_.ScriptStackTrace)" | Out-File -Encoding utf8 -Append $logFile
}
