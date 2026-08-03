$ErrorActionPreference = 'Stop'
$statusDir = Join-Path $env:ProgramData 'PhaseZero'
$payloadDir = Join-Path $env:ProgramData 'PhaseZeroOffline'
$isoPath = Join-Path $payloadDir 'virtio-win.iso'
$trustedVirtioSha256 = '__PZ_VIRTIO_SHA256__'
$statusPath = Join-Path $statusDir 'qga-offline-repair.json'
$mounted = $false
# virt-customize firstboot is hosted by 32-bit RHSrvAny.  On 64-bit Windows,
# System32 is redirected to SysWOW64 for that process; Sysnative escapes that
# redirect and exposes the native servicing tools.
$sysnative = Join-Path $env:SystemRoot 'Sysnative'
$system32 = if (Test-Path -LiteralPath $sysnative) {
    $sysnative
} else {
    Join-Path $env:SystemRoot 'System32'
}
$pnputil = Join-Path $system32 'pnputil.exe'
$msiexec = Join-Path $system32 'msiexec.exe'
$sc = Join-Path $system32 'sc.exe'
$shutdown = Join-Path $system32 'shutdown.exe'

function Write-RepairStatus([bool]$Success, [string]$Phase, [string]$Error = '') {
    [ordered]@{
        schemaVersion = 1
        success = $Success
        phase = $Phase
        qgaServiceHealthy = $Success
        msiSignatureStatus = $msiSignatureStatus
        error = $Error
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

New-Item -Path $statusDir -ItemType Directory -Force | Out-Null
try {
    if (-not (Test-Path -LiteralPath $isoPath)) { throw 'virtio media payload missing' }
    $isoSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $isoPath).Hash.ToLowerInvariant()
    if ($isoSha256 -ne $trustedVirtioSha256.ToLowerInvariant()) {
        throw 'virtio media payload hash mismatch'
    }
    Mount-DiskImage -ImagePath $isoPath -StorageType ISO -PassThru | Out-Null
    $mounted = $true
    $drive = (Get-DiskImage -ImagePath $isoPath | Get-Volume | Select-Object -First 1).DriveLetter
    if (-not $drive) { throw 'virtio media mount has no drive letter' }
    $root = "${drive}:\"
    $serialInf = Get-ChildItem (Join-Path $root 'vioserial') -Filter 'vioser.inf' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { if ($_.FullName -match '\\w11\\amd64\\') { 0 } else { 1 } } | Select-Object -First 1
    if ($serialInf) {
        & $pnputil /add-driver $serialInf.FullName /install | Out-Null
        if ($LASTEXITCODE -notin @(0, 259, 3010)) { throw 'vioserial driver installation failed' }
    }
    Write-RepairStatus $true 'driver-installed'
    $msi = Join-Path $root 'guest-agent\qemu-ga-x86_64.msi'
    if (-not (Test-Path -LiteralPath $msi)) { throw 'QGA MSI missing from verified virtio media' }
    # The ISO was hash-pinned before upload and re-checked above.  Under the
    # SYSTEM firstboot context Windows may report a non-Valid Authenticode
    # state while trusted roots are unavailable, so that state is diagnostic,
    # not an authorization boundary.  A positive hash mismatch remains fatal.
    $msiSignatureStatus = (Get-AuthenticodeSignature -FilePath $msi).Status.ToString()
    if ($msiSignatureStatus -eq 'HashMismatch') {
        throw 'QGA MSI signature hash mismatch'
    }
    $install = Start-Process $msiexec -ArgumentList '/i', $msi, '/qn', '/norestart',
        'REINSTALL=ALL', 'REINSTALLMODE=vomus' -PassThru -WindowStyle Hidden
    if (-not $install.WaitForExit(300000)) {
        Stop-Process -Id $install.Id -Force -ErrorAction SilentlyContinue
        throw 'QGA installer timeout'
    }
    if ($install.ExitCode -notin @(0, 3010) -and
        -not (Get-Service -Name qemu-ga -ErrorAction SilentlyContinue)) {
        throw "QGA installer failed: $($install.ExitCode)"
    }
    & $sc config qemu-ga start= delayed-auto depend= / | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'QGA service configuration failed' }
    & $sc failure qemu-ga reset= 0 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    Start-Service -Name qemu-ga -ErrorAction SilentlyContinue
    $service = Get-Service -Name qemu-ga -ErrorAction Stop
    if ($service.Status -notin @('Running', 'StartPending')) { throw 'QGA service did not start' }
    Write-RepairStatus $true 'qga-installed'
    & $shutdown /r /t 15 /f /c 'PhaseZero QGA repair complete; rebooting to verify transport' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Windows reboot scheduling failed' }
    Write-RepairStatus $true 'reboot-scheduled'
} catch {
    try { Write-RepairStatus $false 'failed' 'offline-qga-repair-failed' } catch { }
    throw
} finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $payloadDir -Force -Recurse -ErrorAction SilentlyContinue
}
