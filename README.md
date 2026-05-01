<div align="center">
  <img src="https://img.shields.io/badge/Windows-0078D6?style=for-the-badge&logo=windows&logoColor=white" />
  <img src="https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" />
  <img src="https://img.shields.io/badge/Steam_Deck-151014?style=for-the-badge&logo=steamdeck&logoColor=white" />
  
  <h1>🚀 PhaseZero</h1>
  <p><strong>O Hub definitivo de Bootstrapping e Pós-Instalação para Windows e Steam Deck</strong></p>
</div>

---

## 💡 O que é o PhaseZero?

O **PhaseZero** é muito mais que um script de "pós-formatação". É um orquestrador sob demanda capaz de forjar o ambiente ideal para a sua máquina através de perfis predefinidos. Com uma interface CLI e suporte à Interface de Usuário (UI) amigável, ele automatiza a instalação de ferramentas, configurações de ambiente e ajustes profundos do sistema para Gamers, Desenvolvedores, Criadores de Conteúdo, e Entusiastas de Inteligência Artificial.

## ✨ Principais Funcionalidades

- 🎮 **Steam Deck Essentials & Automation**: Instalação customizada para Steam Deck (LCD/OLED) rodando Windows. Configurações de display automático (Handheld, TV, Monitor), overlay, automação de áudio, hotkeys baseadas em família de monitor, e suporte total a *Steam Deck Tools*.
- 🤖 **Perfis de IA Embutidos**: Deploy rápido de stacks contemporâneos de IA, como Claude Desktop, Cursor, Trae, Gemini CLI, Ollama, e muito mais. 
- 🛠️ **DevForge Hub**: SDKs, Winget, WSL/Docker, Node LTS, Python 3.13+, Git LFS e utilitários chave instalados silenciosamente.
- 🎨 **Interface Contratual Opcional**: Integrável a scripts visuais (`bootstrap-ui.bat`) para quem prefere dar "cliques" invés de lidar com flags de terminal diretamente.
- 🧹 **Host Health (Saúde do Host)**: Monitoramento de recursos de GPU/CPU, finalização de apps de background pesados enquanto se joga e tratativas de limpeza do sistema.

## 📦 Perfis Embutidos (Profiles)

O **PhaseZero** entende que cada máquina tem uma fase zero diferente. Escolha o perfil alvo durante o Bootstrap:
*   **Base**: Kit de sobrevivência essencial, universal para qualquer PC limpo (Navegadores, Git, terminais robustos).
*   **Containers & Game Dev**: Builds completas via WSL2, Docker e CMake/Unity.
*   **AI Ecosystem**: Transforma a sua máquina em um cluster criativo cognitivo local.
*   **Steam Deck Full**: Transforma o seu portátil com a camada máxima de facilidades, convertendo perfis automaticamente ao dockar.

## 🚀 Como Usar

### Requisitos

- Windows 10/11 com Windows PowerShell 5.1.
- Sessão interativa de usuário para abrir a UI WPF.
- Em Windows 11 limpo com internet, o script usa apenas Windows PowerShell 5.1 inicial. Se `winget`/App Installer não estiver acessível, tenta baixar e instalar o App Installer oficial (`https://aka.ms/getwinget`) antes de continuar.
- Git, Node/npm e Python são verificados pelo `-Doctor` e instalados pelos perfis quando necessário.
- Pester 3.4+ para rodar a suíte local de testes.

1. **Clone o Repositório:**
   ```powershell
   git clone https://github.com/Misael-art/PhaseZero.git
   cd PhaseZero
   ```

2. **Inicie o Bootstrap** (Através do Bat UI)
   ```cmd
   .\bootstrap-ui.bat
   ```
   **Ou pela linha de comando** caso queira ser direto ao ponto:
   ```powershell
   .\bootstrap-tools.ps1 # irá expor prompts via console.
   ```

3. **Execute um diagnóstico seguro antes de instalar:**
   ```powershell
   .\bootstrap-tools.ps1 -Doctor -DryRun -NonInteractive
   .\bootstrap-tools.ps1 -Profile base -DryRun -NonInteractive
   ```

