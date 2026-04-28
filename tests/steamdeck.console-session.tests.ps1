$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$automationRoot = Join-Path $repoRoot 'assets\steamdeck\automation'

function New-TestSettingsPath {
    $path = Join-Path $env:TEMP ("steamdeck_console_settings_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    @{
        consoleSession = @{
            primaryShell = 'steam'
            fallbackShell = 'playnite'
            steamLaunch = 'steam://open/bigpicture'
        }
        steamdeckTweaks = @{
            hibernation = 'enabled'
            realtimeUtc = $true
            requireLoginAfterSleep = $false
            gameBar = 'enabled'
            touchKeyboard = 'enabled'
        }
        steamdeckTools = @{
            required = @('RTSS', 'AMD Adrenalin', 'CRU', 'Steam Deck Tools')
        }
        sessionProfiles = @{
            HANDHELD = 'game-handheld'
            DOCKED_TV = 'game-docked'
            DOCKED_MONITOR = 'desktop'
        }
        monitorProfiles = @()
        monitorFamilies = @()
        genericExternal = @{
            mode = 'UNCLASSIFIED_EXTERNAL'
            layout = 'external-unclassified'
            resolutionPolicy = 'desktop-safe'
        }
        displayMode = 'extend'
    } | ConvertTo-Json -Depth 10 | Microsoft.PowerShell.Management\Set-Content -Path $path -Encoding utf8
    return $path
}

