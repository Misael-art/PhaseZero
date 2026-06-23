$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Windows home server: profiles' {
    $expected = @{
        'server-llm'                = @('ollama', 'os-slim-server')
        'server-homelab'            = @('homelab-stack', 'tailscale')
        'server-homelab-hermes'     = @('homelab-stack', 'tailscale', 'hermes-remote')
        'server-llm-hermes'         = @('ollama', 'hermes-remote', 'os-slim-server')
        'server-llm-homelab'        = @('ollama', 'homelab-stack', 'tailscale', 'os-slim-server')
        'server-llm-homelab-hermes' = @('ollama', 'homelab-stack', 'tailscale', 'hermes-remote', 'os-slim-server')
    }
    It 'define os 6 perfis de servidor com os componentes corretos' {
        $profiles = Get-BootstrapProfileCatalog
        foreach ($name in $expected.Keys) {
            $profiles.Contains($name) | Should Be $true
            foreach ($item in $expected[$name]) { @($profiles[$name].Items) -contains $item | Should Be $true }
        }
    }
    It 'todos os itens dos 6 perfis existem no catalogo de componentes' {
        $catalog = Get-BootstrapComponentCatalog
        $profiles = Get-BootstrapProfileCatalog
        foreach ($name in $expected.Keys) {
            foreach ($item in @($profiles[$name].Items)) { $catalog.Contains($item) | Should Be $true }
        }
    }
    It 'expoe os 6 perfis de servidor no contrato da UI/CLI com a familia "Servidor caseiro"' {
        $contract = Get-BootstrapUiContract
        $names = @($contract.profiles | ForEach-Object { [string]$_.name })
        foreach ($p in $expected.Keys) { $names -contains $p | Should Be $true }
        foreach ($entry in @($contract.profiles | Where-Object { [string]$_.name -like 'server-*' })) {
            [string]$entry.family | Should Be 'Servidor caseiro'
        }
        # cada entrada de perfil tem o campo family
        foreach ($entry in @($contract.profiles)) {
            ($entry.PSObject.Properties.Name -contains 'family') -or ($entry.Contains('family')) | Should Be $true
        }
    }
    It 'resolve o perfil mais completo a componentes (com dependencias) sem erro' {
        $res = Resolve-BootstrapComponents -SelectedProfiles @('server-llm-homelab-hermes')
        $resolved = @($res.ResolvedComponents)
        foreach ($item in @('ollama', 'homelab-stack', 'hermes-remote', 'os-slim-server', 'tailscale')) {
            $resolved -contains $item | Should Be $true
        }
        # dependencias transitivas presentes
        foreach ($dep in @('wsl-core', 'docker', 'hermes')) { $resolved -contains $dep | Should Be $true }
    }
}

Describe 'Windows home server: hermes-remote' {
    It 'declara hermes-remote opt-in dependente de hermes e tailscale' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('hermes-remote') | Should Be $true
        [bool]$catalog['hermes-remote'].Optional | Should Be $true
        @($catalog['hermes-remote'].DependsOn) -contains 'hermes' | Should Be $true
        @($catalog['hermes-remote'].DependsOn) -contains 'tailscale' | Should Be $true
    }
    It 'NUNCA embute authkey/token no codigo (usa env/secrets)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-BootstrapHermesRemote' }, $true))[0]
        $fn | Should Not BeNullOrEmpty
        $fn.Extent.Text | Should Not Match 'tskey-[A-Za-z0-9]|--authkey[= ]+[A-Za-z0-9]'
    }
    It 'em dry-run nao executa tailscale up nem reparo' {
        Mock -CommandName Invoke-BootstrapCommandCapture -MockWith { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Mock -CommandName Invoke-BootstrapMcpConfigRepair -MockWith { [ordered]@{ totalFixed = 0; targets = @() } }
        Mock -CommandName Ensure-HermesProjectOpenCloudConfig -MockWith {}
        $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot $env:TEMP -ResolvedCloneBaseDir $env:TEMP
        $state.DryRun = $true
        Ensure-BootstrapHermesRemote -State $state
        Assert-MockCalled -CommandName Invoke-BootstrapCommandCapture -Times 0 -Scope It
        Assert-MockCalled -CommandName Invoke-BootstrapMcpConfigRepair -Times 0 -Scope It
    }
}

