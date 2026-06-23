$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Windows home server: os-slim-server' {
    It 'declara o componente os-slim-server como opt-in e do Kind correto' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('os-slim-server') | Should Be $true
        $def = $catalog['os-slim-server']
        [string]$def.Kind | Should Be 'os-slim-server'
        [bool]$def.Optional | Should Be $true
    }

    It 'NUNCA remove arquivos do usuario nem desabilita o shell (invariante de seguranca)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-BootstrapOsSlimServer' }, $true))[0]
        $fn | Should Not BeNullOrEmpty
        $fn.Extent.Text | Should Not Match 'Remove-Item\s+.*Users|Stop-Process\s+-Name\s+''?explorer|Winlogon.*Shell'
    }

    It 'cada mutacao de host passa por um registrador de rollback' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-BootstrapOsSlimServer' }, $true))[0]
        $cmds = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { ($_.GetCommandName() -split '\\')[-1] })
        $mutating = @('Set-ItemProperty', 'Remove-ItemProperty', 'New-ItemProperty')
        if (@($cmds | Where-Object { $mutating -contains $_ }).Count -gt 0) {
            (@($cmds | Where-Object { $_ -in @('Register-BootstrapChange', 'Register-BootstrapFileChange', 'Set-BootstrapServiceStartupTypes') }).Count -gt 0) | Should Be $true
        }
    }

    It 'em dry-run nao muta o host (nenhuma chamada de escrita executada)' {
        Mock -CommandName Set-ItemProperty -MockWith {}
        Mock -CommandName Remove-ItemProperty -MockWith {}
        Mock -CommandName Set-BootstrapServiceStartupTypes -MockWith {}
        Mock -CommandName Repair-BootstrapFastStartup -MockWith {}
        $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot $env:TEMP -ResolvedCloneBaseDir $env:TEMP
        $state.DryRun = $true
        $state.ChangeManifestPath = Join-Path $env:TEMP ("os-slim-dry-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        try {
            Ensure-BootstrapOsSlimServer -State $state
            Assert-MockCalled -CommandName Set-ItemProperty -Times 0 -Scope It
            Assert-MockCalled -CommandName Set-BootstrapServiceStartupTypes -Times 0 -Scope It
        } finally {
            Remove-Item -LiteralPath $state.ChangeManifestPath -Force -ErrorAction SilentlyContinue
        }
    }
}
