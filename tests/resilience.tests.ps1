$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

Describe 'Resilience Architecture' {
    BeforeAll {
        . $scriptPath -BootstrapUiLibraryMode
    }

    Context 'Disk Space Check' {
        It 'Get-BootstrapFreeSpace returns a number' {
            $space = Get-BootstrapFreeSpace -Path 'C:\'
            $space | Should BeGreaterThan -1
        }

        It 'Test-BootstrapDiskSpace logs warnings if space is low (Mocked)' {
            Mock Get-BootstrapFreeSpace { return 0.5 } # 0.5 GB
            Mock Write-Log

            $selection = @{ Profiles = @('full') }
            $components = @('c1', 'c2')

            try {
                Test-BootstrapDiskSpace -Selection $selection -ResolvedComponents $components -ResolvedWorkspaceRoot 'C:\'
            } catch { }

            Assert-MockCalled Write-Log -ParameterFilter { $Message -match 'Espaco em disco insuficiente' -and $Level -eq 'WARN' }
        }

        It 'Assert-BootstrapDiskSpace throws if space is low' {
            Mock Get-BootstrapFreeSpace { return 0.5 } # 0.5 GB
            { Assert-BootstrapDiskSpace -RequiredGB 1.0 } | Should Throw 'Espaco em disco insuficiente'
        }

        It 'Assert-BootstrapDiskSpace passes if space is enough' {
            Mock Get-BootstrapFreeSpace { return 5.0 }
            { Assert-BootstrapDiskSpace -RequiredGB 1.0 } | Should Not Throw
        }
    }

    Context 'Checkpoint & Resume' {
        It 'Save and Load checkpoint' {
            $selection = @{ Profiles = @('base'); Components = @() }
            $completed = @('system-core', 'git-core')
            $tuning = @(@{ id = 'test-tune'; status = 'applied' })

            Save-BootstrapCheckpoint -Selection $selection -CompletedComponents $completed -AppTuningResults $tuning

            $loaded = Load-BootstrapCheckpoint
            $loaded.ProfileSelection | Should Be @('base')
            $loaded.CompletedComponents | Should Be @('system-core', 'git-core')
            $loaded.AppTuningResults[0].id | Should Be 'test-tune'

            # Cleanup
            Remove-Item (Get-BootstrapCheckpointPath) -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Offline Mode & Cache' {
        It 'Invoke-WebRequestWithRetry uses cache if available' {
            $tempDir = Join-Path $env:TEMP ('bootstrap-test-' + (New-Guid).ToString())
            $null = New-Item -Path $tempDir -ItemType Directory -Force
            $cacheDir = Join-Path $tempDir 'cache'
            $null = New-Item -Path $cacheDir -ItemType Directory -Force

            $script:CacheDir = $cacheDir
            $script:Offline = $true

            $testFile = Join-Path $cacheDir 'out.txt'
            'hello' | Set-Content -Path $testFile

            $outFile = Join-Path $tempDir 'out.txt'

            # Should NOT throw because it's in cache
            Invoke-WebRequestWithRetry -Uri 'http://dummy' -OutFile $outFile

            Get-Content $outFile | Should Be 'hello'

            # Should throw if NOT in cache
            { Invoke-WebRequestWithRetry -Uri 'http://dummy2' -OutFile (Join-Path $tempDir 'missing.txt') } | Should Throw

            # Cleanup
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            $script:CacheDir = ''
            $script:Offline = $false
        }
    }

    Context 'Rollback' {
        It 'Registers changes and rolls them back' {
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'C:\'
            Mock Remove-ItemProperty
            Mock Set-ItemProperty
            Mock Write-Log

            Register-BootstrapChange -State $state -Type 'Registry' -Target 'HKCU:\Test' -Name 'MyKey' -OldValue $null
            Register-BootstrapChange -State $state -Type 'Registry' -Target 'HKCU:\Test2' -Name 'MyKey2' -OldValue 'prev'

            $state.Changes.Count | Should Be 2

            Invoke-BootstrapAutoRollback -State $state

            Assert-MockCalled Remove-ItemProperty -ParameterFilter { $Path -eq 'HKCU:\Test' -and $Name -eq 'MyKey' }
            Assert-MockCalled Set-ItemProperty -ParameterFilter { $Path -eq 'HKCU:\Test2' -and $Name -eq 'MyKey2' -and $Value -eq 'prev' }
        }
    }

    Context 'Audit & Repair' {
        It 'Invoke-BootstrapAuditMode performs repair' {
            $catalog = @{
                'broken-comp' = [pscustomobject]@{
                    Name = 'broken-comp'
                    Data = @{ CommandName = 'non-existent-cmd' }
                    VersionCheckCommand = ''
                }
            }
            $resolution = @{
                ResolvedComponents = @('broken-comp')
                Catalog = $catalog
            }
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'C:\'

            Mock Invoke-BootstrapComponent {
                param($Name, $State)
                $State.Completed[$Name] = @{ Status = 'Repaired' }
            }

            $results = Invoke-BootstrapAuditMode -Resolution $resolution -State $state -Repair
            $results[0].Status | Should Be 'Repaired'
            Assert-MockCalled Invoke-BootstrapComponent
        }
    }
}
