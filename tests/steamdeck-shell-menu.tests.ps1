$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Steam Deck shell menu maintenance' {
    It 'detects elevated admin or system context as boolean' {
        $value = Test-BootstrapElevatedOrSystem

        ($value -is [bool]) | Should Be $true
    }

    It 'builds desktop background shell menu spec without writing registry' {
        $spec = Get-BootstrapSteamDeckShellMenuSpec

        [string]$spec.RootPath | Should Be 'HKLM:\SOFTWARE\Classes\DesktopBackground\Shell\ZBootstrapSteamDeck'
        @($spec.Commands | ForEach-Object { [string]$_.Id }) | Should Be @(
            'power-save',
            'power-balanced',
            'power-performance',
            'windows-update-now',
            'compact-os',
            'restore-point',
            'clear-caches',
            'clear-standby-memory',
            'apply-sharedvram-launch-options'
        )
    }

    It 'supports dry-run shell menu install report' {
        $result = Install-BootstrapSteamDeckShellMenu -DryRun

        [bool]$result.DryRun | Should Be $true
        [bool]$result.Changed | Should Be $false
        [string]$result.RegistryPath | Should Be 'HKLM:\SOFTWARE\Classes\DesktopBackground\Shell\ZBootstrapSteamDeck'
    }

    It 'propagates component dry-run to shell menu installation' {
        $state = @{
            Completed = @{}
            IsDryRun = $true
        }

        { Invoke-BootstrapComponent -Name 'steamdeck-shell-menu' -State $state } | Should Not Throw
        [bool]$state.Completed['steamdeck-shell-menu'] | Should Be $true
    }

    It 'keeps all maintenance scripts parseable' {
        $maintenanceRoot = Join-Path $repoRoot 'assets\steamdeck\maintenance'

        foreach ($file in @(Get-ChildItem -Path $maintenanceRoot -Filter '*.ps1')) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null

            @($errors).Count | Should Be 0
        }
    }
}
