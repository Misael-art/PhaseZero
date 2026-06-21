param(
    [string]$SettingsPath,
    [ValidateSet('DOCKED_MONITOR', 'UNCLASSIFIED_EXTERNAL')][string]$Mode = 'DOCKED_MONITOR',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSCommandPath) 'SteamDeck.Common.ps1')

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Get-SteamDeckSettingsPath
}

function Write-DevSessionLog {
    param([string]$Message)

    $logPath = Get-SteamDeckAutomationLogPath
    Ensure-SteamDeckParentDirectory -Path $logPath
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [DEV] {1}" -f (Get-Date), $Message
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

Assert-SteamDeckFileExists -Path $SettingsPath -Description 'Settings file'

$actions = New-Object System.Collections.Generic.List[string]
$actions.Add('ensure-explorer-desktop')
$actions.Add('skip-steam-big-picture')

if (-not $DryRun) {
    $explorer = Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $explorer) {
        Start-Process -FilePath 'explorer.exe' | Out-Null
    }
}

$result = [ordered]@{
    mode = $Mode
    sessionProfile = 'Desktop/Dev'
    steamBigPicture = 'not-started'
    dryRun = [bool]$DryRun
    actions = @($actions.ToArray())
}

if (-not $DryRun) {
    Write-DevSessionLog "Dev session requested for $Mode (dryRun=$DryRun)"
}
$result | ConvertTo-Json -Depth 8
