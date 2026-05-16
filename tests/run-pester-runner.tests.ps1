$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $PSScriptRoot 'run-pester.ps1'

. $runner -LibraryMode

Describe 'Pester runner dependency bootstrap' {
    It 'loads helper functions without running the suite in library mode' {
        Get-Command Resolve-PesterRunnerModule -ErrorAction SilentlyContinue | Should Not Be $null
        Get-Command Invoke-PesterRunnerBootstrapStep -ErrorAction SilentlyContinue | Should Not Be $null
    }

    It 'uses an already installed exact Pester version' {
        Mock Get-PesterRunnerAvailableModules {
            [pscustomobject]@{
                Name = 'Pester'
                Version = [version]'3.4.0'
                ModuleBase = 'C:\Pester\3.4.0'
            }
        }
        Mock Invoke-PesterRunnerBootstrapStep { throw 'Install should not run when Pester exists.' }

        $module = Resolve-PesterRunnerModule -RequiredVersion ([version]'3.4.0') -NoInstall:$false

        [string]$module.Version | Should Be '3.4.0'
        Assert-MockCalled Invoke-PesterRunnerBootstrapStep -Times 0
    }

    It 'fails early with an actionable install command when install is disabled' {
        Mock Get-PesterRunnerAvailableModules { @() }

        { Resolve-PesterRunnerModule -RequiredVersion ([version]'3.4.0') -NoInstall } |
            Should Throw 'Install-Module Pester -RequiredVersion 3.4.0 -Scope CurrentUser'
    }

    It 'bootstraps missing Pester with timeout guarded steps and validates after install' {
        $script:LookupCount = 0
        $script:Steps = @()
        Mock Get-PesterRunnerAvailableModules {
            $script:LookupCount++
            if ($script:LookupCount -lt 2) { return @() }
            return [pscustomobject]@{
                Name = 'Pester'
                Version = [version]'3.4.0'
                ModuleBase = 'C:\Pester\3.4.0'
            }
        }
        Mock Invoke-PesterRunnerBootstrapStep {
            param(
                [string]$Name,
                [scriptblock]$ScriptBlock,
                [int]$TimeoutSeconds,
                [int]$Attempts
            )
            $script:Steps += [pscustomobject]@{
                Name = $Name
                TimeoutSeconds = $TimeoutSeconds
                Attempts = $Attempts
            }
        }

        $module = Resolve-PesterRunnerModule -RequiredVersion ([version]'3.4.0') -NoInstall:$false -InstallTimeoutSeconds 123 -InstallAttempts 2

        [string]$module.Version | Should Be '3.4.0'
        @($script:Steps).Count | Should Be 2
        [string]$script:Steps[0].Name | Should Match 'NuGet'
        [string]$script:Steps[1].Name | Should Match 'Pester 3.4.0'
        [int]$script:Steps[0].TimeoutSeconds | Should Be 123
        [int]$script:Steps[1].Attempts | Should Be 2
    }
}
