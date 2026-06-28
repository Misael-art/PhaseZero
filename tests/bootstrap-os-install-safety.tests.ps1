$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'OS install disk topology classification' {
    It 'flags a disk with Windows partitions and clears a dedicated Linux disk' {
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'Win'; SizeGB = 512; BusType = 'NVMe'; Partitions = @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'System'; SizeGB = 0.1; FileSystem = 'FAT32'; DriveLetter = ''; IsBoot = $false; IsSystem = $true },
                    [pscustomobject]@{ PartitionNumber = 2; Type = 'Basic'; SizeGB = 480; FileSystem = 'NTFS'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false },
                    [pscustomobject]@{ PartitionNumber = 3; Type = 'Recovery'; SizeGB = 1; FileSystem = 'NTFS'; DriveLetter = ''; IsBoot = $false; IsSystem = $false }
                ) },
                [pscustomobject]@{ Number = 1; FriendlyName = 'Linux'; SizeGB = 1000; BusType = 'SATA'; Partitions = @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 1000; FileSystem = 'ext4'; DriveLetter = ''; IsBoot = $false; IsSystem = $false }
                ) }
            )
        }
        $topo = Get-BootstrapOsInstallDiskTopology
        $win = @($topo | Where-Object { $_.diskNumber -eq 0 })[0]
        $lin = @($topo | Where-Object { $_.diskNumber -eq 1 })[0]
        $win.hasWindows | Should Be $true
        $win.isDedicatedLinuxCandidate | Should Be $false
        $lin.hasWindows | Should Be $false
        $lin.isDedicatedLinuxCandidate | Should Be $true
    }
}

Describe 'OS install target safety (hard rule)' {
    It 'NEVER marks a disk with Windows partitions as a safe install target' {
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @( [pscustomobject]@{ Number = 0; FriendlyName = 'Win'; SizeGB = 512; BusType = 'NVMe'; Partitions = @(
                [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 480; FileSystem = 'NTFS'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false }
            ) } )
        }
        $safety = Test-BootstrapOsInstallTargetSafe -DiskNumber 0
        $safety.safe | Should Be $false
        (@($safety.reasons) -contains 'disk-contains-windows-partitions') | Should Be $true
        @($safety.allowedMethods).Count | Should Be 0
    }

    It 'allows raw passthrough and native installer only on a dedicated disk' {
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @( [pscustomobject]@{ Number = 3; FriendlyName = 'Dedicated'; SizeGB = 1000; BusType = 'SATA'; Partitions = @(
                [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 1000; FileSystem = 'ext4'; DriveLetter = ''; IsBoot = $false; IsSystem = $false }
            ) } )
        }
        $safety = Test-BootstrapOsInstallTargetSafe -DiskNumber 3
        $safety.safe | Should Be $true
        $safety.isDedicated | Should Be $true
        (@($safety.allowedMethods) -contains 'vm-raw-passthrough') | Should Be $true
        (@($safety.allowedMethods) -contains 'native-installer') | Should Be $true
    }

    It 'returns not-found for an unknown disk number' {
        Mock Get-BootstrapPhysicalDisksSnapshot { @() }
        $safety = Test-BootstrapOsInstallTargetSafe -DiskNumber 9
        $safety.safe | Should Be $false
        (@($safety.reasons) -contains 'disk-not-found') | Should Be $true
    }

    It 'treats an empty (unpartitioned) disk as a dedicated candidate' {
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @( [pscustomobject]@{ Number = 4; FriendlyName = 'Blank'; SizeGB = 250; BusType = 'SATA'; Partitions = @() } )
        }
        (Test-BootstrapOsInstallTargetSafe -DiskNumber 4).safe | Should Be $true
    }
}

