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

## ⚙️ Customização

Você pode facilmente plugar seus próprios aplicativos. Basta editar a seção principal de Componentes em `bootstrap-tools.ps1` usando a função:
`New-BootstrapComponentDefinition` injetando IDs do Winget, npm, ou links diretos de download.

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
