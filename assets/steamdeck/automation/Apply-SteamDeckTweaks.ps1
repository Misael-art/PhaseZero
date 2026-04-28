param(
    [string]$SettingsPath,
    [ValidateSet('HANDHELD', 'DOCKED_TV', 'DOCKED_MONITOR')][string]$Mode = 'HANDHELD',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSCommandPath) 'SteamDeck.Common.ps1')

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Get-SteamDeckSettingsPath
}

function Write-TweaksLog {
    param([string]$Message)

    $logPath = Get-SteamDeckAutomationLogPath
    Ensure-SteamDeckParentDirectory -Path $logPath
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [TWEAKS] {1}" -f (Get-Date), $Message
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

function Test-SteamDeckTweaksAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
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

function Resolve-ToolCandidate {
    param([string[]]$Candidates)

    foreach ($candidate in @($Candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $expanded = $ExecutionContext.InvokeCommand.ExpandString($candidate)
        if (Test-Path $expanded) { return $expanded }
        $command = Get-Command $expanded -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    return ''
}

function Set-RegistryDwordBestEffort {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][int]$Value,
        [bool]$NeedsAdmin = $false
    )

    if ($NeedsAdmin -and -not (Test-SteamDeckTweaksAdmin)) {
        Write-TweaksLog "Admin required for registry value $Path\$Name; skipped."
        return $false
    }

    try {
        if (-not (Test-Path $Path)) { $null = New-Item -Path $Path -Force }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
        return $true
    } catch {
        Write-TweaksLog "Registry value failed ${Path}\${Name}: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-PowerCfgBestEffort {
    param([string[]]$Arguments)

    $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (-not (Test-Path $powercfg)) { $powercfg = 'powercfg.exe' }
    try {
        & $powercfg @Arguments | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-TweaksLog "powercfg failed: $(@($Arguments) -join ' ') :: $($_.Exception.Message)"
        return $false
    }
}

function Start-ToolIfPresent {
    param(
        [string]$Path,
        [string]$ProcessName
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
        if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) { return $true }
    }
    try {
        Start-Process -FilePath $Path -WindowStyle Minimized | Out-Null
        return $true
    } catch {
        Write-TweaksLog "Could not start ${Path}: $($_.Exception.Message)"
        return $false
    }
}

Assert-SteamDeckFileExists -Path $SettingsPath -Description 'Settings file'
$settings = Read-SteamDeckJsonFile -Path $SettingsPath
$tweaks = if ($settings.PSObject.Properties.Name -contains 'steamdeckTweaks') { $settings.steamdeckTweaks } else { $null }

$actions = New-Object System.Collections.Generic.List[string]
$results = New-Object System.Collections.Generic.List[object]
$isAdmin = Test-SteamDeckTweaksAdmin

if ($Mode -ne 'HANDHELD') {
    $actions.Add('handheld-tweaks-skipped')
    [ordered]@{
        mode = $Mode
        profile = 'not-handheld'
        dryRun = [bool]$DryRun
        isAdmin = [bool]$isAdmin
        actions = @($actions.ToArray())
        results = @()
    } | ConvertTo-Json -Depth 8
    return
}

$hibernateMode = [string](Get-SettingValue -Object $tweaks -Name 'hibernation' -Default 'enabled')
$realtimeUtc = [bool](Get-SettingValue -Object $tweaks -Name 'realtimeUtc' -Default $true)
$requireLoginAfterSleep = [bool](Get-SettingValue -Object $tweaks -Name 'requireLoginAfterSleep' -Default $false)
$gameBar = [string](Get-SettingValue -Object $tweaks -Name 'gameBar' -Default 'enabled')
$touchKeyboard = [string](Get-SettingValue -Object $tweaks -Name 'touchKeyboard' -Default 'enabled')
$toolSettings = if ($settings.PSObject.Properties.Name -contains 'steamdeckTools') { $settings.steamdeckTools } else { $null }
$autoStartOnHandheld = @(Get-SettingValue -Object $toolSettings -Name 'autoStartOnHandheld' -Default @('RTSS', 'Steam Deck Tools'))

function Test-ToolAutoStart {
    param([string]$Name)

    foreach ($item in @($autoStartOnHandheld)) {
        if ([string]::Equals([string]$item, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

if ($hibernateMode -eq 'enabled') {
    $actions.Add('powercfg-hibernate-enabled')
    $ok = $true
    if (-not $DryRun) { $ok = Invoke-PowerCfgBestEffort -Arguments @('/hibernate', 'on') }
    $results.Add([ordered]@{ action = 'powercfg-hibernate-enabled'; ok = [bool]$ok; requiresAdmin = $true })
}

if ($realtimeUtc) {
    $actions.Add('windows-clock-utc')
    $ok = $true
    if (-not $DryRun) {
        $ok = Set-RegistryDwordBestEffort -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name 'RealTimeIsUniversal' -Value 1 -NeedsAdmin $true
    }
    $results.Add([ordered]@{ action = 'windows-clock-utc'; ok = [bool]$ok; requiresAdmin = $true })
}

if (-not $requireLoginAfterSleep) {
    $actions.Add('login-after-sleep-disabled')
    $ok = $true
    if (-not $DryRun) {
        $ok = (Invoke-PowerCfgBestEffort -Arguments @('/SETACVALUEINDEX', 'SCHEME_CURRENT', 'SUB_NONE', 'CONSOLELOCK', '0')) -and
              (Invoke-PowerCfgBestEffort -Arguments @('/SETDCVALUEINDEX', 'SCHEME_CURRENT', 'SUB_NONE', 'CONSOLELOCK', '0')) -and
              (Invoke-PowerCfgBestEffort -Arguments @('/SETACTIVE', 'SCHEME_CURRENT'))
    }
    $results.Add([ordered]@{ action = 'login-after-sleep-disabled'; ok = [bool]$ok; requiresAdmin = $false })
}

if ($gameBar -eq 'enabled') {
    $actions.Add('ms-gamebar-enabled')
    $ok = $true
    if (-not $DryRun) {
        $ok = (Set-RegistryDwordBestEffort -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 1) -and
              (Set-RegistryDwordBestEffort -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'UseNexusForGameBarEnabled' -Value 1) -and
              (Set-RegistryDwordBestEffort -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 1)
    }
    $results.Add([ordered]@{ action = 'ms-gamebar-enabled'; ok = [bool]$ok; requiresAdmin = $false })
}

if ($touchKeyboard -eq 'enabled') {
    $actions.Add('touch-keyboard-enabled')
    $ok = $true
    if (-not $DryRun) {
        $ok = (Set-RegistryDwordBestEffort -Path 'HKCU:\Software\Microsoft\TabletTip\1.7' -Name 'EnableDesktopModeAutoInvoke' -Value 1) -and
              (Set-RegistryDwordBestEffort -Path 'HKCU:\Software\Microsoft\TabletTip\1.7' -Name 'TipbandDesiredVisibility' -Value 1)
    }
    $results.Add([ordered]@{ action = 'touch-keyboard-enabled'; ok = [bool]$ok; requiresAdmin = $false })
}

$toolSpecs = @(
    [ordered]@{
        key = 'rtss'
        name = 'RTSS'
        process = 'RTSS'
        autoStart = (Test-ToolAutoStart -Name 'RTSS')
        candidates = @('RTSS.exe', '${env:ProgramFiles(x86)}\RivaTuner Statistics Server\RTSS.exe')
    },
    [ordered]@{
        key = 'amd-adrenalin'
        name = 'AMD Adrenalin'
        process = 'RadeonSoftware'
        autoStart = $false
        candidates = @('$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe', '$env:ProgramFiles\AMD\CNext\CNext\AMDRSServ.exe')
    },
    [ordered]@{
        key = 'cru'
        name = 'CRU'
        process = 'CRU'
        autoStart = $false
        candidates = @('CRU.exe', '$env:ProgramFiles\Custom Resolution Utility\CRU.exe', '$env:LOCALAPPDATA\Programs\Custom Resolution Utility\CRU.exe')
    },
    [ordered]@{
        key = 'steam-deck-tools'
        name = 'Steam Deck Tools'
        autoStart = (Test-ToolAutoStart -Name 'Steam Deck Tools')
        components = @(
            [ordered]@{
                name = 'PowerControl'
                process = 'PowerControl'
                candidates = @('PowerControl.exe', '$env:ProgramFiles\SteamDeckTools\PowerControl.exe', '$env:LOCALAPPDATA\Programs\SteamDeckTools\PowerControl.exe')
            },
            [ordered]@{
                name = 'SteamController'
                process = 'SteamController'
                candidates = @('SteamController.exe', '$env:ProgramFiles\SteamDeckTools\SteamController.exe', '$env:LOCALAPPDATA\Programs\SteamDeckTools\SteamController.exe')
            },
            [ordered]@{
                name = 'PerformanceOverlay'
                process = 'PerformanceOverlay'
                candidates = @('PerformanceOverlay.exe', '$env:ProgramFiles\SteamDeckTools\PerformanceOverlay.exe', '$env:LOCALAPPDATA\Programs\SteamDeckTools\PerformanceOverlay.exe')
            }
        )
    }
)

foreach ($tool in $toolSpecs) {
    $action = "tooling-readiness-$($tool.key)"
    $actions.Add($action)
    if ($tool.Contains('components')) {
        $componentResults = New-Object System.Collections.Generic.List[object]
        $allReady = $true
        $anyStarted = $false
        foreach ($component in @($tool.components)) {
            $componentPath = Resolve-ToolCandidate -Candidates @($component.candidates)
            $componentReady = -not [string]::IsNullOrWhiteSpace($componentPath)
            if (-not $componentReady) { $allReady = $false }
            $componentStarted = $false
            if (-not $DryRun -and [bool]$tool.autoStart -and $componentReady) {
                $componentStarted = Start-ToolIfPresent -Path $componentPath -ProcessName ([string]$component.process)
                $anyStarted = ($anyStarted -or $componentStarted)
            }
            $componentResults.Add([ordered]@{
                name = [string]$component.name
                process = [string]$component.process
                ready = [bool]$componentReady
                path = $componentPath
                started = [bool]$componentStarted
            })
        }
        $results.Add([ordered]@{
            action = $action
            name = [string]$tool.name
            ready = [bool]$allReady
            path = ''
            started = [bool]$anyStarted
            components = @($componentResults.ToArray())
            requiresAdmin = $false
        })
        continue
    }

    $path = Resolve-ToolCandidate -Candidates @($tool.candidates)
    $started = $false
    if (-not $DryRun -and [bool]$tool.autoStart -and -not [string]::IsNullOrWhiteSpace($path)) {
        $started = Start-ToolIfPresent -Path $path -ProcessName ([string]$tool.process)
    }
    $results.Add([ordered]@{
        action = $action
        name = [string]$tool.name
        ready = -not [string]::IsNullOrWhiteSpace($path)
        path = $path
        started = [bool]$started
        requiresAdmin = $false
    })
}

if (-not $DryRun) {
    Write-TweaksLog "Handheld tweaks applied. Actions=$(@($actions.ToArray()) -join ', ')"
}

[ordered]@{
    mode = $Mode
    profile = 'handheld'
    dryRun = [bool]$DryRun
    isAdmin = [bool]$isAdmin
    actions = @($actions.ToArray())
    results = @($results.ToArray())
} | ConvertTo-Json -Depth 8
