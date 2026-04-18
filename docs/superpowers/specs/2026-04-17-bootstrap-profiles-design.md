# Bootstrap Profiles Design

**Goal:** Reestruturar o `bootstrap-tools.ps1` para suportar perfis reutilizáveis, componentes individuais e resolução automática de dependências, preservando um caminho de compatibilidade com o comportamento atual.

## Contexto

O script atual instala uma base forte de ferramentas para Windows 11, com foco em CLI, IA e setup inicial de desenvolvimento. Ao mesmo tempo, ele já acumula responsabilidades de categorias diferentes: base do sistema, runtimes, apps desktop, ferramentas de agente, configurações do Claude, WSL e clonagem de repositórios.

O volume `F:\Steam\Steamapps` está sendo usado como raiz pessoal de `DevKits` e `DevProjetos`, o que indica que o bootstrap ideal precisa considerar não só instalação de pacotes, mas também organização do workspace e seleção por perfil de uso.

## Problema

O modelo linear atual do script dificulta:

- escolher apenas um conjunto coerente de ferramentas
- reaproveitar dependências entre grupos de instalação
- manter compatibilidade com setups anteriores
- ampliar o bootstrap para creator tools, containers e automação sem tornar o script ainda mais rígido

## Objetivos

- Permitir instalação por perfil (`base`, `ai`, `containers`, etc.).
- Permitir instalação individual por componente (`docker`, `ollama`, `ffmpeg`, etc.).
- Resolver dependências automaticamente.
- Preservar um perfil `legacy` que replique o fluxo atual.
- Tornar o workspace em `F:\Steam\Steamapps` um alvo de primeira classe para organização do ambiente.
- Manter o script executável em modo interativo e não interativo.

## Não Objetivos

- Não migrar o bootstrap para múltiplos arquivos nesta primeira etapa.
- Não substituir imediatamente toda a lógica existente de instalação.
- Não introduzir interface gráfica.
- Não remover o suporte ao fluxo atual antes de existir um perfil de compatibilidade.

## Abordagens Consideradas

### 1. Fluxo linear com `if/else` por perfil

Adicionar condicionais diretamente no script atual.

**Vantagens**

- Mudança inicial pequena
- Fácil de começar

**Desvantagens**

- Escala mal
- Duplica dependências
- Aumenta o acoplamento do script

### 2. Catálogo interno de componentes + perfis agregadores

Manter tudo no mesmo script, mas separar:

- catálogo de componentes instaláveis
- mapa de perfis
- resolvedor de dependências
- executor genérico

**Vantagens**

- Melhor equilíbrio entre simplicidade e extensibilidade
- Permite compatibilidade progressiva
- Facilita escolha por perfil ou item individual

**Desvantagens**

- Exige refactor estrutural do script

### 3. Manifesto externo em JSON/YAML

Extrair perfis e componentes para um arquivo de dados.

**Vantagens**

- Excelente manutenção futura
- Fácil versionamento de catálogos

**Desvantagens**

- Introduz complexidade extra cedo demais
- Aumenta a superfície de erro para esta primeira migração

## Abordagem Escolhida

Adotar a **abordagem 2**: catálogo interno de componentes + perfis agregadores.

Essa abordagem preserva o formato PowerShell único do projeto, reduz o risco do refactor e cria a base para evoluir depois para manifesto externo, se isso ainda fizer sentido.

## Interface de Execução

O script deve aceitar os seguintes parâmetros:

- `-Profile <string[]>`
- `-Component <string[]>`
- `-Exclude <string[]>`
- `-Interactive`
- `-ListProfiles`
- `-ListComponents`
- `-DryRun`
- `-NonInteractive`
- `-CloneBaseDir <string>`
- `-WorkspaceRoot <string>`

## Regras de Seleção

