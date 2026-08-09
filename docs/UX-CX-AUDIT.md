# Auditoria CX/UX — Control Center Nativo + CLI Linux v1.15.1

Data: 2026-08-08
Alvo: `linux/ui_native` (PySide6) + CLI instalada `/usr/lib/phasezero/linux/pz` (v1.15.1-1)
Método: auditoria objetiva — 19 comandos executados na CLI instalada, suite pytest (437 testes), análise estática com verificação adversarial das claims. Sem entrevistas.

## Sumário executivo

- **Catálogo ↔ CLI: 476/476 ações, zero drift** (`pz commands --json` schemaVersion 2 == `build_catalog`). Fundação sólida.
- **Nenhum bug P0** (crash/perda de dados). **1 P1 funcional** (`pz doctor` trava) + **4 P1 de arquitetura/UX** + ~9 P2/P3.
- Webapp legada `linux/ui` e lado Windows fora de escopo; duplicações entre superfícies aparecem apenas como achados pontuais.

## Matriz funcional (evidência F1)

| Jornada | Comando | Latência | rc | Veredito |
|---|---|---|---|---|
| version | `pz version` | 18ms | 0 | OK |
| ai | `pz ai status` | 25,8s | 0 | P2 lento |
| routing | `ai routing status --json` | 1,9s | 0 | OK |
| windows-vm | `windows-vm status --json` | 28,8s | 0 | P2 lento |
| waydroid | `waydroid status` | 336ms | 0 | OK |
| emulation | `emulation status` | 562ms | 0 | OK |
| server | `server status --json` | 7,1s | 0 | P2 lento |
| flatpak | `flatpak status` | 153ms | 0 | OK |
| boot | `boot status` | 557ms | 0 | OK |
| homelab | `homelab status --json` | 30ms | 1 | Design: fail-closed (não configurado); JSON válido |
| capabilities | `capabilities detect` | 177ms | 0 | OK |
| updates | `updates check` | 24,5s | 0 | P2 lento |
| steamdeck | `steamdeck status` | 1,7s | 0 | OK |
| doctor | `pz doctor` | >120s | 124 | **P1 TRAVA** na seção `=== AI Tools ===` |
| pytest | suite completa | 586s | 437 ✓ 1 ✗ | flaky `qprocess_runner` + `offscreen_smoke` (timeout 30s) sob carga; isolados passam |

Nota: `pz commands --json` primeiro run >60s (cold start), depois 0,16s.

## Achados P1

1. **`pz doctor` trava >120s na seção "AI Tools"** (RC=124). Agravante: `tune.*` (Ajustes) e `system.support-bundle` (Visão geral) usam `preview=("doctor",)` (catalog.py:713, :171) — qualquer ação de Ajustes trava a UI no preview. Causa provável: checagem de LLM/AI sem timeouts.
2. **Código morto**: registry.py:64-71 substitui 5 páginas bespoke por `CatalogWorkspacePage` — `pages/windows_vm.py`, `waydroid.py`, `boot.py`, `flatpak.py`, `server.py` são dead code (~1200 linhas).
3. **Duplicata de label perigosa**: `"Instalar boot direto"` = `windows.boot.install` (catalog.py:279) + `waydroid.boot.install` (:358) — ambos elevated, mutáveis, mesmo ícone. Usuário não distingue qual GRUB altera.
4. **Duplicata de ação com contradição de segurança**: `homelab.restore` (catalog.py:374) vs `server.homelab.restore` (:396) — mesmo comando em 2 categorias, mesmo badge "Resgate". Catálogo anuncia `--yes`, mas a página Homelab usa `--plan` e recusa aplicar sem arquivo de confirmação (homelab.py:352-355). O comportamento seguro é o da página; o catálogo contradiz a superfície.
5. **"Executar" engana**: todo mutável roda `preview=action.mutable` (main_window.py:493); botão "Executar" do card (overview.py:154) e pill "Executar" abrem dry-run, nunca executam direto. Rótulo deveria ser "Prévia"/"Auditar" para mutáveis.

## Achados P2

