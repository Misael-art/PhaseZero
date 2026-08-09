# UI Spec — Central de Controle

## Direção

BigLinux reinterpretado: shell escuro, sidebar fixa, busca global, cards
arredondados e ciano como acento. Layout responsivo: três, duas ou uma coluna.
Janela sem decoração nativa; header próprio mantém mover, maximizar, minimizar
e fechar.

## Revelação progressiva

Modo simplificado é padrão. Superfície principal responde primeiro:
"está funcionando?" e "o que devo fazer?". Comandos, stdout/stderr e JSON não
ocupam o fluxo normal. Cada resultado oferece "Ver detalhes técnicos" e a chave
global "Modo avançado" mantém esses detalhes visíveis entre sessões.

Serviços usam um vocabulário visual comum:

- hero com nome, estado e ação primária de ligar/desligar;
- badges verde/amarelo/vermelho para saudável/atenção/falha;
- sliders somente dentro dos limites seguros informados pelo backend;
- toggles desabilitados com motivo quando o recurso não está disponível;
- ações destrutivas isoladas em "Zona de perigo" e ainda sujeitas ao preview.

Windows VM, Waydroid e Servidor têm páginas dedicadas. Demais módulos continuam
usando catálogo allowlisted e herdam o mesmo modo simplificado.

## Feedback

Sucesso de mutação gera toast não bloqueante. Resultado consultivo abre resumo
visual compacto. Falha abre diálogo com causa curta, ação corretiva principal e
detalhes técnicos recolhidos. Histórico preserva envelope completo para
auditoria.

Diagnóstico converte linhas `PASS`, `WARN`, `FAIL` e `INFO` em painel de saúde,
agrupado por Hardware, Conexão, Steam, Windows VM e Sistema. Avisos e falhas
expõem explicação prática ou ação sugerida.

## Estados

`Idle → PreviewInProgress → PreviewCompleted → MutationInProgress → Completed`
ou `Failed`. Cancelamento disponível enquanto processo roda. Fechamento durante
operação exige confirmação.

## Contrato

`catalog.py` é allowlist. `command_runner.py` chama somente `linux/pz`; não usa
shell e passa argumentos como lista. Valor escolhido pelo usuário substitui
somente token `{input}`. Saída chega em tempo real por `QProcess`.

Preview bem-sucedido fica vinculado a ação e valor de entrada. Botão
“Confirmar e aplicar” executa exatamente essa combinação. Resultado persistido
inclui comando, timestamps, exit code, stdout, stderr e último JSON detectado,
mesmo quando esses dados ficam ocultos na apresentação.

## Acessibilidade

Navegação por Tab, nomes textuais junto aos ícones, atalhos globais, foco
visível, contraste AA no tema escuro, textos selecionáveis e cards ativáveis
por teclado. Tema claro disponível no topo.
