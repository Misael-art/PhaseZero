# Apps, desenvolvimento, IA e contas — proposta de produto v1

Data: 2026-09-24. Base examinada: `889d132`. Estado: **implementação iniciada; aceites pendentes**.
Solicitação: reorganizar escolhas e gestão de apps, preparar ambientes de desenvolvimento,
centralizar contas e avaliar a integração opt-in apresentada no vídeo de Elton Machado.

## 1. Diagnóstico e limites da evidência

A arquitetura de execução já oferece peças reutilizáveis. O principal problema de produto
é a distribuição das decisões: a pessoa precisa conhecer a implementação para encontrar
uma ferramenta. Mover botões, sem unificar identidade e estado, apenas muda essa dificuldade.

| Evidência no código | Consequência | Direção proposta |
|---|---|---|
| `linux/ui_native/catalog.py`: Perfis, Recursos, Ajustes, IA & Dev, Proxies IA e Roteamento IA são categorias separadas | Mesmo objetivo exige navegar por vocabulários técnicos diferentes | Navegação por objetivo, destino canônico por app |
| `profiles/dev-ai.json`: linguagens, editores, bancos, containers, IA e scripts; habilita Docker, Ollama, SSH e Tailscale | Escolher desenvolvimento pode trazer serviços além da necessidade inicial | Receitas compostas, dependências explícitas, serviços opt-in |
| `pages/profiles.py`: seleção de perfil e instalação | Pouco apoio para comparar alternativas e entender custo de recursos | Assistente por objetivo com revisão do plano |
| `linux_hub.py`, `pages/linux_hub.py`, capabilities e `ActionSpec` já integram ações | Há infraestrutura útil; não é necessário outro instalador | Reutilizar plan/apply, runner e ledger |
| Hermes/LLM aparecem em contextos de servidor e IA; IDEs e runtimes também em Recursos | App, instância e finalidade ficam visualmente misturados | Um registro de produto; várias instâncias e atalhos contextuais |
| `pages/ai_proxies.py` apresenta inventário de autenticação agregado e explicitamente sem identidade | Não atende foto, conta individual e autorização por consumidor | Visão privada de contas separada da telemetria redigida |
| `linux/ai/auth-registry.sh` agrega grupos; presença local de credencial participa de estados de autenticação | Credencial encontrada não prova sessão válida; indisponibilidade pode parecer logout | Evidência, validade e frescor explícitos por dimensão |

Contagem do catálogo nesta base: 90 ações em IA & Dev, 37 em Proxies IA, 10 em
Roteamento IA, 98 em Recursos e 15 em Perfis. São ações registradas, **não** botões
simultaneamente expostos. Duplicação de apresentação não prova instalação duplicada.

Análise estática do código e documentação; não certifica usabilidade ou operação real.
Windows VM e Homelab permanecem destinos próprios. A avaliação positiva do usuário é
premissa de escopo, não nova certificação técnica dessas superfícies.

## 2. Organização proposta

| Destino | Pergunta respondida | Conteúdo principal |
|---|---|---|
| Início | O que precisa da minha atenção? | Jornadas, operações pendentes e retomar trabalho |
| Aplicativos | O que usar e o que já tenho? | Descobrir, comparar, instalados, atualizar, remover |
| Desenvolvimento | Como preparar este projeto? | Ambientes, linguagens, versões, editor, bancos e containers |
| Inteligência artificial | Qual assistente e qual origem usar? | Assistentes, modelos locais/nuvem, conexões e diagnóstico |
| Contas e conexões | Quem está conectado e quem pode usar? | Contas, chaves, permissões, instâncias, cotas e canais disponíveis |
| Plataformas | Onde executar? | Windows VM, Homelab, Steam Deck, Waydroid, Emulação e Servidor |
| Sistema | Como personalizar esta máquina? | Linux, recursos de sistema, ajustes, boot e temas |
| Atividade | O que aconteceu e como recuperar? | Resultados, operações, falhas e reversões disponíveis |

Destinos podem ser grupos com páginas; não transformar cada seção em outro item lateral.
Perfis vira entrada contextual “Preparar máquina” no Início e modelos de ambiente em
Desenvolvimento. Flatpak vira fonte de instalação em Aplicativos. Recursos de sistema
continuam em Sistema; linguagens e ferramentas recebem atalhos nas jornadas adequadas.
Proxies e roteamento ficam em **Inteligência artificial → Conexões → Avançado**.
Disponibilidade, custo e origem efetiva continuam visíveis no modo simples.

Mudança de escopo deliberada em relação ao “não adicionar superfície nova” de
`control-center-surfaces-v1.md` e ao escopo anterior de `linux-ux-v1.md`: esta solicitação
autoriza propor nova organização. Não remove gates operacionais daqueles roadmaps.

### Um app, vários contextos

Introduzir `appId` estável e registro canônico: nome, finalidade, alternativas, plataformas,
fontes de instalação, ações existentes, requisitos, conflitos, maturidade e capacidades.
Instância separada: `instanceId`, `appId`, host, escopo, versão, gerenciador, recursos e
estado observado. Exemplo: Ollama local e Ollama no Homelab são duas instâncias do mesmo
produto. Seus dados, portas e consumidores não podem ser confundidos.

Atalhos de Desenvolvimento, IA e Servidor abrem o mesmo detalhe, com contexto preservado.
Não duplicar backend nem remover IDs antigos: aliases de navegação mantêm busca e favoritos.
Catálogo global indexa finalidade e sinônimos (“Python”, “programar”, “chat local”).

Cada detalhe mostra: para que serve; quando escolher; local/nuvem; conta necessária;
recursos estimados e medidos separados; origem; status; ação principal; alternativas.
Comparação começa pela categoria funcional: editor, agente, runtime de modelos, router,
proxy de provedor, monitor de consumo. Ferramentas de categorias diferentes não são
apresentadas como substitutas. VS Code/VSCodium são comparáveis; Ollama/9Router não.

