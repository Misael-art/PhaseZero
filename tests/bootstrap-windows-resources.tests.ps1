$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

. $scriptPath
Reset-BootstrapFileCmdlets

Describe 'Windows resources catalog' {
    It 'declares conservative Windows feature and support app components' {
        $catalog = Get-BootstrapComponentCatalog

        foreach ($name in @('hyper-v','hyper-v-tools','windows-hypervisor-platform','openssh-client','openssh-server','3d-viewer','winhance')) {
            $catalog.Contains($name) | Should Be $true
        }

        $catalog['hyper-v'].Kind | Should Be 'windows-feature'
        (@($catalog['hyper-v'].FeatureNames) -contains 'Microsoft-Hyper-V-All') | Should Be $true

        $catalog['hyper-v-tools'].Kind | Should Be 'windows-feature'
        (@($catalog['hyper-v-tools'].FeatureNames) -contains 'Microsoft-Hyper-V-Management-Clients') | Should Be $true
        (@($catalog['hyper-v-tools'].FeatureNames) -contains 'Microsoft-Hyper-V-Management-PowerShell') | Should Be $true

        $catalog['windows-hypervisor-platform'].Kind | Should Be 'windows-feature'
        (@($catalog['windows-hypervisor-platform'].FeatureNames) -contains 'HypervisorPlatform') | Should Be $true

        $catalog['openssh-client'].Kind | Should Be 'windows-capability'
        (@($catalog['openssh-client'].CapabilityNames) -contains 'OpenSSH.Client~~~~0.0.1.0') | Should Be $true
        (@($catalog['openssh-client'].CommandNames) -contains 'ssh') | Should Be $true

        $catalog['openssh-server'].Kind | Should Be 'windows-capability'
        (@($catalog['openssh-server'].CapabilityNames) -contains 'OpenSSH.Server~~~~0.0.1.0') | Should Be $true
        $catalog['openssh-server'].ServiceName | Should Be 'sshd'
        (@($catalog['openssh-server'].FirewallProfiles) -contains 'Domain') | Should Be $true
        (@($catalog['openssh-server'].FirewallProfiles) -contains 'Private') | Should Be $true
        (@($catalog['openssh-server'].FirewallProfiles) -contains 'Public') | Should Be $false

        $catalog['3d-viewer'].Kind | Should Be 'winget'
        $catalog['3d-viewer'].Id | Should Be '9NBLGGH42THS'
        (@($catalog['3d-viewer'].AppxPackageNames) -contains 'Microsoft.Microsoft3DViewer') | Should Be $true

        $catalog['winhance'].Kind | Should Be 'winhance'
        $catalog['winhance'].InstallCommand | Should Be 'download-validate-execute https://get.winhance.net/'
        $catalog['winhance'].SourceUrl | Should Be 'https://get.winhance.net/'
    }

    It 'keeps Windows resources opt-in and out of safe-base public-beta profiles' {
        $profiles = Get-BootstrapProfileCatalog
        $windowsResources = @('hyper-v','hyper-v-tools','windows-hypervisor-platform','openssh-client','openssh-server','3d-viewer','winhance')

        foreach ($profileName in @('safe-base','public-beta')) {
            foreach ($resource in $windowsResources) {
                (@($profiles[$profileName].Items) -contains $resource) | Should Be $false
            }
        }
    }
}

Describe 'Windows resources execution guards' {
    It 'plans Windows feature dry-run without mutation' {
        $state = New-BootstrapState -Selection ([pscustomobject]@{ Profiles = @(); Components = @() }) -ResolvedWorkspaceRoot $repoRoot -ResolvedCloneBaseDir $repoRoot -IsDryRun $true
        $catalog = Get-BootstrapComponentCatalog
        $result = Ensure-BootstrapWindowsFeatureComponent -State $state -ComponentName 'hyper-v' -ComponentDef $catalog['hyper-v']

        $result.status | Should Be 'planned'
        $result.dryRun | Should Be $true
        (@($result.featureNames) -contains 'Microsoft-Hyper-V-All') | Should Be $true
    }

    It 'blocks OpenSSH Server firewall from Public profile by default' {
        $catalog = Get-BootstrapComponentCatalog
        $state = New-BootstrapState -Selection ([pscustomobject]@{ Profiles = @(); Components = @() }) -ResolvedWorkspaceRoot $repoRoot -ResolvedCloneBaseDir $repoRoot -IsDryRun $true
        $result = Ensure-BootstrapWindowsCapabilityComponent -State $state -ComponentName 'openssh-server' -ComponentDef $catalog['openssh-server']

        $result.status | Should Be 'planned'
        (@($result.firewallProfiles) -contains 'Domain') | Should Be $true
        (@($result.firewallProfiles) -contains 'Private') | Should Be $true
        (@($result.firewallProfiles) -contains 'Public') | Should Be $false
    }

    It 'plans Winhance official installer without applying tweaks in dry-run' {
        $catalog = Get-BootstrapComponentCatalog
        $state = New-BootstrapState -Selection ([pscustomobject]@{ Profiles = @(); Components = @() }) -ResolvedWorkspaceRoot $repoRoot -ResolvedCloneBaseDir $repoRoot -IsDryRun $true
        $result = Install-BootstrapWinhanceComponent -State $state -ComponentDef $catalog['winhance']

        $result.status | Should Be 'planned'
        $result.tweaksApplied | Should Be $false
        $result.sourceUrl | Should Be 'https://get.winhance.net/'
    }
}

Describe 'Native summary output hygiene' {
    It 'removes NUL bytes from corrupt native output before logging' {
        $clean = ConvertTo-BootstrapSafeNativeSummaryLine -Value ([string]([char]0) + 'Classe' + [string]([char]0) + ' n�o' + [string]([char]0))
        $clean.Contains([string][char]0) | Should Be $false
        $clean.Contains([string][char]0xFFFD) | Should Be $false
        $clean | Should Be 'Classe no'
    }

    It 'times out native summary commands quickly' {
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $line = Invoke-NativeFirstLine -Exe $powershellExe -Arguments @('-NoProfile','-Command','Start-Sleep -Seconds 10; Write-Output late') -TimeoutMs 1000

        $line | Should Match 'timeout'
    }
}

Describe 'App tuning probe timeouts' {
    It 'returns a timeout marker instead of waiting forever' {
        $result = Invoke-BootstrapScriptBlockWithTimeout -Name 'slow-test-probe' -TimeoutSeconds 1 -ScriptBlock { Start-Sleep -Seconds 10; return 'late' }

        $result.timedOut | Should Be $true
        $result.status | Should Be 'timeout'
    }

    It 'tolerates missing DeviceGuard properties during security posture audit' {
        Mock Get-BootstrapServiceSnapshot { return [ordered]@{ name = $Name; exists = $false } }
        Mock Invoke-BootstrapScriptBlockWithTimeout { return [ordered]@{ status = 'ok'; timedOut = $false; value = [ordered]@{ available = $true; exclusionPath = @(); exclusionProcess = @() }; error = '' } }
        Mock Get-ItemProperty { return [pscustomobject]@{} }
        Mock Get-Process { return @() }

        $audit = Get-BootstrapAiAgentPerformanceAudit

        $audit.deviceGuard.enableVirtualizationBasedSecurity | Should Be ''
        $audit.defender.available | Should Be $true
    }
}
