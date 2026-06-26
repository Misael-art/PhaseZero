$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-PhaseZeroCliCoherenceTest {
    param(
        [Parameter(Mandatory = $true)][string]$Arguments,
        [int]$TimeoutMs = 180000
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = '/d /c ""{0}" {1}"' -f (Join-Path $script:RepoRoot 'install-cli.bat'), $Arguments
    $startInfo.WorkingDirectory = $script:RepoRoot
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
        try { $process.Kill() } catch { }
        throw "CLI excedeu timeout de $TimeoutMs ms."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Stdout = [string]$stdout
        Stderr = [string]$stderr
    }
}

Describe 'CLI and UI coherence' {
    It 'preserves excluded configs in the printed apply command' {
        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-exclude-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--config-category browser-startup --exclude-config zen-browser-privacy-prefs --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath)

            $run.ExitCode | Should Be 0
            $applyLine = [regex]::Match($run.Stdout, '(?m)^Aplicar:\s*(?<cmd>.+)$')
            $applyLine.Success | Should Be $true
            [string]$applyLine.Groups['cmd'].Value | Should Match '--config-category\s+browser-startup'
            [string]$applyLine.Groups['cmd'].Value | Should Match '--exclude-config\s+zen-browser-privacy-prefs'
            [string]$applyLine.Groups['cmd'].Value | Should Match '--yes'
            [string]$applyLine.Groups['cmd'].Value | Should Not Match '--dry-run'
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports a missing option value without treating the next flag as a selection' {
        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-missing-value-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--config --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath)

            $run.ExitCode | Should Be 2
            Test-Path -LiteralPath $resultPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'argument-parse'
            [string]$json.error | Should Match 'Valor ausente.*--config'
            [string]$json.error | Should Not Match "configuracao encontrado para '--dry-run'"
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes result json for MCP repair dry-run' {
        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-mcp-repair-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--repair-mcp --dry-run --yes --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath)

            $run.ExitCode | Should Be 0
            Test-Path -LiteralPath $resultPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'mcp-repair'
            [bool]$json.dryRun | Should Be $true
            $json.PSObject.Properties.Name -contains 'targets' | Should Be $true
            $json.PSObject.Properties.Name -contains 'artifactPaths' | Should Be $true
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'uses a guarded backend process helper instead of raw Start-Process wait in CLI execution paths' {
        $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install-cli.ps1') -Raw

        $raw | Should Match 'function Invoke-CliBackendProcess'
        $raw | Should Match 'WaitForExit\(\$TimeoutMs\)'
        $raw | Should Match 'Write-CliLegacyFailureResult'
        $raw | Should Not Match '\$dryProcess\s*=\s*Start-Process -FilePath ''powershell\.exe'' -ArgumentList \$dryArgs -NoNewWindow -PassThru -Wait'
        $raw | Should Not Match '\$installProcess\s*=\s*Start-Process -FilePath ''powershell\.exe'' -ArgumentList \$installArgs -NoNewWindow -PassThru -Wait'
    }

    It 'keeps apply backend timeout configurable and longer than large profile installs' {
        $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install-cli.ps1') -Raw

        $raw | Should Match 'BackendTimeoutMs'
        $raw | Should Match 'PHASEZERO_CLI_APPLY_TIMEOUT_MS'
        $raw | Should Match '7200000'
        $raw | Should Not Match '\[int\]\$TimeoutMs\s*=\s*1800000'
    }

    It 'writes common envelope fields for lifecycle dry-run' {
        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-lifecycle-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        $exportDir = Join-Path $env:TEMP ("phasezero-export-{0}" -f ([Guid]::NewGuid().ToString('N')))
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--item cursor --export-config "{0}" --dry-run --yes --result-path "{1}" --log-path "{2}"' -f $exportDir, $resultPath, $logPath)

            $run.ExitCode | Should Be 0
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'config-lifecycle'
            [bool]$json.dryRun | Should Be $true
            $json.PSObject.Properties.Name -contains 'artifactPaths' | Should Be $true
            $json.PSObject.Properties.Name -contains 'diagnostics' | Should Be $true
            $json.PSObject.Properties.Name -contains 'rollback' | Should Be $true
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $exportDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'lists a unified numbered catalog and resolves its first number through --item' {
        $list = Invoke-PhaseZeroCliCoherenceTest -Arguments '--list-items'

        $list.ExitCode | Should Be 0
        $list.Stdout | Should Match '(?m)^\s*1\.\s+\[(app|config|tool)\]\s+'
        $list.Stdout | Should Not Match '(?m)acoes:\s*\|\s*risco:\s*$'
        $first = [regex]::Match($list.Stdout, '(?m)^\s*1\.\s+\[(?<kind>app|config|tool)\]\s+(?<id>[^\s|]+)')
        $first.Success | Should Be $true

        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-item-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--item 1 --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath)
            $run.ExitCode | Should Be 0
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.item | Should Be ([string]$first.Groups['id'].Value)
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps isolated result collection fields as arrays and doctor as a structured object' {
        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-result-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--item traefik --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath)
            $run.ExitCode | Should Be 0
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop

            $json.paths -is [System.Array] | Should Be $true
            $json.nextSteps -is [System.Array] | Should Be $true
            $null -eq $json.doctor | Should Be $false
            [string]$json.doctor.status | Should Be 'not-run'
            $json.doctor.checks -is [System.Array] | Should Be $true
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'labels the AppTuning local refresh action honestly' {
        $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'bootstrap-ui.ps1') -Raw

        $raw | Should Match "AppTuningAudit\s*=\s*'Refresh status'"
        $raw | Should Match "AppTuningAudit\s*=\s*'Atualizar status'"
        $raw | Should Match 'Status local atualizado'
    }

    It 'returns individual selection guidance when --item does not resolve' {
        $resultPath = Join-Path $env:TEMP ("phasezero-coherence-error-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $logPath = [System.IO.Path]::ChangeExtension($resultPath, '.log')
        try {
            $run = Invoke-PhaseZeroCliCoherenceTest -Arguments ('--item item-inexistente --dry-run --yes --no-admin --result-path "{0}" --log-path "{1}"' -f $resultPath, $logPath)
            $run.ExitCode | Should Be 2
            $run.Stdout | Should Match 'Result:'
            $run.Stdout | Should Match 'Log:'
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'isolated-selection'
            [string]$json.howToFix | Should Match '--list-items'
        } finally {
            Remove-Item -LiteralPath $resultPath,$logPath -Force -ErrorAction SilentlyContinue
        }
    }
}
