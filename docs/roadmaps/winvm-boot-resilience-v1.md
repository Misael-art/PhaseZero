# Roadmap canônico — WinVM Boot Resilience v1

> Fonte operacional única para a frente de robustez do boot direto Windows.
> Este documento coordena implementação. Não prova conclusão. Commits, testes,
> CI e validação física são as provas.

## Metadados

| Campo | Valor |
|---|---|
| Status | Planejado |
| Criado | 2026-08-19, America/Sao_Paulo |
| Repositório | `/mnt/sdcard/Projects/PhaseZero` |
| Base | `main` em `1ccaf61` (pacote host `1.16.6-1`) |
| Incidente originador | Primeiro boot GRUB da VM atual (2026-08-19): NTFS sujo, Reparo Automático interrompido, janela QEMU pequena/baixa resolução, usuário leigo sem próximo passo |

## Missão

Um usuário leigo que iniciar o Windows pelo GRUB, pela UI ou pelo dock nunca
fica preso: toda falha tem causa removida automaticamente quando possível e um
próximo passo de um clique quando não. O encerramento de sessão nunca corrompe
o estado do guest. A imagem aparece sempre em tela cheia: 1280×800 no LCD do
Deck, resolução do monitor quando houver monitor.

## Análise do incidente (2026-08-19)

Evidência coletada em diagnóstico read-only do host:

1. **Windows não estava corrompido.** `qemu-img check` 0 erros; boot sector
   NTFS válido; `winload.efi`/`bootmgfw.efi`/BCD presentes; GPT padrão Win11.
2. **Volume NTFS sujo** (`ntfsinfo`: "Volume is scheduled for check"). Causa:
   as duas únicas sessões GRUB da VM (193 s e 36 s) terminaram com o QEMU
   encerrado com o guest vivo — log mostra `terminating on signal 1` e
   `tpm-emulator: Could not cleanly shutdown the TPM`. Fechar a janela do QEMU
   GTK encerra o processo (rc 0) sem shutdown do guest.
3. **Reparo Automático interrompido.** `SrtTrail.txt` inexistente: o reparo
   nunca concluiu porque a sessão acabou antes (36 s é pouco até para o
   diagnóstico). Cada relançamento sobre NTFS suja perpetua o loop.
