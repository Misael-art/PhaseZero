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
        foreach ($svc in @('jellyfin','syncthing','vaultwarden','uptime-kuma')) { $raw | Should Match $svc }
        $raw | Should Not Match '(?m)^\s*portainer:'
    }
    It 'o compose de extras referencia o portainer e os servicos pesados opt-in' {
        $extras = Join-Path (Split-Path -Parent $scriptPath) 'assets/home-server/docker-compose.extras.yml'
        Test-Path $extras | Should Be $true
        $raw = Get-Content $extras -Raw
        foreach ($svc in @('portainer','nextcloud','grafana','prometheus','paperless','n8n')) { $raw | Should Match $svc }
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

    It 'expoe 3 perfis de performance (velocidade/capacidade/moderado) com trade-offs coerentes' {
        $speed = Get-BootstrapLlamaPerformanceProfile -Mode 'speed'
        $moderate = Get-BootstrapLlamaPerformanceProfile -Mode 'moderate'
        $capacity = Get-BootstrapLlamaPerformanceProfile -Mode 'capacity'

        # contexto cresce de velocidade -> moderado -> capacidade
        ([int]$speed.ctxSize -lt [int]$moderate.ctxSize) | Should Be $true
        ([int]$moderate.ctxSize -lt [int]$capacity.ctxSize) | Should Be $true
        # KV cache: velocidade quantiza agressivo; capacidade mantem f16
        [string]$speed.cacheTypeK | Should Be 'q4_0'
        [string]$capacity.cacheTypeK | Should Be 'f16'
        # cada perfil sugere um quant tier e tem flash-attn
        foreach ($p in @($speed, $moderate, $capacity)) {
            [bool]$p.flashAttn | Should Be $true
            ([string]$p.quantTier) | Should Match '^(IQ|Q)\d'
            ([string]$p.priority) | Should Not Be ''
        }
    }
    It 'rejeita modo de performance invalido' {
        $threw = $false
        try { Get-BootstrapLlamaPerformanceProfile -Mode 'turbo' | Out-Null } catch { $threw = $true }
        $threw | Should Be $true
    }
    It 'o launcher aceita -PerfMode e aplica --cache-type/--ctx-size/--flash-attn' {
        $launcher = Join-Path (Split-Path -Parent $scriptPath) 'assets/home-server/run-llamacpp.ps1'
        $raw = Get-Content $launcher -Raw
        $raw | Should Match '\$PerfMode'
        $raw | Should Match '--cache-type-k'
        $raw | Should Match '--cache-type-v'
    }

    It 'monta a URL de download GGUF do Hugging Face corretamente' {
        $url = Get-BootstrapGgufDownloadUrl -Repo 'Qwen/Qwen2.5-7B-Instruct-GGUF' -File 'qwen2.5-7b-instruct-q4_k_m.gguf'
        $url | Should Be 'https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf'
    }
    It 'expoe um catalogo curado de modelos GGUF marcados por perfil de performance' {
        $catalog = @(Get-BootstrapGgufModelCatalog)
        $catalog.Count | Should BeGreaterThan 0
        foreach ($m in $catalog) {
            ([string]$m.repo) | Should Not Be ''
            ([string]$m.file) | Should Match '\.gguf$'
            ([string]$m.profile) | Should Match '^(speed|capacity|moderate)$'
            ([double]$m.sizeGB -gt 0) | Should Be $true
        }
        # ha pelo menos um modelo para cada perfil
        foreach ($p in @('speed', 'moderate', 'capacity')) {
            (@($catalog | Where-Object { [string]$_.profile -eq $p }).Count -gt 0) | Should Be $true
        }
    }
    It 'resolve um modelo recomendado para cada perfil de performance' {
        foreach ($p in @('speed', 'moderate', 'capacity')) {
            $m = Resolve-BootstrapGgufModelForProfile -Mode $p
            [string]$m.profile | Should Be $p
            [string]$m.file | Should Match '\.gguf$'
            (Get-BootstrapGgufDownloadUrl -Repo $m.repo -File $m.file) | Should Match '^https://huggingface\.co/'
        }
    }
    It 'em dry-run o download de modelo nao baixa nada' {
        Mock -CommandName Invoke-WebRequest -MockWith {}
        $dir = Join-Path $env:TEMP ("gguf-dry-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $res = Install-BootstrapGgufModel -Repo 'Qwen/Qwen2.5-7B-Instruct-GGUF' -File 'qwen2.5-7b-instruct-q4_k_m.gguf' -ModelsDir $dir -DryRun
        [string]$res.status | Should Be 'planned'
        Assert-MockCalled -CommandName Invoke-WebRequest -Times 0 -Scope It
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

Describe 'gpedit hardening (privacidade/telemetria, reversivel)' {
    It 'declara o componente gpedit-hardening opt-in' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('gpedit-hardening') | Should Be $true
        [bool]$catalog['gpedit-hardening'].Optional | Should Be $true
        [string]$catalog['gpedit-hardening'].Kind | Should Be 'gpedit-hardening'
    }
    It 'todas as mutacoes passam por Apply-BootstrapRegistryDword (registradas p/ rollback)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-BootstrapGpeditHardening' }, $true))[0]
        $fn | Should Not BeNullOrEmpty
        $cmds = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { ($_.GetCommandName() -split '\\')[-1] })
        # nao usa escrita de registro crua sem registrar
        (@($cmds | Where-Object { $_ -in @('Set-ItemProperty', 'New-ItemProperty', 'Remove-Item') }).Count) | Should Be 0
        (@($cmds | Where-Object { $_ -eq 'Apply-BootstrapRegistryDword' }).Count -gt 0) | Should Be $true
    }
    It 'NAO inclui o bloqueio agressivo de privacidade de apps (Forcar Negacao) por padrao' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-BootstrapGpeditHardening' }, $true))[0]
        $fn.Extent.Text | Should Not Match 'LetAppsAccessCamera|LetAppsAccessMicrophone|LetAppsRunInBackground'
    }
    It 'em dry-run nao escreve no registro' {
        Mock -CommandName Apply-BootstrapRegistryDword -MockWith {}
        $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot $env:TEMP -ResolvedCloneBaseDir $env:TEMP
        $state.DryRun = $true
        Ensure-BootstrapGpeditHardening -State $state
        Assert-MockCalled -CommandName Apply-BootstrapRegistryDword -Times 0 -Scope It
    }
    It 'aplica politicas-chave do PDF (telemetria, widgets, advertising id, activity feed)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-BootstrapGpeditHardening' }, $true))[0]
        foreach ($k in @('DataCollection', 'AllowNewsAndInterests', 'AdvertisingInfo', 'EnableActivityFeed', 'CloudContent', 'PushToInstall')) {
            $fn.Extent.Text | Should Match $k
        }
    }
}

