# Prompt — PhaseZero: fechar lacunas do plano host-hygiene com rigor

> Prompt reutilizável para agente de IA (Codex/Claude/Grok). Deriva da validação
> do plano `.grok/sessions/.../plan.md` (Fase 0–1) contra o código real.
> Mantém as constraints do projeto: dry-run default, namespace PhaseZero,
> leave-no-trace, admin bridge explícito, sem assets proprietários.

Você é engenheiro sênior atuando no repositório **PhaseZero** (`/mnt/sdcard/Projects/PhaseZero`), hub de pós-instalação Linux + Windows. Stack: **bash** (`linux/lib/*`, `linux/pz`), **Python Qt6** (`linux/ui_native/*`), **PowerShell** (Windows `*.ps1`).

## Contexto

Existe um plano aprovado cuja Fase 0–1 (ledger de mutações + higiene do host + wipe unificado) está correta, mas uma validação contra o código real revelou **6 lacunas técnicas** que tornam o PR1 incompleto ou arriscado se ignoradas. Sua tarefa: **implementar as 6 correções abaixo com rigor verificável**, integrando-as ao PR1/PR2 antes de qualquer reorganização de UI.

## Princípios obrigatórios do projeto (NÃO violar)

- **Dry-run default.** Toda mutação do host exige apply explícito + token quando destrutiva.
- **Namespace PhaseZero.** Tudo que o produto cria vive sob `~/.local/state|config|share/phasezero` + `/etc/phasezero` + `/usr/local/lib/phasezero`, ou é marcado `_managedBy=phasezero` + entrada no ledger.
- **Leave no trace.** Uninstall remove tudo que o ledger registra; **nunca** toca `~/Emulation` nem dados do usuário.
- **Admin bridge explícito.** Use `phasezero-admin` ou `bigsudo`. **Nunca** configure sudo sem senha nem armazene senhas. Se ambos ausentes: degrade com mensagem acionável, não faça crash.
- **Não baixar** ROMs, BIOS, keys ou assets proprietários.
- Antes de começar: **consulte `ai-memory`** (MCP) por soluções prévias relacionadas a backup/ledger/uninstall. Ao final, registre aprendizados não triviais via `ai-memory write-page` com frontmatter `tier: semantic`.
- Respeite `AGENTS.md` (caveman nas respostas; RTK só se resolver em PATH; Ponytail só se workspace detectado).

## Estado real confirmado no código (ponto de partida)

- `linux/lib/common.sh:63` e `:78` — `pz_write_managed_file` grava backup como `${path}.bak.<ts>.<pid>.<rand>` **ao lado do arquivo original** (lixo).
- `linux/lib/common.sh:7-13` — cria `PZ_STATE`/`operations` no `source` (até `pz help` toca o host).
- `linux/uninstall.sh:205-216` — `print_root_items()` **só imprime** comandos `sudo` para o cliente copiar.
- `linux/ui_native/catalog.py:69` — **já existe** campo `visibility` (default `advanced` se `risk in {high,elevated}`, senão `standard`).
- `linux/lib/ledger.sh` — **não existe** (criar).
- Envelope `howToFix`/`ledgerRef`/`logPath` — **ausente** em todo `linux/`.
- 10 scripts em `linux/ai/` escrevem fora do namespace (`9router`, `codexbar`, `hermes`, `odysseus`, `mcp`, `omniroute`, etc).

## As 6 correções (faça todas, nesta ordem)

### 1. Migração de backups legados (subespecificada no plano)

- Novo caminho de backup: `$PZ_STATE/backups/<sha256-do-path-original>/<basename>.bak.<ts>`.
- Implemente `migrate_legacy_baks()` em `linux/lib/common.sh`: escaneia configs PhaseZero-conhecidas (`~/.bashrc`, `~/.config/**`, `~/.local/bin/*` wrappers) por padrão `*.bak.<num>.<num>.*` legado e move para o novo local. **Idempotente**; respeita dry-run.
- **Dual-read** em qualquer função de restore: tenta novo local antes do legado (para não quebrar restore de backups feitos antes desta versão).
- Critério: após migração (em dry-run e apply), **zero** arquivos `*.bak.*` PhaseZero fora de `$PZ_STATE/backups`.

### 2. Hook único do ledger (rota de gravação faltando)

