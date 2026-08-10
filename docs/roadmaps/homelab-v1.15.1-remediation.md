# Roadmap canônico — Homelab v1.15.1

> Fonte operacional única para agentes humanos e de IA.
>
> Este documento coordena implementação. Não prova conclusão. Commits, testes,
> CI, artefatos e validações são as provas.

## Metadados

| Campo | Valor |
|---|---|
| Status | Planejado; implementação ainda não aceita como concluída |
| Última verificação | 2026-08-07, America/Sao_Paulo |
| Repositório | `/mnt/sdcard/Projects/PhaseZero` |
| Base observada | `origin/main` em `31642be1965513932ad338051c51c4c236092490` |
| Release instalada observada | `phasezero-control-center 1.14.7-1` |
| Release pública observada | `v1.14.7` |
| Branch rejeitada | `codex/homelab-appliance` em `d24b233` |
| PR rejeitada | `#36`, aberta, conflitante, CI vermelha |
| Tag reservada | `v1.15.0`; não mover, apagar ou recriar |
| Release alvo | `v1.15.1`, somente a partir de `main` verde |
| Branch de remediação | `codex/homelab-v1151-remediation` |

Dados acima são snapshot, não pressupostos eternos. Todo agente deve revalidá-los.

## Missão

Entregar Homelab PhaseZero coeso, resiliente, seguro e amigável sem implantar os
workloads no host de desenvolvimento. Entrega inclui fundação, perfis, operações,
Player, segurança, backup/restore, Resource Governor, testes, documentação, merge,
release e validação do pacote instalado.

Nenhum agente pode reduzir “funcional” a presença de arquivo, import smoke, mock ou
Compose válido. Comportamento exige prova comportamental proporcional.

## Ordem das fontes de verdade

Quando houver conflito, usar esta ordem:

1. Estado vivo de `main`, GitHub, CI, releases, pacote e host.
2. Este roadmap versionado.
3. Código e schemas versionados no repositório.
4. Findings do reviewer acompanhadas de reprodução.
5. Documentação histórica e `ai-memory`.
6. Resumos, chats e retornos de agentes apenas como contexto.

O arquivo histórico `tool_fcfd9c5d4001YpNoFLb9Fx0EOq` não é prompt puro. O
contrato original estava entre as linhas 642 e 1708; o restante contém conversa e
avaliações. Nunca tratar as 1908 linhas inteiras como especificação.

## Regras permanentes anti-poluição

### Antes de alterar

1. Ler `AGENTS.md` e referências integralmente.
2. Consultar `ai-memory` para Homelab, release, Docker security, worktree bleed e
   conflito de recursos com WinVM.
3. Revalidar Git, branches, worktrees, tags, PR, CI e releases.
4. Registrar arquivos modificados e untracked antes do trabalho.
5. Verificar processos/agentes concorrentes e worktrees existentes.
6. Criar worktree dedicado. Nunca reutilizar worktree de WinVM ou outra frente.
7. Executar baseline dos gates afetados antes da primeira mudança.

### Durante alterações

- Uma responsabilidade por commit.
- Nunca usar `git add -A` ou staging indiscriminado.
- Nunca sobrescrever, limpar, stashar ou commitar WIP alheio.
- Nunca force-push.
- Nunca editar tag antiga.
- Nunca copiar runtime manualmente para `/usr/lib/phasezero`.
- Nunca introduzir `latest` como dependência estável.
- Nunca adicionar segredo, token, senha ou material privado ao Git, logs ou testes.
- Alteração fora do escopo exige prova da dependência e registro no handoff.
- Arquivos WinVM ficam fora de escopo, salvo interface mínima do Resource Governor
  aprovada por teste de contrato.
- Gate vermelho interrompe avanço da fase. Corrigir causa; não mascarar.
- Falha “preexistente” exige reprodução em `main` limpo.

### Depois de cada unidade de trabalho

1. Executar testes específicos e regressões afetadas.
2. Executar `git diff --check`.
3. Revisar diff por segredos, paths do host e mudanças não relacionadas.
4. Atualizar somente as seções `Estado vivo` e `Ledger de execução` deste roadmap.
5. Produzir handoff no formato definido no fim do documento.

## Limites operacionais do host

Até a release ser publicada e verificada:

- Não executar `homelab apply`, `homelab up` ou `docker compose up` no host real.
- Não criar, apagar ou reiniciar containers e serviços reais.
- Não tocar no container `ai-memory` existente.
- Não instalar ou configurar Ollama, Hermes, OpenClaw, Dify, n8n ou Tailscale.
- Não alterar firewall, GRUB, `grubenv`, SDDM, WinVM, mounts ou discos.
- Não reiniciar host ou guest.
- Não usar `rsync`, `cp` ou symlinks para atualizar runtime privilegiado.
- Testes Docker executam somente em CI descartável com projeto, portas, volumes e
  cleanup próprios.

Após release, somente pacote PhaseZero pode ser instalado. Workloads continuam
desligados.

