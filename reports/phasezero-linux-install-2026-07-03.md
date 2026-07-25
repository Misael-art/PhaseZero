# Relatório técnico — instalação PhaseZero Linux

Data: 2026-07-02 a 2026-07-03  
Host: `misael-jupiter`  
Projeto: `/mnt/sdcard/Projects/PhaseZero`  
Escopo: instalação, configuração e validação Linux/BigLinux/Arch  
Branch: `codex/fix-cli-status-legend`, 4 commits à frente do remoto  
Política aplicada: worktree preservado; nenhum commit, push, reset, checkout, clean ou descarte

## Resumo executivo

Instalação Linux aplicável concluída com sucesso parcial alto.

- Host confirmado como Steam Deck LCD/Jupiter, BigLinux/Manjaro, KDE Plasma Wayland, AMD Van Gogh, 14 GiB RAM.
- Perfis `safe-base`, `dev-ai`, `gaming`, `emulation-linux`, `steamdeck-linux` e `homelab` planejados antes da aplicação.
- 97 pacotes/dependências instalados ou atualizados pelo lote principal Pacman; componentes adicionais instalados por AUR e Flatpak.
- AI, MCPs, IDEs, SteamOS UX, Decky, emulação, mídia canônica, serviços e ajustes persistentes configurados.
- Cinco suites Linux passaram. Sintaxe Bash e JSON passaram. Nenhuma unidade systemd falha.
- Homelab Compose validado, mas containers PhaseZero não iniciados: segredos obrigatórios ausentes e conflito de porta nos extras.
- Proton-GE não instalado: pacote do repositório BigLinux possui dependências indisponíveis.
- Nenhuma ROM, BIOS, firmware, key, crack ou conteúdo não autorizado baixado. BIOS existente permaneceu local. Switch keys/firmware continuam vazios.
- Nenhum componente Windows executado. Arquivos PowerShell preservados.
- Nenhuma mudança PhaseZero de boot executada. Hook pós-instalação do pacote CoreCtrl regenerou `grub.cfg` automaticamente; risco registrado.

Estado final: operacional. Pendências principais: login Tailscale, instalação Proton-GE via ProtonUp-Qt, segredos homelab, reinício do Steam Gamepad UI, correções no CLI/doctor.

## Inventário do host

- SO: BigLinux baseado em Manjaro Linux, x86_64.
- Kernel: `6.18.36-1-MANJARO`.
- Hardware: Valve Jupiter/Steam Deck LCD; AMD Custom APU 0405; GPU AMD Van Gogh.
- CPU: 4 núcleos, 8 threads.
- RAM/swap: 14 GiB / 22 GiB.
- Desktop: KDE Plasma, Wayland.
- Root: Btrfs em NVMe de 1 TB; uso final 72%.
- microSD: NTFS, 477,5 GiB, montada em `/mnt/sdcard`; uso final 68%.
- Init: systemd 260.
- Steam Deck: compatível. Perfil `steamdeck-linux` aplicado.
- Homelab: compatível. Pacotes e serviços base aplicados; stacks bloqueadas por segredos.
- RTK: ausente. Modo PhaseZero degradado; comandos executados diretamente.
- ai-memory: instalado, MCP alcançável e serviço de usuário ativo.

## Planos e dry-runs executados

Todos retornaram código 0:

- `linux/pz install safe-base --dry-run`
- `linux/pz install dev-ai --dry-run`
- `linux/pz install gaming --dry-run`
- `linux/pz install emulation-linux --dry-run`
- `linux/pz install steamdeck-linux --dry-run`
- `linux/pz install homelab --dry-run`
- `linux/pz install full-workstation --dry-run`
- Planos Steam Deck: detecção, hotkeys, watcher, controles privilegiados, boot e plugins.
- Planos de emulação: layout, RetroDECK, mídia, atalhos e integrações.
- Planos AI: Hermes, OpenClaw, ai-memory, IDEs e UsageBar.

Lacuna detectada: `full-workstation` produz plano vazio. `linux/lib/common.sh` não resolve `extends`.

