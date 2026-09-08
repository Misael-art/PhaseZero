# Verificação independente — 70d959f

Data de fechamento: 2026-09-08. Escopo: UX-001..004, correções c784373 e documentação8c7a3d3/70d959f. Nenhuma alteração de produto nesta revisão.

## Parecer

**Aceite local de UX-001..004: 117 testes passaram** (Player49, Windows VM30, agente/web38). Correções de código e QA dark confirmadas localmente. Resultado final dos testes em [validation.json](validation.json) e [pytest-final.txt](pytest-final.txt). Não equivale a release, instalação limpa ou teste físico.

| Item | Prova independente |
|---|---|
| UX-001 | Só uma definição de _refresh_onboard_label. Na etapa review, confirmação hidden:false, enabled:true, visibleRegion não vazio. Teste público agora exige visibilidade e habilitação, retângulo inteiro e QApplication.widgetAt antes de enviar clique. |
| UX-002 | Planos com16000→15999MiB, mesmos apps e ambos pass, disparam execução simulada. Suite cobre mudança material e verdict fail. |
| UX-003 | MainWindow + tema dark, alternância800→1280→800: máximos horizontais zero. Conteúdo rolável, controles do header/onboarding legíveis. |
| UX-004 | Mesma alternância: máximos horizontais zero. Em800, botão Iniciar termina emx708 contra limite737; totalmente dentro do viewport. |

[Probes/medidas](probes.json) · [Homelab800](Homelab-800.png) · [Windows800](Windows-VM-800.png) · [Homelab1280](Homelab-1280.png) · [Windows1280](Windows-VM-1280.png).

`review_button.confirmed:false` no probe é intencional: esse cenário verifica que Avançar sozinho não confirma revisão; clique de confirmação é coberto pelo teste público da suíte. Não representa regressão.

Reprodução visual: `python reports/verify-ux-70d959f/verify.py`. Wrapper cria ambiente allowlist e HOME/XDG temporários, intercepta status, bloqueia serviços. Capturas demonstram layout, não prontidão real de servidor/VM. Primeira tentativa de harness foi interrompida durante renderização lenta; log misto de tentativas foi descartado como prova. Rodada final de pytest usa arquivo e basetemp exclusivos.

## Próxima etapa aprovada como direção

Avançar UX-005/007/009: modo simples por jornada, separando instalação de simulação de orçamento, com estado funcional, ação principal, configuração de acesso e Abrir solução. Preferir um fluxo completo de referência antes de replicá-lo pelo catálogo.

Aceite sugerido: usuário escolhe destino e app instalável, revisa impacto, instala, configura primeiro acesso, abre solução e retoma após erro. Testar somente por controles apresentados, dentro de MainWindow/tema real. JSON, logs, política e orçamento ficam em detalhes avançados; não se tornam requisito para operar.

Depois R2/UX-008 (primeiro pareamento) e R3/UX-010 (contrato gráfico). Permanecem pendentes tema light, escala150/200%, leitor de tela, usabilidade com participantes, CI/PR/release, banco↔anexos e snapshots por serviço. Não reexecutei suíte shell sem mudanças nem pytest completo/falha dualscreen alegada pelo agente.

## Handoff

```text
Objetivo: verificar retorno de70d959f e fechar contrarrevisão UX-001..004.
Branch/worktree: codex/verify-ux-70d959f; /mnt/sdcard/Projects/pz-verify-ux-70d959f-tree.
HEAD inicial:70d959f; final: commit documental via git log.
Arquivos: reports/verify-ux-70d959f; notas Estado vivo/Ledger Homelab e roadmap REV.
Testes: validation.json/pytest-final.txt; QA dark e medidas de viewport.
CI/PR: nenhum; host sem alteração de workloads/serviços/VM/boot/pacotes.
Segredos: ambiente allowlist, fixtures sintéticas, diff revisto; gitleaks não executado.
Limitações: aceite local; demais UX e certificação física continuam pendentes.
Próximo passo: UX-005/007/009 com jornada de referência completa; depois R2/R3.
```
