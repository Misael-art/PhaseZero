# PhaseZero — biblioteca de jogos e menu de aplicações coesos

**Data:** 2026-07-11  
**Estado:** implementado em v1.6.0  
**Alvo funcional:** Linux/SteamOS  
**Alvo arquitetural:** núcleo portável para Windows

## 1. Resultado pretendido

PhaseZero deve apresentar tarefas, não scripts. Usuário escolhe uma origem de jogos, recebe diagnóstico compreensível, revisa plano seguro e aplica somente transformações necessárias para cada sistema e emulador.

No desktop, todas entradas gerenciadas ficam sob uma única raiz `PhaseZero`. Aplicações, jogos, frontends, atalhos de sessão e web apps não podem inundar categorias globais nem aparecer duplicados.

## 2. Evidência atual

### 2.1 UI nativa

- Categoria Emulação expõe 71 ações; 36 marcadas avançadas e 46 mutáveis.
- Seção `Biblioteca e mídia` mistura compartilhamento, capas, limpeza, otimização, BIOS, keys, firmware, NSZ e importação PS3.
- `Otimizar ROMs` aceita somente uma pasta. Não oferece biblioteca completa, pasta específica ou arquivos específicos como jornadas distintas.
- Painel lateral de contexto permanece vazio até uma linha ser escolhida e ocupa largura permanente em 1280×800.
- Resultado fala em formatos técnicos (`CHD/RVZ/CSO/NSZ/ZIP`) antes de explicar benefício, destino ou emulador.
- Entrada `Converter NSZ` duplica parte do domínio de `Otimizar ROMs`, mas com objetivo oposto: compatibilidade NSZ→NSP em vez de economia NSP→NSZ.

### 2.2 Caso real Vita

Entrada:

```text
/home/misael/Emulation/roms/psvita/PCSE01224.zip
```

Conteúdo relevante:

```text
eboot.bin
sce_module/
sce_sys/param.sfo
sce_sys/package/work.bin
```

Comportamento atual:

```text
Platform: psvita (0.70, via dir)
Current format: zip
archive input zip is unsupported; source preserved
```

O mesmo erro ocorre nos cinco ZIPs atuais da pasta `psvita`. Falha está no modelo: `romopt` trata ZIP como formato de compressão antes de identificar pacote instalável. Para Vita3K, ZIP/VPK com dump compatível é entrada de instalação; após instalação, jogo vive no diretório `ux0/app/<TITLE_ID>` do emulador.

### 2.3 Menu KDE

- Host contém 178 entradas detectadas como gerenciadas PhaseZero; 77 permanecem visíveis.
- Existem duas raízes separadas: `Jogos` e `Web Apps`.
- Launchers canônicos, wrappers `phz-*`, wrappers `phasezero-*`, AppImageLauncher e Wine coexistem.
- Jogos PC geram uma entrada por título. Isso transforma menu iniciar em outra biblioteca de jogos, sem filtros, favoritos ou política de exposição.
- Organização está dividida entre `games.sh`, `webapp.sh`, `shortcuts.sh`, `heroic.py` e scripts específicos. Não existe contrato canônico único nem ledger completo de alterações.

## 3. Decisão de produto

### 3.1 Nova arquitetura de Emulação

Página inicial de Emulação terá quatro destinos de primeiro nível:

1. **Biblioteca de jogos** — adicionar, preparar, instalar, mover e validar jogos.
2. **Emuladores e frontends** — instalar, integrar, atualizar e testar launchers.
3. **Arquivos do sistema** — BIOS, firmware, keys e licenças locais do usuário.
4. **Saúde e manutenção** — diagnóstico, reparo, mídia, atalhos e performance.

Comandos individuais continuam disponíveis em `Avançado`, pesquisa global e histórico. Não aparecem como dezenas de opções equivalentes na jornada principal.

### 3.2 Biblioteca de jogos como workflow

A tela `Biblioteca de jogos` usa cinco etapas persistentes:

```text
Origem → Análise → Plano → Execução → Validação
```

#### Origem

Controle segmentado, três opções:

- **Toda biblioteca** — usa raízes canônicas e integrações detectadas.
- **Uma pasta** — usuário escolhe qualquer diretório.
- **Arquivos específicos** — seleção múltipla de arquivos/pacotes.

Campos têm rótulo visível, histórico recente e botão `Selecionar`. Drop de arquivos/pastas deve produzir mesmo contrato. Ação primária única: `Analisar`.

#### Análise

Scan sempre read-only. Resumo superior:

