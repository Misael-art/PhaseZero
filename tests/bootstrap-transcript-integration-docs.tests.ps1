$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

Describe 'Transcript integration documentation' {
    It 'ships a 58-title decision matrix with final destination action reason and risk' {
        $path = Join-Path $repoRoot 'docs\video-transcript-integration.md'

        Test-Path -LiteralPath $path | Should Be $true
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $raw | Should Match 'PhaseZero'
        $raw | Should Match '58 titulos'
        $raw | Should Match 'Destino final'
        $raw | Should Match 'GreenLuma'
        $raw | Should Match 'Descartado'
        $raw | Should Match 'llamacpp-mtp-template'
        $raw | Should Not Match 'TBD|TODO|A definir|Sem destino'

        $rows = @($raw -split '\r?\n' | Where-Object {
            $_ -match '^\|\s*\d+\s*\|' -and $_ -notmatch '^\|\s*#\s*\|'
        })
        $rows.Count | Should Be 58

        foreach ($row in $rows) {
            $cells = @($row.Trim('|') -split '\|')
            $cells.Count | Should BeGreaterThan 5
            foreach ($idx in 0..5) {
                ([string]::IsNullOrWhiteSpace([string]$cells[$idx])) | Should Be $false
            }
        }
    }
}