## Itens instalados e configurados

### Base e desenvolvimento

- Firefox, UFW, Syncthing, Timeshift, codecs GStreamer/FFmpeg e fontes Noto.
- Node.js, npm, pnpm, Python, pip/pipx, uv, Rust/Cargo, Go, CMake, GCC, Clang, LLDB.
- jq, yq, ripgrep, fd, fzf, bat, eza, zoxide, tmux, Neovim, Git, GitHub CLI, direnv.
- Docker, Docker Compose, PostgreSQL, SQLite, OpenSSH, Tailscale, age, pass.
- Valkey instalado como substituto compatível do pacote Redis removido dos repositórios Arch.
- KeePassXC funcional em `/usr/bin/keepassxc`, fornecido por `bigcontrolcenter-base`.

### Gaming e Steam Deck

- Steam, gamescope, MangoHud, GameMode, Lutris, Heroic, Wine, Winetricks, Protontricks.
- Vulkan AMD 64/32 bits, ryzenadj, CoreCtrl, GOverlay, Discord, OBS Studio.
- Heroic 2.22.0 e `wvkbd` instalados via AUR.
- Maliit e Onboard instalados; teclado virtual KDE configurado.
- Hotkeys Ctrl+Alt+F1..F6 instaladas. Serviço `phasezero-steamdeck-hotkeys` ativo.
- Watcher de modo instalado. Serviço `phasezero-steamdeck-mode-watcher` ativo.
- Modo detectado/aplicado: `docked-tv`.
- Ponte privilegiada TDP/GPU instalada.
- Decky Loader system service ativo e sem conflito de serviço duplo.
- Diretórios Decky corrigidos para escrita do usuário.
- Plugins Decky instalados e saudáveis: PowerTools, CSS Loader, Animation Changer, Audio Loader, ProtonDB, HLTB, SteamGridDB, Storage Cleaner, DeckSettings, Bluetooth, vibrantDeck, EmuDecky, AutoFlatpaks, Ludusavi, Wine Cellar, LSFG-VK e NonSteamLaunchers.
- Temas instalados: PhaseZero SteamOS Plus, Obsidian, Round e Centered-Home.
- `ananicy-cpp` ativado como substituto compatível de `ananicy-git`.
- GameMode, MangoHud, CoreCtrl e regras Ananicy configurados.

### AI, MCPs e IDEs

- Codex CLI 0.142.5.
- Claude Code 2.1.197.
- OpenCode 1.17.7.
- Hermes 0.17.0.
- OpenClaw 2026.6.11; gateway de usuário ativo.
- Ollama 0.30.8; serviço ativo.
- Open WebUI ativo e saudável em container.
- Modelos Ollama existentes: Llama 3.1 e Gemma 3.
- ai-memory 1.5.0; serviço de usuário ativo; MCP em `127.0.0.1:49374/mcp`.
- AI UsageBar 0.8.0 instalado via AUR.
- MCP seguro `ai-memory` sincronizado para OpenCode, Claude, Claude Desktop, Codex global/projeto, VS Code global/projeto, Cursor, Zed, ZCode, Hermes e OpenClaw.
- Seis definições MCP válidas detectadas. Somente padrão seguro instalado automaticamente.
- VS Code, Cursor, Neovim, Zed e ZCode instalados/configurados.
- Shims locais criados: `~/.local/bin/zed` e `~/.local/bin/zcode`.

### Emulação

