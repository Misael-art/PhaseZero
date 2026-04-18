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

---

<div align="center">
  <i>Construído com foco em automação e flexibilidade máxima para Windows Power Users.</i>
</div>
