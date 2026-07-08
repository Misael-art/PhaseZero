# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
As versões seguem a data de build em `version.json`.

## [1.3.0] - 2026-07-08

Foco: Homelab CX — o servidor caseiro (Docker Compose) ganha status/plano rico,
geração segura de segredos, modos de acesso explícitos, backup/restore/update e um
gate de compatibilidade CasaOS opt-in. UI nativa e dashboard web legado atualizados.

### Adicionado
- **`pz server homelab`** ganhou `plan`, `open <app>`, `logs <app>`, `backup`,
  `restore --source PATH --yes`, `update` e `repair`, todos com saída JSON estruturada
  (`status`, `blockers`, `nextSteps`, `apps[]` com URL/bind/volumes/estado).
- **Segredos gerados automaticamente**: `pz server homelab repair`/`up` cria um `.env`
  seguro (`chmod 600`, fora do repositório) com tokens/senhas aleatórios para
  Vaultwarden, Nextcloud, Grafana, Paperless e n8n; nunca inline no compose.
- **Modos de acesso explícitos**: `--access local` (padrão, tudo em `127.0.0.1`),
  `--access tailscale` (expõe apps sensíveis apenas no IP Tailscale, bloqueado se
  deslogado) e `--access lan` (opt-in, `0.0.0.0`). Nenhuma porta fica exposta à WAN
  por padrão.
- **Imagens Docker fixadas por tag** (Portainer, Jellyfin, Syncthing, Vaultwarden,
  Uptime Kuma, Nextcloud, Grafana, Prometheus, Paperless, n8n) — sem `:latest` —
  com overrides `PZ_IMAGE_*` para quem quiser trocar a versão.
- **`pz server casaos`** (`status`/`plan`/`install`): gate de compatibilidade para
  CasaOS real. Detecta distro/arquitetura e bloqueia Arch/SteamOS/BigLinux/Manjaro;
  instalação permanece opt-in (`--yes`) mesmo em hosts compatíveis (Debian/Ubuntu/
  Raspberry Pi OS). O caminho padrão do PhaseZero continua sendo a stack Docker
  Compose + Portainer.
- **UI nativa**: 26 novos cards na categoria Servidor (status, planos, subir/parar,
  abrir apps, logs, backup/restaurar/atualizar, Tailscale, CasaOS). **Dashboard web
  legado**: nova página "Servidor" e lista de perfis `server-*` atualizada.
- **Testes**: `tests/linux-homelab.sh` cobre sintaxe, tags fixadas, binds seguros,
  bloqueio por segredo ausente, `.env` sem vazar segredo, `docker compose config`,
  bloqueio por Tailscale deslogado, URLs de `open`, dry-runs de backup/restore e o
  gate de compatibilidade CasaOS (Ubuntu ok, Arch bloqueado).

### Corrigido
- **Empacotamento (.deb/.rpm)**: `packaging/linux/deb/build-deb.sh` e
  `.../rpm/build-rpm.sh` copiavam `control`/`.spec` sem sincronizar o campo
  `Version` com `version.json` — um `.deb`/`.rpm` publicado podia reportar a
  versão anterior. Os scripts agora derivam a versão de `version.json` na cópia
  de build, sem alterar os arquivos versionados.
- **Empacotamento (AppImage)**: `build-appimage.sh` construía o AppDir dentro do
  checkout do repositório; em filesystems FUSE (ex.: NTFS-3g), a compactação
  paralela do `mksquashfs` podia descartar silenciosamente arquivos da stdlib do
  Python (`encodings/` incluído), gerando um AppImage que falhava ao abrir com
  "Failed to import encodings module" sem nenhum erro no build. O script agora
  usa por padrão um diretório temporário (`/tmp`, tmpfs); `PZ_APPIMAGE_WORK`
  continua disponível para quem sabe que seu filesystem é seguro.

## [1.2.0] - 2026-07-07

Foco: trilha Linux — IA/agentes, servidor caseiro, correções de emulação/Steam Deck
e redesign da Central de Controle. Os fluxos Windows não são afetados.

### Adicionado
- **Servidor caseiro**: perfis `server-llm`, `server-homelab`, `server-homelab-hermes`,
  `server-llm-hermes`, `server-llm-homelab`, `server-llm-homelab-hermes` e módulo
  `linux/server/` (`pz server status|llm|homelab|hermes|slim|boot`). Entrada GRUB
  `PhaseZero Homelab (headless)` (`multi-user.target` + `phasezero.homelab=1`, SO enxuto
  reversível) via `sudo pz server boot install`.
- **Proxies de IA nas IDEs**: `pz ai proxies configure-ides` conecta kimi/qwen/deeps/mimo
  ao opencode, opencode-desktop e zcode; `pz ai proxies test` faz probe honesto.
- **Acesso host↔guest**: `pz windows-vm host-access` (guestmount) e `pz waydroid host-access`
  (link ao armazenamento Android); bind opcional do home completo no Waydroid
  (`PZ_WAYDROID_SHARE_FULL_HOME=1`).
- **Perfis de controle Steam Deck**: `pz emulation controllers apply` (Ryujinx/RPCS3).
- **Central de Controle** redesenhada no estilo EmuDeck (dashboard, sidebar agrupada,
  cards com badges de estado, tema escuro roxo, toasts) — expõe todos os recursos acima.

### Corrigido
- **OpenCode "Interrompido"** (CLI/desktop): o padrão era um modelo Ollama local lento
  que estourava o timeout; agora usa um modelo free keyless do OpenCode Zen
  (`deepseek-v4-flash-free`), com Ollama como provider offline. `pz ai opencode free-model`.
- **Steam ROM Manager** não percorria ROMs e "Test/Parse" falhava com "invalid
  configuration": `${racores}` mapeia para `environmentVariables.raCoresDirectory`
  (Settings), que estava vazio; agora aponta para os cores do RetroArch.
- **Emulation Station** ignorava o Switch por um `noload.txt` órfão na raiz do sistema
  (auto-heal em `media.sh`).
- **Mídia** unificada para RetroArch flatpak (e DuckStation/PCSX2 flatpak).
- **BigBox** usa aceleração de hardware (DXVK) em vez de renderização por software.
- **Decky/CSS Loader**: a antigravity-proxy saiu de `:8080` (porta do CEF do Steam) para
  `:8090`; `plugins.sh` detecta conflito real de `:8080`.
- **Windows VM**: `HOME` e `/mnt/sdcard` agora são bind-montados (não symlinks) e expostos
  no SMB embutido do SLIRP (`\\10.0.2.4\qemu` → `home/`, `sdcard/`).
- **Portas dos proxies** movidas para 3010-3013 (evita colisão com open-webui/uptime-kuma).

## [1.1.0] - 2026-07-06
- Integrações do Control Center e proxy suite; sessões Gamescope; boot direto de
  Windows VM/Waydroid; instalação limpa LaunchBox/ES-DE. (Ver histórico git.)
