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

## Rodada seguinte — UX-009 replicado pelo catálogo real (510eeed)

A jornada de referência só tinha sido provada com um app sintético. Agora ela é
exercida uma vez por app real do catálogo.

| Mudança | Prova |
|---|---|
| `firstUse.stepsPtBr` para os 10 apps user-facing (+ node-exporter); `steps` continua sendo a cópia inglesa do CLI | teste parametrizado percorre não instalado → preparando → configurar acesso → pronto para usar, por app, conferindo `openUrl` e cada passo no card |
| `journey.first_use_steps` prefere `stepsPtBr`, com fallback para `steps` | app sem tradução não fica sem texto; teste de cobertura exige tradução para todo user-facing |
| Abrir a solução deixou de marcar primeiro acesso sozinho | operador confirma os passos da própria solução; "Ainda não" mantém o card em Configurar acesso — abrir página não é conta criada |
| Contrato pt-BR no CLI | `tests/linux-homelab.sh` exige `stepsPtBr` do mesmo tamanho e diferente de `steps`; `apps list --json` real devolve a cópia pt-BR |

## Falha de suíte investigada — canal de instalação (60104a5)

A execução completa de pytest acusou `test_installation_manager.py::test_status_reports_channel_and_root_conflicts`.
Não era teste frágil nem efeito do diff de UX: `manager.status()` derivava o canal
`user` de `XDG_DATA_HOME` sempre que a variável existisse, enquanto o home vinha de
`_target_account()`. Sob sudo/pkexec — como o admin bridge chama `pz` — as duas
fontes discordam, e uma instalação de usuário presente era reportada como ausente,
com `activeChannels` e conflitos errados. `XDG_DATA_HOME` passa a valer só quando
pertence ao home da conta alvo. Dois testes novos cobrem o caso elevado e o comum.

Resultados destas duas rodadas: **pytest 866 passaram, 0 falhas** (antes 863/1, e a
falha só aparecia com `XDG_DATA_HOME` exportado) e **`tests/linux-homelab.sh` exit 0**,
reexecutada após os dois commits. A suíte shell é hermética: `HOME`/`XDG_*`/estado em
`mktemp -d`, `PZ_HOMELAB_APPS_NO_DOCKER=1`, WinVM stubbado por arquivo. Segue sendo
aceite local: nenhum app foi instalado de verdade, nenhuma conta criada em servidor
real, nenhuma medição com participantes.

## Rodada UX-005/007 — escolha indisponível deixa de fingir instalação (7099ef4)

Diagnóstico antes de mexer, contra o CLI real: **todo perfil do catálogo tem
`installable=false`** (`assistant-private`, `developer`, `automation`, `ai-studio`,
`edge`, `assistant-multichannel`). `prepare --dry-run --profile edge` reserva
1664 MiB e devolve `apps: [jellyfin, syncthing, vaultwarden, uptime-kuma]`, enquanto
`profileServices: [zeroclaw, 9router]` — o que o perfil promete — não é instalado.
O aviso de orçamento já existia; a execução seguia mesmo assim. Era exatamente o
que o aceite de UX-005 proíbe, e não um caso de borda: é o comportamento de todo
perfil hoje.

| Mudança | Prova |
|---|---|
| Plano revisado com perfil sem receita não executa sozinho; a página nomeia os serviços que ele não instala e exige decisão explícita | cancelar não roda comando nenhum; "só reservar recursos" roda apenas `profile set`; "instalar base do servidor" roda `prepare` sem perfil; perfil instalável executa o plano revisado sem perguntar |
| `journey.plan_simulation_refusal` nomeia serviços e nota | recusa cita `zeroclaw`, `9router` e `zeroclaw worker not implemented` |
| UX-007: plano resumido em `journey.plan_summary` num widget — servidor, apps, acesso, memória, etapas | resumo confere as cinco linhas e não contém argv nem flags (`--json`, `--dry-run`, `--profile`, `dryRun`, `appsSource`); JSON permanece na Saída para a visão avançada |

Dois testes R01-003 fixavam a redação antiga do aviso no log; foram reescritos contra
a invariante (verdade do perfil orçamento afirmada na interface), agora conferida no
widget e no log. Resultado desta rodada: **pytest 872 passaram, 0 falhas** e
**`tests/linux-homelab.sh` exit 0**.

Sem captura visual nesta rodada — o aceite é por controle e por comando executado,
não por layout. Limites anteriores continuam valendo.

## Rodada UX-006 — o card do objetivo chega à jornada que promete (a4ad262)