Describe 'Windows home server: homelab-stack' {
    It 'declara homelab-stack opt-in dependente de wsl-core e docker' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('homelab-stack') | Should Be $true
        [bool]$catalog['homelab-stack'].Optional | Should Be $true
        @($catalog['homelab-stack'].DependsOn) -contains 'wsl-core' | Should Be $true
        @($catalog['homelab-stack'].DependsOn) -contains 'docker' | Should Be $true
    }
    It 'o compose core existe e referencia os servicos leves padrao' {
        $compose = Join-Path (Split-Path -Parent $scriptPath) 'assets/home-server/docker-compose.homelab.yml'
        Test-Path $compose | Should Be $true
        $raw = Get-Content $compose -Raw
        foreach ($svc in @('portainer','jellyfin','syncthing','vaultwarden','uptime-kuma')) { $raw | Should Match $svc }
    }
    It 'o compose de extras existe e referencia os servicos pesados opt-in' {
        $extras = Join-Path (Split-Path -Parent $scriptPath) 'assets/home-server/docker-compose.extras.yml'
        Test-Path $extras | Should Be $true
        $raw = Get-Content $extras -Raw
        foreach ($svc in @('nextcloud','grafana','prometheus','paperless','n8n')) { $raw | Should Match $svc }
    }
    It 'nenhum compose embute segredos em texto puro (apenas placeholders ${...})' {
        foreach ($f in @('docker-compose.homelab.yml','docker-compose.extras.yml')) {
            $p = Join-Path (Split-Path -Parent $scriptPath) ("assets/home-server/{0}" -f $f)
            $raw = Get-Content $p -Raw
            $raw | Should Not Match 'Bearer\s+[A-Za-z0-9]'
            $raw | Should Not Match '(PASSWORD|TOKEN|SECRET_KEY|ENCRYPTION_KEY)=(?!\$\{)[A-Za-z0-9]'
        }
    }
}

Describe 'Windows home server: llama.cpp offload autocalc' {
    It 'aloca todas as camadas na GPU quando o modelo cabe na VRAM' {
        $p = Get-BootstrapLlamaOffloadPlan -VramGB 24 -RamGB 32 -ModelSizeGB 12 -TotalLayers 80
        [int]$p.gpuLayers | Should Be 80
        [bool]$p.lowVram | Should Be $false
        [bool]$p.insufficient | Should Be $false
    }
    It 'faz split hibrido proporcional com margem quando o modelo excede a VRAM' {
        $p = Get-BootstrapLlamaOffloadPlan -VramGB 8 -RamGB 32 -ModelSizeGB 20 -TotalLayers 80
        ([int]$p.gpuLayers -gt 0 -and [int]$p.gpuLayers -lt 80) | Should Be $true
        [bool]$p.lowVram | Should Be $true
        [bool]$p.insufficient | Should Be $false
    }
    It 'sinaliza hardware insuficiente quando nem soma VRAM+RAM cabe' {
        $p = Get-BootstrapLlamaOffloadPlan -VramGB 4 -RamGB 4 -ModelSizeGB 20 -TotalLayers 80
        [bool]$p.insufficient | Should Be $true
    }
    It 'declara o componente llamacpp-server como opt-in' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('llamacpp-server') | Should Be $true
        [bool]$catalog['llamacpp-server'].Optional | Should Be $true
    }
    It 'seleciona o asset Windows x64 correto por preferencia de GPU' {
        $assets = @(
            'cudart-llama-bin-win-cu12.4-x64.zip',
            'llama-b4458-bin-win-cuda-cu12.4-x64.zip',
            'llama-b4458-bin-win-vulkan-x64.zip',
            'llama-b4458-bin-win-cpu-x64.zip',
            'llama-b4458-bin-win-hip-radeon-x64.zip',
            'llama-b4458-bin-ubuntu-x64.zip'
        )
        Select-BootstrapLlamaCppAsset -AssetNames $assets -Prefer 'cuda' | Should Be 'llama-b4458-bin-win-cuda-cu12.4-x64.zip'
        Select-BootstrapLlamaCppAsset -AssetNames $assets -Prefer 'vulkan' | Should Be 'llama-b4458-bin-win-vulkan-x64.zip'
        Select-BootstrapLlamaCppAsset -AssetNames $assets -Prefer 'cpu' | Should Be 'llama-b4458-bin-win-cpu-x64.zip'
    }
    It 'nunca escolhe o cudart (runtime) como binario principal' {
        $assets = @('cudart-llama-bin-win-cu12.4-x64.zip')
        Select-BootstrapLlamaCppAsset -AssetNames $assets -Prefer 'cuda' | Should Be $null
    }
    It 'retorna null quando nao ha asset Windows x64' {
        Select-BootstrapLlamaCppAsset -AssetNames @('llama-b4458-bin-ubuntu-x64.zip', 'llama-b4458-bin-macos-arm64.zip') -Prefer 'cpu' | Should Be $null
    }

    It 'o launcher run-llamacpp.ps1 existe e tem fallback de offload' {
        $launcher = Join-Path (Split-Path -Parent $scriptPath) 'assets/home-server/run-llamacpp.ps1'
        Test-Path $launcher | Should Be $true
        $raw = Get-Content $launcher -Raw
        $raw | Should Match '--n-gpu-layers'
        $raw | Should Match '--flash-attn'
        $raw | Should Match '8080'
    }
}

