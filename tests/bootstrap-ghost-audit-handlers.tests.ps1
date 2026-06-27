$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Bootstrap ghost-audit extras (powertoys/terminal/docker)' {

    Context 'Get-BootstrapDockerInstallInfo' {

        It 'retorna hashtable com campos esperados' {
            $info = Get-BootstrapDockerInstallInfo
            foreach ($key in @('Installed','InstallRoot','ExePath','FileVersion','ServiceState','WslDistroPresent','HealthIssues','GhostState','GhostReason')) {
                $info.Contains($key) | Should Be $true
            }
        }

        It 'Installed e GhostState sao mutuamente exclusivos' {
            $info = Get-BootstrapDockerInstallInfo
            if ([bool]$info.Installed) {
                [bool]$info.GhostState | Should Be $false
            }
        }

        It 'campos string nao retornam $null' {
            $info = Get-BootstrapDockerInstallInfo
            foreach ($key in @('InstallRoot','ExePath','FileVersion','ServiceState','GhostReason')) {
                ($info.$key -is [string]) | Should Be $true
            }
        }
    }

    Context 'Catalogo - ProbePaths estendidos' {

        It 'powertoys cobre ProgramFiles, ProgramFiles(x86), LOCALAPPDATA e WindowsApps MSIX' {
            $catalog = Get-BootstrapComponentCatalog
            $pt = $catalog['powertoys']
            $pt | Should Not Be $null
            $paths = @($pt.ProbePaths)
            (@($paths | Where-Object { $_ -match 'WindowsApps' })).Count | Should BeGreaterThan 0
            (@($paths | Where-Object { $_ -match 'LOCALAPPDATA|Local' })).Count | Should BeGreaterThan 0
        }

        It 'docker cobre LOCALAPPDATA e ambos paths Program Files (Docker.exe + Docker Desktop.exe)' {
            $catalog = Get-BootstrapComponentCatalog
            $dk = $catalog['docker']
            $dk | Should Not Be $null
            $paths = @($dk.ProbePaths)
            (@($paths | Where-Object { $_ -match 'Docker Desktop\.exe' })).Count | Should BeGreaterThan 0
            (@($paths | Where-Object { $_ -match 'LOCALAPPDATA|Local' })).Count | Should BeGreaterThan 0
        }

        It 'terminal nao usa alias wt.exe como ProbePaths e valida pacote Appx' {
            $catalog = Get-BootstrapComponentCatalog
            $terminal = $catalog['terminal']
            $terminal | Should Not Be $null
            $paths = @($terminal.ProbePaths)
            (@($paths | Where-Object { $_ -match 'Microsoft\\WindowsApps\\wt\.exe' })).Count | Should Be 0
            (@($terminal.AppxPackageNames) -contains 'Microsoft.WindowsTerminal') | Should Be $true
        }

        It 'powershell valida instalacao MSIX via AppxPackageNames' {
            $catalog = Get-BootstrapComponentCatalog
            $powershell = $catalog['powershell']
            $powershell | Should Not Be $null
            (@($powershell.AppxPackageNames) -contains 'Microsoft.PowerShell') | Should Be $true
        }

        It 'claude-desktop cobre instalacao atual em LOCALAPPDATA AnthropicClaude' {
            $catalog = Get-BootstrapComponentCatalog
            $claude = $catalog['claude-desktop']
            $claude | Should Not Be $null
            $paths = @($claude.ProbePaths)
            (@($paths | Where-Object { $_ -match 'AnthropicClaude\\claude\.exe' })).Count | Should BeGreaterThan 0
            (@($paths | Where-Object { $_ -match 'AnthropicClaude\\app-\*\\claude\.exe' })).Count | Should BeGreaterThan 0
        }

        It 'opencode-desktop cobre instalacao atual em Program Files OpenCode' {
            $catalog = Get-BootstrapComponentCatalog
            $opencodeDesktop = $catalog['opencode-desktop']
            $opencodeDesktop | Should Not Be $null
            $paths = @($opencodeDesktop.ProbePaths)
            (@($paths | Where-Object { $_ -match 'OpenCode\\OpenCode\.exe' })).Count | Should BeGreaterThan 0
        }

        It 'desktop AI apps cover current winget install locations and known machine-scope packages' {
            $catalog = Get-BootstrapComponentCatalog

            @(@($catalog['opencode-desktop'].ProbePaths) | Where-Object { $_ -match '@opencode-aidesktop\\OpenCode\.exe' }).Count | Should BeGreaterThan 0
            @(@($catalog['perplexity'].ProbePaths) | Where-Object { $_ -match 'Perplexity\\Comet\\Application\\comet\.exe' }).Count | Should BeGreaterThan 0
            @(@($catalog['ollama'].ProbePaths) | Where-Object { $_ -match 'Programs\\Ollama\\ollama\.exe' }).Count | Should BeGreaterThan 0
            @(@($catalog['zed'].ProbePaths) | Where-Object { $_ -match 'Programs\\Zed\\Zed\.exe' }).Count | Should BeGreaterThan 0

            [bool]$catalog['go-core'].PreferUserScope | Should Be $false
            [bool]$catalog['autoclaw'].PreferUserScope | Should Be $false
            [bool]$catalog['perplexity'].PreferUserScope | Should Be $false
            [bool]$catalog['zed'].PreferUserScope | Should Be $false
        }
    }

    Context 'Contrato generico de auditoria' {
        It 'usa status GhostInstall de forma consistente' {
            $raw = Get-Content -LiteralPath $scriptPath -Raw
            $raw | Should Not Match 'GhostInstalled'
            $raw | Should Match 'GhostInstall'
        }

        It 'usa verificador generico enriquecido no fallback para suportar globs, portable e registro' {
            $raw = Get-Content -LiteralPath $scriptPath -Raw
            $raw | Should Match 'Test-BootstrapPackageArtifactsPresent -ProbePaths \$probeList'
            $raw | Should Match 'Test-BootstrapWingetRegistryArtifact -Id \$WingetId'
        }
    }

    Context 'Get-AuditSpecializedRow lida com novos componentes' {
        # Carrega as funcoes internas via library mode; o switch fica dentro de Invoke-BootstrapAuditMode,
        # entao chamamos via auditoria com Resolution sintetico.

        It 'powertoys retorna Healthy ou GhostInstall ou Missing - nunca null/Unknown' {
            $state = @{
                Changes = New-Object System.Collections.Generic.List[object]
                Winget = ''
                CurrentComponent = ''
                RunId = 'pester'
                WorkspaceRoot = $env:TEMP
                CloneBaseDir = $env:TEMP
            }
            $resolution = [pscustomobject]@{ ResolvedComponents = @('powertoys') }
            $rows = @(Invoke-BootstrapAuditMode -Resolution $resolution -State $state)
            $rows.Count | Should Be 1
            $status = [string]$rows[0].Status
            ($status -in @('Healthy','GhostInstall','Missing','InstalledButNotInPath')) | Should Be $true
        }

        It 'terminal retorna status reconhecido' {
            $state = @{
                Changes = New-Object System.Collections.Generic.List[object]
                Winget = ''
                CurrentComponent = ''
                RunId = 'pester'
                WorkspaceRoot = $env:TEMP
                CloneBaseDir = $env:TEMP
            }
            $resolution = [pscustomobject]@{ ResolvedComponents = @('terminal') }
            $rows = @(Invoke-BootstrapAuditMode -Resolution $resolution -State $state)
            $rows.Count | Should Be 1
            $status = [string]$rows[0].Status
            ($status -in @('Healthy','GhostInstall','Missing','InstalledButNotInPath')) | Should Be $true
        }

        It 'docker retorna status reconhecido' {
            $state = @{
                Changes = New-Object System.Collections.Generic.List[object]
                Winget = ''
                CurrentComponent = ''
                RunId = 'pester'
                WorkspaceRoot = $env:TEMP
                CloneBaseDir = $env:TEMP
            }
            $resolution = [pscustomobject]@{ ResolvedComponents = @('docker') }
            $rows = @(Invoke-BootstrapAuditMode -Resolution $resolution -State $state)
            $rows.Count | Should Be 1
            $status = [string]$rows[0].Status
            ($status -in @('Healthy','GhostInstall','Missing','Unhealthy')) | Should Be $true
        }
    }
}