## Decisões arquiteturais fechadas

### Runtime e identidade

- Runtime instalado vem de `/usr/lib/phasezero`.
- Serviços usam usuário/grupo alvo explícitos; nunca criam estado em `/root`.
- `HOME` e paths XDG são explícitos.
- Estado e operações têm schema versionado, lock atômico e IDs persistentes.
- Erro essencial produz falha e estado degradado; nunca sucesso aparente.

### Docker e imagens

- Nenhum serviço recebe `/var/run/docker.sock` diretamente.
- Portainer usa socket proxy de privilégio mínimo ou fica indisponível.
- Imagem estável usa manifest-list digest ou lock por plataforma.
- Adapter experimental pode usar versão fixa resolvida para digest, nunca `latest`.
- Compose renderizado não contém segredos.
- Redes internas, healthchecks, readiness, limites, rotação de logs,
  `no-new-privileges` e `cap_drop` são padrão quando suportados.

### Segredos e backup

- Aplicações recebem referências, não segredos copiados entre arquivos.
- Entrada de segredo usa UI protegida ou stdin/fd; nunca argv.
- Backup de segredos exige formato autenticado, KDF, rotação e teste de senha
  incorreta. Implementação requer ADR antes do código.
- Restore sempre oferece `--plan`, valida antes de escrever, faz backup prévio e
  rollback automático após falha parcial.

### Maturidade

- Estável somente após E2E representativo.
- Integração que exige credencial/canal real permanece preview até teste do operador.
- Recursos sem prova ficam `preview`, `experimental` ou `blocked` no status e UI.
- ZeroClaw, NanoClaw e CrewAI permanecem experimentais/templates.
- Vellum, memU e MimiClaw permanecem integração externa/documentação até backend
  local auditado.

## Arquitetura-alvo

```text
Clientes e canais
      ↓
Acesso autenticado: loopback, Tailscale ou proxy TLS
      ↓
Um gateway: Hermes | OpenClaw | ZeroClaw
      ↓
PhaseZero Policy Broker
      ↓
9Router
      ↓
Ollama local | providers externos
      ↓
Memória, workflows e workers isolados
```

Invariantes:

- Um gateway principal por perfil.
- 9Router roteia modelos; não executa ação privilegiada.
- `ai-memory` é memória canônica PhaseZero.
- n8n não recebe shell irrestrito ou Docker socket.
- OpenHands executa por tarefa em sandbox efêmero.
- LangGraph assume fluxos críticos, persistência, retry e aprovação humana.
- CrewAI fornece templates; não duplica runtime LangGraph.

## Perfis públicos

| Perfil | Objetivo | Componentes principais | Maturidade inicial |
|---|---|---|---|
| `assistant-private` | Assistente local privado | Hermes, 9Router, Ollama, ai-memory, OpenWebUI opcional | Preview até E2E |
| `assistant-multichannel` | Canais externos supervisionados | Hermes; OpenClaw avançado; pairing e allowlist | Preview |
| `automation` | Workflows auditáveis | n8n, PostgreSQL, LangGraph | Preview |
| `ai-studio` | Dify isolado | Dify, DB, Redis, vector store, 9Router/Ollama | Pesado; desligado |
| `developer` | Coding assistido | Aider padrão, OpenHands sob demanda | Preview |
| `edge` | Gateway leve supervisionado | ZeroClaw, modelo remoto via 9Router | Experimental |

Nenhum perfil pesado sobe por padrão. Host sem orçamento recebe `blocked` com razão e
plano de impacto.

## Interfaces públicas mínimas

CLI deve manter stdout JSON puro e logs em stderr:

```text
pz server homelab profiles --json
pz server homelab plan --profile <id> --json
pz server homelab apply --profile <id> --json
pz server homelab status --json
pz server homelab verify --json
pz server homelab repair --json
pz server homelab backup --json
pz server homelab restore --plan --json
pz server homelab rollback --operation-id <id> --json
pz server homelab player
pz server homelab resource-status --json
pz server homelab security-audit --json
```

Contratos obrigatórios:

- `schemaVersion` em todos documentos persistidos ou públicos.
- Exit codes documentados.
- Paths canônicos.
- Lock cross-process.
- Operation ID persistente.
- Apply, repair, cancel, attach, resume e rollback idempotentes.
- Redação centralizada de segredos.

## Fases e gates

### Fase 0 — Baseline e recuperação da rejeição

Objetivo: estabelecer base limpa e reproduzível.

- Criar worktree da `origin/main` atual.
- Criar `codex/homelab-v1151-remediation`.
- Extrair requisitos históricos para matriz versionada.
- Reproduzir ShellCheck, Pester e demais falhas da PR #36.
- Portar seletivamente código válido; não carregar metadata release prematura.
- Corrigir bugs confirmados: ShellCheck, Pester, `QFileDialog`, bloqueios GUI e restore
  com confirmação cega.
