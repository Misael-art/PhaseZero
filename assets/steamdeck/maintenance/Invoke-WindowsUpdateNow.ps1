$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-WindowsUpdateCom {
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    $searchResult = $searcher.Search("IsInstalled=0 and Type='Software'")
    $updates = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($update in @($searchResult.Updates)) {
        if ($update -and -not [bool]$update.IsDownloaded) {
            [void]$updates.Add($update)
        }
    }
    if ($updates.Count -gt 0) {
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $updates
        [void]$downloader.Download()
    }

    $installUpdates = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($update in @($searchResult.Updates)) {
        if ($update -and [bool]$update.IsDownloaded) {
            [void]$installUpdates.Add($update)
        }
    }
    if ($installUpdates.Count -gt 0) {
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $installUpdates
        [void]$installer.Install()
    }

    return [ordered]@{
        engine = 'com'
        found = [int]$searchResult.Updates.Count
        downloaded = [int]$updates.Count
        installAttempted = [int]$installUpdates.Count
    }
}

function Invoke-WindowsUpdateUsoClientFallback {
    $usoclient = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
    if (-not (Test-Path $usoclient)) {
        throw 'UsoClient.exe não encontrado para fallback.'
    }

    foreach ($action in @('StartScan', 'StartDownload', 'StartInstall')) {
        & $usoclient $action | Out-Null
    }
    return [ordered]@{
        engine = 'usoclient'
        steps = @('StartScan', 'StartDownload', 'StartInstall')
    }
}

try {
    $result = $null
    try {
        $result = Invoke-WindowsUpdateCom
    } catch {
        $result = Invoke-WindowsUpdateUsoClientFallback
        $result['fallbackReason'] = $_.Exception.Message
    }
    $result['status'] = 'applied'
    $result['action'] = 'windows-update-now'
    $result | ConvertTo-Json -Depth 8
} catch {
    throw "Falha ao disparar Windows Update imediato: $($_.Exception.Message)"
}
