# Comparação de scripts de jogos/emulação — LinuxToys · EmuDeck · PhaseZero · RetroDECK

> Tabela comparativa de todos os scripts relacionados a jogos/emulação (instalação, preparo,
> pós-configuração, lançamento, ROM/BIOS/saves, nuvem, performance) nos 4 projetos.
>
> Colunas: **Arquivo** · **Projeto** · **Tipo de solução** · **O que faz** · **Resiliência/Robustez/Qualidade**.
> Escala de qualidade: **Low / Medium / High** (com justificativa de 1 linha).

---

## Matriz resumo

| Projeto | Foco | Nº de scripts (aprox.) | Distribuição Low/Med/High | Característica de robustez |
|---|---|---|---|---|
| **LinuxToys** | Launchers de jogos (flatpak/nativo) | 23 | 0 / 7 / 16 | Wrappers finos delegam em `p3/libs/` (idempotente); **sem `set -e`** |
| **EmuDeck** | Backend de emulação (shell) | ~50 | 0 / ~35 / ~15 | Env-var + scripts host; **sem `set -e`**, sem store central de keys |
| **PhaseZero** | Orquestrador cross-platform | ~40 | 0 / ~6 / ~34 | **`set -euo pipefail`**, escritas atômicas, política local-only |
| **RetroDECK** | Framework Flatpak (orquestração) | ~20 runtime | 1 / ~16 / ~3 | Data-driven, sandbox-safe; **sem `set -e`**, `eval`/rm perigosos |

> Observação importante: no RetroDECK o código de instala/config/lançamento *por emulador*
> (Dolphin, PCSX2, RPCS3, Yuzu/Azahar, Cemu, RetroArch, ES-DE, SRM) vive num repo **separado**
> (`RetroDECK/components`), baixado em build e executado com confiança total em runtime.
> Este repo contém só a camada de orquestração.

---

## 1. LinuxToys — `p3/scripts/game/`

Tipo de solução dominante: **shell wrapper** que faz `source` de `p3/libs/` (instaladores
distro-branch, edição de arquivos com `.bak`, systemd, Zenity-aware). Qualidade vem das libs.

