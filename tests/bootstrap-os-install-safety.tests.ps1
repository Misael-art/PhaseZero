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

    It 'does not recommend removable exFAT media as an OS install target' {
        Mock Get-BootstrapHostManufacturerModel { [ordered]@{ manufacturer = 'Valve'; model = 'Jupiter' } }
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'Windows Deck SSD'; SizeGB = 1000; BusType = 'NVMe'; Partitions = @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'System'; SizeGB = 0.1; FileSystem = 'FAT32'; DriveLetter = ''; IsBoot = $false; IsSystem = $true },
                    [pscustomobject]@{ PartitionNumber = 2; Type = 'Basic'; SizeGB = 190; FileSystem = 'NTFS'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false }
                ) },
                [pscustomobject]@{ Number = 3; FriendlyName = 'USB installer'; SizeGB = 14.6; BusType = 'USB'; Partitions = @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'IFS'; SizeGB = 14.5; FileSystem = 'exFAT'; DriveLetter = 'R'; IsBoot = $false; IsSystem = $false }
                ) }
            )
        }
        Mock Get-BootstrapDualBootInfo { @{ Warnings = @() } }

        $plan = Get-BootstrapOsInstallPlan

        $plan.recommendedTarget | Should Be $null
        (@($plan.blockReasons) -contains 'no-dedicated-internal-linux-disk') | Should Be $true
        @($plan.removableTargets | Where-Object { [int]$_.diskNumber -eq 3 }).Count | Should Be 1
    }

    It 'surfaces Linux partitions on a mixed Windows disk as manual-only candidates' {
        Mock Get-BootstrapHostManufacturerModel { [ordered]@{ manufacturer = 'Valve'; model = 'Jupiter' } }
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @( [pscustomobject]@{ Number = 0; FriendlyName = 'Mixed Deck SSD'; SizeGB = 1000; BusType = 'NVMe'; Partitions = @(
                [pscustomobject]@{ PartitionNumber = 1; Type = 'System'; SizeGB = 0.1; FileSystem = 'FAT32'; DriveLetter = ''; IsBoot = $false; IsSystem = $true },
                [pscustomobject]@{ PartitionNumber = 8; Type = 'Unknown'; SizeGB = 720; FileSystem = ''; DriveLetter = ''; IsBoot = $false; IsSystem = $false },
                [pscustomobject]@{ PartitionNumber = 10; Type = 'Basic'; SizeGB = 190; FileSystem = 'NTFS'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false }
            ) } )
        }
        Mock Get-BootstrapDualBootInfo { @{ Warnings = @() } }

        $plan = Get-BootstrapOsInstallPlan

        $plan.recommendedTarget | Should Be $null
        @($plan.manualPartitionTargets).Count | Should Be 1
        [int]$plan.manualPartitionTargets[0].diskNumber | Should Be 0
        [int]$plan.manualPartitionTargets[0].partitionNumber | Should Be 8
        [string]$plan.manualPartitionTargets[0].method | Should Be 'native-installer-manual-partition'
    }
}

