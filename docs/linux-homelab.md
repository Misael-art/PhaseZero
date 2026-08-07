# Homelab Linux (v1.15)

Stack `pz server homelab` — 4 layers core + extras, governada por perfis e
orçamento, com backup verificável e broker de política AI. Tudo hermético:
nenhum teste exige daemon Docker.

## Camadas e perfis

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

Governor `linux/server/homelab-governor.sh`:

```bash
linux/pz server homelab governor list
linux/pz server homelab governor weights        # pesos por serviço
linux/pz server homelab governor budget core    # orçamento MiB vs headroom 20%
linux/pz server homelab governor check --profile assistant-private
```

Overcommit ou perfil desconhecido: **fail-closed** (exit != 0, sem plano).
`docker-compose.lock.json` fixa 12 imagens com tag (sem `latest`, sem digest
prometido). Todo serviço roda com `no-new-privileges` + `init` + `mem_limit`
+ `cpus`.

## Backup / restore (schemaVersion 2)

```bash
linux/pz server homelab backup --extras          # manifest.json + sha256 por volume
linux/pz server homelab backup verify --source <dir>
linux/pz server homelab restore --source <dir> --yes   # verify-then-apply
```

- Manifest obrigatório; backup sem manifest **não** verifica nem restaura.
- Arquivo adulterado: verify falha; restore recusa antes de aplicar.
- Sem `--yes`: recusa. Cadência sugerida: `backup` antes de `update`
  (update já faz backup automático) e semanal via cron.

## Player PySide6 (categoria "Homelab")

Página nativa com: tabela de status ao vivo (serviço/layer/bind/URL/rodando),
combo de perfil + rótulo de orçamento do governor, botões Plan/Up/Down/
Backup/Verify/Restore (QProcess em `linux/pz`), seletor de diretório para
restore e popup do broker de política. Sem daemon: página mostra
"não pronto" com degradação sinalizada — nunca trava a UI.

## Broker de política AI

`linux/server/ai-policy-broker.sh` — modos `conservative` (default) e
`permissive`, persistido em `<PZ_AI_STATE>/policy.json`:

```bash
linux/pz ai policy status
linux/pz ai policy set permissive
linux/server/ai-policy-broker.sh check openclaw-install version=0.9.4
```

Semântica: negações são **advisory** (gates nos setup scripts), mas o broker
falha fechado: ação desconhecida → deny; `set <modo inválido>` → rejeitado e
modo atual intacto. Hints aceitos: `version=<pin>`, `checksum=<sha256 64>`,
`explicit=1`. Adapters endurecidos: setup-openclaw pina `0.9.4`, setup-codex
pina `0.66.0`, setup-memory pina `0.7.2` (sem `--network host`), setup-hermes
exige `PZ_HERMES_INSTALL_SHA256`, setup-ollama não faz auto-pull.

## Verificação

```bash
bash tests/linux-homelab.sh        # hermético, sem Docker (exit 0)
QT_QPA_PLATFORM=offscreen python3 -m pytest tests/test_homelab_player.py
```

CI: job `homelab-fault` roda a suíte sem daemon Docker; `shell-test` roda via
`tests/runner.sh`; `python-test` cobre o player offscreen. Shellcheck limpo
em todos os `.sh` tocados.