## ✅ Verificação Local

Use estes comandos antes de publicar ou rodar perfis reais:

```powershell
# parse dos scripts principais
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\bootstrap-tools.ps1), [ref]$tokens, [ref]$errors)
$errors | Format-List

# contrato usado pela UI
.\bootstrap-tools.ps1 -UiContractJson -NonInteractive | ConvertFrom-Json | Out-Null

# suíte automatizada
Import-Module Pester -MinimumVersion 3.4.0
Invoke-Pester -Script .\tests -PassThru
```

Checks manuais recomendados:

- `.\bootstrap-ui.bat -SmokeTest` deve retornar JSON com páginas, idiomas e caminho de estado.
- `.\bootstrap-tools.ps1 -Profile ai -DryRun -NonInteractive` deve resolver dependências sem instalar.
- `.\bootstrap-tools.ps1 -ListApps` lista apps instaláveis sob demanda.
- `.\bootstrap-tools.ps1 -App steam,vscode -DryRun -NonInteractive` resolve apps individuais para componentes instaláveis.
- `.\bootstrap-tools.ps1 -Profile steamdeck-recommended -DryRun -NonInteractive` deve listar bloqueadores manuais e auditoria Steam Deck.
- `.\bootstrap-tools.ps1 -Profile steamdeck-input-advanced -DryRun -NonInteractive` mostra a pilha opt-in com Handheld Companion e GlosSI.

## 🚢 Prontidão de Produção

- Rode sempre em `-DryRun` antes de execução real, principalmente em perfis que alteram PATH, variáveis de usuário, WSL, serviços, agendamentos ou automação Steam Deck.
- Execute PowerShell como administrador somente quando o relatório listar necessidade explícita.
- A página **Windows e Linux** audita o Windows Boot Manager/BCD, mostra default, timeout, ordem de menu e entradas órfãs. Alterações de default/timeout e limpeza de BCD exigem Administrador e criam backup antes de mudar.
- Guarde logs em `%TEMP%\bootstrap-tools_*.log` ou em `-LogPath` controlado.
- Não versionar `.bootstrap-tools/`, `.mcp.json`, dumps de logs, manifests com credenciais, clones locais ou worktrees de agentes.
- Para MCPs locais, copie `.mcp.example.json` para `.mcp.json` e substitua placeholders apenas no arquivo ignorado.
- Rotacione qualquer token que tenha sido colado em arquivo fora do gerenciador de segredos.

## ⚙️ Customização

Você pode instalar apps individuais sem ativar um perfil inteiro:

```powershell
.\bootstrap-tools.ps1 -ListApps
.\bootstrap-tools.ps1 -App steam,vscode,discord -DryRun -NonInteractive
.\bootstrap-tools.ps1 -App steam,vscode,discord -NonInteractive
```

Para plugar apps próprios, edite `bootstrap-tools.ps1`:

- `New-BootstrapComponentDefinition`: define o componente real (`winget`, `chocolatey`, `npm`, `uvtool`, `manual-required`, `builtin`).
- `Get-BootstrapOnDemandAppDefinitions`: expõe o app na UI/CLI sob demanda.
- `Get-BootstrapAppTuningCatalog`: agrupa otimizações e instalações individuais na página **Otimizar Apps**.

## 🎮 Steam Deck no Windows

O perfil `steamdeck-recommended` mantém o caminho seguro por padrão:

- Steam Deck Tools portable por ayufan com `PowerControl.exe`, `SteamController.exe`, `FanControl.exe` e `PerformanceOverlay.exe`;
- RTSS/MSI Afterburner para overlay low;
- Playnite em fullscreen como fallback de console;
- auditoria de conflito do Steam Input Desktop Layout para evitar duplo comando no Windows.

Stacks avançados ficam opt-in por risco de conflito de controle:

```powershell
.\bootstrap-tools.ps1 -Profile steamdeck-input-advanced -DryRun -NonInteractive
.\bootstrap-tools.ps1 -App handheld-companion,glossi -DryRun -NonInteractive
```

