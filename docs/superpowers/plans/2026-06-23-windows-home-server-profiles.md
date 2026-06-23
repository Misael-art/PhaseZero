# Windows Home Server Profiles (6 modos) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Implementar tarefa a tarefa, TDD. Steps usam checkbox (`- [ ]`).

**Goal:** Adicionar um novo conjunto de perfis que transformam um PC Windows (mantendo o Windows — **não** é Umbrel/Linux bare-metal) em servidor caseiro, com 6 modos combinando: LLM local, stack de homelab (NAS/mídia/DNS/cofre) e Hermes para atuação remota. Modos com LLM local também enxugam o SO (reversível) para reduzir RAM.

**Architecture:** Mantém a arquitetura do PhaseZero. Tudo entra como **componentes** (`New-BootstrapComponentDefinition`) com `Kind` custom + função `Ensure-*` ligada ao dispatcher `switch ($componentDef.Kind)` (`bootstrap-tools.ps1:2965`) e à tabela de auditoria, e como **perfis** (`New-BootstrapProfileDefinition`) que apenas agrupam componentes. Toda mutação de host passa por `Register-BootstrapChange`/`Register-BootstrapFileChange` para rollback. Sem novos serviços fora do `.bootstrap-tools/`. Surface CLI (`-Profile`, `-UiContractJson`) e UI herdam automaticamente.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4. Reuso: `wsl-core`, `docker`, `tailscale`, `ollama`, `lm-studio`, `hermes`, host-health cleanup, drift/audit, scheduled-task helpers. Novo: `llamacpp-server` (opt-in), `homelab-stack` (Docker via WSL2), `os-slim-server`, `hermes-remote`.

---

## Decisões travadas (do usuário)

- **Runtime LLM:** Ollama é o padrão dos perfis; `llamacpp-server` é componente **opt-in** (controle fino de offload VRAM/RAM, autocalc de camadas).
- **Stack de servidor:** **Docker via WSL2** (reusa `wsl-core` + `docker`). Tailscale nativo no Windows. Compose dentro do WSL2.
- **Enxugar SO:** **Agressivo mas reversível** — telemetria, efeitos visuais, busca/indexação, OneDrive, apps de fundo, Game Bar/GameDVR, serviços não-essenciais; tudo registrado para rollback; shell continua utilizável.
- **Entrega:** Plano primeiro (este doc), depois implementação em lotes com checkpoints.

## Filtragem honesta das fontes (o que entra e o que sai)

- **Umbrel OS → DESCARTADO.** É Linux bare-metal que substitui o SO; conflita com "manter Windows". Substituído por **Docker compose via WSL2** + Tailscale nativo. Mantém a ideia (Jellyfin/Nextcloud/Pi-hole/Vaultwarden/Tailscale), troca o veículo.
- **llama.cpp offload autocalc → MANTIDO** (como `Get-BootstrapLlamaOffloadPlan`), mas opt-in; Ollama cobre o caminho fácil.
- **Tailscale (WireGuard, sem port-forwarding) → MANTIDO.** Já existe componente `tailscale`.
- **"Self-healing daemon" → REUSAR** o que já existe (drift-check + audit/repair + scheduled task), não criar daemon novo.
- **Números de t/s, "auto-mutação", payloads de API "presumidos" → IGNORADOS** (hype/não verificável). Endpoints inventados do Umbrel não se aplicam.
- **Segredos/authkeys:** nunca hardcode. Tailscale auth-key e tokens vêm do manifesto de secrets (mascarado) ou variável de ambiente; rollback registrado.

### Fontes adicionais avaliadas (DietPi + CasaOS)

