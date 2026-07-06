# Suite Linux de proxies de IA

## Estado

Implementada por `linux/ai/proxy-suite.sh`. Instalação é por usuário e não grava segredos no repositório.

```bash
linux/pz ai proxies status all
linux/pz ai proxies plan all
linux/pz ai proxies install all
linux/pz ai proxies install kimiproxy
linux/pz ai proxies start ollieproxy
linux/pz ai proxies stop ollieproxy
```

## Catálogo

| ID | Upstream | Tipo | Porta PhaseZero |
|---|---|---|---:|
| `kimiproxy` | `pedrofariasx/kimiproxy` | Node | 3000 |
| `qwen-worker-proxy` | `aptdnfapt/qwen-worker-proxy` | Cloudflare Worker | externa |
| `qwenproxy` | `pedrofariasx/qwenproxy` | Node | 3001 |
| `antigravity-proxy` | `pedrofariasx/antigravity-proxy` | Node | 8080 |
| `antigravity-openai-adapter` | `pedrofariasx/antigravity-openai-adapter` | Node | 8081 |
| `ollieproxy` | `pedrofariasx/ollieproxy` | Node | 3002 |
| `airlock` | `pedrofariasx/airlock` | biblioteca Node | externa |
| `unlimited-ai-proxy` | `pedrofariasx/unlimited-ai-proxy` | Node | 8787 |
| `deepsproxy` | `pedrofariasx/deepsproxy` | Node | 3004 |
| `mimo-ai-proxy` | `pedrofariasx/mimo-ai-proxy` | Go | 3005 |

## Portabilidade

- Checkouts: `~/.local/share/phasezero/ai-proxies/<id>`.
- Wrappers: `~/.local/bin/<id>`.
- Units: `~/.config/systemd/user/phasezero-<id>.service`.
- Ambientes: `~/.config/phasezero/ai-proxies/<id>.env`.
- Node: runtime 24 isolado em `.runtime/node24`; não depende da versão Node global.
- Playwright: Chromium de usuário é instalado para KimiProxy, QwenProxy e DeepsProxy.
- Go: build nativo em `.phasezero-bin`.
- Atualização: fast-forward. Checkout com mudanças locais/geradas é preservado e não sobrescrito.

Node com `start` baseado em `dist/` recebe build TypeScript. Worker e biblioteca recebem dependências, sem serviço local inventado. Serviços locais são instalados desativados.

## Credenciais e ativação

Cada upstream mantém seu próprio login, token ou fluxo OAuth. PhaseZero não fabrica credenciais e não inicia serviços antes do usuário configurar o arquivo `.env` ou o fluxo upstream.

Exemplo:

```bash
install -d -m 700 ~/.config/phasezero/ai-proxies
$EDITOR ~/.config/phasezero/ai-proxies/ollieproxy.env
linux/pz ai proxies start ollieproxy
systemctl --user status phasezero-ollieproxy.service
```

`qwen-worker-proxy` exige conta Cloudflare para deploy. `airlock` é biblioteca. Ambos são instalados localmente, mas não recebem unit systemd.

Teste de catálogo e dry-run: `tests/linux-ai-proxies.sh`.