4. **Tela pequena/baixa resolução.** Entrada GRUB rodava runtime instalado em
   **2026-07-25** proveniente do worktree `pz-winvm-display`
   (`configured_repo`), anterior a todos os fixes de display. O código em
   `main` (PR #54/#60) já resolve: handheld → 1280×800 eDP-1; docked → modo
   físico do monitor (KWin/EDID hash, refresh real, fallback 1080p).
5. **Detecção existente sem ação efetiva.** `runtime-check`/status já expõem
   `boot-runtime-stale` e a UI já mostra aviso + botão "reparar boot", mas o
   incidente ocorreu no caminho GRUB, fora do app, onde não há aviso algum.
6. **Padrão correto já existe isolado.** `recover.sh::stop_vm` faz
   QGA shutdown → espera 120 s → fallback. Nenhuma sessão de boot ou launch
   comum usa esse padrão.

## Princípios

- Nunca matar o guest vivo: encerramento gracioso é caminho feliz; kill é
  último recurso com registro explícito `unclean`.
- Toda superfície (UI, GRUB, sessão) comunica estado e próximo passo em
  linguagem leiga; nada de beco sem saída.
- Runtime do boot direto nunca diverge do pacote instalado por mais de uma
  interação com o app.
- Comportamento só é `verified` com prova: teste hermético, CI e, para
  display/shutdown, validação no hardware real.

## Requisitos (matriz de evidência obrigatória)

| ID | Requisito | Implementação esperada | Teste comportamental | Prova CI/hardware | Estado |
|---|---|---|---|---|---|
| WBR-001 | Encerramento de sessão gracioso | `windows-vm-session.sh`: launcher em background com monitor; fim de sessão (SIGHUP/TERM/INT, `shutdown.requested`) pede QGA `guest-login shutdown` → espera ≤120 s → TERM → 15 s → KILL; GTK com `confirm-quit=on` nos dois perfis (`5238f7d`) | `tests/test_windows_vm_session.sh`: stop-file e SIGTERM produzem sequência graciosa (`graceful:stop-file`, `graceful:signal`); `tests/linux-windows-vm-graphics.sh` cobre `confirm-quit=on` | hermética verde + runner 43/43; shutdown físico via GRUB pendente | in_progress |
| WBR-002 | Sem relançamento sobre estado sujo | Crash pós-estável recusa relançamento (pré-existente) e agora classifica `launcher-crash` como `graceful:false`; give-up registra `start-failure` sem tocar o convidado; `fallback_desktop` ganha kill-switch de teste | Suíte de sessão: crash ≥stable → rc propagado + `graceful:false`; start-failure limitado termina em give-up | hermética verde; CI `windows-vm-shell-test` agora roda a suíte (`c73f211`) | in_progress |
| WBR-003 | Reparo leigo de um clique | `status --json` emite finding `guest-unclean-shutdown` (warning) com orientação; página Windows VM mostra card "Windows foi desligado de forma inesperada. Inicie e deixe o reparo automático concluir" e mantém Iniciar habilitado; hint info para saída não verificada | `tests/test_windows_vm_ui.py`: pending-sync + unclean acionam botão/mensagem e estado limpo os oculta | pytest 575 + 9; ciclo real de reparo no host pendente | in_progress |
| WBR-004 | Runtime nunca stale após interação | Hook pós-transação grava `/var/lib/phasezero/windows-vm-runtime-sync.pending` (legível sem privilégio); `status --json` expõe `boot.bootRuntimePendingSync`; `boot install` consome o marker e grava `provenance.json` (fonte/versão/data) | `tests/test_boot_runtime_notice.sh`: stale→aviso+marker, current/ausente→silêncio, nunca falha transação; `linux-windows-vm.sh` asserts pendingSync true/false | hermética verde + E2E real no host: reinstalação 14:08 criou o marker e `status` instalado devolveu `pending:true` | in_progress |
| WBR-005 | Resolução correta em cada tela | Já implementado em `display-session.sh` (handheld 1280×800; docked usa modo do monitor por EDID hash do KWin, fallback 1080p; Deck primário opcional) — requisito é prova e regressão | Fixture `PZ_DISPLAY_SYSFS_ROOT` existente; falta caso dedicado de troca de monitor | validação física Deck LCD + monitor pendente | pending |
| WBR-006 | Tela cheia, controles e teclado virtual no boot GRUB | Entregue no main (PR #60); valida somente com runtime sincronizado (depende de WBR-004 física) | — | boot físico com evidência pendente | pending |
| WBR-007 | Escalada de recuperação guiada | Após 2 reparos sem sucesso, wizard encadeia `pz windows-vm recover` → WinRE guiado | Estado `repairFailed>=2` ainda não existe | hermética; físico opcional | pending |
| WBR-008 | Telemetria de sessão alimenta status | `session-state.json` versionado (graceful, reason, duração, display) gravado em todo fim de launch; `status --json` expõe `session` + findings por severidade | Suíte de sessão cobre os cinco motivos e o schema; status real no host devolve o bloco | hermética verde + host | in_progress |

Adicionar IDs, nunca reutilizar. Estados: `pending`, `in_progress`, `verified`,
`deferred`.

## Fases e gates

### Fase 0 — Baseline e fixtures

- Worktree dedicado; reproduzir incidente em fixture (launcher fake que "morre
  com guest vivo").
- Fixtures de display já suportam `PZ_DISPLAY_SYSFS_ROOT`.
- Gate: suíte nova executa em <60 s; baseline documentado aqui.

### Fase 1 — Ciclo de vida gracioso (WBR-001, WBR-002, WBR-008)

- Extrair padrão `stop_vm` para função compartilhada; aplicar na sessão GRUB e
  no launch comum.
- `confirm-quit` no GTK; ação de desligar nos controles.
- Registro de sessão versionado; status/UI consomem.
- Gate: hermética verde; 1 shutdown físico real via GRUB com registro `clean`.

### Fase 2 — Reparo leigo (WBR-003, WBR-007)

- Modo reparo (sem auto-kill, banner, timeout longo).
- Card de um clique na página Windows VM; wizard de escalada após 2 falhas.
- Gate: hermética verde; 1 ciclo real de reparo no host (NTFS suja → clean).

### Fase 3 — Runtime sob controle (WBR-004)

- Marker no hook pós-transação; card de sincronização com preview elevado.
- `boot install` fonte única = pacote; sobreposição de `configured_repo`.
- Gate: package-smoke; instalar pacote em ambiente de teste → card aparece →
  boot install → `runtime-check` `current`.

### Fase 4 — Validação física de display (WBR-005, WBR-006)

- Deck LCD: 1280×800, tela cheia, controles, teclado virtual.
- Monitor: modo do monitor com refresh real; troca a quente re-resolve no
  próximo boot.
- Gate: evidência registrada (log de sessão + foto) nesta seção.

### Fase 5 — Docs, changelog, release

- CHANGELOG, release notes, atualização deste roadmap.
- Gate: CI verde; release com checksums; instalação no host validada.

## Estado vivo

| Item | Estado atual | Verificado por | Data |
|---|---|---|---|
| Incidente originador | diagnosticado; sem mutação; correções ainda não aplicadas | diagnóstico read-only 2026-08-19 | 2026-08-19 |
| Runtime GRUB do host | `stale` (2026-07-25, worktree `pz-winvm-display`); sincronização pendente de autorização | `pz windows-vm boot runtime-check --json` | 2026-08-19 |
| VM atual | NTFS sujo; Reparo Automático não concluiu; disco estruturalmente são | `qemu-img check`, `ntfsinfo`, boot sector | 2026-08-19 |
| Implementação Fases 1–3 | WBR-001..004/008 implementados com testes herméticos (`da373f8`, `5238f7d`, `8a92aab`, `c73f211`, `095d674`); runner 43/43; pytest 575+9; ShellCheck paridade CI | `bash tests/runner.sh`, `pytest tests/` | 2026-08-19 |
| Pacote host | `1.16.6-1` reinstalado às 14:08 do HEAD `095d674`; hook criou `/var/lib/phasezero/windows-vm-runtime-sync.pending`; `status` instalado devolve `pending:true`, `stale:true` e bloco `session` | `pacman -Q`, `cat` marker, `pz windows-vm status --json` | 2026-08-19 |
| CI | runs `32279172680`/`32279456440` (ci) em andamento no push; gitleaks verde; confirmar verde antes de marcar `verified` | `gh run list` | 2026-08-19 |

## Ledger de execução

| Data | Agente | Branch/worktree | Fase | Commits | Gates | Resultado |
|---|---|---|---|---|---|---|
| 2026-08-19 | ZCode | `main` (diagnóstico) | — | `1ccaf61` (docs anteriores) | diagnóstico read-only | Incidente documentado; roadmap criado |
| 2026-08-19 | ZCode | `main` (worktree principal) | Fases 1–3 + testes CI | `da373f8` (sessão graciosa + estado), `5238f7d` (confirm-quit), `8a92aab` (marker/provenance/cards UI), `c73f211` (suítes no CI), `095d674` (AGENTS.md LF) | runner 43/43 (inclui suítes novas de sessão/notice/remoção); pytest 575+9; `linux-windows-vm.sh` verde; ShellCheck com excludes do CI; `git diff --check`; gitleaks verde | WBR-001..004 e 008 em `in_progress` (falta física). Acidente de sessão durante o desenvolvimento: `fallback_desktop` sob teste dentro do desktop logado aninhou um Plasma e derrubou a sessão KDE; corrigido com kill-switch de teste e análise de parentagem antes de matar processos. Pacote reinstalado 14:08; marker pending criado E2E. **Próximo**: CI verde; boot install autorizado (consome marker, grava provenance); boot físico p/ WBR-005/006; ciclo real de reparo p/ WBR-003 |
| 2026-08-20 | ZCode | `main` (worktree principal) | Reinstalação completa monitorada + avaria de armazenamento | `4ad7d3e` (provenance), `e982eee` (window-close), `ebb2a96` (sendkey em janela inteira) | provision 258/0; CI `ci` verde (run 32280269422); runtime `current` via bigsudo; reinstalação op-20260820-050749-32490: setup→drivers→tweaks(falhou 1×, resume ok)→verify→snapshot→relaunch→**completed 100%**; finalize com `--source provisioned`; preview de remoção limpo; duplicata órfã de 20 GB + staging limpos | Causas-raiz corrigidas no caminho: QEMU rejeitava `confirm-quit` (VM nem iniciava — agora `window-close=off`, provado no binário instalado); instalador travava para sempre no prompt "Press any key" (rajada de teclas por 21 s via QMP + teste comportamental). **Bloqueio real novo**: sob carga de I/O da VM, o btrfs reporta `csum failed` recorrente (10 eventos neste boot) e o QEMU derruba `aio failed` — corrupção de leitura transitória e recorrente; SMART do NVMe (NV530-1T) saudável, 52–59 °C, spare 100%. Suspeitas: RAM do host (não testada), SSD quente, ou interação `compress-force=zstd` + DirectIO. VM nova estruturalmente íntegra (`qemu-img check` ok) mas não inicia confiavelmente até validar o caminho de dados. **Próximo**: memtest86+; teste com VM em subvolume sem compress e `cache=writeback`; `btrfs scrub`; nova tentativa de boot somente após isso |

### Handoff — Fases 1–3 (2026-08-19)

```text
Objetivo da sessão: implementar a robustez de boot direto planejada
  (WBR-001..004, 008) após o incidente de NTFS suja/Reparo Automático.
Fase/IDs assumidos: Fases 1–3; WBR-001/002/003/004/008.
Branch e worktree: `main`, worktree principal.
HEAD inicial: `d54d9fc`.
HEAD final: `095d674` (+ docs deste registro).
Arquivos alterados: `linux/windows-vm/windows-vm-session.sh`,
  `linux/windows-vm/windows-vm.sh`, `linux/windows-vm/boot-runtime-notice.sh`,
  `linux/ui_native/pages/windows_vm.py`, `tests/test_windows_vm_session.sh`
  (novo), `tests/test_boot_runtime_notice.sh` (novo),
  `tests/test_windows_vm_remove.sh`, `tests/test_windows_vm_ui.py`,
  `tests/linux-windows-vm.sh`, `tests/linux-windows-vm-graphics.sh`,
  `tests/runner.sh`, `.github/workflows/ci.yml`, `CHANGELOG.md`, `AGENTS.md`
  (normalizado LF), este roadmap.
Commits criados: `da373f8`, `5238f7d`, `8a92aab`, `c73f211`, `095d674`,
  docs do roadmap.
Testes executados e resultados: runner 43/43 (suítes novas de sessão,
  notice e remoção incluídas); pytest 575 + 9 subtests; suítes individuais
  re-executadas após cada commit; `bash -n`; ShellCheck com os excludes do
  CI; `git diff --check`.
CI/PR: pushes `c73f211` e `095d674`; gitleaks verde; jobs `ci` em andamento
  (runs `32279172680`, `32279456440`) — confirmar verde antes de `verified`.
Estado do host antes/depois: pacote `1.16.6-1` reinstalado às 14:08 do
  HEAD `095d674` via `phasezero-admin pacman -U`; hook criou o marker
  pending; `status` instalado devolve `pending:true`/`stale:true`/bloco
  `session`; runtime GRUB segue de 2026-07-25 (boot install pendente de
  autorização); VM/disco/GRUB não mutados nesta sessão.
Segredos verificados como ausentes: diffs revisados; gitleaks verde.
Limitações e riscos restantes: (1) shutdown gracioso e reparo dependem de
  QGA ativo no convidado — sem agente, escala para TERM após 120 s e marca
  unclean; (2) saída rc=0 sem pedido continua indistinguível entre
  desligamento pelo menu Iniciar e fechamento confirmado — tratada como
  dica, não como dano; (3) validação física (WBR-005/006, ciclo de reparo
  real, shutdown via GRUB) pendente; (4) durante o desenvolvimento, um
  teste rodando a sessão real dentro do desktop logado derrubou a sessão
  KDE do usuário via `fallback_desktop` — kill-switch adicionado e
  guardado por revisão de parentagem antes de qualquer kill.
Bloqueios reais: nenhum técnico; boot install aguarda autorização.
Próximo passo exato: confirmar CI verde; com autorização, `phasezero-admin
  /usr/lib/phasezero/linux/pz windows-vm boot install` (consome o marker,
  grava provenance, sincroniza runtime 1.16.6); bootar VM pela UI, deixar
  o Reparo Automático concluir (WBR-003 física) e registrar
  `session-state.json` real; boot físico GRUB para WBR-005/006.
```

## Definição de concluído

Boot direto resiliente v1 termina quando: WBR-001..008 `verified` ou
`deferred` com razão; shutdown físico e ciclo de reparo provados no host;
runtime `current` após sincronização; evidência de display em LCD e monitor
registrada; CI verde em todas as frentes mergeadas.