6. **"Pronto" duplicado visível**: `status_text` (main_window.py:277) + `global_state` (:318), ambos "Pronto", na mesma operation row (:324).
7. **`global_state` sobrecarregado**: breadcrumb "Página:" (:403), "Selecionado:" (:408), "Busca global" (:416), eco do status (:512, :566), tail "Executando/Erro:" (:541), "Falha ao iniciar" (:660) — 6 papéis num QLabel.
8. **Contador de falhas nunca zera**: `_failure_count` incrementa (:573, :661); label "N falhas pendentes" (:677-684) sem reset — após 1 falha, badge permanente.
9. **`ai.opencode.status` duplicado**: `ai.opencode-status` (catalog.py:557) + `ai.opencode.status` (:867), mesma categoria IA & Dev.
10. **Tripla "IDE"**: "Configurar OpenCode + 9Router", "Configurar IDEs" vs "Configurar proxies nas IDEs" vs botão "Sincronizar IDEs" — 3 labels para ecossistemas relacionados.
11. **Trio PS3 ambíguo**: `ps3-game`/`ps3-pkg`/`ps3-rap` (catalog.py:511, :819, :820) — descrições quase idênticas, 2 escondidos em "advanced", mesmo preview.
12. **`emulation status` vs `emulation doctor`**: "Auditoria geral." vs "Auditoria completa do ecossistema." (:410 vs :442) — copy indistinguível.
13. **Latências sem UX de espera adequada**: windows-vm 28,8s / updates 24,5s / ai 25,8s / server 7,1s. "homelab status" rc=1 é correto por design (fail-closed).
14. **Testes flaky sob carga**: smoke 30s (tests/test_linux_native_ui.py:338) + envelope qprocess (:412) — falham na suite completa, passam isolados.

## Achados refutados (transparência)

- ✗ "Restore roda `--yes` sem plan" — **falso**: página usa `--plan`, recusa sem arquivo de confirmação. Segurança boa; achado real é só a inconsistência do catálogo (#4).
- ✗ "Botão Atualizar leva a doctor" — **falso**: é `refresh_status` do homelab (homelab.py:57-59).
- ✗ "Editor de fallbacks nunca populado" — **falso**: existe e é populado (ai_routing.py:105-125).

## Oportunidades visuais (baseline `docs/design-qa.md`)

- Separar visualmente "prévia (dry-run)" de "execução real" — escudo/lupa vs play.
- Unificar badges de risco: 3 estilos atuais ("Alto risco"/"Elevado"/elevated) → 1 sistema.
- Cards mutáveis: botão "Prévia" em vez de "Executar" (achado #5).
- Estados de loading longos (>5s): skeleton ou linha "verificando X de Y".

## Correções propostas (PRs separados)

| PR | Escopo | Esforço | Status |
|---|---|---|---|
| 1 | `pz doctor` hang (timeouts em AI Tools) + remover `preview=("doctor",)` dos tune.* | M | Merged (#40, `b94f5fc`) |
| 2 | Remover dead pages + limpar registry.py | S | Merged (#41+46, `6f28407`) |
| 3 | Deduplicar catálogo: `server.homelab.restore`, `ai.opencode.status`, unificar label boot direto | S | Merged (#42, `f0dd05e`) |
| 4 | UX core: rótulo "Prévia" para mutáveis, reset do contador de falhas, separar papéis do `global_state` | M | Merged (#43, `6a08b9b`) |
| 5 | Labels/copy: trio PS3, emulation status/doctor, tripla IDE | S | Merged (#44, aguardando pester) |
| 6 | Flaky tests: subir timeouts + isolar smoke | S | Merged (#45, `d56cf7e`) |
| 7 | Performance: windows-vm status 28s (não bloqueante) | L | Encerrado sem mudança — não reproduzível |

**P0: nenhum.** P1#1 (doctor) é o único bug funcional — atinge a ação de suporte mais usada em crise.

**PR 7 (encerrado):** a medição de 28,8s ocorreu sob carga pesada do próprio audit (todas as rotinas `status` paralelas na mesma máquina; updates 24,5s e ai 25,8s na mesma rodada). `status_json` não contém sleeps nem timeouts fixos. Verificado standalone após os merges: `windows-vm status --json` em 1,57s (rc=0, 2929 bytes). Sem intervenção.
