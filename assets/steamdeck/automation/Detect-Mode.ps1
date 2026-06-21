param(
    [string]$SettingsPath,
    [string]$MockStatePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSCommandPath) 'SteamDeck.Common.ps1')

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Get-SteamDeckSettingsPath
}

function Normalize-DisplayValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text -replace "`0", ''
    $text = $text.Trim()
    $text = [regex]::Replace($text, '\s+', ' ')
    return $text.ToLowerInvariant()
}

function ConvertTo-DisplayBool {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    return @('1', 'true', 'yes', 'y', 'sim', 'on') -contains $text
}

function ConvertTo-DisplayRecord {
    param($Display)

    if ($null -eq $Display) { return $null }

    $manufacturer = if ($Display.PSObject.Properties.Name -contains 'manufacturer') { [string]$Display.manufacturer } else { '' }
    $product = if ($Display.PSObject.Properties.Name -contains 'product') { [string]$Display.product } else { '' }
    $serial = if ($Display.PSObject.Properties.Name -contains 'serial') { [string]$Display.serial } else { '' }
    $instanceName = if ($Display.PSObject.Properties.Name -contains 'instanceName') { [string]$Display.instanceName } else { '' }
    $name = if ($Display.PSObject.Properties.Name -contains 'name') { [string]$Display.name } else { $product }
    $isActive = $true
    $isPrimary = $false
    if ($Display.PSObject.Properties.Name -contains 'isActive') { $isActive = [bool]$Display.isActive }
    if ($Display.PSObject.Properties.Name -contains 'isPrimary') { $isPrimary = [bool]$Display.isPrimary }

    return [ordered]@{
        manufacturer = $manufacturer
        product = $product
        serial = $serial
        instanceName = $instanceName
        name = $name
        manufacturerNormalized = Normalize-DisplayValue $manufacturer
        productNormalized = Normalize-DisplayValue $product
        serialNormalized = Normalize-DisplayValue $serial
        instanceNormalized = Normalize-DisplayValue $instanceName
        nameNormalized = Normalize-DisplayValue $name
        isActive = $isActive
        isPrimary = $isPrimary
    }
}

function Get-SettingsObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-SteamDeckFileExists -Path $Path -Description 'Settings file'
    return (Get-Content -Path $Path -Raw | ConvertFrom-Json)
}

function Get-SettingsArray {
    param($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IDictionary]) {
        if (@($Value.Keys).Count -eq 0) { return @() }
        return @($Value)
    }
    if ($Value -is [pscustomobject]) {
        if (@($Value.PSObject.Properties).Count -eq 0) { return @() }
        return @($Value)
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]) -and -not ($Value -is [pscustomobject])) {
        return @($Value)
    }
    return @($Value)
}

function Get-SessionProfiles {
    param($Settings)

    $defaults = [ordered]@{
        HANDHELD = 'game-handheld'
        DOCKED_TV = 'game-docked'
        DOCKED_MONITOR = 'desktop'
    }

    if ($Settings.PSObject.Properties.Name -notcontains 'sessionProfiles') {
        return [pscustomobject]$defaults
    }

    foreach ($property in $Settings.sessionProfiles.PSObject.Properties) {
        $defaults[$property.Name] = [string]$property.Value
    }

    return [pscustomobject]$defaults
}

function Get-DisplayClassification {
    param($Settings)

    $defaults = [ordered]@{
        unknownExternalMode = 'UNCLASSIFIED_EXTERNAL'
        uiFallbackMode = 'DOCKED_MONITOR'
    }

    if ($Settings.PSObject.Properties.Name -notcontains 'displayClassification') {
        return [pscustomobject]$defaults
    }

    foreach ($property in $Settings.displayClassification.PSObject.Properties) {
        $defaults[$property.Name] = [string]$property.Value
    }

    return [pscustomobject]$defaults
}