Estado orienta CTA: não instalado → Preparar; instalado sem configuração → Configurar;
configurado sem evidência recente → Verificar; pronto → Abrir/Usar; falha → Resolver.
“Instalado” nunca equivale automaticamente a “pronto”. Remover informa dependentes e dados
preservados. Detectar instalação externa não autoriza adotá-la ou removê-la silenciosamente.

### Desenvolvimento por objetivo

Fluxo: objetivo → projeto/escopo → escolhas recomendadas → revisão → preparação → validação.
Receitas iniciais: Web JS/TS, Python/dados, Rust, C/C++, Java/.NET e desenvolvimento com IA.
Escolha de editor independente; IA, banco, Docker e acesso remoto opcionais. Não selecionar
todos os runtimes nem habilitar serviços por escolher “desenvolvimento”.

Reusar `linux/capabilities` e perfis existentes como backend. Primeiro transformar o perfil
atual em receita legada claramente descrita; depois introduzir composição. Ambiente por
projeto pode fixar versões sem substituir Python do sistema. Revisão mostra downloads,
espaço, administrador, serviços, reinício, conflitos e o que já existe. Instalação retomável,
idempotente, cancelável entre etapas seguras; falha informa etapa e recuperação.

Registrar propriedade e dependentes antes de oferecer remoção compartilhada. Nunca remover
runtime ainda usado por outra receita ou pacote preexistente. Em Windows, escolher uma fonte
por pacote e detectar duplicidade entre winget/Chocolatey; não unificar seus executores com
`linux/pz`. Arch limpo e Windows limpo exigem aceites separados.

### Modo simples e avançado

Simples padrão: estado, recomendação explicada, próximo passo e ação principal. Opções
avançadas persistentes por usuário/dispositivo: versões, gerenciadores, endpoints, rotas,
políticas e logs. Avisos de custo, permissões, reinício e perda de dados nunca ficam ocultos.
Não usar o modo avançado como requisito para recuperar uma falha comum.

## 3. Contas, conexões e cotas

Não existe login universal: cada integração declara quais dados pode consultar e quais
consumidores suporta. Conectar conta não autoriza exportar cookies/chaves para todos os apps.

Modelo proposto, versionado e compatível com o resumo atual:

- `Account`: ID opaco, provedor, workspace/tenant, apelido, identidade opcional, avatar opcional,
  referência ao armazenamento seguro. Nenhum segredo no payload da UI.
- `Connection`: conta + adaptador + instância + habilitação; capacidades declaradas e observadas.
- `Grant`: consumidor/instância, conta/conexão, escopo e consentimento. Revogação independente.
- `Observation`: origem, instante observado, instante efetivamente verificado, expiração, erro
  tipado. Não carimbar “verificado agora” apenas porque um arquivo existe.
- `Quota`: dimensão/modelo, unidade, total/restante quando conhecido, janela/reset quando
  informado, fonte e confiança (`official`, `local_estimate`, `unknown`).

Dimensões independentes: credencial armazenada; sessão válida/expirada/desconhecida;
instância online/offline/desconhecida; acesso ao modelo/ferramenta permitido/negado/desconhecido;
cota disponível/esgotada/desconhecida. Timeout não significa logout. Cota desconhecida não
vira zero nem ilimitada. Saldo de API, mensagens de assinatura e estimativas locais não se somam.

Tela “Minhas contas”: avatar ou iniciais, apelido, provedor/workspace, estado com horário,
cota com fonte, consumidores autorizados; ações conectar novamente, verificar, pausar uso,
revogar consumidor e desconectar. “Adicionar conexão” lista canais compatíveis, requisitos,
tipo de login e maturidade. “Chaves de API” mostra rótulo, escopo e identificação mascarada.

Identidade só mediante interface suportada e consentida; se indisponível, permitir apelido
local. Avatar não bloqueia login: cache com limite de bytes, tipo validado, sem SVG ativo,
sem URL arbitrária acessando rede local, iniciais como fallback. Modo privacidade oculta
identidade na tela. Exportações e diagnósticos continuam redigidos; não desfazer mascaramento
recém-corrigido no AISR. Segredos via cofre do SO/adaptador já proprietário; nunca argv ou logs.

Monitor assíncrono com cancelamento, prazo por adaptador e prazo global, cache, backoff e
jitter. Polling somente conexões habilitadas; sem prompts pagos para atualizar status.
Retornar resultados parciais; resposta tardia de outra conta não atualiza a seleção atual.
Limites iniciais propostos: cache de 60s e deadline agregado de 10s, ajustáveis após medidas.

Consumidor recebe referência/endpoint adequado, não cópia indiscriminada da credencial.
Conexão incompatível deve explicar o motivo. Mudança de conta, rota ou fonte cobrada exige
escolha explícita. Não alternar contas para contornar limites. Logout local, revogação no
provedor e remoção de credencial são ações distintas; informar o alcance de cada uma.

## 4. Solução do vídeo: avaliação e integração proposta

