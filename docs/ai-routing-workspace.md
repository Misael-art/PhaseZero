# 9Router e Odysseus

PhaseZero integra dois componentes distintos:

- **9Router**: gateway OpenAI-compatible local. Consolida providers autorizados, combos e fallback.
- **Odysseus**: workspace web agnóstico de IA. Consome endpoints locais/remotos; não é distribuição Linux.

Na UI nativa, a página **Proxies IA** reúne ambos os gateways, os cards de ciclo de vida dos proxies OpenAI-compatible (`kimi`, `qwen`, `deeps`, `mimo`), a autenticação por navegador e a sincronização com IDEs, com polling passivo de `pz ai proxies detailed-status`.

## 9Router

```bash
linux/pz ai 9router install
linux/pz ai 9router status
linux/pz ai 9router dashboard
linux/pz ai 9router provider status
linux/pz ai 9router combo sync
linux/pz ai 9router client status
linux/pz ai 9router check-update
linux/pz ai 9router update
```

Controles PhaseZero:

- pacote npm exato; `dist.integrity` comparado antes da instalação;
- staging, troca atômica, health check e rollback;
- bind exclusivo em `127.0.0.1:20128`;
- ponte privada Unix para workloads Podman; sem bind adicional em LAN;
- senha, JWT e API key aleatórios; arquivos `0600`; dados `0700`;
- `REQUIRE_API_KEY=true`; request logs desativados;
- watchdog passivo a cada dez minutos. Testes reais de provider somente sob demanda;
- telemetria do status resumida. IDs de conta, prompts e chaves não saem no inventário.

Executar cliente com perfil temporário:

```bash
phasezero-9router-run codex
phasezero-9router-run claude
phasezero-9router-run opencode
```

Wrapper injeta endpoint e chave apenas no processo filho. Configurações globais de cada agente não são sobrescritas. Uso de OAuth, assinaturas e modelos deve respeitar termos e cotas do provider. Fallback não significa evasão de limites.

## Odysseus

```bash
linux/pz ai odysseus install
linux/pz ai odysseus status
linux/pz ai odysseus open
linux/pz ai odysseus check-update
linux/pz ai odysseus update
linux/pz ai odysseus backup
linux/pz ai odysseus doctor
```

Upstream não publica releases ou tags. PhaseZero resolve `dev`, clona repositório oficial, exige SHA estável durante clone e fixa commit. Manifesto registra origem, commit e tree. Commit não assinado permanece identificado; atualização nunca ocorre automaticamente.

Deploy usa Podman rootless e Compose. UI, ChromaDB, SearXNG e ntfy ficam em loopback. Imagens dependentes são resolvidas e travadas por digest. Limites padrão preservam recursos do Steam Deck: 6 GiB/5 CPUs para app, 2 GiB para ChromaDB, 1 GiB para SearXNG e 256 MiB para ntfy. Autenticação é obrigatória; bypass localhost fica desligado; `no-new-privileges` fica ativo; socket Docker não é montado. Segredos residem em `~/.config/phasezero/odysseus/odysseus.env`, modo `0600`. Comando `credentials-path` revela somente caminho.

Patch local registrado remove `setup_requires` de Torch/CUDA usado somente ao construir wheels Python do Real-ESRGAN. Isso evita baixar toolchain NVIDIA num host AMD. Manifesto registra SHA-256 do diff junto ao tree upstream.

Odysseus recebe 9Router como endpoint OpenAI-compatible quando chave gerenciada existe. Um proxy interno no container atravessa socket Unix `0600`; 9Router continua preso ao loopback do host. Doctor valida socket e rota. Dashboard permite cadastrar outro endpoint sem acoplar workspace a provider.

Odysseus inclui console administrativo, execução de ferramentas e armazenamento de arquivos. Não publicar porta 7000 diretamente. Para acesso remoto, usar proxy TLS ou rede privada, `SECURE_COOKIES=true` e origem CORS exata.

## Atualizações

```bash
linux/pz updates check
linux/pz updates install-service
linux/pz updates apply 9router
linux/pz updates apply odysseus
linux/pz updates apply codex-desktop
```

Inventário agrega PhaseZero, canais instalados, apps IA, frontends Windows, 9Router, Odysseus e pacotes Arch pendentes. Timer diário verifica e notifica; nunca aplica automaticamente.

Arch exige upgrade completo. PhaseZero não executa atualização parcial. Aplicação do host permanece explícita:

```bash
phasezero-admin pacman -Syu
```

Self-update PhaseZero mantém plano e confirmação próprios:

```bash
linux/pz self-update plan
linux/pz self-update apply <plan-id> <token>
```