Describe 'OS install VM raw passthrough safety' {
    It 'New-BootstrapRawVmdkPlan blocks a disk with Windows partitions and never yields a command' {
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @( [pscustomobject]@{ Number = 0; FriendlyName = 'Win'; SizeGB = 512; BusType = 'NVMe'; Partitions = @(
                [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 480; FileSystem = 'NTFS'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false }
            ) } )
        }
        $plan = New-BootstrapRawVmdkPlan -DiskNumber 0 -OutputPath 'X:\rawdisk.vmdk'
        [string]$plan.status | Should Be 'blocked'
        ($plan.PSObject.Properties.Name -contains 'command') | Should Be $false
    }

    It 'New-BootstrapRawVmdkPlan maps the correct PhysicalDrive for a dedicated disk' {
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @( [pscustomobject]@{ Number = 3; FriendlyName = 'Dedicated'; SizeGB = 1000; BusType = 'SATA'; Partitions = @(
                [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 1000; FileSystem = 'ext4'; DriveLetter = ''; IsBoot = $false; IsSystem = $false }
            ) } )
        }
        $plan = New-BootstrapRawVmdkPlan -DiskNumber 3 -OutputPath 'X:\rawdisk-3.vmdk'
        [string]$plan.status | Should Be 'ready'
        # Evita backslash duplo literal (linter colapsa): valida sufixo e presenca no comando.
        ([string]$plan.physicalDrive).EndsWith('PhysicalDrive3') | Should Be $true
        ([string]$plan.physicalDrive).StartsWith([string][char]92) | Should Be $true
        @(@($plan.command) | Where-Object { $_ -like '*PhysicalDrive3' }).Count | Should Be 1
    }

    It 'os-install-vm on a shared (Windows) disk blocks and never calls VBoxManage' {
        Mock Get-BootstrapHostManufacturerModel { [ordered]@{ manufacturer = 'MSI'; model = 'Z790' } } # generic PC -> bazzite (VM eligible)
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @( [pscustomobject]@{ Number = 0; FriendlyName = 'Only Windows'; SizeGB = 512; BusType = 'NVMe'; Partitions = @(
                [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 480; FileSystem = 'NTFS'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false }
            ) } )
        }
        Mock Get-BootstrapDualBootInfo { @{ Warnings = @() } }
        Mock Get-BootstrapVBoxManagePath { throw 'VBoxManage must not be probed/called when blocked' }
        $res = Ensure-BootstrapOsInstallVm -State @{ DryRun = $false } -ComponentDef $null
        [string]$res.status | Should Be 'blocked'
        [string]$res.reason | Should Be 'no-dedicated-disk'
    }

    It 'os-install-vm dry-run on a dedicated disk yields the createrawvmdk plan without side effects' {
        Mock Get-BootstrapHostManufacturerModel { [ordered]@{ manufacturer = 'MSI'; model = 'Z790' } }
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'Win'; SizeGB = 512; BusType = 'NVMe'; Partitions = @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 480; FileSystem = 'NTFS'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false }
                ) },
                [pscustomobject]@{ Number = 1; FriendlyName = 'Dedicated'; SizeGB = 500; BusType = 'SATA'; Partitions = @() }
            )
        }
        Mock Get-BootstrapDualBootInfo { @{ Warnings = @() } }
        $res = Ensure-BootstrapOsInstallVm -State @{ DryRun = $true } -ComponentDef $null
        [string]$res.status | Should Be 'planned'
        [int]$res.target | Should Be 1
        @(@($res.vmdkPlan.command) | Where-Object { $_ -like '*PhysicalDrive1' }).Count | Should Be 1
    }
}

Describe 'OS install components and profile wiring' {
    It 'registers os-install-detect/vm/native as builtin components' {
        $catalog = Get-BootstrapComponentCatalog
        foreach ($id in @('os-install-detect','os-install-vm','os-install-native')) {
            $catalog.Contains($id) | Should Be $true
            [string]$catalog[$id].Kind | Should Be 'builtin'
        }
    }

    It 'wires the steamos-install profile and keeps it out of recommended/full' {
        $profiles = Get-BootstrapProfileCatalog
        $profiles.Contains('steamos-install') | Should Be $true
        foreach ($item in @('os-install-detect','os-install-vm','os-install-native','dualboot-manager')) {
            (@($profiles['steamos-install'].Items) -contains $item) | Should Be $true
        }
        (@($profiles['steamdeck-recommended'].Items) -contains 'steamos-install') | Should Be $false
        (@($profiles['steamdeck-full'].Items) -contains 'steamos-install') | Should Be $false
    }

    It 'os-install-detect is read-only (never registers a host change)' {
        Mock Get-BootstrapHostManufacturerModel { [ordered]@{ manufacturer = 'Valve'; model = 'Jupiter' } }
        Mock Get-BootstrapPhysicalDisksSnapshot { @( [pscustomobject]@{ Number = 1; FriendlyName = 'Dedicated'; SizeGB = 500; BusType = 'SATA'; Partitions = @() } ) }
        Mock Get-BootstrapDualBootInfo { @{ Warnings = @() } }
        Mock Register-BootstrapChange { throw 'os-install-detect must never register a change (read-only)' }
        $res = Ensure-BootstrapOsInstallDetect -State @{ DryRun = $false }
        [bool]$res.readOnly | Should Be $true
        [string]$res.status | Should Be 'completed'
        Assert-MockCalled Register-BootstrapChange -Times 0
    }
}
