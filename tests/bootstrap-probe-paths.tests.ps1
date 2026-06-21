$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Bootstrap ProbePaths sanity (anti-regression after 2026-05-28 destructive ghost-recovery)' {

    Context 'vcpp-redist ProbePaths' {

        It 'aponta para System32 (onde o runtime VC++ realmente fica)' {
            $catalog = Get-BootstrapComponentCatalog
            $vcpp = $catalog['vcpp-redist']
            $vcpp | Should Not Be $null
            $paths = @($vcpp.ProbePaths)
            (@($paths | Where-Object { $_ -match 'System32' })).Count | Should BeGreaterThan 0
        }

        It 'NAO aponta para o caminho fantasma Program Files\Microsoft Visual C++ Redistributable' {
            $catalog = Get-BootstrapComponentCatalog
            $vcpp = $catalog['vcpp-redist']
            $paths = @($vcpp.ProbePaths)
            (@($paths | Where-Object { $_ -match 'Microsoft Visual C\+\+ Redistributable\\2015-2022' })).Count | Should Be 0
        }

        It 'cobre as 3 DLLs esperadas (vcruntime140, vcruntime140_1, msvcp140)' {
            $catalog = Get-BootstrapComponentCatalog
            $paths = @($catalog['vcpp-redist'].ProbePaths)
            (@($paths | Where-Object { $_ -match 'vcruntime140\.dll' })).Count | Should BeGreaterThan 0
            (@($paths | Where-Object { $_ -match 'vcruntime140_1\.dll' })).Count | Should BeGreaterThan 0
            (@($paths | Where-Object { $_ -match 'msvcp140\.dll' })).Count | Should BeGreaterThan 0
        }
    }

    Context 'vigembus-runtime ProbePaths' {

        It 'aponta para System32\drivers (onde drivers .sys vivem)' {
            $catalog = Get-BootstrapComponentCatalog
            $vbus = $catalog['vigembus-runtime']
            $vbus | Should Not Be $null
            $paths = @($vbus.ProbePaths)
            (@($paths | Where-Object { $_ -match 'System32\\drivers' })).Count | Should BeGreaterThan 0
        }

        It 'NAO aponta para Program Files\Nefarius Software Solutions (caminho que nao recebe o .sys binario)' {
            $catalog = Get-BootstrapComponentCatalog
            $paths = @($catalog['vigembus-runtime'].ProbePaths)
            (@($paths | Where-Object { $_ -match 'Nefarius Software Solutions' })).Count | Should Be 0
        }
    }

    Context 'explorerpatcher ProbePaths' {

        It 'NAO procura ep_weather_host.dll (plugin opcional baixado dinamicamente)' {
            $catalog = Get-BootstrapComponentCatalog
            $paths = @($catalog['explorerpatcher'].ProbePaths)
            (@($paths | Where-Object { $_ -match 'ep_weather_host' })).Count | Should Be 0
        }

        It 'procura ep_setup.exe (binario garantido pelo install winget)' {
            $catalog = Get-BootstrapComponentCatalog
            $paths = @($catalog['explorerpatcher'].ProbePaths)
            (@($paths | Where-Object { $_ -match 'ep_setup\.exe' })).Count | Should BeGreaterThan 0
        }
    }

    Context 'WingetGhostRecoveryBlocklist' {

        It 'esta definido como array com pelo menos 1 entrada' {
            $script:WingetGhostRecoveryBlocklist | Should Not Be $null
            @($script:WingetGhostRecoveryBlocklist).Count | Should BeGreaterThan 0
        }

        It 'inclui Microsoft.VCRedist.2015+.x64 (runtime critico que foi desinstalado pelo bug 2026-05-28)' {
            $script:WingetGhostRecoveryBlocklist -contains 'Microsoft.VCRedist.2015+.x64' | Should Be $true
        }

        It 'inclui ViGEm.ViGEmBus (driver de input do Steam Deck)' {
            $script:WingetGhostRecoveryBlocklist -contains 'ViGEm.ViGEmBus' | Should Be $true
        }

        It 'inclui Microsoft.DirectX (runtime do sistema)' {
            $script:WingetGhostRecoveryBlocklist -contains 'Microsoft.DirectX' | Should Be $true
        }
    }

    Context 'Mensagens distintas para exit codes do winget' {

        It 'exit=-1978335216 (NO_APPLICABLE_INSTALLER) produz Reason no-applicable-installer' {
            # Smoke-test do helper inline em Ensure-WingetPackage: o codigo deve agora distinguir
            # entre falha por privilegio e pacote sem instalador aplicavel. Validamos via regex no
            # texto fonte da funcao (acesso a closure interno nao e exposto fora da funcao).
            $src = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap-tools.ps1') -Raw
            ($src -match 'no-applicable-installer') | Should Be $true
            ($src -match '0x8A150010') | Should Be $true
        }
    }

    Context 'Timeout user-scope nao kill prematuro de download legitimo' {

        It 'timeout user-scope >= 300s (cobre downloads ate ~300MB)' {
            # Validacao via fonte. O fix muda 120000 -> 300000 no ramo isNonAdminSkippable.
            $src = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap-tools.ps1') -Raw
            # busca pelo trecho "if (\$isNonAdminSkippable) { 300000 }"
            ($src -match 'isNonAdminSkippable\)\s*\{\s*300000\s*\}') | Should Be $true
        }
    }
}
