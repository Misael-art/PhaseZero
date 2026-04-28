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
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [HANDHELD] {1}" -f (Get-Date), $Message
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

function Get-SettingsArray {
    param($Value)

    if ($null -eq $Value) { return @() }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]) -and -not ($Value -is [pscustomobject])) {
        return @($Value)
    }
    return @($Value)
}

function Stop-GameModeProcesses {
    param($Settings)

    $hostHealthMode = if ($Settings.hostHealth -and $Settings.hostHealth.mode) { [string]$Settings.hostHealth.mode } else { 'off' }
    if ($hostHealthMode -eq 'off') { return }

    foreach ($processName in @(Get-SettingsArray -Value $Settings.hostHealth.killInGame)) {
        if ([string]::IsNullOrWhiteSpace([string]$processName)) { continue }
        try {
            $candidateProcesses = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
            if ($processName -eq 'msedge') {
                $candidateProcesses = @($candidateProcesses | Where-Object { $_.MainWindowHandle -eq 0 })
            }
            foreach ($process in $candidateProcesses) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                Write-ApplyLog "Stopped process for game mode: $($process.ProcessName) [$($process.Id)]"
            }
        } catch {
            Write-ApplyLog "Could not stop process $processName for game mode."
        }
    }
}

Assert-SteamDeckFileExists -Path $SettingsPath -Description 'Settings file'
$settings = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json
$detection = if (Test-Path $DetectionPath) { Get-Content -Path $DetectionPath -Raw | ConvertFrom-Json } else { $null }
$displaySwitch = Join-Path $env:SystemRoot 'System32\DisplaySwitch.exe'
if (Test-Path $displaySwitch) {
    Start-Process -FilePath $displaySwitch -ArgumentList '/internal' -WindowStyle Hidden
} else {
    Write-ApplyLog "DisplaySwitch.exe not found: $displaySwitch"
}

Stop-GameModeProcesses -Settings $settings

$tweaksResult = $null
$tweaksScript = Join-Path (Split-Path -Parent $PSCommandPath) 'Apply-SteamDeckTweaks.ps1'
if (Test-Path $tweaksScript) {
    try {
        $tweaksJson = & $tweaksScript -SettingsPath $SettingsPath -Mode 'HANDHELD'
        $tweaksResult = $tweaksJson | ConvertFrom-Json
    } catch {
        Write-ApplyLog "Handheld tweaks failed: $($_.Exception.Message)"
    }
}

$sessionResult = $null
$sessionScript = Join-Path (Split-Path -Parent $PSCommandPath) 'Start-ConsoleSession.ps1'
if (Test-Path $sessionScript) {
    try {
        $sessionJson = & $sessionScript -SettingsPath $SettingsPath -Mode 'HANDHELD'
        $sessionResult = $sessionJson | ConvertFrom-Json
    } catch {
        Write-ApplyLog "Console session failed: $($_.Exception.Message)"
    }
}

$result = [ordered]@{
    mode = 'HANDHELD'
    effectiveMode = 'HANDHELD'
    sessionProfile = if ($detection -and $detection.sessionProfile) { $detection.sessionProfile } else { 'game-handheld' }
    experience = 'Game - Steam Deck'
    tweaks = $tweaksResult
    consoleSession = $sessionResult
    resolution = $settings.handheld.resolution
    refreshHz = $settings.handheld.refreshHz
    taskbarMode = $settings.handheld.taskbarMode
    inputProfile = $settings.handheld.inputProfile
    gyroEnabled = $settings.handheld.gyroEnabled
    matchedBy = if ($detection) { $detection.matchedBy } else { 'manual' }
}

$resultPath = Get-SteamDeckLastModePath
Write-SteamDeckJsonFile -Path $resultPath -Value $result -Depth 8
Write-ApplyLog "Applied handheld mode at $($settings.handheld.resolution)"
$result | ConvertTo-Json -Depth 8
