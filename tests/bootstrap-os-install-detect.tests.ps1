$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'OS install host profile' {
    It 'recommends the official SteamOS recovery image on a Valve Steam Deck' {
        Mock Get-BootstrapHostManufacturerModel { [ordered]@{ manufacturer = 'Valve'; model = 'Jupiter' } }
        $p = Get-BootstrapOsInstallHostProfile
        $p.hostType | Should Be 'steam-deck'
        $p.isSteamDeck | Should Be $true
        $p.recommendedImage | Should Be 'steamos-recovery'
    }

    It 'recommends Bazzite on a generic PC' {
        Mock Get-BootstrapHostManufacturerModel { [ordered]@{ manufacturer = 'ASUSTeK'; model = 'ROG' } }
        $p = Get-BootstrapOsInstallHostProfile
        $p.hostType | Should Be 'generic-pc'
        $p.isSteamDeck | Should Be $false
        $p.recommendedImage | Should Be 'bazzite'
    }
}

Describe 'OS install image catalog' {
    It 'exposes steamos-recovery and bazzite with checksum policy and official source' {
        $catalog = Get-BootstrapOsImageCatalog
        $catalog.Contains('steamos-recovery') | Should Be $true
        $catalog.Contains('bazzite') | Should Be $true
        [string]$catalog['steamos-recovery'].kind | Should Be 'raw-img'
        [string]$catalog['steamos-recovery'].checksumPolicy | Should Be 'manual-verify'
        [string]$catalog['bazzite'].kind | Should Be 'iso'
        [string]$catalog['bazzite'].officialSource | Should Match 'bazzite'
    }
}

Describe 'OS install plan (read-only)' {
    It 'recommends a dedicated disk and excludes VM passthrough for the raw SteamOS image' {
        Mock Get-BootstrapHostManufacturerModel { [ordered]@{ manufacturer = 'Valve'; model = 'Galileo' } }
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'Windows SSD'; SizeGB = 512; BusType = 'NVMe'; Partitions = @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'System'; SizeGB = 0.1; FileSystem = 'FAT32'; DriveLetter = ''; IsBoot = $false; IsSystem = $true },
                    [pscustomobject]@{ PartitionNumber = 2; Type = 'Basic'; SizeGB = 480; FileSystem = 'NTFS'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false }
                ) },
                [pscustomobject]@{ Number = 2; FriendlyName = 'Dedicated Linux SSD'; SizeGB = 1000; BusType = 'SATA'; Partitions = @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 1000; FileSystem = 'ext4'; DriveLetter = ''; IsBoot = $false; IsSystem = $false }
                ) }
            )
        }
        Mock Get-BootstrapDualBootInfo { @{ Warnings = @() } }

        $plan = Get-BootstrapOsInstallPlan
        $plan.recommendedImage | Should Be 'steamos-recovery'
        $plan.recommendedTarget | Should Be 2
        (@($plan.eligibleMethods) -contains 'native-installer') | Should Be $true
        (@($plan.eligibleMethods) -contains 'vm-raw-passthrough') | Should Be $false
        $plan.neverWritesDisk | Should Be $true
    }

    It 'blocks when there is no dedicated disk' {
        Mock Get-BootstrapHostManufacturerModel { [ordered]@{ manufacturer = 'Dell'; model = 'XPS' } }
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @( [pscustomobject]@{ Number = 0; FriendlyName = 'Only Windows'; SizeGB = 512; BusType = 'NVMe'; Partitions = @(
                [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 480; FileSystem = 'NTFS'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false }
            ) } )
        }
        Mock Get-BootstrapDualBootInfo { @{ Warnings = @() } }
        $plan = Get-BootstrapOsInstallPlan
        $plan.recommendedTarget | Should Be $null
        (@($plan.blockReasons) -contains 'no-dedicated-disk') | Should Be $true
        @($plan.eligibleMethods).Count | Should Be 0
    }

    It 'keeps VM passthrough eligible for Bazzite on a dedicated disk (generic PC)' {
        Mock Get-BootstrapHostManufacturerModel { [ordered]@{ manufacturer = 'MSI'; model = 'Z790' } }
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'Win'; SizeGB = 512; BusType = 'NVMe'; Partitions = @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 480; FileSystem = 'NTFS'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false }
                ) },
                [pscustomobject]@{ Number = 1; FriendlyName = 'Empty Linux disk'; SizeGB = 500; BusType = 'SATA'; Partitions = @() }
            )
        }
        Mock Get-BootstrapDualBootInfo { @{ Warnings = @() } }
        $plan = Get-BootstrapOsInstallPlan
        $plan.recommendedImage | Should Be 'bazzite'
        $plan.recommendedTarget | Should Be 1
        (@($plan.eligibleMethods) -contains 'vm-raw-passthrough') | Should Be $true
    }
}
