param(
    [string]$SettingsPath,
    [string]$DetectionPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSCommandPath) 'SteamDeck.Common.ps1')

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Get-SteamDeckSettingsPath
}
if ([string]::IsNullOrWhiteSpace($DetectionPath)) {
    $DetectionPath = Get-SteamDeckDetectionPath
}

function Write-ApplyLog {
    param([string]$Message)
    $logPath = Get-SteamDeckAutomationLogPath
    Ensure-SteamDeckParentDirectory -Path $logPath
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [DOCKED_MONITOR] {1}" -f (Get-Date), $Message
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

Assert-SteamDeckFileExists -Path $SettingsPath -Description 'Settings file'
$settings = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json
$detection = if (Test-Path $DetectionPath) { Get-Content -Path $DetectionPath -Raw | ConvertFrom-Json } else { $null }
$displaySwitch = Join-Path $env:SystemRoot 'System32\DisplaySwitch.exe'
if (Test-Path $displaySwitch) {
    Start-Process -FilePath $displaySwitch -ArgumentList '/external' -WindowStyle Hidden
} else {
    Write-ApplyLog "DisplaySwitch.exe not found: $displaySwitch"
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

$resultPath = Get-SteamDeckLastModePath
Write-SteamDeckJsonFile -Path $resultPath -Value $result -Depth 8
Write-ApplyLog "Applied docked monitor mode with policy $resolutionPolicy and layout $layout"
$result | ConvertTo-Json -Depth 8
