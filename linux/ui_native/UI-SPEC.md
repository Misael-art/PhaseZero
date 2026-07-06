# UI Spec — Central de Controle

## Direção

BigLinux reinterpretado: shell escuro, sidebar fixa, busca global, cards
arredondados e ciano como acento. Layout responsivo: três, duas ou uma coluna.
Janela sem decoração nativa; header próprio mantém mover, maximizar, minimizar
e fechar.

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
inclui comando, timestamps, exit code, stdout, stderr e último JSON detectado.

## Acessibilidade

Navegação por Tab, nomes textuais junto aos ícones, atalhos globais, foco
visível, contraste AA no tema escuro, textos selecionáveis e cards ativáveis
por teclado. Tema claro disponível no topo.
