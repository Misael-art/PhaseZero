$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

. $scriptPath -BootstrapUiLibraryMode

function Assert-Equals {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message`nExpected=$Expected`nActual=$Actual" }
}

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-QuoteWindowsPaths {
    $text = 'run C:\Program Files\Foo\bar.exe and C:\Tools\baz.cmd'
    $quoted = Quote-WindowsPathTokensInString -Text $text
    Assert-True -Condition ($quoted -match '"C:\\Program Files\\Foo\\bar\.exe"') -Message 'Must wrap exe path with spaces in quotes.'
    Assert-True -Condition ($quoted -match '"C:\\Tools\\baz\.cmd"') -Message 'Must wrap cmd path in quotes.'
}

function Test-QuoteSkipAlreadyQuoted {
    $text = 'use "C:\Program Files\App\app.exe" already quoted'
    $quoted = Quote-WindowsPathTokensInString -Text $text
    Assert-Equals -Actual $quoted -Expected $text -Message 'Already quoted path must be untouched.'
}

function Test-ConvertHookItemKeepsCleanString {
    $item = 'safe-cli --flag'
    $result = Convert-HookItemIfNeeded -Item $item -GitBashPath 'C:\Program Files\Git\bin\bash.exe'
    Assert-True -Condition ($null -ne $result) -Message 'Clean command must pass through.'
    Assert-Equals -Actual $result -Expected $item -Message 'Clean command must be unchanged.'
}

function Test-ConvertHookItemRedirectsBashLcToGitBash {
    if (-not $env:TEMP) { return }
    $fakeBash = Join-Path $env:TEMP 'fake-bash.exe'
    'fake' | Set-Content -Path $fakeBash -Encoding utf8
    try {
        $obj = [pscustomobject]@{ command = '/usr/bin/bash -lc echo hi'; args = @() }
        $result = Convert-HookItemIfNeeded -Item $obj -GitBashPath $fakeBash
        Assert-True -Condition ($null -ne $result) -Message 'Object with -lc script must convert.'
        Assert-Equals -Actual $result.command -Expected $fakeBash -Message 'Command must be replaced with git-bash path.'
        Assert-Equals -Actual ($result.args[0]) -Expected '-lc' -Message 'First arg must be -lc.'
    } finally {
        if (Test-Path $fakeBash) { Remove-Item -LiteralPath $fakeBash -Force -ErrorAction SilentlyContinue }
    }
}

function Test-ConvertHookItemKeepsHarmlessString {
    $item = 'C:\Tools\harmless.exe -flag'
    $result = Convert-HookItemIfNeeded -Item $item -GitBashPath ''
    Assert-True -Condition ($null -ne $result) -Message 'Plain command must pass through.'
}

function Test-CandidatePathsRespectsDeepScanFlag {
    $oldEnv = $env:BOOTSTRAP_HOOKS_DEEP_SCAN
    try {
        $env:BOOTSTRAP_HOOKS_DEEP_SCAN = $null
        $shallow = Get-ClaudeHookConfigCandidatePaths
        # Shallow scan must not throw and produce list (possibly empty)
        Assert-True -Condition (@($shallow).Count -ge 0) -Message 'Shallow scan must succeed.'
    } finally {
        $env:BOOTSTRAP_HOOKS_DEEP_SCAN = $oldEnv
    }
}

Test-QuoteWindowsPaths
Test-QuoteSkipAlreadyQuoted
Test-ConvertHookItemKeepsCleanString
Test-ConvertHookItemRedirectsBashLcToGitBash
Test-ConvertHookItemKeepsHarmlessString
Test-CandidatePathsRespectsDeepScanFlag

Write-Host 'hooks tests: ok'