| Arquivo | Projeto | Tipo de solução | O que faz | Resiliência/Robustez/Qualidade |
|---|---|---|---|---|
| `p3/scripts/game/faugus.sh` | LinuxToys | Shell wrapper (pkg + flatpak override) | Instala Faugus Launcher (Wine/Proton); aplica overrides Steam flatpak. | **Medium** — delega em `pkg_flat`/`pkg_install` (idempotente, `fatal`-guarded); overrides raw `sudo flatpak override` não-guardados. |
| `p3/scripts/game/gamemode.sh` | LinuxToys | Shell wrapper (pkg, distro-aware) | Instala gamemode (Feral); checa conflito `set-ondemand-governor`. | **High** — script de jogo mais defensivo: conflito via Zenity, `multilib_chk`, idempotente. |
| `p3/scripts/game/gfn.sh` | LinuxToys | Shell wrapper (flatpak + remote) | Instala GeForce NOW flatpak do repo NVIDIA. | **Medium** — cadeia `{ … \|\| sudo … } \|\| fatal` boa; última override não-guardada. |
| `p3/scripts/game/glight.sh` | LinuxToys | Shell wrapper (flatpak) | Instala Greenlight (cliente Moonlight/Sunshine). | **High** — delegação de 1 linha em `pkg_flat`+`zeninf`; idempotente/guardado. |
| `p3/scripts/game/goverlay.sh` | LinuxToys | Shell wrapper (pkg + flatpak layers) | Instala GOverlay + MangoHUD; camadas Vulkan flatpak. | **Medium-High** — pkg guardado; layer install não-guardado mas opcional. |
| `p3/scripts/game/gscope.sh` | LinuxToys | Shell wrapper (pkg, distro-aware) | Instala Gamescope (compositor aninhado Valve). | **Medium** — duplo `sudo_rq` e branching, lógica sã; idempotência via `rpm -qi`. |
| `p3/scripts/game/gsr.sh` | LinuxToys | Shell wrapper (flatpak) | Instala GPU Screen Recorder; plataforma VAAPI se Intel. | **Medium-High** — `\|\| fatal` na plataforma Intel; resto limpo. |
| `p3/scripts/game/hgl.sh` | LinuxToys | Shell wrapper (download versionado + pkg) | Instala Heroic (RPM GitHub/Fedora, AUR/Arch, flatpak demais). | **Medium** — `curl\|grep` frágil a mudanças de API; branches repetem `wget`. |
| `p3/scripts/game/lsfg.sh` | LinuxToys | Shell wrapper (multi-distro complexo) | Instala/atualiza Lossless Scaling (lsfg-vk) frame-gen. | **Medium** — mais envolvido; `find /` por DLL, `sed` injeta path; paths copiados (copy-paste). |
| `p3/scripts/game/lutris.sh` | LinuxToys | Shell wrapper (pkg/flatpak) | Instala Lutris. | **High** — mínimo, guardado, idempotente. |
| `p3/scripts/game/mcbe.sh` | LinuxToys | Shell wrapper (flatpak) | Instala Minecraft Bedrock Launcher. | **High** — delegação trivial. |
| `p3/scripts/game/mgjuice.sh` | LinuxToys | Shell wrapper | Instala MangoJuice (GUI MangoHUD) + MangoHUD. | **Medium-High** — pkg guardado + flatpak. |
| `p3/scripts/game/moonlight.sh` | LinuxToys | Shell wrapper (flatpak) | Instala Moonlight (streaming). | **High** — delegação trivial. |
| `p3/scripts/game/osu.sh` | LinuxToys | Shell wrapper (flatpak) | Instala osu! flatpak. | **High** — delegação trivial. |
| `p3/scripts/game/prism.sh` | LinuxToys | Shell wrapper (flatpak) | Instala Prism Launcher (Minecraft). | **High** — delegação trivial. |
| `p3/scripts/game/protonplus.sh` | LinuxToys | Shell wrapper (flatpak) | Instala ProtonPlus (gerenciador Proton/Wine). | **High** — delegação trivial. |
| `p3/scripts/game/ptricks.sh` | LinuxToys | Shell wrapper (flatpak) | Instala Protontricks. | **High** — delegação trivial. |
| `p3/scripts/game/pup.sh` | LinuxToys | Shell wrapper (flatpak) | Instala ProtonUp-Qt. | **High** — delegação trivial. |
| `p3/scripts/game/sober.sh` | LinuxToys | Shell wrapper (flatpak) | Instala Sober (Roblox, `org.vinegarhq.Sober`). | **High** — trivial; **redundante com `vinegar.sh`**. |
| `p3/scripts/game/steam.sh` | LinuxToys | Shell wrapper (pkg/flatpak, distro-aware) | Instala Steam (nativo Fedora/Arch, flatpak demais). | **High** — branching limpo, guardado, idempotente. |
| `p3/scripts/game/sunshine.sh` | LinuxToys | Shell wrapper (flatpak + driver repo) | Instala Sunshine (servidor de stream) + toolkit NVIDIA. | **Medium** — `curl\|gpg\|tee` não-guardados; typo `libnvidia-container-toolslibnvidia-container1`. |
| `p3/scripts/game/vinegar.sh` | LinuxToys | Shell wrapper (flatpak) | Instala Vinegar (`org.vinegarhq.Sober`). | **High** — trivial; **redundante com `sober.sh`**. |
| `p3/scripts/game/wivrn.sh` | LinuxToys | Shell wrapper (multi-step) | Instala WiVRn (VR streaming); hooks PATH, avahi, overrides. | **Medium-High** — idempotência boa; `prep_create` pode criar dir como root (falha permissão). |

---

## 2. EmuDeck — backend shell

Tipo de solução: **shell scripts orientados a ação** (install/config/update/uninstall por emulador),
launchers, ferramentas de ROM/save/nuvem, e servidor Python. Avaliado em nível de categoria
(inventário do repo); sem `set -e`, sem store central de keys/firmware.