- EmuDeck, RetroDECK 0.10.9b, ES-DE, SRM, Eden, Citron, Hydra, Ryujinx, DuckStation, PCSX2, RPCS3, Cemu, Azahar, shadPS4, Vita3K e BigPEmu integrados.
- Wrappers e 16 launchers canônicos reparados.
- SRM configurado com 7 parsers gerenciados e diretório de imagens local.
- PS1, PS2 e PS3 configurados. RPCS3: 6 jogos existentes; nenhum PKG/RAP importado.
- Perfis adaptativos Switch/PS3/PS4 instalados.
- LSFG Vulkan pronto; Lossless Scaling detectado.
- RetroArch nativo e Flatpak; ProtonUp-Qt e Protontricks presentes.
- Ludusavi 0.31.0 e BoilR 1.9.6 instalados como Flatpaks de usuário.
- RetroDECK possui acesso Flatpak de usuário a `/home/misael/Emulation`.
- Conteúdo RetroDECK ligado ao root canônico para ROMs, BIOS, saves, states, shaders, screenshots, vídeos, temas, gamelists, collections, cheats, mods, texture packs, firmware, keys e patches.
- Mídia: índice de 516 jogos, 459 itens ignorados e 3.382 arquivos canônicos; 5.138 arquivos em `downloaded_media`.
- Switch scan-safe: 9 de 9 jogos primários.
- Ryujinx aponta para visão scan-safe.
- ES-DE standalone e RetroDECK apontam para ROMs e mídia canônicas.
- BIOS locais existentes: 5.616 arquivos. Switch keys/firmware: 0 arquivos.

### Homelab, serviços e tuning

- Docker, Cockpit, Cockpit Docker/Podman, Netdata, Tailscale, Nginx, Certbot, acme.sh, Restic e Borg instalados.
- Ativos/habilitados: Docker, Ollama, Nginx, Tailscale daemon, Cockpit socket, Netdata, SSH, Bluetooth e Ananicy CPP.
- Serviços de usuário ativos/habilitados: ai-memory, OpenClaw gateway, GameMode, Syncthing, hotkeys e watcher Steam Deck.
- Nenhuma unidade systemd falha.
- `/etc/sysctl.d/99-phasezero-dev.conf` criado.
- Ajustes persistentes: watchers inotify, buffers de rede, BBR/fq, swappiness 10, cache pressure 50, dirty ratios e NMI watchdog desativado.
- Git e npm do usuário configurados pelo perfil dev.

## Itens ignorados ou bloqueados

- Windows/PowerShell: não aplicável no Linux; todos preservados.
- ROMs, BIOS, firmware e keys: nenhum download/import. Exigem dumps próprios do usuário.
- Homelab core/extras: não iniciados. Faltam `VW_ADMIN_TOKEN`, senhas Nextcloud/Grafana, `PAPERLESS_SECRET_KEY` e `N8N_ENCRYPTION_KEY`.
- Homelab extras: porta 9090 do Prometheus conflita com Cockpit; stack deve receber preflight completo antes de subir.
- Proton-GE: pacote `proton-ge-custom-bin` bloqueado por dependências `lib32-gst-plugins-base-libs` e `libsoup`, ausentes nos repositórios atuais.
- `swhkd`: indisponível. `sxhkd` instalado, configurado e ativo.
- `ananicy-git`: nome ausente. `ananicy-cpp` instalado e ativo.
- `redis`: nome removido. Valkey instalado como substituto.
- `codecs`: metapacote ausente. FFmpeg e plugins GStreamer instalados.
- KeePassXC: pacote conflita com arquivo pertencente a `bigcontrolcenter-base`; binário funcional preservado, sem sobrescrita.
- Power Profiles Daemon: pacote instalado, serviço mascarado pelo host BigLinux. Não desmascarado.
- SteamTinkerLaunch: pacote não encontrado; opcional.
- Temas Decky Galactic e Phantom: catálogo desejado, não instalados.
- Steam Big Picture Plus/OpenGamepadUI: fallback Steam Gamepad UI disponível; componente adicional ausente.
- Boot: instalação/aplicação PhaseZero não executada. Entrada já existente foi somente validada.

## Testes executados

### Suites automatizadas

Todas código 0:

- `tests/linux-ai.sh`
- `tests/linux-emulation-performance.sh`
- `tests/linux-shortcuts.sh`
- `tests/linux-steamos-ux.sh`
- `tests/linux-ui.sh`

Também código 0:

- `bash -n` em todos scripts Linux.
- `jq empty` em perfis, MCPs, schema de segredos e ações UI.
- `linux/pz ai doctor`.
- `linux/pz emulation doctor`.
- `linux/pz steamdeck status`.
- `linux/pz ai status`.
- `linux/pz repair-plan`.
- `linux/pz support-bundle`.
- Validação de 22 arquivos `.desktop`; somente hints de categorias múltiplas.
- APIs UI: módulos, ações, token, status global/modular, allowlist, confirmação e autenticação.
- Flatpak info/overrides para RetroDECK, Ludusavi e BoilR.
- Compose `config --quiet` core/extras; código 0 com warnings de segredos ausentes.

### Doctor geral

`linux/pz doctor`:

- 76 PASS, 2 WARN, 1 FAIL, 7 INFO; 86 checks.
- Código de saída incorreto: 0 mesmo com FAIL.
- FAIL Go é falso positivo: doctor chama `go --version`; Go aceita `go version`. Validação direta confirmou `go1.26.4`.
- WARN Tailscale: daemon ativo, usuário deslogado.
- WARN Decky: Steam CEF 8080 fechado enquanto Gamepad UI não está rodando.

### UI/TUI

- Suite HTTP/API passou.
- Dashboard visual abriu shell, CSS e JS no navegador interno, mas permaneceu em `Loading...`; APIs diretas funcionaram. Suspeita: restrição do navegador interno ou falha de bootstrap frontend.
- TUI falha com `TERM=dumb` (código 1). Com `TERM=xterm-256color`, menu renderiza corretamente.

## Falhas e causas prováveis

| Severidade | Comando/componente | Código | Erro principal | Impacto |
|---|---|---:|---|---|
| Alta | Segurança operacional do hook CoreCtrl | 0 | Hook BigLinux executou regeneração GRUB durante instalação do pacote | Mudança automática de `grub.cfg` fora do controle direto do PhaseZero; comando concluiu sem erro |
| Alta | `full-workstation` | 0 | `extends` ignorado por `pz_run_profile` | Perfil agregado aparenta sucesso sem instalar perfis filhos |
| Alta | Runner de pacotes | variável | `set -e` interrompe perfil no primeiro pacote inválido | Viola continuação após falhas não críticas |
| Alta | Doctor | 0 | Retorna sucesso mesmo com checks FAIL | Automação/CI pode aceitar máquina incompleta |
| Média | Proton-GE | 1 interno | Dependências BigLinux não resolvidas | GE-Proton ausente; ProtonUp-Qt disponível |
| Média | ai-memory Docker health | unhealthy | Healthcheck executa `ai-memory status`; multi-user responde 401 sem autenticação | MCP funciona, mas Docker sinaliza falso negativo |
| Média | Dashboard visual | n/a | Shell carrega; estado fica `Loading...` no navegador interno | API/TUI utilizáveis; UX web não confirmada ponta a ponta |
| Média | Homelab | não iniciado | Segredos obrigatórios ausentes | Portainer/Jellyfin/Syncthing/Vaultwarden/Kuma/Nextcloud etc. não implantados |
| Média | Espelho Pacman inicial | 1 | Mirrors inválidos/lentos e falha DNS | Corrigido com `pacman-mirrors --fasttrack 5` e `pacman -Syy` |
| Média | Pacman KeePassXC | 1 | `/usr/bin/keepassxc` pertence a `bigcontrolcenter-base` | Pacote oficial não instalado; aplicativo existente funciona |
| Média | LuaRocks hook | 0 no lote | `/usr/bin/lua5.1` ausente | Hook pós-pacote incompleto; Lua 5.4/5.5/LuaJIT e LuaRocks validados |
| Baixa | CoreCtrl autostart hook | 0 no lote | Desktop source ausente para cópia/chown | CoreCtrl instalado; autostart do hook não criado |
| Baixa | `linux/pz status` | 1 | Comando global não implementado | Usar statuses modulares |
| Baixa | Zed/ZCode | 0 após correção | Pacotes usam `zeditor` e `/opt/ZCode/zcode`; detector procura nomes curtos | Corrigido com shims locais |
| Baixa | Tailscale | 1 | `Logged out` | Serviço ativo, rede privada indisponível até login |
| Baixa | TUI | 1 em `TERM=dumb` | Terminal sem controle de cursor/clear | Funciona em terminal interativo normal |
| Baixa | Desktop files | 0 | `Game;Utility;` contém duas categorias principais | Possível entrada duplicada no menu |

