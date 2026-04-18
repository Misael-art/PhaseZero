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

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $output = @($stdout, $stderr) -join [Environment]::NewLine

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $output
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

function Test-ListProfiles {
    $result = Invoke-Bootstrap -CommandArgs @('-ListProfiles')
    if ($result.ExitCode -ne 0) {
        throw "Expected success for -ListProfiles, got exit code $($result.ExitCode)`n$($result.Output)"
    }

    Assert-Contains -Text $result.Output -Pattern 'legacy' -Message 'Expected legacy profile in output.'
    Assert-Contains -Text $result.Output -Pattern 'recommended' -Message 'Expected recommended profile in output.'
    Assert-Contains -Text $result.Output -Pattern 'steamdeck-recommended' -Message 'Expected steamdeck-recommended profile in output.'
    Assert-Contains -Text $result.Output -Pattern 'steamdeck-full' -Message 'Expected steamdeck-full profile in output.'
    Assert-Contains -Text $result.Output -Pattern 'steamdeck-dock' -Message 'Expected steamdeck-dock profile in output.'
}

function Test-ListHostHealthModes {
    $result = Invoke-Bootstrap -CommandArgs @('-ListHostHealthModes')
    if ($result.ExitCode -ne 0) {
        throw "Expected success for -ListHostHealthModes, got exit code $($result.ExitCode)`n$($result.Output)"
    }

    foreach ($expected in @('off', 'conservador', 'equilibrado', 'agressivo')) {
        Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected host health mode in output.'
    }
}

function Test-DryRunResolution {
    $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'ai', '-Component', 'docker', '-DryRun')
    if ($result.ExitCode -ne 0) {
        throw "Expected success for ai+docker dry-run, got exit code $($result.ExitCode)`n$($result.Output)"
    }

    foreach ($expected in @('node-core', 'python-core', 'wsl-core', 'docker', 'codex-cli')) {
        Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected resolved component in dry-run output.'
    }

    Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern 'host health mode: conservador' -Message 'Expected modern selections to default HostHealth to conservador.'
}

function Test-InvalidExcludeFails {
    $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'ai', '-Exclude', 'node-core', '-DryRun')
    if ($result.ExitCode -eq 0) {
        throw "Expected failure when excluding mandatory dependency.`n$($result.Output)"
    }

    if (($result.Output -notmatch 'depend') -and ($result.Output -notmatch 'obrigat')) {
        throw "Expected dependency or required-component error message.`n$($result.Output)"
    }
}

function Test-SteamDeckRecommendedDryRun {
    $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'steamdeck-recommended', '-SteamDeckVersion', 'Auto', '-DryRun')
    if ($result.ExitCode -ne 0) {
        throw "Expected success for steamdeck-recommended dry-run, got exit code $($result.ExitCode)`n$($result.Output)"
    }

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

function Test-LegacyDefaultsHostHealthOff {
    $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'legacy', '-DryRun')
    if ($result.ExitCode -ne 0) {
        throw "Expected success for legacy dry-run, got exit code $($result.ExitCode)`n$($result.Output)"
    }

    Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern 'host health mode: off' -Message 'Expected legacy to keep HostHealth off by default.'
}

function Test-HostHealthEquilibradoDryRun {
    $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'steamdeck-recommended', '-SteamDeckVersion', 'Auto', '-HostHealth', 'equilibrado', '-DryRun')
    if ($result.ExitCode -ne 0) {
        throw "Expected success for HostHealth equilibrado dry-run, got exit code $($result.ExitCode)`n$($result.Output)"
    }

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

function Test-HostHealthAgressivoDryRun {
    $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'steamdeck-recommended', '-SteamDeckVersion', 'Auto', '-HostHealth', 'agressivo', '-DryRun')
    if ($result.ExitCode -ne 0) {
        throw "Expected success for HostHealth agressivo dry-run, got exit code $($result.ExitCode)`n$($result.Output)"
    }

    foreach ($expected in @('Host health mode: agressivo', 'Microsoft.BingSearch', 'Microsoft.MicrosoftPCManager')) {
        Assert-Contains -Text $result.Output -Pattern $expected -Message 'Expected HostHealth agressivo dry-run output.'
    }
}

function Test-SteamDeckFullDryRun {
    $result = Invoke-Bootstrap -CommandArgs @('-Profile', 'steamdeck-full', '-SteamDeckVersion', 'Auto', '-DryRun')
    if ($result.ExitCode -ne 0) {
        throw "Expected success for steamdeck-full dry-run, got exit code $($result.ExitCode)`n$($result.Output)"
    }

    foreach ($expected in @('lossless-scaling', 'macrium-reflect', 'manual blockers:')) {
        Assert-Contains -Text $result.Output.ToLowerInvariant() -Pattern $expected.ToLowerInvariant() -Message 'Expected steamdeck-full output to surface manual blockers.'
    }
}

Test-ListHostHealthModes
Test-ListProfiles
Test-DryRunResolution
Test-InvalidExcludeFails
Test-SteamDeckRecommendedDryRun
Test-SteamDeckFullDryRun
Test-LegacyDefaultsHostHealthOff
Test-HostHealthEquilibradoDryRun
Test-HostHealthAgressivoDryRun

Write-Host 'bootstrap-tools.profiles.tests.ps1: PASS'
