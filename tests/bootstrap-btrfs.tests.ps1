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

    It 'exposes WinBtrfs driver state shape' {
        $s = Get-BootstrapWinBtrfsState
        ($s.Contains('installed')) | Should Be $true
        ([string]$s.driverPath) | Should Match 'btrfs\.sys'
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