| Arquivo | Projeto | Tipo de solução | O que faz | Resiliência/Robustez/Qualidade |
|---|---|---|---|---|
| `functions/installEmu*.sh` | EmuDeck | Shell installer (por emulador) | Instala emuladores (Yuzu, Ryujinx, Cemu, PCSX2, RPCS3, Dolphin, RetroArch, PPSSPP, etc.). | **Medium** — padrão repetitivo por emulador; poucos guards, paths hard-coded por deck. |
| `functions/configEmu*.sh` | EmuDeck | Shell configurator | Configura emuladores pós-instalação (paths, perfis, parsers). | **Medium** — escreve configs direto; sem rollback; dependede de AppImage/desktop presentes. |
| `functions/updateEmu*.sh` | EmuDeck | Shell updater | Atualiza emuladores (baixa AppImage/versão). | **Medium** — download + substituição; pouco idempotente; sem verificação de checksum consistente. |
| `functions/uninstallEmu*.sh` | EmuDeck | Shell uninstaller | Remove emuladores e artefatos. | **Medium** — `rm` de arquivos/dirs; alguns leftovers de config não limpos. |
| `functions/EmuScripts/` | EmuDeck | Shell scripts utilitários | Scripts variados de setup de emuladores/parsers. | **Medium** — repositório de helpers; qualidade heterogênea. |
| `functions/GenericApplicationsScripts/` | EmuDeck | Shell scripts | Apps genéricas (Steam, dependências, tools). | **Medium** — helpers de app; env-driven. |
| `functions/RemotePlayClientScripts/` | EmuDeck | Shell scripts | Clientes de remote play (Chiaki, Moonlight). | **Medium** — instala/conf clientes; poucos guards. |
| `functions/ToolScripts/` | EmuDeck | Shell scripts | Ferramentas (bios, parsers, SRM helpers). | **Medium** — apoiam SRM/config; qualidade variável. |
| `tools/emu-launch.sh` | EmuDeck | Launcher script | Lança emulador com env/args corretos. | **Medium-High** — ponto de launch central; trata env; sem `set -e`. |
| `tools/proton-launch.sh` | EmuDeck | Launcher script | Lança jogo Windows via Proton. | **Medium-High** — env de Proton; razoável. |
| `tools/launchers/` | EmuDeck | Launcher scripts | Launchers por emulador/plataforma. | **Medium** — um por sistema; repetitivo. |
| `tools/cloudSync` | EmuDeck | Shell sync | Sync de saves/ROMs via nuvem (rclone/etc.). | **Medium** — depende de credenciais externas; frágil a erros de rede. |
| `tools/savesync.sh` | EmuDeck | Shell sync | Sync de saves locais/nuvem. | **Medium** — lógica de sync; poucos guards de conflito. |
| `tools/chdconv` | EmuDeck | Shell converter | Converte ROMs para CHD. | **Medium** — wrapper de `chdman`; sem timeout/verificação estrita. |
| `tools/scrapers` | EmuDeck | Shell/tool | Scraping de metadados/boxart. | **Medium** — depende de APIs externas; sem retry consistente. |
| `tools/retro-library` | EmuDeck | Shell/tool | Gerencia biblioteca retro. | **Medium** — organza biblioteca; qualidade variável. |
| `api.sh` | EmuDeck | Shell API dispatcher | Expõe ações via API para UIs (Decky/Electron). | **Medium-High** — superfície de ação já orientada a UI; sem `set -e`. |
| `functions/RunFunc.sh` | EmuDeck | Shell runner | Executa funções nomeadas por string (ponte UI→backend). | **Medium-High** — core do dispatch; `eval` de nome de função. |
| `tools/server.py` | EmuDeck | Servidor Python | API HTTP/local que aciona funções de backend. | **Medium-High** — já action-oriented p/ Decky; sem auth forte (localhost). |

---

## 3. PhaseZero — `linux/emulation/` (orquestrador)

Tipo de solução: **bash com `set -euo pipefail` + bibliotecas Python** (pipelines scan→plan→apply→
verify→rollback), escritas atômicas, política *local-owned-dump-only*. Mais resiliente dos 4.

