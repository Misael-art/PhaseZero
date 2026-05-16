$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$uiScriptPath = Join-Path $repoRoot 'bootstrap-ui.ps1'

function Import-UiVersionHelpersForTest {
    $raw = Get-Content -Path $uiScriptPath -Raw
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-UiContractVersionCompat' }, $true)
    if (-not $fn) { throw 'Test-UiContractVersionCompat not found' }
    Invoke-Expression ("function global:Test-UiContractVersionCompat {0}" -f $fn.Body.Extent.Text)
}

Import-UiVersionHelpersForTest

Describe 'UI Contract version negotiation' {
    Context 'compatibility matrix' {
        It 'accepts a version within the supported range' {
            $result = Test-UiContractVersionCompat -Version '1.0.0' -Min '1.0.0' -Max '1.99.99'
            $result.status | Should Be 'ok'
            $result.severity | Should Be 'info'
        }

        It 'warns when minor is newer than supported' {
            $result = Test-UiContractVersionCompat -Version '1.5.0' -Min '1.0.0' -Max '1.4.0'
            $result.status | Should Be 'minor-newer'
            $result.severity | Should Be 'warning'
        }

        It 'errors when major is newer than supported (UI too old)' {
            $result = Test-UiContractVersionCompat -Version '2.0.0' -Min '1.0.0' -Max '1.99.99'
            $result.status | Should Be 'cli-too-new'
            $result.severity | Should Be 'error'
        }

        It 'errors when major is older than supported (CLI too old)' {
            $result = Test-UiContractVersionCompat -Version '0.9.0' -Min '1.0.0' -Max '1.99.99'
            $result.status | Should Be 'cli-too-old'
            $result.severity | Should Be 'error'
        }

        It 'rejects malformed version strings' {
            $result = Test-UiContractVersionCompat -Version 'not-a-version' -Min '1.0.0' -Max '1.99.99'
            $result.status | Should Be 'invalid'
            $result.severity | Should Be 'error'
        }
    }
}
