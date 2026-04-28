Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath
Reset-BootstrapFileCmdlets

function New-AgentSkillsTestRoot {
    return (Join-Path $env:TEMP ("bootstrap_agent_skills_{0}" -f ([Guid]::NewGuid().ToString('N'))))
}

function Reset-AgentSkillsTestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $env:BOOTSTRAP_DATA_ROOT = $Path
    Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
}

function Remove-AgentSkillsTestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Bootstrap agent skills' {
    BeforeEach {
        $script:TestDataRoot = New-AgentSkillsTestRoot
        Reset-AgentSkillsTestRoot -Path $script:TestDataRoot
        $script:OriginalUserProfile = $env:USERPROFILE
        $script:OriginalAppData = $env:APPDATA
        $script:OriginalLocalAppData = $env:LOCALAPPDATA
        $env:USERPROFILE = Join-Path $script:TestDataRoot 'User'
        $env:APPDATA = Join-Path $script:TestDataRoot 'AppData\Roaming'
        $env:LOCALAPPDATA = Join-Path $script:TestDataRoot 'AppData\Local'
        New-Item -Path $env:USERPROFILE -ItemType Directory -Force | Out-Null
        New-Item -Path $env:APPDATA -ItemType Directory -Force | Out-Null
        New-Item -Path $env:LOCALAPPDATA -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        $env:USERPROFILE = $script:OriginalUserProfile
        $env:APPDATA = $script:OriginalAppData
        $env:LOCALAPPDATA = $script:OriginalLocalAppData
        Remove-AgentSkillsTestRoot -Path $script:TestDataRoot
        Remove-Variable -Scope Script -Name TestDataRoot -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalUserProfile -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalAppData -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name OriginalLocalAppData -ErrorAction SilentlyContinue
    }

    It 'resolves agent-skills after vscode-extensions and claude-config in the ai profile' {
        $resolution = Resolve-BootstrapComponents -SelectedProfiles @('ai') -SelectedComponents @() -ExcludedComponents @()
        $resolved = @($resolution.ResolvedComponents)

        $extensionsIndex = [array]::IndexOf($resolved, 'vscode-extensions')
        $claudeConfigIndex = [array]::IndexOf($resolved, 'claude-config')
        $agentSkillsIndex = [array]::IndexOf($resolved, 'agent-skills')

        $extensionsIndex | Should BeGreaterThan -1
        $claudeConfigIndex | Should BeGreaterThan -1
        $agentSkillsIndex | Should BeGreaterThan -1
        $extensionsIndex | Should BeLessThan $agentSkillsIndex
        $claudeConfigIndex | Should BeLessThan $agentSkillsIndex
    }

    It 'defines the documented Caveman install commands without invoking them' {
        $catalog = Get-BootstrapCavemanTargetCatalog

        $catalog.claudeCode.commands[0].exe | Should Be 'claude'
        $catalog.claudeCode.commands[0].args | Should Be @('plugin', 'marketplace', 'add', 'JuliusBrussee/caveman')
        $catalog.claudeCode.commands[1].args | Should Be @('plugin', 'install', 'caveman@caveman')
        $catalog.geminiCli.commands[0].args | Should Be @('extensions', 'install', 'https://github.com/JuliusBrussee/caveman')
        $catalog.cursor.commands[0].args | Should Be @('-y', 'skills', 'add', 'JuliusBrussee/caveman', '-a', 'cursor', '--copy')
        $catalog.githubCopilot.commands[0].args | Should Be @('-y', 'skills', 'add', 'JuliusBrussee/caveman', '-a', 'github-copilot', '--copy')
    }

    It 'records missing runtimes as skipped instead of failing the component' {
        Mock Resolve-CommandPath { return $null }
        Mock Invoke-NativeWithLog { throw 'should not invoke missing runtime' }

        $state = New-BootstrapState -ResolvedWorkspaceRoot $script:TestDataRoot -ResolvedCloneBaseDir $script:TestDataRoot -RequestedSteamDeckVersion 'Auto' -ResolvedSteamDeckVersion '' -HostHealthMode 'off' -UsesSteamDeckFlow:$false -IsDryRun:$false
        $summary = Ensure-BootstrapAgentSkills -State $state

        (Test-Path $summary.path) | Should Be $true
        $summary.targets.claudeCode.status | Should Be 'skipped'
        $summary.targets.cursor.status | Should Be 'skipped'
        $summary.targets.githubCopilot.status | Should Be 'skipped'
    }

    It 'merges Caveman rule files idempotently while preserving existing user content' {
        $workspaceRoot = Join-Path $script:TestDataRoot 'workspace'
        $cursorPath = Join-Path $workspaceRoot '.cursor\rules\caveman.mdc'
        New-Item -Path (Split-Path -Path $cursorPath -Parent) -ItemType Directory -Force | Out-Null
        Set-Content -Path $cursorPath -Encoding utf8 -Value @'
---
description: Existing user rule
---
Keep this custom line.
'@

        $first = Ensure-BootstrapCavemanRuleFiles -WorkspaceRoot $workspaceRoot
        $second = Ensure-BootstrapCavemanRuleFiles -WorkspaceRoot $workspaceRoot
        $content = Get-Content -Path $cursorPath -Raw

        $first.updated | Should Be $true
        $second.updated | Should Be $false
        $content | Should Match 'Keep this custom line\.'
        ([regex]::Matches($content, 'BEGIN BOOTSTRAP CAVEMAN').Count) | Should Be 1
        ([regex]::Matches($content, 'ACTIVE EVERY RESPONSE').Count) | Should Be 1
        (Test-Path (Join-Path $workspaceRoot '.windsurf\rules\caveman.md')) | Should Be $true
        (Test-Path (Join-Path $workspaceRoot '.clinerules\caveman.md')) | Should Be $true
        (Test-Path (Join-Path $workspaceRoot '.github\copilot-instructions.md')) | Should Be $true
        (Test-Path (Join-Path $workspaceRoot 'AGENTS.md')) | Should Be $true
    }
}