Tentativas adicionais registradas:

- Primeira instalação Flatpak sem `--user/--system`: código 1 por remoto Flathub duplicado. Repetida com `--user`: código 0.
- `bigsudo bash linux/tuning/dev-tweaks.sh`: código 127 porque pkexec não preservou cwd. Repetido com caminho absoluto: código 0.
- Validação `zcode --version`: aplicativo GUI abriu, iniciou auto-update e foi terminado pelo teste; código 143. ZCode 3.2.2 abriu; atualização 3.2.3 ficou baixada em cache, não aplicada.

## Correções aplicadas

- Mirrorlist BigLinux regenerada; bancos Pacman sincronizados.
- Instalação reexecutada sem sobrescrever KeePassXC.
- Valkey instalado no lugar de Redis.
- Ananicy CPP ativado no lugar de `ananicy-git`.
- Tailscale daemon, Cockpit, Netdata, GameMode e Syncthing ativados.
- Sysctl dev/homelab persistido.
- GameMode, MangoHud, CoreCtrl e Ananicy configurados.
- Permissões Decky corrigidas para o usuário.
- Hotkeys, watcher, teclado virtual e plugins Steam Deck reparados.
- Flatpak RetroDECK recebeu acesso ao root canônico.
- Ludusavi e BoilR instalados no escopo do usuário.
- Launchers, SRM, ES-DE, Ryujinx, RetroDECK e mídia canônica reparados.
- Shims Zed/ZCode criados.
- Support bundle copiado para armazenamento persistente.

Nenhuma correção de código-fonte existente foi aplicada: worktree já continha 43 entradas alteradas/não rastreadas. Relatório é único novo artefato do projeto criado nesta etapa.

## Pendências de usuário, sudo ou reboot

Usuário:

- Autenticar Tailscale: `sudo tailscale up`.
- Reiniciar Steam/Gamepad UI para abrir CEF e ativar menu Decky.
- Abrir ProtonUp-Qt e instalar GE-Proton no prefixo Steam.
- Fornecer segredos homelab por secret store ou ambiente; nunca versionar `.env`.
- Revisar atualização ZCode 3.2.3 baixada em cache.
- Fornecer dumps próprios somente se desejar BIOS/keys/firmware.

Sudo:

- Necessário para `tailscale up`.
- Necessário para implantação system-wide do homelab, se escolhida.
- Não necessário para correções restantes de usuário.

Reboot:

- Não exigido pela instalação.
- Logout/relogin opcional para sessão gráfica.
- Reinício do Steam Gamepad UI recomendado; reboot completo dispensável.

## Riscos

- Hook de pacote pode regenerar GRUB sem aviso do PhaseZero. Pacotes com hooks devem ser auditados antes do lote privilegiado.
- AUR: Heroic, wvkbd e AI UsageBar foram compilados/instalados com checksums, mas mensagens indicaram assinaturas PGP de fontes ignoradas.
- Homelab publica várias portas; nunca expor diretamente na WAN. Usar Tailscale/reverse proxy/TLS.
- Vaultwarden com token vazio seria inseguro. Stack corretamente não iniciada.
- `latest` em imagens Compose reduz reprodutibilidade.
- Container ai-memory tem healthcheck falso negativo; monitoramento externo pode reiniciá-lo indevidamente.
- Root Btrfs em 72%; sem urgência, mas stacks e modelos podem consumir espaço rapidamente.
- Worktree extenso e sujo aumenta risco de atribuir mudanças preexistentes a esta instalação.

## Oportunidades priorizadas

### P0

1. Implementar resolução recursiva e deduplicada de `extends` em `pz_run_profile`.
2. Alterar runner de pacotes para registrar falha por pacote e continuar; retornar resumo agregado.
3. Fazer doctor retornar código não zero quando `FAIL` ou `ERROR` existir.
4. Corrigir versão Go no doctor: `go version`, não `go --version`.

