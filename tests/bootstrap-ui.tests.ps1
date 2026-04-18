$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$backendScriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
$uiScriptPath = Join-Path $repoRoot 'bootstrap-ui.ps1'
$uiLauncherBatPath = Join-Path $repoRoot 'bootstrap-ui.bat'

function Invoke-PowerShellScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$CommandArgs = @(),
        [int]$TimeoutMs = 30000
    )

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $CommandArgs
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
        throw "Failed to start PowerShell for $ScriptPath"
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutMs)) {
        try { $process.Kill() } catch { }
        throw "Invocation timed out after $TimeoutMs ms for $ScriptPath $($CommandArgs -join ' ')"
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

function Test-BackendUiContract {
    $result = Invoke-PowerShellScript -ScriptPath $backendScriptPath -CommandArgs @('-UiContractJson')
    if ($result.ExitCode -ne 0) {
        throw "Expected success for backend UI contract export, got exit code $($result.ExitCode)`n$($result.Output)"
    }

    $contract = $result.Output | ConvertFrom-Json
    if (-not $contract) {
        throw "Expected valid JSON contract output.`n$($result.Output)"
    }

    Assert-Contains -Text ($contract.hostHealthModes -join ',') -Pattern 'conservador' -Message 'Expected HostHealth modes in contract.'
    Assert-Contains -Text ($contract.profileNames -join ',') -Pattern 'steamdeck-recommended' -Message 'Expected steamdeck-recommended in contract.'
    Assert-Contains -Text ($contract.componentNames -join ',') -Pattern 'steamdeck-automation' -Message 'Expected steamdeck-automation in contract.'

    if ($contract.defaults.legacyHostHealth -ne 'off') {
        throw "Expected legacyHostHealth=off, got $($contract.defaults.legacyHostHealth)"
    }
    if ($contract.defaults.modernHostHealth -ne 'conservador') {
        throw "Expected modernHostHealth=conservador, got $($contract.defaults.modernHostHealth)"
    }
}

function Test-UiLauncherFilesExist {
    foreach ($path in @($uiScriptPath, $uiLauncherBatPath)) {
        if (-not (Test-Path $path)) {
            throw "Expected UI launcher file to exist: $path"
        }
    }
}

function Test-UiSmoke {
    $statePath = Join-Path $env:TEMP ("bootstrap_ui_state_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        $result = Invoke-PowerShellScript -ScriptPath $uiScriptPath -CommandArgs @('-SmokeTest', '-UiStatePath', $statePath) -TimeoutMs 45000
        if ($result.ExitCode -ne 0) {
            throw "Expected success for bootstrap-ui smoke test, got exit code $($result.ExitCode)`n$($result.Output)"
        }

        $smoke = $result.Output | ConvertFrom-Json
        if (-not $smoke) {
            throw "Expected valid JSON smoke output.`n$($result.Output)"
        }

        foreach ($expectedPage in @('welcome', 'selection', 'host-setup', 'steamdeck-control', 'review', 'run')) {
            Assert-Contains -Text ($smoke.pages -join ',') -Pattern $expectedPage -Message 'Expected wizard page in smoke output.'
        }
        foreach ($expectedLanguage in @('pt-BR', 'en-US')) {
            Assert-Contains -Text ($smoke.languages -join ',') -Pattern $expectedLanguage -Message 'Expected supported language in smoke output.'
        }

        if (-not (Test-Path $statePath)) {
            throw "Expected UI state file to be created by smoke test: $statePath"
        }
    } finally {
        if (Test-Path $statePath) {
            Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        }
    }
}

Test-BackendUiContract
Test-UiLauncherFilesExist
Test-UiSmoke

Write-Host 'bootstrap-ui.tests.ps1: PASS'