- **DietPi e CasaOS → DESCARTADOS como OS/camada.** Ambos são Linux que substituem/assumem o host (`dietpi.txt`, `AUTO_SETUP_INSTALL_SOFTWARE_ID`, `casaos-cli`, `/var/lib/casaos/apps/`). Conflitam com "manter Windows". No nosso caso a camada amigável é o **Portainer** (não CasaOS).
- **DOBRADOS (como containers no `homelab-stack`):**
  - **Portainer CE** — dashboard web de gestão do Docker (o maior ganho de "amigável"; equivalente prático ao CasaOS no Windows/WSL2).
  - **Uptime Kuma** — monitor de uptime + alertas (Telegram/webhook); integra com o self-healing reusando drift/audit.
  - **Syncthing** — sync de arquivos leve P2P → vira a opção **padrão** de "Drive" para casar com baixo RAM (resolve a questão aberta #4). Nextcloud passa a ser opt-in pesado.
- **OPT-IN pesados** (não entram no padrão): **Grafana + Prometheus + Node Exporter** (observabilidade), **Paperless-ngx** (OCR de documentos), **n8n** (workflows). Documentados como add-ons via `--component`.
- **IGNORADOS:** watchdog térmico (`/sys/class/thermal` é Linux; no Windows o próprio SO + auditoria existente cobrem), Evolution API/WhatsApp (nicho), e os números anedóticos. Nome correto é **paperless-ngx** (o doc escreveu "Paperless-JSX").

## Matriz Modo → Perfil → Componentes

| # | Modo | Perfil (Name) | Componentes | Enxuga SO |
|---|------|---------------|-------------|-----------|
| 1 | LLM local | `server-llm` | `ollama`, `os-slim-server` | sim |
| 2 | Servidor caseiro (Drive/mídia) | `server-homelab` | `homelab-stack`, `tailscale` | não |
| 3 | Servidor caseiro + Hermes remoto | `server-homelab-hermes` | `homelab-stack`, `tailscale`, `hermes-remote` | não |
| 4 | LLM local + Hermes remoto | `server-llm-hermes` | `ollama`, `hermes-remote`, `os-slim-server` | sim |
| 5 | LLM local + servidor caseiro | `server-llm-homelab` | `ollama`, `homelab-stack`, `tailscale`, `os-slim-server` | sim |
| 6 | LLM + servidor + Hermes | `server-llm-homelab-hermes` | `ollama`, `homelab-stack`, `tailscale`, `hermes-remote`, `os-slim-server` | sim* |

\* O usuário marcou "enxugar" explicitamente em 1/4/5; o modo 6 tem LLM e se beneficia igual, então incluímos `os-slim-server` por consistência. **Confirmar na revisão** se 6 deve mesmo enxugar.

`llamacpp-server` é opt-in e **não** entra nos perfis por padrão; documentado como add-on dos modos LLM (`--component llamacpp-server`).

---

## File Map

- Modify: `bootstrap-tools.ps1`
  - `Get-BootstrapComponentCatalog` — 4 novos componentes
  - `Get-BootstrapProfileCatalog` — 6 novos perfis
  - dispatcher de instalação (`switch ($componentDef.Kind)` ~2965) — 4 novos Kinds
  - dispatcher de auditoria — assinaturas instaladas dos 4
  - novas funções `Ensure-BootstrapOsSlimServer`, `Ensure-BootstrapLlamaCppServer`, `Get-BootstrapLlamaOffloadPlan`, `Ensure-BootstrapHomelabStack`, `Ensure-BootstrapHermesRemote`, `Get-BootstrapHomelabComposePath`
- Modify: `bootstrap-ui.ps1` — apenas se o contrato precisar rotular a família "Servidor" (provavelmente automático via profiles)
- Add: `assets/home-server/docker-compose.homelab.yml` — template do stack
- Add: `assets/home-server/run-llamacpp.ps1` — launcher resiliente com fallback de offload
- Add tests:
  - `tests/bootstrap-home-server.tests.ps1` — componentes, perfis, offload autocalc, invariantes de segurança/reversibilidade
  - estender `tests/bootstrap-tools.profiles.tests.ps1` se necessário (resolução dos 6 perfis)

---

### Task 1: Componente `os-slim-server` (enxugar SO, reversível)

**Files:** `bootstrap-tools.ps1`; `tests/bootstrap-home-server.tests.ps1`

- [ ] **Step 1 — teste falhando**

Criar `tests/bootstrap-home-server.tests.ps1` carregando `. $scriptPath -BootstrapUiLibraryMode` e:

```powershell
Describe 'Windows home server: os-slim-server' {
    It 'declara o componente os-slim-server como reversivel e builtin' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('os-slim-server') | Should Be $true
        $def = $catalog['os-slim-server']
        [string]$def.Kind | Should Be 'os-slim-server'
    }
    It 'NUNCA remove arquivos do usuario nem desabilita o shell (invariante)' {
        $tokens=$null;$errors=$null
        $ast=[System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
        $fn=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-BootstrapOsSlimServer'},$true))[0]
        $fn | Should Not BeNullOrEmpty
        $fn.Extent.Text | Should Not Match 'Remove-Item\s+.*Users|Stop-Process\s+-Name\s+''?explorer|Set-ItemProperty.*Winlogon.*Shell'
    }
    It 'cada tweak de host passa por Register-BootstrapChange' {
        $tokens=$null;$errors=$null
        $ast=[System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
        $fn=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-BootstrapOsSlimServer'},$true))[0]
        $cmds=@($fn.Body.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true)|ForEach-Object{($_.GetCommandName() -split '\\')[-1]})
        if (@($cmds|Where-Object{$_ -in @('Set-ItemProperty','Set-Service')}).Count -gt 0) {
            (@($cmds|Where-Object{$_ -in @('Register-BootstrapChange','Register-BootstrapFileChange','Set-BootstrapServiceStartupTypes','Disable-BootstrapRunEntries')}).Count -gt 0) | Should Be $true
        }
    }
}
```

- [ ] **Step 2 — rodar e ver falhar** (`tests/run-pester.ps1 -Path .\tests\bootstrap-home-server.tests.ps1`).

- [ ] **Step 3 — implementar `Ensure-BootstrapOsSlimServer`**

Aplicar, com `Register-BootstrapChange` por mutação (e reusando `Set-BootstrapServiceStartupTypes`/`Disable-BootstrapRunEntries`/`Invoke-BootstrapHostHealthCleanup` quando já cobrem o item):

- Telemetria: `DiagTrack` → Disabled; `dmwappushservice` → Manual.
- Busca/indexação: `WSearch` → Disabled (ganho de RAM/IO em servidor).
- Superfetch: `SysMain` → Disabled.
- Efeitos visuais: `VisualFXSetting=2` (best performance) em `HKCU\...\VisualEffects`.
- Apps de fundo: `HKCU\...\BackgroundAccessApplications GlobalUserDisabled=1`.
- Game Bar/GameDVR: `AppCaptureEnabled=0`, `GameDVR_Enabled=0`.
- OneDrive autostart: remover Run entry (via `Disable-BootstrapRunEntries`).
- Fast Startup/hibernação: reusar `Repair-BootstrapFastStartup` (já existe).
- **Não** mexer em Explorer/Winlogon Shell, **não** desabilitar Windows Update core, **não** apagar arquivos.

Registrar o componente no catálogo com `Kind 'os-slim-server'`, `-Optional $true`, `Stage='config'`, descrição pt-BR, e wire no dispatcher de install (`switch` ~2965) → `Ensure-BootstrapOsSlimServer -State $State`. Adicionar assinatura de auditoria (ex.: checar `DiagTrack` Disabled) na tabela de audit.

- [ ] **Step 4 — rodar e ver passar.**
- [ ] **Step 5 — commit:** `feat(server): componente os-slim-server (enxuga RAM, reversivel)`.

---

### Task 2: Componente `llamacpp-server` (opt-in) + autocalc de offload

**Files:** `bootstrap-tools.ps1`; `assets/home-server/run-llamacpp.ps1`; `tests/bootstrap-home-server.tests.ps1`

- [ ] **Step 1 — teste falhando** (autocalc determinístico, sem hardware real):

```powershell
Describe 'Windows home server: llama.cpp offload autocalc' {
    It 'aloca todas as camadas na GPU quando o modelo cabe na VRAM' {
        $p = Get-BootstrapLlamaOffloadPlan -VramGB 24 -RamGB 32 -ModelSizeGB 12 -TotalLayers 80
        [int]$p.gpuLayers | Should Be 80
        [bool]$p.lowVram | Should Be $false
    }
    It 'faz split hibrido proporcional com margem quando o modelo excede a VRAM' {
        $p = Get-BootstrapLlamaOffloadPlan -VramGB 8 -RamGB 32 -ModelSizeGB 20 -TotalLayers 80
        ([int]$p.gpuLayers -gt 0 -and [int]$p.gpuLayers -lt 80) | Should Be $true
        [bool]$p.lowVram | Should Be $true
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
}
```

- [ ] **Step 2 — rodar e ver falhar.**

- [ ] **Step 3 — implementar `Get-BootstrapLlamaOffloadPlan`** (porta determinística do pseudo-código do doc):
  - `vramUtil = VramGB - 1` (margem SO).
  - cabe inteiro → `{ gpuLayers=TotalLayers; cpuThreads=1; lowVram=$false; insufficient=$false }`.
  - cabe em VRAM+RAM → `gpuLayers = [int]($TotalLayers * (vramUtil/ModelSizeGB)) - 2` (mín. 1), `cpuThreads = núcleos físicos`, `lowVram=$true`.
  - senão → `{ insufficient=$true }`.

- [ ] **Step 4 — `Ensure-BootstrapLlamaCppServer`**: baixa release oficial prebuilt do `llama.cpp` (GGUF runtime; sem build local), grava `assets/home-server/run-llamacpp.ps1` parametrizado pelo plano, expõe `--port 8080` com `--flash-attn`. Fallback automático (decrementa `--n-gpu-layers` em caso de Out-of-VRAM). `Kind 'llamacpp-server'`, `-Optional $true`, `riskLevel='experimental'`, `RequiresNetwork=$true`. Wire no dispatcher + audit (probe do binário).

- [ ] **Step 5 — rodar e ver passar.** **Step 6 — commit:** `feat(server): llamacpp-server opt-in + autocalc de offload`.

---

### Task 3: Componente `homelab-stack` (Docker via WSL2, em camadas)

**Files:** `bootstrap-tools.ps1`; `assets/home-server/docker-compose.homelab.yml`; `assets/home-server/docker-compose.extras.yml`; `tests/bootstrap-home-server.tests.ps1`

Stack em duas camadas:
- **Core (padrão, leve):** Portainer CE (dashboard de gestão — camada amigável), Jellyfin (mídia), **Syncthing** (Drive leve), Vaultwarden (cofre), Uptime Kuma (monitor + alertas). Pi-hole entra como **opt-in** (muda DNS da LAN). 
- **Extras (opt-in pesado):** Nextcloud (+db), Grafana + Prometheus + Node Exporter, Paperless-ngx, n8n — em `docker-compose.extras.yml`, ativados por flag (`--component homelab-extras` ou variável de seleção do componente).

- [ ] **Step 1 — teste falhando:**

```powershell
Describe 'Windows home server: homelab-stack' {
    It 'declara homelab-stack dependente de wsl-core e docker' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('homelab-stack') | Should Be $true
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
    It 'nenhum compose embute segredos em texto puro' {
        foreach ($f in @('docker-compose.homelab.yml','docker-compose.extras.yml')) {
            $p = Join-Path (Split-Path -Parent $scriptPath) ("assets/home-server/{0}" -f $f)
            (Get-Content $p -Raw) | Should Not Match 'Bearer\s+[A-Za-z0-9]|PASSWORD=\S+|password:\s*\S+!'
        }
    }
}
```

- [ ] **Step 2 — rodar e ver falhar.**

- [ ] **Step 3 — criar os dois composes**:
  - `docker-compose.homelab.yml` (core): Portainer (`:9000`, socket docker `no-new-privileges`), Jellyfin, Syncthing, Vaultwarden, Uptime Kuma. `restart: unless-stopped`, volumes persistentes, **valores sensíveis só via `.env`/variável** (nunca inline). Vaultwarden e Portainer só atrás de Tailscale (documentar: não expor HTTP cru na WAN).
  - `docker-compose.extras.yml` (opt-in): Nextcloud(+db), Grafana, Prometheus, Node Exporter, Paperless-ngx, n8n.

- [ ] **Step 4 — `Ensure-BootstrapHomelabStack`**: garante WSL2/Docker prontos, copia o(s) compose(s) para diretório de estado, gera `.env` (senhas via secrets manifest / geradas e registradas), roda `docker compose up -d` no WSL2 (reusar `Invoke-BootstrapWslBashCommand`); aplica `extras` só se selecionado. Registrar arquivos via `Register-BootstrapFileChange`. Wire dispatcher + audit (probe `docker ps` dos serviços core). `Get-BootstrapHomelabComposePath` resolve o destino. **Uptime Kuma + Portainer** dão o monitoramento/“self-healing” amigável (em vez de daemon novo).

- [ ] **Step 5 — rodar e ver passar.** **Step 6 — commit:** `feat(server): homelab-stack via Docker/WSL2 (core leve + extras opt-in)`.

---

### Task 4: Componente `hermes-remote` (Hermes + acesso remoto)

**Files:** `bootstrap-tools.ps1`; `tests/bootstrap-home-server.tests.ps1`

- [ ] **Step 1 — teste falhando:**

```powershell
Describe 'Windows home server: hermes-remote' {
    It 'declara hermes-remote dependente de hermes e tailscale' {
        $catalog = Get-BootstrapComponentCatalog
        $catalog.Contains('hermes-remote') | Should Be $true
        @($catalog['hermes-remote'].DependsOn) -contains 'hermes' | Should Be $true
        @($catalog['hermes-remote'].DependsOn) -contains 'tailscale' | Should Be $true
    }
}
```

- [ ] **Step 2 — rodar e ver falhar.**

- [ ] **Step 3 — `Ensure-BootstrapHermesRemote`**: reusar `Ensure-Hermes`, garantir Tailscale (auth-key via secrets/env, nunca hardcode; registrar), e ajustar `.hermes/opencloud.json` (via `Ensure-HermesProjectOpenCloudConfig`) para o modo de atuação remota (bind na interface Tailscale, não em `0.0.0.0` público). Aplicar `--repair-mcp` ao config do Hermes (já é alvo desde commit recente) para garantir launch correto. `Kind 'hermes-remote'`. Wire dispatcher + audit.

- [ ] **Step 4 — rodar e ver passar.** **Step 5 — commit:** `feat(server): hermes-remote (Hermes + Tailscale para atuacao remota)`.

---

### Task 5: Os 6 perfis

**Files:** `bootstrap-tools.ps1`; `tests/bootstrap-home-server.tests.ps1`

- [ ] **Step 1 — teste falhando** (resolução dos 6 perfis e seus itens):

```powershell
Describe 'Windows home server: profiles' {
    $expected = @{
        'server-llm'                 = @('ollama','os-slim-server')
        'server-homelab'             = @('homelab-stack','tailscale')
        'server-homelab-hermes'      = @('homelab-stack','tailscale','hermes-remote')
        'server-llm-hermes'          = @('ollama','hermes-remote','os-slim-server')
        'server-llm-homelab'         = @('ollama','homelab-stack','tailscale','os-slim-server')
        'server-llm-homelab-hermes'  = @('ollama','homelab-stack','tailscale','hermes-remote','os-slim-server')
    }
    It 'define os 6 perfis com os componentes corretos' {
        $profiles = Get-BootstrapProfileCatalog
        foreach ($name in $expected.Keys) {
            $profiles.Contains($name) | Should Be $true
            foreach ($item in $expected[$name]) { @($profiles[$name].Items) -contains $item | Should Be $true }
        }
    }
    It 'todos os itens dos perfis existem no catalogo de componentes' {
        $catalog = Get-BootstrapComponentCatalog; $profiles = Get-BootstrapProfileCatalog
        foreach ($name in $expected.Keys) {
            foreach ($item in @($profiles[$name].Items)) { $catalog.Contains($item) | Should Be $true }
        }
    }
}
```

- [ ] **Step 2 — rodar e ver falhar.**
- [ ] **Step 3 — adicionar os 6 `New-BootstrapProfileDefinition`** ao `Get-BootstrapProfileCatalog`, descrições pt-BR.
- [ ] **Step 4 — rodar e ver passar** + rodar `tests/bootstrap-tools.profiles.tests.ps1` (não quebrar resolução existente).
- [ ] **Step 5 — commit:** `feat(server): 6 perfis de servidor caseiro Windows`.

---

### Task 6: Surface CLI/UI e dry-run

**Files:** `bootstrap-tools.ps1` (contrato), `bootstrap-ui.ps1` (se necessário); testes de contrato

- [ ] **Step 1 — verificar** que `-UiContractJson` lista os 6 perfis (provavelmente automático). Teste: contrato contém `server-llm-homelab-hermes`.
- [ ] **Step 2 — dry-run** de cada perfil sem mutar host:
  `.\bootstrap-tools.ps1 -Profile server-llm -DryRun -NonInteractive` (e os outros 5) devem resolver componentes sem erro.
- [ ] **Step 3 — agrupar a família** "Servidor caseiro" na UI (se o contrato precisar de rótulo/página). Caso o contrato derive perfis automaticamente, só validar render.
- [ ] **Step 4 — commit:** `feat(server): expoe perfis de servidor no contrato CLI/UI`.

---

### Task 7: Docs + verificação final

- [ ] Atualizar `README.md` (pt-BR) com a família de perfis de servidor e a nota "mantém Windows, não é Umbrel".
- [ ] Rodar suíte completa (`Invoke-Pester -Path .\tests`) — 0 falhas.
- [ ] Parser check nos 3 `.ps1`.
- [ ] `git diff --check`.
- [ ] Atualizar a allow-list/gate de qualidade se algum novo `Ensure-*` mutar host sem `Register-BootstrapChange` direto (preferir sempre registrar).

## Ordem de commits sugerida

1. os-slim-server
2. llamacpp-server + autocalc
3. homelab-stack
4. hermes-remote
5. 6 perfis
6. contrato CLI/UI
7. docs + verificação

## Riscos e mitigação

- **Enxugar SO** mexe em serviços — risco de "quebrar" Search/telemetria que o usuário quer. Mitigação: tudo reversível via `-Rollback`; nada de Explorer/Update core; auditável.
- **homelab-stack** depende de WSL2+Docker saudáveis; falhas devem ser não-fatais com mensagem clara (reusar padrão `AllowFailureWhenNotAdmin`/try-catch).
- **Segredos** (Tailscale authkey, senhas dos serviços): sempre via secrets manifest/env, nunca no compose/script; rollback registrado.
- **llama.cpp**: prebuilt release, opt-in, experimental; sem build toolchain no host.

## Questões abertas para a revisão

1. Modo 6 deve **enxugar o SO** também? (incluí por consistência; o spec só marcou 1/4/5).
2. Nome da família: `server-*` (proposto) vs `homeserver-*`?
3. **Resolvido:** Pi-hole fica **opt-in** dentro do stack (muda DNS da LAN). Confirmar.
4. **Resolvido:** "Drive" padrão = **Syncthing** (leve, casa com baixo RAM); Nextcloud vira extra opt-in. Confirmar.
5. **Novo:** incluir **Portainer + Uptime Kuma** no core por padrão (recomendado, camada amigável) — ok? Algum deles deve ser opt-in?
6. **Novo:** os extras pesados (Grafana/Prometheus, Paperless-ngx, n8n) — entrar via um único `--component homelab-extras`, ou componentes separados por serviço?
