# Roadmap canônico — Superfícies da Central v1

> Fonte operacional única para o plano de melhorias das sessões da Central
> Linux (Steam Deck, Windows VM CX, Waydroid, Servidor/Homelab UI, Emulação
> contratos, Recursos, IA, Boot, Ajustes, doctor).
>
> Este documento coordena implementação. Não prova conclusão. Commits, testes,
> CI e validação no host são as provas.
>
> Não substitui os roadmaps de Homelab appliance nem de WinVM boot-resilience.
> Quando o trabalho tocar compose/governor/AI-appliance, usar
> `homelab-v1.15.1-remediation.md`. Quando tocar sessão GRUB/QGA/WBR-00x, usar
> `winvm-boot-resilience-v1.md`.

## Metadados

| Campo | Valor |
|---|---|
| Status | Planejado; implementação ainda não aceita como concluída |
| Criado | 2026-08-23, America/Sao_Paulo |
| Origem | Diagnóstico de superfícies (sessão Grok); wiki `notes/surface-maturity-audit-2026-08-23.md` |
| Repositório | `/mnt/sdcard/Projects/PhaseZero` |
| Base observada | `main` em `ea9b927` (repo `version.json` 1.16.6) |
| Pacote host | revalidar com `pacman -Q phasezero-control-center` antes de mutar |
| IDs | `CCS-xxx` (Control Center Surfaces). Nunca reutilizar. |

Dados acima são snapshot. Todo agente deve revalidá-los.

## Missão

Leigo usa a Central sem mentira operacional: status reflete o que está
ligado, preview não dispara doctor, restore não aplica `--yes` pela busca,
boot GRUB tem saída, OLED não vira PC genérico, Homelab não some do menu.
Não adicionar superfície nova. Consertar as que já existem.

## Ordem das fontes de verdade

1. Estado vivo de `main`, GitHub, CI, releases, pacote e host.
2. Este roadmap para trabalho de superfície/CX/contratos da Central.
3. `docs/roadmaps/winvm-boot-resilience-v1.md` para boot Windows / QGA / WBR.
4. `docs/roadmaps/homelab-v1.15.1-remediation.md` para stack Docker / perfis appliance.
5. Código e schemas versionados.
6. Wiki ai-memory (`notes/surface-maturity-audit-2026-08-23.md`, `gotchas/*`).
7. `docs/UX-CX-AUDIT.md` (2026-08-08) só como contexto — várias claims estão obsoletas.

## Regras permanentes

- Worktree dedicado. Não reutilizar worktree de WinVM ou Homelab.
- Uma responsabilidade por commit. Sem `git add -A`.
- Sem `homelab up` / `homelab apply` neste host.
- Sem boot WinVM até CCS-000 (storage) `verified` ou `deferred` com prova.
- Sem reintroduzir `/etc/default/grub.d/09-phasezero-handheld.cfg`.
- Sem marcar `verified` sem teste comportamental. Físico só onde a matriz pede.
- Sem unificar `bootstrap-tools.ps1` com `linux/pz`.
- Temas: shipped. Fora de escopo salvo bug novo.
- Appliance AI (Hermes/Ollama/OpenClaw no compose): Homelab roadmap, não aqui.

Estados: `pending`, `in_progress`, `verified`, `deferred`.

## Matriz de evidência

### Fase 0 — Parar dano e mentira (P0)

Gate de saída: todos CCS-000..007 `verified` ou `deferred` com razão; pytest
da UI nativa verde; suítes shell das superfícies tocadas verdes; nenhum
preview de Ajustes chama `doctor`.