| Arquivo | Projeto | Tipo de solução | O que faz | Resiliência/Robustez/Qualidade |
|---|---|---|---|---|
| `linux/pz` | PhaseZero | Bash dispatcher | Roteia `pz emulation <verb>` para scripts em `linux/emulation/`. | **High** — `set -euo pipefail`, routing limpo, `--json` por componente. |
| `linux/emulation/common.sh` | PhaseZero | Bash lib (compartilhada) | Layout `Emulation/`, symlinks, detecção Steam Deck, **política de BIOS/keys local-only**. | **High** — backbone bem fatorado; paths env-overridable; symlink-safe. |
| `linux/emulation/emudeck.sh` | PhaseZero | Bash wrapper/installer | Instala/gerencia EmuDeck (AppImage/.desktop) com validação + retry. | **High** — diferencia deck/pc; `curl --retry 3`; JSON status; backup no overwrite. |
| `linux/emulation/eden.sh` | PhaseZero | Bash wrapper/installer | Instala Eden (Switch); reponta keys/firmware p/ store central. | **High** — limpeza de symlink cuidadosa; store central previne bug de keys. |
| `linux/emulation/citron.sh` | PhaseZero | Bash wrapper/installer | Instala Citron (Switch); mesmo padrão de Eden. | **High** — quase idêntico a Eden (duplicação DRI, mas correto). |
| `linux/emulation/hydra.sh` | PhaseZero | Bash configurator | Instala Hydra; policy `user-owned-games-only`; config clássica. | **High** — pula escrita se Hydra rodando; backup de configs. |
| `linux/emulation/srm.sh` | PhaseZero | Bash + jq configurator | Configura Steam ROM Manager reusando templates do EmuDeck. | **High** — reusa parsers upstream; idempotente; `--skip-if-configured`. |
| `linux/emulation/sony.sh` | PhaseZero | Bash INI configurator | PS1 (DuckStation)/PS2 (PCSX2): paths BIOS/save via `ini_set`. | **High** — import local-only enforced; dedup em status. |
| `linux/emulation/ps3.sh` | PhaseZero | Bash + python importer | PS3/RPCS3: import local-only de dumps; wrapper + ES-DE block. | **High** — gating local-only em todo import; backups não-destrutivos. |
| `linux/emulation/retrodeck.sh` | PhaseZero | Bash orchestrator | Ponte fina p/ `shared-content.sh`/`media.sh` (RetroDECK). | **High** — pura delegação; baixo risco. |
| `linux/emulation/shared-content.sh` | PhaseZero | Bash migration manager | Link/migra ~22 classes de conteúdo entre PhaseZero e RetroDECK. | **High** — journal de reversão; não clobbera; idempotente. |
| `linux/emulation/media.sh` + `media-index.py`/`media-gamelist.py` | PhaseZero | Bash + Python | Boxart/screenshots; detecta órfãos; patch XML ES-DE. | **High** — `media-index.py` determinístico; orphan-clean move p/ backup (seguro). |
| `linux/emulation/shortcuts.sh` | PhaseZero | Bash desktop generator | Gera `.desktop` p/ ~16 emuladores/frontends. | **High** — table-driven; descoberta multi-candidato; idempotente. |
| `linux/emulation/frontends.sh` + `frontends.py` | PhaseZero | Bash + Python | Roteamento de frontends (Big Box, ES-DE, Steam, etc.). | **High** — separação shell/Python; escritas JSON atômicas. |
| `linux/emulation/launchbox.sh` + `.py`/`_import.py` | PhaseZero | Bash Wine + Python | Integra LaunchBox/Big Box via Wine. | **Medium-High** — Wine robusto (timeout, quarantine `.broken`); fluxo Wine inerentemente frágil. |
| `linux/emulation/heroic.sh` + `heroic.py` | PhaseZero | Bash + Python | Ajusta Heroic; higiene de menu KDE. | **High** — aborta se Heroic rodando; JSON safe. |
| `linux/emulation/controllers.sh` | PhaseZero | Bash input aligner | Alinha perfis de input (Ryujinx/RPCS3) c/ Steam Input. | **High** — backups; atomic jq; recusa sintetizar GUID. |
| `linux/emulation/dualscreen.sh` | PhaseZero | Bash KWin-rules | Roteia emuladores dual-window p/ 2 telas (Desktop Mode). | **High** — reasoning sólido (Wayland vs gamescope); fallbacks. |
| `linux/emulation/performance.sh` + `performance-launch.sh` | PhaseZero | Bash profile/runtime | Perfis adaptativos (gamemode, MANGOHUD, TDP, LSFG). | **High** — injeção de env segura; `PZ_EMULATION_LSFG_STRICT` p/ hard-fail. |
| `linux/emulation/nsz.sh` | PhaseZero | Bash + venv/Python | Conversão NSZ→NSP atômica e verificada. | **High** — locks, staging, reserva de espaço, SHA-256, quarantine. |
| `linux/emulation/bios.sh` | PhaseZero | Bash importer | Import local-only de BIOS/keys/firmware; store central. | **High** — single-source-of-truth; recusa fontes remotas. |
| `linux/emulation/lua.sh` / `steam-tools.sh` | PhaseZero | Bash status/install | Lua p/ launchers; inventário de ferramentas Steam. | **Medium-High** — `pz_can_sudo_noninteractive`; JSON status. |
| `linux/emulation/setup-emulation.sh` | PhaseZero | Bash orchestrator | Instala emulação em sequência (dry-run/plan). | **High** — sequência declarativa; `set -e` propaga parada segura. |
| `linux/emulation/optimizers.sh` (+`optimizers/*.sh`) | PhaseZero | Bash table-driven | Aplica settings por-jogo documentados. | **Medium-High** — dispatch simples; baixo risco. |
| `linux/emulation/fixes.sh` | PhaseZero | Bash safe-fix catalog | Catálogo de reparos não-destrutivos. | **High** — todos `destructive:false`; `\|\| true`. |
| `linux/emulation/pc-games.sh` + `pc-games.py` | PhaseZero | Bash + Python | Descobre PC games locais p/ frontends. | **Medium-High** — exclusões/norm cuidadosas; `GENERATED_MARKER`. |
| `linux/emulation/library/*` (Python pkg) | PhaseZero | Python pipeline | Scan→plan→apply→verify→rollback de biblioteca ROM. | **High** — recusa symlinks; perms seguras; validação anti-traversal. |
| `linux/emulation/romopt/*` (Python pkg) | PhaseZero | Python pipeline | Detect→convert→verify→clean/rename de ROMs. | **High** — timeouts SIGKILL; verificação padrão; anti-zip-bomb. |

