$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath
Reset-BootstrapFileCmdlets

function New-RotationTestDataRoot {
    return (Join-Path $env:TEMP ("bootstrap_rotation_{0}" -f ([Guid]::NewGuid().ToString('N'))))
}

function Reset-RotationTestDataRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    $env:BOOTSTRAP_DATA_ROOT = $Path
    Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
}

function Remove-RotationTestDataRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-RotationSecretsManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Active = 'openai-primary-01',
        [string[]]$Order = @('openai-primary-01', 'openai-backup-01')
    )
    Write-BootstrapJsonFile -Path $Path -Value @{
        '$schema' = 'https://bootstrap.local/schemas/bootstrap-secrets.schema.json'
        metadata = @{ version = 2 }
        providers = @{
            openai = @{
                defaults = @{ baseUrl = 'https://api.openai.com/v1' }
                activeCredential = $Active
                rotationOrder = $Order
                credentials = @{
                    'openai-primary-01' = @{
                        displayName = 'Primary'
                        secret = 'sk-proj-old'
                        secretKind = 'apiKey'
                        validation = @{ state = 'unknown'; checkedAt = ''; message = '' }
                    }
                    'openai-backup-01' = @{
                        displayName = 'Backup'
                        secret = 'sk-proj-new'
                        secretKind = 'apiKey'
                        validation = @{ state = 'unknown'; checkedAt = ''; message = '' }
                    }
                }
            }
        }
        targets = @{
            userEnv = @{
                OPENAI_API_KEY = '{{activeProviders.openai.apiKey}}'
            }
        }
    }
}

