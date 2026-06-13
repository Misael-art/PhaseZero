$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-PhaseZeroBatForTest {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$Arguments = '',
        [int]$TimeoutMs = 180000
    )

    $out = Join-Path $env:TEMP ("phasezero-bat-{0}.out" -f ([Guid]::NewGuid().ToString('N')))
    $err = Join-Path $env:TEMP ("phasezero-bat-{0}.err" -f ([Guid]::NewGuid().ToString('N')))
    $process = $null
    $result = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Join-Path $repoRoot $FileName)
        $startInfo.Arguments = $Arguments
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch { Write-Verbose $_.Exception.Message }
            throw ("{0} timed out for args: {1}" -f $FileName, $Arguments)
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result

        $result = [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
        }
    } finally {
        if ($process) { try { $process.Dispose() } catch { Write-Verbose $_.Exception.Message } }
        Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
    }
    return $result
}

Describe 'PhaseZero BAT launchers' {
    It 'runs bootstrap-ui.bat SmokeTest without stderr or console noise' {
        $result = @(Invoke-PhaseZeroBatForTest -FileName 'bootstrap-ui.bat' -Arguments '-SmokeTest' | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

        $result.ExitCode | Should Be 0
        [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
        $json = $result.Stdout | ConvertFrom-Json -ErrorAction Stop
        (@($json.pages) -contains 'health') | Should Be $true
        $replacementCharacter = [string][char]0xFFFD
        $result.Stdout | Should Not Match ('\[INFO\]|\[WARN\]|Configurao|Verso|sade|RPIDOS|' + [regex]::Escape($replacementCharacter))
    }

    It 'runs bootstrap-ui.bat SmokeTestWindow without opening a persistent process' {
        $result = @(Invoke-PhaseZeroBatForTest -FileName 'bootstrap-ui.bat' -Arguments '-SmokeTestWindow' | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

        $result.ExitCode | Should Be 0
        [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
        $json = $result.Stdout | ConvertFrom-Json -ErrorAction Stop
        [bool]$json.windowLoaded | Should Be $true
        [bool]$json.handlersRegistered | Should Be $true
    }

    It 'passes install-cli.bat AI Usagebar dry-run validation arguments through as JSON' {
        $result = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '--tool ai-usagebar --validate --dry-run --yes' | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

        $result.ExitCode | Should Be 0
        [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
        $json = $result.Stdout | ConvertFrom-Json -ErrorAction Stop
        [string]$json.tool | Should Be 'ai-usagebar'
        [string]$json.action | Should Be 'validate'
        [bool]$json.dryRun | Should Be $true
        $replacementCharacter = [string][char]0xFFFD
        $result.Stdout | Should Not Match ('ghp_|sk-or-|sk-|protectedData|Configurao|Verso|sade|RPIDOS|' + [regex]::Escape($replacementCharacter))
    }

    It 'keeps install-cli.bat ListProfiles readable and free of mojibake' {
        $result = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '-ListProfiles' | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

        $result.ExitCode | Should Be 0
        [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
        $result.Stdout | Should Match 'Perfis recomendados'
        $result.Stdout | Should Match 'safe-base'
        @($result.Stdout -split '\r?\n' | Where-Object { $_.Length -gt 118 }).Count | Should Be 0
        $replacementCharacter = [string][char]0xFFFD
        $result.Stdout | Should Not Match ('Configurao|Verso|sade|RPIDOS|' + [regex]::Escape($replacementCharacter))
    }

    It 'quotes script paths and forwards all arguments from paths that may contain spaces' {
        $installBat = Get-Content -LiteralPath (Join-Path $repoRoot 'install-cli.bat') -Raw
        $uiBat = Get-Content -LiteralPath (Join-Path $repoRoot 'bootstrap-ui.bat') -Raw

        $installBat | Should Match '"%SCRIPT_DIR%install-cli\.ps1" %\*'
        $installBat | Should Match 'pushd "%SCRIPT_DIR%"'
        $uiBat | Should Match '"%UI_SCRIPT%".*%\*'
        $uiBat | Should Match 'pushd "%SCRIPT_DIR%"'
    }

    It 'keeps BAT launchers robust for literal arguments and missing fixed PowerShell paths' {
        $installBat = Get-Content -LiteralPath (Join-Path $repoRoot 'install-cli.bat') -Raw
        $uiBat = Get-Content -LiteralPath (Join-Path $repoRoot 'bootstrap-ui.bat') -Raw

        $installBat | Should Match 'setlocal EnableExtensions DisableDelayedExpansion'
        $uiBat | Should Match 'setlocal EnableExtensions DisableDelayedExpansion'
        $installBat | Should Match 'if not defined PS_EXE set "PS_EXE=powershell\.exe"'
        $installBat | Should Match 'BOOTSTRAP_CLI_VERBOSE'
        $installBat | Should Not Match 'echo \[install-cli\].*1>&2'
    }
}
