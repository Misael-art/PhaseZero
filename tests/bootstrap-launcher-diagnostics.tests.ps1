$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot    = Split-Path -Parent $PSScriptRoot
$uiBat       = Join-Path $repoRoot 'bootstrap-ui.bat'
$toolsScript = Join-Path $repoRoot 'bootstrap-tools.ps1'

function Invoke-PhaseZeroBatForTest {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$Arguments = '',
        [int]$TimeoutMs = 180000,
        [string]$StdinText = ''
    )

    $out = Join-Path $env:TEMP ("phasezero-bat-{0}.out" -f ([Guid]::NewGuid().ToString('N')))
    $err = Join-Path $env:TEMP ("phasezero-bat-{0}.err" -f ([Guid]::NewGuid().ToString('N')))
    $process = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Join-Path $repoRoot $FileName)
        $startInfo.Arguments = $Arguments
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        if ($StdinText) {
            $startInfo.RedirectStandardInput = $true
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $null = $process.Start()
        if ($StdinText) {
            # Escrever bytes crus sem BOM: StandardInput.Write usa Console.InputEncoding e pode
            # emitir preambulo UTF-8, fazendo o menu receber "<BOM>5" e rejeitar a opcao.
            $stdinBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes([string]$StdinText)
            $process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
            $process.StandardInput.BaseStream.Flush()
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
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Stdout   = $stdout
            Stderr   = $stderr
        }
    } finally {
        if ($process) { try { $process.Dispose() } catch { Write-Verbose $_.Exception.Message } }
        Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
    }
}

Describe 'PhaseZero launcher diagnostics and CLI short menu' {
    It 'maps bootstrap-ui.bat atalhos to backend -Intent -DryRun -NonInteractive' {
        $raw = Get-Content -LiteralPath $uiBat -Raw
        $raw | Should Match '"--doctor"\s+set\s+"BOOTSTRAP_UI_SHORTCUT=doctor"'
        $raw | Should Match '"--support-bundle"\s+set\s+"BOOTSTRAP_UI_SHORTCUT=support-bundle"'
        $raw | Should Match '"--repair-plan"\s+set\s+"BOOTSTRAP_UI_SHORTCUT=repair-plan"'
        $raw | Should Match 'SHORTCUT_FLAG=-Doctor"'
        $raw | Should Match 'SHORTCUT_FLAG=-SupportBundle"'
        $raw | Should Match 'SHORTCUT_FLAG=-RepairPlan"'
        $raw | Should Match '%SHORTCUT_FLAG%\s+-DryRun\s+-NonInteractive'
        $raw | Should Match '"--smoke"\s+set\s+"BOOTSTRAP_SMOKE_TEST=1"'
        $raw | Should Match '"--verbose"\s+set\s+"BOOTSTRAP_UI_VERBOSE=1"'
    }

    It 'keeps the launcher diagnostics banner for --doctor and forwards to doctor mode' {
        $result = Invoke-PhaseZeroBatForTest -FileName 'bootstrap-ui.bat' -Arguments '--doctor' -TimeoutMs 180000

        $result.ExitCode | Should Be 0
        $result.Stdout   | Should Match 'PhaseZero atalho doctor \(dry-run, sem alteracoes\)'
        $result.Stdout   | Should Match 'Modo: Doctor'
    }

    It 'renders the Run timeline in WPF smoke output' {
        $result = Invoke-PhaseZeroBatForTest -FileName 'bootstrap-ui.bat' -Arguments '-SmokeTestWindow' -TimeoutMs 90000

        $result.ExitCode | Should Be 0
        [string]::IsNullOrWhiteSpace([string]$result.Stderr) | Should Be $true
        $json = $result.Stdout | ConvertFrom-Json -ErrorAction Stop
        $json.runTimeline | Should Not BeNullOrEmpty
        [bool]$json.runTimeline.present | Should Be $true
        $expectedStages = @('Preparando','Dry-run','Executando','result.json','Bundle/Logs')
        $actual = @($json.runTimeline.stages)
        $actual.Count | Should Be $expectedStages.Count
        for ($i = 0; $i -lt $expectedStages.Count; $i++) {
            [string]$actual[$i] | Should Be $expectedStages[$i]
        }
    }

    It 'exposes launcherDiagnostics, guidedCliMenu and runTimeline in the UI contract' {
        . $toolsScript
        Reset-BootstrapFileCmdlets
        $contract = Get-BootstrapUiContract
        $contract.schemaVersion | Should Be '1.6.0'
        [bool]$contract.capabilities.launcherDiagnostics | Should Be $true
        [bool]$contract.capabilities.guidedCliMenu       | Should Be $true
        [bool]$contract.capabilities.runTimeline         | Should Be $true
    }

    It 'refuses install-cli.bat without -Profile in non-interactive mode and emits result.json' {
        $result = Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '-NonInteractive' -TimeoutMs 60000

        $result.ExitCode | Should Be 2
        $result.Stdout   | Should Match '-Profile e obrigatorio em modo nao-interativo'
        $braceIdx = $result.Stdout.IndexOf('{')
        $braceIdx | Should BeGreaterThan -1
        $jsonText = $result.Stdout.Substring($braceIdx).Trim()
        $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
        [string]$json.status | Should Be 'error'
        [string]$json.error  | Should Match '-Profile e obrigatorio'
    }

    It 'shows the short CLI menu when install-cli.bat is launched interactively without --profile' {
        $result = Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '' -TimeoutMs 60000 -StdinText "0`n"

        $result.ExitCode | Should Be 0
        $result.Stdout   | Should Match 'menu rapido'
        $result.Stdout   | Should Match 'Doctor \(diagnostico, dry-run sem alteracoes\)'
        $result.Stdout   | Should Match 'Exportar SupportBundle'
        $result.Stdout   | Should Match 'Dry-run perfil safe-base'
        $result.Stdout   | Should Match 'Instalacao guiada'
    }

    # Menu interativo via .bat: incompativel com o runner headless do CI (stdin redirecionado
    # sem console -> stdout vazio). Roda em host Windows com console; pulado no GitHub Actions.
    It 'lists profiles from the guided picker when menu option 5 is selected' -Skip:([bool]$env:GITHUB_ACTIONS) {
        $result = Invoke-PhaseZeroBatForTest -FileName 'install-cli.bat' -Arguments '' -TimeoutMs 60000 -StdinText "5`n0`n"

        $result.ExitCode | Should Be 0
        $result.Stdout   | Should Match 'Perfis recomendados'
        $result.Stdout   | Should Match 'safe-base'
        $result.Stdout   | Should Match 'public-beta'
    }
}
