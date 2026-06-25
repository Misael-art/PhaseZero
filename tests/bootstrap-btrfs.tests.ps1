$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Btrfs dual-boot support (read/write, never formats)' {
    It 'NEVER calls a formatting/partitioning cmdlet in any Btrfs function (hard safety invariant)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match 'Btrfs' }, $true))
        @($fns).Count | Should BeGreaterThan 0
        foreach ($f in $fns) {
            $f.Extent.Text | Should Not Match 'Format-Volume|Initialize-Disk|Clear-Disk|Remove-Partition|New-Partition|mkfs|diskpart'
        }
    }

    It 'reports readiness without touching disk in library mode and asserts neverFormats' {
        $r = Get-BootstrapBtrfsReadiness
        [bool]$r.neverFormats | Should Be $true
        ($r.checks.Contains('fast-startup-off')) | Should Be $true
        ($r.checks.Contains('winbtrfs-driver')) | Should Be $true
        (@($r.recommendations) -join ' ') | Should Match 'NUNCA formata'
    }

    It 'scans Linux partitions in library mode when explicitly requested' {
        Mock Get-BootstrapFastStartupStatus { @{ Enabled = $false; Safe = $true; RegistryPath = 'HKLM:\probe'; Value = 0 } }
        Mock Get-BootstrapPendingRebootReasons { @() }
        Mock Get-BootstrapWinBtrfsState { [ordered]@{ installed = $true; driverPath = 'C:\Windows\System32\drivers\btrfs.sys'; serviceState = 'Running' } }
        Mock Get-Partition { @([pscustomobject]@{ DiskNumber = 0; PartitionNumber = 8; Size = (727.5 * 1GB); Type = 'Unknown'; GptType = '{933ac7e1-2eb4-4f13-b844-0e14e2aef915}' }) }
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'Unknown' } }

        $r = Get-BootstrapBtrfsReadiness -ScanPartitions

        [int]$r.linuxPartitionCount | Should Be 1
        [string]$r.accessLevel | Should Be 'write-opt-in'
        Assert-MockCalled Get-Partition -Times 1
    }

    It 'exposes WinBtrfs driver state shape' {
        $s = Get-BootstrapWinBtrfsState
        ($s.Contains('installed')) | Should Be $true
        ([string]$s.driverPath) | Should Match 'btrfs\.sys'
    }

    It 'computes a safety access matrix (blocked|unsafe|read-only-ok|write-opt-in) from real gates' {
        # sem driver -> blocked
        $a = Get-BootstrapBtrfsAccessLevel -WinbtrfsInstalled $false -ServiceState '' -FastStartupEnabled $false -PendingReboot $false -LinuxPartitionCount 2
        [string]$a.level | Should Be 'blocked'
        (@($a.blockedReasons) -contains 'winbtrfs-not-installed') | Should Be $true

        # driver instalado mas servico parado -> blocked
        $b = Get-BootstrapBtrfsAccessLevel -WinbtrfsInstalled $true -ServiceState 'Stopped' -FastStartupEnabled $false -PendingReboot $false -LinuxPartitionCount 2
        [string]$b.level | Should Be 'blocked'
        (@($b.blockedReasons) -contains 'winbtrfs-service-not-running') | Should Be $true

        # Fast Startup ligado -> unsafe (FS pode ficar suja)
        $c = Get-BootstrapBtrfsAccessLevel -WinbtrfsInstalled $true -ServiceState 'Running' -FastStartupEnabled $true -PendingReboot $false -LinuxPartitionCount 2
        [string]$c.level | Should Be 'unsafe'
        (@($c.blockedReasons) -contains 'fast-startup-on') | Should Be $true

        # reboot pendente -> unsafe
        $d = Get-BootstrapBtrfsAccessLevel -WinbtrfsInstalled $true -ServiceState 'Running' -FastStartupEnabled $false -PendingReboot $true -LinuxPartitionCount 2
        [string]$d.level | Should Be 'unsafe'
        (@($d.blockedReasons) -contains 'pending-reboot') | Should Be $true

        # tudo ok mas sem particao detectada -> read-only-ok (nao habilita escrita)
        $e = Get-BootstrapBtrfsAccessLevel -WinbtrfsInstalled $true -ServiceState 'Running' -FastStartupEnabled $false -PendingReboot $false -LinuxPartitionCount 0
        [string]$e.level | Should Be 'read-only-ok'

        # todos os gates passam -> write-opt-in
        $f = Get-BootstrapBtrfsAccessLevel -WinbtrfsInstalled $true -ServiceState 'Running' -FastStartupEnabled $false -PendingReboot $false -LinuxPartitionCount 2
        [string]$f.level | Should Be 'write-opt-in'
        @($f.blockedReasons).Count | Should Be 0
    }

    It 'readiness exposes accessLevel/blockedReasons and gates readWriteSupported to write-opt-in only' {
        $r = Get-BootstrapBtrfsReadiness
        ($r.Contains('accessLevel')) | Should Be $true
        ($r.Contains('blockedReasons')) | Should Be $true
        ($r.Contains('readOnlySupported')) | Should Be $true
        @('blocked', 'unsafe', 'read-only-ok', 'write-opt-in') -contains [string]$r.accessLevel | Should Be $true
        [bool]$r.readWriteSupported | Should Be ([string]$r.accessLevel -eq 'write-opt-in')
        [bool]$r.readOnlySupported | Should Be ([string]$r.accessLevel -in @('read-only-ok', 'write-opt-in'))
    }

    It 'declares the winbtrfs component as guided (manual-required) enabling read/write, never formatting' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('winbtrfs') | Should Be $true
        $def = $catalog['winbtrfs']
        [string]$def.Kind | Should Be 'manual-required'
        [bool]$def.Optional | Should Be $true
        [string]$def.officialSource | Should Match 'maharmstone/btrfs'
        ([string]$def.Instructions) | Should Match 'NUNCA FORMATA'
        ([string]$def.Description) | Should Match 'ESCREVER'
    }
}