- Abrir novo PR que substitui #36. Fechar #36 somente após novo PR existir.

Gate de saída:

- Baseline documentado.
- CI existente totalmente verde no novo PR.
- Nenhum claim de feature nova sem teste.
- Tag `v1.15.0` intacta.

### Fase 1 — Fundação operacional

Objetivo: runtime, identidade, configuração e lifecycle confiáveis.

- Usuário/grupo, HOME e XDG corretos.
- Configuração e `accessMode` persistentes com migração idempotente.
- `up/down/restart/update/repair/cancel/resume` no mesmo conjunto de serviços.
- Lock atômico e recuperação de operação interrompida.
- Status verdadeiro: installed, configured, active, healthy, ready, degraded,
  reasons, endpoints, versões, digests, orçamento, conflitos e rollback.
- Mídia via XDG pt-BR, permissões e mounts read-only.

Gate de saída:

- Nada escrito em `/root`.
- Segunda execução idempotente.
- Crash→resume e cancel seguros.
- Estado corrompido falha fechado.
- Testes shell/Python/Pester afetados verdes.

### Fase 2 — Compose e serviços

Objetivo: stacks completas e endurecidas.

- Redes internas e exposição loopback por padrão.
- Healthchecks e readiness reais.
- Digests/lock por plataforma.
- Socket proxy para Portainer.
- Jellyfin com mídia read-only e `/dev/dri` somente após preflight.
- Nextcloud com Redis, cron e trusted proxies.
- Paperless com Valkey e ingest/export.
- n8n com PostgreSQL, encryption key e controles SSRF/nodes.
- Prometheus com configuração; Grafana com datasource/dashboard/alertas.
- Uptime Kuma provisionado idempotentemente.

Gate de saída:

- `docker compose config` em todos perfis.
- Nenhuma porta pública inesperada.
- Nenhum socket direto ou segredo renderizado.
- Integração CI descartável prova health→degraded→repair.

### Fase 3 — Backup e restore

Objetivo: backup consistente e restore reversível.

- Preflight recusa `/`, `$HOME`, symlink escape e destino dentro da origem.
- Quiesce ou dumps nativos para PostgreSQL, MariaDB e SQLite.
- Staging seguro, manifestos, versões, digests, checksums e timestamps ISO.
- Segredos cifrados conforme ADR.
- Retenção configurável e adaptador offsite opcional.
- Restore plan, validação de compatibilidade, limpeza controlada, backup prévio,
  rollback automático e relatório.

Gate de saída:

- CI prova backup→destruição de fixture→restore→dados iguais.
- Checksum inválido, senha incorreta e versão incompatível falham fechados.
- Falha parcial restaura estado anterior.

### Fase 4 — Perfis e Resource Governor

Objetivo: seleção amigável com orçamento honesto.

- Implementar os seis perfis públicos.
- Inventariar CPU, MemAvailable, swap, GPU/VRAM, disco, I/O e temperatura.
- Classes: always-on-light, local-inference, automation, heavy-studio,
  coding-worker e winvm.
- WinVM tem prioridade configurável; conflito gera plano de impacto.
- Suspensão é graciosa, persistida e retomável. Nunca kill silencioso.

Gate de saída:

- Host limitado recusa perfil pesado com razão verificável.
- Falha de stop aparece no status.
- Resume correto após término da WinVM.
- Nenhum arquivo WinVM alterado sem teste de contrato.

### Fase 5 — AI e Policy Broker

Objetivo: adapters mínimos e enforcement real.

- `ai-memory`: digest, mounts mínimos, histórico read-only, sem `$HOME`, limites,
  healthcheck e migração preservando dados.
- Ollama: loopback, escolha explícita, espaço, progresso/cancel/resume e benchmark.
- Hermes: versão/checksum, pairing, allowlist, aprovação manual e workspace mínimo.
- OpenClaw: sandbox total, install policy fail-closed, skills/plugins desligados.
- Dify, OpenHands, Aider, LangGraph e ZeroClaw conforme maturidade declarada.
- Policy Broker: identidade, classificação de ação, aprovação, secret references,
  audit trail, quotas, rate limits, timeouts, kill switch, egress, denylist,
  symlink protection e idempotency keys.

Antes do código do broker:

- Criar ADR de schemas, storage, aprovação, auditoria, expiração e integração.
- Adicionar testes de contrato que falhem antes da implementação.

Gate de saída:

- SSH, credenciais cloud, `.env` e outros projetos invisíveis aos adapters.
- Ação não confiável bloqueada por padrão.
- Nenhum segredo em stdout, stderr, logs, estados ou snapshots.
- Integrações sem E2E real permanecem preview/experimental.

### Fase 6 — Homelab Player

Objetivo: experiência gráfica não bloqueante e recuperável.

Fluxo:

```text
Discover → Select → Preflight → Configure → Security review
→ Plan → Confirm → Apply → Validate → Done
```

