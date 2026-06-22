function Normalize-SteamDeckPathSegment {
    <#
    .SYNOPSIS
        Garante segmento escalar para Join-Path (evita ChildPath como Object[] no PS 5.1).
    #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $arr = @($Value)
    if ($arr.Count -eq 0) { return '' }
    $first = $arr[0]
    if ($null -eq $first) { return '' }
    return ([string]$first).Trim()
}

function Join-SteamDeckSystemChild {
    param([Parameter(Mandatory = $true)][string]$RelativeChild)
    $root = Normalize-SteamDeckPathSegment -Value $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'SteamDeck.Common: variavel de ambiente SystemRoot vazia ou invalida; nao e possivel montar caminho do sistema. Verifique o ambiente Windows e execute novamente.'
    }
    return (Join-Path -Path $root -ChildPath $RelativeChild)
}

function Get-SteamDeckUserHomePath {
    $up = Normalize-SteamDeckPathSegment -Value $env:USERPROFILE
    if (-not [string]::IsNullOrWhiteSpace($up)) { return $up }
    $homePath = Normalize-SteamDeckPathSegment -Value $env:HOME
    if (-not [string]::IsNullOrWhiteSpace($homePath)) { return $homePath }
    $hd = Normalize-SteamDeckPathSegment -Value $env:HOMEDRIVE
    $hp = Normalize-SteamDeckPathSegment -Value $env:HOMEPATH
    if (-not [string]::IsNullOrWhiteSpace($hd) -and -not [string]::IsNullOrWhiteSpace($hp)) {
        return ($hd + $hp)
    }
    $la = Normalize-SteamDeckPathSegment -Value $env:LOCALAPPDATA
    if (-not [string]::IsNullOrWhiteSpace($la)) { return $la }
    $tmp = Normalize-SteamDeckPathSegment -Value $env:TEMP
    if (-not [string]::IsNullOrWhiteSpace($tmp)) { return $tmp }
    $tmp2 = Normalize-SteamDeckPathSegment -Value $env:TMP
    if (-not [string]::IsNullOrWhiteSpace($tmp2)) { return $tmp2 }
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
    try {
        return (Join-SteamDeckSystemChild -RelativeChild 'System32\WindowsPowerShell\v1.0\powershell.exe')
    } catch {
        return 'powershell.exe'
    }
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

function Get-SteamDeckModeWatcherDecision {
    <#
    .SYNOPSIS
        Logica pura de debounce/cooldown do ModeWatcher: dada a deteccao atual e o estado,
        decide se um novo modo deve ser aplicado. Sem efeitos colaterais (testavel).
    #>
    param(
        [AllowNull()][string]$DetectedMode,
        [AllowNull()]$State,
        [int]$StableSamples = 2,
        [int]$CooldownSeconds = 5,
        [Nullable[datetime]]$Now = $null
    )

    if ($null -eq $Now) { $Now = Get-Date }

    $s = @{ lastCandidateMode = $null; candidateCount = 0; lastAppliedMode = $null; lastAppliedAt = $null }
    if ($null -ne $State) {
        foreach ($k in @('lastCandidateMode', 'candidateCount', 'lastAppliedMode', 'lastAppliedAt')) {
            $v = Get-SteamDeckSettingMember -Object $State -Name $k -Default $null
            if ($null -ne $v) { $s[$k] = $v }
        }
    }

    # Debounce: conta amostras consecutivas do mesmo modo; troca de modo reinicia a contagem.
    if ([string]$s['lastCandidateMode'] -eq [string]$DetectedMode) {
        $s['candidateCount'] = [int]$s['candidateCount'] + 1
    } else {
        $s['lastCandidateMode'] = $DetectedMode
        $s['candidateCount'] = 1
    }

    # Cooldown: evita reaplicar logo apos a ultima aplicacao.
    $cooldownReady = $true
    if ($s['lastAppliedAt']) {
        try {
            $cooldownReady = (($Now - [datetime]$s['lastAppliedAt']).TotalSeconds -ge $CooldownSeconds)
        } catch {
            $cooldownReady = $true
        }
    }

    $shouldApply = (
        ([int]$s['candidateCount'] -ge $StableSamples) -and
        $cooldownReady -and
        ([string]$s['lastAppliedMode'] -ne [string]$DetectedMode) -and
        (-not [string]::IsNullOrWhiteSpace([string]$DetectedMode))
    )

    return [ordered]@{
        State = $s
        ShouldApply = [bool]$shouldApply
        ApplyMode = $(if ($shouldApply) { [string]$DetectedMode } else { '' })
        CooldownReady = [bool]$cooldownReady
    }
}
