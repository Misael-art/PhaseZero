param(
    [string]$SettingsPath,
    [string]$DetectionPath,
    [ValidateSet('MonitorDev', 'TvGame')][string]$Choice,
    [switch]$DryRun
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

function Normalize-DisplayText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value) -replace "`0", ''
    $text = $text.Trim()
    $text = [regex]::Replace($text, '\s+', ' ')
    return $text
}

function Get-MapValue {
    param(
        [hashtable]$Map,
        [string]$Name
    )

    if ($Map -and $Map.ContainsKey($Name)) { return $Map[$Name] }
    return $null
}

Assert-SteamDeckFileExists -Path $SettingsPath -Description 'Settings file'
Assert-SteamDeckFileExists -Path $DetectionPath -Description 'Detection file'

$settings = ConvertTo-SteamDeckHashtable -InputObject (Read-SteamDeckJsonFile -Path $SettingsPath)
$detection = ConvertTo-SteamDeckHashtable -InputObject (Read-SteamDeckJsonFile -Path $DetectionPath)
$display = Get-MapValue -Map $detection -Name 'selectedDisplay'
if (-not ($display -is [hashtable])) {
    throw 'No selected display available to classify.'
}

$manufacturer = Normalize-DisplayText (Get-MapValue -Map $display -Name 'manufacturer')
$product = Normalize-DisplayText (Get-MapValue -Map $display -Name 'product')
$serial = Normalize-DisplayText (Get-MapValue -Map $display -Name 'serial')

if ([string]::IsNullOrWhiteSpace($manufacturer) -or [string]::IsNullOrWhiteSpace($product)) {
    throw 'Display classification requires manufacturer and product.'
}

$mode = 'DOCKED_MONITOR'
$layout = 'external-monitor-dev'
$resolutionPolicy = 'native-prefer-1440p-else-1080p'
if ($Choice -eq 'TvGame') {
    $mode = 'DOCKED_TV'
    $layout = 'external-tv-game'
    $resolutionPolicy = '1920x1080-safe'
}

$entry = [ordered]@{
    manufacturer = $manufacturer
    product = $product
    namePattern = $product
    mode = $mode
    layout = $layout
    resolutionPolicy = $resolutionPolicy
    primary = $true
    classifiedAt = (Get-Date).ToString('o')
    classifiedBy = 'bootstrap-ui'
}
if (-not [string]::IsNullOrWhiteSpace($serial)) {
    $entry['sampleSerial'] = $serial
}

if (-not $settings.ContainsKey('monitorFamilies')) { $settings['monitorFamilies'] = @() }
$families = @($settings['monitorFamilies'])
$nextFamilies = @()
$exists = $false
foreach ($family in $families) {
    $familyMap = ConvertTo-SteamDeckHashtable -InputObject $family
    $sameManufacturer = (Normalize-DisplayText (Get-MapValue -Map $familyMap -Name 'manufacturer')) -ieq $manufacturer
    $sameProduct = (Normalize-DisplayText (Get-MapValue -Map $familyMap -Name 'product')) -ieq $product
    if ($sameManufacturer -and $sameProduct) {
        $familyMap['mode'] = $mode
        $familyMap['layout'] = $layout
        $familyMap['resolutionPolicy'] = $resolutionPolicy
        $familyMap['primary'] = $true
        $familyMap['classifiedAt'] = $entry['classifiedAt']
        $familyMap['classifiedBy'] = 'bootstrap-ui'
        $exists = $true
    }
    $nextFamilies += @($familyMap)
}

if (-not $exists) {
    $nextFamilies += @($entry)
}
$settings['monitorFamilies'] = @($nextFamilies)

if (-not $DryRun) {
    Write-SteamDeckJsonFile -Path $SettingsPath -Value (ConvertTo-SteamDeckObjectGraph -InputObject $settings) -Depth 12
}

[ordered]@{
    choice = $Choice
    target = 'monitorFamilies'
    mode = $mode
    layout = $layout
    resolutionPolicy = $resolutionPolicy
    manufacturer = $manufacturer
    product = $product
    dryRun = [bool]$DryRun
} | ConvertTo-Json -Depth 8