- `-Profile` seleciona um ou mais perfis.
- `-Component` seleciona componentes individuais.
- `-Profile` e `-Component` podem ser usados juntos; o conjunto final é a união dos dois.
- `-Exclude` remove apenas componentes opcionais do conjunto final.
- Se um item excluído for dependência obrigatória de outro item selecionado, o script deve abortar com mensagem clara.
- `-DryRun` mostra o plano final de execução sem instalar nada.
- `-ListProfiles` exibe nomes, descrição curta e componentes de cada perfil.
- `-ListComponents` exibe todos os componentes disponíveis e suas dependências.
- Se nenhum parâmetro for informado:
  - com `-Interactive`, abrir menu de seleção
  - com `-NonInteractive`, assumir `legacy`

## Modos de Uso

### Modo por perfil

Exemplos:

```powershell
.\bootstrap-tools.ps1 -Profile recommended
.\bootstrap-tools.ps1 -Profile base,ai
.\bootstrap-tools.ps1 -Profile full -Exclude chrome
```

### Modo por componente

Exemplos:

```powershell
.\bootstrap-tools.ps1 -Component docker,ollama,ffmpeg
.\bootstrap-tools.ps1 -Component git-lfs,powershell,terminal
```

### Modo interativo

Menu principal:

- `Recommended`
- `Legacy`
- `Full`
- `Custom by profile`
- `Custom by component`

## Modelo de Componentes

Cada componente deve ter:

- `Name`
- `Description`
- `DependsOn`
- `Optional`
- `InstallerType`
- `Handler`

### Tipos de instalador

- `winget`
- `npm`
- `uv`
- `feature`
- `config`
- `git`
- `workspace`

## Catálogo Inicial de Componentes

### Base do sistema

- `system-core`
  - responsabilidade: log, proxy WinHTTP, refresh de PATH, validações centrais, `winget`
  - dependências: nenhuma

- `git-core`
  - responsabilidade: instalar `Git.Git`
  - dependências: `system-core`

- `git-lfs`
  - responsabilidade: instalar `GitHub.GitLFS` e executar `git lfs install`
  - dependências: `git-core`

- `node-core`
  - responsabilidade: instalar `OpenJS.NodeJS.LTS`
  - dependências: `system-core`

- `python-core`
  - responsabilidade: instalar `Python.Python.3.13`, ajustar PATH e instalar `uv`
  - dependências: `system-core`

- `java-core`
  - responsabilidade: instalar `EclipseAdoptium.Temurin.17.JDK`
  - dependências: `system-core`

- `archive-tools`
  - responsabilidade: instalar `7zip.7zip`
  - dependências: `system-core`

- `media-core`
  - responsabilidade: instalar `ImageMagick.ImageMagick`
  - dependências: `system-core`

- `shell-upgrade`
  - responsabilidade: instalar `Microsoft.PowerShell`, `Microsoft.WindowsTerminal`, `Microsoft.PowerToys`
  - dependências: `system-core`

- `github-cli`
  - responsabilidade: instalar `GitHub.cli`
  - dependências: `git-core`

- `daily-apps`
  - responsabilidade: instalar `Google.Chrome` e `Notepad++.Notepad++`
  - dependências: `system-core`

### Containers

- `wsl-core`
  - responsabilidade:
    - habilitar `Microsoft-Windows-Subsystem-Linux`
    - habilitar `VirtualMachinePlatform`
    - executar `wsl --install -d Ubuntu`
    - executar `wsl --update`
    - executar `wsl --set-default-version 2`
  - dependências: `system-core`

- `wsl-ui`
  - responsabilidade: instalar `Microsoft.EdgeWebView2Runtime` e `OctasoftLtd.WSLUI`
  - dependências: `wsl-core`

- `docker`
  - responsabilidade: instalar `Docker.DockerDesktop`
  - dependências: `wsl-core`

### IA e agentes

