# AI Coding Tools

Escopo: integrações opcionais. Nenhuma chave real entra no repositório.

## Fontes oficiais usadas

- Claude Code: https://docs.claude.com/en/docs/claude-code/setup
- Claude Desktop Linux: https://support.claude.com/en/articles/10065433-install-claude-desktop
- OpenCode: https://opencode.ai/docs/
- RTK / Rust Token Killer: https://www.rtk-ai.app/docs/
- Hermes Agent: https://hermes-agent.nousresearch.com/docs/getting-started/installation
- Hermes MCP: https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp
- OpenClaw: https://docs.openclaw.ai/install
- OpenClaw CLI: https://docs.openclaw.ai/cli/onboard
- AionUi: https://aionui.com/download/
- Google Antigravity: https://antigravity.google/
- Printing Press: https://github.com/mvanhorn/cli-printing-press
- IndexTTS2: https://github.com/index-tts/index-tts
- Odysseus: https://github.com/pewdiepie-archdaemon/odysseus
- Ollama: https://ollama.com/download
- LM Studio: https://lmstudio.ai/
- Open WebUI: https://docs.openwebui.com/
- n8n: https://docs.n8n.io/
- ai-usagebar: https://github.com/akitaonrails/ai-usagebar
- ai-memory: https://github.com/akitaonrails/ai-memory

## Suporte implementado

| Tool | Instalação | Validação | Configuração | Desinstalação |
| --- | --- | --- | --- | --- |
| `claude-code` | `npm install -g --prefix <root> @anthropic-ai/claude-code` | `claude --version` | Manual/login/chave oficial | Remove pacote/prefixo/PATH gerenciado |
| `opencode` | `npm install -g --prefix <root> opencode-ai` | `opencode --version` | Manual/provider oficial | Remove pacote/prefixo/PATH gerenciado |
| `openclaw` | Linux: `npm install -g --prefix <root> openclaw@latest` | `openclaw --version`, `openclaw doctor` | Linux: baseline non-interactive, MCP, ai-memory hooks; daemon guiado via `openclaw onboard --install-daemon` | Remove pacote/prefixo/PATH gerenciado |
| `rtk` | Windows: release GitHub; Linux: release GitHub `rtk-*-linux-*.tar.gz` com SHA-256 de `checksums.txt` | `rtk --version` | `rtk init`, `rtk gain`; no Linux via `linux/pz ai setup rtk` | Remove binario gerenciado em `~/.local/bin` |
| `antigravity-workflows` | Sem binário | Arquivos locais | Gera `.antigravity/workflows/*.md` | Manual, para preservar edições |
| `hermes-agent` | Linux/WSL2 + `install.sh --skip-setup --non-interactive` oficial | `hermes --version`, `hermes doctor` | Linux: MCP em `~/.hermes/config.yaml`; provider/login via `hermes setup --portal` ou `hermes model` | Manual, preserva `~/.hermes` |
| `hermes-desktop` | Manual | Detecta caminhos comuns | Manual | Não remove artefato não gerenciado |
| `aion-ui` | Manual/winget oficial | Detecta caminhos comuns | Manual | Não remove artefato não gerenciado |
| `printing-press` | `manual-workflow` oficial | Caminho/repo local quando usuario instala | Manual opt-in | Nao remove artefato nao gerenciado |
| `indextts2` | `manual-workflow` oficial | Caminho/repo local quando usuario instala | Manual opt-in, GPU/modelos por host | Nao remove artefato nao gerenciado |
| `odysseus` | `manual-workflow` oficial | Caminho/repo local quando usuario instala | Manual opt-in, admin console | Nao remove artefato nao gerenciado |
| `ollama` | Winget `Ollama.Ollama` sob demanda | `ollama --version` | Modelos/pulls manuais | Remocao via winget manual |
| `lm-studio` | Winget `LMStudio.LMStudio` sob demanda | Caminhos comuns/`lms` quando disponivel | Modelos manuais | Remocao via winget manual |
| `openwebui` | Docker manual | Container/porta sob escolha do usuario | Login/providers manuais | Manual para preservar volume |
| `n8n` | Template de workflow | `n8n --version` quando instalado | Workflows manuais com credenciais do usuario | Manual para preservar dados |
| `ai-usagebar` | Release Linux verificada (WSL) ou fallback cargo; no Windows experiencia e TUI/CLI `--json`, widget Waybar so em Linux | `ai-usagebar --help` / `ai-usagebar-tui` | `config.toml` gerado; chaves Z.AI/OpenRouter/DeepSeek vindas do manifesto validado; Claude/Codex usam OAuth dos CLIs oficiais | Remove binarios Windows gerenciados; preserva config/tokens |
| `ai-memory` | Release nativa Windows `ai-memory-windows-x86_64.zip` verificada por sha256; fallback `cargo install` | `ai-memory status` / `ai-memory --help` | `install-mcp`/`install-hooks --apply` por agente detectado; servidor loopback `127.0.0.1:49374` via task de logon | Remove binario gerenciado e task; preserva `wiki/`/`raw/`/`db/` do usuario |
| `headroom` | Linux: `uv tool install "headroom-ai[proxy]"` com fallback `pipx` | `headroom version` | Wrappers/proxy ficam explicitos via `linux/ai/headroom-agent.sh`; nada auto-wrap | Remove via `uv tool uninstall headroom-ai`/`pipx uninstall` |
| `phasezero-admin` | Linux: wrapper local; usa `bigsudo` oficial, fallback `pkexec`, fallback `sudo`; instala `bigsudo` via pacman/pkexec quando ausente e disponivel | `phasezero-admin --status` | Variaveis `PHASEZERO_ADMIN*` e regras para CLIs/IDEs; sem senha armazenada e sem sudoers passwordless | Remove `~/.local/bin/phasezero-admin`/fallback e configs user |

