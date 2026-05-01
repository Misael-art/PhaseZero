$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath
Reset-BootstrapFileCmdlets

Describe 'Bootstrap apps and Windows boot manager' {
    It 'normalizes persisted UI category objects by id instead of Hashtable type name' {
        $names = Normalize-BootstrapNames -Names @(
            @{ id = 'gaming-console' },
            [pscustomobject]@{ id = 'dev-ai' },
            'browser-startup'
        )

        $names | Should Be @('gaming-console', 'dev-ai', 'browser-startup')
    }

    It 'adds on-demand app install rows to AppTuning' {
        $catalog = Get-BootstrapAppTuningCatalog
        $rows = Get-BootstrapAppTuningStatusRows -Plan ([ordered]@{ items = @(); installedInventory = @{} }) -InstalledInventory @{}
        $steam = $rows | Where-Object { $_.id -eq 'app-steam' } | Select-Object -First 1
        $photopea = $rows | Where-Object { $_.id -eq 'app-web-photopea' } | Select-Object -First 1

        (@($catalog.categories).id -contains 'app-install') | Should Be $false
        foreach ($categoryId in @('ia','comunicacao','design','office','produtividade','dev','sistema','drivers','utilitarios','seguranca','midia')) {
            (@($catalog.categories).id -contains $categoryId) | Should Be $true
        }
        $steam | Should Not Be $null
        (@($steam.installComponents) -contains 'steam') | Should Be $true
        [bool]$steam.canInstall | Should Be $true
        $photopea | Should Not Be $null
        (@($photopea.installComponents) -contains 'webapp-photopea') | Should Be $true
    }

    It 'parses Windows Boot Manager BCD output with display order and default entry' {
        $sample = @'
Windows Boot Manager
--------------------
identifier              {bootmgr}
displayorder            {current}
                        {11111111-1111-1111-1111-111111111111}
default                 {current}
timeout                 5

Windows Boot Loader
-------------------
identifier              {current}
device                  partition=C:
description             Windows 11
osdevice                partition=C:

Windows Boot Loader
-------------------
identifier              {11111111-1111-1111-1111-111111111111}
device                  unknown
description             Old Windows
osdevice                unknown
'@

        $state = Get-BootstrapWindowsBootManagerState -BcdText $sample

        $state.Default | Should Be '{current}'
        $state.ResolvedCurrent | Should Be '{11111111-1111-1111-1111-111111111111}'
        $state.ResolvedDefault | Should Be '{11111111-1111-1111-1111-111111111111}'
        $state.Timeout | Should Be 5
        @($state.DisplayOrder).Count | Should Be 2
        @($state.PhantomEntries).Count | Should Be 1
        $state.PhantomEntries[0].Description | Should Be 'Old Windows'
        @($state.Entries | Where-Object { $_.id -eq '{11111111-1111-1111-1111-111111111111}' })[0].isCurrent | Should Be $true
        @($state.Entries | Where-Object { $_.id -eq '{11111111-1111-1111-1111-111111111111}' })[0].isDefault | Should Be $true
    }

    It 'checks dictionary keys for hashtable and ordered dictionary safely' {
        $plain = @{ alpha = 1 }
        $ordered = [ordered]@{ beta = 2 }

        (Test-BootstrapMapContainsKey -Map $plain -Key 'alpha') | Should Be $true
        (Test-BootstrapMapContainsKey -Map $ordered -Key 'beta') | Should Be $true
        (Test-BootstrapMapContainsKey -Map $ordered -Key 'missing') | Should Be $false
    }

    It 'creates web app shortcut idempotently without duplicate files' {
        $tempRoot = Join-Path $env:TEMP ("bootstrap_webapp_{0}" -f ([Guid]::NewGuid().ToString('N')))
        $browserExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        try {
            Mock Get-BootstrapDesktopPath { return $tempRoot }
            Mock Get-BootstrapWebAppBrowserCandidate {
                return [ordered]@{
                    browser = 'edge'
                    exe = $browserExe
                    argsPrefix = '--app='
                }
            }

            $first = Ensure-BootstrapWebAppShortcut -DisplayName 'Photopea' -Url 'https://www.photopea.com/' -CategoryFolder 'Design'
            $second = Ensure-BootstrapWebAppShortcut -DisplayName 'Photopea' -Url 'https://www.photopea.com/' -CategoryFolder 'Design'
            $allLinks = @(Get-ChildItem -Path $tempRoot -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)

            $first.path | Should Be $second.path
            @($allLinks).Count | Should Be 1
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'does not fail the whole run for optional manual requirements in broad profiles' {
        $catalog = Get-BootstrapComponentCatalog
        $state = @{
            Completed = @{}
            ManualRequirements = New-Object System.Collections.Generic.List[object]
        }

        { Ensure-BootstrapManualRequirement -State $state -ComponentDef $catalog['google-app-desktop'] } | Should Not Throw

        $state.ManualRequirements.Count | Should Be 1
        [string]$state.ManualRequirements[0].component | Should Be 'google-app-desktop'
        [string]$state.ManualRequirements[0].status | Should Be 'manual-required'
    }

    It 'keeps host health and app tuning off for component-only runs unless explicitly requested' {
        $selection = [pscustomobject]@{
            Profiles = @()
            Components = @('google-app-desktop')
            Excludes = @()
            HostHealth = $null
            AppTuning = ''
            AppTuningCategories = @()
            AppTuningItems = @()
            ExcludedAppTuningItems = @()
        }
        $resolution = [ordered]@{
            ExpandedProfiles = @()
            ResolvedComponents = @('google-app-desktop')
        }

        Get-BootstrapDefaultHostHealthMode -Selection $selection -Resolution $resolution | Should Be 'off'
        $plan = Resolve-BootstrapAppTuningSelection -Mode '' -Categories @() -Items @() -ExcludedItems @() -Selection $selection -Resolution $resolution -InstalledInventory @{}

        [string]$plan.mode | Should Be 'off'
        @($plan.items).Count | Should Be 0
    }

    It 'normalizes ordered AppTuning item results before adding severity defaults' {
        $result = [ordered]@{
            id = 'sample'
            status = 'failed'
        }

        $normalized = Normalize-BootstrapAppTuningItemResult -Result $result

        ($normalized -is [hashtable]) | Should Be $true
        [string]$normalized['severity'] | Should Be 'blocking'
        [string]$normalized['classification'] | Should Be 'execution-failure'
        [bool]$normalized['blocking'] | Should Be $true
    }

    It 'serializes manual requirements into execution result JSON' {
        $tempResult = Join-Path $env:TEMP ("bootstrap_result_{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $state = New-BootstrapState -ResolvedWorkspaceRoot 'C:\ws' -ResolvedCloneBaseDir 'C:\clones'
        $state.ManualRequirements.Add([ordered]@{
            component = 'google-app-desktop'
            status = 'manual-required'
        }) | Out-Null

        try {
            Write-BootstrapExecutionResultFile -Path $tempResult -Value ([ordered]@{
                status = 'success'
                manualRequirements = @($state.ManualRequirements.ToArray())
            })
            $json = Get-Content -Path $tempResult -Raw | ConvertFrom-Json -ErrorAction Stop

            [string]$json.status | Should Be 'success'
            @($json.manualRequirements).Count | Should Be 1
            [string]$json.manualRequirements[0].component | Should Be 'google-app-desktop'
        } finally {
            if (Test-Path $tempResult) {
                Remove-Item -LiteralPath $tempResult -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
