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

function Read-SteamDeckJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    return (Get-Content -Path $Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop)
}

function ConvertTo-SteamDeckHashtable {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-SteamDeckHashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string]) -and -not ($InputObject -is [pscustomobject])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += @(ConvertTo-SteamDeckHashtable -InputObject $item)
        }
        return ,@($items)
    }

    if ($InputObject -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-SteamDeckHashtable -InputObject $property.Value
        }
        return $result
    }

    return $InputObject
}

function ConvertTo-SteamDeckObjectGraph {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-SteamDeckObjectGraph -InputObject $InputObject[$key]
        }
        return [pscustomobject]$result
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string]) -and -not ($InputObject -is [pscustomobject])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += @(ConvertTo-SteamDeckObjectGraph -InputObject $item)
        }
        return ,@($items)
    }

    if ($InputObject -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-SteamDeckObjectGraph -InputObject $property.Value
        }
        return [pscustomobject]$result
    }

    return $InputObject
}

function Get-SteamDeckSettingsArray {
    param($Value)

    if ($null -eq $Value) { return @() }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]) -and -not ($Value -is [pscustomobject])) {
        return @($Value)
    }
    return @($Value)
}

function Get-SteamDeckSettingMember {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function ConvertTo-SteamDeckBool {
    param($Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim()
    return @('1', 'true', 'yes', 'y', 'sim', 'on') -contains $text.ToLowerInvariant()
}

function Resolve-SteamDeckDisplayMode {
    param(
        [AllowNull()]$Settings,
        [string]$Default = 'extend'
    )

    $mode = ([string](Get-SteamDeckSettingMember -Object $Settings -Name 'displayMode' -Default $Default)).Trim().ToLowerInvariant()
    if (@('extend', 'internal', 'external', 'clone') -notcontains $mode) {
        $mode = $Default
    }

    $internalDisplay = Get-SteamDeckSettingMember -Object $Settings -Name 'internalDisplay' -Default $null
    $internalPrimary = ConvertTo-SteamDeckBool (Get-SteamDeckSettingMember -Object $internalDisplay -Name 'primary' -Default $false)
    if ($internalPrimary -and $mode -eq 'external') {
        return 'extend'
    }

    return $mode
}

function Resolve-SteamDeckDisplaySwitchArgument {
    param(
        [AllowNull()]$Settings,
        [string]$Default = 'extend'
    )

    $mode = Resolve-SteamDeckDisplayMode -Settings $Settings -Default $Default
    switch ($mode) {
        'internal' { return '/internal' }
        'external' { return '/external' }
        'clone' { return '/clone' }
        default { return '/extend' }
    }
}

function Get-SteamDeckSteamInputConflictAudit {
    param([AllowNull()]$Settings)

    $steamInput = Get-SteamDeckSettingMember -Object $Settings -Name 'steamInput' -Default $null
    $activeStack = ([string](Get-SteamDeckSettingMember -Object $steamInput -Name 'activeStack' -Default 'steamdeck-tools')).Trim()
    if ([string]::IsNullOrWhiteSpace($activeStack)) { $activeStack = 'steamdeck-tools' }

    $policy = ([string](Get-SteamDeckSettingMember -Object $steamInput -Name 'desktopLayoutConflictPolicy' -Default 'manual-disable')).Trim()
    if ([string]::IsNullOrWhiteSpace($policy)) { $policy = 'manual-disable' }

    $recommendedAction = [string](Get-SteamDeckSettingMember -Object $steamInput -Name 'recommendedAction' -Default 'Steam > Settings > Controller > Desktop Layout: disable/clear layout when Steam Deck Tools, Handheld Companion or GlosSI manages desktop input.')
    if ([string]::IsNullOrWhiteSpace($recommendedAction)) {
        $recommendedAction = 'Steam > Settings > Controller > Desktop Layout: disable/clear layout when Steam Deck Tools, Handheld Companion or GlosSI manages desktop input.'
    }

    return [ordered]@{
        name = 'Steam Input Desktop Layout'
        ready = $true
        status = 'manual-review'
        activeStack = $activeStack
        policy = $policy
        recommendedAction = $recommendedAction
        reason = 'Desktop Layout ativo no Steam pode duplicar input quando outro stack controla mouse/controle no Windows.'
    }
}