Describe 'Secrets rotation worker' {
    BeforeEach {
        $script:RotationDataRoot = New-RotationTestDataRoot
        Reset-RotationTestDataRoot -Path $script:RotationDataRoot
        New-Item -ItemType Directory -Path $script:RotationDataRoot -Force | Out-Null
    }

    AfterEach {
        Remove-RotationTestDataRoot -Path $script:RotationDataRoot
        Remove-Item Env:BOOTSTRAP_DATA_ROOT -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
    }

    Context 'failure classification' {
        It 'classifies 401 as auth (terminal)' {
            Get-BootstrapSecretsValidationFailureCategory -Message 'The remote server returned an error: (401) Unauthorized.' | Should Be 'auth'
            Test-BootstrapSecretsRetryableFailure -Category 'auth' | Should Be $false
        }

        It 'classifies 503 as server (retryable)' {
            Get-BootstrapSecretsValidationFailureCategory -Message '503 Service Unavailable' | Should Be 'server'
            Test-BootstrapSecretsRetryableFailure -Category 'server' | Should Be $true
        }

        It 'classifies timeout as retryable' {
            Get-BootstrapSecretsValidationFailureCategory -Message 'The operation has timed out.' | Should Be 'timeout'
            Test-BootstrapSecretsRetryableFailure -Category 'timeout' | Should Be $true
        }

        It 'classifies rate-limit as retryable' {
            Get-BootstrapSecretsValidationFailureCategory -Message 'HTTP 429 quota exceeded' | Should Be 'rate-limit'
            Test-BootstrapSecretsRetryableFailure -Category 'rate-limit' | Should Be $true
        }
    }

    Context 'queue item lifecycle' {
        It 'creates a queue item with state queued' {
            $manifestPath = Join-Path $script:RotationDataRoot 'bootstrap-secrets.json'
            New-RotationSecretsManifest -Path $manifestPath
            $bundle = Get-BootstrapSecretsData
            $result = Add-BootstrapSecretRotationItem -SecretsData $bundle.Data -ProviderName 'openai' -Trigger 'cli'
            $result.Item.state | Should Be 'queued'
            $result.Item.provider | Should Be 'openai'
            $result.Item.previousActiveCredentialId | Should Be 'openai-primary-01'
            $result.Item.attempts | Should Be 0
            $queue = Get-BootstrapSecretRotationQueue -SecretsData $result.Data -ProviderName 'openai'
            $queue.Count | Should Be 1
        }

        It 'rejects unknown target credential' {
            $manifestPath = Join-Path $script:RotationDataRoot 'bootstrap-secrets.json'
            New-RotationSecretsManifest -Path $manifestPath
            $bundle = Get-BootstrapSecretsData
            { Add-BootstrapSecretRotationItem -SecretsData $bundle.Data -ProviderName 'openai' -TargetCredentialId 'does-not-exist' } | Should Throw 'Credencial desconhecida'
        }
    }

    Context 'happy path' {
        It 'rotates to next valid credential and reaches settled in dry-run' {
            $manifestPath = Join-Path $script:RotationDataRoot 'bootstrap-secrets.json'
            New-RotationSecretsManifest -Path $manifestPath

            Mock Test-BootstrapSecretsProviderCredential {
                param([string]$ProviderName, [hashtable]$ProviderDefinition, [string]$CredentialId, [hashtable]$Credential, [int]$TimeoutSeconds = 15)
                if ($CredentialId -eq 'openai-primary-01') {
                    return @{ state = 'failed'; checkedAt = '2026-05-14T00:00:00Z'; message = '401 Unauthorized' }
                }
                return @{ state = 'passed'; checkedAt = '2026-05-14T00:00:01Z'; message = 'ok' }
            }

            $bundle = Get-BootstrapSecretsData
            $added = Add-BootstrapSecretRotationItem -SecretsData $bundle.Data -ProviderName 'openai'
            Write-BootstrapJsonFile -Path $manifestPath -Value $added.Data

            $result = Invoke-BootstrapSecretRotation -ProviderName 'openai' -DryRun
            $result.Processed.Count | Should Be 1
            $result.Processed[0].state | Should Be 'settled'
            $result.Processed[0].targetCredentialId | Should Be 'openai-backup-01'
        }
    }

    Context 'auth failure is terminal' {
        It 'marks item failed without retry when only candidate returns 401' {
            $manifestPath = Join-Path $script:RotationDataRoot 'bootstrap-secrets.json'
            Write-BootstrapJsonFile -Path $manifestPath -Value @{
                metadata = @{ version = 2 }
                providers = @{
                    openai = @{
                        defaults = @{ baseUrl = 'https://api.openai.com/v1' }
                        activeCredential = 'openai-only-01'
                        rotationOrder = @('openai-only-01')
                        credentials = @{
                            'openai-only-01' = @{
                                displayName = 'Only'
                                secret = 'sk-proj-bad'
                                secretKind = 'apiKey'
                                validation = @{ state = 'unknown'; checkedAt = ''; message = '' }
                            }
                        }
                    }
                }
                targets = @{}
            }

            Mock Test-BootstrapSecretsProviderCredential {
                return @{ state = 'failed'; checkedAt = '2026-05-14T00:00:00Z'; message = '401 Unauthorized' }
            }

            $bundle = Get-BootstrapSecretsData
            $added = Add-BootstrapSecretRotationItem -SecretsData $bundle.Data -ProviderName 'openai' -TargetCredentialId 'openai-only-01'
            Write-BootstrapJsonFile -Path $manifestPath -Value $added.Data

            $result = Invoke-BootstrapSecretRotation -ProviderName 'openai' -DryRun
            $result.Processed[0].state | Should Be 'failed'
        }
    }

    Context 'timeout' {
        It 'honors total timeout and marks failed when deadline elapses mid-validation' {
            $manifestPath = Join-Path $script:RotationDataRoot 'bootstrap-secrets.json'
            New-RotationSecretsManifest -Path $manifestPath

            # Simula falha retryavel para forcar backoff e exceder o deadline.
            Mock Test-BootstrapSecretsProviderCredential {
                return @{ state = 'failed'; checkedAt = '2026-05-14T00:00:00Z'; message = '503 Service Unavailable' }
            }

            $bundle = Get-BootstrapSecretsData
            $added = Add-BootstrapSecretRotationItem -SecretsData $bundle.Data -ProviderName 'openai' -MaxAttempts 5 -TimeoutSecondsTotal 1
            Write-BootstrapJsonFile -Path $manifestPath -Value $added.Data

            $result = Invoke-BootstrapSecretRotation -ProviderName 'openai' -DryRun -TimeoutSeconds 2
            $result.Processed[0].state | Should Be 'failed'
            ($result.Processed[0].lastError -match 'timeout|tentativas') | Should Be $true
        }
    }

    Context 'file lock' {
        It 'releases the lock after a successful run' {
            $manifestPath = Join-Path $script:RotationDataRoot 'bootstrap-secrets.json'
            New-RotationSecretsManifest -Path $manifestPath

            Mock Test-BootstrapSecretsProviderCredential {
                return @{ state = 'passed'; checkedAt = '2026-05-14T00:00:00Z'; message = 'ok' }
            }

            $bundle = Get-BootstrapSecretsData
            $added = Add-BootstrapSecretRotationItem -SecretsData $bundle.Data -ProviderName 'openai'
            Write-BootstrapJsonFile -Path $manifestPath -Value $added.Data

            Invoke-BootstrapSecretRotation -ProviderName 'openai' -DryRun | Out-Null
            $lockPath = "$manifestPath.lock"
            Test-Path $lockPath | Should Be $false
        }

        It 'throws RotationConcurrencyError when lock cannot be acquired' {
            $manifestPath = Join-Path $script:RotationDataRoot 'bootstrap-secrets.json'
            New-RotationSecretsManifest -Path $manifestPath

            $heldLock = Lock-BootstrapSecretsFile -Path $manifestPath -TimeoutSeconds 1
            try {
                { Invoke-BootstrapSecretRotation -ProviderName 'openai' -DryRun } | Should Throw 'RotationConcurrencyError'
            } finally {
                Unlock-BootstrapSecretsFile -Stream $heldLock -Path $manifestPath
            }
        }
    }

    Context 'events sink' {
        It 'writes JSONL events when rotating' {
            $manifestPath = Join-Path $script:RotationDataRoot 'bootstrap-secrets.json'
            New-RotationSecretsManifest -Path $manifestPath

            Mock Test-BootstrapSecretsProviderCredential {
                param([string]$ProviderName, [hashtable]$ProviderDefinition, [string]$CredentialId, [hashtable]$Credential, [int]$TimeoutSeconds = 15)
                if ($CredentialId -eq 'openai-primary-01') {
                    return @{ state = 'failed'; checkedAt = '2026-05-14T00:00:00Z'; message = '401 Unauthorized' }
                }
                return @{ state = 'passed'; checkedAt = '2026-05-14T00:00:01Z'; message = 'ok' }
            }

            $bundle = Get-BootstrapSecretsData
            $added = Add-BootstrapSecretRotationItem -SecretsData $bundle.Data -ProviderName 'openai'
            Write-BootstrapJsonFile -Path $manifestPath -Value $added.Data

            Invoke-BootstrapSecretRotation -ProviderName 'openai' -DryRun | Out-Null

            $eventsPath = Join-Path $script:RotationDataRoot 'rotation-events.jsonl'
            Test-Path $eventsPath | Should Be $true
            $lines = Get-Content -LiteralPath $eventsPath -Encoding UTF8
            $lines.Count | Should BeGreaterThan 0
            ($lines -join "`n").Contains('validation-result') | Should Be $true
        }
    }

    Context 'compatibility wrapper' {
        It 'Move-BootstrapSecretsToNextCredential still rotates manually' {
            $data = @{
                metadata = @{ version = 2 }
                providers = @{
                    openai = @{
                        defaults = @{ baseUrl = 'https://api.openai.com/v1' }
                        activeCredential = 'openai-primary-01'
                        rotationOrder = @('openai-primary-01', 'openai-backup-01')
                        credentials = @{
                            'openai-primary-01' = @{
                                displayName = 'Primary'
                                secret = 'sk-proj-bad'
                                secretKind = 'apiKey'
                                validation = @{ state = 'unknown'; checkedAt = ''; message = '' }
                            }
                            'openai-backup-01' = @{
                                displayName = 'Backup'
                                secret = 'sk-proj-good'
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
                if ($CredentialId -eq 'openai-primary-01') {
                    return @{ state = 'failed'; checkedAt = '2026-05-14T00:00:00Z'; message = 'quota exceeded' }
                }
                return @{ state = 'passed'; checkedAt = '2026-05-14T00:00:01Z'; message = 'ok' }
            }

            $rotated = Move-BootstrapSecretsToNextCredential -SecretsData $data -ProviderName 'openai'
            $rotated.providers.openai.activeCredential | Should Be 'openai-backup-01'
        }
    }
}