function Get-LiveState {
    param($Settings)

    $displays = @()
    try {
        foreach ($monitor in @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop)) {
            $manufacturer = -join ($monitor.ManufacturerName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
            $product = -join ($monitor.UserFriendlyName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
            $serial = -join ($monitor.SerialNumberID | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
            $displays += @([ordered]@{
                manufacturer = $manufacturer
                product = $product
                serial = $serial
                instanceName = $monitor.InstanceName
                name = $product
                isActive = $true
                isPrimary = $false
            })
        }
    } catch {
        $displays = @()
    }

    $internalCriteria = ConvertTo-DisplayRecord -Display $Settings.internalDisplay
    $normalizedDisplays = @($displays | ForEach-Object { ConvertTo-DisplayRecord -Display $_ })
    $internalDisplay = $normalizedDisplays | Where-Object {
        $_.manufacturerNormalized -eq $internalCriteria.manufacturerNormalized -and
        $_.productNormalized -eq $internalCriteria.productNormalized
    } | Select-Object -First 1

    $externalDisplays = @($normalizedDisplays | Where-Object {
        -not ($internalDisplay -and $_.instanceNormalized -eq $internalDisplay.instanceNormalized)
    })

    $onAcPower = $false
    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if ($battery) {
            $onAcPower = ($battery.BatteryStatus -eq 2)
        }
    } catch {
        $onAcPower = $false
    }

    return [ordered]@{
        battery = [ordered]@{
            onAcPower = $onAcPower
        }
        internalDisplay = $internalDisplay
        externalDisplays = @($externalDisplays)
    }
}

function Resolve-PreferredDisplay {
    param(
        [Parameter(Mandatory = $true)][object[]]$Displays,
        [System.Collections.Generic.List[string]]$Warnings
    )

    if ($Displays.Count -eq 0) { return $null }

    $primary = @($Displays | Where-Object { $_.isPrimary }) | Select-Object -First 1
    if ($primary) { return $primary }

    if (($Displays.Count -gt 1) -and $Warnings) {
        $Warnings.Add('Multiple candidate displays found without a primary flag. Falling back to the first active display.')
    }

    return $Displays[0]
}

function Resolve-PreferredDisplayMatch {
    param(
        [Parameter(Mandatory = $true)][object[]]$Matches,
        [System.Collections.Generic.List[string]]$Warnings
    )

    if ($Matches.Count -eq 0) { return $null }

    $primaryConfigMatches = @($Matches | Where-Object {
        $_.config -and ($_.config.PSObject.Properties.Name -contains 'primary') -and (ConvertTo-DisplayBool $_.config.primary)
    })

    $candidateMatches = if ($primaryConfigMatches.Count -gt 0) { $primaryConfigMatches } else { $Matches }
    $selectedDisplay = Resolve-PreferredDisplay -Displays @($candidateMatches.display) -Warnings $Warnings
    if (-not $selectedDisplay) { return $candidateMatches[0] }

    return ($candidateMatches | Where-Object { $_.display.instanceNormalized -eq $selectedDisplay.instanceNormalized } | Select-Object -First 1)
}

function Test-DisplayMatch {
    param(
        [Parameter(Mandatory = $true)]$Display,
        [Parameter(Mandatory = $true)]$Matcher,
        [switch]$RequireSerial
    )

    $manufacturerMatch = $Display.manufacturerNormalized -eq (Normalize-DisplayValue $Matcher.manufacturer)
    $productMatch = $Display.productNormalized -eq (Normalize-DisplayValue $Matcher.product)
    if (-not ($manufacturerMatch -and $productMatch)) { return $false }

    if ($RequireSerial -and ($Matcher.PSObject.Properties.Name -contains 'serial')) {
        $serialValue = Normalize-DisplayValue $Matcher.serial
        if (-not [string]::IsNullOrWhiteSpace($serialValue) -and $Display.serialNormalized -ne $serialValue) {
            return $false
        }
    }

    if ($Matcher.PSObject.Properties.Name -contains 'namePattern') {
        $pattern = Normalize-DisplayValue $Matcher.namePattern
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $Display.nameNormalized -notmatch [regex]::Escape($pattern)) {
            return $false
        }
    }

    return $true
}

$settings = Get-SettingsObject -Path $SettingsPath
$monitorProfiles = @(Get-SettingsArray -Value $settings.monitorProfiles)
$monitorFamilies = @(Get-SettingsArray -Value $settings.monitorFamilies)
$sessionProfiles = Get-SessionProfiles -Settings $settings
$displayClassification = Get-DisplayClassification -Settings $settings
$state = if ($MockStatePath) {
    Get-Content -Path $MockStatePath -Raw | ConvertFrom-Json
} else {
    Get-LiveState -Settings $settings
}

$warnings = New-Object System.Collections.Generic.List[string]
$internalDisplay = ConvertTo-DisplayRecord -Display $state.internalDisplay
$externalDisplays = @()
foreach ($display in @($state.externalDisplays)) {
    $normalized = ConvertTo-DisplayRecord -Display $display
    if ($normalized -and $normalized.isActive) {
        $externalDisplays += @($normalized)
    }
}

$mode = 'TRANSITIONING'
$matchedBy = 'none'
$matchedConfig = $null
$selectedDisplay = $null

