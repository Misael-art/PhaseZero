param(
    [ValidateSet('auto', 'password', 'status', 'recovery-status', 'recovery-apply', 'recovery-enable', 'recovery-disable')]
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

function Get-GuestRuntimeStatus {
    # Status must remain available while networking or optional virtio devices
    # are still coming up.  Each probe therefore degrades to false instead of
    # turning a login-policy query into a QGA failure.
    $networkReady = $false
    $dnsReady = $false
    $exchangeMapped = $false
    $audioReady = $false
    $graphicsAdapters = @()
    try {
        $networkReady = @(Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }).Count -gt 0
    } catch { Write-Verbose 'Network readiness probe unavailable' }
    try {
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
    try {
        $graphicsAdapters = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
            ForEach-Object { $_.Name } | Where-Object { $_ })
    } catch { Write-Verbose 'Graphics readiness probe unavailable' }
    [ordered]@{
        networkReady = [bool]$networkReady
        dnsReady = [bool]$dnsReady
        exchangeMapped = [bool]$exchangeMapped
        audioReady = [bool]$audioReady
        graphicsAdapters = $graphicsAdapters
        graphicsReady = ($graphicsAdapters.Count -gt 0)
    }
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
        networkReady = $runtime.networkReady
        dnsReady = $runtime.dnsReady
        exchangeMapped = $runtime.exchangeMapped
        audioReady = $runtime.audioReady
        graphicsAdapters = $runtime.graphicsAdapters
        graphicsReady = $runtime.graphicsReady
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

@{
    schemaVersion = 1
    policy = $Mode
    user = $UserName
    appliedAt = (Get-Date).ToUniversalTime().ToString('o')
    secretLocation = if ($Mode -eq 'auto') { 'lsa' } else { 'none' }
} | ConvertTo-Json | Set-Content -LiteralPath $policyFile -Encoding UTF8

Get-PolicyStatus | ConvertTo-Json -Compress
