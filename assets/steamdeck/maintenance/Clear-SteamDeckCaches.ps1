$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$steamdeckRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $steamdeckRoot 'automation') 'SteamDeck.Common.ps1')

function Clear-DirectoryContentsSafe {
    param([Parameter(Mandatory = $true)][string]$TargetPath)

    if ([string]::IsNullOrWhiteSpace($TargetPath) -or -not (Test-Path $TargetPath)) {
        return [ordered]@{ path = $TargetPath; removed = 0; skipped = 0; note = 'path-missing' }
    }

    $removed = 0
    $skipped = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue)) {
        try {
            if ($item.PSIsContainer) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            }
            $removed++
        } catch {
            $skipped++
        }
    }
    return [ordered]@{ path = $TargetPath; removed = $removed; skipped = $skipped; note = 'ok' }
}

try {
    $tempEnv = Normalize-SteamDeckPathSegment -Value $env:TEMP
    $localTemp = Normalize-SteamDeckPathSegment -Value $env:LOCALAPPDATA
    $targets = @(
        $tempEnv,
        $(if (-not [string]::IsNullOrWhiteSpace($localTemp)) { Join-Path -Path $localTemp -ChildPath 'Temp' } else { $null }),
        'C:\Windows\Temp',
        'C:\Windows\Prefetch'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $results = @()
    foreach ($target in @($targets)) {
        $results += @(Clear-DirectoryContentsSafe -TargetPath $target)
    }

    try {
        Clear-RecycleBin -Force -ErrorAction Stop | Out-Null
        $recycle = 'cleared'
    } catch {
        $recycle = 'partial'
    }

    [ordered]@{
        status = 'applied'
        action = 'clear-steamdeck-caches'
        recycleBin = $recycle
        targets = @($results)
    } | ConvertTo-Json -Depth 8
} catch {
    throw "Falha na limpeza de caches Steam Deck: $($_.Exception.Message)"
}
