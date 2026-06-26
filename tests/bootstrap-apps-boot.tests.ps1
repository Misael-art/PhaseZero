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

    It 'detects SteamOS EFI GRUB files without firmware admin access' {
        $root = Join-Path $env:TEMP ("pz-steamos-efi-{0}" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $efi = Join-Path $root 'EFI\steamos'
            New-Item -ItemType Directory -Path $efi -Force | Out-Null
            Set-Content -Path (Join-Path $efi 'grubx64.efi') -Value 'efi' -Encoding Ascii
            Set-Content -Path (Join-Path $efi 'grub.cfg') -Value 'timeout=0' -Encoding Ascii

            $installs = @(Get-BootstrapSteamOsEfiInstallations -RootPaths @($root))
            $grub = Get-BootstrapGrubPresence -SteamOsEfiInstallations $installs

            $installs.Count | Should Be 1
            [bool]$installs[0].customConfigManaged | Should Be $false
            [bool]$installs[0].grubConfigTimeoutZero | Should Be $true
            [bool]$grub.Detected | Should Be $true
            [string]$grub.Confidence | Should Be 'high'
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'writes a managed SteamOS GRUB Windows chainloader custom.cfg without replacing user content' {
        $root = Join-Path $env:TEMP ("pz-steamos-custom-{0}" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $efi = Join-Path $root 'EFI\steamos'
            New-Item -ItemType Directory -Path $efi -Force | Out-Null
            Set-Content -Path (Join-Path $efi 'grubx64.efi') -Value 'efi' -Encoding Ascii
            Set-Content -Path (Join-Path $efi 'grub.cfg') -Value 'source custom.cfg' -Encoding Ascii
            Set-Content -Path (Join-Path $efi 'custom.cfg') -Value '# user entry' -Encoding Ascii

            $result = Ensure-BootstrapSteamOsGrubDualBootMenu -RootPaths @($root)
            $custom = Get-Content -Path (Join-Path $efi 'custom.cfg') -Raw

            [bool]$result.changed | Should Be $true
            $custom | Should Match '# user entry'
            $custom | Should Match '# BEGIN PHASEZERO GRUB DUAL BOOT'
            $custom | Should Match 'Windows Boot Manager'
            $custom | Should Match 'bootmgfw\.efi'
            $custom | Should Match 'set timeout=5'
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'installs SteamOS GRUB as the safe UEFI fallback bootloader' {
        $root = Join-Path $env:TEMP ("pz-steamos-fallback-{0}" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $efi = Join-Path $root 'EFI\steamos'
            New-Item -ItemType Directory -Path $efi -Force | Out-Null
            Set-Content -Path (Join-Path $efi 'grubx64.efi') -Value 'grub-binary' -Encoding Ascii
            Set-Content -Path (Join-Path $efi 'grub.cfg') -Value 'source custom.cfg' -Encoding Ascii

            $result = Ensure-BootstrapSteamOsEfiFallbackBootloader -RootPaths @($root)
            $fallback = Join-Path $root 'EFI\Boot\bootx64.efi'

            [bool]$result.changed | Should Be $true
            (Test-Path -LiteralPath $fallback) | Should Be $true
            (Get-Content -LiteralPath $fallback -Raw) | Should Match 'grub-binary'
        } finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'executes dualboot-manager builtin instead of failing unsupported kind' {
        $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\ws' -ResolvedCloneBaseDir 'C:\clones' -IsDryRun:$true
        Mock Get-BootstrapDualBootInfo {
            return @{
                IsDualBoot = $true
                GrubDetected = $true
                GrubEfiPath = 'D:\EFI\steamos\grubx64.efi'
                LinuxPartitions = @()
                SteamOsEfiInstallations = @(
                    [pscustomobject]@{
                        root = 'D:\'
                        customConfigManaged = $false
                        grubConfigHasWindowsEntry = $false
                        fallbackBootMatchesGrub = $false
                    }
                )
                FastStartup = @{ Enabled = $false }
                BitLocker = @{ CEnabled = $false }
                IsAdmin = $true
                Warnings = @()
            }
        }
        Mock Get-BootstrapDualBootRecommendations { return @('[ACAO] aplicar GRUB seguro') }
        Mock Ensure-BootstrapSteamOsGrubDualBootMenu {
            return [ordered]@{ success = $true; changed = $false; dryRun = [bool]$DryRun; installations = @() }
        }
        Mock Ensure-BootstrapSteamOsEfiFallbackBootloader {
            return [ordered]@{ success = $true; changed = $false; dryRun = [bool]$DryRun; installations = @() }
        }
        Mock Write-Log {}

        { Invoke-BootstrapComponent -Name 'dualboot-manager' -State $state } | Should Not Throw

        $state.Completed.ContainsKey('dualboot-manager') | Should Be $true
        Assert-MockCalled Ensure-BootstrapSteamOsGrubDualBootMenu -Times 1 -Exactly -Scope It
        Assert-MockCalled Ensure-BootstrapSteamOsEfiFallbackBootloader -Times 1 -Exactly -Scope It
    }

    It 'parses firmware boot manager SteamOS candidates and plans persistent boot order safely' {
        $sample = @'
Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
displayorder            {aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}
                        {bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}
bootsequence            {fwsetup}

Firmware Application (101fffff)
-------------------------------
identifier              {aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}
description             SteamOS
path                    \EFI\steamos\grubx64.efi

Firmware Application (101fffff)
-------------------------------
identifier              {bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}
description             Windows Boot Manager
path                    \EFI\Microsoft\Boot\bootmgfw.efi
'@

        $state = Get-BootstrapFirmwareBootManagerState -BcdText $sample
        $plan = Set-BootstrapFirmwareBootDefault -EntryGuid '{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}' -BcdText $sample -DryRun

        @($state.SteamOsCandidates).Count | Should Be 1
        [string]$state.SteamOsCandidates[0].description | Should Be 'SteamOS'
        [string]$state.BootSequence | Should Be '{fwsetup}'
        [bool]$plan.DryRun | Should Be $true
        (@($plan.Actions) -contains 'displayorder-addfirst={aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}') | Should Be $true
        (@($plan.Actions) -contains 'clear-bootsequence') | Should Be $true
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
        $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\ws' -ResolvedCloneBaseDir 'C:\clones'
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

    It 'detects protected temp artifacts before HostHealth cleanup' {
        (Test-BootstrapHostHealthProtectedTempItem -Path (Join-Path $env:TEMP 'codex-index-cache')) | Should Be $true
        (Test-BootstrapHostHealthProtectedTempItem -Path (Join-Path $env:TEMP 'node-repl-kernel-assets')) | Should Be $true
        (Test-BootstrapHostHealthProtectedTempItem -Path (Join-Path $env:TEMP 'bootstrap-tools\ui.log')) | Should Be $true
        (Test-BootstrapHostHealthProtectedTempItem -Path (Join-Path $env:TEMP 'ordinary-delete.tmp')) | Should Be $false
    }

    It 'preserves protected temp directories while clearing ordinary temp items' {
        $tempRoot = Join-Path $env:TEMP ("bootstrap_cleanup_{0}" -f ([Guid]::NewGuid().ToString('N')))
        $protectedDir = Join-Path $tempRoot 'codex-index-cache'
        $ordinaryDir = Join-Path $tempRoot 'ordinary-cache'
        $ordinaryFile = Join-Path $tempRoot 'ordinary-delete.tmp'

        try {
            $null = New-Item -Path $protectedDir -ItemType Directory -Force
            $null = New-Item -Path $ordinaryDir -ItemType Directory -Force
            Set-Content -Path (Join-Path $protectedDir 'state.json') -Value '{}' -Encoding utf8
            Set-Content -Path (Join-Path $ordinaryDir 'state.json') -Value '{}' -Encoding utf8
            Set-Content -Path $ordinaryFile -Value 'delete' -Encoding utf8
            Mock Write-Log { }

            Clear-BootstrapDirectoryContents -TargetPath $tempRoot

            (Test-Path $protectedDir) | Should Be $true
            (Test-Path $ordinaryDir) | Should Be $false
            (Test-Path $ordinaryFile) | Should Be $false
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