Describe 'OS install partition label guidance' {
    It 'builds a pedagogical label plan without renaming protected or Linux partitions' {
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'Deck SSD'; SizeGB = 1000; BusType = 'NVMe'; Partitions = @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'System'; SizeGB = 0.1; FileSystem = 'FAT32'; FileSystemLabel = 'SYSTEM'; DriveLetter = ''; IsBoot = $false; IsSystem = $true },
                    [pscustomobject]@{ PartitionNumber = 8; Type = 'Unknown'; SizeGB = 720; FileSystem = ''; FileSystemLabel = ''; DriveLetter = ''; IsBoot = $false; IsSystem = $false },
                    [pscustomobject]@{ PartitionNumber = 10; Type = 'Basic'; SizeGB = 190; FileSystem = 'NTFS'; FileSystemLabel = 'Windows'; DriveLetter = 'C'; IsBoot = $true; IsSystem = $false }
                ) },
                [pscustomobject]@{ Number = 3; FriendlyName = 'USB installer'; SizeGB = 14.6; BusType = 'USB'; Partitions = @(
                    [pscustomobject]@{ PartitionNumber = 1; Type = 'IFS'; SizeGB = 14.5; FileSystem = 'exFAT'; FileSystemLabel = ''; DriveLetter = 'R'; IsBoot = $false; IsSystem = $false }
                ) }
            )
        }

        $plan = Get-BootstrapPartitionLabelPlan
        $linux = @($plan.entries | Where-Object { $_.role -eq 'steamos-linux-manual' })[0]
        $windows = @($plan.entries | Where-Object { $_.driveLetter -eq 'C' })[0]
        $usb = @($plan.entries | Where-Object { $_.driveLetter -eq 'R' })[0]

        [string]$linux.proposedLabel | Should Be 'PZ-DECK-LINUX'
        [bool]$linux.canRename | Should Be $false
        [string]$linux.action | Should Be 'guide-only'
        [string]$windows.proposedLabel | Should Be 'PZ-WIN-C'
        [bool]$windows.canRename | Should Be $false
        (@($windows.reasons) -contains 'protected-windows-volume') | Should Be $true
        [string]$usb.proposedLabel | Should Be 'PZ-USB-INSTALL'
        [bool]$usb.canRename | Should Be $false
        (@($usb.reasons) -contains 'removable-volume') | Should Be $true
    }

    It 'renames only safe mounted data volumes when apply is explicitly enabled' {
        Mock Set-BootstrapVolumeLabel { [ordered]@{ status = 'renamed'; driveLetter = $DriveLetter; newLabel = $NewFileSystemLabel } }

        $plan = [ordered]@{
            entries = @(
                [ordered]@{ identity = 'D0P1'; driveLetter = 'C'; currentLabel = 'Windows'; proposedLabel = 'PZ-WIN-C'; canRename = $false; action = 'blocked'; reasons = @('protected-windows-volume') },
                [ordered]@{ identity = 'D2P1'; driveLetter = 'F'; currentLabel = ''; proposedLabel = 'PZ-DATA-F'; canRename = $true; action = 'rename'; reasons = @() }
            )
        }

        $result = Invoke-BootstrapPartitionLabelPlan -Plan $plan -Apply:$true

        [int]$result.changedCount | Should Be 1
        Assert-MockCalled Set-BootstrapVolumeLabel -Times 1 -ParameterFilter { $DriveLetter -eq 'F' -and $NewFileSystemLabel -eq 'PZ-DATA-F' }
    }

    It 'blocks tiny mounted FAT EFI-like partitions even when Windows assigns a drive letter' {
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @( [pscustomobject]@{ Number = 0; FriendlyName = 'Deck SSD'; SizeGB = 1000; BusType = 'NVMe'; Partitions = @(
                [pscustomobject]@{ PartitionNumber = 2; Type = 'Basic'; SizeGB = 0.1; FileSystem = 'FAT'; FileSystemLabel = 'efi'; DriveLetter = 'D'; IsBoot = $false; IsSystem = $false }
            ) } )
        }

        $entry = @(Get-BootstrapPartitionLabelPlan).entries[0]

        [string]$entry.role | Should Be 'efi-system'
        [string]$entry.action | Should Be 'blocked'
        [bool]$entry.canRename | Should Be $false
        (@($entry.reasons) -contains 'protected-windows-volume') | Should Be $true
    }

    It 'counts empty partition label plans without Count/null errors' {
        $counts = Get-BootstrapPartitionLabelPlanCounts -Plan ([ordered]@{})

        [int]$counts.total | Should Be 0
        [int]$counts.renameable | Should Be 0
        [int]$counts.blocked | Should Be 0
        [int]$counts.guideOnly | Should Be 0
    }

    It 'CLI partition-labels mode diagnoses without renaming by default' {
        Mock Get-BootstrapPartitionLabelPlan {
            [ordered]@{
                schemaVersion = 'partition-labels/v1'
                entries = @(
                    [pscustomobject]@{ identity = 'D2P1'; displayName = 'Disco 2 / Particao 1 - F: - 500GB - NTFS'; driveLetter = 'F'; role = 'windows-data'; currentLabel = ''; proposedLabel = 'PZ-DATA-F'; canRename = $true; action = 'rename'; reasons = @() }
                )
                renameableCount = 1
                applyOptInEnv = 'PHASEZERO_PARTITION_LABEL_APPLY=1'
            }
        }
        Mock Set-BootstrapVolumeLabel { throw 'must not rename in diagnose mode' }
        $oldApply = $env:PHASEZERO_PARTITION_LABEL_APPLY
        try {
            Remove-Item Env:\PHASEZERO_PARTITION_LABEL_APPLY -ErrorAction SilentlyContinue
            $result = Invoke-BootstrapPartitionLabelsMode
        } finally {
            if ($null -ne $oldApply) { $env:PHASEZERO_PARTITION_LABEL_APPLY = $oldApply } else { Remove-Item Env:\PHASEZERO_PARTITION_LABEL_APPLY -ErrorAction SilentlyContinue }
        }

        [string]$result.status | Should Be 'success'
        [int]$result.exitCode | Should Be 0
        [string]$result.mode | Should Be 'partition-labels'
        [int]$result.counts.renameable | Should Be 1
        [string]$result.partitionLabels.result.status | Should Be 'planned'
        Assert-MockCalled Set-BootstrapVolumeLabel -Times 0 -Scope It
    }

    It 'CLI partition-labels apply is blocked unless the apply environment opt-in is present' {
        Mock Get-BootstrapPartitionLabelPlan {
            [ordered]@{
                entries = @(
                    [pscustomobject]@{ identity = 'D2P1'; displayName = 'Disco 2 / Particao 1 - F: - 500GB - NTFS'; driveLetter = 'F'; role = 'windows-data'; currentLabel = ''; proposedLabel = 'PZ-DATA-F'; canRename = $true; action = 'rename'; reasons = @() }
                )
                renameableCount = 1
            }
        }
        Mock Set-BootstrapVolumeLabel { throw 'must not rename without env opt-in' }
        $oldApply = $env:PHASEZERO_PARTITION_LABEL_APPLY
        try {
            Remove-Item Env:\PHASEZERO_PARTITION_LABEL_APPLY -ErrorAction SilentlyContinue
            $result = Invoke-BootstrapPartitionLabelsMode -Apply
        } finally {
            if ($null -ne $oldApply) { $env:PHASEZERO_PARTITION_LABEL_APPLY = $oldApply } else { Remove-Item Env:\PHASEZERO_PARTITION_LABEL_APPLY -ErrorAction SilentlyContinue }
        }

        [string]$result.status | Should Be 'blocked'
        [int]$result.exitCode | Should Be 2
        [string]$result.blockerKind | Should Be 'partition-label-apply-opt-in-missing'
        [string]$result.partitionLabels.result.status | Should Be 'planned'
        Assert-MockCalled Set-BootstrapVolumeLabel -Times 0 -Scope It
    }

    It 'CLI partition-labels apply renames only safe data volumes when env opt-in is present' {
        Mock Get-BootstrapPartitionLabelPlan {
            [ordered]@{
                entries = @(
                    [pscustomobject]@{ identity = 'D0P1'; displayName = 'Disco 0 / Particao 1 - C: - 190GB - NTFS'; driveLetter = 'C'; role = 'windows-system'; currentLabel = 'Windows'; proposedLabel = 'PZ-WIN-C'; canRename = $false; action = 'blocked'; reasons = @('protected-windows-volume') },
                    [pscustomobject]@{ identity = 'D2P1'; displayName = 'Disco 2 / Particao 1 - F: - 500GB - NTFS'; driveLetter = 'F'; role = 'windows-data'; currentLabel = ''; proposedLabel = 'PZ-DATA-F'; canRename = $true; action = 'rename'; reasons = @() }
                )
                renameableCount = 1
            }
        }
        Mock Set-BootstrapVolumeLabel { [ordered]@{ status = 'renamed'; driveLetter = $DriveLetter; newLabel = $NewFileSystemLabel } }
        $oldApply = $env:PHASEZERO_PARTITION_LABEL_APPLY
        try {
            $env:PHASEZERO_PARTITION_LABEL_APPLY = '1'
            $result = Invoke-BootstrapPartitionLabelsMode -Apply
        } finally {
            if ($null -ne $oldApply) { $env:PHASEZERO_PARTITION_LABEL_APPLY = $oldApply } else { Remove-Item Env:\PHASEZERO_PARTITION_LABEL_APPLY -ErrorAction SilentlyContinue }
        }

        [string]$result.status | Should Be 'success'
        [int]$result.exitCode | Should Be 0
        [int]$result.partitionLabels.result.changedCount | Should Be 1
        Assert-MockCalled Set-BootstrapVolumeLabel -Times 1 -Scope It -ParameterFilter { $DriveLetter -eq 'F' -and $NewFileSystemLabel -eq 'PZ-DATA-F' }
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
    It 'registers os-install-detect/labels/vm/native as builtin components' {
        $catalog = Get-BootstrapComponentCatalog
        foreach ($id in @('os-install-detect','os-partition-labels','os-install-vm','os-install-native')) {
            $catalog.Contains($id) | Should Be $true
            [string]$catalog[$id].Kind | Should Be 'builtin'
        }
    }

    It 'wires the steamos-install profile and keeps it out of recommended/full' {
        $profiles = Get-BootstrapProfileCatalog
        $profiles.Contains('steamos-install') | Should Be $true
        foreach ($item in @('os-install-detect','os-partition-labels','os-install-vm','os-install-native','dualboot-manager')) {
            (@($profiles['steamos-install'].Items) -contains $item) | Should Be $true
        }
        (@($profiles['steamdeck-recommended'].Items) -contains 'steamos-install') | Should Be $false
        (@($profiles['steamdeck-full'].Items) -contains 'steamos-install') | Should Be $false
    }

    It 'os-partition-labels is planned by default and does not rename without opt-in' {
        Mock Get-BootstrapPhysicalDisksSnapshot {
            @( [pscustomobject]@{ Number = 2; FriendlyName = 'Data'; SizeGB = 500; BusType = 'SATA'; Partitions = @(
                [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; SizeGB = 500; FileSystem = 'NTFS'; FileSystemLabel = ''; DriveLetter = 'F'; IsBoot = $false; IsSystem = $false }
            ) } )
        }
        Mock Set-BootstrapVolumeLabel { throw 'must not rename without explicit opt-in' }
        $old = $env:PHASEZERO_PARTITION_LABEL_APPLY
        try {
            $env:PHASEZERO_PARTITION_LABEL_APPLY = ''
            $res = Ensure-BootstrapPartitionLabels -State @{ DryRun = $false }
        } finally {
            $env:PHASEZERO_PARTITION_LABEL_APPLY = $old
        }
        [string]$res.status | Should Be 'planned'
        [int]$res.plan.renameableCount | Should Be 1
        Assert-MockCalled Set-BootstrapVolumeLabel -Times 0
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

    It 'keeps steamos-install dry-run isolated from HostHealth and AppTuning defaults' {
        $selection = New-BootstrapSelectionObject -SelectedProfiles @('steamos-install')
        $resolution = Resolve-BootstrapComponents -SelectedProfiles @('steamos-install') -SelectedComponents @() -ExcludedComponents @()

        Get-BootstrapDefaultHostHealthMode -Selection $selection -Resolution $resolution | Should Be 'off'
        Get-BootstrapDefaultAppTuningMode -Selection $selection -Resolution $resolution | Should Be 'off'
    }
}
