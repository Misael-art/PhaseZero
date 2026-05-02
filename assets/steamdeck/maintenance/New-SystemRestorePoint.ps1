$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    Checkpoint-Computer -Description 'Z Bootstrap manual checkpoint' -RestorePointType 'MODIFY_SETTINGS' | Out-Null
    [ordered]@{ status = 'applied'; action = 'new-system-restore-point'; description = 'Z Bootstrap manual checkpoint' } | ConvertTo-Json -Depth 6
} catch {
    throw "Falha ao criar ponto de restauração: $($_.Exception.Message)"
}