- `ai-desktop`
  - responsabilidade instalar:
    - `Anthropic.Claude`
    - `Anthropic.ClaudeCode`
    - `Anysphere.Cursor`
    - `Codeium.Windsurf`
    - `Warp.Warp`
    - `ByteDance.Trae`
    - `SST.OpenCodeDesktop`
    - `Microsoft.VisualStudioCode.Insiders`
    - `Google.Antigravity`
    - `ZhipuAI.AutoClaw`
    - `Perplexity.Comet`
    - `Ollama.Ollama`
    - `kangfenmao.CherryStudio`
    - `ZedIndustries.Zed`
  - dependências: `system-core`

- `ai-cli-node`
  - responsabilidade instalar:
    - `@google/gemini-cli`
    - `@bonsai-ai/cli`
    - `@vibe-kit/grok-cli`
    - `@qwen-code/qwen-code@latest`
    - `@github/copilot`
    - `@openai/codex`
    - `openclaw`
  - dependências: `node-core`

- `ai-cli-py`
  - responsabilidade instalar:
    - `aider-chat`
    - `goose`
    - `opencode`
  - dependências: `python-core`

- `claude-config`
  - responsabilidade: aplicar defaults do Claude Code e corrigir hooks
  - dependências: `git-core`, `ai-desktop`

- `repos`
  - responsabilidade: clonar `gemini-cli` no diretório de trabalho
  - dependências: `git-core`

### Automação

- `n8n`
  - responsabilidade: instalar `n8n` via npm global
  - dependências: `node-core`

### Creator tools

- `creator-tools`
  - responsabilidade instalar:
    - `AutoHotkey.AutoHotkey`
    - `BlenderFoundation.Blender.LTS.4.5`
    - `Gyan.FFmpeg`
  - dependências: `system-core`

### Game dev

- `game-dev-tools`
  - responsabilidade instalar:
    - `Unity.UnityHub`
    - `Kitware.CMake`
    - `LLVM.LLVM`
    - `Rustlang.Rustup`
    - `Microsoft.VisualStudio.2022.Community`
  - dependências: `system-core`, `git-core`

### Gaming

- `gaming-tools`
  - responsabilidade instalar:
    - `Valve.Steam`
    - `Valve.SteamCMD`
  - dependências: `system-core`

### Workspace

- `workspace-layout`
  - responsabilidade:
    - garantir existência de `F:\Steam\Steamapps\DevKits`
    - garantir existência de `F:\Steam\Steamapps\DevProjetos`
    - garantir existência de `F:\Steam\Steamapps\DevProjetos\Docker`
    - usar `F:\Steam\Steamapps\DevProjetos` como raiz padrão de clones quando `-CloneBaseDir` não for informado
  - dependências: nenhuma

## Perfis

### `legacy`

Replica o comportamento atual do script, preservando ordem e componentes já existentes. Esse perfil existe para compatibilidade e rollback de risco.

Componentes:

- `system-core`
- `git-core`
- `node-core`
- `java-core`
- `media-core`
- `archive-tools`
- `python-core`
- `ai-desktop`
- `github-cli`
- `ai-cli-node`
- `ai-cli-py`
- `claude-config`
- `repos`
- `wsl-ui`

### `base`

Base universal para qualquer máquina nova.

Componentes:

- `system-core`
- `git-core`
- `git-lfs`
- `node-core`
- `python-core`
- `java-core`
- `archive-tools`
- `media-core`
- `shell-upgrade`
- `github-cli`
- `daily-apps`

### `containers`

Stack de containers e Linux no Windows.

Componentes:

- `wsl-core`
- `wsl-ui`
- `docker`

### `ai`

Ferramentas de IA locais, desktop e CLI.

Componentes:

- `ai-desktop`
- `ai-cli-node`
- `ai-cli-py`
- `claude-config`
- `repos`

### `automation`

Automação de fluxos locais.

Componentes:

- `n8n`

### `creator`

Ferramentas de criação e multimídia.

Componentes:

- `creator-tools`

### `game-dev`

