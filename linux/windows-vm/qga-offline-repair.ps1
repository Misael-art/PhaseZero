$ErrorActionPreference = 'Stop'
$statusDir = Join-Path $env:ProgramData 'PhaseZero'
$payloadDir = Join-Path $env:ProgramData 'PhaseZeroOffline'
$isoPath = Join-Path $payloadDir 'virtio-win.iso'
$statusPath = Join-Path $statusDir 'qga-offline-repair.json'
$mounted = $false

New-Item -Path $statusDir -ItemType Directory -Force | Out-Null
try {
    if (-not (Test-Path -LiteralPath $isoPath)) { throw 'virtio media payload missing' }
    Mount-DiskImage -ImagePath $isoPath -StorageType ISO -PassThru | Out-Null
    $mounted = $true
    $drive = (Get-DiskImage -ImagePath $isoPath | Get-Volume | Select-Object -First 1).DriveLetter
    if (-not $drive) { throw 'virtio media mount has no drive letter' }
    $root = "${drive}:\"
    $serialInf = Get-ChildItem (Join-Path $root 'vioserial') -Filter 'vioser.inf' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { if ($_.FullName -match '\\w11\\amd64\\') { 0 } else { 1 } } | Select-Object -First 1
    if ($serialInf) {
        & pnputil.exe /add-driver $serialInf.FullName /install | Out-Null
        if ($LASTEXITCODE -notin @(0, 259, 3010)) { throw 'vioserial driver installation failed' }
    }
    $msi = Join-Path $root 'guest-agent\qemu-ga-x86_64.msi'
    if (-not (Test-Path -LiteralPath $msi)) { throw 'QGA MSI missing from verified virtio media' }
    if ((Get-AuthenticodeSignature -FilePath $msi).Status -ne 'Valid') {
        throw 'QGA MSI signature is not valid'
    }
    $install = Start-Process msiexec.exe -ArgumentList '/i', $msi, '/qn', '/norestart',
        'REINSTALL=ALL', 'REINSTALLMODE=vomus' -PassThru -WindowStyle Hidden
    if (-not $install.WaitForExit(300000)) {
        Stop-Process -Id $install.Id -Force -ErrorAction SilentlyContinue
        throw 'QGA installer timeout'
    }
    if ($install.ExitCode -notin @(0, 3010) -and
        -not (Get-Service -Name qemu-ga -ErrorAction SilentlyContinue)) {
        throw "QGA installer failed: $($install.ExitCode)"
    }
    & sc.exe config qemu-ga start= delayed-auto depend= / | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'QGA service configuration failed' }
    & sc.exe failure qemu-ga reset= 0 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    Start-Service -Name qemu-ga -ErrorAction SilentlyContinue
    $service = Get-Service -Name qemu-ga -ErrorAction Stop
    if ($service.Status -notin @('Running', 'StartPending')) { throw 'QGA service did not start' }
    @{
        schemaVersion = 1
        success = ($service.Status -in @('Running', 'StartPending'))
        qgaServiceHealthy = ($service.Status -in @('Running', 'StartPending'))
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
} catch {
    @{
        schemaVersion = 1
        success = $false
        qgaServiceHealthy = $false
        error = 'offline-qga-repair-failed'
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8 -ErrorAction SilentlyContinue
    throw
} finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $payloadDir -Force -Recurse -ErrorAction SilentlyContinue
}
