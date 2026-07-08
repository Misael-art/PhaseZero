# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
As versões seguem a data de build em `version.json`.

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
