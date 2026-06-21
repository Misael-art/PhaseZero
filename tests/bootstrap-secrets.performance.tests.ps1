$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode
Reset-BootstrapFileCmdlets

Describe 'Bootstrap secrets performance' {
    It 'normalizes the default secrets template fast enough for UI refreshes' {
        $template = Get-BootstrapSecretsTemplate

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = Normalize-BootstrapSecretsData -Secrets $template
        $sw.Stop()

        $sw.ElapsedMilliseconds | Should BeLessThan 5000
    }
}
