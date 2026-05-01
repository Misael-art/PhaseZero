$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

function Invoke-Bootstrap {
    param([string[]]$CommandArgs)

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $CommandArgs
    $quotedArgs = foreach ($arg in $allArgs) {
        if ($arg -match '[\s"]') {
            '"' + ($arg -replace '"', '\"') + '"'
        } else {
            $arg
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellExe
    $startInfo.Arguments = [string]::Join(' ', $quotedArgs)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw "Failed to start bootstrap process for args: $($CommandArgs -join ' ')"
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit(120000)) {
        try { $process.Kill() } catch { }
        throw "Bootstrap invocation timed out after 120000ms for args: $($CommandArgs -join ' ')"
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = @($stdoutTask.Result, $stderrTask.Result) -join [Environment]::NewLine
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Text -notmatch [regex]::Escape($Pattern)) {
        throw "$Message`nMissing: $Pattern`nOutput:`n$Text"
    }
}

Describe 'Bootstrap profile mode' {
    It 'lists supported profiles' {
        $result = Invoke-Bootstrap -CommandArgs @('-ListProfiles')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('legacy', 'recommended', 'steamdeck-recommended', 'steamdeck-full', 'steamdeck-dock')) {
            Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected profile in output.'
        }
    }

    It 'lists supported host health modes' {
        $result = Invoke-Bootstrap -CommandArgs @('-ListHostHealthModes')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('off', 'conservador', 'equilibrado', 'agressivo')) {
            Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected host health mode in output.'
        }
    }

    It 'lists supported app tuning catalog entries' {
        $result = Invoke-Bootstrap -CommandArgs @('-ListAppTuningCatalog')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('gaming-console', 'steamdeck-control', 'dev-ai', 'browser-startup', 'ia', 'steam-big-picture-session', 'app-steam', 'app-web-photopea')) {
            Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected app tuning catalog entry in output.'
        }
    }

    It 'lists installable apps for on-demand installation' {
        $result = Invoke-Bootstrap -CommandArgs @('-ListApps')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('steam', 'vscode', 'discord', 'component', 'winget')) {
            Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern $expected.ToLowerInvariant() -Message 'Expected installable app in output.'
        }
    }

    It 'resolves individual app requests into components' {
        $result = Invoke-Bootstrap -CommandArgs @('-App', 'steam,vscode', '-DryRun')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('system-core', 'steam', 'vscode')) {
            Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern $expected.ToLowerInvariant() -Message 'Expected app component in dry-run output.'
        }
    }

    It 'resolves ai profile dry-run dependencies' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'ai', '-Component', 'docker', '-DryRun')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('node-core', 'python-core', 'wsl-core', 'docker', 'codex-cli')) {
            Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected resolved component in dry-run output.'
        }
        Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern 'host health mode: conservador' -Message 'Expected modern selections to default HostHealth to conservador.'
        Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern 'apptuning: recommended' -Message 'Expected modern selections to default AppTuning to recommended.'
    }

    It 'rejects excluding a required dependency' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'ai', '-Exclude', 'node-core', '-DryRun')

        ($result.ExitCode -ne 0) | Should Be $true
        (($result.Output -match 'depend') -or ($result.Output -match 'obrigat')) | Should Be $true
    }

    It 'shows the steamdeck recommended dry-run audit' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'steamdeck-recommended', '-SteamDeckVersion', 'Auto', '-DryRun')

        $result.ExitCode | Should Be 0
        foreach ($expected in @(
            'Resolved steam deck version: lcd',
            'Host health mode: conservador',
            'Audit:',
            'Runtimes:',
            'Payloads:',
            'Config:',
            'Verify:',
            'steamdeck-settings',
            'steamdeck-automation',
            'steamdeck-tweaks',
            'steamdeck-tools',
            'console-session-manager',
            'dev-session-manager',
            'display-classifier',
            'recovery-hotkeys',
            'console-readiness-audit',
            'displayfusion',
            'soundswitch'
        )) {
            Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern $expected.ToLowerInvariant() -Message 'Expected steamdeck-recommended audit output.'
        }

        foreach ($expected in @(
            'Console mode: HANDHELD=Game - Steam Deck',
            'DOCKED_TV=Game - Steam Deck',
            'DOCKED_MONITOR=Desktop/Dev',
            'Unknown external: UNCLASSIFIED_EXTERNAL -> UI classification -> fallback Desktop/Dev',
            'Handheld tweaks: hibernation=enabled, UTC clock, login-after-sleep=off, ms-gamebar=enabled, touch-keyboard=enabled',
            'Steam Deck tooling: RTSS, AMD Adrenalin, CRU, Steam Deck Tools'
        )) {
            Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected console-first Steam Deck dry-run output.'
        }
    }

    It 'keeps legacy profile default host health off' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'legacy', '-DryRun')

        $result.ExitCode | Should Be 0
        Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern 'host health mode: off' -Message 'Expected legacy to keep HostHealth off by default.'
        Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern 'apptuning: off' -Message 'Expected legacy to keep AppTuning off by default.'
    }

    It 'renders steamdeck app tuning categories in dry-run' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'steamdeck-recommended', '-SteamDeckVersion', 'Auto', '-DryRun')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('AppTuning: recommended', 'AppTuning categories:', 'gaming-console', 'steamdeck-control', 'dev-ai')) {
            Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected AppTuning dry-run output.'
        }
    }

    It 'supports custom app tuning category and item exclusions' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'steamdeck-recommended', '-SteamDeckVersion', 'Auto', '-AppTuning', 'custom', '-AppTuningCategory', 'gaming-console', '-ExcludeAppTuningItem', 'rtss-frame-presets', '-DryRun')

        $result.ExitCode | Should Be 0
        Assert-Contains -Text $result.Output -Pattern 'AppTuning: custom' -Message 'Expected custom AppTuning mode.'
        Assert-Contains -Text $result.Output -Pattern 'steam-big-picture-session' -Message 'Expected category item.'
        if ($result.Output -match 'AppTuning items:.*rtss-frame-presets') {
            throw "Excluded item should not be listed as selected.`nOutput:`n$($result.Output)"
        }
    }

    It 'renders equilibrado host health tasks' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'steamdeck-recommended', '-SteamDeckVersion', 'Auto', '-HostHealth', 'equilibrado', '-DryRun')

        $result.ExitCode | Should Be 0
        foreach ($expected in @(
            'Host health mode: equilibrado',
            'Host health cleanup:',
            'Host health startup:',
            'Host health registry-fixes:',
            'Host health game-mode:',
            'Host health bloat:',
            'Host health verify:',
            'Microsoft.GetHelp',
            'MSTeams',
            'game-handheld',
            'game-docked',
            'desktop'
        )) {
            Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected HostHealth equilibrado dry-run output.'
        }
    }

    It 'renders agressivo host health tasks' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'steamdeck-recommended', '-SteamDeckVersion', 'Auto', '-HostHealth', 'agressivo', '-DryRun')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('Host health mode: agressivo', 'Microsoft.BingSearch', 'Microsoft.MicrosoftPCManager')) {
            Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected HostHealth agressivo dry-run output.'
        }
    }

    It 'surfaces manual blockers in steamdeck full dry-run' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'steamdeck-full', '-SteamDeckVersion', 'Auto', '-DryRun')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('lossless-scaling', 'macrium-reflect', 'manual blockers:')) {
            Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern $expected.ToLowerInvariant() -Message 'Expected steamdeck-full output to surface manual blockers.'
        }
    }
}
