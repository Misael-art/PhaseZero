[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester BeforeAll variables are consumed by nested It scriptblocks.')]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Windows VM guest recovery contracts' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $guestScript = Join-Path $repoRoot 'linux/windows-vm/guest-login.ps1'
        $offlineScript = Join-Path $repoRoot 'linux/windows-vm/qga-offline-repair.ps1'
        $shellScript = Join-Path $repoRoot 'linux/windows-vm/guest-login.sh'
    }

    It 'parses guest and offline repair scripts without errors' {
        foreach ($path in @($guestScript, $offlineScript)) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $path, [ref]$tokens, [ref]$errors)
            if ($errors -and $errors.Count -gt 0) {
                throw (($errors | ForEach-Object Message) -join '; ')
            }
        }
    }

    It 'keeps autologon secret in LSA and removes registry plaintext' {
        $source = Get-Content -LiteralPath $guestScript -Raw
        if ($source -notmatch "PhaseZeroLsa\]::Store\('DefaultPassword'") { throw 'LSA storage missing' }
        if ($source -notmatch 'Remove-ItemProperty -Path \$winlogon -Name DefaultPassword') { throw 'registry plaintext cleanup missing' }
        if ($source -match 'Set-ItemProperty[^\r\n]+DefaultPassword') { throw 'registry plaintext writer found' }
    }

    It 'keeps PZ-Recovery separate, local-only by default, and localized admin-safe' {
        $source = Get-Content -LiteralPath $guestScript -Raw
        if ($source -notmatch '\$recoveryUser = ''PZ-Recovery''') { throw 'recovery account missing' }
        if ($source -notmatch "Get-LocalGroup -SID 'S-1-5-32-544'") { throw 'localized admin SID lookup missing' }
        if ($source -notmatch 'SeDenyNetworkLogonRight') { throw 'network deny right missing' }
        if ($source -notmatch 'SeDenyRemoteInteractiveLogonRight') { throw 'RDP deny right missing' }
        if ($source -match 'DefaultUserName[^\r\n]+recoveryUser') { throw 'recovery account participates in autologon' }
    }

    It 'uses signed media and removes offline payloads after first boot' {
        $source = Get-Content -LiteralPath $offlineScript -Raw
        if ($source -notmatch 'Get-AuthenticodeSignature') { throw 'MSI signature verification missing' }
        if ($source -notmatch 'qemu-ga start= delayed-auto') { throw 'delayed-auto QGA missing' }
        if ($source -notmatch 'Remove-Item -LiteralPath \$payloadDir') { throw 'offline payload cleanup missing' }
        if ($source -match '(?i)password|secret') { throw 'offline payload contains a secret channel' }
    }

    It 'accepts recovery passwords only from stdin' {
        $source = Get-Content -LiteralPath $shellScript -Raw
        if ($source -notmatch 'recovery apply requires --password-stdin') { throw 'stdin gate missing' }
        if ($source -notmatch 'IFS= read -r password') { throw 'stdin read missing' }
        if ($source -match 'PZ_RECOVERY_PASSWORD') { throw 'password environment channel found' }
    }
}