### P1

1. Mapear pacotes por distro/capability: Redis→Valkey, ananicy-git→ananicy-cpp, swhkd→sxhkd, codecs→plugins concretos.
2. Adicionar preflight Pacman para detectar conflitos de ownership e dependências quebradas antes da transação.
3. Corrigir healthcheck ai-memory para operação pública/autenticada ou desativá-lo no wrapper Docker.
4. Adicionar preflight homelab: segredos, portas, RAM, bind loopback e confirmação de exposição.
5. Fixar tags/digests das imagens Compose.
6. Adicionar teste visual real do dashboard; capturar erro JS quando bootstrap parar em `Loading...`.
7. Evitar hooks de pacote com efeitos de boot ou mostrar aviso explícito antes do lote.

### P2

1. Detectar executáveis alternativos `zeditor` e `/opt/ZCode/zcode`.
2. Adicionar comando global `linux/pz status` ou removê-lo da expectativa operacional.
3. TUI: detectar `TERM=dumb` e mostrar fallback textual.
4. Ajustar categorias `.desktop`.
5. Tornar Galactic/Phantom opcionais explícitos ou removê-los da lista desejada.
6. Corrigir hook LuaRocks para Lua instalada.

## Comandos recomendados

```bash
# Rede privada; abre fluxo de autenticação.
sudo tailscale up

# Reinicia experiência SteamOS/Decky na sessão atual.
/mnt/sdcard/Projects/PhaseZero/linux/pz steamdeck console

# Instalar GE-Proton via interface segura já instalada.
protonup-qt

# Revalidar módulos.
/mnt/sdcard/Projects/PhaseZero/linux/pz doctor
/mnt/sdcard/Projects/PhaseZero/linux/pz ai doctor
/mnt/sdcard/Projects/PhaseZero/linux/pz emulation doctor
/mnt/sdcard/Projects/PhaseZero/linux/pz steamdeck status

# Validar homelab depois de carregar segredos no ambiente.
docker compose -f /mnt/sdcard/Projects/PhaseZero/assets/home-server/docker-compose.homelab.yml config
docker compose -f /mnt/sdcard/Projects/PhaseZero/assets/home-server/docker-compose.homelab.yml up -d
```

Não executar o último `up -d` antes de definir segredos e revisar exposição de portas.

## Logs e artefatos

- Relatório: `/mnt/sdcard/Projects/PhaseZero/reports/phasezero-linux-install-2026-07-03.md`
- Log PhaseZero: `/home/misael/.local/state/phasezero/pz.log`
- Manifesto PhaseZero: `/home/misael/.local/state/phasezero/manifest.json`
- Backups MCP: `/home/misael/.local/state/phasezero/backups/ai-mcp/`
- Support bundle: `/home/misael/.local/state/phasezero/support/phasezero-support-misael-jupiter-20260702-235707.tar.gz`
- SHA-256 bundle: `6e2ad446b7cd83031fb24bbf270d438095f6ccdc3ab506420ccec2465ed5c694`
- Índice de mídia: `/home/misael/Emulation/media/index/media-index.json`
- Config performance: `/home/misael/.config/phasezero/emulation-performance.json`
- Config ai-memory: `/home/misael/.config/ai-memory/`
- Serviço ai-memory: `/home/misael/.config/systemd/user/ai-memory.service`
- Config sysctl: `/etc/sysctl.d/99-phasezero-dev.conf`
- Config GameMode: `/etc/gamemode.ini`
- Regras Ananicy: `/etc/ananicy.d/99-phasezero.rules`

## Estado final do worktree

- 11 arquivos rastreados modificados, preexistentes.
- 32 entradas não rastreadas, preexistentes antes do relatório, além deste relatório.
- Um arquivo PowerShell rastreado já aparecia modificado: `tests/bootstrap-app-tuning.tests.ps1`.
- Nenhum arquivo Windows editado deliberadamente nesta execução.
- Nenhum commit ou push realizado.