Describe 'System optimization apps (opt-in, guiados)' {
    It 'declara sparkle-optimizer (thedogecraft) como manual-required experimental com fonte oficial' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('sparkle-optimizer') | Should Be $true
        $def = $catalog['sparkle-optimizer']
        [string]$def.Kind | Should Be 'manual-required'
        [bool]$def.Optional | Should Be $true
        [string]$def.officialSource | Should Match 'thedogecraft/sparkle'
        ([string]$def.manualReason) | Should Not Be ''
    }
    It 'corrige o rotulo do componente sparkle existente (xishang0128 = Mihomo GUI, nao otimizador)' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('sparkle') | Should Be $true
        ([string]$catalog['sparkle'].Description) | Should Match 'Mihomo|Clash|proxy'
        ([string]$catalog['sparkle'].Description) | Should Not Match 'otimizador|debloat'
    }
    It 'declara performance-v4 como manual-required experimental (MS Store)' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('performance-v4') | Should Be $true
        $def = $catalog['performance-v4']
        [string]$def.Kind | Should Be 'manual-required'
        [bool]$def.Optional | Should Be $true
        ([string]$def.Instructions) | Should Match 'Store|9N5N9D6JB8VT'
    }
    It 'nao inclui esses otimizadores em nenhum perfil seguro' {
        $profiles = Get-BootstrapProfileCatalog
        foreach ($safe in @('safe-base', 'recommended', 'public-beta')) {
            if ($profiles.Contains($safe)) {
                @($profiles[$safe].Items) -contains 'sparkle-optimizer' | Should Be $false
                @($profiles[$safe].Items) -contains 'performance-v4' | Should Be $false
            }
        }
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
