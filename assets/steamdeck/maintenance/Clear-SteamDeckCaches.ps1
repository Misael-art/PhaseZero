$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
    $targets = @(
        $env:TEMP,
        (Join-Path $env:LOCALAPPDATA 'Temp'),
        'C:\Windows\Temp',
        'C:\Windows\Prefetch'
    )
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