if ($externalDisplays.Count -eq 0) {
    $mode = 'HANDHELD'
    $matchedBy = 'internal-display'
} else {
    $profileMatches = @()
    foreach ($profile in $monitorProfiles) {
        $matchedDisplays = @($externalDisplays | Where-Object { Test-DisplayMatch -Display $_ -Matcher $profile -RequireSerial })
        foreach ($matchedDisplay in $matchedDisplays) {
            $profileMatches += @([pscustomobject]@{
                display = $matchedDisplay
                config = $profile
                matchedBy = 'profile'
            })
        }
    }

    if ($profileMatches.Count -gt 0) {
        $selectedMatch = Resolve-PreferredDisplayMatch -Matches @($profileMatches) -Warnings $warnings
        $selectedDisplay = $selectedMatch.display
        $matchedConfig = $selectedMatch.config
        $mode = if ($matchedConfig.PSObject.Properties.Name -contains 'mode') { [string]$matchedConfig.mode } else { 'DOCKED_MONITOR' }
        $matchedBy = 'profile'
    } else {
        $familyMatches = @()
        foreach ($family in $monitorFamilies) {
            $matchedDisplays = @($externalDisplays | Where-Object { Test-DisplayMatch -Display $_ -Matcher $family })
            foreach ($matchedDisplay in $matchedDisplays) {
                $familyMatches += @([pscustomobject]@{
                    display = $matchedDisplay
                    config = $family
                    matchedBy = 'family'
                })
            }
        }

        if ($familyMatches.Count -gt 0) {
            $selectedMatch = Resolve-PreferredDisplayMatch -Matches @($familyMatches) -Warnings $warnings
            $selectedDisplay = $selectedMatch.display
            $matchedConfig = $selectedMatch.config
            $mode = if ($matchedConfig.PSObject.Properties.Name -contains 'mode') { [string]$matchedConfig.mode } else { 'DOCKED_MONITOR' }
            $matchedBy = 'family'
        } else {
            $selectedDisplay = Resolve-PreferredDisplay -Displays $externalDisplays -Warnings $warnings
            $matchedConfig = $settings.genericExternal
            $unknownMode = if ($displayClassification.PSObject.Properties.Name -contains 'unknownExternalMode') { [string]$displayClassification.unknownExternalMode } else { 'UNCLASSIFIED_EXTERNAL' }
            if ($unknownMode -eq 'UNCLASSIFIED_EXTERNAL') {
                $fallbackMode = if ($displayClassification.PSObject.Properties.Name -contains 'uiFallbackMode') { [string]$displayClassification.uiFallbackMode } else { 'DOCKED_MONITOR' }
                $mode = 'UNCLASSIFIED_EXTERNAL'
                $matchedBy = 'unclassifiedExternal'
                $matchedConfig = [ordered]@{
                    mode = $fallbackMode
                    resolutionPolicy = if ($settings.genericExternal.PSObject.Properties.Name -contains 'resolutionPolicy') { [string]$settings.genericExternal.resolutionPolicy } else { 'desktop-safe' }
                    layout = if ($settings.genericExternal.PSObject.Properties.Name -contains 'layout') { [string]$settings.genericExternal.layout } else { 'external-unclassified' }
                    classificationRequired = $true
                }
                $warnings.Add('External display not recognized. UI classification required; fallback Desktop/Dev is used until classified.')
            } else {
                $mode = if ($matchedConfig.PSObject.Properties.Name -contains 'mode') { [string]$matchedConfig.mode } else { 'DOCKED_TV' }
                $matchedBy = 'genericExternal'
                $warnings.Add('External display not recognized. Generic fallback applied.')
            }
        }
    }
}

$sessionProfile = switch ($mode) {
    'HANDHELD' { [string]$sessionProfiles.HANDHELD }
    'DOCKED_TV' { [string]$sessionProfiles.DOCKED_TV }
    'DOCKED_MONITOR' { [string]$sessionProfiles.DOCKED_MONITOR }
    'UNCLASSIFIED_EXTERNAL' { [string]$sessionProfiles.DOCKED_MONITOR }
    default { 'desktop' }
}

$effectiveMode = if ($mode -eq 'UNCLASSIFIED_EXTERNAL') {
    if ($matchedConfig -and ($matchedConfig.PSObject.Properties.Name -contains 'mode')) { [string]$matchedConfig.mode } else { 'DOCKED_MONITOR' }
} else {
    $mode
}

[ordered]@{
    mode = $mode
    effectiveMode = $effectiveMode
    sessionProfile = $sessionProfile
    matchedBy = $matchedBy
    matchedConfig = $matchedConfig
    internalDisplay = $internalDisplay
    externalDisplays = @($externalDisplays)
    selectedDisplay = $selectedDisplay
    externalDisplayCount = $externalDisplays.Count
    onAcPower = [bool]$state.battery.onAcPower
    warnings = @($warnings.ToArray())
} | ConvertTo-Json -Depth 8
