param(
    [ValidateSet('auto', 'password', 'status', 'touch-input', 'recovery-status', 'recovery-apply', 'recovery-enable', 'recovery-disable')]
    [string]$Mode = 'status',
    [string]$UserName = 'phasezero',
    [string]$InputPath = ''
)

$ErrorActionPreference = 'Stop'
if ($env:PZ_GUEST_LOGIN_MODE) { $Mode = $env:PZ_GUEST_LOGIN_MODE }
if ($env:PZ_GUEST_LOGIN_USER) { $UserName = $env:PZ_GUEST_LOGIN_USER }
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$policyDir = Join-Path $env:ProgramData 'PhaseZero'
$policyFile = Join-Path $policyDir 'guest-login-policy.json'
$recoveryUser = 'PZ-Recovery'
$recoveryPolicyFile = Join-Path $policyDir 'recovery-login-policy.json'

if (-not ('PhaseZeroLsa' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PhaseZeroLsa {
    [StructLayout(LayoutKind.Sequential)]
    private struct LSA_UNICODE_STRING {
        public UInt16 Length;
        public UInt16 MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LSA_OBJECT_ATTRIBUTES {
        public UInt32 Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public UInt32 Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [DllImport("advapi32.dll", PreserveSig=true)]
    private static extern UInt32 LsaOpenPolicy(IntPtr systemName,
        ref LSA_OBJECT_ATTRIBUTES objectAttributes, UInt32 desiredAccess,
        out IntPtr policyHandle);
    [DllImport("advapi32.dll", PreserveSig=true)]
    private static extern UInt32 LsaStorePrivateData(IntPtr policyHandle,
        ref LSA_UNICODE_STRING keyName, IntPtr privateData);
    [DllImport("advapi32.dll", PreserveSig=true)]
    private static extern UInt32 LsaRetrievePrivateData(IntPtr policyHandle,
        ref LSA_UNICODE_STRING keyName, out IntPtr privateData);
    [DllImport("advapi32.dll")]
    private static extern UInt32 LsaClose(IntPtr policyHandle);
    [DllImport("advapi32.dll")]
    private static extern UInt32 LsaFreeMemory(IntPtr buffer);

    private static LSA_UNICODE_STRING InitString(string value) {
        LSA_UNICODE_STRING result = new LSA_UNICODE_STRING();
        result.Buffer = Marshal.StringToHGlobalUni(value);
        result.Length = (UInt16)(value.Length * 2);
        result.MaximumLength = (UInt16)((value.Length + 1) * 2);
        return result;
    }

    private static IntPtr Open(UInt32 access) {
        LSA_OBJECT_ATTRIBUTES attrs = new LSA_OBJECT_ATTRIBUTES();
        attrs.Length = (UInt32)Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr handle;
        UInt32 status = LsaOpenPolicy(IntPtr.Zero, ref attrs, access, out handle);
        if (status != 0) throw new InvalidOperationException("LsaOpenPolicy failed: " + status);
        return handle;
    }

    public static void Store(string key, string value) {
        IntPtr handle = Open(0x20);
        LSA_UNICODE_STRING keyName = InitString(key);
        IntPtr valuePtr = IntPtr.Zero;
        try {
            UInt32 status;
            if (value == null) {
                status = LsaStorePrivateData(handle, ref keyName, IntPtr.Zero);
            } else {
                LSA_UNICODE_STRING secret = InitString(value);
                valuePtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(LSA_UNICODE_STRING)));
                Marshal.StructureToPtr(secret, valuePtr, false);
                status = LsaStorePrivateData(handle, ref keyName, valuePtr);
                Marshal.FreeHGlobal(secret.Buffer);
            }
            if (status != 0) throw new InvalidOperationException("LsaStorePrivateData failed: " + status);
        } finally {
            if (valuePtr != IntPtr.Zero) Marshal.FreeHGlobal(valuePtr);
            Marshal.FreeHGlobal(keyName.Buffer);
            LsaClose(handle);
        }
    }

    public static bool Has(string key) {
        IntPtr handle = Open(0x4);
        LSA_UNICODE_STRING keyName = InitString(key);
        IntPtr value = IntPtr.Zero;
        try {
            UInt32 status = LsaRetrievePrivateData(handle, ref keyName, out value);
            if (status != 0 || value == IntPtr.Zero) return false;
            LSA_UNICODE_STRING secret = (LSA_UNICODE_STRING)Marshal.PtrToStructure(value, typeof(LSA_UNICODE_STRING));
            return secret.Length > 0;
        } finally {
            if (value != IntPtr.Zero) LsaFreeMemory(value);
            Marshal.FreeHGlobal(keyName.Buffer);
            LsaClose(handle);
        }
    }
}
'@
}

function Get-WddmVersion {
    # Only a real WDDM display driver publishes a WddmVersion under its device
    # class key.  The encoding is (major << 12) | minor, e.g. 0x2007 = WDDM 2.7.
    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    if (-not (Test-Path -LiteralPath $classKey)) { return '' }
    foreach ($child in Get-ChildItem -LiteralPath $classKey -ErrorAction SilentlyContinue) {
        if ($child.PSChildName -notmatch '^\d{4}$') { continue }
        foreach ($name in @('WddmVersion', 'WddmVersion_Max', 'WddmVersion_Min')) {
            $raw = (Get-ItemProperty -LiteralPath $child.PSPath -Name $name -ErrorAction SilentlyContinue).$name
            if ($raw -is [int] -and $raw -gt 0) {
                return ('{0}.{1}' -f ($raw -shr 12), ($raw -band 0xFFF))
            }
        }
    }
    return ''
}

function Get-GraphicsStatus {
    # "Display adapter exists" is not "graphics acceleration works".  QXL and the
    # Microsoft Basic Display Adapter both satisfy the former while offering no
    # 3D pipeline, so each fact is reported separately and only the composite
    # signal may gate readiness.
    $status = [ordered]@{
        graphicsAdapters = @()
        displayAdapterPresent = $false
        graphicsDriver = ''
        graphicsDriverVersion = ''
        wddmVersion = ''
        basicDisplayAdapterOnly = $false
        direct3DReady = $false
        graphicsAccelerationVerified = $false
    }
    try {
        $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        $status.graphicsAdapters = @($controllers | ForEach-Object { $_.Name } | Where-Object { $_ })
        $status.displayAdapterPresent = $status.graphicsAdapters.Count -gt 0
        $accelerated = @($controllers | Where-Object {
            $_.ConfigManagerErrorCode -eq 0 -and
            $_.Name -notmatch 'Basic Display|Basic Render|Standard VGA'
        })
        $status.basicDisplayAdapterOnly = ($status.displayAdapterPresent -and $accelerated.Count -eq 0)
        $primary = if ($accelerated.Count -gt 0) { $accelerated[0] }
                   elseif ($controllers.Count -gt 0) { $controllers[0] }
                   else { $null }
        if ($primary) {
            $status.graphicsDriver = [string]$primary.AdapterCompatibility
            $status.graphicsDriverVersion = [string]$primary.DriverVersion
            # A driver with a working 3D pipeline registers user-mode display
            # driver DLLs; the basic fallback adapter registers none.
            $umd = @(@($primary.InstalledDisplayDrivers) | Where-Object { $_ })
            $status.direct3DReady = (-not $status.basicDisplayAdapterOnly) -and $umd.Count -gt 0
        }
        $status.wddmVersion = Get-WddmVersion
        $status.graphicsAccelerationVerified = ($status.direct3DReady -and [bool]$status.wddmVersion)
    } catch { Write-Verbose 'Graphics readiness probe unavailable' }
    $status
}

function Get-GuestRuntimeStatus {
    # Status must remain available while networking or optional virtio devices
    # are still coming up.  Each probe therefore degrades to false instead of
    # turning a login-policy query into a QGA failure.
    $networkReady = $false
    $dnsReady = $false
    $dnsServersConfigured = $false
    $exchangeMapped = $false
    $audioReady = $false
    $explorerReady = $false
    $lastBootUpTime = ''
    try {
        $networkReady = @(Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }).Count -gt 0
    } catch { Write-Verbose 'Network readiness probe unavailable' }
    try {
        $dnsServersConfigured = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { @($_.ServerAddresses).Count -gt 0 }).Count -gt 0
    } catch { Write-Verbose 'DNS configuration probe unavailable' }
    try {
        # Public resolution is diagnostic only: an offline or filtered network is
        # a legitimate guest state and must not fail provisioning.
        $dnsReady = @(Resolve-DnsName -Name microsoft.com -Type A -DnsOnly -QuickTimeout -ErrorAction Stop).Count -gt 0
    } catch { Write-Verbose 'DNS readiness probe unavailable' }
    try {
        foreach ($hive in Get-ChildItem Registry::HKEY_USERS -ErrorAction Stop) {
            if ($hive.PSChildName -notmatch '^S-1-5-21-') { continue }
            $drive = "Registry::HKEY_USERS\$($hive.PSChildName)\Network\P"
            if (Test-Path -LiteralPath $drive) { $exchangeMapped = $true; break }
        }
    } catch { Write-Verbose 'Exchange mapping probe unavailable' }
    try {
        $audioReady = @(Get-CimInstance Win32_SoundDevice -ErrorAction Stop |
            Where-Object { $_.Status -eq 'OK' }).Count -gt 0
    } catch { Write-Verbose 'Audio readiness probe unavailable' }
    try { $explorerReady = @(Get-Process explorer -ErrorAction Stop).Count -gt 0 } catch { Write-Verbose 'Explorer readiness probe unavailable' }
    try {
        $lastBootUpTime = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
    } catch { Write-Verbose 'Boot time probe unavailable' }
    $graphics = Get-GraphicsStatus
    $repair = Get-OfflineRepairStatus $lastBootUpTime
    [ordered]@{
        networkReady = [bool]$networkReady
        dnsReady = [bool]$dnsReady
        dnsServersConfigured = [bool]$dnsServersConfigured
        exchangeMapped = [bool]$exchangeMapped
        audioReady = [bool]$audioReady
        graphicsAdapters = $graphics.graphicsAdapters
        # Retained for compatibility: presence of an adapter, nothing more.
        graphicsReady = [bool]$graphics.displayAdapterPresent
        displayAdapterPresent = [bool]$graphics.displayAdapterPresent
        graphicsDriver = $graphics.graphicsDriver
        graphicsDriverVersion = $graphics.graphicsDriverVersion
        wddmVersion = $graphics.wddmVersion
        basicDisplayAdapterOnly = [bool]$graphics.basicDisplayAdapterOnly
        direct3DReady = [bool]$graphics.direct3DReady
        graphicsAccelerationVerified = [bool]$graphics.graphicsAccelerationVerified
        explorerReady = [bool]$explorerReady
        lastBootUpTime = $lastBootUpTime
        offlineRepairPhase = $repair.offlineRepairPhase
        offlineRepairBootUpTime = $repair.offlineRepairBootUpTime
        offlineRepairRebootProven = [bool]$repair.offlineRepairRebootProven
    }
}

