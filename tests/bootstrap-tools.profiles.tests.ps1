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

    if (-not $process.WaitForExit(30000)) {
        try { $process.Kill() } catch { }
        throw "Bootstrap invocation timed out after 30000ms for args: $($CommandArgs -join ' ')"
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

    It 'resolves ai profile dry-run dependencies' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'ai', '-Component', 'docker', '-DryRun')

        $result.ExitCode | Should Be 0
        foreach ($expected in @('node-core', 'python-core', 'wsl-core', 'docker', 'codex-cli')) {
            Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected resolved component in dry-run output.'
        }
        Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern 'host health mode: conservador' -Message 'Expected modern selections to default HostHealth to conservador.'
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
            'displayfusion',
            'soundswitch'
        )) {
            Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern $expected.ToLowerInvariant() -Message 'Expected steamdeck-recommended audit output.'
        }
    }

    It 'keeps legacy profile default host health off' {
        $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'legacy', '-DryRun')

        $result.ExitCode | Should Be 0
        Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern 'host health mode: off' -Message 'Expected legacy to keep HostHealth off by default.'
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
