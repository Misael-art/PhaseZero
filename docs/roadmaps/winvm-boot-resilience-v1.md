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
| WBR-001 | Encerramento de sessão gracioso | Ao terminar sessão GRUB/launch (fechar janela, logout SDDM, SIGTERM, fim de compositor): QGA `guest-login shutdown` → ACPI `system_powerdown` → espera (≤120 s) → kill apenas como último recurso; reutilizar padrão de `recover.sh::stop_vm`; QEMU GTK com `confirm-quit` para evitar fecho acidental; combo/botão "Desligar Windows" sempre alcançável (controles evdev já previstos) | Suíte com QEMU fake via `PZ_WINDOWS_VM_RUNTIME_LAUNCHER` stub: fecho de janela/sinais produzem sequência QGA→ACPI→kill e registram `clean`/`unclean` | hermética + validação física (1 shutdown real via GRUB) | pending |
| WBR-002 | Sem relançamento sobre estado sujo | Retry loop da sessão (`windows-vm-session.sh`) não relança automaticamente após término `unclean` ou falha rápida do launcher; em vez disso encerra com motivo e deixa estado acionável | Fixture: launcher falha 2× rápido → sessão NÃO reexecuta; grava `lastSessionUnclean` | hermética | pending |
| WBR-003 | Reparo leigo de um clique | Status detecta `unclean` persistente (flag de sessão + falha de boot repetida) e a UI oferece card "Windows precisa de reparo — Reparar agora": inicia VM em modo reparo (sem auto-kill, banner "não desligue", timeout ≥15 min), deixa chkdsk/Reparo Automático concluir; sucesso = próximo boot com sessão `clean` | Suíte: modo reparo não mata por timeout curto; sucesso/falha atualizam estado e card some | hermética + 1 ciclo real de reparo no host | pending |
| WBR-004 | Runtime nunca stale após interação | Hook pós-transação do pacote grava marker de versão; app na bandeja/página Windows mostra "Preparar boot Windows (1 clique)" com fluxo elevado preview-first já existente (`windows.boot.install`); `boot install` copia SEMPRE da fonte do pacote `/usr/lib/phasezero`, nunca de worktree; `configured_repo` de worktree é sobreposto e reportado | Teste: runtime divergente + marker → card aparece; boot install com repo configurado de worktree usa pacote; runtime-check volta `current` | hermética + package-smoke | pending |
| WBR-005 | Resolução correta em cada tela | Handheld (só eDP): 1280×800@refresh do painel; docked: modo físico do monitor (preferência KWin por EDID hash → EDID nativo → 1080p), Deck pode permanecer primário (`PZ_DISPLAY_PRIMARY_TARGET=internal`); já implementado em `display-session.sh` — requisito é prova e regressão | Fixture `PZ_DISPLAY_SYSFS_ROOT` com EDID/modes falsos: handheld e docked resolvem como especificado; monitor trocado re-resolve | hermética + validação física Deck LCD e monitor 2560×1080 | pending |
| WBR-006 | Tela cheia, controles e teclado virtual no boot GRUB | Já entregue em main (PR #60: evdev, virtio-multitouch GTK/Gamescope, teclado virtual); requisito é validar no runtime sincronizado (depende de WBR-004) | — | boot físico com evidência (foto/log de sessão com resolução e controles) | pending |
| WBR-007 | Escalada de recuperação guiada | Após 2 reparos sem sucesso, wizard leigo encadeia: `pz windows-vm recover` (offline QGA) → último recurso guiado WinRE (prompt para `chkdsk C: /f` com instruções passo a passo na UI); nunca automático sem consentimento | Suíte: estado `repairFailed>=2` oferece wizard; recover invocado com argumentos corretos | hermética; físico opcional | pending |
| WBR-008 | Telemetria de sessão alimenta status | Fim de cada sessão grava registro versionado (`session-state.json`: clean/unclean, duração, motivo, resolução usada); `status --json` e página Windows VM expõem; estado `unclean` sem reparo deixa card visível | Suíte: sessões fake clean/unclean refletem no status e na UI offscreen | hermética | pending |

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

## Ledger de execução

| Data | Agente | Branch/worktree | Fase | Commits | Gates | Resultado |
|---|---|---|---|---|---|---|
| 2026-08-19 | ZCode | `main` (diagnóstico) | — | `1ccaf61` (docs anteriores) | diagnóstico read-only | Incidente documentado; roadmap criado |

## Definição de concluído

Boot direto resiliente v1 termina quando: WBR-001..008 `verified` ou
`deferred` com razão; shutdown físico e ciclo de reparo provados no host;
runtime `current` após sincronização; evidência de display em LCD e monitor
registrada; CI verde em todas as frentes mergeadas.