## CLI

Exemplos:

```powershell
.\install-cli.bat --tool claude-code --validate --dry-run --yes --no-admin
.\install-cli.bat --tool opencode --install-root "$env:TEMP\PhaseZero AI Tools" --yes --no-admin
.\install-cli.bat --tool opencode --uninstall --install-root "$env:TEMP\PhaseZero AI Tools" --yes --no-admin
.\install-cli.bat --tool hermes-agent --yes
.\install-cli.bat --tool printing-press --install --dry-run --yes --no-admin
.\install-cli.bat --all-ai-tools --validate --dry-run --yes
```

## Linux / SteamOS-like host

Entrada: `linux/pz ai`.

```bash
linux/pz ai status
linux/pz ai setup opencode
linux/pz ai setup codex
linux/pz ai setup claude
linux/pz ai desktop install-claude
linux/pz ai desktop status
linux/pz ai desktop repair-codex
linux/pz ai desktop install-services
linux/pz ai setup memory
linux/pz ai setup compat
linux/pz ai setup admin
linux/pz ai admin status
linux/pz ai setup rtk
linux/pz ai setup caveman
linux/pz ai setup headroom
linux/pz ai setup frugality
linux/pz ai compat status
linux/pz ai setup ides
linux/pz ai setup hermes
linux/pz ai setup openclaw
linux/pz ai mcp sync
linux/pz ai mcp repair
linux/pz ai mcp doctor
linux/pz ai mcp status
linux/pz ai menu
```

Automacoes Linux:

- `linux/ai/status.sh`: status JSON para runtime, CLIs, IDEs, MCP, Docker/Open WebUI, Ollama, RTK e ai-memory.
- `linux/ai/setup-agent-compat.sh`: instala RTK Linux por release GitHub verificada, aplica `rtk init`, instala Headroom via `uv`/`pipx`, reaplica regras Caveman/PhaseZero, mantém Ponytail limitado a workspace detectado, gera pack `ai-context-frugality` e status `agentCompat`.
- `linux/ai/setup-admin-bridge.sh`: cria `phasezero-admin`, detecta/instala `bigsudo`, fornece fallback `pkexec`/`sudo`, escreve estado/env user e sincroniza regra para agentes/IDEs.
- `linux/ai/headroom-agent.sh`: helper explícito para `headroom status/proxy/wrap-*`; wrappers não rodam automaticamente.
- `linux/ai/desktop-apps.sh`: instala Claude Desktop pelo repositorio apt oficial Anthropic em prefixo atomico do usuario. Valida assinatura, fingerprint e SHA-256. Corrige o pipeline do Codex Desktop Linux, habilita guarda de workspace e timer user.
- `linux/ai/setup-codex.sh`: instala/atualiza `@openai/codex` no prefixo npm do usuario e publica symlink em `~/.local/bin`.
- `linux/ai/setup-memory.sh`: instala `ai-memory` por AUR (`ai-memory-bin`) quando disponivel; fallback Docker wrapper; fallback build Cargo. Configura serviço user loopback `127.0.0.1:49374` e roda `install-mcp`/`install-hooks` para agentes detectados.
- `linux/ai/setup-hermes.sh`: instala Hermes pelo instalador oficial em modo não interativo, escreve env template sem segredos, sincroniza MCPs em `~/.hermes/config.yaml` e instala o pacote Python `mcp` no venv quando disponível.
- `linux/ai/setup-openclaw.sh`: instala `openclaw@latest` no prefixo npm do usuário, executa baseline não interativo (`openclaw setup --non-interactive --accept-risk` com fallback legado), sincroniza MCPs em `~/.openclaw/config.json`, aplica `ai-memory` MCP/hooks e instala o Gateway user service via `openclaw gateway install/start`.
- `linux/ai/setup-ides.sh`: gera recomendações `.vscode/extensions.json`, sincroniza MCP seguro em VS Code workspace/user, Cursor, Zed e ZCode, adiciona helper Neovim opcional e grava estado em `~/.local/state/phasezero/ai/ides.json`.
- `linux/ai/mcp-manager.sh`: sincroniza MCP seguro por padrao (`ai-memory` loopback), repara configs quebradas, e permite install explicito de remotos em OpenCode (`mcp`), Claude/Claude Desktop, Codex TOML, VS Code, Cursor, Zed, ZCode, Hermes YAML e OpenClaw JSON.
- `linux/ai/setup-usagebar.sh`: instala `ai-usagebar-bin` quando AUR existe e cria config por env vars.

