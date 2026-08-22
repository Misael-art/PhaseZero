# Homelab Linux (v1.15.1)

Stack `pz server homelab` — 4 layers core + extras, governada por perfis e
orçamento, com backup verificável e rollback, broker de política AI e um
contrato explícito com a WinVM. Tudo hermético: `tests/linux-homelab.sh` não
exige daemon Docker; o E2E com Docker real roda em CI descartável.

## Arquitetura e perfis

Core (sempre presente, porta 9000): `jellyfin`, `syncthing`, `vaultwarden`,
`uptime-kuma`. Extras (opt-in `--extras`): `portainer`, `nextcloud`, `grafana`,
`prometheus`, `paperless-ngx`, `n8n`.

Registro `assets/home-server/homelab-profiles.json` — 6 perfis públicos
(cada um com `class` de recursos e `maturity` honesta; default `edge`,
nenhum perfil pesado sobe por padrão):

| Perfil | Objetivo | Classe | Maturidade |
|---|---|---|---|
| `assistant-private` | Assistente local privado (Hermes, 9Router, Ollama, ai-memory) | local-inference | preview |
| `assistant-multichannel` | Canais externos supervisionados (Hermes, OpenClaw) | automation | preview |
| `automation` | Workflows auditáveis (n8n, PostgreSQL, LangGraph) | automation | preview |
| `ai-studio` | Dify isolado; pesado, permanece desligado | heavy-studio | blocked |
| `developer` | Coding assistido (Aider, OpenHands sob demanda) | coding-worker | preview |
| `edge` | Gateway leve supervisionado (ZeroClaw, modelo remoto via 9Router) | always-on-light | experimental |

- `up` sem perfil sobe somente o core (`edge`). Perfil pesado exige gate de
  RAM do governor e `--yes`-like: overcommit ou perfil desconhecido é
  **fail-closed** (exit != 0, sem plano).
- `plan --profile` compara serviços declarados com Compose real. Perfil
  `assistant-private` permanece preview e não pode executar `up`: Hermes,
  9Router, Ollama e ai-memory ainda não são orquestrados por esse Compose.
  Use `pz ai workspaces doctor` para diagnóstico completo e redigido.
- `docker-compose.lock.json` fixa 13 imagens com tag (sem `latest`).
- Todo serviço roda `no-new-privileges` + `init` + memória/CPU limitadas
  (pelo menos um serviço carrega `mem_limit`; validado por CI).
- Único bind do socket Docker é `socket-proxy`
  (tecnativa/docker-socket-proxy, read-only, allowlist `CONTAINERS`/`TASKS`);
  o Portainer fala com o Docker via `DOCKER_HOST=tcp://socket-proxy:2375` e
  nunca monta `/var/run/docker.sock`. Nenhum outro serviço tem acesso a Docker.

Matriz de suporte (o que é testado, com prova): perfis, weights e fail-closed
em `tests/linux-homelab.sh`; compose core e core+extras validado
(`docker compose config --quiet` e checks de socket/limits) em CI
(`compose-validate`); operação sem daemon é degradação sinalizada.

## Governança de recursos e conflito WinVM

Governor `linux/server/homelab-governor.sh`:

```bash
linux/pz server homelab governor list
linux/pz server homelab governor weights        # pesos por serviço
linux/pz server homelab governor budget core    # orçamento MiB vs headroom 20%
linux/pz server homelab governor check --profile assistant-private
```

Regra: `total ≤ usable` com `usable = RAM - 20% headroom`; ultrapassar é
`fail` (exit != 0). WinVM ativa e overcommit: falha com razão **explicitando**
a guest e o caminho gracioso (`winvm-suspend --dry-run`).

Contrato com a guest Windows (nenhum arquivo/processo da VM é tocado; só a
API pública):

```bash
linux pz server homelab governor winvm-status               # JSON status
linux pz server homelab governor winvm-suspend --dry-run    # só planeja
linux pz server homelab governor winvm-suspend              # só via QGA
linux pz server homelab governor winvm-resume               # re-checa budget
```

- Fonte do estado: `PZ_HOMELAB_WINVM_STATUS_FILE` (teste/hermético) ou
  `pz windows-vm status --json`; campos `libvirtState`, `currentMarker`;
  `bootRuntimeStale` não conta como ativo.
- Suspensão **100% graciosa**: comando `PZ_HOMELAB_WINVM_SUSPEND_CMD`
  (default `pz windows-vm guest-login shutdown --json`). Em todos os planos e
  resultados: `killUsed:"never"`. Não existe caminho de kill.
