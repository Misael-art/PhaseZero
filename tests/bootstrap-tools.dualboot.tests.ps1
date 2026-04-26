$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

. $scriptPath -BootstrapUiLibraryMode

$script:OriginalFunctions = @{}

function Mock-Function {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:OriginalFunctions[$Name] = $cmd.Definition
    }
    Set-Item -Path "function:script:$Name" -Value $ScriptBlock
}

function Restore-Function {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($script:OriginalFunctions.ContainsKey($Name)) {
        $body = $script:OriginalFunctions[$Name]
        Set-Item -Path "function:script:$Name" -Value ([scriptblock]::Create($body))
        $script:OriginalFunctions.Remove($Name)
    }
}

function Assert-True {
    param([Parameter(Mandatory = $true)]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equals {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message`nExpected=$Expected`nActual=$Actual"
    }
}

function Test-PhantomPreviewEmpty {
    Mock-Function -Name 'Get-BootstrapPhantomBootEntries' -ScriptBlock { ,@() }
    $preview = Get-BootstrapPhantomBootEntriesPreview
    Assert-Equals -Actual ([int]$preview.Count) -Expected 0 -Message 'Phantom preview count should be 0 when no phantoms.'
    Restore-Function -Name 'Get-BootstrapPhantomBootEntries'
}

function Test-PhantomPreviewLines {
    Mock-Function -Name 'Get-BootstrapPhantomBootEntries' -ScriptBlock {
        @(
            @{ Id = '{aaaa-bbbb}'; Description = 'Old Windows' },
            @{ Id = '{cccc-dddd}'; Description = 'Stale loader' }
        )
    }
    $preview = Get-BootstrapPhantomBootEntriesPreview
    Assert-Equals -Actual $preview.Count -Expected 2 -Message 'Phantom preview count should match.'
    $joined = ($preview.Lines -join "`n")
    Assert-True -Condition ($joined -match 'aaaa-bbbb') -Message 'Preview must include first GUID.'
    Assert-True -Condition ($joined -match 'cccc-dddd') -Message 'Preview must include second GUID.'
    Restore-Function -Name 'Get-BootstrapPhantomBootEntries'
}

function Test-DualBootRecommendationsNoDualBoot {
    $info = @{
        IsDualBoot      = $false
        FastStartup     = @{ Enabled = $false }
        BitLocker       = @{ CEnabled = $false }
        GrubDetected    = $false
        GrubEfiPath     = ''
        LinuxPartitions = @()
    }
    $recs = @(Get-BootstrapDualBootRecommendations -DualBootInfo $info)
    Assert-Equals -Actual $recs.Count -Expected 1 -Message 'Should return single "no action" recommendation.'
    Assert-True -Condition ($recs[0] -match 'Nenhum dual boot') -Message 'Should indicate no dual boot.'
}

function Test-DualBootRecommendationsAllFlags {
    $info = @{
        IsDualBoot      = $true
        FastStartup     = @{ Enabled = $true }
        BitLocker       = @{ CEnabled = $true }
        GrubDetected    = $true
        GrubEfiPath     = '\EFI\ubuntu\grubx64.efi'
        LinuxPartitions = @(@{ DiskNumber = 0; PartitionNumber = 5 })
    }
    $recs = Get-BootstrapDualBootRecommendations -DualBootInfo $info
    $joined = ($recs -join "`n")
    Assert-True -Condition ($joined -match 'CRITICO') -Message 'Should include critical Fast Startup recommendation.'
    Assert-True -Condition ($joined -match 'BitLocker') -Message 'Should include BitLocker warning.'
    Assert-True -Condition ($joined -match 'GRUB') -Message 'Should include GRUB info.'
    Assert-True -Condition (($joined -match 'particao') -or ($joined -match 'partição')) -Message 'Should include partition info.'
}

function Test-DualBootPrereqsHasFastStartupIssue {
    Mock-Function -Name 'Get-BootstrapFastStartupStatus' -ScriptBlock { @{ Enabled = $true; Safe = $false; Value = 1; RegistryPath = 'X' } }
    Mock-Function -Name 'Get-BootstrapBitLockerStatus' -ScriptBlock { @{ CEnabled = $false; StatusText = 'disabled' } }
    $issues = Test-BootstrapDualBootPrerequisites
    Assert-True -Condition (@($issues).Count -ge 1) -Message 'Should return at least one issue.'
    $fs = $issues | Where-Object { $_.Id -eq 'fast-startup' } | Select-Object -First 1
    Assert-True -Condition ($null -ne $fs) -Message 'Should detect fast-startup issue.'
    Assert-Equals -Actual $fs.Severity -Expected 'critical' -Message 'Fast Startup must be critical.'
    Restore-Function -Name 'Get-BootstrapFastStartupStatus'
    Restore-Function -Name 'Get-BootstrapBitLockerStatus'
}

Test-DualBootRecommendationsNoDualBoot
Test-DualBootRecommendationsAllFlags
Test-PhantomPreviewEmpty
Test-PhantomPreviewLines
Test-DualBootPrereqsHasFastStartupIssue

Write-Host 'dualboot tests: ok'
