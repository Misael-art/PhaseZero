param(
    [string]$SettingsPath = (Join-Path (Join-Path $env:USERPROFILE '.bootstrap-tools') 'steamdeck-settings.json'),
    [string]$StatePath = (Join-Path (Join-Path $env:USERPROFILE '.bootstrap-tools') 'steamdeck-mode-state.json'),
    [int]$PollIntervalSeconds = 2,
    [int]$CooldownSeconds = 5,
    [int]$StableSamples = 2,
    [switch]$RunOnce
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    try {
        return (Get-Content -Path $Path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent) { $null = New-Item -Path $parent -ItemType Directory -Force }
    $Value | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8
}

function Write-WatcherLog {
    param([string]$Message)

    $logPath = Join-Path (Split-Path -Path $StatePath -Parent) 'steamdeck-mode-watcher.log'
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

$scriptRoot = Split-Path -Parent $PSCommandPath
$detectScript = Join-Path $scriptRoot 'Detect-Mode.ps1'
$handheldScript = Join-Path $scriptRoot 'Apply-Handheld.ps1'
$dockMonitorScript = Join-Path $scriptRoot 'Apply-DockedMonitor.ps1'
$dockTvScript = Join-Path $scriptRoot 'Apply-DockedTv.ps1'
$currentDetectionPath = Join-Path (Split-Path -Path $StatePath -Parent) 'steamdeck-current-detection.json'

do {
    $state = Read-JsonFile -Path $StatePath
    if (-not $state) {
        $state = [ordered]@{
            lastCandidateMode = $null
            candidateCount = 0
            lastAppliedMode = $null
            lastAppliedAt = $null
        }
    }

    $json = & powershell -NoProfile -ExecutionPolicy Bypass -File $detectScript -SettingsPath $SettingsPath
    $detection = $json | ConvertFrom-Json
    Write-JsonFile -Path $currentDetectionPath -Value $detection

    if ($state.lastCandidateMode -eq $detection.mode) {
        $state.candidateCount = [int]$state.candidateCount + 1
    } else {
        $state.lastCandidateMode = $detection.mode
        $state.candidateCount = 1
    }

    $cooldownReady = $true
    if ($state.lastAppliedAt) {
        try {
            $lastAppliedAt = [datetime]$state.lastAppliedAt
            $cooldownReady = ((Get-Date) - $lastAppliedAt).TotalSeconds -ge $CooldownSeconds
        } catch {
            $cooldownReady = $true
        }
    }

    if (($state.candidateCount -ge $StableSamples) -and $cooldownReady -and ($state.lastAppliedMode -ne $detection.mode)) {
        $applyScript = switch ($detection.mode) {
            'HANDHELD' { $handheldScript }
            'DOCKED_MONITOR' { $dockMonitorScript }
            'DOCKED_TV' { $dockTvScript }
            default { $null }
        }

        if ($applyScript -and (Test-Path $applyScript)) {
            Write-WatcherLog "Applying mode $($detection.mode)"
            & powershell -NoProfile -ExecutionPolicy Bypass -File $applyScript -SettingsPath $SettingsPath -DetectionPath $currentDetectionPath | Out-Null
            $state.lastAppliedMode = $detection.mode
            $state.lastAppliedAt = (Get-Date).ToString('o')
        } else {
            Write-WatcherLog "No apply script found for mode $($detection.mode)"
        }
    }

    Write-JsonFile -Path $StatePath -Value $state

    if (-not $RunOnce) {
        Start-Sleep -Seconds $PollIntervalSeconds
    }
} while (-not $RunOnce)