- jogos encontrados;
- sistemas reconhecidos;
- prontos para jogar;
- ações recomendadas;
- bloqueios;
- espaço estimado antes/depois.

Lista agrupa por sistema e mostra:

| Campo | Exemplo |
|---|---|
| Jogo | PCSE01224 |
| Sistema | PlayStation Vita |
| Origem | ZIP instalável |
| Destino | Vita3K |
| Estado | Pronto para instalar |
| Recomendação | Instalar e validar |

Filtros: `Todos`, `Prontos`, `Requer ação`, `Bloqueados`, `Não reconhecidos`.

#### Plano

Selecionar linha abre painel de detalhes somente quando necessário. Em 1280×800 ele substitui/encobre parte da lista; não consome largura permanente quando vazio.

Detalhe explica:

- como sistema foi detectado e confiança;
- formato atual;
- emulador escolhido e motivo;
- arquivos que serão criados, movidos ou preservados;
- espaço necessário;
- pré-requisitos ausentes;
- reversibilidade;
- resultado esperado.

Ação primária: `Aplicar plano`. Secundárias: `Alterar destino`, `Ignorar item`, `Exportar relatório`.

#### Execução

Uma operação longa, com etapas por item, percentual global, tempo, item atual, cancelamento seguro e resumo de log. Cancelamento termina item em ponto consistente e preserva staging para retomada somente quando seguro.

#### Validação

Resultado por item:

- instalado/preparado;
- verificação de integridade;
- emulador detectado;
- launch probe;
- frontend atualizado;
- caminho final;
- ação `Abrir jogo` ou `Abrir emulador`.

Falhas não apagam origem. UI oferece `Tentar novamente`, `Ver causa`, `Abrir pasta` e `Reverter` quando aplicável.

## 4. Contrato técnico unificado

### 4.1 Separar artefato, transformação e execução

Três conceitos devem deixar de ser uma ação única:

- **Artefato:** ZIP Vita, ISO PS2, NSP Switch, pasta PS3, ROM GBA etc.
- **Transformação:** instalar, extrair, converter, recomprimir, copiar, vincular ou manter.
- **Destino de execução:** Vita3K, PCSX2, RPCS3, Dolphin, RetroArch, Eden etc.

`NSZ` deixa de ser módulo principal:

- NSP/XCI→NSZ/XCZ é otimização de armazenamento quando emulador aceita formato.
- NSZ→NSP é preparação de compatibilidade quando destino exige NSP.
- Usuário escolhe objetivo (`economizar espaço` ou `tornar jogável`); planner escolhe conversor.

### 4.2 Registry declarativo

Criar registry canônico, consumido por CLI e UI:

```python
SystemAdapter(
    id="psvita",
    aliases=("vita", "psv"),
    canonical_rom_dir="psvita",
    detectors=(...),
    artifacts=(...),
    destinations=("vita3k",),
    planner=...,
    verifier=...,
    launcher=...,
)
```

Cada adapter define:

- aliases de pasta e sistema;
- extensões e assinaturas;
- probes internos de arquivo compactado;
- estrutura esperada e identificador de título;
- formatos aceitos por cada emulador;
- transformação recomendada;
- destino canônico por plataforma do host;
- pré-requisitos de BIOS/firmware/keys;
- comando de instalação e lançamento;
- verificação pós-operação;
- capacidade e motivo quando operação não é suportada.

Gate exige adapter para todos sistemas públicos listados no catálogo PhaseZero. Sistema reconhecido sem transformação deve retornar `ready`/`no_action`, nunca erro genérico. Sistema desconhecido deve ser preservado e mostrar evidência insuficiente.

### 4.3 CLI pública

Nova família:

```text
pz emulation library scan --scope library --json
pz emulation library scan --scope directory --input PATH --json
pz emulation library scan --scope files --input FILE... --json
pz emulation library plan --scan-id ID --json
pz emulation library apply --plan-id ID --confirm TOKEN --json
pz emulation library verify --operation-id ID --json
pz emulation library rollback --operation-id ID --json
```

CLI emite envelopes versionados. UI nunca interpreta stdout humano para decidir comportamento.

`rom-optimize` e `nsz` permanecem aliases compatíveis, marcados deprecated e roteados ao planner novo. Ações antigas continuam em `Avançado` até uma release posterior.

### 4.4 Pipeline resiliente

Invariantes:

- argumentos sem shell;
- scan não mutável;
- recusa symlinks fora da origem;
- proteção contra path traversal, symlink ZIP e archive bomb;
- limite de tamanho, quantidade de entradas e razão de expansão;
- preflight de espaço, ferramentas, destino e permissões;
- staging no mesmo filesystem do destino;
- lock por biblioteca/destino;
- hashes antes/depois;
- validação específica de formato;
- publicação atômica;
- original preservado por padrão;
- limpeza somente após verificação e confirmação explícita;
- manifest privado `0600` com plano, hashes e rollback;
- quarentena reversível para conflitos;
- retomada idempotente;
- logs e erros sanitizados.

## 5. Tratamento correto do caso Vita

Planner deve:

1. reconhecer pasta `psvita` como evidência fraca;
2. abrir ZIP sem extrair;
3. validar nomes e limites do arquivo;
4. localizar `eboot.bin` e `sce_sys/param.sfo` na raiz;
5. parsear SFO e validar `TITLE_ID` contra nome/pasta quando presente;
6. classificar como `vita3k.installable_zip`;
7. detectar Vita3K, pref-path, firmware e instalação existente;
8. propor `Instalar no Vita3K`, mantendo ZIP original;
9. instalar por interface suportada pelo adapter ou staging seguro em `ux0/app/<TITLE_ID>`;
10. confirmar aplicação instalada e executar launch probe;
11. atualizar ES-DE/SRM/LaunchBox somente após validação;
12. apresentar `Abrir jogo`.

Para `PCSE01224.zip`, estado esperado após scan:

```text
PlayStation Vita · ZIP instalável · Vita3K
Pronto para instalar — original será preservado
```

Se conteúdo for Vitamin/MaiDump incompatível, planner deve bloquear com motivo específico. Não renomear extensão nem extrair silenciosamente.

## 6. Menu KDE único

### 6.1 Estrutura

```text
PhaseZero
├── Central de Controle
├── Jogos e emulação
│   ├── Biblioteca e favoritos
│   ├── Frontends
│   ├── Emuladores
│   └── Ferramentas
├── Apps web
│   ├── Comunicação
│   ├── Mídia
│   ├── IA
│   ├── Nuvem e documentos
│   └── Produtividade
└── Sistema e sessões
    ├── Steam Deck
    ├── Boot e recuperação
    └── Máquinas e Android
```

Não existirão raízes globais PhaseZero separadas `Jogos` e `Web Apps`.

### 6.2 Registry de menu

Criar `MenuItemSpec` canônico:

```python
MenuItemSpec(
    id="emulator.vita3k",
    name="Vita3K",
    group="games.emulators",
    launch_target=...,
    icon=...,
    visibility="installed",
    platforms=("linux", "windows"),
)
```

Providers:

- `XdgKdeMenuProvider` gera `.desktop`, `.directory` e um único `.menu`.
- `WindowsStartMenuProvider` gera mesma hierarquia com pastas e `.lnk`.

Scripts não escrevem categorias independentemente. Pedem ao registry para materializar menu.

### 6.3 Política de exposição

- Central de Controle sempre visível.
- Ferramenta/emulador visível somente quando instalado e canônico.
- Jogos individuais ficam fora do menu por padrão.
- Usuário pode marcar `Mostrar no menu` ou `Favorito`; somente esses recebem entrada visível.
- Biblioteca completa permanece em frontend próprio (Steam/ES-DE/LaunchBox/Heroic).
- Entries auxiliares, debug e bridges usam `NoDisplay=true`.

### 6.4 Deduplicação reversível

Scanner calcula identidade por:

- desktop ID/Flatpak app ID;
- executable normalizado e argumentos funcionais;
- Steam URI;
- AppImage alvo/hash;
- Wine prefix e executável;
- nome apenas como sinal auxiliar, nunca decisão única.

Ao escolher canônico:

- arquivo estrangeiro não é apagado;
- override local reversível pode ocultá-lo;
- manifest registra origem, hash, decisão e backup;
- atualização reavalia identidade;
- rollback restaura visibilidade;
- conflito ambíguo exige escolha do usuário.

UI `Menu e atalhos` oferece `Analisar`, preview por grupo, `Organizar` e `Restaurar`.

## 7. Composição visual

### 7.1 Emulação inicial

- faixa compacta de saúde real;
- no máximo quatro cards de jornada;
- um CTA primário por card;
- incidentes abaixo, ordenados por impacto;
- ações técnicas atrás de `Avançado`.

### 7.2 Biblioteca

- cabeçalho e seletor de origem;
- stepper horizontal;
- resumo de scan;
- lista/tabela central com densidade confortável;
- painel de detalhe aparece após seleção;
- operação global na barra inferior somente enquanto ativa.

### 7.3 Hierarquia

