$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$uiScriptPath = Join-Path $repoRoot 'bootstrap-ui.ps1'

function New-TestDataRoot {
    return (Join-Path $env:TEMP ("bootstrap_ui_{0}" -f ([Guid]::NewGuid().ToString('N'))))
}

function Remove-TestDataRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Bootstrap UI launcher' {
    BeforeEach {
        $script:TestDataRoot = New-TestDataRoot
    }

    AfterEach {
        Remove-TestDataRoot -Path $script:TestDataRoot
        Remove-Variable -Scope Script -Name TestDataRoot -ErrorAction SilentlyContinue
    }

    It 'supports smoke test execution from Windows PowerShell file mode' {
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $uiStatePath = Join-Path $script:TestDataRoot 'ui-state.json'
        $uiLogPath = Join-Path $script:TestDataRoot 'bootstrap-ui.log'

        $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $uiScriptPath -UiStatePath $uiStatePath -UiLogPath $uiLogPath -SmokeTest 2>&1
        $exitCode = $LASTEXITCODE
        $text = ((@($output) -join [Environment]::NewLine)).Trim()

        $exitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($text)) | Should Be $false

        $result = $text | ConvertFrom-Json -ErrorAction Stop
        (@($result.pages) -contains 'welcome') | Should Be $true
        (@($result.languages) -contains 'pt-BR') | Should Be $true
        $result.statePath | Should Be $uiStatePath
        (Test-Path $uiStatePath) | Should Be $true
    }

    It 'keeps the embedded XAML parseable' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $match = [regex]::Match($raw, '(?s)\[xml\]\$xaml = @''\r?\n(.*?)\r?\n''@')

        $match.Success | Should Be $true
        { [xml]$null = $match.Groups[1].Value } | Should Not Throw
    }

    It 'runs the batch launcher smoke test without stderr noise' {
        $stdoutPath = Join-Path $script:TestDataRoot 'stdout.txt'
        $stderrPath = Join-Path $script:TestDataRoot 'stderr.txt'
        $command = ('.\bootstrap-ui.bat -SmokeTest 1> "{0}" 2> "{1}"' -f $stdoutPath, $stderrPath)

        $null = New-Item -Path $script:TestDataRoot -ItemType Directory -Force

        Push-Location $repoRoot
        try {
            & cmd /c $command | Out-Null
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $exitCode | Should Be 0

        $stdout = ''
        if (Test-Path $stdoutPath) {
            $stdout = (Get-Content -Path $stdoutPath -Raw)
        }

        $stderr = ''
        if (Test-Path $stderrPath) {
            $stderr = (Get-Content -Path $stderrPath -Raw)
        }

        $stdout | Should Match '"pages"'
        ([string]::IsNullOrWhiteSpace($stderr)) | Should Be $true
    }
}
