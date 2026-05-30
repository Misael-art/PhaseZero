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
        try { & taskkill.exe /PID $process.Id /T /F | Out-Null } catch { $null = $_ }
        try { if (-not $process.HasExited) { $process.Kill() } } catch { $null = $_ }
        throw "Bootstrap invocation timed out after 120000ms for args: $($CommandArgs -join ' ')"
    }

    [void]$stdoutTask.Wait(5000)
    [void]$stderrTask.Wait(5000)

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
        foreach ($expected in @('legacy', 'safe-base', 'dev-ai', 'full-workstation', 'recommended', 'steamdeck-recommended', 'steamdeck-full', 'steamdeck-dock')) {
            Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected profile in output.'
        }
    }

    It 'renders install-cli profile selection as readable line-bounded sections' {
        $cli = Join-Path $repoRoot 'install-cli.ps1'
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $cli -ListProfiles 2>&1
        $LASTEXITCODE | Should Be 0
        $text = (@($output) -join [Environment]::NewLine)
        $lines = @($text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $text | Should Match 'Perfis recomendados'
        $text | Should Match 'Steam Deck'
        $text | Should Match 'Nome\s+Descricao'
        $text | Should Match '(?m)^\s*safe-base\s{2,}'
        $text | Should Not Match 'legacy - .*safe-base - .*public-beta -'
        @($lines | Where-Object { $_.Length -gt 118 }).Count | Should Be 0
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

    It 'ships a Pester wrapper with explicit FailedCount exit semantics' {
        $runner = Join-Path $repoRoot 'tests\run-pester.ps1'

        Test-Path $runner | Should Be $true
        $raw = Get-Content -Path $runner -Raw
        $raw | Should Match 'Invoke-Pester'
        $raw | Should Match '-PassThru'
        $raw | Should Match 'FailedCount'
        $raw | Should Match '\[Environment\]::Exit\(\$exitCode\)'
    }

    It 'documents the safe product contract without mojibake' {
        $readme = Get-Content -Path (Join-Path $repoRoot 'README.md') -Raw

        $readme | Should Not Match '\u00F0|\u00C3|\u00C2|\uFFFD|\u00E2\u0080|\u00E2\u009C|\u00E2\u009A'
        $readme | Should Match 'safe-base'
        $readme | Should Match 'full-workstation'
        $readme | Should Match 'result\.json'
        $readme | Should Match 'UnsupportedAudit'
        $readme | Should Match 'Limites'
    }

    It 'resolves individual app requests into components' {
        $result = Invoke-Bootstrap -CommandArgs @('-App', 'steam,vscode', '-DryRun')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('system-core', 'steam', 'vscode')) {
            Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern $expected.ToLowerInvariant() -Message 'Expected app component in dry-run output.'
        }
    }

    It 'keeps component-only dry-run free from HostHealth and AppTuning defaults' {
        $result = Invoke-Bootstrap -CommandArgs @('-Component', 'notepadpp', '-DryRun')

        $result.ExitCode | Should Be 0
        Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern 'host health mode: off' -Message 'Expected component-only dry-run to keep HostHealth off.'
        Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern 'apptuning: off' -Message 'Expected component-only dry-run to keep AppTuning off.'
    }

    It 'writes a default result json even when ResultPath is omitted' {
        $result = Invoke-Bootstrap -CommandArgs @('-Component', 'notepadpp', '-DryRun', '-NonInteractive')

        $result.ExitCode | Should Be 0
        $match = [regex]::Match($result.Output, 'Result:\s*(.+?\.result\.json)')
        $match.Success | Should Be $true
        $resultPath = $match.Groups[1].Value.Trim()
        Test-Path -LiteralPath $resultPath | Should Be $true
        $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        [string]$json.status | Should Be 'success'
        [string]$json.resultPath | Should Be $resultPath
        [string]$json.mode | Should Be 'profile'
        [int]$json.exitCode | Should Be 0
        [string]$json.artifactPaths.resultPath | Should Be $resultPath
        [string]$json.artifactPaths.logPath | Should Not Be ''
        @($json.diagnostics).Count | Should Be 0
        [string]$json.scope.selection.Components[0] | Should Be 'notepadpp'
        [string]$json.scope.resolution.ResolvedComponents[0] | Should Be 'system-core'
        $json.rollback.available | Should Be $false
    }

    It 'install-cli legacy dry-run passes result and log paths through to backend' {
        $cli = Join-Path $repoRoot 'install-cli.ps1'
        $resultPath = Join-Path $env:TEMP ("phasezero-install-cli-{0}.result.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = Join-Path $env:TEMP ("phasezero-install-cli-{0}.log" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $cli -Profile safe-base -DryRun -NonInteractive --result-path $resultPath --log-path $logPath 2>&1
            $LASTEXITCODE | Should Be 0
            Test-Path -LiteralPath $resultPath | Should Be $true
            Test-Path -LiteralPath $logPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            [string]$json.status | Should Be 'success'
            [string]$json.resolvedHostHealthMode | Should Be 'off'
            [string]$json.resolvedAppTuningMode | Should Be 'off'
            [string]$json.artifactPaths.resultPath | Should Be ([System.IO.Path]::GetFullPath($resultPath))
            [string]$json.artifactPaths.logPath | Should Be ([System.IO.Path]::GetFullPath($logPath))
            [int]$json.exitCode | Should Be 0
        } finally {
            Remove-Item -LiteralPath $resultPath, $logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'install-cli legacy missing profile writes actionable result schema' {
        $cli = Join-Path $repoRoot 'install-cli.ps1'
        $resultPath = Join-Path $env:TEMP ("phasezero-install-cli-missing-profile-{0}.result.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = Join-Path $env:TEMP ("phasezero-install-cli-missing-profile-{0}.log" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $cli -NonInteractive --result-path $resultPath --log-path $logPath 2>&1
            $LASTEXITCODE | Should Be 2
            Test-Path -LiteralPath $resultPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            [string]$json.status | Should Be 'error'
            [int]$json.exitCode | Should Be 2
            [string]$json.artifactPaths.resultPath | Should Be ([System.IO.Path]::GetFullPath($resultPath))
            [string]$json.artifactPaths.logPath | Should Be ([System.IO.Path]::GetFullPath($logPath))
            @($json.diagnostics).Count | Should BeGreaterThan 0
            [string]$json.diagnostics[0].message | Should Match 'Profile'
            $json.rollback.available | Should Be $false
        } finally {
            Remove-Item -LiteralPath $resultPath, $logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps safe-base and recommended small without AI desktop or container stacks' {
        foreach ($profileName in @('safe-base', 'recommended')) {
            $resultPath = Join-Path $env:TEMP ("phasezero-{0}-{1}.json" -f $profileName, ([Guid]::NewGuid().ToString('N')))
            try {
                $result = Invoke-Bootstrap -CommandArgs @('-Profile', $profileName, '-DryRun', '-NonInteractive', '-ResultPath', $resultPath)

                $result.ExitCode | Should Be 0
                Test-Path $resultPath | Should Be $true
                $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
                @($json.resolution.ResolvedComponents).Count | Should BeLessThan 25
                foreach ($forbidden in @('docker', 'wsl-core', 'claude-desktop', 'cursor', 'steam', 'visual-studio-community')) {
                    (@($json.resolution.ResolvedComponents) -contains $forbidden) | Should Be $false
                }
                [string]$json.resolvedHostHealthMode | Should Be 'off'
                [string]$json.resolvedAppTuningMode | Should Be 'off'
            } finally {
                Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'keeps full-workstation as explicit broad opt-in profile' {
        $resultPath = Join-Path $env:TEMP ("phasezero-full-workstation-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'full-workstation', '-DryRun', '-NonInteractive', '-ResultPath', $resultPath)

            $result.ExitCode | Should Be 0
            Test-Path $resultPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            @($json.resolution.ResolvedComponents).Count | Should BeGreaterThan 40
            foreach ($expected in @('docker', 'claude-desktop', 'cursor', 'notepadpp')) {
                (@($json.resolution.ResolvedComponents) -contains $expected) | Should Be $true
            }
        } finally {
            Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
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