O perfil `profiles/dev-ai.json` preserva Windows e expande só Linux com `python-pipx`, `uv`, `git`, `github-cli`, `direnv` e scripts AI novos.

Resultados estruturados:

- `--result-path <file>` grava JSON.
- `--log-path <file>` grava JSONL.
- Exit `0`: ação validada/planejada/concluída ou validação sem bloqueio.
- Exit `2`: argumento/tool inválido ou erro de execução.
- Exit `3`: install/configure/uninstall bloqueado por suporte externo ou falha validada.

## Segurança

- Instalações automatizadas usam root gerenciado por usuário.
- PATH é alterado só no escopo User e registrado em manifesto.
- Uninstall remove apenas artefatos registrados pelo projeto.
- Chaves/API/login ficam em métodos oficiais das ferramentas ou SecretStore/Credential Manager; placeholders em docs.
- No Linux, `rotate-secrets.sh` grava chaves no `pass`; aplicação de valor cru em config exige `PZ_AI_APPLY_RAW_SECRETS=1`.
- Claude Desktop usa somente o repositorio oficial Anthropic. BigLinux extrai o `.deb` validado para `~/.local/share/phasezero`; nenhum AUR e nenhuma escrita root.
- Codex Desktop Linux continua sendo wrapper comunitario sobre o DMG macOS. PhaseZero valida o pacote pacman local e usa PolicyKit; Codex CLI permanece pacote oficial `@openai/codex`.
- Hermes Agent não usa o pacote npm `hermes` como sinal oficial. Em Windows, o caminho automatizado suportado é WSL2; se `wsl.exe` retornar `Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG`, o fluxo bloqueia cedo com `blockerKind=wsl-msi-registration-broken`.
- Integrações sem método Windows oficial ou silent installer confirmado ficam `manual`.
- OpenRouter Owl Alpha foi tratado como modelo opcional com ID `openrouter/owl-alpha`; disponibilidade/limites/preço dependem do provedor e devem ser validados antes de configurar Hermes.
- Providers BYOK OpenAI-compatible extras (`minimax`, `nex`, `zhipu-glm`) ficam manual opt-in no catalogo de secrets.
- `ai-usagebar` nao raspa APIs de billing com chaves brutas: Claude/Codex usam as credenciais OAuth gravadas pelos CLIs oficiais; Z.AI/OpenRouter/DeepSeek usam env vars vindas do manifesto validado (`validation.state == passed`). Z.AI permanece manual opt-in (zhipu-glm).
- `ai-memory` e beta (autor pede uso com cautela). O servidor loopback `127.0.0.1:49374` e opt-in via task de logon; `install-mcp`/`install-hooks` so rodam para agentes detectados e sao idempotentes. Dados de memoria do usuario (`wiki/`, `raw/`, `db/`) sao preservados na desinstalacao.
- RTK no Linux usa somente release oficial `rtk-ai/rtk`, asset por arquitetura e checksum publicado. Se RTK estiver ausente, PhaseZero fica em modo degradado e comandos seguem diretos.
- Headroom nunca auto-envolve agentes. O usuario chama `linux/ai/headroom-agent.sh wrap-codex`, `wrap-claude`, `proxy` ou `mcp-install` conscientemente.
- Admin bridge nunca grava senha, nunca cria sudoers passwordless e nunca executa comando privilegiado em validação. Ele só padroniza o caminho: `phasezero-admin <cmd>` ou `bigsudo <cmd>`.