Describe 'Windows home server: os-slim-server' {
    It 'declara o componente os-slim-server como opt-in e do Kind correto' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('os-slim-server') | Should Be $true
        $def = $catalog['os-slim-server']
        [string]$def.Kind | Should Be 'os-slim-server'
        [bool]$def.Optional | Should Be $true
    }

    It 'NUNCA remove arquivos do usuario nem desabilita o shell (invariante de seguranca)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-BootstrapOsSlimServer' }, $true))[0]
        $fn | Should Not BeNullOrEmpty
        $fn.Extent.Text | Should Not Match 'Remove-Item\s+.*Users|Stop-Process\s+-Name\s+''?explorer|Winlogon.*Shell'
    }

    It 'cada mutacao de host passa por um registrador de rollback' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-BootstrapOsSlimServer' }, $true))[0]
        $cmds = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { ($_.GetCommandName() -split '\\')[-1] })
        $mutating = @('Set-ItemProperty', 'Remove-ItemProperty', 'New-ItemProperty')
        if (@($cmds | Where-Object { $mutating -contains $_ }).Count -gt 0) {
            (@($cmds | Where-Object { $_ -in @('Register-BootstrapChange', 'Register-BootstrapFileChange', 'Set-BootstrapServiceStartupTypes') }).Count -gt 0) | Should Be $true
        }
    }

    It 'em dry-run nao muta o host (nenhuma chamada de escrita executada)' {
        Mock -CommandName Set-ItemProperty -MockWith {}
        Mock -CommandName Remove-ItemProperty -MockWith {}
        Mock -CommandName Set-BootstrapServiceStartupTypes -MockWith {}
        Mock -CommandName Repair-BootstrapFastStartup -MockWith {}
        $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot $env:TEMP -ResolvedCloneBaseDir $env:TEMP
        $state.DryRun = $true
        $state.ChangeManifestPath = Join-Path $env:TEMP ("os-slim-dry-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        try {
            Ensure-BootstrapOsSlimServer -State $state
            Assert-MockCalled -CommandName Set-ItemProperty -Times 0 -Scope It
            Assert-MockCalled -CommandName Set-BootstrapServiceStartupTypes -Times 0 -Scope It
        } finally {
            Remove-Item -LiteralPath $state.ChangeManifestPath -Force -ErrorAction SilentlyContinue
        }
    }
}