---

## 4. RetroDECK — framework (repo `retrodeck/retrodeck`)

Tipo de solução: **orquestração Flatpak data-driven** (sandbox; symlink indirection; edição de config
format-aware; API IPC + Zenity). **Sem `set -e`**; `eval`/`rm` perigosos; cloud_sync é stub vazio.

| Arquivo | Projeto | Tipo de solução | O que faz | Resiliência/Robustez/Qualidade |
|---|---|---|---|---|
| `functions/retrodeck.sh` | RetroDECK | Bash CLI dispatcher | CLI `flatpak run net.retrodeck.retrodeck …`; detecta update. | **Medium** — validação boa; `shift 2` incondicional pode falhar. |
| `functions/global.sh` | RetroDECK | Bootstrap/source hub | Sobe logging, detecta HW (sysfs/DRM), carrega todo `functions/*.sh`. | **Medium-High** — sandbox-aware; glob-source auto-executa qualquer arquivo dropado. |
| `functions/all_vars.sh` | RetroDECK | Constants header | Paths/URLs/versão constantes. | **High** — centralizado; paths hard-coded (`/app`, `/run/media/mmcblk0p1`). |
| `functions/framework.sh` | RetroDECK | Bash config-engine | `set/get_setting_value` p/ ~15 sintaxes; patch system; `prepare_component`. | **Medium** — edição in-place idempotente; sed/jq densos; delimitador `^` quebra valores. |
| `functions/other_functions.sh` | RetroDECK | Bash lib/installer | `finit`, `dir_prep`, backup 3-gerações, self-update, `repair_paths`. | **Medium** — backup/SHA no self-update; `mkdir` não-guardado; `rm -rf /var` no fresh-install. |
| `functions/checks.sh` | RetroDECK | Bash checks | Rede, desktop mode, Steam Deck (DMI), versão. | **Medium** — fallbacks OK; `check_for_version_update` parcialmente comentado/TODO. |
| `functions/compression.sh` | RetroDECK | ROM compressor | CHD/zip/rvz com `flock`, skip já-comprimido. | **Medium-High** — thread-safe, idempotente; `read -p` não-headless. |
| `functions/multi_user.sh` | RetroDECK | Save-sync local | Isola saves/config por usuário Steam (symlinks). | **Medium** — backup antes overwrite; bug `SteamAppUser="$?"` pega exit code. |
| `functions/presets.sh` | RetroDECK | Config-generator | Presets (bordas, widescreen, rewind, cheevos) data-driven. | **Medium-High** — manifest-driven; `eval` de valores (injeção se manifest não confiável). |
| `functions/run_game.sh` | RetroDECK | Launcher/cmd-builder | Resolve sistema/emulador e `eval "$final_command"`. | **Medium** — descoberta robusta; `eval` é vetor de injeção. |
| `functions/convert_cfg_to_json.sh` | RetroDECK | Config converter | Migra `retrodeck.cfg` INI→JSON. | **High** — **único** com `set -euo pipefail` local; idempotente. |
| `functions/post_update.sh` | RetroDECK | Upgrade/migration | Orquestra update de componentes pós-upgrade. | **Medium** — passos ordenados; source de componentes sem verificação de integridade. |
| `functions/post_build_check.sh` | RetroDECK | Smoke test | Valida launch de emuladores (timeout 3s). | **Medium** — útil; `//` no jq; não valida emulação real. |
| `functions/configurator_functions.sh` | RetroDECK | Validation helper | Escaneia estrutura de pastas multi-arquivo. | **Medium** — `find` repetido (ineficiente, não incorreto). |
| `functions/dialogs.sh` + `zenity_processing.sh` | RetroDECK | UI/dialog lib | Todos os diálogos do configurador Zenity. | **Medium** — bem organizado; delega trabalho real p/ framework. |
| `functions/logger.sh` | RetroDECK | Logging lib | `log` (debug/info/warn/error) + rotação. | **High** — autocontido, level-gated, rotação. |
| `functions/api_server.sh` + `api_data_processing.sh` | RetroDECK | Control API (IPC) | API JSON sobre pipe/socket p/ GUI Godot. | **Medium-High** — `flock`; reusa framework; poucos guards em opers poderosas. |
| `functions/cloud_sync.sh` | RetroDECK | **Stub vazio** | (sem implementação, sem callers) | **Low** — arquivo de 2 linhas; nenhum sync de nuvem real no repo. |
| `tools/configurator.sh` | RetroDECK | GUI launcher | Entrada Zenity + árvore de diálogos. | **Medium** — árvore limpa; mesmas ressalvas de global-state. |
| `tools/retrodeck_function_wrapper.sh` | RetroDECK | Thin wrapper | Chama função nomeada por string. | **Low-Medium** — marcado TODO; largamente obsoleto. |

