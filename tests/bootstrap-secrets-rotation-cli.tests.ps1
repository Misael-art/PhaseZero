$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath
Reset-BootstrapFileCmdlets

function New-CliTestDataRoot {
    return (Join-Path $env:TEMP ("bootstrap_rotcli_{0}" -f ([Guid]::NewGuid().ToString('N'))))
}

Describe 'Rotate secrets CLI helpers' {
    BeforeEach {
        $script:CliDataRoot = New-CliTestDataRoot
        New-Item -ItemType Directory -Path $script:CliDataRoot -Force | Out-Null
        $env:BOOTSTRAP_DATA_ROOT = $script:CliDataRoot
        Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
    }

    AfterEach {
        if (Test-Path $script:CliDataRoot) {
            Remove-Item -LiteralPath $script:CliDataRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item Env:BOOTSTRAP_DATA_ROOT -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
    }

    Context 'stale provider detection' {
        It 'flags providers whose active credential has unknown validation' {
            $data = @{
                metadata = @{ version = 2 }
                providers = @{
                    openai = @{
                        defaults = @{ baseUrl = 'https://api.openai.com/v1' }
                        activeCredential = 'openai-only-01'
                        rotationOrder = @('openai-only-01')
                        credentials = @{
                            'openai-only-01' = @{
                                displayName = 'Only'
                                secret = 'sk-x'
                                secretKind = 'apiKey'
                                validation = @{ state = 'unknown'; checkedAt = ''; message = '' }
                            }
                        }
                    }
                }
                targets = @{}
            }
            $stale = Get-BootstrapRotationStaleProviders -SecretsData $data -StaleHours 24
            ($stale -contains 'openai') | Should Be $true
        }

        It 'flags providers whose passed validation is older than the cutoff' {
            $oldCheck = (Get-Date).ToUniversalTime().AddHours(-48).ToString('o')
            $data = @{
                metadata = @{ version = 2 }
                providers = @{
                    openai = @{
                        defaults = @{ baseUrl = 'https://api.openai.com/v1' }
                        activeCredential = 'openai-only-01'
                        rotationOrder = @('openai-only-01')
                        credentials = @{
                            'openai-only-01' = @{
                                displayName = 'Only'
                                secret = 'sk-x'
                                secretKind = 'apiKey'
                                validation = @{ state = 'passed'; checkedAt = $oldCheck; message = 'ok' }
                            }
                        }
                    }
                }
                targets = @{}
            }
            $stale = Get-BootstrapRotationStaleProviders -SecretsData $data -StaleHours 24
            ($stale -contains 'openai') | Should Be $true
        }

        It 'does NOT flag providers with recent passed validation' {
            $recentCheck = (Get-Date).ToUniversalTime().ToString('o')
            $data = @{
                metadata = @{ version = 2 }
                providers = @{
                    openai = @{
                        defaults = @{ baseUrl = 'https://api.openai.com/v1' }
                        activeCredential = 'openai-only-01'
                        rotationOrder = @('openai-only-01')
                        credentials = @{
                            'openai-only-01' = @{
                                displayName = 'Only'
                                secret = 'sk-x'
                                secretKind = 'apiKey'
                                validation = @{ state = 'passed'; checkedAt = $recentCheck; message = 'ok' }
                            }
                        }
                    }
                }
                targets = @{}
            }
            $stale = Get-BootstrapRotationStaleProviders -SecretsData $data -StaleHours 24
            ($stale -contains 'openai') | Should Be $false
        }
    }

    Context 'scheduled task management (dry-run only — does not touch host)' {
        It 'reports would-register for daily schedule in dry-run' {
            $result = Register-BootstrapRotationScheduledTask -Schedule 'daily' -DryRun
            $result.status | Should Be 'would-register'
            $result.schedule | Should Be 'daily'
            $result.taskName | Should Match 'PhaseZero'
        }

        It 'reports would-remove for none in dry-run' {
            $result = Register-BootstrapRotationScheduledTask -Schedule 'none' -DryRun
            $result.status | Should Be 'would-remove'
        }
    }

    Context 'rotate mode end-to-end (dry-run)' {
        It 'enqueues a stale provider and processes it in dry-run' {
            $manifestPath = Join-Path $script:CliDataRoot 'bootstrap-secrets.json'
            Write-BootstrapJsonFile -Path $manifestPath -Value @{
                metadata = @{ version = 2 }
                providers = @{
                    openai = @{
                        defaults = @{ baseUrl = 'https://api.openai.com/v1' }
                        activeCredential = 'openai-primary-01'
                        rotationOrder = @('openai-primary-01', 'openai-backup-01')
                        credentials = @{
                            'openai-primary-01' = @{
                                displayName = 'Primary'
                                secret = 'sk-old'
                                secretKind = 'apiKey'
                                validation = @{ state = 'failed'; checkedAt = ''; message = '401' }
                            }
                            'openai-backup-01' = @{
                                displayName = 'Backup'
                                secret = 'sk-new'
                                secretKind = 'apiKey'
                                validation = @{ state = 'unknown'; checkedAt = ''; message = '' }
                            }
                        }
                    }
                }
                targets = @{}
            }

            Mock Test-BootstrapSecretsProviderCredential {
                param([string]$ProviderName, [hashtable]$ProviderDefinition, [string]$CredentialId, [hashtable]$Credential, [int]$TimeoutSeconds = 15)
                if ($CredentialId -eq 'openai-backup-01') {
                    return @{ state = 'passed'; checkedAt = '2026-05-14T00:00:00Z'; message = 'ok' }
                }
                return @{ state = 'failed'; checkedAt = '2026-05-14T00:00:00Z'; message = '401' }
            }

            $result = Invoke-BootstrapRotateSecretsMode -Provider 'openai' -DryRun
            $result.enqueued.Count | Should Be 1
            $result.processedCount | Should Be 1
            $result.processed[0].state | Should Be 'settled'
            $result.processed[0].targetCredentialId | Should Be 'openai-backup-01'
        }
    }

    Context 'UI Contract exposes secretsRotation' {
        It 'includes schemaVersion and secretsRotation block' {
            $contract = Get-BootstrapUiContract
            $contract.schemaVersion | Should Be '1.4.0'
            $contract.secretsRotation | Should Not BeNullOrEmpty
            $contract.secretsRotation.scheduleOptions -contains 'daily' | Should Be $true
            $contract.secretsRotation.staleHoursDefault | Should Be 24
        }

        It 'exposes a non-empty eventsPath rooted in the data dir' {
            $contract = Get-BootstrapUiContract
            $contract.secretsRotation.eventsPath | Should Not BeNullOrEmpty
            ($contract.secretsRotation.eventsPath -match 'rotation-events\.jsonl$') | Should Be $true
        }
    }

    Context 'rotation events log rotation' {
        It 'caps the events file when crossing the 1000-line threshold' {
            $eventsPath = Join-Path $script:CliDataRoot 'rotation-events.jsonl'
            for ($i = 1; $i -le 1005; $i++) {
                Write-BootstrapRotationEvent -Name 'state-change' -Payload @{ idx = $i } -EventsPath $eventsPath
            }
            $lines = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8)
            ($lines.Count -le 1000) | Should Be $true
            ($lines.Count -ge 750) | Should Be $true
            ($lines[-1] -match '"idx":1005') | Should Be $true
        }
    }
}
