$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Drift detection (snapshot / compare / severity)' {
    It 'ranks severities (ok < atencao < critico)' {
        Get-BootstrapCheckSeverityRank -Status 'healthy' | Should Be 0
        Get-BootstrapCheckSeverityRank -Status 'warning' | Should Be 1
        Get-BootstrapCheckSeverityRank -Status 'missing' | Should Be 1
        Get-BootstrapCheckSeverityRank -Status 'error'   | Should Be 2
        Get-BootstrapCheckSeverityRank -Status 'critical' | Should Be 2
        Get-BootstrapCheckSeverityRank -Status 'admin'   | Should Be 0
    }

    It 'builds a snapshot map from a doctor report' {
        $doctor = [ordered]@{ checks = @(
            [ordered]@{ id = 'winget'; status = 'healthy' },
            [ordered]@{ id = 'wsl'; status = 'warning' },
            [ordered]@{ id = ''; status = 'healthy' }
        ) }
        $snap = Get-BootstrapDriftSnapshotFromDoctor -DoctorReport $doctor
        $map = Get-BootstrapDriftChecksMap -Snapshot $snap
        $map['winget'] | Should Be 'healthy'
        $map['wsl'] | Should Be 'warning'
        $map.ContainsKey('') | Should Be $false
    }

    It 'flags only checks that got worse as regressions' {
        $baseline = [ordered]@{ checks = [ordered]@{ winget = 'healthy'; wsl = 'healthy'; secrets = 'warning' } }
        $current  = [ordered]@{ checks = [ordered]@{ winget = 'warning'; wsl = 'healthy'; secrets = 'healthy'; novo = 'error' } }
        $reg = @(Compare-BootstrapDriftSnapshot -Baseline $baseline -Current $current)
        @($reg).Count | Should Be 1
        [string]$reg[0].id | Should Be 'winget'
        [string]$reg[0].from | Should Be 'healthy'
        [string]$reg[0].to | Should Be 'warning'
    }

    It 'reports no regression when status improves or is unchanged' {
        $baseline = [ordered]@{ checks = [ordered]@{ a = 'error'; b = 'healthy' } }
        $current  = [ordered]@{ checks = [ordered]@{ a = 'healthy'; b = 'healthy' } }
        @(Compare-BootstrapDriftSnapshot -Baseline $baseline -Current $current).Count | Should Be 0
    }

    It 'exposes a stable drift task name and a state shape' {
        Get-BootstrapDriftCheckTaskName | Should Be 'BootstrapTools-DriftCheck'
        $state = Get-BootstrapDriftCheckTaskState
        ($state.PSObject.Properties.Name -contains 'registered') -or ($state.Contains('registered')) | Should Be $true
    }
}
