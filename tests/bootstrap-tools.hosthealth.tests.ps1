$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

. $scriptPath -BootstrapUiLibraryMode

function Assert-Equals {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message`nExpected=$Expected`nActual=$Actual" }
}

function Assert-Contains {
    param([string[]]$Collection, $Item, [string]$Message)
    if (@($Collection) -notcontains $Item) {
        throw "$Message`nExpected to contain: $Item`nActual: $((@($Collection)) -join ', ')"
    }
}

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-HostHealthModesList {
    $modes = Get-BootstrapHostHealthModes
    foreach ($m in @('off', 'conservador', 'equilibrado', 'agressivo')) {
        Assert-Contains -Collection $modes -Item $m -Message "Mode $m must be available."
    }
}

function Test-NormalizeRejectsUnknown {
    $threw = $false
    try { Normalize-BootstrapHostHealthMode -Mode 'paranoia' } catch { $threw = $true }
    Assert-True -Condition $threw -Message 'Normalize must throw on unknown mode.'
}

function Test-NormalizeNullReturnsNull {
    $result = Normalize-BootstrapHostHealthMode -Mode $null
    Assert-True -Condition ($null -eq $result) -Message 'Null mode must normalize to null.'
}

function Test-PolicyOffReturnsEmptyAppx {
    $policy = Get-BootstrapHostHealthPolicy -Mode 'off'
    Assert-Equals -Actual $policy.Mode -Expected 'off' -Message 'Policy mode must be off.'
    Assert-Equals -Actual (@($policy.AppxRemove)).Count -Expected 0 -Message 'off mode must not remove apps.'
    Assert-Equals -Actual (@($policy.ServiceAdjustments)).Count -Expected 0 -Message 'off mode must not adjust services.'
}

function Test-PolicyConservadorMinimal {
    $policy = Get-BootstrapHostHealthPolicy -Mode 'conservador'
    Assert-Equals -Actual (@($policy.AppxRemove)).Count -Expected 0 -Message 'conservador must NOT remove appx.'
    Assert-Equals -Actual (@($policy.ScheduledTasksDisable)).Count -Expected 0 -Message 'conservador must NOT disable tasks.'
}

function Test-PolicyEquilibradoRemovesAppxNotPCManager {
    $policy = Get-BootstrapHostHealthPolicy -Mode 'equilibrado'
    Assert-Contains -Collection $policy.AppxRemove -Item 'Microsoft.GetHelp' -Message 'equilibrado must remove GetHelp.'
    Assert-Contains -Collection $policy.AppxRemove -Item 'MSTeams' -Message 'equilibrado must remove MSTeams.'
    Assert-True -Condition ((@($policy.AppxRemove)) -notcontains 'Microsoft.MicrosoftPCManager') -Message 'equilibrado must NOT remove PCManager.'
}

function Test-PolicyAgressivoIncludesPCManagerAndService {
    $policy = Get-BootstrapHostHealthPolicy -Mode 'agressivo'
    Assert-Contains -Collection $policy.AppxRemove -Item 'Microsoft.MicrosoftPCManager' -Message 'agressivo must remove PCManager.'
    Assert-Contains -Collection $policy.AppxRemove -Item 'Microsoft.BingSearch' -Message 'agressivo must remove BingSearch.'
    Assert-Equals -Actual (@($policy.ServiceAdjustments)).Count -Expected 1 -Message 'agressivo must adjust 1 service.'
    Assert-Equals -Actual (@($policy.ServiceAdjustments))[0].Name -Expected 'MapsBroker' -Message 'agressivo must touch MapsBroker.'
}

function Test-DescriptionsCoverAllModes {
    $desc = Get-BootstrapHostHealthModeDescriptions
    foreach ($m in @('off', 'conservador', 'equilibrado', 'agressivo')) {
        Assert-True -Condition ([bool]$desc[$m]) -Message "Description for $m must exist."
    }
}

function Test-EstimatedTimeProducesText {
    $text = Get-BootstrapEstimatedTimeText -ComponentNames @('git-core', 'node-core', 'python-core')
    Assert-True -Condition ($text -match 'm') -or ($text -match 's') -Message 'Estimated text must include time unit.'
}

function Test-EstimatedTimeEmpty {
    $text = Get-BootstrapEstimatedTimeText -ComponentNames @()
    Assert-Equals -Actual $text -Expected '<1m' -Message 'Empty list must yield <1m.'
}

Test-HostHealthModesList
Test-NormalizeRejectsUnknown
Test-NormalizeNullReturnsNull
Test-PolicyOffReturnsEmptyAppx
Test-PolicyConservadorMinimal
Test-PolicyEquilibradoRemovesAppxNotPCManager
Test-PolicyAgressivoIncludesPCManagerAndService
Test-DescriptionsCoverAllModes
Test-EstimatedTimeProducesText
Test-EstimatedTimeEmpty

Write-Host 'hosthealth tests: ok'