Toolchain de jogos e compilação pesada.

Componentes:

- `game-dev-tools`

### `gaming`

Ferramentas relacionadas a jogos e servidores Steam.

Componentes:

- `gaming-tools`

### `workspace`

Estrutura de diretórios e organização do volume `F:`.

Componentes:

- `workspace-layout`

### `recommended`

Padrão sugerido para sua máquina pessoal.

Componentes:

- `base`
- `containers`
- `ai`
- `creator`
- `workspace`

### `full`

Instala tudo.

Componentes:

- `recommended`
- `automation`
- `game-dev`
- `gaming`

## Resolução de Dependências

O resolvedor deve:

1. Expandir perfis em componentes.
2. Expandir dependências transitivas.
3. Eliminar duplicatas.
4. Ordenar por dependência antes da execução.
5. Validar exclusões inválidas.

Exemplo:

- Entrada: `-Profile ai -Component docker`
- Resultado lógico:
  - `system-core`
  - `git-core`
  - `node-core`
  - `python-core`
  - `wsl-core`
  - `docker`
  - `ai-desktop`
  - `ai-cli-node`
  - `ai-cli-py`
  - `claude-config`
  - `repos`

## Comportamento do Workspace

O script deve passar a reconhecer:

- `-WorkspaceRoot`, com padrão em `F:\Steam\Steamapps`
- `-CloneBaseDir`, com padrão em:
  - `F:\Steam\Steamapps\DevProjetos`, se existir ou puder ser criado
  - caso contrário, o diretório atual

Esse desenho alinha o bootstrap com o uso real identificado no volume `F:`.

## Regras de Compatibilidade

- O perfil `legacy` deve ser mantido até a nova estrutura estar validada.
- O fluxo atual sem parâmetros não deve quebrar em automações existentes.
- Componentes já encapsulados em funções (`Ensure-*`) devem ser reaproveitados antes de qualquer reescrita.
- A nova arquitetura deve primeiro reorganizar a orquestração; otimizações internas podem vir depois.

## Observabilidade

O script deve registrar:

- perfis escolhidos
- componentes solicitados
- componentes efetivamente resolvidos
- dependências adicionadas automaticamente
- componentes excluídos
- modo `dry-run`

## Estratégia de Implementação

O refactor deve ocorrer em etapas:

1. Introduzir estrutura de catálogo sem remover chamadas atuais.
2. Criar resolvedor de perfis e componentes.
3. Adicionar `legacy` e validar equivalência com o fluxo atual.
4. Migrar perfis novos para usarem o resolvedor.
5. Só então tornar `recommended` o perfil principal.

## Estratégia de Teste

Validação manual mínima por cenário:

- `-ListProfiles`
- `-ListComponents`
- `-Profile legacy -DryRun`
- `-Profile recommended -DryRun`
- `-Component docker,ollama -DryRun`
- `-Profile ai -Exclude node-core`
  - resultado esperado: falha por dependência obrigatória
- execução real de um perfil pequeno:
  - `-Profile workspace`
  - `-Profile base`

## Riscos

- Misturar perfis com lógica antiga pode gerar duplicação de instalação.
- WSL e Docker exigem privilégios e reinício eventual.
- Alguns pacotes `winget` podem mudar de disponibilidade ao longo do tempo.
- O bloco de `game-dev` é pesado e deve permanecer opt-in.

## Mitigações

- Manter `legacy`.
- Implementar `-DryRun` cedo.
- Centralizar IDs de pacotes em um único catálogo.
- Separar componente obrigatório de componente opcional.

## Resultado Esperado

Ao final do refactor, o `bootstrap-tools.ps1` continuará sendo um único script, mas deixará de ser uma sequência rígida de instalações. Ele passará a funcionar como um bootstrap declarativo orientado por perfis e componentes, compatível com seu fluxo atual e preparado para crescer junto com o seu setup no Windows 11.
