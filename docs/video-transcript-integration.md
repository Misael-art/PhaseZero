# PhaseZero video transcript integration

Plano aplicado para transcricoes tecnicas. Escopo: 58 titulos, cada um com Destino final definido. Itens arriscados ficam opt-in/manual; itens sem valor para o host atual ficam Descartado. Template MTP registrado como `llamacpp-mtp-template`.

| # | Titulo | Destino final | Acao | Risco | Observacao |
|---|---|---|---|---|---|
| 1 | Zen Browser | `zen-browser` + `zen-browser-privacy-prefs` | Integrado | Seguro | Winget real, prefs manuais. |
| 2 | Jan | `jan-ai` | Integrado | Seguro | Winget real, modelos sob escolha do usuario. |
| 3 | Obsidian | `obsidian` + `knowledge-vault-obsidian-template` | Integrado | Seguro | Vault local manual. |
| 4 | KDE Connect | `kde-connect` | Integrado | Seguro login | Pareamento interativo. |
| 5 | Godot | `godot` + perfil `game-dev` | Integrado | Seguro | Engine de criacao. |
| 6 | Krita | `krita` + perfil `game-dev` | Integrado | Seguro | Arte 2D. |
| 7 | Audacity | `audacity` + perfil `game-dev` | Integrado | Seguro | Audio local. |
| 8 | Supermaven VS Code | `supermaven-vscode` | Integrado | Seguro login | Extensao VS Code opt-in. |
| 9 | Printing Press | `printing-press` | Integrado manual | Experimental | Fluxo oficial manual. |
| 10 | Odysseus | `odysseus` | Integrado manual | Experimental login | Admin console experimental. |
| 11 | IndexTTS2 | `indextts2` | Integrado manual | Experimental GPU | Requer GPU/Python conforme host. |
| 12 | AnythingLLM | `anythingllm` | Integrado manual | Manual login | Instalador silencioso nao validado. |
| 13 | llama.cpp server MTP | `llamacpp-server` + `llamacpp-mtp-template` | Integrado manual | Experimental | Diagnostico sem baixar modelos. |
| 14 | Ollama | `ollama` | Integrado | Seguro | Winget ja existente no catalogo. |
| 15 | LM Studio | `lm-studio` | Integrado | Seguro | Winget ja existente no catalogo. |
| 16 | Open WebUI | `openwebui` | Integrado manual | Manual login | Docker/porta/login sob controle do usuario. |
| 17 | n8n | `n8n` + `n8n-youtube-workflow-template` | Integrado manual | Manual login | Workflow template sem credenciais. |
| 18 | v0.dev | `app-v0-dev` | Integrado | Seguro login | Atalho web app. |
| 19 | Bolt.new | `app-bolt-new` | Integrado | Seguro login | Atalho web app. |
| 20 | Lovable.dev | `app-lovable-dev` | Integrado | Seguro login | Atalho web app. |
| 21 | MiniMax | provider `minimax` | Integrado | BYOK | OpenAI-compatible manual. |
| 22 | NexRouter | provider `nex` | Integrado | BYOK | OpenAI-compatible manual. |
| 23 | Zhipu GLM / Z.ai | provider `zhipu-glm` | Integrado | BYOK | OpenAI-compatible manual. |
| 24 | Claude RTK config | `agent-config-claude-rtk-template` | Integrado manual | Manual | Template sem segredos. |
| 25 | Agent Config categoria | `agent-config` | Integrado | Manual | Categoria AppTuning opt-in. |
| 26 | Knowledge Vault categoria | `knowledge-vault` | Integrado | Manual | Categoria AppTuning opt-in. |
| 27 | Workflow Automation categoria | `workflow-automation` | Integrado | Manual | Categoria AppTuning opt-in. |
| 28 | OpenAI-compatible BYOK | `bootstrap-secrets` | Integrado | BYOK | Providers passam por manifesto. |
| 29 | AI tool dry-run | `Invoke-BootstrapAiToolAction -DryRun` | Integrado | Seguro | Experimental planeja sem mutar host. |
| 30 | UI safety badges | `Get-BootstrapUiContract.components[].badges` | Integrado | Seguro | Seguro, Experimental, Manual, GPU, login. |
| 31 | UI official source | `officialSource` | Integrado | Seguro | Link oficial no contrato. |
| 32 | UI manual reason | `manualReason` | Integrado | Seguro | Motivo visivel no tooltip. |
| 33 | UI GPU flag | `requiresGpu` | Integrado | Seguro | IndexTTS2 sinalizado. |
| 34 | UI login flag | `requiresInteractiveLogin` | Integrado | Seguro | KDE Connect, web apps e similares. |
| 35 | App install Zen | `app-zen-browser` | Integrado | Seguro | App sob demanda. |
| 36 | App install Jan | `app-jan-ai` | Integrado | Seguro | App sob demanda. |
| 37 | App install Obsidian | `app-obsidian` | Integrado | Seguro | App sob demanda. |
| 38 | App install KDE Connect | `app-kde-connect` | Integrado | Seguro login | App sob demanda. |
| 39 | App install Godot | `app-godot` | Integrado | Seguro | App sob demanda. |
| 40 | App install Krita | `app-krita` | Integrado | Seguro | App sob demanda. |
| 41 | App install Audacity | `app-audacity` | Integrado | Seguro | App sob demanda. |
| 42 | App install AnythingLLM | `app-anythingllm` | Integrado manual | Manual login | App sob demanda com manual gate. |
| 43 | App install Odysseus | `app-odysseus` | Integrado manual | Experimental login | App sob demanda com manual gate. |
| 44 | App install IndexTTS2 | `app-indextts2` | Integrado manual | Experimental GPU | App sob demanda com GPU flag. |
| 45 | Safe profile leakage | `safe-base`, `recommended`, `public-beta` | Bloqueado | Seguro | Novos itens nao entram em defaults seguros. |
| 46 | Game-dev focus | `game-dev` | Integrado | Seguro | Inclui so Godot, Krita, Audacity. |
| 47 | GreenLuma | nenhum componente | Descartado | Alto | Risco/legalidade incompatibiliza bootstrap real. |
| 48 | Autoinstalacao de pesos TTS | nenhum componente | Descartado | Alto | Peso grande exige decisao do usuario. |
| 49 | Clone automatico Odysseus | nenhum componente | Descartado | Alto | Console admin exige revisao manual. |
| 50 | MCP gerado por Printing Press | nenhum componente | Descartado | Alto | Geracao so apos auditoria humana. |
| 51 | Download automatico de modelos llama.cpp | nenhum componente | Descartado | Alto | Modelo/VRAM variam por host. |
| 52 | Login automatico web apps | nenhum componente | Descartado | Alto | Credenciais ficam com usuario. |
| 53 | Sync remoto Obsidian | nenhum componente | Descartado | Medio | Vault local preserva privacidade. |
| 54 | n8n cron automatico | nenhum componente | Descartado | Alto | Jobs exigem credenciais e revisao. |
| 55 | Provider default global novo | nenhum componente | Descartado | Alto | BYOK fica opt-in por app. |
| 56 | Preferencias Zen automutaveis | nenhum componente | Descartado | Medio | Checklist manual evita sobrescrever perfil. |
| 57 | Teste final host | Pester + dry-run + UI smoke | Integrado | Seguro | Verificacao local fecha o trabalho. |
| 58 | Headroom AI | `headroom-ai` + `headroom-agent-context-compression` | Integrado manual | Experimental | PyPI/uv tool real; wrappers e proxy ficam opt-in por helper local. |
