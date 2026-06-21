$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    return [string](Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

try {
    $memReductCandidates = @(
        "${env:ProgramFiles}\Mem Reduct\memreduct.exe",
        "${env:ProgramFiles(x86)}\Mem Reduct\memreduct.exe"
    )
    $memReduct = [string]($memReductCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($memReduct)) {
        Start-Process -FilePath $memReduct -ArgumentList '/emptyworkingsets' -WindowStyle Hidden | Out-Null
        [ordered]@{ status = 'applied'; action = 'clear-standby-memory'; engine = 'mem-reduct'; path = $memReduct } | ConvertTo-Json -Depth 6
        return
    }

    $emptyStandbyPath = Join-Path (Split-Path -Parent $PSCommandPath) 'EmptyStandbyList.exe'
    $pinnedHashes = @(
        'UNSET_PINNED_SHA256_REPLACE_WITH_VERIFIED_BINARY_HASH'
    )
    if (Test-Path $emptyStandbyPath) {
        $hash = (Get-FileSha256 -Path $emptyStandbyPath).ToUpperInvariant()
        if ($pinnedHashes -contains $hash) {
            Start-Process -FilePath $emptyStandbyPath -ArgumentList 'standbylist' -WindowStyle Hidden | Out-Null
            [ordered]@{ status = 'applied'; action = 'clear-standby-memory'; engine = 'emptystandbylist'; path = $emptyStandbyPath } | ConvertTo-Json -Depth 6
            return
        }
    }

    [ordered]@{
        status = 'manual-blocker'
        action = 'clear-standby-memory'
        reason = 'Mem Reduct ausente e EmptyStandbyList sem hash validado/pinned.'
    } | ConvertTo-Json -Depth 6
} catch {
    throw "Falha ao limpar standby memory: $($_.Exception.Message)"
}
