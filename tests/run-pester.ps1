param(
    [string]$Path = (Join-Path $PSScriptRoot '*.tests.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module Pester -RequiredVersion 3.4.0

$result = Invoke-Pester -Path $Path -PassThru
$passed = [int]$result.PassedCount
$failed = [int]$result.FailedCount
$skipped = [int]$result.SkippedCount
$total = [int]$result.TotalCount

Write-Host ("Pester summary: Passed={0} Failed={1} Skipped={2} Total={3}" -f $passed, $failed, $skipped, $total)

$exitCode = if ($failed -gt 0) { 1 } else { 0 }
[Environment]::Exit($exitCode)
