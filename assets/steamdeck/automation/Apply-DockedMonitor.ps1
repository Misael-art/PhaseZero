param(
    [string]$SettingsPath = (Join-Path (Join-Path $env:USERPROFILE '.bootstrap-tools') 'steamdeck-settings.json'),
    [string]$DetectionPath = (Join-Path (Join-Path $env:USERPROFILE '.bootstrap-tools') 'steamdeck-current-detection.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-ApplyLog {
    param([string]$Message)
    $logPath = Join-Path (Join-Path $env:USERPROFILE '.bootstrap-tools') 'steamdeck-automation.log'
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [DOCKED_MONITOR] {1}" -f (Get-Date), $Message
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

$settings = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json
$detection = if (Test-Path $DetectionPath) { Get-Content -Path $DetectionPath -Raw | ConvertFrom-Json } else { $null }
$displaySwitch = Join-Path $env:SystemRoot 'System32\DisplaySwitch.exe'
if (Test-Path $displaySwitch) {
    Start-Process -FilePath $displaySwitch -ArgumentList '/external' -WindowStyle Hidden
}

$matchedConfig = if ($detection -and $detection.matchedConfig) { $detection.matchedConfig } else { $settings.dockMonitor }
$resolutionPolicy = if ($matchedConfig.PSObject.Properties.Name -contains 'resolutionPolicy') { $matchedConfig.resolutionPolicy } else { $settings.dockMonitor.resolutionPolicy }
$layout = if ($matchedConfig.PSObject.Properties.Name -contains 'layout') { $matchedConfig.layout } else { $settings.dockMonitor.layout }

$result = [ordered]@{
    mode = 'DOCKED_MONITOR'
    sessionProfile = if ($detection -and $detection.sessionProfile) { $detection.sessionProfile } else { 'desktop' }
    resolutionPolicy = $resolutionPolicy
    layout = $layout
    taskbarMode = $settings.dockMonitor.taskbarMode
    inputProfile = $settings.dockMonitor.inputProfile
    gyroEnabled = $settings.dockMonitor.gyroEnabled
    matchedBy = if ($detection) { $detection.matchedBy } else { 'manual' }
    selectedDisplay = if ($detection) { $detection.selectedDisplay } else { $null }
}

$resultPath = Join-Path (Join-Path $env:USERPROFILE '.bootstrap-tools') 'steamdeck-last-mode.json'
$result | ConvertTo-Json -Depth 8 | Set-Content -Path $resultPath -Encoding utf8
Write-ApplyLog "Applied docked monitor mode with policy $resolutionPolicy and layout $layout"
$result | ConvertTo-Json -Depth 8