function Get-OfflineRepairStatus([string]$LastBootUpTime) {
    # The offline repair records the boot it ran on. Comparing that against the
    # current boot proves the scheduled reboot happened, which a transport-gap
    # heuristic cannot do reliably.
    $result = [ordered]@{
        offlineRepairPhase = ''
        offlineRepairBootUpTime = ''
        offlineRepairRebootProven = $true
    }
    $repairFile = Join-Path $policyDir 'qga-offline-repair.json'
    if (-not (Test-Path -LiteralPath $repairFile)) { return $result }
    try {
        $repair = Get-Content -LiteralPath $repairFile -Raw | ConvertFrom-Json
        $result.offlineRepairPhase = [string]$repair.phase
        $result.offlineRepairBootUpTime = [string]$repair.repairBootUpTime
    } catch { Write-Verbose 'Offline repair status file is unavailable or invalid'; return $result }
    if ($result.offlineRepairBootUpTime -and $LastBootUpTime) {
        $result.offlineRepairRebootProven = ($LastBootUpTime -ne $result.offlineRepairBootUpTime)
    }
    $result
}

function Get-PolicyStatus {
    $auto = (Get-ItemProperty -Path $winlogon -Name AutoAdminLogon -ErrorAction SilentlyContinue).AutoAdminLogon
    $configuredUser = (Get-ItemProperty -Path $winlogon -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
    $secretStored = [PhaseZeroLsa]::Has('DefaultPassword')
    $loggedOn = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    $policy = if ($auto -eq '1' -and $secretStored) { 'auto' } else { 'password' }
    $runtime = Get-GuestRuntimeStatus
    [ordered]@{
        success = $true
        policy = $policy
        configured = ($configuredUser -eq $UserName -and
            (($policy -eq 'auto' -and $auto -eq '1' -and $secretStored) -or
             ($policy -eq 'password' -and $auto -ne '1' -and -not $secretStored)))
        user = $configuredUser
        secretStored = $secretStored
        registryPasswordStored = [bool](Get-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue)
        loggedOnUser = $loggedOn
        explorerReady = $runtime.explorerReady
        networkReady = $runtime.networkReady
        dnsReady = $runtime.dnsReady
        dnsServersConfigured = $runtime.dnsServersConfigured
        exchangeMapped = $runtime.exchangeMapped
        audioReady = $runtime.audioReady
        graphicsAdapters = $runtime.graphicsAdapters
        graphicsReady = $runtime.graphicsReady
        displayAdapterPresent = $runtime.displayAdapterPresent
        graphicsDriver = $runtime.graphicsDriver
        graphicsDriverVersion = $runtime.graphicsDriverVersion
        wddmVersion = $runtime.wddmVersion
        basicDisplayAdapterOnly = $runtime.basicDisplayAdapterOnly
        direct3DReady = $runtime.direct3DReady
        graphicsAccelerationVerified = $runtime.graphicsAccelerationVerified
        lastBootUpTime = $runtime.lastBootUpTime
        offlineRepairPhase = $runtime.offlineRepairPhase
        offlineRepairBootUpTime = $runtime.offlineRepairBootUpTime
        offlineRepairRebootProven = $runtime.offlineRepairRebootProven
        qgaServiceHealthy = [bool](Get-Service -Name qemu-ga -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Running' })
        lastVerifiedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-RecoveryStatus {
    $account = Get-LocalUser -Name $recoveryUser -ErrorAction SilentlyContinue
    $isAdmin = $false
    $adminGroup = (Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue).Name
    if ($account) {
        try {
            $isAdmin = @(Get-LocalGroupMember -Group $adminGroup -ErrorAction Stop |
                Where-Object { $_.Name -match "\\\\$([regex]::Escape($recoveryUser))$" }).Count -gt 0
        } catch { Write-Verbose 'Recovery administrator membership probe unavailable' }
    }
    $localOnly = $true
    if (Test-Path -LiteralPath $recoveryPolicyFile) {
        try {
            $localOnly = ((Get-Content -LiteralPath $recoveryPolicyFile -Raw | ConvertFrom-Json).localOnly -ne $false)
        } catch { Write-Verbose 'Recovery policy file is unavailable or invalid' }
    }
    [ordered]@{
        success = $true
        recoveryAccount = $recoveryUser
        recoveryConfigured = [bool]$account
        recoveryEnabled = [bool]($account -and $account.Enabled)
        recoveryAdministrator = [bool]$isAdmin
        recoveryLocalOnly = [bool]$localOnly
        qgaServiceHealthy = [bool](Get-Service -Name qemu-ga -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Running' })
        lastVerifiedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Set-ExchangeMappingTask {
    # QGA runs as SYSTEM, so mapping P: there would be invisible to the
    # interactive desktop. A per-user logon task repairs the mapping after
    # every AutoAdminLogon without storing a credential.
    $mapScript = Join-Path $policyDir 'map-exchange.ps1'
    @'
$ErrorActionPreference = 'SilentlyContinue'
cmd.exe /c 'net use P: /delete /y' | Out-Null
foreach ($target in @('\\10.0.2.4\qemu', '\\10.0.2.2\PZExchange')) {
    try {
        New-PSDrive -Name P -PSProvider FileSystem -Root $target -Persist -Scope Global -ErrorAction Stop | Out-Null
        exit 0
    } catch { }
}
exit 1
'@ | Set-Content -LiteralPath $mapScript -Encoding UTF8
    $taskUser = "$env:COMPUTERNAME\$UserName"
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$mapScript`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
    $principal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'PhaseZero-MapExchange' -TaskPath '\PhaseZero\' -Action $action -Trigger $trigger `
        -Principal $principal -Force | Out-Null
}

function Set-TouchInputPolicy {
    # Windows' device policy value 2 means "Always": tapping an editable field
    # opens the touch keyboard even though QEMU exposes a virtual USB keyboard.
    # QGA executes as LocalSystem, which is the partition required by the MDM
    # bridge for device policies. Older Windows builds may not expose the newer
    # property, so keep the per-user setting as a compatibility path.
    $cspApplied = $false
    try {
        $namespace = 'root\cimv2\mdm\dmmap'
        $class = 'MDM_Policy_Config01_TextInput02'
        $filter = "ParentID='./Vendor/MSFT/Policy/Config' and InstanceID='TextInput'"
        $policy = Get-CimInstance -Namespace $namespace -ClassName $class -Filter $filter -ErrorAction Stop
        if ($policy -and $policy.CimInstanceProperties['EnableTouchKeyboardAutoInvokeInDesktopMode']) {
            $policy.EnableTouchKeyboardAutoInvokeInDesktopMode = 2
            Set-CimInstance -CimInstance $policy -ErrorAction Stop | Out-Null
            $cspApplied = $true
        }
    } catch {
        Write-Verbose "TextInput CSP bridge unavailable: $($_.Exception.Message)"
    }

    $account = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND Name='$UserName'" -ErrorAction Stop |
        Select-Object -First 1
    if (-not $account) { throw "Managed guest user not found: $UserName" }
    $sid = [string]$account.SID
    $profile = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop
    if (-not $profile -or -not $profile.LocalPath) { throw "Guest profile not found: $UserName" }

    $hiveName = "PZTouchInput-$PID"
    $hiveRoot = "Registry::HKEY_USERS\$sid"
    $loadedHere = $false
    if (-not (Test-Path -LiteralPath $hiveRoot)) {
        & reg.exe load "HKU\$hiveName" (Join-Path $profile.LocalPath 'NTUSER.DAT') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to load guest user registry hive: $LASTEXITCODE" }
        $hiveRoot = "Registry::HKEY_USERS\$hiveName"
        $loadedHere = $true
    }
    try {
        $tabletTip = Join-Path $hiveRoot 'Software\Microsoft\TabletTip\1.7'
        New-Item -Path $tabletTip -Force | Out-Null
        New-ItemProperty -Path $tabletTip -Name EnableDesktopModeAutoInvoke -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -Path $tabletTip -Name TouchKeyboardTapInvoke -PropertyType DWord -Value 2 -Force | Out-Null
    } finally {
        if ($loadedHere) { & reg.exe unload "HKU\$hiveName" | Out-Null }
    }
    Start-Service -Name TabletInputService -ErrorAction SilentlyContinue
    $service = Get-Service -Name TabletInputService -ErrorAction SilentlyContinue
    [ordered]@{
        schemaVersion = 1
        user = $UserName
        touchKeyboardAutoInvoke = 'always'
        cspApplied = $cspApplied
        userSettingApplied = $true
        tabletInputServiceRunning = [bool]($service -and $service.Status -eq 'Running')
        appliedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Compress
}

function Set-RecoveryRemotePolicy([bool]$LocalOnly) {
    # User-right assignments are system policy, not per-account registry data.
    # Keep the temporary export inside the guest and remove it even on failure.
    $cfg = Join-Path $env:TEMP ('pz-recovery-' + [guid]::NewGuid().ToString('N') + '.inf')
    try {
        & secedit.exe /export /cfg $cfg /areas USER_RIGHTS | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to export local user rights' }
        $sid = ([System.Security.Principal.NTAccount]::new($env:COMPUTERNAME, $recoveryUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $text = Get-Content -LiteralPath $cfg -Raw
        foreach ($right in @('SeDenyNetworkLogonRight', 'SeDenyRemoteInteractiveLogonRight')) {
            $match = [regex]::Match($text, "(?m)^$right\s*=\s*(.*)$")
            $members = if ($match.Success -and $match.Groups[1].Value) { @($match.Groups[1].Value -split ',') } else { @() }
            $members = @($members | Where-Object { $_.TrimStart('*') -ne $sid })
            if ($LocalOnly) { $members += "*$sid" }
            $line = "$right = " + ($members -join ',')
            $text = if ($match.Success) { [regex]::Replace($text, "(?m)^$right\s*=.*$", [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $line }) } else { $text + "`r`n$line`r`n" }
        }
        Set-Content -LiteralPath $cfg -Value $text -Encoding Unicode
        & secedit.exe /configure /db (Join-Path $env:TEMP 'pz-recovery.sdb') /cfg $cfg /areas USER_RIGHTS | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to apply local recovery policy' }
    } finally {
        Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:TEMP 'pz-recovery.sdb') -Force -ErrorAction SilentlyContinue
    }
}

function Set-RecoveryAccount {
    $raw = if ($InputPath) { Get-Content -LiteralPath $InputPath -Raw } else { [Console]::In.ReadToEnd() }
    $payload = $raw | ConvertFrom-Json
    if (-not $payload.password) { throw 'recovery password missing' }
    $localOnly = ($payload.localOnly -ne $false)
    $account = Get-LocalUser -Name $recoveryUser -ErrorAction SilentlyContinue
    if (-not $account) { $account = New-LocalUser -Name $recoveryUser -NoPassword -AccountNeverExpires -Disabled }
    $adsi = [ADSI]("WinNT://./{0},user" -f $recoveryUser)
    $adsi.psbase.Invoke('SetPassword', @([string]$payload.password))
    $adsi.SetInfo()
    Enable-LocalUser -Name $recoveryUser
    $adminGroup = (Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop).Name
    if (-not (@(Get-LocalGroupMember -Group $adminGroup | Where-Object { $_.Name -match "\\\\$([regex]::Escape($recoveryUser))$" }).Count)) {
        Add-LocalGroupMember -Group $adminGroup -Member $recoveryUser
    }
    Set-RecoveryRemotePolicy $localOnly
    New-Item -Path $policyDir -ItemType Directory -Force | Out-Null
    @{ schemaVersion = 1; localOnly = $localOnly; updatedAt = (Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $recoveryPolicyFile -Encoding UTF8
    Get-RecoveryStatus | ConvertTo-Json -Compress
}

if ($Mode -eq 'status') {
    Get-PolicyStatus | ConvertTo-Json -Compress
    exit 0
}

if ($Mode -eq 'touch-input') {
    Set-TouchInputPolicy
    exit 0
}

if ($Mode -eq 'recovery-status') {
    Get-RecoveryStatus | ConvertTo-Json -Compress
    exit 0
}
if ($Mode -eq 'recovery-apply') {
    Set-RecoveryAccount
    exit 0
}
if ($Mode -eq 'recovery-enable') {
    Enable-LocalUser -Name $recoveryUser -ErrorAction Stop
    Get-RecoveryStatus | ConvertTo-Json -Compress
    exit 0
}
if ($Mode -eq 'recovery-disable') {
    Disable-LocalUser -Name $recoveryUser -ErrorAction Stop
    Get-RecoveryStatus | ConvertTo-Json -Compress
    exit 0
}

$raw = if ($InputPath) { Get-Content -LiteralPath $InputPath -Raw } else { [Console]::In.ReadToEnd() }
$payload = $raw | ConvertFrom-Json
if (-not $payload.username -or -not $payload.password) { throw 'username/password payload missing' }
$UserName = [string]$payload.username
$account = [ADSI]("WinNT://./{0},user" -f $UserName)
$account.psbase.Invoke('SetPassword', @([string]$payload.password))
$account.SetInfo()

New-Item -Path $policyDir -ItemType Directory -Force | Out-Null
Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue
Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value $UserName -Type String
Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String

if ($Mode -eq 'auto') {
    [PhaseZeroLsa]::Store('DefaultPassword', [string]$payload.password)
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1' -Type String
} else {
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0' -Type String
    [PhaseZeroLsa]::Store('DefaultPassword', $null)
}

Set-ExchangeMappingTask

@{
    schemaVersion = 1
    policy = $Mode
    user = $UserName
    appliedAt = (Get-Date).ToUniversalTime().ToString('o')
    secretLocation = if ($Mode -eq 'auto') { 'lsa' } else { 'none' }
} | ConvertTo-Json | Set-Content -LiteralPath $policyFile -Encoding UTF8

Get-PolicyStatus | ConvertTo-Json -Compress
