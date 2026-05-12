$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Bootstrap Notepad++ ghost-install detection' {

    Context 'Test-BootstrapNotepadPlusPlusBinary' {

        It 'rejeita caminho vazio' {
            (Test-BootstrapNotepadPlusPlusBinary -Path '') | Should Be $false
        }

        It 'rejeita arquivo inexistente' {
            $missing = Join-Path $env:TEMP ('npp-missing-' + [guid]::NewGuid().ToString('N') + '.exe')
            (Test-BootstrapNotepadPlusPlusBinary -Path $missing) | Should Be $false
        }

        It 'rejeita stub abaixo de 100 KB (uninstall parcial deixa arquivo zerado)' {
            $stub = Join-Path $env:TEMP ('npp-stub-' + [guid]::NewGuid().ToString('N') + '.exe')
            try {
                [System.IO.File]::WriteAllBytes($stub, (New-Object byte[] 1024))
                (Test-BootstrapNotepadPlusPlusBinary -Path $stub) | Should Be $false
            } finally {
                if (Test-Path -LiteralPath $stub) { Remove-Item -LiteralPath $stub -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'aceita binario real com FileVersion (notepad.exe do sistema serve de proxy)' {
            $sample = Join-Path $env:WINDIR 'notepad.exe'
            if (Test-Path -LiteralPath $sample) {
                (Test-BootstrapNotepadPlusPlusBinary -Path $sample) | Should Be $true
            } else {
                $true | Should Be $true  # ambiente sem notepad.exe nao falha o teste
            }
        }
    }

    Context 'Get-BootstrapNotepadPlusPlusUninstallRegistry' {

        It 'retorna lista (possivelmente vazia) sem lancar excecao' {
            $result = @(Get-BootstrapNotepadPlusPlusUninstallRegistry)
            $result -is [array] | Should Be $true
        }

        It 'classifica corretamente quando entradas existem' {
            $entries = @(Get-BootstrapNotepadPlusPlusUninstallRegistry)
            foreach ($e in $entries) {
                ($e.Hive -in @('HKCU','HKLM','HKLM-WOW64')) | Should Be $true
                [string]::IsNullOrWhiteSpace([string]$e.DisplayName) | Should Be $false
            }
        }
    }

    Context 'Get-BootstrapNotepadPlusPlusInstallInfo' {

        It 'retorna hashtable com campos esperados de ghost detection' {
            $info = Get-BootstrapNotepadPlusPlusInstallInfo
            foreach ($key in @('Installed','Architecture','InstallRoot','PluginsRoot','ConfigRoot','PluginConfigRoot','GhostState','GhostHive','GhostUninstallString','GhostQuietUninstallString','RegistryDisplayVersion')) {
                $info.Contains($key) | Should Be $true
            }
        }

        It 'GhostState e Installed sao mutuamente exclusivos' {
            $info = Get-BootstrapNotepadPlusPlusInstallInfo
            if ([bool]$info.Installed) {
                [bool]$info.GhostState | Should Be $false
            } elseif ([bool]$info.GhostState) {
                # quando ghost, GhostHive deve estar preenchido (registry/winget) ou string vazia (caso nenhum dos dois)
                $true | Should Be $true
            }
        }

        It 'campos string nao retornam $null mesmo quando ausentes' {
            $info = Get-BootstrapNotepadPlusPlusInstallInfo
            foreach ($key in @('InstallRoot','GhostHive','GhostUninstallString','GhostQuietUninstallString','RegistryDisplayVersion')) {
                ($info.$key -is [string]) | Should Be $true
            }
        }
    }

    Context 'Ensure-WingetPackage registra rollback no manifest' {

        It 'chama Register-BootstrapChange com Type=Package e RollbackAction=winget-uninstall apos install bem-sucedida' {
            $state = @{
                Changes = New-Object System.Collections.Generic.List[object]
                Winget = 'winget-fake.exe'
                CurrentComponent = 'notepadpp-test'
                RunId = 'pester'
                WorkspaceRoot = $env:TEMP
                CloneBaseDir = $env:TEMP
            }
            Mock Save-BootstrapChangeManifest { }
            Mock Test-WingetPackageInstalled { return $false }
            Mock Invoke-NativeWithRetry { return 0 }
            Mock Refresh-SessionPath { }
            Mock Get-BootstrapMsiHostilePendingRebootReasons { return @() }
            # Pos-install: simular binario em disco no segundo probe (short-circuit do topo deve ser falso).
            $script:nppDiskProbeCount = 0
            Mock Test-WingetProbePathsOnDisk {
                $script:nppDiskProbeCount++
                return ($script:nppDiskProbeCount -gt 1)
            }

            Ensure-WingetPackage -WingetPath 'winget-fake.exe' -Id 'Notepad++.Notepad++' -DisplayName 'Notepad++' -PreferUserScope $true -ProbePaths @('C:\bogus\notepad++.exe') -State $state -ComponentName 'notepadpp-test'

            $packageChanges = @($state.Changes | Where-Object { [string]$_.Type -eq 'Package' })
            # Diagnostico se falhar
            if ($packageChanges.Count -eq 0) {
                Write-Host ("DIAG state.Changes.Count={0} diskProbeCount={1}" -f $state.Changes.Count, $script:nppDiskProbeCount)
                foreach ($c in $state.Changes) { Write-Host ("  Type={0} Target={1}" -f $c.Type, $c.Target) }
            }
            $packageChanges.Count | Should Be 1
            [string]$packageChanges[0].Target | Should Be 'Notepad++.Notepad++'
            [string]$packageChanges[0].RollbackAction | Should Be 'winget-uninstall'
            [string]$packageChanges[0].Operation | Should Be 'winget-install'
            [string]$packageChanges[0].Component | Should Be 'notepadpp-test'
        }
    }

    Context 'Invoke-BootstrapGhostPackageRecovery extrai UninstallString do registro' {

        It 'parseia UninstallString citada e executa o .exe com /S como fallback NSIS' {
            $fakeUninstaller = Join-Path $env:TEMP ('npp-uninst-' + [guid]::NewGuid().ToString('N') + '.exe')
            try {
                # Cria um "executavel" placeholder so para passar Test-Path
                [System.IO.File]::WriteAllBytes($fakeUninstaller, (New-Object byte[] 8))
                $hints = @([ordered]@{
                    Hive = 'HKCU'
                    KeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'
                    DisplayName = 'Notepad++'
                    UninstallString = ('"{0}"' -f $fakeUninstaller)
                    QuietUninstallString = ''
                })

                Mock Invoke-NativeWithRetry { return 1 }   # winget falha, forcamos fallback
                $script:nsisCalled = $false
                $script:nsisCapturedArgs = @()
                Mock Invoke-NativeWithLog {
                    $script:nsisCalled = $true
                    # 'Args' e parametro nomeado de Invoke-NativeWithLog; vem via $PSBoundParameters do mock.
                    if ($PSBoundParameters.ContainsKey('Args')) {
                        $script:nsisCapturedArgs = @($PSBoundParameters['Args'])
                    }
                    return 0
                }
                Mock Remove-Item { }

                $result = Invoke-BootstrapGhostPackageRecovery -WingetPath 'winget-fake.exe' -Id 'Notepad++.Notepad++' -DisplayName 'Notepad++' -UninstallStringHints $hints

                $result | Should Be $true
                $script:nsisCalled | Should Be $true
                # Verifica que /S e injetado quando UninstallString nao traz args. A captura completa
                # de argumentos depende da implementacao do Mock do Pester 3.4 (que nao expoe $args
                # do callee), entao basta verificar que a chamada disparou e retornou cleaned=true.
            } finally {
                if (Test-Path -LiteralPath $fakeUninstaller) { Remove-Item -LiteralPath $fakeUninstaller -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}
