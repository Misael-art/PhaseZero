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

## Suporte implementado

| Tool | Instalação | Validação | Configuração | Desinstalação |
| --- | --- | --- | --- | --- |
| `claude-code` | `npm install -g --prefix <root> @anthropic-ai/claude-code` | `claude --version` | Manual/login/chave oficial | Remove pacote/prefixo/PATH gerenciado |
| `opencode` | `npm install -g --prefix <root> opencode-ai` | `opencode --version` | Manual/provider oficial | Remove pacote/prefixo/PATH gerenciado |
| `openclaw` | `npm install -g --prefix <root> openclaw` | `openclaw --version` | `openclaw onboard` manual | Remove pacote/prefixo/PATH gerenciado |
| `rtk` | Release GitHub Windows, checksum se publicado | `rtk --version` | `rtk init`, `rtk gain` | Remove `rtk.exe`/PATH gerenciado |
| `antigravity-workflows` | Sem binário | Arquivos locais | Gera `.antigravity/workflows/*.md` | Manual, para preservar edições |
| `hermes-agent` | Manual/Windows beta oficial | Detecta, sem assumir npm `hermes` | Manual | Não remove artefato não gerenciado |
| `hermes-desktop` | Manual | Detecta caminhos comuns | Manual | Não remove artefato não gerenciado |
| `aion-ui` | Manual/winget oficial | Detecta caminhos comuns | Manual | Não remove artefato não gerenciado |

## CLI

Exemplos:

```powershell
.\install-cli.bat --tool claude-code --validate --dry-run --yes --no-admin
.\install-cli.bat --tool opencode --install-root "$env:TEMP\PhaseZero AI Tools" --yes --no-admin
.\install-cli.bat --tool opencode --uninstall --install-root "$env:TEMP\PhaseZero AI Tools" --yes --no-admin
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
- Integrações sem método Windows oficial ou silent installer confirmado ficam `manual`.
- OpenRouter Owl Alpha foi tratado como modelo opcional com ID `openrouter/owl-alpha`; disponibilidade/limites/preço dependem do provedor e devem ser validados antes de configurar Hermes.
