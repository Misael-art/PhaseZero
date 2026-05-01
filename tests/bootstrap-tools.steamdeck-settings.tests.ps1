$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

function New-TestDataRoot {
    return (Join-Path $env:TEMP ("bootstrap_settings_{0}" -f ([guid]::NewGuid().ToString('N'))))
}

Describe 'Steam Deck settings schema' {
    BeforeEach {
        $script:PreviousBootstrapDataRoot = $env:BOOTSTRAP_DATA_ROOT
        $script:TestDataRoot = New-TestDataRoot
        $env:BOOTSTRAP_DATA_ROOT = $script:TestDataRoot
        . $scriptPath -BootstrapUiLibraryMode
    }

    AfterEach {
        $env:BOOTSTRAP_DATA_ROOT = $script:PreviousBootstrapDataRoot
        if (Test-Path $script:TestDataRoot) {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Variable -Scope Script -Name PreviousBootstrapDataRoot -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name TestDataRoot -ErrorAction SilentlyContinue
    }

    It 'keeps monitor families as a flat list of objects' {
        $bundle = Get-BootstrapSteamDeckSettingsData -RequestedSteamDeckVersion 'Auto' -ResolvedSteamDeckVersion 'lcd'
        $families = @($bundle.Data['monitorFamilies'])

        $families.Count | Should Be 1
        ($families[0] -is [System.Collections.IDictionary]) | Should Be $true
        [string]$families[0]['manufacturer'] | Should Be 'GSM'
        [string]$families[0]['product'] | Should Be 'LG HDR WFHD'
        [string]$bundle.Data['displayMode'] | Should Be 'extend'
        [bool]$bundle.Data['internalDisplay']['primary'] | Should Be $false
        [bool]$families[0]['primary'] | Should Be $true
    }

    It 'upgrades legacy single-object monitor profiles and families to flat arrays' {
        $settings = @{
            monitorProfiles = @{
                manufacturer = 'ACR'
                product = 'Portable'
                mode = 'DOCKED_MONITOR'
            }
            monitorFamilies = @{
                manufacturer = 'GSM'
                product = 'LG HDR WFHD'
                mode = 'DOCKED_MONITOR'
            }
        }

        $normalized = Normalize-BootstrapSteamDeckSettingsData -Settings $settings

        @($normalized['monitorProfiles']).Count | Should Be 1
        @($normalized['monitorFamilies']).Count | Should Be 1
        ($normalized['monitorProfiles'][0] -is [System.Collections.IDictionary]) | Should Be $true
        ($normalized['monitorFamilies'][0] -is [System.Collections.IDictionary]) | Should Be $true
    }

    It 'normalizes invalid display modes back to extend' {
        $normalized = Normalize-BootstrapSteamDeckSettingsData -Settings @{
            displayMode = 'external-only-but-not-supported'
            internalDisplay = @{
                manufacturer = 'VLV'
                product = 'ANX7530 U'
            }
        }

        [string]$normalized['displayMode'] | Should Be 'extend'
    }

    It 'repairs blank session profile values saved by the UI' {
        $normalized = Normalize-BootstrapSteamDeckSettingsData -Settings @{
            sessionProfiles = @{
                HANDHELD = ''
                DOCKED_TV = ''
                DOCKED_MONITOR = ''
            }
        }

        [string]$normalized['sessionProfiles']['HANDHELD'] | Should Be 'game-handheld'
        [string]$normalized['sessionProfiles']['DOCKED_TV'] | Should Be 'game-docked'
        [string]$normalized['sessionProfiles']['DOCKED_MONITOR'] | Should Be 'desktop'
    }
}
