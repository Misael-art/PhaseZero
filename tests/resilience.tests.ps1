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

        It 'writes a change manifest with auditable rollback metadata' {
            $tempDir = Join-Path $env:TEMP ('bootstrap-manifest-test-' + (New-Guid).ToString())
            $null = New-Item -Path $tempDir -ItemType Directory -Force
            try {
                $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'C:\'
                $state.ChangeManifestPath = Join-Path $tempDir 'changes.json'
                $state.CurrentComponent = 'test-component'

                Register-BootstrapChange -State $state -Type 'EnvVar' -Target 'PHASEZERO_TEST' -OldValue 'old' -NewValue 'new'

                Test-Path $state.ChangeManifestPath | Should Be $true
                $manifest = Get-Content -Path $state.ChangeManifestPath -Raw | ConvertFrom-Json
                $manifest.summary.total | Should Be 1
                $manifest.changes[0].Component | Should Be 'test-component'
                $manifest.changes[0].RollbackAction | Should Be 'restore-env-var'
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'rolls back registry values from a manifest before legacy fallback' {
            $tempDir = Join-Path $env:TEMP ('bootstrap-rollback-test-' + (New-Guid).ToString())
            $null = New-Item -Path $tempDir -ItemType Directory -Force
            $manifestPath = Join-Path $tempDir 'changes.json'
            try {
                $manifest = [ordered]@{
                    changes = @(
                        [ordered]@{ Type = 'Registry'; Target = 'HKCU:\PhaseZeroTest'; Name = 'Value'; OldValue = 'old'; Reversible = 'partial' }
                    )
                }
                $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding utf8
                Mock Set-ItemProperty
                Mock Write-Log

                Invoke-BootstrapRollback -ChangesPath $manifestPath

                Assert-MockCalled Set-ItemProperty -ParameterFilter { $Path -eq 'HKCU:\PhaseZeroTest' -and $Name -eq 'Value' -and $Value -eq 'old' }
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Reversibility Contract' {
        It 'infers package and manual reversibility metadata' {
            $winget = [pscustomobject]@{ Kind = 'winget'; Name = 'git-core' }
            $manual = [pscustomobject]@{ Kind = 'manual-required'; Name = 'steamdeck-manual' }

            (@((Get-BootstrapComponentReversibility -ComponentDef $winget).changeTypes) -contains 'package') | Should Be $true
            (Get-BootstrapComponentReversibility -ComponentDef $manual).reversible | Should Be 'none'
        }
    }

    Context 'Audit & Repair' {
        It 'Invoke-BootstrapAuditMode performs repair' {
            $catalog = @{
                'broken-comp' = [pscustomobject]@{
                    Name = 'broken-comp'
                    Description = 'Broken test component'
                    Kind = 'test'
                    DependsOn = @()
                    Data = @{ CommandName = 'non-existent-cmd' }
                    VersionCheckCommand = ''
                }
            }
            $resolution = @{
                ResolvedComponents = @('broken-comp')
                Catalog = $catalog
            }
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'C:\'

            Mock Get-BootstrapComponentCatalog { $catalog }
            Mock Invoke-BootstrapComponent {
                param($Name, $State)
                $State.Completed[$Name] = @{ Status = 'Repaired' }
            }

            $results = Invoke-BootstrapAuditMode -Resolution $resolution -State $state -Repair
            $results[0].Status | Should Be 'Repaired'
            Assert-MockCalled Invoke-BootstrapComponent
        }
    }

    Context 'AppTuning log lines (StrictMode safe)' {
        It 'materializes empty AppTuning filter lists without null.Count' {
            $selection = [pscustomobject]@{
                AppTuningCategories    = @()
                AppTuningItems         = @()
                ExcludedAppTuningItems = @()
            }
            $reqItems = @(
                foreach ($it in @($selection.AppTuningItems)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$it)) { [string]$it }
                }
            )
            ($null -eq $reqItems) | Should Be $false
            $reqItems.Length | Should Be 0

            $plan = [ordered]@{ items = @() }
            $planItemIds = @(
                foreach ($planItem in @($plan.items)) {
                    $planItemId = [string]$planItem.id
                    if (-not [string]::IsNullOrWhiteSpace($planItemId)) { $planItemId }
                }
            )
            $planItemIds.Length | Should Be 0
        }

        It 'DryRun notepadpp with custom AppTuning logs param lines without throwing' {
            $log = Join-Path $env:TEMP ("bt-apptun-{0}.log" -f ([Guid]::NewGuid().ToString('N')))
            $res = Join-Path $env:TEMP ("bt-apptun-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $res -Force -ErrorAction SilentlyContinue
            $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $invokeArgs = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
                '-NonInteractive', '-DryRun', '-LogPath', $log, '-ResultPath', $res,
                '-Component', 'notepadpp', '-AppTuning', 'custom'
            )
            $proc = Start-Process -FilePath $pwsh -ArgumentList $invokeArgs -Wait -PassThru -NoNewWindow
            $proc.ExitCode | Should Be 0
            $raw = Get-Content -LiteralPath $log -Raw -ErrorAction Stop
            $raw | Should Match 'AppTuning itens \(param\):'
            $raw | Should Match 'AppTuning plano:'
            Remove-Item -LiteralPath $log, $res -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Git path resolution e Join-Path (repo-clone)' {
        It 'Set-UserEnvVar normaliza Value em colecao para o primeiro elemento nao vazio' {
            Mock Write-Log
            $name = 'PHASEZERO_MULTI_SETUSERTEST'
            $oldUser = [Environment]::GetEnvironmentVariable($name, 'User')
            $oldProc = [Environment]::GetEnvironmentVariable($name, 'Process')
            try {
                [Environment]::SetEnvironmentVariable($name, $null, 'User')
                [Environment]::SetEnvironmentVariable($name, $null, 'Process')
                Set-UserEnvVar -Name $name -Value @('  primeiro  ', 'segundo')
                [Environment]::GetEnvironmentVariable($name, 'User') | Should Be 'primeiro'
            } finally {
                if ($null -ne $oldUser) { [Environment]::SetEnvironmentVariable($name, $oldUser, 'User') } else { [Environment]::SetEnvironmentVariable($name, $null, 'User') }
                if ($null -ne $oldProc) { [Environment]::SetEnvironmentVariable($name, $oldProc, 'Process') } else { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
            }
        }

        It 'Get-GitBashExe retorna um FullName quando variavel User tem wildcard e varios ficheiros' {
            $td = Join-Path $env:TEMP ("pz-gitbash-wc-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $td -Force
            $oldUser = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
            try {
                'stub' | Out-File -FilePath (Join-Path $td 'bash1.exe') -Encoding ascii
                'stub' | Out-File -FilePath (Join-Path $td 'bash2.exe') -Encoding ascii
                $pat = Join-Path $td 'bash?.exe'
                [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $pat, 'User')
                $r = Get-GitBashExe
                @($r).Count | Should Be 1
                [string]$r | Should Match 'bash[12]\.exe$'
            } finally {
                if ($null -ne $oldUser) { [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $oldUser, 'User') } else { [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $null, 'User') }
                Remove-Item -LiteralPath $td -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Invoke-BootstrapComponent repo-clone falha se TargetName for colecao com mais de um valor' {
            Mock Write-Log
            Mock Ensure-BootstrapGitCore { }
            Mock Ensure-RepoClone { }
            $bad = New-BootstrapComponentDefinition -Name 'bad-repo' -Description 'test' -Kind 'repo-clone' -Optional $false -DependsOn @() -Data @{ RepoUrl = 'https://example.com/x.git'; TargetName = @('a', 'b') }
            $catalog = @{ 'bad-repo' = $bad }
            Mock Get-BootstrapComponentCatalog { $catalog }
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'D:\clones'
            $state.GitInfo = @{ Git = 'C:\Program Files\Git\cmd\git.exe'; Bash = 'C:\Program Files\Git\bin\bash.exe' }
            { Invoke-BootstrapComponent -Name 'bad-repo' -State $state } | Should Throw 'TargetName deve ser uma unica string'
        }

        It 'Invoke-BootstrapComponent repo-clone usa primeiro TargetName quando e array de um elemento' {
            Mock Write-Log
            Mock Ensure-BootstrapGitCore { }
            $captured = $null
            Mock Ensure-RepoClone {
                param($GitExe, $RepoUrl, $TargetDir)
                $script:capturedRepoCloneTarget = $TargetDir
            }
            $one = New-BootstrapComponentDefinition -Name 'one-repo' -Description 'test' -Kind 'repo-clone' -Optional $false -DependsOn @() -Data @{ RepoUrl = 'https://example.com/x.git'; TargetName = @('onlyname') }
            $catalog = @{ 'one-repo' = $one }
            Mock Get-BootstrapComponentCatalog { $catalog }
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'D:\clones'
            $state.GitInfo = @{ Git = 'C:\Program Files\Git\cmd\git.exe'; Bash = 'C:\Program Files\Git\bin\bash.exe' }
            Invoke-BootstrapComponent -Name 'one-repo' -State $state
            $script:capturedRepoCloneTarget | Should Be (Join-Path 'D:\clones' 'onlyname')
        }
    }

    Context 'Invoke-NativeFirstLine ps1' {
        It 'executa .ps1 via powershell -File em vez de cmd (evita dialogo Abrir com)' {
            $tmp = Join-Path $env:TEMP ("pz-nfl-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
            'Write-Output "hello-from-nfl-test"' | Set-Content -Path $tmp -Encoding utf8
            try {
                $line = Invoke-NativeFirstLine -Exe $tmp -Args @()
                [string]$line | Should Match 'hello-from-nfl-test'
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Test-BootstrapDotNetSdkListHasEntry' {
        It 'retorna true quando ha linha major.minor.patch' {
            $out = @"
8.0.416 [C:\Program Files\dotnet\sdk]
6.0.428 [C:\Program Files\dotnet\sdk]
"@
            Test-BootstrapDotNetSdkListHasEntry -ListSdksOutput $out | Should Be $true
        }

        It 'retorna false quando vazio ou so espacos' {
            Test-BootstrapDotNetSdkListHasEntry -ListSdksOutput '' | Should Be $false
            Test-BootstrapDotNetSdkListHasEntry -ListSdksOutput "   `n  " | Should Be $false
        }

        It 'retorna false quando saida sem versao SDK (mensagens apenas)' {
            $out = @'
Welcome to .NET 8.0!
---------------------
'@
            Test-BootstrapDotNetSdkListHasEntry -ListSdksOutput $out | Should Be $false
        }
    }

    Context 'Normalize-BootstrapPathSegment' {
        It 'retorna primeiro elemento quando valor e colecao' {
            Normalize-BootstrapPathSegment -Value @('C:\primeiro', 'C:\segundo') | Should Be 'C:\primeiro'
        }

        It 'retorna string vazia para null' {
            Normalize-BootstrapPathSegment -Value $null | Should Be ''
        }
    }

    Context 'Get-BootstrapChangeManifestPath com RunId colecao' {
        It 'normaliza RunId para primeiro segmento e gera um unico ficheiro changes.json' {
            Mock Get-BootstrapDataRoot { return 'D:\fakeDataRoot' }
            $st = @{
                RunId              = @('runA', 'runB')
                ChangeManifestPath = ''
                Changes            = (New-Object 'System.Collections.Generic.List[object]')
            }
            $p = Get-BootstrapChangeManifestPath -State $st
            $p | Should Be 'D:\fakeDataRoot\runs\runA\changes.json'
            $st.ChangeManifestPath | Should Be 'D:\fakeDataRoot\runs\runA\changes.json'
        }
    }

    Context 'Test-BootstrapDotNetSdkListHasMajorBand' {
        It 'retorna true quando existe SDK 8.x' {
            $out = "6.0.428 [C:\sdk]`n8.0.416 [C:\sdk]"
            Test-BootstrapDotNetSdkListHasMajorBand -ListSdksOutput $out -Major 8 | Should Be $true
        }

        It 'retorna false quando so SDK 6' {
            $out = "6.0.428 [C:\Program Files\dotnet\sdk]"
            Test-BootstrapDotNetSdkListHasMajorBand -ListSdksOutput $out -Major 8 | Should Be $false
        }
    }

    Context 'Winget list probe (Invoke-WingetListIdProbe)' {
        It 'Invoke-WingetListIdProbe le stdout/stderr apos Start-Process com redirecionamento (Start-Process mock)' {
            Mock Start-Process {
                param(
                    [string]$FilePath,
                    [string[]]$ArgumentList,
                    [string]$RedirectStandardOutput,
                    [string]$RedirectStandardError
                )
                if (-not [string]::IsNullOrWhiteSpace($RedirectStandardOutput)) {
                    [System.IO.File]::WriteAllText($RedirectStandardOutput, "Nome Id Versao`nPkg Microsoft.WindowsTerminal 1.0 winget")
                }
                if (-not [string]::IsNullOrWhiteSpace($RedirectStandardError)) {
                    [System.IO.File]::WriteAllText($RedirectStandardError, '')
                }
                $fake = New-Object psobject -Property @{ Id = 424242; ExitCode = 0 }
                $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param([int]$milliseconds = 0) $true } -Force
                return $fake
            }
            $cap = Invoke-WingetListIdProbe -WingetPath 'C:\Fake\winget.exe' -Id 'Microsoft.WindowsTerminal' -TimeoutMs 5000
            $cap.timedOut | Should Be $false
            $cap.exitCode | Should Be 0
            $cap.stdout | Should Match 'Microsoft\.WindowsTerminal'
            Assert-MockCalled Start-Process -Times 1 -Exactly
        }

        It 'Test-WingetPackageInstalled com exit -1978335212 regista INFO e nao WARN de assume-se nao instalado' {
            Mock Invoke-WingetListIdProbe {
                return [ordered]@{
                    exitCode = -1978335212
                    timedOut = $false
                    stdout   = ''
                    stderr   = ''
                }
            }
            Mock Write-Log
            $r = Test-WingetPackageInstalled -WingetPath 'C:\Windows\System32\cmd.exe' -Id 'OpenJS.NodeJS.LTS'
            $r | Should Be $false
            Assert-MockCalled Write-Log -ParameterFilter { $Message -match 'NO_APPLICATIONS_FOUND' } -Times 1 -Exactly
            Assert-MockCalled Write-Log -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'assume-se nao instalado' } -Times 0 -Exactly
        }

        It 'Test-WingetPackageInstalled nao chama Invoke-NativeCaptureWithLog' {
            Mock Invoke-NativeCaptureWithLog { throw 'Invoke-NativeCaptureWithLog nao deve ser usado para winget list' }
            Mock Invoke-WingetListIdProbe {
                return [ordered]@{
                    exitCode = -1978335212
                    timedOut = $false
                    stdout   = ''
                    stderr   = ''
                }
            }
            Mock Write-Log
            { Test-WingetPackageInstalled -WingetPath 'C:\Windows\System32\cmd.exe' -Id 'X.Y.Z' } | Should Not Throw
            Assert-MockCalled Invoke-NativeCaptureWithLog -Times 0 -Exactly
        }
    }

    Context 'Winget install modo silencioso preferencial' {
        It 'Ensure-WingetPackage tenta --silent primeiro e faz fallback sem --silent' {
            Mock Test-WingetPackageInstalled { return $false }
            Mock Invoke-NativeWithRetry {
                param([string]$Exe, [string[]]$Args, [string]$OperationName)
                if ($OperationName -match '--silent') { return 1 }
                return 0
            }
            Mock Refresh-SessionPath { }
            Mock Write-Log { }

            { Ensure-WingetPackage -WingetPath 'C:\Fake\winget.exe' -Id 'Notepad++.Notepad++' -DisplayName 'Notepad++' -PreferUserScope $true -AllowFailureWhenNotAdmin $false } | Should Not Throw

            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Notepad++ via winget --scope user --silent' } -Times 1 -Exactly
            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Notepad++ via winget --scope user' } -Times 1 -Exactly
            Assert-MockCalled Refresh-SessionPath -Times 1 -Exactly
        }
    }

    Context 'Perfis e preflight manual/reboot' {
        It 'perfil base nao inclui google-app-desktop; utilities inclui' {
            $baseRes = Resolve-BootstrapComponents -SelectedProfiles @('base') -SelectedComponents @() -ExcludedComponents @()
            @($baseRes.ResolvedComponents) -contains 'google-app-desktop' | Should Be $false

            $utilRes = Resolve-BootstrapComponents -SelectedProfiles @('utilities') -SelectedComponents @() -ExcludedComponents @()
            @($utilRes.ResolvedComponents) -contains 'google-app-desktop' | Should Be $true
        }

        It 'Invoke-BootstrapExecutionPreflight falha com RequireNoPendingReboot quando ha reboot pendente' {
            $prev = $script:RequireNoPendingReboot
            $prevAllow = $script:AllowPendingReboot
            try {
                $script:RequireNoPendingReboot = $true
                $script:AllowPendingReboot = $false
                Mock Test-BootstrapDiskSpace { }
                Mock Get-BootstrapPreflightRequirements {
                    return [ordered]@{
                        RequiresNetwork = $false
                        RequiresWinget = $false
                        ConnectivityGroups = @()
                    }
                }
                Mock Get-BootstrapPendingRebootReasons { return @('WindowsUpdate') }
                $sel = New-BootstrapSelectionObject -SelectedProfiles @() -SelectedComponents @('system-core') -ExcludedComponents @()
                $state = New-BootstrapState -Selection $sel -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'C:\'
                { Invoke-BootstrapExecutionPreflight -State $state -ResolvedComponents @('system-core') } | Should Throw 'RequireNoPendingReboot'
            } finally {
                $script:RequireNoPendingReboot = $prev
                $script:AllowPendingReboot = $prevAllow
            }
        }
    }
    Context 'Winget ghost install handling' {
        It 'Ensure-WingetPackage detecta ghost install via ProbePaths' {
            Mock Test-WingetPackageInstalled { return $true }
            Mock Test-WingetProbePathsOnDisk { return $false }
            Mock Invoke-NativeWithRetry { return 0 }
            Mock Refresh-SessionPath {}
            Mock Write-Log {}

            # Nao deve lancar excecao
            { Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Test.Ghost' -DisplayName 'GhostPkg' -ProbePaths @('C:\fake\ghost.exe') } | Should Not Throw
        }
    }

    Context 'Invoke-NativeWithRetry soft-success exit codes' {
        It 'Exit code -1978335189 (UPDATE_NOT_APPLICABLE) curto-circuita retries' {
            Mock Invoke-NativeWithLog { return -1978335189 }
            Mock Write-Log {}
            $r = Invoke-NativeWithRetry -Exe 'fake.exe' -Args @('install') -OperationName 'pkg-test' -MaxAttempts 5 -InitialDelaySeconds 1 -SoftSuccessExitCodes $script:WingetSoftSuccessExitCodes
            $r | Should Be 0
            Assert-MockCalled Invoke-NativeWithLog -Times 1 -Exactly
        }

        It 'Sem SoftSuccessExitCodes, exit -1978335189 ainda dispara retries ate o limite' {
            Mock Invoke-NativeWithLog { return -1978335189 }
            Mock Write-Log {}
            Mock Start-Sleep {}
            $maxAttempts = 3
            $r = Invoke-NativeWithRetry -Exe 'fake.exe' -Args @('install-no-soft') -OperationName 'pkg-test-no-soft' -MaxAttempts $maxAttempts -InitialDelaySeconds 1
            $r | Should Be -1978335189
            # Filtro pelo arg unico deste teste para nao contar chamadas do It vizinho.
            Assert-MockCalled Invoke-NativeWithLog -ParameterFilter { $Args -contains 'install-no-soft' } -Times $maxAttempts -Exactly
        }

        It 'Test-WingetSoftSuccessExit reconhece todos os codigos catalogados' {
            Test-WingetSoftSuccessExit -ExitCode -1978335189 | Should Be $true
            Test-WingetSoftSuccessExit -ExitCode -1978335212 | Should Be $true
            Test-WingetSoftSuccessExit -ExitCode -1978335215 | Should Be $true
            Test-WingetSoftSuccessExit -ExitCode 0 | Should Be $false
            Test-WingetSoftSuccessExit -ExitCode -1 | Should Be $false
        }
    }

    Context 'Test-WingetListOutputContainsId parser' {
        It 'casa Id em linha tabular real' {
            $output = @'
Name              Id                   Version  Source
-----------------------------------------------------
Python 3.13       Python.Python.3.13   3.13.13  winget
'@
            Test-WingetListOutputContainsId -Output $output -Id 'Python.Python.3.13' | Should Be $true
        }

        It 'NAO casa Id quando aparece apenas em frase de log narrativa' {
            $output = 'Foi encontrado um pacote existente ja instalado. Tentando atualizar o pacote instalado...'
            Test-WingetListOutputContainsId -Output $output -Id 'Python.Python.3.13' | Should Be $false
        }

        It 'NAO casa Id quando saida vazia' {
            Test-WingetListOutputContainsId -Output '' -Id 'X.Y' | Should Be $false
        }

        It 'ignora linha de cabecalho mesmo se Id se repete depois' {
            $output = "Name  Id  Version`nFoo  X.Y  1.0"
            Test-WingetListOutputContainsId -Output $output -Id 'X.Y' | Should Be $true
        }
    }

    Context 'Test-WingetProbePathsOnDisk' {
        It 'retorna true quando algum probe path existe' {
            Mock Test-Path { param($LiteralPath) return ($LiteralPath -eq 'C:\real\bin.exe') }
            Test-WingetProbePathsOnDisk -ProbePaths @('C:\nope\bin.exe', 'C:\real\bin.exe') | Should Be $true
        }

        It 'retorna false quando nenhum probe existe' {
            Mock Test-Path { return $false }
            Mock Get-ChildItem { return @() }
            Test-WingetProbePathsOnDisk -ProbePaths @('C:\a\bin.exe', 'C:\b\bin.exe') | Should Be $false
        }

        It 'retorna false para lista vazia' {
            Test-WingetProbePathsOnDisk -ProbePaths @() | Should Be $false
        }

        It 'expande $env: em paths antes de testar' {
            $expectedExpanded = [Environment]::ExpandEnvironmentVariables('%LOCALAPPDATA%\Programs\Foo\bin.exe')
            Mock Test-Path { param($LiteralPath) return ($LiteralPath -eq $expectedExpanded) }
            Test-WingetProbePathsOnDisk -ProbePaths @('$env:LOCALAPPDATA\Programs\Foo\bin.exe') | Should Be $true
        }
    }

    Context 'Ensure-WingetPackage curto-circuito por ProbePaths' {
        It 'Pula winget completamente quando binario ja existe em disco' {
            Mock Test-WingetProbePathsOnDisk { return $true }
            Mock Test-WingetPackageInstalled { throw 'nao deve ser chamado' }
            Mock Invoke-NativeWithRetry { throw 'nao deve ser chamado' }
            Mock Write-Log {}
            { Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Foo.Bar' -DisplayName 'Foo' -ProbePaths @('C:\real\foo.exe') } | Should Not Throw
            Assert-MockCalled Test-WingetProbePathsOnDisk -Times 1 -Exactly
            Assert-MockCalled Test-WingetPackageInstalled -Times 0 -Exactly
        }
    }
}