- PySide6 não modal e singleton.
- QProcess/QThreadPool para toda operação externa.
- stdout/stderr separados, timeout e proteção contra double emit.
- Wizard por perfil, custos, orçamento, privacidade, canais e segredos protegidos.
- Operation ID, attach, resume, cancel, repair e rollback.
- Close event interrompe polling, não operação persistente.
- Restore nunca passa `--yes` automaticamente.
- Diagnóstico exportado sem segredos.

Gate de saída:

- Import, singleton, lifecycle, timeout, close, cancel, attach, resume, repair,
  rollback e secret redaction testados.
- Teste prova event loop responsivo durante subprocesso lento.

### Fase 7 — CLI e schemas

Objetivo: compatibilidade e contratos públicos finais.

- Consolidar comandos mínimos listados acima.
- Publicar JSON schemas.
- Documentar exit codes, migração e compatibilidade.
- Garantir JSON puro e idempotência.

Gate de saída:

- Contract tests shell/Python/Pester.
- Snapshots não contêm valores específicos do host ou segredos.

### Fase 8 — Testes e CI

Objetivo: provar resiliência sem tocar host real.

Jobs obrigatórios:

- `homelab-shell-test`
- `homelab-python-test`
- `compose-validate`
- `homelab-integration-disposable`
- `security-secret-scan`
- `package-smoke`

Fault injection mínimo:

- Docker indisponível.
- Imagem ausente ou pull interrompido.
- Disco cheio simulado.
- Porta ocupada.
- Banco ou serviço unhealthy.
- Estado corrompido.
- Permissão negada.
- Timeout e processo morto.
- Rede offline.
- Segredo ausente.
- Versão incompatível.

Gate de saída:

- Python completo.
- `tests/runner.sh`.
- Pester.
- `bash -n` em todos scripts.
- ShellCheck 0.9.0 e 0.11.x com os mesmos excludes do CI.
- `git diff --check`.
- Compose e JSON schemas válidos.
- Gitleaks/secret scan.
- Package build e install-root test.
- Nenhum `continue-on-error` em gate obrigatório.

### Fase 9 — Documentação

Objetivo: operação e limitações compreensíveis sem contexto de chat.

- Arquitetura e perfis.
- Matriz de suporte e recursos.
- Threat model e policy de skills/plugins.
- Segredos, rede e acesso.
- Backup, restore e disaster recovery.
- Governor e conflitos WinVM.
- Operação sem UI, troubleshooting e rollback.
- Limitações honestas e release notes.

Gate de saída:

- Documentação corresponde ao comportamento testado.
- Nenhum uso de “pronto”, “seguro”, “privado” ou “funcional” sem prova citada.

### Fase 10 — Merge, release e pacote

Objetivo: publicar v1.15.1 de forma reproduzível.

1. CI obrigatória totalmente verde no PR.
2. PR documenta arquitetura, riscos, migrações, testes, limitações e rollback.
3. Merge em `main`.
4. Atualizar `main` e confirmar árvore limpa.
5. Executar fluxo canônico `packaging/release.sh 1.15.1`.
6. Criar tag anotada `v1.15.1`; preservar `v1.15.0`.
7. Exigir CI, release e gitleaks verdes.
8. Confirmar sete assets:
   - source tarball
   - `.deb`
   - `.rpm`
   - `.pkg.tar.zst`
   - `.AppImage`
   - `.flatpak`
   - `SHA256SUMS-1.15.1`
9. Baixar assets e verificar checksums e conteúdo básico dos pacotes.
10. Entregar comando administrativo ao usuário. Não esperar Polkit em background.

Comando esperado, somente após SHA256 confirmado:

```bash
phasezero-admin pacman -U --noconfirm <phasezero-control-center-1.15.1-1-any.pkg.tar.zst>
```

Depois da confirmação do usuário, validar somente:

- versão;
- imports UI;
- arquivos e checksum do runtime instalado;
- `profiles --json`;
- `status --json`;
- `plan --profile assistant-private --json`;
- dry-runs dos outros perfis.

Containers, serviços, listeners, mounts, `grubenv` e WinVM devem permanecer iguais.

## Matriz de evidência obrigatória

Cada requisito precisa de uma linha. Não aceitar relatório narrativo sem matriz.