- Peso reservado: `winvmMB` no registro (incluído no `homelab-profiles.json`,
  default 2048). Enquanto a guest estiver ativa, ele é descontado do
  orçamento usado pelo stack.
- Testados: detecção idle/ativa (stub), fail-closed com guest ativa,
  plano de impacto, dry-run sem efeito colateral, execução do comando
  configurado, no-op quando idle, resume.

## Segredos, rede e acesso

- Segredos em `<state>/.env` (gerados por `repair --gen-env`); variáveis
  obrigatórias com valor de teste em CI (`VW_ADMIN_TOKEN`, senhas
  Nextcloud/Grafana etc). Sem .env real no repositório.
- Rede: `9000` local por padrão; `HOMELAB_ACCESS_MODE` (`local` | `tailscale`)
  persiste no `.env` (testado).
- Scripts de setup de agentes AI usam **redação de segredos** no broker e
  pinagem de versão (ver abaixo).

## Backup, restore e disaster recovery

```bash
linux pz server homelab backup --extras          # manifest.json + sha256 por volume
linux pz server homelab backup verify --source <dir>
linux pz server homelab restore --source <dir> --yes   # snapshot+apply com rollback
```

- Manifest obrigatório (schemaVersion 2); backup sem manifest não verifica
  nem restaura; arquivo adulterado → `verify` falha, restore recusa antes de
  aplicar (verificado por checksum + tar).
- Recusa tudo sem `--yes` explícito. Cadência sugerida: backup antes de
  `update` (update já faz backup automático) e semanal via cron.
- **Pre-restore snapshot (v1.15.1)**: antes de parar a stack o restore grava
  `--source.pre-restore/manifest.json` + `.tgz` de cada volume existente
  (verificável, mesmo schema). Em falha parcial de extração, devolve ao
  snapshot prévio cada volume tocado (saída `rollbackApplied:true`); sem
  exclusive: `rollbackFailed` lista o que não voltou. Diretórios
  `*.pre-restore` nunca aparecem como backups no `status`.
- DR em CI (`homelab-integration-disposable`): seed de volumes Docker
  descartáveis → backup → destroy (volume rm/recreate) → restore → igualdade
  byte a byte dos sentinelas.

## Operação sem UI, troubleshooting e rollback

UI (Player PySide6) é conveniência; tudo existe em CLI (`linux/pz server
homelab ...`), com JSON envelope (INFO/WARN/ERROR vão para stderr, nunca
poluem stdout). Logs: `pz server homelab logs`, `pz ... governor budget`
para diagnóstico de RAM. Boot: `homelab-boot-prepare.sh` é unitário
(`PZ_BOOT_MARKER=1`), roda como usuário alvo, marca `degraded.json` com
razões quando um serviço essencial (docker) não sobe; `repair` regenera
segredos/valida compose/restaura acesso — o estado nunca é escrito em
`/root`.

Rollback em falha de aplicação é automático apenas no restore (snapshot
prévio); para alterações de configuração o procedimento é: reverter manual
(mensagem clara), recriar `.env`, validar `docker compose config` e rodar
`verify`/`status` antes de subir.

## Limitações honestas

- `ai-studio` está **blocked** (maturidade declarada) — não sobe por padrão.
- `edge` é experimental; nenhum perfil pesado sobe até ser comprovado por
  teste.
- Sem integração com drivers de GPU no host são candidatos; recursos do
  governor são números de RAM (budget), não CPU/vídeo.
- Docker real: os jobs E2E usam volumes descartáveis; o stack completo não
  é exercitado em runtime em CI (sem GPU/network da appliance).
- Backup/restore só dá rollback de dados de volume; segredos/respostas do
  `.env` não são parte do manifest.

## Verificação

```bash
bash tests/linux-homelab.sh        # hermético, sem Docker (exit 0)
QT_QPA_PLATFORM=offscreen python3 -m pytest tests/test_homelab_player.py
```

CI: `homelab-shell-test` (hermético + bash -n + registro/lock JSON),
`homelab-integration-disposable` (E2E Docker), `homelab-python-test` (player
offscreen), `compose-validate` (config + socket/limits), `package-smoke`
(install-root), `security-secret-scan` (gitleaks). Shellcheck 0.9.0/0.11.x
com excludes fixos sobre todos os `.sh`.
