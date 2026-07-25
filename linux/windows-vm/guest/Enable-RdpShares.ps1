# PhaseZero Windows VM - Enable RDP drive redirection
# Run as Administrator in the Windows guest.
# Host drives appear as \\tsclient\<share> after RDP connection.

param(
    [switch]$RestartService
)

$LOG = "$env:ProgramData\PhaseZero\rdp-shares.log"
$null = New-Item -ItemType Directory -Force -Path "$env:ProgramData\PhaseZero"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $Message" | Out-File -FilePath $LOG -Encoding utf8 -Append
    Write-Host "$ts $Message"
}

Write-Log "=== Enabling RDP drive redirection ==="

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
try {
    Set-ItemProperty -Path $regPath -Name "fSingleSessionPerUser" -Value 0 -Type DWord -Force
    Write-Log "fSingleSessionPerUser=0"
} catch { Write-Log "WARN: fSingleSessionPerUser: $_" }

try {
    Set-ItemProperty -Path "$regPath\WinStations\RDP-Tcp" -Name "fDisableAutoReconnect" -Value 0 -Type DWord -Force
    Write-Log "fDisableAutoReconnect=0"
} catch { Write-Log "WARN: fDisableAutoReconnect: $_" }

$rdpDriveReg = "HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services"
$null = New-Item -ItemType Directory -Force -Path $rdpDriveReg
try {
    Set-ItemProperty -Path $rdpDriveReg -Name "fDisableCdm" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $rdpDriveReg -Name "fEnableDriveRedirection" -Value 1 -Type DWord -Force
    Write-Log "RDP drive redirection GPO enabled"
} catch { Write-Log "WARN: RDP GPO: $_" }

try {
    Set-ItemProperty -Path "$regPath" -Name "AllowRemoteRPC" -Value 1 -Type DWord -Force
    Write-Log "AllowRemoteRPC=1"
} catch { Write-Log "WARN: AllowRemoteRPC: $_" }

if ($RestartService) {
    Restart-Service TermService -Force -ErrorAction SilentlyContinue
    Write-Log "TermService restarted"
} else {
    Write-Log "Restart TermService manually or reboot for changes to take effect"
}

Write-Log "RDP shares configured. Connect with: xfreerdp3 /drive:home,$env:USERPROFILE"
