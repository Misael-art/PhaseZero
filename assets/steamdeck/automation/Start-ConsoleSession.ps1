param(
    [string]$SettingsPath,
    [ValidateSet('HANDHELD', 'DOCKED_TV')][string]$Mode = 'HANDHELD',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSCommandPath) 'SteamDeck.Common.ps1')

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Get-SteamDeckSettingsPath
}

function Write-ConsoleSessionLog {
    param([string]$Message)

    $logPath = Get-SteamDeckAutomationLogPath
    Ensure-SteamDeckParentDirectory -Path $logPath
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [CONSOLE] {1}" -f (Get-Date), $Message
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

function Get-SettingValue {
    param(
        $Object,
        [string]$Name,
        $Default
    )

    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $value = $Object.$Name
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return $value
        }
    }
    return $Default
}

function Find-PlayniteFullscreenPath {
    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Playnite\Playnite.FullscreenApp.exe') }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Playnite\Playnite.FullscreenApp.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Playnite\Playnite.FullscreenApp.exe') }

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Start-SteamBigPicture {
    param([string]$LaunchUri)

    try {
        Start-Process -FilePath $LaunchUri | Out-Null
        return $true
    } catch {
        Write-ConsoleSessionLog "Steam URI launch failed: $($_.Exception.Message)"
        return $false
    }
}

Assert-SteamDeckFileExists -Path $SettingsPath -Description 'Settings file'
$settings = Read-SteamDeckJsonFile -Path $SettingsPath
$consoleSession = if ($settings.PSObject.Properties.Name -contains 'consoleSession') { $settings.consoleSession } else { $null }

$primaryShell = [string](Get-SettingValue -Object $consoleSession -Name 'primaryShell' -Default 'steam')
$fallbackShell = [string](Get-SettingValue -Object $consoleSession -Name 'fallbackShell' -Default 'playnite')
$steamLaunch = [string](Get-SettingValue -Object $consoleSession -Name 'steamLaunch' -Default 'steam://open/bigpicture')
$playnitePath = Find-PlayniteFullscreenPath

$actions = New-Object System.Collections.Generic.List[string]
$actions.Add('launch-steam-big-picture')
if ($fallbackShell -eq 'playnite') {
    $actions.Add('fallback-playnite-fullscreen')
}

$launched = $false
if (-not $DryRun) {
    if ($primaryShell -eq 'steam') {
        $launched = Start-SteamBigPicture -LaunchUri $steamLaunch
    }

    if (-not $launched -and $fallbackShell -eq 'playnite' -and $playnitePath) {
        Start-Process -FilePath $playnitePath | Out-Null
        $launched = $true
    }
}

$result = [ordered]@{
    mode = $Mode
    sessionProfile = 'Game - Steam Deck'
    primaryShell = $primaryShell
    fallbackShell = $fallbackShell
    steamLaunch = $steamLaunch
    playnitePath = $playnitePath
    launched = [bool]$launched
    dryRun = [bool]$DryRun
    actions = @($actions.ToArray())
}

if (-not $DryRun) {
    Write-ConsoleSessionLog "Console session requested for $Mode (dryRun=$DryRun primary=$primaryShell fallback=$fallbackShell)"
}
$result | ConvertTo-Json -Depth 8
