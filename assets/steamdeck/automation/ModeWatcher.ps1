param(
    [string]$SettingsPath,
    [string]$StatePath,
    [int]$PollIntervalSeconds = 2,
    [int]$CooldownSeconds = 5,
    [int]$StableSamples = 2,
    [switch]$RunOnce
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSCommandPath) 'SteamDeck.Common.ps1')

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Get-SteamDeckSettingsPath
}
if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Get-SteamDeckModeStatePath
}
Assert-SteamDeckFileExists -Path $SettingsPath -Description 'Settings file'

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

    Write-SteamDeckJsonFile -Path $Path -Value $Value -Depth 10
}

function Write-WatcherLog {
    param([string]$Message)

    $logPath = Join-Path (Split-Path -Path $StatePath -Parent) 'steamdeck-mode-watcher.log'
    Ensure-SteamDeckParentDirectory -Path $logPath
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    Add-Content -Path $logPath -Value $line -Encoding utf8
}

$scriptRoot = Split-Path -Parent $PSCommandPath
$detectScript = Join-Path $scriptRoot 'Detect-Mode.ps1'
$handheldScript = Join-Path $scriptRoot 'Apply-Handheld.ps1'
$dockMonitorScript = Join-Path $scriptRoot 'Apply-DockedMonitor.ps1'
$dockTvScript = Join-Path $scriptRoot 'Apply-DockedTv.ps1'
$currentDetectionPath = Join-Path (Split-Path -Path $StatePath -Parent) 'steamdeck-current-detection.json'
$powershellExe = Get-SteamDeckWindowsPowerShellPath
Assert-SteamDeckFileExists -Path $powershellExe -Description 'Windows PowerShell executable'

do {
    # Isolamento por iteracao: uma falha transitoria (deteccao/WMI/JSON/apply) registra no log
    # e a proxima iteracao continua -- o daemon nao morre. (Sem isso, EAP=Stop encerraria o watcher.)
    try {
        $state = Read-JsonFile -Path $StatePath
        if (-not $state) {
            $state = [ordered]@{
                lastCandidateMode = $null
                candidateCount = 0
                lastAppliedMode = $null
                lastAppliedAt = $null
            }
        }

        $detection = $null
        $json = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $detectScript -SettingsPath $SettingsPath
        if ($json) {
            try { $detection = ($json | ConvertFrom-Json) } catch { $detection = $null }
        }

        if ($null -eq $detection -or ($detection.PSObject.Properties.Name -notcontains 'mode') -or [string]::IsNullOrWhiteSpace([string]$detection.mode)) {
            Write-WatcherLog 'Deteccao indisponivel nesta iteracao; mantendo estado e tentando novamente.'
        } else {
            Write-JsonFile -Path $currentDetectionPath -Value $detection

            $decision = Get-SteamDeckModeWatcherDecision -DetectedMode ([string]$detection.mode) -State $state -StableSamples $StableSamples -CooldownSeconds $CooldownSeconds
            $state = $decision.State

            if ($decision.ShouldApply) {
                $applyScript = switch ([string]$decision.ApplyMode) {
                    'HANDHELD' { $handheldScript }
                    'DOCKED_MONITOR' { $dockMonitorScript }
                    'DOCKED_TV' { $dockTvScript }
                    'UNCLASSIFIED_EXTERNAL' { $dockMonitorScript }
                    default { $null }
                }

                if ($applyScript -and (Test-Path $applyScript)) {
                    Write-WatcherLog "Applying mode $($decision.ApplyMode)"
                    & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $applyScript -SettingsPath $SettingsPath -DetectionPath $currentDetectionPath | Out-Null
                    $state['lastAppliedMode'] = [string]$decision.ApplyMode
                    $state['lastAppliedAt'] = (Get-Date).ToString('o')
                } else {
                    Write-WatcherLog "No apply script found for mode $($decision.ApplyMode)"
                }
            }

            Write-JsonFile -Path $StatePath -Value $state
        }
    } catch {
        try { Write-WatcherLog ("Erro na iteracao (continuando): {0}" -f $_.Exception.Message) } catch { }
    }

    if (-not $RunOnce) {
        Start-Sleep -Seconds $PollIntervalSeconds
    }
} while (-not $RunOnce)