| ID | Requisito | Implementação | Teste | Prova | Estado |
|---|---|---|---|---|---|
| CCS-000 | Não bootar WinVM até caminho de dados | Ops: memtest86+, `btrfs scrub`, VM em subvolume nocow/sem zstd, experimento `cache=writeback`. Código já faz `nodatacow` só em imagem **nova**. Disco atual continua CoW+csum | Registro no ledger do roadmap WinVM | Host. Sem isso, WBR físico bloqueado | deferred 2026-08-23 — memtest86+/`btrfs scrub` exigem reboot ou I/O pesado no host em uso (proibido neste mandato); pendência registrada no ledger do roadmap WinVM |
| CCS-002 | Botão GRUB Dock na polaridade certa | `windows_vm.py`: clique não usa `isChecked()` pós-toggle. Checked → enable, unchecked → disable. Revalidar contra HEAD `ea9b927` (já registrou as ações no catálogo) | `test_windows_vm_ui.py` **click dispatch**, não só sync JSON | pytest | verified `ebd9ef8` |
| CCS-003 | Preview de Ajustes/bundle ≠ doctor | `catalog.py` ~169 e ~725: `tune.{browser,gaming,dev}` preview = `tune <area>` dry-run; `system.support-bundle` preview ≠ `("doctor",)` | pytest catálogo: preview args não contêm `doctor` para esses IDs; smoke UI não dispara doctor | pytest | verified `7d22851` |
| CCS-004 | Restore Homelab sem `--yes` no catálogo | CLI `restore --plan` = verify+impacto, zero write. Catálogo e Player só `--plan`. `--yes` só CLI explícito / arquivo de confirmação. Consertar `up --resume` (implementar ou tirar da UI). `test_homelab_player.py` deixa de congelar flag inexistente | `tests/linux-homelab.sh` + `test_homelab_player.py`: plan não escreve; busca/catálogo sem `--yes` | hermético. Sem `homelab up` no host | verified `0f2d939` + `fdec4c3` |
| CCS-005 | Waydroid power = sessão Android | JSON `android.sessionRunning`. Página usa sessão, não `waydroid-container`. Stop idempotente. Container-only = Parado | `tests/linux-waydroid.sh` + pytest UI: fixture sessão down + container up → Parado | hermético | verified `29b0fc1` |
| CCS-006 | Galileo/OLED é Steam Deck | `steamdeck_is_jupiter` / `pz_display_is_jupiter` / `pz_display_profile` distinguem lcd vs oled. Gamescope handheld não assume só 1280×800 de Jupiter | `tests/linux-steamos-ux.sh` fixture DMI Galileo | hermético | verified `f49a12f` |
| CCS-007 | Waydroid GRUB tem saída | Após N falhas de UI / imagem ausente: `Relogin=false` ou strip SDDM autologin, greeter normal. Espelhar padrão de escape do WinVM, não QGA | suíte waydroid: missing image → autologin stripped | hermético. Físico opcional | verified `139be97` |

### Fase 1 — CX das sessões reais (P1)

Gate: Steam Deck mostra estado vivo; Homelab visível ou fundido; Waydroid
toggles honestos; doctor default never; contrato `~/Emulation` reescrito;
nenhum `windows.install` no modo simples.

| ID | Requisito | Implementação | Teste | Prova | Estado |
|---|---|---|---|---|---|
| CCS-010 | Página Steam Deck viva | StatusLoader: modo, watcher, teclado, Decky, boot. Radios leem `status.mode`. Não é só CatalogWorkspace + rádio | pytest página: payload liga radios e facts | pytest | pending |
| CCS-011 | Copy e preview honestos no Deck | Hotkeys **Meta+Shift+F1–F8**. Plugins preview = `plugins dry-run`. Conveniências = `conveniences plan`. Display detect não `mutable` | assert catálogo | pytest | pending |
| CCS-012 | Elevated primário visível | `action_section`: boot/privileged/USB no grupo Sessão/Controles com badge de risco. Advanced = `*.status` e remove. Expor `watcher enable` | pytest grouping | pytest | pending |
| CCS-013 | Homelab no menu ou fundido | `SIDEBAR_GROUPS` inclui Homelab **ou** Player move para Servidor e categoria some. Uma superfície | pytest sidebar + registry | pytest | pending |
| CCS-014 | Um vocabulário de perfil | Copy: install `server-*` ≠ appliance `edge\|assistant-*` (só orçamento RAM; compose continua core/extras). `homelab.budget` perfil real, não `core` | teste hermético budget; copy review | hermético | pending |
| CCS-015 | Waydroid: três toggles e dois boots | Host-link ≠ LXC shares ≠ USB. `waydroid.boot.next` agenda; ação explícita “Reiniciar no Android” para `next-reboot` | pytest UI + linux-waydroid | hermético | pending |
| CCS-016 | Doctor não inunda host fresco | `subsystem_opted` default `never` se conf ausente. Overview nativo `PZ_DOCTOR_SCOPE=system`. Alinhar `linux/audit/subsystems.conf` com o código | `tests/linux-doctor.sh` host sem conf → INFO, não 50 WARN | hermético | pending |
| CCS-017 | Contrato `~/Emulation` | `docs/host-surface.md`: wipe/uninstall nunca toca; módulo emulação escreve em `$PZ_EMULATION_ROOT` | review doc; uninstall test continua a não apagar | doc + teste wipe | pending |
| CCS-018 | Optimizers estritos | `set -euo pipefail` em `dolphin.sh`, `duckstation.sh`, `pcsx2.sh` | `linux-emulation-optimizers.sh` | hermético | pending |
| CCS-019 | OmniRoute: UI ou sumir | Card experimental no catálogo **ou** CLI deprecado. 9Router permanece o router público | catálogo 0 ou 1 OmniRoute, nunca silencioso | pytest catálogo | pending |
| CCS-020 | WinVM modo simples honesto | Esconder `windows.install` (disco vazio) do modo simples. QGA-down = modal/bloqueio de launch (120s+KILL recria NTFS suja). Sliders RAM/CPU rotulados só-leitura | pytest UI | pytest. WBR-007 continua no roadmap WinVM | pending |
| CCS-021 | `gamescope` no perfil Waydroid | `profiles/waydroid-linux.json` inclui gamescope (sessão handheld já prefere) | profile JSON assert | hermético | pending |