- Crie `linux/lib/ledger.sh` com `ledger_record()` — **único ponto** de mutação registrada.
- Schema JSONL por operação: `operation_id, module, action, timestamp, created[], modified[], backups[], services[], packages[], scope(user|system), reversible(bool), rollback_cmd`.
- **Plugue** `ledger_record()` em **todos** os pontos de mutação: `pz_write_managed_file`, install de systemd units, desktop files, wrappers em `~/.local/bin`, GRUB generators, backups de boot. Audite cobertura módulo a módulo: `steamdeck, windows-vm, waydroid, emulation, server, ai, boot, capabilities`.
- Critério de rigor: gere um mapa `docs/host-surface.md` listando cada mutação e se está coberta pelo ledger. **Nenhuma** mutação de host sem passar por `ledger_record()` — se alguma não puder ser instrumentada agora, documente como dívida técnica explícita no mapa.

### 3. Escopo do Windows (PR6) — decidir e justificar

- Leia `plans/install-errors-analysis.md` e `*.ps1` na raiz.
- Decomponha em sub-tarefas: **(A)** `result.json` mínimo no startup do backend (`bootstrap-ui.ps1`/launcher), **(B)** `manual-required` vira opt-in/aviso (não bloqueia `safe-base`), **(C)** UTF-8 consistente nos logs.
- Decida e justifique: cabe num PR único ou split (A sozinho é pré-requisito de B). Escreva a decisão em `docs/windows-pr6-scope.md`.

### 4. Fallback degraded quando admin bridge ausente

- Se `phasezero-admin` E `bigsudo` ausentes: **não faça crash**. Degrade para dry-run + mensagem acionável ("instale a bridge: `linux/pz ai setup admin`" ou o comando exato para o contexto).
- Mesmo em degraded, todo apply/preview **termina com envelope result**: `{ok, code, summary, howToFix[], ledgerRef, logPath}`.
- Critério: UI e CLI nunca terminam sem um result legível; modo degraded marcado no envelope (`code: degraded` / flag).

### 5. Harness de teste sandboxed (sem tocar host real)

- Crie fixture/harness para os novos testes: `tests/test_host_ledger.py`, `tests/test_uninstall_leaves_clean.py`, `tests/test_help_no_host_touch.py`.
- Harness: `HOME=$TMPDIR/fake-home`, `XDG_STATE_HOME`/`XDG_CONFIG_HOME`/`XDG_DATA_HOME` redirecionados, snapshot de filesystem antes/depois.
- Assert por **diff**: o único delta permitido fora de `$PZ_STATE` é o explicitamente documentado no mapa de host-surface.
- **Nunca** execute nada que toque `~/Emulation` ou exija sudo real.
- Critério: testes rodam verdes em CI sem root e sem sujar o host do runner; `pz help` e abertura de UI não produzem delta.

### 6. Risco não listado — reusar `visibility` existente (não reinventar)

- `catalog.py:69` já implementa progressive disclosure (`standard` vs `advanced`). **Não** crie sistema novo na Fase 2.1.
- Audite todas as actions com `visibility` vazia/nula; classifique `standard` vs `advanced` por risk real.
- Reduza o escopo do PR3 (jornadas/UI) para: copy/curadoria PT + busca global + melhor agrupamento do dashboard — **reaproveitando** a infra de `visibility`. Documente a redução de escopo.

## Fluxo de entrega

1. Branch a partir de `main` (ou da branch atual se já em feature): `codex/host-hygiene-lacunas`.
2. Implemente por PR na ordem: **PR1** = correções 1+2 (backups centralizados + ledger + migração legados). **PR2** = correção 4 (fallback degraded) + wipe unificado `pz host wipe/prune` + UI Manutenção. **PR3 menor** = correção 6. **PR6** = correção 3. Cada PR com os testes da correção 5 correspondentes.
3. Rode `tests/test_linux_native_ui.py` (smoke Qt offscreen) + pytest nativos + os novos testes de higiene. **Não afirme sucesso sem saída verde anexada.**
4. Se algo falhar ou for pulado, reporte explicitamente — não silencie.

## Definição de pronto

- [ ] Migração de `.bak` legados implementada, idempotente, dual-read no restore.
- [ ] `ledger.sh` + `ledger_record()` plugado em todas as mutações; mapa `docs/host-surface.md` entregue.
- [ ] Escopo Windows decidido em `docs/windows-pr6-scope.md`.
- [ ] Fallback degraded sem crash; envelope result mesmo em falha.
- [ ] Harness sandboxed + 3 novos testes verdes (sem sudo, sem `~/Emulation`).
- [ ] PR3 reescrito para reusar `visibility` existente.
- [ ] Após `host wipe --apply --confirm PHASEZERO-WIPE`, **não restam** paths PhaseZero do ledger; `~/Emulation` intacto.
- [ ] Saídas de teste anexadas; aprendizados relevantes em `ai-memory`.

Comece consultando `ai-memory`, depois abra a branch e inicie pela correção 1+2.