- primário sólido somente para próximo passo;
- secundário em contorno/texto;
- destrutivo vermelho somente quando ação remove conteúdo;
- alvo mínimo 48×48;
- foco visível e ordem de tabulação estável;
- labels persistentes;
- mensagens junto ao item afetado;
- toast somente para confirmação não bloqueante;
- diálogo somente para risco, escolha irreversível ou elevação.

## 8. Portabilidade Windows

UI, registry, planner e envelopes JSON não conhecem XDG, KDE, symlinks ou `/home`.

Abstrações obrigatórias:

- paths de biblioteca/emulador;
- operações atômicas e permissões;
- processo e cancelamento;
- abertura de arquivo/pasta;
- menu/atalho;
- elevação;
- associação de arquivos;
- descoberta de executáveis.

Linux implementa comportamento completo nesta rodada. Windows recebe contratos, provider de Start Menu testável e caminhos simulados; empacotamento Windows permanece fora do escopo.

## 9. Fases de implementação

### Fase A — contrato e inventário

- registry de sistemas, artefatos, destinos e menu;
- envelopes JSON e schemas;
- scan de biblioteca/pasta/arquivos;
- compatibilidade dos comandos antigos;
- testes de cobertura de todos sistemas públicos.

### Fase B — planner e caso Vita

- probes seguros de ZIP/VPK/PKG/pastas;
- adapter Vita3K completo;
- preflight, plan, staging, apply, verify e rollback;
- migração NSZ/romopt para planner;
- teste real local de `PCSE01224.zip` em dry-run e install controlado.

### Fase C — nova UI de Emulação

- landing com quatro jornadas;
- workspace Biblioteca em cinco etapas;
- filtros, detalhes, progresso e resultado;
- estado persistido e retomada;
- ações antigas movidas para Avançado.

### Fase D — menu unificado

- `MenuItemSpec` e provider KDE;
- migração de Games/Web Apps/shortcuts/Heroic;
- scan de 178 entradas atuais;
- preview e ledger reversível;
- raiz única PhaseZero;
- política de favoritos para jogos individuais.

### Fase E — validação, instalação e release

- testes unitários, integração e offscreen;
- validação XDG/KDE em raiz isolada e host real;
- instalação user/Flatpak/pacote do host;
- screenshots 1280×800 e 1920×1080;
- smoke no SteamOS e Desktop Mode;
- pacotes Linux, changelog, tag, release e push após gates.

## 10. Gates de aceite

### Biblioteca

- três origens funcionam: biblioteca, pasta e arquivos múltiplos;
- todo sistema público tem adapter ou bloqueio específico testado;
- arquivo reconhecido e já compatível nunca falha como “unsupported”;
- `PCSE01224.zip` é identificado como Vita instalável;
- preview não altera disco;
- cancelamento, retry, retomada e rollback preservam consistência;
- nenhuma origem é removida sem verificação e confirmação explícita;
- frontend só atualiza depois da validação do destino.

### UI

- máximo quatro escolhas principais na landing de Emulação;
- nenhuma lista principal expõe comandos `status/plan/apply` separados;
- um CTA primário por estado;
- inspector não ocupa largura quando vazio em 1280×800;
- teclado, foco, leitor de tela e contraste verificados;
- erros apontam item, causa e recuperação.

### KDE

- uma única raiz visível `PhaseZero`;
- zero entrada PhaseZero duplicada entre raiz/submenus;
- zero launcher canônico duplicado visível;
- jogos individuais visíveis somente se favoritos/pinados;
- arquivos `.desktop` passam `desktop-file-validate`;
- XML passa parser e `kbuildsycoca` em ambiente isolado;
- reparo é idempotente;
- rollback restaura estado anterior.

### Portabilidade

- domínio e UI importam sob plataforma Windows simulada;
- provider Windows produz árvore equivalente sem primitivas Unix;
- plataforma incompatível aparece desabilitada com motivo ou é filtrada conforme contrato.

## 11. Fora do escopo

- download automático de ROMs, BIOS, firmware, keys ou licenças;
- tentativa de contornar DRM;
- garantia de compatibilidade de cada jogo com emulador;
- MSI/PyInstaller nesta rodada;
- evolução da Web UI congelada.

## 12. Recomendação

Implementar como substituição de jornada, não como novo botão ao lado dos 71 existentes. Primeiro milestone deve entregar `scan → plan → install → verify` para Vita e estrutura genérica cobrindo demais sistemas. Segundo milestone conecta UI. Terceiro consolida menu KDE usando mesmo registry e ledger.