### Ferramentas de build/cooker (fora do runtime, listadas por completude)
`retrodeck_builder.sh` (Flatpak builder; `eval $command`, `curl|bash`), `automation_tools/fetch_components.sh`
(download+SHA dos components), `automation_tools/install_components.sh`, `automation_tools/flathub_push.sh`,
`automation_tools/search_missing_libs.sh`, `developer_toolbox/*` (lint/manifest/JSON, hooks).
Qualidade geral **Medium** — SHA no download, mas `curl|bash` e sem checksum em extract.

---

## Callouts transversais

- **LinuxToys**: `sober.sh` e `vinegar.sh` instalam o **mesmo** flatpak (redundantes). Repo **não usa `set -e`**;
  segurança vem das `p3/libs/` (idempotência, `.bak`, `fatal`). Scripts não rodam standalone (precisam `SCRIPT_DIR`).
- **EmuDeck**: **sem store central de keys/firmware**; cada emulador gerencia o próprio. Scripts host, **sem `set -e`**.
  `api.sh`/`RunFunc.sh`/`server.py` já são a ponte orientada a ação para Decky/Electron.
- **PhaseZero**: **autocontido** — não chama LinuxToys (apenas "inspirado", reimplementado). Integra EmuDeck/Eden/Citron/
  Hydra/SRM/RetroDECK mas impõe: `set -euo pipefail`, escritas atômicas, **store central de keys/firmware**, e política
  **local-owned-dump-only** (bloqueia BIOS/firmware/keys/ROM remotos). Mais resiliente dos 4.
- **RetroDECK**: só o **framework** está neste repo; lógica por-emulador está em `RetroDECK/components` (baixado em build,
  confiado em runtime). **Sem `set -e`**; `eval` em `run_game.sh`/`presets.sh`; `rm -rf /var` no fresh-install (5 confirmações);
  `cloud_sync.sh` é stub vazio. Sandbox Flatpak obriga symlink indirection (`dir_prep`) — frágil porém necessário.

## Como os 4 se diferenciam no mesmo objetivo

| Dimensão | LinuxToys | EmuDeck | PhaseZero | RetroDECK |
|---|---|---|---|---|
| Modelo | Launchers de jogos (flatpak/nativo) | Backend de emulação host | Orquestrador cross-platform | Plataforma Flatpak |
| Error handling | Libs guardam; sem `set -e` | Sem `set -e` | `set -euo pipefail` | Sem `set -e` |
| Store de keys/firmware | N/A | Por emulador | Central + local-only | Symlink p/ `retrodeck/` |
| Reusabilidade de parsers | — | Templates SRM | Reusa templates SRM/EmuDeck | ES-DE + componentes próprios |
| CLI/JSON scriptável | Não (GUI Zenity) | `api.sh`/`server.py` | `pz emulation … --json` | API IPC + Zenity |
| Resiliência geral | Medium-High (delegação) | Medium | **High** | Medium (framework) |
