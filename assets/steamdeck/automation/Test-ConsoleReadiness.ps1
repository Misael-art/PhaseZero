param(
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSCommandPath) 'SteamDeck.Common.ps1')

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Get-SteamDeckSettingsPath
}

function Test-CommandOrPath {
    param([string[]]$Candidates)

    foreach ($candidate in @($Candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $expanded = $ExecutionContext.InvokeCommand.ExpandString($candidate)
        if (Test-Path $expanded) { return $true }
        if (Get-Command $expanded -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Get-SteamDeckToolsReadiness {
    $components = @(
        [ordered]@{ name = 'PowerControl'; candidates = @('PowerControl.exe', '$env:ProgramFiles\SteamDeckTools\PowerControl.exe', '$env:LOCALAPPDATA\Programs\SteamDeckTools\PowerControl.exe') },
        [ordered]@{ name = 'SteamController'; candidates = @('SteamController.exe', '$env:ProgramFiles\SteamDeckTools\SteamController.exe', '$env:LOCALAPPDATA\Programs\SteamDeckTools\SteamController.exe') },
        [ordered]@{ name = 'FanControl'; candidates = @('FanControl.exe', '$env:ProgramFiles\SteamDeckTools\FanControl.exe', '$env:LOCALAPPDATA\Programs\SteamDeckTools\FanControl.exe') },
        [ordered]@{ name = 'PerformanceOverlay'; candidates = @('PerformanceOverlay.exe', '$env:ProgramFiles\SteamDeckTools\PerformanceOverlay.exe', '$env:LOCALAPPDATA\Programs\SteamDeckTools\PerformanceOverlay.exe') }
    )

    $componentChecks = New-Object System.Collections.Generic.List[object]
    foreach ($component in $components) {
        $componentChecks.Add([ordered]@{
            name = [string]$component.name
            ready = Test-CommandOrPath -Candidates @($component.candidates)
        })
    }

    return [ordered]@{
        name = 'Steam Deck Tools'
        ready = (@(@($componentChecks.ToArray()) | Where-Object { -not $_.ready }).Count -eq 0)
        components = @($componentChecks.ToArray())
    }
}

$settings = $null
if (Test-Path $SettingsPath) {
    $settings = Read-SteamDeckJsonFile -Path $SettingsPath
}
$steamInputAudit = Get-SteamDeckSteamInputConflictAudit -Settings $settings

$checks = @(
    [ordered]@{ name = 'Steam'; ready = Test-CommandOrPath -Candidates @('steam.exe', '${env:ProgramFiles(x86)}\Steam\steam.exe', '$env:ProgramFiles\Steam\steam.exe') },
    [ordered]@{ name = 'Playnite'; ready = Test-CommandOrPath -Candidates @('$env:LOCALAPPDATA\Playnite\Playnite.FullscreenApp.exe', '$env:ProgramFiles\Playnite\Playnite.FullscreenApp.exe') },
    (Get-SteamDeckToolsReadiness),
    $steamInputAudit,
    [ordered]@{ name = 'RTSS'; ready = Test-CommandOrPath -Candidates @('RTSS.exe', '${env:ProgramFiles(x86)}\RivaTuner Statistics Server\RTSS.exe') },
    [ordered]@{ name = 'AMD Adrenalin'; ready = Test-CommandOrPath -Candidates @('$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe', '$env:ProgramFiles\AMD\CNext\CNext\AMDRSServ.exe') },
    [ordered]@{ name = 'CRU'; ready = Test-CommandOrPath -Candidates @('CRU.exe', '$env:ProgramFiles\Custom Resolution Utility\CRU.exe', '$env:LOCALAPPDATA\Programs\Custom Resolution Utility\CRU.exe') },
    [ordered]@{ name = 'SoundSwitch'; ready = Test-CommandOrPath -Candidates @('SoundSwitch.exe') },
    [ordered]@{ name = 'ModeWatcher'; ready = Test-Path (Join-Path (Split-Path -Parent $PSCommandPath) 'ModeWatcher.ps1') }
)

[ordered]@{
    settingsPath = $SettingsPath
    checks = @($checks)
    readyCount = @($checks | Where-Object { $_.ready }).Count
    totalCount = @($checks).Count
} | ConvertTo-Json -Depth 8