- `handheld-companion`: instala via winget (`BenjaminLSR.HandheldCompanion`) para Auto-TDP, gyro, emulação DS4 e QuickTools overlay.
- `glossi`: instala via Chocolatey (`glossi`) para Steam Input global em UWP/launchers. Se Chocolatey não existir, a execução real precisa de Administrador para bootstrap do `choco.exe`.
- Antes de usar Handheld Companion ou GlosSI junto com Steam, revise `Steam > Settings > Controller > Desktop Layout` e desative/limpe o layout de desktop quando outro stack estiver gerenciando input.

## 🔐 Segredos Locais

O bootstrap agora mantém credenciais locais em `.bootstrap-tools/bootstrap-secrets.json`, arquivo já ignorado pelo Git. Cada provedor pode ter várias chaves nomeadas, uma credencial ativa e uma fila manual de rotação.

Fluxo sugerido:

```powershell
# garante/cria o manifesto local
.\bootstrap-tools.ps1 -Component bootstrap-secrets -NonInteractive

# importa um arquivo bruto de anotações, valida o que for suportado
.\bootstrap-tools.ps1 -SecretsImportPath "C:\caminho\credenciais.md"

# lista provider/id/status sem imprimir o segredo
.\bootstrap-tools.ps1 -SecretsList

# revalida todas as credenciais suportadas
.\bootstrap-tools.ps1 -SecretsValidateAll

# gira para a próxima credencial válida do provedor
.\bootstrap-tools.ps1 -SecretsActivateProvider openrouter

# ativa uma credencial específica, se passar na validação
.\bootstrap-tools.ps1 -SecretsActivateCredential openrouter-gmail-01
```

Provedores com validação dedicada nesta etapa:

- `openai`
- `anthropic`
- `google`
- `openrouter`
- `github`
- `moonshot`
- `deepseek`
- `bonsai` entra como `unsupported/manual-review` até existir um validador confiável

Quando a credencial ativa falha na validação, o bootstrap não reaplica aquele segredo nos env vars nem nos arquivos de configuração dos clientes.

## 🧠 API Center, OpenCode, Comet e Agent Skills

O perfil `ai` e o fluxo `legacy` agora incluem o componente `agent-skills`. Ele instala o `caveman` por padrão usando os caminhos oficiais quando os runtimes existem, registra o resultado em `.bootstrap-tools/agent-skill-state.json` e não falha o bootstrap quando uma IDE/CLI ainda não está instalada.

Automação Caveman:

- `Claude Code`: tenta `claude plugin marketplace add JuliusBrussee/caveman` e depois `claude plugin install caveman@caveman`;
- fallback Claude Code: usa o instalador standalone documentado apenas se o plugin falhar;
- `Gemini CLI`: usa `gemini extensions install https://github.com/JuliusBrussee/caveman`;
- `Cursor`, `Windsurf`, `Cline` e `GitHub Copilot`: usam `npx skills add JuliusBrussee/caveman -a <target> --copy` no Windows;
- regras always-on são geradas a partir de `assets/agent-skills/caveman-always-on.md` com blocos marcados, sem sobrescrever instruções existentes.

Arquivos de regra gerados quando o componente roda:

- `.cursor/rules/caveman.mdc`
- `.windsurf/rules/caveman.md`
- `.clinerules/caveman.md`
- `.github/copilot-instructions.md`
- `AGENTS.md`

O `OpenCode` agora recebe todos os provedores LLM com credencial ativa e `validation.state = passed`. O bootstrap mescla `~/.local/share/opencode/auth.json`, preserva credenciais não gerenciadas e só adiciona metadata em `opencode.json` quando precisa de `baseURL` customizado. A seleção de `model`, `small_model`, tema e providers não gerenciados é preservada.

O `Comet` é tratado como `manual-only`: o bootstrap detecta a instalação e mostra quais provedores já estão prontos, mas não escreve arquivos internos não documentados.

