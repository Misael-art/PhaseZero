# Apps, desenvolvimento, IA e contas — proposta de produto v1

Data: 2026-09-24. Base examinada: `889d132`. Estado: **proposta; implementação não iniciada**.
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