### Fase 2 — Higiene (P2)

Gate: pyc órfãos fora; headers de roadmap alinhados ao estado vivo;
CHANGELOG 1.16.x; decisão explícita sobre `linux/ui/server.py`.

| ID | Requisito | Implementação | Teste | Prova | Estado |
|---|---|---|---|---|---|
| CCS-030 | Apagar pyc de páginas mortas | `pages/{boot,flatpak,applications,ai_dev,steamdeck,waydroid,server}.cpython-314.pyc` | tree limpa | git | pending |
| CCS-031 | Ledger root D2–D5 | GRUB/polkit/sysctl/iso-boot via chokepoint ou `print_root_items` completo (removable udev incluso). Escopo grande: um commit por chokepoint | `test_host_ledger.py` / wipe notes | hermético | pending |
| CCS-032 | Headers de roadmap honestos | Temas: shipped. Homelab header 1.14.7 → snapshot atual, **sem** marcar appliance concluído. WinVM: `confirm-quit` → `window-close=off` | review | doc | pending |
| CCS-033 | CHANGELOG | Unreleased WinVM/IA/Homelab sob versão real 1.16.x/1.17; 1.13.0 não parece latest | review | doc | pending |
| CCS-034 | Destino `linux/ui/server.py` | Decidir: manter com teste de drift contra `catalog.py`, ou marcar legado e parar de expandir | ADR curto neste arquivo | decisão | pending |
| CCS-035 | Copy tríplice IDE | Unificar labels OpenCode / proxies / “Sincronizar IDEs” | catálogo | pytest copy | pending |
| CCS-036 | `pz` help Waydroid | Documentar `stop` e `shares` | help grep | hermético | pending |
| CCS-037 | Testes UI Waydroid | Espelhar `test_windows_vm_ui.py` para power/toggles | pytest | pytest | pending |
| CCS-038 | Fallback user `misael` | Tirar hardcoded dos scripts waydroid/steamdeck | grep | hermético | pending |

Fora deste plano (apontar, não executar aqui):

- WBR-001/003/005/006 físicos, WBR-007 wizard → roadmap WinVM.
- Compose healthchecks, digest, appliance Hermes/9Router, `restore --plan` semântica profunda de volumes → roadmap Homelab. CCS-004 só alinha flags da Central.
- Temas Wallpaper Engine experimental.

## Fases e ordem de execução

1. **Fase 0** — PRs pequenos, paralelizáveis em worktrees distintos, sem mutar host: CCS-002, 003, 004, 005, 006, 007. CCS-000 é ops do operador (não código).
2. **Fase 1** — CCS-013 e CCS-010 primeiro (navegação + host). Depois 011/012, 015, 016, 017/018, 019, 020, 021, 014.
3. **Fase 2** — higiene quando Fase 0 verde.

Não abrir Fase 1 de Steam Deck page enquanto CCS-006 (OLED) estiver vermelho: a página herdaria o detector errado.

## Anti-escopo

Não fazer neste plano:

- Nova categoria na sidebar.
- Unificar Windows bootstrap e Linux.
- `homelab up` neste host.
- Boot WinVM “para ver se ainda quebra”.
- Terceiro router além de 9Router/OmniRoute.
- Appliance AI no compose.
- QML/plasmoid de cheatsheet Steam Deck (plano 2026-07-04 supersedido por yad; só reabrir com opt-in).

## Ledger de execução

| Data | Agente | Branch/worktree | IDs | Resultado |
|---|---|---|---|---|
| 2026-08-23 | Grok | diagnóstico em `main` `ea9b927` | — | Auditoria. Plano criado. Zero implementação |

## Handoff (modelo)

```text
Objetivo da sessão: <IDs CCS-xxx>
Branch e worktree: <dedicado, não WinVM/Homelab>
HEAD inicial / final:
Arquivos:
Testes e resultados:
Host mutado? (deve ser não, salvo CCS-000 ops)
Próximo ID exatamente:
```

## Definição de concluído

Plano v1 termina quando CCS-000..021 estão `verified` ou `deferred` com razão;
CCS-030..038 `verified`/`deferred`; CI verde nas suítes tocadas; wiki
`notes/surface-maturity-audit-2026-08-23.md` aponta para este arquivo como
fonte de execução (auditoria permanece histórica).