| ID | Requisito | Implementação | Teste comportamental | Prova CI | Estado | Limitação |
|---|---|---|---|---|---|---|
| HL-F0-001 | Baseline reproduzível | Worktree dedicado + 19 commits por fase | Suíte hermética exit 0; pytest 437; smoke | `homelab-*` verdes em `main` (run `31257317111`, merge `3cb05fb`) | verified | — |
| HL-RUN-001 | Estado nunca em `/root` | `boot-prepare`/ops com HOME/XDG explícitos | `tests/linux-homelab.sh` (identity; boot-prepare) | homelab-shell-test | verified | — |
| HL-CMP-001 | Nenhum Docker socket direto | `socket-proxy` (read-only, allowlist) + Portainer via `DOCKER_HOST` | Suíte: compose pins/binds/hardening; compose-validate assina `socket-proxy` ro=true apenas | compose-validate | verified | — |
| HL-BKP-001 | Restore reversível | manifest schemaVersion 2 + verify-then-apply + snapshot prévio `<source>.pre-restore` + rollback automático em falha parcial (`rollbackApplied`); `status` ignora `*.pre-restore` | Suíte: tamper fail-closed, restore sem `--yes` recusa, verify antes de aplicar, falha parcial com volume envenenado → estado prévio devolvido; E2E Docker: backup→destroy→restore→igualdade byte a byte | homelab-shell-test + homelab-integration-disposable (PR #38, run `31265085899` success) | verified | Rollback cobre dados de volume; `.env`/segredos fora do manifest |
| HL-GOV-001 | WinVM gera suspensão graciosa | governor: `winvm-status`/`winvm-suspend [--dry-run]`/`winvm-resume`; boundary `PZ_HOMELAB_WINVM_STATUS_FILE` ou `pz windows-vm status --json`; `winvmMB` (default 2048) descontado do orçamento; suspensão só via QGA (`PZ_HOMELAB_WINVM_SUSPEND_CMD`, default `guest-login shutdown --json`); `killUsed:"never"`; nenhum arquivo da VM tocado | Suíte: seção "winvm contract" (idle/active via stub, fail-closed com guest ativa, plano de impacto, dry-run sem efeito, execução capturada, no-op idle, resume) | homelab-shell-test (PR #38, run `31265085899` success) | verified | Maturação real da suspensão depende de guest Windows real (não exercitada em CI) |
| HL-SEC-001 | Segredos ausentes das saídas | repair gera `.env` sem leak; redação no status | Suíte: valor secreto ausente do JSON de repair | security-secret-scan (gitleaks) verde em `main` e no release | verified | — |
| HL-UI-001 | Player não bloqueia event loop | async QProcess; separado stdout/stderr; timeout | 13 testes do player (offscreen) incl. spawn/close/timeout | homelab-python-test | verified | — |
| HL-UI-002 | Interface leiga com revelação progressiva | modo simplificado padrão; comandos/logs/JSON recolhidos; páginas visuais Windows VM, Waydroid, Servidor e Saúde; modo avançado global | pytest 428 + 9 subtestes; UI smoke 27; provision 226/0; QA offscreen de 6 superfícies | PR #48: CI `31327861952` e gitleaks verdes; `main` `31329472867` verde | verified | Sliders de recursos são somente leitura enquanto backend não expõe mutação tipada segura |

Adicionar IDs, nunca reutilizar ID para requisito diferente. Estados permitidos:
`pending`, `in_progress`, `blocked`, `verified`, `deferred`.

## Estado vivo

Atualizar esta seção no início e fim de cada sessão. Não alterar metadados históricos
sem evidência.

| Item | Estado atual | Verificado por | Data |
|---|---|---|---|
| `main` | `31642be`, alinhada com `origin/main` | `git status`, `ls-remote` | 2026-08-07 |
| `main` | `c11155b`, alinhada com `origin/main` | `git status`, `ls-remote` | 2026-08-08 |
| PR #38 | mergeada via squash (`fc7ede8`); branch local/remota apagadas; worktree `pz-homelab-f9` preservado | `gh pr view 38`, `git ls-remote`, `git worktree list` | 2026-08-08 |
| CI pós-merge | run `31266597239` (ci) + `31266597234` (gitleaks) success em `main` | `gh run view` | 2026-08-08 |
| Pendências Fase 2/3/9 | implementadas; CI run `31265085899` 14/14 success | `gh run view 31265085899` | 2026-08-08 |
| CI homelab | + job `homelab-integration-disposable` (E2E Docker real, sudo, seed→backup→verify→destroy→restore→igualdade) | ci.yml, run `31265085899` | 2026-08-08 |
| Suíte hermética | exit 0 incluindo "winvm contract" e "restore partial failure rolls back" | bash | 2026-08-08 |
| Worktree pendências | `pz-homelab-f9` (branch `codex/homelab-f9`, HEAD `ce1f072`) preservado | git worktree list | 2026-08-08 |
| PR #36 | fechada (substituída) | `gh pr close 36` | 2026-08-08 |
| PR novo | `#37` aberta; `codex/homelab-v1151-remediation` -> `main` | `gh pr view 37` | 2026-08-08 |
| Branch de remediação | mergeada via PR #37; branch local e remota apagadas; worktree `pz-homelab-v1151` preservado | `gh pr view 37`, `git ls-remote` | 2026-08-08 |
| Latest release | `v1.15.1` publicada (7 assets + SHA256SUMS) | `gh release view v1.15.1` | 2026-08-08 |
| Pacote host | `1.15.1-1` instalado via `bigsudo pacman -U` (assets re-baixados, `SHA256SUMS-1.15.1` 7/7 SUCESSO) | `pacman -Q`, `sha256sum -c` | 2026-08-08 |
| Tag `v1.15.0` | existente; preservada/intacta | `git ls-remote` | 2026-08-08 |
| Homelab real | não deve ser implantado | revalidar antes/depois | 2026-08-07 |
| Player UI | async QProcess; restore sem `--yes`; 13 testes verdes | `pytest tests/test_homelab_player.py` | 2026-08-07 |
| Suíte hermética | `tests/linux-homelab.sh` exit 0 (perfis, governo, backup, broker) | bash | 2026-08-07 |
| Socket Docker | somente `socket-proxy` read-only; Portainer via `DOCKER_HOST` | compose test, suíte | 2026-08-07 |
| CI homelab | `homelab-shell-test`, `-python-test`, `compose-validate`, `security-secret-scan`, `package-smoke` adicionados | ci.yml | 2026-08-07 |
| `main` | `93adbca`, alinhada com `origin/main`; PR #49 mergeada em `7923035` | `git status`, `gh pr view 49` | 2026-08-09 |
| Latest release | `v1.15.4` publicada com 7 assets; workflow `31349835128` success | `gh release view`, `SHA256SUMS-1.15.4` | 2026-08-09 |
| Pacote host | `phasezero-control-center 1.15.3-1`; pacote `1.15.4-1` validado, instalação bloqueada por autorização Bigsudo | `pacman -Q`, `phasezero-admin pacman -U` | 2026-08-09 |
| Homelab real | não configurado/ativo; 0 workloads; nenhum apply executado | `pz server homelab status --json`, `docker ps` | 2026-08-09 |
| Jornada Windows/integrações | PR #49 mergeada; ISO antecipada, índices 1–10, player modal e controles reversíveis Windows/Waydroid/Servidor publicados em `v1.15.4` | pytest 436 + 9; provision 228/0; CI PR `31348479922` success; CI main `31349833848` success; release `31349835128` success | 2026-08-09 |
| Feedback visual e prontidão Windows | branch `codex/ui-state-feedback`; switches explícitos e otimistas, janelas de instalação opacas, launch bloqueado sem guest inicializável e saúde acionável | pytest 437 + 9; shell Windows exit 0; ShellCheck; QA offscreen | 2026-08-10 |
| `main` | `9b0e6e3`, alinhada com `origin/main`; PR #50 mergeada em `f0d88fe` | `git status`, `gh pr view 50` | 2026-08-10 |
| Latest release | `v1.15.5` publicada com 7 assets; workflow `31377411747` success | `gh release view`, `SHA256SUMS-1.15.5` | 2026-08-10 |
| Pacote host | `phasezero-control-center 1.15.5-1` instalado via `phasezero-admin pacman -U`; pacote Arch SHA-256 validado | `pacman -Q`, `sha256sum -c`, import UI | 2026-08-10 |
| Boot direto Windows | runtime em `/usr/local/lib/phasezero/windows-vm-runtime` permanece `stale`; nenhuma mutação de boot executada nesta release | `pz windows-vm boot runtime-check` | 2026-08-10 |
| Recuperação do Player Windows | branch `codex/windows-provision-state-recovery`; estado órfão é validado, preservado para diagnóstico e substituído por nova jornada acionável | pytest 441 + 9; Player 38/38; descarte/recuperação 6 rodadas; shell Windows exit 0 | 2026-08-10 |
| Latest release | `v1.15.6` publicada com 7 assets; workflow `31419021099` success | `gh release view`, `SHA256SUMS-1.15.6` | 2026-08-10 |
| Pacote host | `phasezero-control-center 1.15.6-1` instalado; estado sintético `op-test` movido para quarentena e Player retorna a `idle` | `pacman -Q`, import/instanciação UI instalada, arquivo de quarentena | 2026-08-10 |

## Ledger de execução

Adicionar uma linha por sessão material. Não apagar histórico.

| Data | Agente | Branch/worktree | Fase | Commit/PR | Gates | Resultado/próximo passo |
|---|---|---|---|---|---|---|
| 2026-08-07 | Codex | `main` | Roadmap | não commitado | `git diff --check` passou | Roadmap canônico criado; iniciar Fase 0 em worktree novo |
| 2026-08-07 | opencode | `codex/homelab-v1151-remediation` / `pz-homelab-v1151` | Fase 0 (baseline) | `22298d3`..`92d576b` (8 commits) | suíte hermética exit 0; pytest 437; shellcheck; `git diff --check` | Port validado em commits por fase; Player reescrito (async QProcess) + 12 testes verdes |
| 2026-08-07 | opencode | idem | Fase 4 (perfis) | `4458ff3` | suíte hermética exit 0 | 6 perfis públicos implementados: assistant-private, assistant-multichannel, automation, ai-studio (blocked), developer, edge (default) |
| 2026-08-07 | opencode | idem | Fase 5/8 (CLI+CI) | `0e261eb`, `6bac525`, `9676b8e` | suíte exit 0; smoke install-root exit 0; compose-validate local OK | alias `profiles --json`; socket-proxy; 5 jobs homelab no CI; `homelab-integration-disposable` delegado à Fase 2 (probe E2E faltante) |
| 2026-08-08 | opencode | idem | Fase 0/10 (PR) | branch pushed; PR #37 aberto; #36 fechada | gitleaks green; compose-validate green; homelab-python-test green; security-secret-scan green (parcial) | CI principal em andamento (lint, shell-lint, python-test, shell-test, pester); aguardar conclusão antes do merge |
| 2026-08-08 | opencode | idem | Fase 0/10 (CI verde + fixes) | `4d15f15` (SC2120/0.9.0), `f373266` (chmod +x), `0429af3` (rg nos jobs), `9c02010` (PZ_ROOT pin) | CI PR #37 run `31255687739`: 12/12 jobs success | CI verde completo: lint, shell-lint 0.9.0 e 0.11.0, python-test, pester, shell-test, windows-vm, homelab-python-test, homelab-shell-test, compose-validate, package-smoke, security-secret-scan. Próximo: merge da PR #37 |

Prova CI: run `31255687739` — status `success`, 12 jobs verdes (`gh run view 31255687739`).

Prova CI pendências Fase 2/3/9: run `31265085899` — status `success`, 14 jobs
verdes incluindo o novo `homelab-integration-disposable` (PR #38).

| Data | Agente | Branch/worktree | Fase | Primeiro item | Gates | Resultado/próximo passo |
|---|---|---|---|---|---|---|
| 2026-08-08 | opencode | `codex/homelab-f9` / `pz-homelab-f9` | Fase 2/3/9 (pendências) | `0259b55` (winvm contract), `676c643` (pre-restore + rollback), `6ff4298` (E2E disposable), `ce1f072` (docs/changelog) | suíte hermética exit 0; bash -n; shellcheck; diff --check; CI run `31265085899` 14/14 success | PR #38 mergeada (`fc7ede8`); main CI + gitleaks verdes (`31266597239`/`31266597234`); suíte exit 0 em `main`. **Próximo**: usuário instala `1.15.1-1` via `phasezero-admin pacman -U <pkg>` e valida pós-instalação (0 dry-runs) |

Prova release: workflow `31258447568` success; assets em `gh release view v1.15.1` (7); checksums 7/7 `SUCESSO`; `e2b85e6` release commit no `main`.

| Data | Agente | Branch/worktree | Fase | Primeiro item | Gates | Resultado/próximo passo |
|---|---|---|---|---|---|---|
| 2026-08-08 | opencode | `main` (worktree principal) | Fase 10 (merge/release/pacote) | `3cb05fb` (squash PR #37), `e2b85e6` (release v1.15.1), tag `v1.15.1` | run `31257317111` main verde; release `31258447568` verde; `SHA256SUMS-1.15.1` 7/7 SUCESSO; conteúdo arch/deb/rpm/src conferido | **Próximo**: usuário instala via `phasezero-admin pacman -U <pkg.tar.zst>` e valida versão/profiles/status/plan (0 dry-runs) após confirmação |
| 2026-08-09 | opencode | `main` (worktree principal) | Pós-v1.15.1: release v1.15.2 (auditoria CX/UX + dependabot) | 10+ PRs audit (dead pages, doctor timeouts, dedup catálogo, UX core, labels, flaky) + 5 dependabot; `release.sh 1.15.2 --push` (`d4bc8a2`, tag `v1.15.2`) | run release `31314293821` success; `SHA256SUMS-1.15.2` 7/7 SUCESSO; bigsudo pacman -U exit 0 | Instalado `phasezero-control-center 1.15.2-1`; `pz --version` → v1.15.2; homelab status fail-closed (`configured:false active:false`, 0 workloads); doctor 130 PASS / 0 técnico (1 FAIL `CPU01` sensor 88°C — estado real do HW, não regressão); CLI `profiles/status/plan` top-level não existem — usar `pz server homelab status --json` e `pz server homelab profile list` |
| 2026-08-09 | Codex | `codex/ui-progressive-disclosure` (`/tmp/pz-ui-progressive`) + `main` | HL-UI-002: UX leiga, release v1.15.3 e instalação | 6 commits de implementação/docs + PR #48 (`32664a1`); release `1339a35`, tag `v1.15.3` | pytest 428 + 9; runner CI 39/39; ShellCheck 0.9/0.11; Pester; gitleaks; CI PR `31327861952`; CI main `31329472867`; release `31329478165` | Instalado `1.15.3-1`; Arch SHA `924feeda…` OK; 5/6 binários baixados validaram localmente e 7/7 digests da API GitHub coincidem com manifesto (AppImage local corrompida por retomada NAT64, rejeitada); Homelab `configured:false active:false`, 0 workloads; mounts/cmdline/Docker iguais; listener adicional pertence a pytest concorrente de `Port_Steam`, não ao pacote |
| 2026-08-09 | Codex | `codex/ui-windows-install-journey` (`/tmp/pz-ui-windows-install`) | HL-UI-002: correção da jornada Windows e controles reais | `6338d21` (implementação), `153a973` (contratos/testes), base `fc1af96` | pytest 436 + 9; provision 228 PASS/0 FAIL; Windows VM shell exit 0; Waydroid smoke exit 0; bash -n; compileall; diff-check | ISO exigida antes do player; edições limitadas e já concluídas bloqueadas; janela não incorpora no painel; logs recolhidos; toggles executam pares enable/disable e recarregam estado. Sem push, PR, release ou instalação; próximo: revisão, push/PR e release somente sob autorização explícita |
| 2026-08-09 | Codex | `codex/ui-windows-install-journey` + `main` | HL-UI-002: merge, release e instalação | PR #49 mergeada (`7923035`); release `93adbca`, tag `v1.15.4` | CI PR `31348479922` success; CI main `31349833848` success; release `31349835128` success; Arch SHA256 OK | 7/7 assets publicados; pacote Arch `1.15.4-1` validado. Host continua `1.15.3-1`: Bigsudo recusou autorização, sem fallback sudo. Próximo: autorizar Bigsudo e repetir `phasezero-admin pacman -U <pkg>`. |
| 2026-08-10 | Codex | `codex/ui-state-feedback` (`/tmp/pz-ui-state-feedback`) | HL-UI-002: feedback de estado, opacidade e saúde Windows | `4fb2e5c`, `80a30d9`, `d9f09c5` | pytest 437 + 9; 63 testes focados; `tests/linux-windows-vm.sh` exit 0; bash -n; ShellCheck; QA offscreen | Toggles mostram Ligado/Desligado/Aplicando e restauram cancelamento; player virou QDialog opaco; status real reporta `needsinstall`, `guest-not-installed` e `boot-runtime-stale`; sem push/release/install nesta sessão. |
| 2026-08-10 | Codex | `main` + `codex/ui-state-feedback` | HL-UI-002: merge, release e pacote | PR #50 (`f0d88fe`); release `9b0e6e3`, tag `v1.15.5` | CI PR `31374802265` + `31374785566` success; release `31377411747` success; `SHA256SUMS-1.15.5` Arch OK; import UI OK | Host atualizado para `1.15.5-1`. WinVM reporta `needsinstall` por disco ainda não inicializável e runtime de boot direto `stale`; nenhuma mudança em VM, GRUB ou runtime de boot. |
| 2026-08-10 | Codex | `codex/windows-provision-state-recovery` (`/tmp/pz-windows-state-recovery`) | HL-UI-002: recuperação de sessão órfã | `9a88e75` | pytest 441 + 9; Player 38/38; descarte/recuperação 6/6; `tests/linux-windows-vm.sh` exit 0; diff-check | `op-test` sintético não bloqueia nova instalação; registro órfão é preservado; erro backend fica acionável; lifecycle de testes fecha todas as janelas. Próximo: PR/release/instalação após CI. |
| 2026-08-10 | Codex | `main` + `codex/windows-provision-state-recovery` | HL-UI-002: merge, release e recuperação no host | PR #51 (`4197d6e`); release `33c6311`, tag `v1.15.6` | CI PR `31416105858` success; release `31419021099` success; Arch SHA-256 OK; UI instalada retorna `idle`/start visível | Host em `1.15.6-1`; `player.json` órfão preservado como `player.orphaned-20260810T191226218069Z.json`; status `needsinstall`, sem iniciar VM. Boot runtime continua `stale` e exige autorização administrativa separada. |

## Formato obrigatório de handoff

Todo agente encerra trabalho material com este bloco:

```text
Objetivo da sessão:
Fase/IDs assumidos:
Branch e worktree:
HEAD inicial:
HEAD final:
Arquivos alterados:
Commits criados:
Testes executados e resultados:
CI/PR:
Estado do host antes/depois:
Segredos verificados como ausentes:
Limitações e riscos restantes:
Bloqueios reais:
Próximo passo exato:
```

Handoff sem comandos/resultados verificáveis não altera requisito para `verified`.

## Definição de concluído

Homelab v1.15.1 somente termina quando:

- Todos requisitos da matriz estão `verified` ou explicitamente `deferred` com
  maturidade reduzida e razão aceita.
- Fundação, perfis, operações, Player, Policy Broker, backup e governor possuem
  provas comportamentais.
- CI completa está verde.
- Novo PR foi mergeado em `main`.
- `main` está limpa.
- Release `v1.15.1` foi publicada a partir de `main`.
- Sete assets e checksums foram baixados e verificados.
- Pacote foi instalado via gerenciador de pacotes após aprovação do usuário.
- Validação pós-instalação não implantou workloads.
- Containers, serviços, listeners, mounts, GRUB e WinVM permaneceram inalterados.
- Tags anteriores permanecem intactas.
- Relatório final liga cada claim a arquivo/commit, teste e prova CI.