function New-TestDetectionPath {
    param([hashtable]$Detection)

    $path = Join-Path $env:TEMP ("steamdeck_console_detection_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $Detection | ConvertTo-Json -Depth 10 | Microsoft.PowerShell.Management\Set-Content -Path $path -Encoding utf8
    return $path
}

Describe 'Steam Deck console session automation' {
    It 'resolves docked display switch mode to extend by default and keeps internal enabled when flagged primary' {
        . (Join-Path $automationRoot 'SteamDeck.Common.ps1')

        Resolve-SteamDeckDisplaySwitchArgument -Settings @{ displayMode = 'extend' } | Should Be '/extend'
        Resolve-SteamDeckDisplaySwitchArgument -Settings @{ displayMode = 'clone' } | Should Be '/clone'
        Resolve-SteamDeckDisplaySwitchArgument -Settings @{
            displayMode = 'external'
            internalDisplay = @{
                primary = $true
            }
        } | Should Be '/extend'
    }

    It 'dry-runs console session as Steam Big Picture first with Playnite fallback' {
        $settingsPath = New-TestSettingsPath
        $scriptPath = Join-Path $automationRoot 'Start-ConsoleSession.ps1'
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        try {
            $json = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SettingsPath $settingsPath -Mode 'HANDHELD' -DryRun
            $result = $json | ConvertFrom-Json

            $result.sessionProfile | Should Be 'Game - Steam Deck'
            $result.primaryShell | Should Be 'steam'
            $result.fallbackShell | Should Be 'playnite'
            $result.steamLaunch | Should Be 'steam://open/bigpicture'
            $result.actions[0] | Should Be 'launch-steam-big-picture'
        } finally {
            if (Test-Path $settingsPath) { Microsoft.PowerShell.Management\Remove-Item $settingsPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'dry-runs handheld tweaks for power, clock, login, gamebar, keyboard and tooling' {
        $settingsPath = New-TestSettingsPath
        $scriptPath = Join-Path $automationRoot 'Apply-SteamDeckTweaks.ps1'
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        try {
            $json = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SettingsPath $settingsPath -Mode 'HANDHELD' -DryRun
            $result = $json | ConvertFrom-Json

            $result.mode | Should Be 'HANDHELD'
            $result.profile | Should Be 'handheld'
            foreach ($expected in @(
                'powercfg-hibernate-enabled',
                'windows-clock-utc',
                'login-after-sleep-disabled',
                'ms-gamebar-enabled',
                'touch-keyboard-enabled',
                'tooling-readiness-rtss',
                'tooling-readiness-amd-adrenalin',
                'tooling-readiness-cru',
                'tooling-readiness-steam-deck-tools'
            )) {
                (@($result.actions) -contains $expected) | Should Be $true
            }

            $steamDeckTools = @($result.results) | Where-Object { $_.action -eq 'tooling-readiness-steam-deck-tools' } | Select-Object -First 1
            $steamDeckTools.name | Should Be 'Steam Deck Tools'
            foreach ($expectedTool in @('PowerControl', 'SteamController', 'PerformanceOverlay')) {
                (@($steamDeckTools.components | ForEach-Object { $_.name }) -contains $expectedTool) | Should Be $true
            }
        } finally {
            if (Test-Path $settingsPath) { Microsoft.PowerShell.Management\Remove-Item $settingsPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'dry-runs dev session without launching Steam Big Picture' {
        $settingsPath = New-TestSettingsPath
        $scriptPath = Join-Path $automationRoot 'Start-DevSession.ps1'
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        try {
            $json = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SettingsPath $settingsPath -Mode 'DOCKED_MONITOR' -DryRun
            $result = $json | ConvertFrom-Json

            $result.sessionProfile | Should Be 'Desktop/Dev'
            $result.steamBigPicture | Should Be 'not-started'
            $result.actions[0] | Should Be 'ensure-explorer-desktop'
        } finally {
            if (Test-Path $settingsPath) { Microsoft.PowerShell.Management\Remove-Item $settingsPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'audits Steam Deck Tools subcomponents for console readiness' {
        $settingsPath = New-TestSettingsPath
        $scriptPath = Join-Path $automationRoot 'Test-ConsoleReadiness.ps1'
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        try {
            $json = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SettingsPath $settingsPath
            $result = $json | ConvertFrom-Json

            $steamDeckTools = @($result.checks) | Where-Object { $_.name -eq 'Steam Deck Tools' } | Select-Object -First 1
            foreach ($expectedTool in @('PowerControl', 'SteamController', 'PerformanceOverlay')) {
                (@($steamDeckTools.components | ForEach-Object { $_.name }) -contains $expectedTool) | Should Be $true
            }
        } finally {
            if (Test-Path $settingsPath) { Microsoft.PowerShell.Management\Remove-Item $settingsPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'classifies an unknown external display as monitor/dev into monitorFamilies' {
        $settingsPath = New-TestSettingsPath
        $detectionPath = New-TestDetectionPath -Detection @{
            mode = 'UNCLASSIFIED_EXTERNAL'
            matchedBy = 'unclassifiedExternal'
            selectedDisplay = @{
                manufacturer = 'ACR'
                product = 'Acer Portable'
                serial = 'ACR-01'
                instanceName = 'DISPLAY\ACR0001\ACR-01'
                isActive = $true
                isPrimary = $true
            }
        }
        $scriptPath = Join-Path $automationRoot 'Classify-ExternalDisplay.ps1'
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        try {
            $json = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SettingsPath $settingsPath -DetectionPath $detectionPath -Choice 'MonitorDev'
            $result = $json | ConvertFrom-Json
            $settings = Microsoft.PowerShell.Management\Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

            $result.mode | Should Be 'DOCKED_MONITOR'
            $result.target | Should Be 'monitorFamilies'
            @($settings.monitorFamilies).Count | Should Be 1
            $settings.monitorFamilies[0].mode | Should Be 'DOCKED_MONITOR'
            $settings.monitorFamilies[0].product | Should Be 'Acer Portable'
        } finally {
            if (Test-Path $settingsPath) { Microsoft.PowerShell.Management\Remove-Item $settingsPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path $detectionPath) { Microsoft.PowerShell.Management\Remove-Item $detectionPath -Force -ErrorAction SilentlyContinue }
        }
    }
}
