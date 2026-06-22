$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'BCD backup listing and restore' {
    It 'lists BCD backups newest-first with path, name and created' {
        $root = Join-Path $env:TEMP ("pz-bcd-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $env:BOOTSTRAP_DATA_ROOT = $root
        Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
        try {
            $backupDir = Join-Path $root 'bcd-backups'
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            Set-Content -Path (Join-Path $backupDir 'bcd_backup_20260101_010101.bak') -Value 'old' -Encoding Ascii
            Start-Sleep -Milliseconds 80
            Set-Content -Path (Join-Path $backupDir 'bcd_backup_20260202_020202.bak') -Value 'new' -Encoding Ascii
            Set-Content -Path (Join-Path $backupDir 'unrelated.txt') -Value 'x' -Encoding Ascii

            $list = @(Get-BootstrapBcdBackups)
            $list.Count | Should Be 2
            [string]$list[0].Name | Should Be 'bcd_backup_20260202_020202.bak'
            [string]$list[0].Path | Should Match 'bcd-backups'
            [string]$list[0].Created | Should Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$'
        } finally {
            Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
            $env:BOOTSTRAP_DATA_ROOT = ''
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns an empty list when no backup folder exists' {
        $root = Join-Path $env:TEMP ("pz-bcd-empty-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $env:BOOTSTRAP_DATA_ROOT = $root
        Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
        try {
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            @(Get-BootstrapBcdBackups).Count | Should Be 0
        } finally {
            Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
            $env:BOOTSTRAP_DATA_ROOT = ''
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses to restore a non-existent / unprivileged backup (guarded)' {
        # Sem admin (CI) lanca por privilegio; com admin lanca por arquivo inexistente. Ambos protegem.
        # (try/catch em vez de Should Throw: este ultimo nao captura de forma confiavel no Pester 3.4 aqui.)
        $caught = $false
        try { [void](Restore-BootstrapWindowsBootManager -BackupPath (Join-Path $env:TEMP ('pz-missing-bcd-{0}.bak' -f ([Guid]::NewGuid().ToString('N'))))) } catch { $caught = $true }
        $caught | Should Be $true
    }
}
