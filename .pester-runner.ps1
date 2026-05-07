$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module Pester -RequiredVersion 3.4.0

$result = Invoke-Pester -Script .\tests -PassThru -Quiet

$summary = "Passed=$($result.PassedCount) Failed=$($result.FailedCount) Skipped=$($result.SkippedCount)"
Set-Content -Path .\pester-summary.txt -Value $summary -Encoding utf8

$lines = @()
foreach ($t in $result.TestResult) {
    if (-not $t.Passed) {
        $lines += "FAIL: [$($t.Describe)] [$($t.Context)] $($t.Name)"
        $lines += "  Msg: $($t.FailureMessage)"
        if ($t.StackTrace) { $lines += "  Stack: $($t.StackTrace -split [Environment]::NewLine | Select-Object -First 3 -join '|')" }
    }
}
Set-Content -Path .\pester-failures.txt -Value $lines -Encoding utf8
Write-Host $summary
exit $result.FailedCount