A UI (`bootstrap-ui.bat`) ganhou a página **API Center**, onde é possível ver:

- total de credenciais por provedor, credencial ativa e estado de validação;
- quais apps estão auto-aplicados e quais exigem setup manual;
- lista de credenciais com segredo mascarado;
- provedores ainda não configurados com links de criação, docs e campos necessários;
- ações para adicionar/editar, validar, ativar, importar arquivo bruto e aplicar nos apps suportados.

## 🧩 VS Code e Insiders

O perfil `ai` agora também garante `Visual Studio Code`, `Visual Studio Code - Insiders` e instala automaticamente estas extensões nos dois editores:

- `augment.vscode-augment`
- `kilocode.Kilo-Code`
- `Kombai.kombai`
- `laurids.agent-skills-sh`
- `digitarald.agent-memory`
- `RooVeterinaryInc.roo-code-nightly`
- `ms-toolsai.jupyter-renderers`
- `saoudrizwan.cline-nightly`
- `Continue.continue`

Automação aplicada nesta etapa:

- instala/extende as extensões via CLI oficial do VS Code (`code` / `code-insiders`);
- reaplica MCPs suportados para `Roo` e `Cline`;
- gera `.continue/.env` e `%USERPROFILE%\.continue\config.yaml` com segredos validados e MCPs suportados;
- define defaults seguros do `Agent Memory` em `settings.json`.

Restrições intencionais para segurança/resiliência:

- `Augment`, `Kilo` e `Kombai` continuam com autenticação manual/assistida porque os fornecedores dependem de login próprio;
- `Cline` e `Roo` recebem MCPs automaticamente, mas a seleção/autenticação do provedor continua na UI da extensão;
- o estado local da automação fica em `.bootstrap-tools/vscode-extension-state.json`, também fora do Git.

## 🔌 MCPs Gerenciados

O componente `bootstrap-mcps` agora instala e reaplica uma camada gerenciada de MCPs para os clientes compatíveis (`Claude Code`, `Claude Desktop`, `Cursor`, `Windsurf`, `Trae`, `OpenCode`, `VS Code`, `Roo`, `Cline`, `Continue`, `Zed`, `ZCode` e `OpenClaw`).

Catálogo automatizado nesta etapa:

- `Markitdown`
- `Netdata`
- `Context7`
- `Chrome DevTools MCP`
- `Playwright`
- `GitHub MCP Server`
- `Serena`
- `Firecrawl`
- `Desktop Commander`
- `Notion`
- `Supabase`
- `Figma MCP Server`
- `Apify`
- `Vercel MCP`
- `Box MCP Server (Remote)`

Estratégia de provisionamento:

- MCPs locais usam `npx` ou `uv tool` quando isso é mais resiliente para o host;
- MCPs remotos usam `mcp-remote@latest`, evitando espalhar secrets desnecessariamente por arquivos locais;
- `Context7` e `Apify` aceitam modo remoto por padrão e alternam para modo local quando existe token ativo;
- `Firecrawl` e `Netdata` só entram quando existe credencial ativa utilizável;
- `Notion`, `Supabase`, `Figma`, `Vercel` e `Box` entram prontos para OAuth/autorizações no primeiro uso.

Arquivos locais de estado:

- `.bootstrap-tools/bootstrap-mcp-state.json`
- `.bootstrap-tools/bootstrap-secrets.json`

Observações de segurança:

- a resolução enriquecida com MCPs é opt-in dentro do script; `bootstrap-secrets` continua conservador e não injeta MCPs gerenciados por padrão;
- nenhum segredo é enviado ao Git;
- segredos só são aplicados quando a credencial ativa está aprovada, com exceção dos provedores explicitamente marcados como bypass manual para MCPs opcionais (`context7`, `firecrawl`, `apify`, `netdata`, `supabase`);
- provedores OAuth continuam dependentes da autorização do usuário no cliente final.

---

<div align="center">
  <i>Construído com foco em automação e flexibilidade máxima para Windows Power Users.</i>
</div>
