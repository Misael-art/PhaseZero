# PhaseZero SteamOS Boot + Hydra Linux Plan

## Objetivo

Criar uma jornada simples para o host Linux iniciar em modo console estilo SteamOS e expor Hydra dentro da experiencia Steam/Gamepad UI.

## Decisao tecnica

GRUB nao inicia aplicativo; GRUB escolhe kernel/cmdline. A implementacao correta e adicionar uma entrada GRUB que inicializa o mesmo Linux com `phasezero.steamos=1`.

No boot com essa flag, um servico systemd antes do SDDM escreve uma configuracao SDDM gerenciada para autologin na sessao `gamescope-session-steam-plus.desktop`. Em boot normal, o mesmo servico remove essa configuracao. Resultado: boot normal preservado; boot SteamOS vira opt-in no menu.

## Componentes

- `linux/steamdeck/install-steamos-boot.sh`: instala helper, service e `/etc/grub.d/42_phasezero_steamos`.
- `linux/steamdeck/steamos-boot-prepare.sh`: aplica/remove SDDM autologin conforme `/proc/cmdline`.
- `linux/pz steamdeck boot status|dry-run|install|remove`: interface CLI.
- `linux/emulation/hydra.sh`: instala Hydra AppImage oficial, wrappers, desktop, Steam shortcut, flags Hydra Classic e mapas DuckStation/PCSX2/RPCS3.
- `linux/emulation/steam-shortcut.py`: adiciona atalho Steam com backup de `shortcuts.vdf`.
- `linux/emulation/srm.sh`: configura Steam ROM Manager AppImage/`steamrommanager.sh`, `steamDirectory`, `romsDirectory`, `retroarchPath` e parsers gerenciados.
- `linux/emulation/ps3.sh`: importa conteúdo PS3 local-only, configura RPCS3 VFS e instala firmware/PKG via RPCS3 quando possível.
- `linux/emulation/lua.sh`: audita/instala Lua, Lua 5.4, LuaJIT e LuaRocks.
- `linux/emulation/steam-tools.sh`: audita Protontricks, ProtonUp-Qt, RetroArch, Ludusavi, BoilR, SRM e SteamTinkerLaunch.
- `linux/emulation/fixes.sh`: lista e aplica reparos seguros de emulacao.

## Guardrails

- Sem mutacao GRUB sem sudo explicito.
- Sem tocar Windows.
- Sem fontes Hydra de repack/torrent/crack/bypass.
- BIOS, firmware, keys e ROMs continuam `local-user-owned-import-only`.

## Estado

- Hydra AppImage restaurado em `/home/misael/Applications/Hydra.AppImage`.
- Hydra launcher desktop, wrapper SteamOS, policy e atalho Steam instalados.
- Hydra Classic config escrita em `~/.config/hydralauncher/config.json`.
- Hydra emulator mappings escritos em `~/.config/hydralauncher/emulators_config.json` com 3 sistemas detectados: DuckStation, PCSX2-Qt e RPCS3.
- Steam ROM Manager configurado em `~/.config/steam-rom-manager/userData` com Steam local, ROMs em `~/Emulation/roms` e 6 parsers gerenciados.
- RPCS3 VFS configurado para `/dev_hdd0/` em `~/Emulation/storage/rpcs3/dev_hdd0/` e `/games/` em `~/Emulation/roms/ps3/`; doctor `EMU11 PASS`.
- EmuDeck, Eden e Citron integrados; Eden/Citron reportam `emudeckIntegrated=true`.
- GRUB SteamOS Console instalado e doctor reporta `BOOT01 PASS`.
- `luarocks`, `protontricks` e `protonup-qt` instalados no host e doctor reporta PASS.
- Conteudo restrito continua local-only: Switch keys/firmware/ROMs nao sao baixados.