Vídeo: [Usei o Codex a semana inteira e gastei 2% da cota](https://www.youtube.com/watch?v=Hh8VYR_pOQ8&t=21s).
Título, descrição e capítulos consultados. Legenda retornou vazia; não houve análise integral
do áudio nem reprodução do experimento. A descrição aponta para
[codex-chatgpt-web](https://github.com/miuuyy/codex-chatgpt-web).

Snapshot upstream: `main` em `757942251222ee0f71953c35636679c6d92dd636`;
release publicada `v6.0.0`, 2026-09-23. Referências móveis devem ser novamente conferidas
na implementação; release observada não está certificada pelo PhaseZero.

É integração comunitária de ChatGPT Web no Codex, com consumo associado à conta ChatGPT.
O relato de 2% não demonstra economia universal: assinatura, limites, outros usos e modos
continuam relevantes. Os pacotes anunciados incluem Linux x64 e Windows x64, ainda sem
assinatura de plataforma. Verificar checksum não equivale a assinatura ou auditoria.
[Fonte: README](https://github.com/miuuyy/codex-chatgpt-web).

A arquitetura documenta bridge local, browser privado e ferramentas opcionais via MCP.
O launcher supervisiona runtime e pode ter início no login. Seus pacotes incluem componentes
de execução; modo completo usa tunnel-client separado. Isso não prova ausência de bibliotecas
nativas faltantes num Arch mínimo. Sua estimativa local de consumo não inclui uso externo.
[Fonte: arquitetura](https://github.com/miuuyy/codex-chatgpt-web/blob/main/docs/architecture.md).

O upstream reconhece fragilidade diante de mudanças na UI do ChatGPT e o limite de proteção
contra processos do mesmo usuário. Seu bridge não deve ser tratado como serviço multiusuário
seguro apenas por escutar em loopback.
[Fonte: modelo de segurança](https://github.com/miuuyy/codex-chatgpt-web/blob/main/docs/security-model.md).

O túnel oficial usa conexão de saída e requer identidade de túnel, chave de runtime e servidor
MCP alcançável. Não é licença automática para executar ferramentas.
[Fonte: Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels).
Disponibilidade de ferramentas de escrita depende de plano/workspace/admin; validar a capacidade
real, não inferir de “Pro” ou de login bem-sucedido.
[Fonte: Developer mode e MCP](https://help.openai.com/en/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt).

### Contrato desejado no PhaseZero — requisitos, não funcionalidades já comprovadas

Nome de produto: **ChatGPT no Codex — experimental**. Entrada em IA → Integrações, registro
no catálogo e conexão em Contas. Não classificá-lo como mais um provedor genérico do 9Router
sem comprovar compatibilidade. Não associar automaticamente a Hermes, OpenCode ou Claude Code.

Assistente: entender origem de consumo → verificar plataforma/versão → instalar isoladamente
→ login explícito → escolher modo → revisar acesso → testar → ativar no contexto escolhido.
Sessão de navegador permanece no runtime proprietário; nenhum reaproveitamento de cookies
do Chrome pessoal. O agente deve primeiro mapear mutações reais de setup/uninstall upstream.

1. **Desligado por padrão:** sem processo, porta, túnel, autostart ou alteração de rota.
2. **Escopo:** preferir launcher/perfil Codex dedicado, com HOME de aplicação isolado e
   compatibilidade comprovada. Se upstream não permitir, parar integração automática e
   apresentar alternativa explícita; não sobrescrever configuração global por conveniência.
3. **Modos claros:** browser sem ferramentas; modo manual assistido; modo com ferramentas.
   Usar nomes descritivos, nunca prometer “risco zero”. Ausência de permissão de escrita não
   impede oferecer modo limitado com aviso claro antes da ativação.
4. **Ferramentas:** consentimento distinto, sandbox e aprovações do Codex preservados;
   rejeitar ação fora do workspace/turno autorizado. Não ativar aprovação automática.
5. **Instalação:** versão fixada, origem e hashes conferidos; preflight de libs, disco,
   arquitetura e portas. Arquivos duráveis fora do worktree e de mounts temporários.
   Dados sensíveis em filesystem com permissões reais, nunca assumir proteção de SD/fuseblk.
6. **Reversão:** journal de alterações e hashes, backup atômico, restore somente do trecho
   ainda pertencente ao PhaseZero. Edição posterior pelo usuário gera conflito visível.
   Desativar drena/cancela tarefas com escolha explícita, remove rota/entrada próprias e
   confirma parada de processos filhos. Sessão fica preservada até pedido de exclusão.
7. **Falhas:** erro de DOM, sessão, modelo, cota ou túnel interrompe com recuperação; nunca
   muda silenciosamente para API paga, outro modelo ou outra conta. Retry não reenvia pedido
   aceito sem prova de idempotência. Estado “incerto” é melhor que duplicar consumo.
8. **Atualizações:** revalidar versão Codex × bridge, regressões e rollback antes de promover;
   sem auto-update durante tarefa. Autostart permanece opção independente de instalar.

“Sem impacto” será objetivo mensurável: desligado sem execução residual; ativado com consumo
de RAM/CPU, disco e rede medido; limites apresentados antes de escolher. Não prometer impacto
zero de um browser e túnel ativos. Não incluir no `dev-ai` padrão até concluir os gates.

## 5. Backlog executável e ordem

Todos os itens abaixo: `planned`, evidência `design_only`. Cada implementação precisa de
commit, teste comportamental, SHA e limites registrados; documentação não fecha aceite.
Arquivos novos indicados como **novo**. Alvos são pontos de partida, não obrigação de
concentrar lógica em shell/UI. IDs `PXA-xxx` são exclusivos deste plano.

| ID / prioridade | Entrega e arquivos-alvo | Dependência | Aceite mínimo |
|---|---|---|---|
| PXA-001 / P1 | Inventário canônico e mapa de migração; `catalog.py`, `hub_overlay.json`, `linux/capabilities/catalog.py`; manifesto **novo** | — | Toda ação atual classificada como canônica, atalho ou legada; zero órfã; mesmo app/host não gera duas instalações |
| PXA-002 / P1 | Schema app/instância/estado e adaptadores; `models.py`, `linux_hub.py`, `status_loader.py` | 001 | Instalação externa, duas instâncias e status desconhecido representados sem “pronto” falso; leituras não mutam host |
| PXA-003 / P1 | Navegação, busca, comparação e detalhe único; `catalog.py`, `pages/registry.py`, `main_window.py`, `pages/workspace.py` | 002 | Todos atalhos resolvem mesmo app/contexto; favoritos antigos migram; modo simples permite instalar/abrir/recuperar sem conhecer proxy |
| PXA-004 / P1 | Receitas compostas e resolução; `profiles/dev-ai.json`, `linux/capabilities/{models,recipes,engine,state}.py` | 002 | JS sem IA não instala Ollama nem liga SSH; conflitos e espaço aparecem antes; repetir apply não duplica; remoção preserva dependência compartilhada |
| PXA-005 / P1 | Jornada Desenvolvimento; `pages/profiles.py`, `pages/ai_dev.py`, `provision_player.py` | 003,004 | Cliques públicos: objetivo→plano→preparar→validar→abrir; cancelamento/retomada e erro parcial testados; runtime do SO preservado |
| PXA-006 / P0 | Contrato de contas e observações; `linux/ai/auth-registry.sh`, adaptadores **novos**, `proxy_models.py` | 002 | Credencial presente, expirada, 401, timeout e backend ausente distintos; prazo global; resumo v1 compatível; nenhum segredo/identidade em export redigido |
| PXA-007 / P1 | Contas UI, avatar e canais; página **nova**, `pages/registry.py`, `pages/ai_proxies.py`, `preferences.py` | 003,006 | Duas contas mesmo provedor; troca não aceita callback anterior; identidade opcional; foto indisponível usa iniciais; teclado e privacidade funcionam |
| PXA-008 / P0 | Grants por consumidor e gestão de credenciais; adaptadores AI, `routing_manager.py`, managers existentes | 006 | Login não habilita consumidor automaticamente; grant/revogação idempotentes; referências seguras; incompatibilidade explícita; sem fallback pago tácito |
| PXA-009 / P1 | Cotas e saúde desacopladas; `auth-registry.sh`, `routing_manager.py`, `pages/ai_routing.py`, status loader | 006,008 | Unknown≠zero; fonte/horário/unidade visíveis; estimativa separada; timeout parcial não apaga conta; polling sem inferência paga |
| PXA-010 / P0 | Spike bridge em fixture; integração **nova** em `linux/ai/` e adapter Windows a definir após mapear bootstrap | 006 | Fixar release/commit; mapear setup/uninstall, arquivos/ports/autostart; provar isolamento Codex, política de aprovação e viabilidade no Arch/Windows; se inviável, registrar gate falho |
| PXA-011 / P1 | Manager bridge: plan/install/enable/status/disable/remove/doctor, nomes propostos | 008,010 | Host simulado limpo, dependência ausente, download truncado, hash errado, porta ocupada, crash e edição externa; rollback só alterações próprias; nenhum processo quando desativado |
| PXA-012 / P1 | Wizard e seleção contextual do bridge; IA, Contas, catálogo e operação comum | 007,009,011 | Só cliques públicos; modo sem ferramentas explícito; grants antes de ativar; cota desconhecida honesta; opção aparece sem mudar modelo/rota atual |
| PXA-013 / P0 | Provas de integração e reversão; testes **novos**, suítes AI/UI existentes | 011,012 | Rejeitar tool fora do escopo, conta errada, replay e sessão expirada; falha sem fallback; disable durante tarefa; restore preserva edição externa; logs redigidos |
| PXA-014 / P1 | Validação limpa e usabilidade; relatório **novo**, Windows bootstrap existente | 005,007,009,013 | Arch e Windows descartáveis; boot/login/sem rede; 800×600 e 1280, 100/150/200%, claro/escuro; foco, hit-test, leitor de tela; evidência real separada de fixture |

Ordem recomendada: 001–002 → 006 → 003–005 → 007–009 → 010–013 → 014.
Prioridade P0 indica bloqueador de confiança/segurança da entrega, não defeito de produção
já reproduzido. PXA-010 pode antecipar investigação isolada para descobrir inviabilidade,
mas não libera ativação antes de contas e grants. Entregar em PRs pequenos por contrato/jornada.

Reusar AISR/AICR para defeitos existentes e LUX/REV/UX para gates já descritos. PXA não
reabre nem declara concluídos itens desses roadmaps. Se requisito coincidir, referenciar
ID original e compartilhar evidência, evitando dois estados contraditórios.

### Gates e provas

- G0 contrato: inventário completo, migração definida e spike sem hipótese crítica oculta.
- G1 hermético: testes de backend, UI por controles públicos, falhas e reversão; fixture
  HOME com um export por variável; nenhuma chamada real de pacote/serviço/login.
- G2 sistema limpo: snapshots Arch e Windows, installer real e dependências reais; documentar
  administrador/reboot/rede; repetir instalar→usar→desativar→reativar→remover.
- G3 conta real: operador com plano/credenciais; conta/modelo/túnel/permissões e consumo
  observados. Stubs não provam estes itens. Sem conta, registrar gate pendente, não sucesso.
- G4 UX: ao menos cinco participantes leigos em descoberta, comparação, ambiente, conta e
  recuperação; meta inicial ≥80% de tarefas sem ajuda e zero ação destrutiva involuntária.
  Incluir fluxo avançado de escolha de versão, rota e reversão. Ajustar copy após observação.

Testes da UI incluem visibilidade **e** habilitação, retângulo inteiro no viewport e hit-test
real; alternar estreito→largo→estreito com tema do MainWindow. Teste geométrico não prova
compreensão. Manter páginas Windows VM/Homelab alcançáveis e jornadas existentes sem regressão.

## 6. Handoff para execução

- Objetivo desta sessão: análise e proposta; nenhum item PXA implementado.
- Base: `889d132`; worktree `/mnt/sdcard/Projects/pz-product-apps-plan`;
  branch `codex/apps-dev-ai-accounts-plan`. Checkout principal preservado.
- Arquivo entregue: este roadmap. Nenhum pacote, serviço, login, modelo, porta, VM ou boot alterado.
- Provas desta sessão: leitura de código, inventário de catálogo, documentação upstream e
  fontes oficiais. Vídeo limitado à descrição/capítulos; nenhuma transcrição integral disponível.
- Validação documental: caminhos existentes referenciados e IDs/dependências conferidos;
  nenhum teste de implementação novo, pois não houve mudança de código.
- Riscos abertos: disponibilidade de identidade/cotas por adaptador, escopo real do setup
  upstream, compatibilidade do Codex instalado, permissões de escrita por plano, libs nativas,
  termos/políticas aplicáveis e instabilidade de automação de navegador. São gates de pesquisa.
- Próximo passo: assumir PXA-001, gerar mapa completo actionId→appId→instância/contexto→destino;
  em seguida schema PXA-002 e observações PXA-006. Não começar por mover todos os botões.
- Antes de executar: ler AGENTS/RTK, consultar ai-memory, conferir HEAD/status e roadmaps
  aplicáveis. Registrar fase/IDs, alterações, testes, SHA, estado do host e próximos passos.
- Trabalho de planejamento não autoriza implantação automática. Implementação futura em
  worktree dedicado; testes vivos de conta e host somente no escopo autorizado da execução.

## 7. Execução inicial — 2026-09-24

Branch `codex/apps-dev-ai-accounts-impl`, worktree
`/mnt/sdcard/Projects/pz-product-apps-impl`, base `889d132`. Esta seção é
posterior ao handoff de planejamento acima.

| Item | Estado | Evidência e limite |
|---|---|---|
| PXA-002 | `verified` | `5b8ff98`, `70ebaca`: `ProductInstance` preserva origem/configuração/saúde; adaptadores de capability e status genérico geram instâncias distintas por host/escopo. Fixture prova instalação externa, duas instâncias do mesmo app e status unknown sem pronto falso. Falha de consulta ao gerenciador vira `unknown`, bloqueia apply/remoção e permanece desconhecida no Hub. `StatusLoader` aceita apenas ação read-only e descarta probe antigo ao trocar contexto. 128 testes direcionados passam em Qt offscreen. Navegação canônica permanece PXA-003. |
| PXA-003 | `in_progress` | `6aedd03`, `e07f2ea`, `260d522`, `ae9071f`, `0a44f6f`, `46d5062`, `e58a05e`: `Aplicativos` é registro pesquisável de 103 apps com detalhe reutilizado; atalhos e busca navegam por `appId` e preservam retorno/escopo. Manifesto contém termos de intenção como “programar”, “chat local” e “agente de código” (Claude Code/OpenCode). Status começa unknown e detalhe consulta só ação read-only; CTA deriva Verificar/Preparar/Configurar/Resolver/Abrir do estado observado. Apps GUI abrem por desktop entry XDG validado e `gio launch`, sem shell; 9Router usa dashboard registrado e Odysseus abre sua UI apenas quando status saudável. Open WebUI agora tem probe read-only por nome exato de container + resposta HTTP local e abre URL loopback observada somente quando saudável; origem continua unknown e backend/timeout não viram ausência ou online. Comparação limitada a pares curados de editor, browser e mesh network. Ollama e OpenCode managed/offline usam setup canônico como recuperação com preview e impacto explícito; OpenCode pode instalar/atualizar CLI e mesclar rota com rollback, sem login/importação; instância external não recebe ação de adoção. Nenhuma preferência antiga de favoritos da UI encontrada (sem setting a migrar). Páginas AI, Contas e conexões, Desenvolvimento e Conexões avançadas agora agrupadas separadamente; IDs de página legados preservados. Limites: uso de agentes CLI requer grants PXA-008 aplicados e isolamento contra fallback pago; recuperação de outros serviços e migração de algumas páginas técnicas continuam pendentes. Resolver nunca escolhe silenciosamente `server.llm.restore`. |
| PXA-004 | `in_progress` | `e9dbce0`, `2cb6999`: Planner expande dependências, rejeita conflitos selecionados e verifica conflito instalado; receitas `development-web-js` e `development-python` são opt-in e JS não seleciona Ollama, SSH, Docker ou serviços. Preview inclui tamanhos diretos de pacote quando disponíveis, espaço livre por filesystem de destino e estado `partial`; esses tamanhos são limite inferior (sem fechamento de dependências). Apply revalida limite conhecido e bloqueia quando ele já excede espaço livre. Repetir plano não duplica pacote. Fixture instala Compose + Kind com Docker compartilhado uma vez, remove Compose sem retirar Docker usado por Kind, bloqueia remoção de Docker enquanto Kind está instalado e permite remover Docker após retirar Kind. `tests/test_capabilities.py`: 35 passaram. `profiles/dev-ai.json` permanece explicitamente rotulado como bundle legado opt-in. Limite: metadados ausentes para algumas fontes/gerenciadores; ainda não há resolução do custo total da transação. |
| PXA-005 | `in_progress` | `5fa5db8`, `8753d96`, `0254d01`, `5cc1035`, `a846827`: Página `Desenvolvimento` oferece objetivo Web JS/TS, Python, Rust, C/C++, Java/JVM e .NET; editor VS Code/VSCodium permanece opcional e entra no mesmo preview. Planner/applier fake prova Rust, GCC C/C++, Java (OpenJDK + Maven) e .NET (SDK escolhido), sem pacote ou serviço real. UI pública abre detalhe canônico de cada runtime sem editor; testes existentes provam composição com editor. Copy Python preserva runtime do SO. Fixture interrompe após Node e retoma sem reinstalar Node. Nesta expansão, `test_development_page.py` + `test_capabilities.py` + snapshot: 61 passaram; shortcut canônico + inventário: 12 passaram. Desenvolvimento com IA segue pendente até enforcement de grants PXA-008; não usar login como grant implícito. Limites: cancelamento real com pacman e jornada em host limpo ainda não provados; validação concreta depende do host G2. |
| PXA-006 | `in_progress` | `3e39ac0`, `7b7f8ee`, `11c22fa`, `ae814d7`: contrato de `Account`, `Connection`, `Grant`, `Evidence`, `Quota` e exportação redigida; deadline agregado e adaptadores read-only para Claude, sessões de proxy e provedores 9Router. Evidência de credencial, sessão, serviço e acesso permanece separada; 401, expiração, timeout e backend ausente têm estados distintos. Claude status agora diferencia probe falho de sessão ausente, preservando `loggedIn`/schema v1 como campo compatível. `lastVerifiedAt` não é inferido de leitura. Novo fixture executa `auth-registry.sh` real contra wrappers: contrato v1 preservado, nomes/IDs privados redigidos, erro do provider vira `backend-unavailable` com contagens null, timeout permanece `timeout`. Faltam sessão/cota real e operador; nenhum login executado. |
| PXA-007 | `in_progress` | Nova tela privada Contas e conexões usa adaptadores existentes em probes read-only acionados por Atualizar status. Abrir página não inicia probes. Dois registros OpenAI com IDs opacos aparecem separados; seleção por provider rejeita estado anterior e callback de probe de geração velha é ignorado. Apelido sem foto usa iniciais acessíveis; projeção exportada contém só contagens. Limites: sem fonte de avatar e sem identidade verificada real; teclado fixture passou, leitor de tela/privacidade com usuários e conta real pendentes. Grants continuam PXA-008. |
| PXA-008 | `in_progress` | `GrantLedger` exige consentimento explícito e compatibilidade declarada consumer/adaptador/escopo; grant e revogação são idempotentes e independentes, com ledger JSON privado 0700/0600 sem identidade ou segredo. `Account.secret_ref` aceita apenas referência opaca namespaced de store; isso valida formato, não prova existência do segredo no cofre. Contas mostra controles por conexão com confirmação e aviso de custo; informa que sessões ainda não aplicam os grants. `routing_manager.recommend(..., consumer_id=..., grants=...)` filtra provedor sem grant antes de pontuar; grant ausente deixa cadeia vazia. Commit `aea982e` faz `pz ai routing run` recusar Claude Code/OpenCode antes de consultar providers ou criar processo: combo/model ID do 9Router não fixa conexão concedida e poderia trocar de conta/custo. `test_routing_manager.py`, `test_account_grants.py`, `test_accounts_page.py`: 49 passaram; `8ee0e73` recusa grants para conexão desativada e desabilita controles novos, preservando revogação; wrappers verificam ausência de consulta/processo. Limite externo: docs do [9Router](https://docs.9router.com/) descrevem fallback automático; upstream mantém aberto o [pedido de API key por combo/conta selecionada](https://github.com/decolua/9router/issues/1075). API local não demonstra isolamento por consumer/connection. Não fechar “sem fallback pago” até interface suportada e teste de execução provarem isso. Pendentes: enforcement efetivo por consumidor em requests de inferência, gerenciadores de credenciais/cofre do SO e conta real. |
| PXA-009 | `planned` | Sem implementação ainda. Depende de enforcement PXA-008; preservar `unknown` para fonte ausente, timeout parcial e cota não observada. |
| PXA-010 | `in_progress` | `608b28e`: spike documental fixou `v6.0.0`/commit `212ceef2acac9d6ee0f3c9037abfaf4ad8ff9827`, checksums publicados Linux/Windows e mapa setup/removal, bridge, autostart e modos. Checksum não foi verificado contra download. Gate de habilitação automática falho: isolamento Codex e política de aprovação não provados; upstream tem opção auto-approve. Arch/Windows descartáveis, conta real e falhas/rollback pendentes. Nenhuma integração implementada ou pacote executado. |
| PXA-011 | `planned` | Aguardando PXA-008 e gate seguro PXA-010. |
| PXA-012 | `planned` | Aguardando PXA-007/009/011; nenhuma rota ou wizard de integração disponível. |
| PXA-013 | `planned` | Aguardando PXA-011/012; rejeição de replay/conta/escopo e rollback não provados. |
| PXA-014 | `planned` | G2/G4 pendentes: Arch e Windows descartáveis, conta real, participantes, escala/tema/acessibilidade e CI. |

Provas: 49 testes focados passaram na base inicial `d9f144f`; depois 151 testes
direcionados e 9 subtestes (`test_capabilities.py`, inventário/status de produto,
autoridades de instalação, Hub, contratos/adaptadores de conta e regressão Windows
VM) passaram com `QT_QPA_PLATFORM=offscreen`. PXA-003: 87 testes de navegação,
Hub, IA e UI nativa passaram; após ajuste de layout, 6 testes do registro/detail
passaram. Após CTA dependente de estado, 46 testes focados de catálogo/status/UI
passaram. `git diff --check` passou. Ollama CLI routes usam
stubs em HOME temporário; prova não chama gerenciador de pacotes, sudo ou serviço
real. Handoff anterior dizia haver instaladores Ollama separados; inspeção atual
mostrou que ambos já delegam pacote a `linux/ai/setup-ollama.sh`, enquanto rota
server também lista/modela o fluxo do servidor. Mapa agora registra essa autoridade
compartilhada e escopo host. A reflow UI de Windows VM falha em 1280 px no QPA da
sessão desktop e reproduz igual em `main` limpo; passa no Qt offscreen usado pelo
CI. Investigar escala/DPI na matriz PXA-014. CI remota, conta real, Arch limpo,
Windows limpo e UX com participantes não executados. Nenhum pacote, serviço,
modelo, login, porta, VM ou boot do host foi alterado.

PXA-004: `tests/test_capabilities.py` (35 testes), `tests/linux-ai-desktop.sh`,
`tests/linux-admin-bridge.sh`, `tests/linux-agent-compat.sh` e
`tests/linux-git-github.sh` passaram. Estes usam providers/fakes e scripts herméticos;
nenhuma instalação de pacote ou serviço foi aplicada no host. `git diff --check`
passou. Preview soma download/instalação quando metadado nativo existe, mostra
disponibilidade local, bloqueia quando esse limite inferior já excede espaço livre e
preserva `partial` porque dependências transitivas ainda não são incluídas. Flatpak
usa filesystem do usuário; pacotes de SO usam `/`. G1 parcial; snapshots Arch/Windows
e G2 continuam pendentes.

PXA-003 continuação: 32 testes focados (`test_product_registry_ui.py`,
`test_product_inventory.py`, `test_native_navigation.py`) passaram. Desktop entry
fixture e navegação de Abrir via `gio launch` passaram junto com snapshot regenerado
(580 ações/101 produtos). Caminhos XDG fora das raízes são rejeitados; sem desktop
entry, CTA Abrir não habilita. Estado Resolver não autoescolhe a restauração Ollama.
Inventário da UI não encontrou preferência antiga de favoritos. Antes da última
atualização, recovery simples para apps/serviços CLI permanecia sem rota; PXA-003 aberto.

PXA-003 atualização: `test_product_registry_ui.py` + `test_product_inventory.py` +
`test_native_navigation.py`: 34 testes passaram; `test_preview_honesty.py`: 6 passaram.
Busca fixture encontra Ollama por
“chat local” e VS Code/VSCodium por “programar”. Ollama offline com origem PhaseZero
direciona a `ai.ollama` com preview de estado, impacto explícito e confirmação; mesma
falha com origem external mantém Resolver desabilitado. Snapshot gerado permanece em
580 ações/101 produtos. Depois, `test_product_registry_ui.py`: 13 testes e
`test_native_navigation.py`: 12 testes passaram com dashboard como CTA Abrir e os
grupos Desenvolvimento/IA/Contas/Conexões avançadas. Sem pacote, serviço ou conta real
alterados.

PXA-003 intent search: `test_product_registry_ui.py` e
`test_product_inventory.py`: 24 testes passaram. “agente de código” encontra Claude
Code e OpenCode sem mostrar Ollama; JSON gerado confere com o renderer. Rotas GUI e
serviço CLI não cobertas por esta mudança.

PXA-003 OpenCode recovery: fixture de instância managed offline seleciona
`ai.opencode-install` com preview e copy de impacto; origem external não habilita
mutação. A suíte completa `test_product_registry_ui.py`: 15 testes passaram,
incluindo recovery OpenCode, CLI/browser open Odysseus, 9Router dashboard e desktop
entry. `test_product_inventory.py`: 11 passaram. Sem execução de setup, CLI ou login.

PXA-003 Open WebUI: `linux/pz ai webui status` normaliza container Docker exato e HTTP
loopback sem iniciar/parar container; abre dashboard só após estado saudável observado.
Backend ausente ou timeout fica unknown; HTTP 5xx fica failed; origem nunca é inferida.
`test_open_webui_manager.py`, detalhe UI público e inventário: 17 passaram. Wrappers
falsos para Docker/curl/xdg-open; nenhum Docker, browser, pacote ou serviço do host chamado.

PXA-003 atalhos: `test_every_app_action_resolves_to_canonical_detail_with_source_context`
passa para todos os 175 actions app-target do catálogo, cobrindo os 103 produtos; cada
despacho encaminha o mesmo `appId` e preserva `actionId` de origem. Com inventário, 12 testes
passaram. Agentes CLI não foram lançados: uso aguarda enforcement PXA-008 e prova sem
fallback pago; isso é limite deliberado de segurança, não evidência de rota concluída.

PXA-005 C/C++: perfil oferece GCC como toolchain mínima com nomes nativos por distro:
Arch `gcc`, Debian `g++`, Fedora/openSUSE `gcc-c++`. Fontes: [Arch GCC](https://archlinux.org/packages/core/x86_64/gcc/),
[Debian g++](https://packages.debian.org/search?keywords=g%2B%2B), [Fedora gcc-c++](https://packages.fedoraproject.org/pkgs/gcc/gcc-c%2B%2B/),
[openSUSE gcc-c++](https://software.opensuse.org/package/gcc-c%2B%2B?locale=de). UI gera plano e abre detalhe `app.cpp`; providers fake comprovam preview/apply. O snapshot atualizado contém 588 actions/103 produtos. `test_development_page.py` + `test_capabilities.py` + inventário + shortcut: 61 passaram; `git diff --check` passou. Nenhum compilador foi instalado.

PXA-005 Rust: capability/profile e objetivo público geram preview e abrem o detalhe
canônico `app.rust`. No snapshot os totais agora são 586 actions e 102 produtos; o renderer
oficial atualizou `product_inventory.json`. `test_development_page.py` +
`test_capabilities.py` + `test_product_inventory.py`: 54 passaram; shortcut + inventário:
12 passaram. Pacote Arch `rust` fornece rustc/Cargo; Debian/Fedora usam `cargo` e SUSE usa
`rust`. Fontes consultadas: [Arch Linux file list](https://archlinux.org/packages/extra/x86_64/rust/files/),
[Debian cargo](https://packages.debian.org/stable/cargo), [Fedora cargo](https://packages.fedoraproject.org/pkgs/rust/cargo/),
[openSUSE rust](https://software.opensuse.org/package/rust?locale=sv). Sem apply de pacote real.

PXA-006 legacy aggregator: `test_auth_registry.py`: 2 passaram. Invoca o shell
`auth-registry.sh status` real com subprocessos providers em PATH temporário; valida
schema v1/redação e separa `backend-unavailable` de timeout sem converter contagens
em zero. Nenhum manager, serviço ou login real executado.

PXA-005: `test_development_page.py` + `test_capabilities.py` +
`test_development_cancel.py`: 37 testes passaram; validação da nova categoria contra
navegação/Hub/UI nativa: 53 testes passaram. O plano opcional de editor combina receita
e capability no mesmo preview; ações são herméticas em provider fake. Interrupção
parcial com exit 130 e retry preserva Node concluído. Outro fixture clica Preparar,
inicia fake parent/child, usa Cancelar público, confirma que nenhum filho sobrevive e
registra ledger `cancelled` com `retry-with-confirmation`. HOME/XDG temporários em
atribuições separadas. Não substitui teste real de pacman nem host limpo. Arch/Windows
descartáveis e G2 continuam pendentes.

PXA-005 Java/.NET: `test_development_page.py` + `test_capabilities.py`: 41 testes
passaram. Botões públicos geram preview dos perfis e abrem detalhe canônico do runtime
selecionado; provider falso prova Java = OpenJDK + Maven e .NET = SDK .NET, sem pacote
ou serviço real. Editor opcional continua no plano quando escolhido. Rust e C/C++ seguem
pendentes; G2 continua pendente.

PXA-007: `test_accounts_page.py` prova dois registros do mesmo provider, seleção
exclusiva por provider, rejeição de callback antigo, exportação sem identidade,
iniciais acessíveis e resultado parcial que nomeia fontes sem resposta sem afirmar
zero contas. Abrir página não chama probe; só botão explícito inicia status.
Regressão combinada `test_accounts_page.py`, `test_linux_native_ui.py` e
`test_native_navigation.py`: 41 testes passaram. Resultado fixture; conta real,
leitor de tela e validação de privacidade com participantes permanecem pendentes.

PXA-008: `test_account_grants.py`, `test_account_contract.py` e
`test_routing_manager.py`: 51 testes passaram. Grant requer consentimento,
adaptador e escopo suportados; grant/revoke repetidos não duplicam estado; ledger
é privado e não guarda identidade/segredo. Recomendação opt-in limita candidatos
às conexões concedidas e não oferece cadeia quando grants faltam. Fixtures da tela
provam confirmar e revogar em conexões distintas; `test_accounts_page.py`,
`test_account_grants.py`, `test_account_contract.py`, `test_native_navigation.py` e
`test_linux_native_ui.py`: 55 testes passaram. O executor ainda não aplica grants
nem restringe conexões irmãs dentro de 9Router, então sem fallback pago permanece
pendente; login real e vault também pendentes.

Próximo lote: continuar PXA-003 (rotas Abrir/recuperação e atalhos de páginas técnicas),
fechar PXA-005 com cancelamento em QProcess/host G2, depois completar UI e wiring
de consumidores em PXA-008. A regressão `test_accounts_page.py`,
`test_account_grants.py`, `test_account_contract.py`, `test_native_navigation.py`
e `test_linux_native_ui.py` passou: 55 testes. Ledger corrompido mantém controles de
consentimento indisponíveis. Gates de host, conta real e UX permanecem pendentes; nenhuma
evidência fixture fecha esses gates.

PXA-010 spike upstream (pesquisa isolada, 2026-09-24): release fixada para avaliação em
`v6.0.0`, commit `212ceef2acac9d6ee0f3c9037abfaf4ad8ff9827` (tag anotada aponta
para objeto `7e7e2bc5164d06448861bc443153d1834ae7e883`). SHA-256 publicado para o
arquivo Linux x64 `715d4cf7b411788df525badb3ed46c25b384d513dd3ca8067f4a893edfe3edd0`
e Windows x64 `94e51956173339ec7932e70939081003f372213c7ecc4d3084b86063c3718b44`.
São hashes publicados, ainda não conferidos contra downloads; pacotes não assinados.
README recomenda instaladores dinâmicos `/releases/latest`; integração PhaseZero deve
fixar release e conferir manifesto, nunca executar o comando dinâmico. [Release v6.0.0]
(https://github.com/miuuyy/codex-chatgpt-web/releases).

Mapa upstream documentado: instalar/substituir launcher mantém configuração e perfil
privado do browser; setup adiciona `openai_base_url` e rota Voice oficial à configuração
Codex com journal/restauração no disconnect/removal; runtime inclui bridge, helper browser,
MCP e pode iniciar túnel e daemon loopback, além de login item/autostart XDG opcional.
Remoção pede Settings → Remove Codex integration, restart integral do Codex, quit e
desinstalação normal; remover túnel, MCP e credencial de conta é passo separado. Modos
observados: Browser-only sem tools; Zero Risk com envio manual e MCP separado; Full harness
com tools via MCP. Approval inesperada falha fechada, mas flag explícita
`--auto-approve-tool-calls` permite clicar Allow uma vez. CI não atesta conta ChatGPT,
connector MCP ativo ou turno completo; checklist Windows 11 requer conta real. Fontes:
[arquitetura](https://github.com/miuuyy/codex-chatgpt-web/blob/v6.0.0/docs/architecture.md),
[segurança](https://github.com/miuuyy/codex-chatgpt-web/blob/v6.0.0/docs/security-model.md),
[remoção](https://github.com/miuuyy/codex-chatgpt-web/blob/v6.0.0/TROUBLESHOOTING.md),
[validação de release](https://github.com/miuuyy/codex-chatgpt-web/blob/v6.0.0/docs/release-validation.md).

Resultado do spike: sem integração/autoridade local existente para este produto, sem
download, instalação ou execução upstream e sem mutação do host. Isolamento do Codex e
preservação das aprovações não provados; opção explícita de auto-approval é incompatível
com política PhaseZero. Arch e Windows descartáveis, crash/rollback/porta ocupada, conta
real e ferramenta MCP continuam sem prova. PXA-010 permanece `in_progress`; gate de
segurança falho para habilitação automática e nenhuma tela/rota deve oferecer ativação até
provas independentes. Próximo passo seguro: spike hermético do contrato esperado e buscar
execução em snapshots/conta autorizada; não adaptar setup upstream no host de trabalho.
