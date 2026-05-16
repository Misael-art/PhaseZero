$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsScriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
$uiScriptPath = Join-Path $repoRoot 'bootstrap-ui.ps1'
$installCliBatPath = Join-Path $repoRoot 'install-cli.bat'

function New-AiToolsTestRoot {
    $root = Join-Path $env:TEMP ("PhaseZero AI Tools {0}" -f ([Guid]::NewGuid().ToString('N')))
    $null = New-Item -Path $root -ItemType Directory -Force
    return $root
}

function Remove-AiToolsTestRoot {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-InstallCliBat {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args,
        [int]$TimeoutMs = 240000
    )

    $argLiteral = ($Args | ForEach-Object {
        $v = [string]$_
        if ($v -match '[\s"]') { '"' + ($v -replace '"', '\"') + '"' } else { $v }
    }) -join ' '
    $cmdLine = ('/c ""{0}" {1}"' -f $installCliBatPath, $argLiteral)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = $cmdLine
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMs)) {
        try { $process.Kill() } catch { }
        throw "install-cli.bat timed out for args: $($Args -join ' ')"
    }

    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Stdout = [string]$stdoutTask.Result
        Stderr = [string]$stderrTask.Result
    }
}

Describe 'AI coding tool support' {
    BeforeEach {
        $script:AiToolsTestRoot = New-AiToolsTestRoot
    }

    AfterEach {
        Remove-AiToolsTestRoot -Path $script:AiToolsTestRoot
        Remove-Variable -Scope Script -Name AiToolsTestRoot -ErrorAction SilentlyContinue
    }

    It 'declares a conservative official-source AI tool catalog' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $catalog = Get-BootstrapAiToolCatalog

        foreach ($toolName in @('rtk','claude-code','opencode','hermes-agent','hermes-desktop','openclaw','aion-ui','antigravity-workflows')) {
            $catalog.Contains($toolName) | Should Be $true
            [string]$catalog[$toolName].DocsUrl | Should Match '^https://'
            [string]$catalog[$toolName].InstallSupport | Should Not Be ''
        }

        [string]$catalog['claude-code'].PackageName | Should Be '@anthropic-ai/claude-code'
        [string]$catalog['opencode'].PackageName | Should Be 'opencode-ai'
        [string]$catalog['rtk'].GitHubRepo | Should Be 'rtk-ai/rtk'
        [bool]$catalog['rtk'].CargoFallbackAllowed | Should Be $false
        [string]$catalog['hermes-agent'].GitHubRepo | Should Be 'NousResearch/hermes-agent'
        [string]$catalog['hermes-agent'].InstallSupport | Should Be 'manual-windows-beta'
        [string]$catalog['antigravity-workflows'].InstallSupport | Should Be 'workflow-only'
    }

    It 'reports AI tool status without claiming missing tools are configured' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $rows = @(Get-BootstrapAiToolStatusRows -InstallRoot $script:AiToolsTestRoot -ProjectRoot $repoRoot)

        (@($rows | Where-Object { [string]$_['tool'] -eq 'claude-code' }).Count) | Should Be 1
        foreach ($row in @($rows)) {
            [string]$row['tool'] | Should Not Be ''
            [string]$row['status'] | Should Match '^(absent|installed|configured|manual|blocked|error)$'
            [string]$row['docs'] | Should Match '^https://'
        }
    }

    It 'supports dry-run install and idempotent uninstall for a path with spaces' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $rootWithSpaces = Join-Path $script:AiToolsTestRoot 'managed tools root'
        $install = Invoke-BootstrapAiToolAction -ToolName 'claude-code' -Action 'install' -InstallRoot $rootWithSpaces -ProjectRoot $repoRoot -DryRun -Yes
        $uninstall1 = Invoke-BootstrapAiToolAction -ToolName 'claude-code' -Action 'uninstall' -InstallRoot $rootWithSpaces -ProjectRoot $repoRoot -DryRun -Yes
        $uninstall2 = Invoke-BootstrapAiToolAction -ToolName 'claude-code' -Action 'uninstall' -InstallRoot $rootWithSpaces -ProjectRoot $repoRoot -DryRun -Yes

        [string]$install.status | Should Be 'planned'
        [string]$uninstall1.status | Should Be 'planned'
        [string]$uninstall2.status | Should Be 'planned'
        [string]$install.installRoot | Should Be $rootWithSpaces
    }

    It 'generates Antigravity workflow templates without external dependencies' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $result = Invoke-BootstrapAiToolAction -ToolName 'antigravity-workflows' -Action 'configure' -InstallRoot $script:AiToolsTestRoot -ProjectRoot $script:AiToolsTestRoot -Yes

        [string]$result.status | Should Be 'configured'
        foreach ($name in @('planning.md','backend.md','frontend.md','tests.md','review.md')) {
            Test-Path -LiteralPath (Join-Path $script:AiToolsTestRoot (Join-Path '.antigravity\workflows' $name)) | Should Be $true
        }
    }

    It 'prefers Windows npm command shims over extensionless package files' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $prefix = Join-Path (Join-Path $script:AiToolsTestRoot 'managed tools root') 'npm-prefix'
        $null = New-Item -Path $prefix -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $prefix 'opencode') -Value '#!/bin/sh' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $prefix 'opencode.cmd') -Value '@echo off' -Encoding ascii

        $catalog = Get-BootstrapAiToolCatalog
        $resolved = Resolve-BootstrapAiToolCommandPath -CatalogEntry $catalog['opencode'] -InstallRoot (Join-Path $script:AiToolsTestRoot 'managed tools root')

        [System.IO.Path]::GetFileName($resolved) | Should Be 'opencode.cmd'
    }

    It 'exposes install-cli AI flags with structured JSON result' {
        $resultPath = Join-Path $script:AiToolsTestRoot 'result.json'
        $logPath = Join-Path $script:AiToolsTestRoot 'ai-tools.log'
        $rootWithSpaces = Join-Path $script:AiToolsTestRoot 'managed tools root'

        $result = Invoke-InstallCliBat -Args @('--tool','claude-code','--validate','--dry-run','--yes','--no-admin','--install-root',$rootWithSpaces,'--result-path',$resultPath,'--log-path',$logPath)

        $result.ExitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($result.Stderr)) | Should Be $true
        Test-Path -LiteralPath $resultPath | Should Be $true
        Test-Path -LiteralPath $logPath | Should Be $true
        $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        [string]$json.mode | Should Be 'ai-tools'
        [string]$json.action | Should Be 'validate'
        [string]$json.installRoot | Should Be $rootWithSpaces
    }

    It 'rejects unknown AI tools with a non-zero exit and diagnostic' {
        $result = Invoke-InstallCliBat -Args @('--tool','not-a-real-tool','--validate','--dry-run','--yes')

        ($result.ExitCode -ne 0) | Should Be $true
        ($result.Stdout + $result.Stderr) | Should Match 'not-a-real-tool'
    }

    It 'adds the AI Coding Tools UI controls and no known PT-BR mojibake' {
        $raw = Get-Content -LiteralPath $uiScriptPath -Raw

        $raw | Should Match 'AI Coding Tools'
        foreach ($name in @('PageAiTools','AiToolsGrid','AiToolsInstallButton','AiToolsValidateButton','AiToolsConfigureButton','AiToolsUninstallButton','AiToolsDocsButton','AiToolsStatusLabel')) {
            $raw | Should Match $name
        }
        $raw | Should Not Match 'Configurao|Verso|RPIDOS|Configuraes|sade|Resolucao'
    }
}
