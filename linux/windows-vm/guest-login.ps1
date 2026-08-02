param(
    [ValidateSet('auto', 'password', 'status')]
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
    } catch {}
    try {
        $dnsReady = @(Resolve-DnsName -Name microsoft.com -Type A -DnsOnly -QuickTimeout -ErrorAction Stop).Count -gt 0
    } catch {}
    try {
        foreach ($hive in Get-ChildItem Registry::HKEY_USERS -ErrorAction Stop) {
            if ($hive.PSChildName -notmatch '^S-1-5-21-') { continue }
            $drive = "Registry::HKEY_USERS\$($hive.PSChildName)\Network\P"
            if (Test-Path -LiteralPath $drive) { $exchangeMapped = $true; break }
        }
    } catch {}
    try {
        $audioReady = @(Get-CimInstance Win32_SoundDevice -ErrorAction Stop |
            Where-Object { $_.Status -eq 'OK' }).Count -gt 0
    } catch {}
    try {
        $graphicsAdapters = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
            ForEach-Object { $_.Name } | Where-Object { $_ })
    } catch {}
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
    }
}

if ($Mode -eq 'status') {
    Get-PolicyStatus | ConvertTo-Json -Compress
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
