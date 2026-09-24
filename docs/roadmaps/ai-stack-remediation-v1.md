# Roadmap canônico — Remediação do stack de IA v1 (AISR)

> Corrige os achados P1 da auditoria `docs/audit/ai-config-review-2026-09-24.md`
> (AICR). P2/P3 ficam no backlog ao fim.

## Metadados

| Campo | Valor |
|---|---|
| Status | **pending** |
| Criado | 2026-09-24, America/Sao_Paulo |
| Base observada | `origin/main` `720b7d5` (v1.21.1) |
| Origem | AICR-001..004 |
| IDs | `AISR-xxx`. Não confundir com `AICR-*`, `LUX-*`, `REV-*`, `CCS-*` |

## Regras

1. Worktree dedicado; nunca no checkout do operador.
2. Testes com HOME/XDG em tmp, **um `export` por variável**; `PZ_USE_SUDO=0`.
3. Cada item: teste que falha antes e passa depois, citado no PR.
4. Copy PT-BR; identificadores em inglês.
5. Não reinstalar proxies no host do operador para provar; prova viva só com
   aceite (mesma allowlist do AICR F1).

## Itens

| ID | Origem | Entrega | Prova |
|---|---|---|---|
| AISR-001 | AICR-001 | `9router-manager.sh` para de escrever `$PROXY_ROOT/.runtime/node24/bin/node`; usa runtime próprio. Launchers de proxies executam `tsx` pelo `NODE_BIN` isolado, não pelo PATH. `proxy-suite.sh` repara shim apontado para node ≠ 24 | Teste: rodar `ensure_runtime` do 9Router com node de sistema v26 fake; assert shim dos proxies continua v24. No host (com aceite): `phasezero-qwenproxy` `NRestarts` estável e `proxies test qwenproxy` com `/v1/models` ok |
| AISR-002 | AICR-002 | `detailed-status`/`status` derivam `service` de `is-active` + porta + `NRestarts` entre duas leituras → `running`/`starting`/`crash-loop`/`failed`. `proxy_models.py` mapeia `crash-loop` para severidade erro com próxima ação | Teste com systemctl stub `active` + porta fechada + restarts crescendo → `crash-loop`; teste Qt offscreen do rótulo |
| AISR-003 | AICR-003 | `setup-codex.sh`: se `codex` existente ≥ mínimo suportado, não reinstala nem troca symlink; pin vira mínimo (`PZ_CODEX_MIN_VERSION`); adiciona `status` e `--dry-run` | Teste: codex fake 0.156.1 no PATH → nenhuma chamada `npm install`, symlink intacto |
| AISR-004 | AICR-004 | `setup-agent-compat.sh rules` sem workspace → recusa com `needs-project` exit 2 (mesmo guarda de `init`: vazio, `/`, `$HOME`) | Teste: `rules` sem `PZ_WORKSPACE_ROOT` e sem registro → exit 2, zero arquivo criado; `linux-admin-bridge.sh` sem WARN |

## Gates

- G1: AISR-001..004 com testes verdes; suíte completa no mesmo estado ou melhor.
- G2 (aceite do operador): validação viva repetida — Qwen deixa de estar
  `broken`; status/UI não mostram "rodando" para serviço em crash-loop.

## Backlog P2/P3

- AICR-005 `proxies test`: exit 0/2/3, envelope `summary/next`, classificação `upstream-error`/`unreachable`.
- AICR-006 "sessão salva (não verificada)" até chat ok.
- AICR-007 runner do 9Router copiado para `INSTALL_ROOT` (independe do checkout em SD).
- AICR-008 mascarar e-mail em `9router provider status`.
- AICR-009 `available` vs `active` em providers do 9Router.
- AICR-010 `pz ai status` < 5 s: versões em paralelo/cache, timeout 1 s, hero sem bloqueio.
- AICR-011 backup de `9router/settings.json` e `ai-routing`.
- AICR-012/013 `pz updates check` inventaria codex, opencode, hermes, codexbar, omniroute, rtk, ai-memory, snapshots.
- AICR-014 `pz ai help|--help|<vazio>`.
- AICR-015..018 polimento (campo MiMo, preview de setup, shellcheck, naming via LUX-016).
