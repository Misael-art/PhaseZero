function Get-SteamDeckUserHomePath {
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $env:USERPROFILE }
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { return $env:HOME }
    if (-not [string]::IsNullOrWhiteSpace($env:HOMEDRIVE) -and -not [string]::IsNullOrWhiteSpace($env:HOMEPATH)) {
        return ($env:HOMEDRIVE + $env:HOMEPATH)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $env:LOCALAPPDATA }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { return $env:TEMP }
    if (-not [string]::IsNullOrWhiteSpace($env:TMP)) { return $env:TMP }
    return (Get-Location).Path
}

function Get-SteamDeckBootstrapRoot {
    return (Join-Path (Get-SteamDeckUserHomePath) '.bootstrap-tools')
}

function Get-SteamDeckSettingsPath {
    return (Join-Path (Get-SteamDeckBootstrapRoot) 'steamdeck-settings.json')
}

function Get-SteamDeckDetectionPath {
    return (Join-Path (Get-SteamDeckBootstrapRoot) 'steamdeck-current-detection.json')
}

function Get-SteamDeckLastModePath {
    return (Join-Path (Get-SteamDeckBootstrapRoot) 'steamdeck-last-mode.json')
}

function Get-SteamDeckModeStatePath {
    return (Join-Path (Get-SteamDeckBootstrapRoot) 'steamdeck-mode-state.json')
}

function Get-SteamDeckAutomationLogPath {
    return (Join-Path (Get-SteamDeckBootstrapRoot) 'steamdeck-automation.log')
}

function Get-SteamDeckModeWatcherLogPath {
    return (Join-Path (Get-SteamDeckBootstrapRoot) 'steamdeck-mode-watcher.log')
}

function Get-SteamDeckWindowsPowerShellPath {
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
    return 'powershell.exe'
}

function Ensure-SteamDeckParentDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $null = New-Item -Path $parent -ItemType Directory -Force
    }
}

function Assert-SteamDeckFileExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path $Path)) {
        throw "$Description not found: $Path"
    }
}

function Write-SteamDeckJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 10
    )

    Ensure-SteamDeckParentDirectory -Path $Path
    $json = $Value | ConvertTo-Json -Depth $Depth
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
}
