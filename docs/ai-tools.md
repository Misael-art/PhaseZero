# AI Coding Tools

Escopo: integrações opcionais. Nenhuma chave real entra no repositório.

## Fontes oficiais usadas

- Claude Code: https://docs.claude.com/en/docs/claude-code/setup
- OpenCode: https://opencode.ai/docs/
- RTK / Rust Token Killer: https://www.rtk-ai.app/docs/
- Hermes Agent: https://github.com/NousResearch/hermes-agent
- OpenClaw: https://clawdocs.org/getting-started/installation/
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
| `openclaw` | `npm install -g --prefix <root> openclaw` | `openclaw --version` | `openclaw onboard` manual | Remove pacote/prefixo/PATH gerenciado |
| `rtk` | Release GitHub Windows, checksum se publicado | `rtk --version` | `rtk init`, `rtk gain` | Remove `rtk.exe`/PATH gerenciado |
| `antigravity-workflows` | Sem binário | Arquivos locais | Gera `.antigravity/workflows/*.md` | Manual, para preservar edições |
| `hermes-agent` | WSL2 + `install.sh --skip-setup` oficial | `wsl bash -lc "hermes --version"` | `hermes model/setup` manual dentro do WSL | Manual, preserva `~/.hermes` |
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
- Hermes Agent não usa o pacote npm `hermes` como sinal oficial. Em Windows, o caminho automatizado suportado é WSL2; se `wsl.exe` retornar `Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG`, o fluxo bloqueia cedo com `blockerKind=wsl-msi-registration-broken`.
- Integrações sem método Windows oficial ou silent installer confirmado ficam `manual`.
- OpenRouter Owl Alpha foi tratado como modelo opcional com ID `openrouter/owl-alpha`; disponibilidade/limites/preço dependem do provedor e devem ser validados antes de configurar Hermes.
- Providers BYOK OpenAI-compatible extras (`minimax`, `nex`, `zhipu-glm`) ficam manual opt-in no catalogo de secrets.
- `ai-usagebar` nao raspa APIs de billing com chaves brutas: Claude/Codex usam as credenciais OAuth gravadas pelos CLIs oficiais; Z.AI/OpenRouter/DeepSeek usam env vars vindas do manifesto validado (`validation.state == passed`). Z.AI permanece manual opt-in (zhipu-glm).
- `ai-memory` e beta (autor pede uso com cautela). O servidor loopback `127.0.0.1:49374` e opt-in via task de logon; `install-mcp`/`install-hooks` so rodam para agentes detectados e sao idempotentes. Dados de memoria do usuario (`wiki/`, `raw/`, `db/`) sao preservados na desinstalacao.
