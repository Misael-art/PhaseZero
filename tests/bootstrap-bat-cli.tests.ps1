$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-PhaseZeroBatForTest {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$Arguments = '',
        [string]$StdinText = '',
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
        if (-not [string]::IsNullOrEmpty($StdinText)) {
            $startInfo.RedirectStandardInput = $true
        }
        $startInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $null = $process.Start()
        if (-not [string]::IsNullOrEmpty($StdinText)) {
            $process.StandardInput.Write($StdinText)
            $process.StandardInput.Close()
        }
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

    It 'passes install-cli.bat individual app dry-run through to the backend' {
        $resultPath = Join-Path $env:TEMP ("phasezero-bat-app-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = Join-Path $env:TEMP ("phasezero-bat-app-{0}.log" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $args = '--app app-zen-browser --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath
            $result = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments $args | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

            $result.ExitCode | Should Be 0
            [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
            Test-Path -LiteralPath $resultPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'isolated'
            [string]$json.status | Should Be 'success'
            [bool]$json.dryRun | Should Be $true
            (@($json.selection.Components) -contains 'zen-browser') | Should Be $true
            [string]$json.resolvedHostHealthMode | Should Be 'off'
            [string]$json.resolvedAppTuningMode | Should Be 'off'
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'passes install-cli.bat individual config dry-run without selecting legacy profile' {
        $resultPath = Join-Path $env:TEMP ("phasezero-bat-config-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = Join-Path $env:TEMP ("phasezero-bat-config-{0}.log" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $args = '--config zen-browser-privacy-prefs --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath
            $result = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments $args | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

            $result.ExitCode | Should Be 0
            [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
            Test-Path -LiteralPath $resultPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'isolated'
            [string]$json.status | Should Be 'success'
            [bool]$json.dryRun | Should Be $true
            @($json.selection.Profiles).Count | Should Be 0
            (@($json.selection.AppTuningItems) -contains 'zen-browser-privacy-prefs') | Should Be $true
            [string]$json.resolvedHostHealthMode | Should Be 'off'
            [string]$json.resolvedAppTuningMode | Should Be 'custom'
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'applies an individual config without components or legacy profile' {
        $resultPath = Join-Path $env:TEMP ("phasezero-bat-config-apply-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = Join-Path $env:TEMP ("phasezero-bat-config-apply-{0}.log" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $args = '--config agent-config-claude-rtk-template --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath
            $result = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments $args -TimeoutMs 360000 | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

            $result.ExitCode | Should Be 0
            [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
            Test-Path -LiteralPath $resultPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'isolated'
            [string]$json.status | Should Be 'success'
            @($json.selection.Profiles).Count | Should Be 0
            @($json.selection.Components).Count | Should Be 0
            (@($json.selection.AppTuningItems) -contains 'agent-config-claude-rtk-template') | Should Be $true
            [string]$json.resolvedAppTuningMode | Should Be 'custom'
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'lists individual apps and configs from install-cli.bat' {
        $apps = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '--list-apps' | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]
        $configs = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '--list-configs' | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

        $apps.ExitCode | Should Be 0
        $apps.Stdout | Should Match 'app-zen-browser'
        $apps.Stdout | Should Match 'component: zen-browser'
        $configs.ExitCode | Should Be 0
        $configs.Stdout | Should Match 'zen-browser-privacy-prefs'
        $configs.Stdout | Should Match 'agent-config'
    }

    It 'prints numbered one-line app and config catalogs for human selection' {
        $apps = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '--list-apps' | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]
        $configs = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '--list-configs' | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

        $apps.ExitCode | Should Be 0
        $apps.Stdout | Should Match '(?m)^\s*1\.\s+\[app\]\s+'
        $apps.Stdout | Should Match '(?m)^\s*\d+\.\s+\[app\]\s+app-zen-browser\s+\|\s+Zen Browser\s+\|\s+component: zen-browser\s+\|\s+termos:'
        $configs.ExitCode | Should Be 0
        $configs.Stdout | Should Match '(?m)^\s*1\.\s+\[config\]\s+'
        $configs.Stdout | Should Match '(?m)^\s*\d+\.\s+\[config\]\s+zen-browser-privacy-prefs\s+\|\s+Zen Browser privacy prefs\s+\|\s+categoria: browser-startup\s+\|\s+termos:'
    }

    It 'lists safe automation configs by category and accepts unified item aliases' {
        $configs = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '--list-configs' | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

        $configs.ExitCode | Should Be 0
        $configs.Stdout | Should Match '\[container-hosting\]'
        $configs.Stdout | Should Match '\[ai-edge-safe\]'
        $configs.Stdout | Should Match '(?m)^\s*\d+\.\s+\[config\]\s+reverse-proxy-traefik-pack\s+\|'
        $configs.Stdout | Should Match 'acoes:'
        $configs.Stdout | Should Match 'risco:'

        $resultPath = Join-Path $env:TEMP ("phasezero-bat-item-traefik-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = Join-Path $env:TEMP ("phasezero-bat-item-traefik-{0}.log" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $args = '--item traefik --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath
            $result = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments $args | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

            $result.ExitCode | Should Be 0
            [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.item | Should Be 'reverse-proxy-traefik-pack'
            [string]$json.category | Should Be 'container-hosting'
            [string]$json.action | Should Be 'dry-run'
            $json.PSObject.Properties.Name -contains 'changed' | Should Be $true
            $json.PSObject.Properties.Name -contains 'blockedReason' | Should Be $true
            $json.PSObject.Properties.Name -contains 'paths' | Should Be $true
            $json.PSObject.Properties.Name -contains 'nextSteps' | Should Be $true
            $json.PSObject.Properties.Name -contains 'doctor' | Should Be $true
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts a readable config term for isolated dry-run' {
        $resultPath = Join-Path $env:TEMP ("phasezero-bat-config-term-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = Join-Path $env:TEMP ("phasezero-bat-config-term-{0}.log" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $args = '--config "Zen Browser privacy prefs" --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath
            $result = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments $args | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

            $result.ExitCode | Should Be 0
            [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            (@($json.selection.AppTuningItems) -contains 'zen-browser-privacy-prefs') | Should Be $true
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the guided app menu open long enough to pick by term and cancel after dry-run' {
        $stdin = "7`nzen`nN`n"
        $result = @(Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '' -StdinText $stdin -TimeoutMs 180000 | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') })[0]

        $result.ExitCode | Should Be 0
        [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
        $result.Stdout | Should Match 'Apps individuais'
        $result.Stdout | Should Match 'Digite numero, ID ou termo'
        $result.Stdout | Should Match 'Dry-run individual'
        $result.Stdout | Should Match 'Operacao cancelada pelo usuario'
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