Diagnóstico antes de mexer: o Início oferecia objetivos, mas cada card disparava
uma ação do catálogo e deixava o resto da jornada para ser achado na barra
lateral. **Não existia card de Windows.** "Cuidar de outro computador" executava
`homelab.hosts` — uma listagem JSON —, não o pareamento. A faixa de primeiro uso
exigia IA duas vezes: `ai.compat` e `ai.backup.export` ("Exportar memória e
acessos", ação da categoria IA & Dev). Não havia retomada de tarefa recente.

| Mudança | Prova |
|---|---|
| `BasePage.category_requested(categoria, foco)` + hook `focus_journey`; `MainWindow.show_journey` abre o destino e pede a etapa de entrada | clique real no card navega: `current_category` e o widget do stack passam a ser a página do destino |
| Objetivos com destino: hospedar → Homelab (fluxo do começo); cuidar de outro computador → Homelab na etapa **pair**; novo objetivo **Instalar e usar Windows** → Windows VM no controle de instalação | teste parametrizado confere `(destino, foco)` por card; pareamento chega em `onboard_step_name() == "pair"` com confirmação de outro host descartada; Windows chega com `focusWidget()` no controle de instalação |
| Primeiro uso sem IA: diagnosticar + preparar este computador | teste cruza os ids usados na faixa com todas as ações das categorias de IA e exige interseção vazia; IA continua ofertada como um objetivo entre outros |
| Retomar tarefa recente, com o estado real, voltando à página dela | ledger com operação `interrupted` produz card "Tarefa interrompida · Preparar Homelab"; clique pede a categoria certa; primeiro uso não mostra o card |

Bug encontrado no caminho: o Início construía `OperationLedger(root)` com a **raiz
do repositório** em vez do diretório de estado, enquanto todo o resto usa
`OperationLedger()`. O ledger procurava `<repo>/*/operation.json`, nunca achava
nada, e por isso todo start parecia primeiro uso — "Bem-vindo de volta" nunca
aparecia e não havia o que retomar. Sem essa correção, a retomada seria um card
que jamais apareceria em uso real.

Dois testes de contrato existentes fixavam o comportamento antigo (cinco cards com
rótulo único; passos de IA no primeiro uso) e foram atualizados à nova regra.
Resultado desta rodada: **pytest 883 passaram, 0 falhas**. Não reexecutei
`tests/linux-homelab.sh` — o diff é só de UI nativa e não toca o backend do
homelab.

Sem captura visual: o aceite aqui é por destino alcançado e por controle em foco,
não por layout. Continua sendo aceite local — nenhuma jornada foi percorrida por
um participante real, e o pareamento remoto de verdade (R2/UX-008) segue pendente.

## Próxima etapa

UX-005/006/007/009 têm aceite local pelas rodadas acima: jornada por app real,
instalação distinta de simulação de orçamento, plano em linguagem de produto,
recuperação por controle visível e objetivos do Início que chegam à jornada que
prometem. O que a direção original pedia e ainda **não** foi feito: medir a jornada
com quem não conhece o produto, e prová-la contra um servidor de verdade — instalar
um app, criar a primeira conta, abrir a solução. Nenhum destino de objetivo foi
percorrido até o fim contra hardware real.

Em aberto no roadmap: R2/UX-008 (primeiro pareamento remoto), R3/UX-010 (contrato
gráfico do Windows) e UX-011 (acessibilidade e usabilidade). Permanecem pendentes tema light, escala150/200%, leitor de tela,
usabilidade com participantes, CI/PR/release, banco↔anexos e snapshots por serviço.
Não verifiquei a falha dualscreen alegada pelo agente.

## Handoff

```text
Objetivo: verificar retorno de70d959f e fechar contrarrevisão UX-001..004.
Branch/worktree: codex/verify-ux-70d959f; /mnt/sdcard/Projects/pz-verify-ux-70d959f-tree.
HEAD inicial:70d959f; documental 4e318a9; jornada 510eeed; canal de instalação 60104a5; UX-005/007 7099ef4; UX-006 a4ad262.
Arquivos: reports/verify-ux-70d959f; notas Estado vivo/Ledger Homelab e roadmap REV.
Testes: validation.json/pytest-final.txt; QA dark e medidas de viewport.
Depois: pytest completo883 verde; tests/linux-homelab.sh exit0 (última execução na rodada UX-005/007).
CI/PR: nenhum; host sem alteração de workloads/serviços/VM/boot/pacotes.
Segredos: ambiente allowlist, fixtures sintéticas, diff revisto; gitleaks não executado.
Limitações: aceite local; demais UX e certificação física continuam pendentes.
Próximo passo: UX-005/006/007/009 com aceite local; faltam R2/UX-008 (pareamento)
e R3/UX-010 (contrato gráfico); UX-011 segue aberto.
```
