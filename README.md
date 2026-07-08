# PhaseZero

PhaseZero e um instalador e auditor Windows para pos-instalacao segura. O alvo minimo e maquina Windows limpa com Windows PowerShell 5.1. O projeto deve explicar escopo, escrever `result.json`, preservar logs e falhar com diagnostico acionavel.

## Principios de Produto

- Dry-run antes de mutacao real.
- Perfil default pequeno e seguro: `safe-base`.
- Perfil amplo somente por opt-in: `full-workstation`.
- Componentes isolados nao herdam perfil, HostHealth ou AppTuning por acidente.
- UI e CLI compartilham contrato de execucao, logs e resultado.
- Falha sem `result.json` e tratada como erro do produto.
- Reboot pendente bloqueia fluxos winget/MSI arriscados antes de mutar.
- Rollback e aplicado onde ha manifest seguro; apps instalados por terceiros podem exigir remocao manual.

## Requisitos

- Windows 10/11.
- Windows PowerShell 5.1.
- Sessao interativa para a UI WPF.
- Internet para bootstrap de App Installer/winget e pacotes online.
- Pester 3.4.0 para rodar a suite local. `tests\run-pester.ps1` detecta a versao exata e tenta instalar em `CurrentUser` quando ausente; use `-NoInstall` para bloquear rede/mutacao e receber erro instrutivo.

Sem winget em maquina limpa, o bootstrap tenta caminho seguro de App Installer oficial (`https://aka.ms/getwinget`) quando aplicavel. Se PATH/sessao ainda nao enxergar winget depois do bootstrap, a UI/CLI devem orientar logoff, nova sessao ou reboot em vez de falhar de modo opaco.

### Linux (expansao aditiva)

A trilha Linux fica isolada em `linux/pz` e usa perfis `profiles/*.json`. Ela nao substitui os fluxos Windows.

#### Instalar o Control Center nativo

A [pagina de Releases](https://github.com/Misael-art/PhaseZero/releases/latest) publica o app nativo Qt6/PySide6 (`phasezero-control-center`) em cinco formatos, gerados e verificados a partir do mesmo `packaging/linux/`:

| Formato | Comando |
|---|---|
| Arch/BigLinux/Manjaro (pacman) | `sudo pacman -U phasezero-control-center-*.pkg.tar` |
| Debian/Ubuntu (.deb) | `sudo apt install ./phasezero-control-center_*_all.deb` |
| Fedora/openSUSE (.rpm) | `sudo dnf install ./phasezero-control-center-*.noarch.rpm` |
| Universal (AppImage) | `chmod +x PhaseZero-*.AppImage && ./PhaseZero-*.AppImage` |
| Flatpak | `flatpak install --user PhaseZero-*.flatpak` |
| AUR | pacote `phasezero-control-center` (`.SRCINFO`/`PKGBUILD` em `packaging/linux/aur/`) |

`SHA256SUMS-<versao>` acompanha cada release; confira com `sha256sum -c`. O pacote instala `phasezero-control-center` (binario) e um atalho de desktop (`io.phasezero.ControlCenter.desktop`); a UI so chama `linux/pz` com argumentos de um catalogo allowlisted, nunca implementa instalacao ou mutacao por conta propria. Detalhes de empacotamento e build local em [`linux/ui_native/README.md`](linux/ui_native/README.md).

Para a trilha CLI completa (perfis, Steam Deck, VM, emulacao, servidor caseiro) sem instalar pacote, use um checkout do repositorio e chame `linux/pz` diretamente:

```bash
linux/pz help
linux/pz ui                        # Central de Controle nativa Qt6
linux/pz ui web                    # Dashboard web legado
linux/pz install safe-base
linux/pz install steamdeck-linux
linux/pz steamdeck detect
linux/pz steamdeck hotkeys dry-run
linux/pz steamdeck keyboard
linux/pz steamdeck console
linux/pz steamdeck boot dry-run
linux/pz steamdeck conveniences install
linux/pz windows-vm plan --iso /path/to/Win11.iso
linux/pz windows-vm discover
sudo linux/windows-vm/windows-vm.sh adopt --disk /var/lib/libvirt/images/win11.qcow2
linux/pz windows-vm install --iso /path/to/Win11.iso
linux/pz windows-vm optimize --dry-run
linux/pz windows-vm launch --fullscreen
linux/pz windows-vm boot dry-run
linux/pz install waydroid-linux --dry-run
linux/pz waydroid status
linux/pz waydroid install
linux/pz waydroid repair --init
linux/pz waydroid launch
linux/pz waydroid boot dry-run
linux/pz emulation setup
linux/pz emulation eden install
linux/pz emulation hydra install
linux/pz emulation hydra configure
linux/pz emulation srm configure
linux/pz emulation controllers apply     # perfil de gamepad Steam Deck (Ryujinx/RPCS3)
linux/pz emulation media apply           # unifica midia canonica (inclui RetroArch flatpak)
linux/pz emulation optimizer plan
linux/pz emulation optimizer apply-all
linux/pz emulation ps3 import-game /path/to/local/ps3-dump
linux/pz emulation ps3 import-pkg /path/to/local/pkg
linux/pz emulation ps3 import-rap /path/to/local/rap
linux/pz emulation lua status
linux/pz emulation steam-tools status
linux/pz emulation fixes list
linux/pz emulation bios import /path/to/local/bios-dump
linux/pz emulation nsz install
linux/pz emulation nsz plan /path/to/local/nsz
linux/pz emulation nsz convert /path/to/local/nsz
linux/pz emulation nsz convert /path/to/local/nsz --delete-source --yes
linux/pz emulation nsz apply --yes
linux/pz ai opencode free-model          # corrige "Interrompido" com modelo free (deepseek-flash)
linux/pz ai proxies plan all
linux/pz ai proxies install all
linux/pz ai proxies configure-ides       # opencode/opencode-desktop/zcode
linux/pz ai proxies test                 # probe honesto /v1/models + chat
linux/pz windows-vm host-access status   # host -> disco da VM (guestmount)
linux/pz waydroid host-access link       # host -> armazenamento interno do Waydroid
linux/pz server status
linux/pz install server-llm              # LLM local (Ollama) + boot enxuto reversivel
linux/pz install server-homelab          # Docker/Tailscale: drive, midia, cofre, monitor
linux/pz install server-llm-homelab-hermes
linux/pz server homelab plan                          # blockers e proximos passos, sem alterar nada
linux/pz server homelab repair --access local          # gera .env seguro (segredos aleatorios, chmod 600)
linux/pz server homelab up --access local              # sobe core (Portainer/Jellyfin/Syncthing/Vaultwarden/Uptime Kuma)
linux/pz server homelab up --extras --access tailscale  # + Nextcloud/Grafana/Prometheus/Paperless/n8n via Tailscale
linux/pz server homelab open jellyfin                   # resolve e abre a URL do app
linux/pz server homelab logs vaultwarden --follow
linux/pz server homelab backup --extras                 # tar.gz por volume nomeado
linux/pz server homelab restore --source PATH --yes
linux/pz server homelab update                          # backup automatico + pull (tags fixadas) + up
linux/pz server casaos plan                             # gate de compatibilidade (Debian/Ubuntu/RPi OS); Arch/SteamOS fica bloqueado
sudo linux/pz server boot install --llm --homelab   # entrada GRUB Homelab headless
```

`steamdeck-linux` e opt-in. O foco inicial e experiencia estilo SteamOS: Steam Gamepad UI, atalhos `Ctrl+Alt+F1..F6`, teclado virtual por Steam/wvkbd/onboard/maliit, watcher de modo com debounce e tuning de jogos.

`windows-vm-linux` e opt-in. Automatiza VM Windows em QEMU/KVM a partir de uma ISO indicada pelo usuario. Antes de criar disco novo, detecta dominios Windows em `qemu:///system` e imagens instaladas; dominio libvirt existente vira default, preservando snapshot, firmware e hardware virtual originais. Sem dominio, usa QEMU direto com CPU `host`, KVM, OVMF, TPM 2.0, audio, SPICE USB redirection, SMB e virtiofs. Compartilhamento host->guest: `HOME` e `/mnt/sdcard` sao bind-montados (nao symlinks, que o smbd embutido do QEMU nao atravessa) sob `RUNTIME_DIR` e expostos no SMB embutido do SLIRP em `\\10.0.2.4\qemu` (pastas `home/` e `sdcard/`); virtiofs continua expondo `HOME`. O acesso reverso guest->host usa `pz windows-vm host-access` (monta o disco da VM via libguestfs com a VM desligada). Quatro canais USB cobrem pendrives, perifericos e leitores smartcard USB.

`waydroid-linux` e opt-in. Automatiza Waydroid como Android em container no host Linux, com detecao de binder, servico `waydroid-container`, compositor kiosk Wayland (`cage` preferido, `kwin_wayland` fallback), launchers do usuario e boot direto via GRUB/SDDM. `repair --init` baixa sistema/vendor por mirrors SourceForge com retry, valida tamanho e SHA-256, prepara runtime e inicializa Android; sem `--init`, nao baixa imagens.

`emulation-linux` e opt-in. Instala launchers do EmuDeck/Eden/Citron/Hydra, configura Hydra Classic e Steam ROM Manager com emuladores detectados, prepara Lua/LuaJIT, audita Steam helper tools e cria layout compartilhado `~/Emulation`. Em Steam Deck real (DMI Valve/Jupiter/Galileo/Sephiroth), EmuDeck usa o `EmuDeck.desktop` do desktop do usuario e PhaseZero cria um wrapper que chama esse launcher; em PC Linux generico, usa o AppImage direto. BIOS, firmware, keys, ROMs, updates e DLC nao sao baixados: use importacao local de dumps proprios. O Steam ROM Manager resolve `${romsdirglobal}`, `${steamdirglobal}`, `${retroarchpath}` e `${racores}` pelas variaveis de ambiente das Settings (`raCoresDirectory` aponta para os cores do RetroArch, senao "Test/Parse" falha com "invalid configuration"). `pz emulation controllers apply` aplica o perfil de gamepad Steam Deck (Ryujinx/RPCS3 via Steam Input), `pz emulation media apply` unifica a midia canonica inclusive para RetroArch flatpak, e o BigBox roda com aceleracao de hardware (DXVK) em vez de renderizacao por software.

Servidor caseiro (opt-in). Seis perfis compoem LLM local, homelab e Hermes: `server-llm` (Ollama + boot enxuto reversivel), `server-homelab` (Docker/Tailscale com drive/midia/cofre/monitor), `server-homelab-hermes`, `server-llm-hermes`, `server-llm-homelab` e `server-llm-homelab-hermes`. `pz server (status|llm|homelab|casaos|hermes|slim|boot)` gerencia os componentes. `sudo pz server boot install --llm --homelab` cria a entrada GRUB `PhaseZero Homelab (headless)`, que inicia o Linux em `multi-user.target` com `phasezero.homelab=1` (SO enxuto reversivel — o boot normal fica intacto); um oneshot sobe Ollama, a stack Docker e o Hermes conforme `/etc/phasezero/server-mode.env`. O enxugamento permanente e opt-in e reversivel via `pz server slim (apply|restore)`.

`pz server homelab` cobre o ciclo de vida completo do stack Docker Compose (Portainer, Jellyfin, Syncthing, Vaultwarden, Uptime Kuma no core; Nextcloud, Grafana, Prometheus, Paperless e n8n como extras opt-in). `status`/`plan` retornam JSON estruturado com Docker, Tailscale, modo de acesso, segredos (presenca, nunca o valor), apps (URL/bind/estado/volumes), `blockers` e `nextSteps`. `repair`/`up` geram um `.env` local seguro (`chmod 600`, fora do git) com segredos aleatorios para Vaultwarden/Nextcloud/Grafana/Paperless/n8n; sem segredo obrigatorio presente, o servico correspondente fica listado em `blockers` e nao sobe. O acesso e sempre explicito via `--access local|tailscale|lan`: `local` (padrao) fixa tudo em `127.0.0.1`; `tailscale` expoe apps sensiveis apenas no IP Tailscale e e bloqueado se a conta estiver deslogada; `lan` e opt-in (`0.0.0.0`) para a rede local. Nenhuma porta fica aberta para a WAN por padrao. Imagens Docker sao fixadas por tag (sem `:latest`, override via `PZ_IMAGE_*`). `open <app>` resolve a URL respeitando o bind atual; `logs <app>`, `backup`/`restore --source PATH --yes` (tar.gz por volume nomeado) e `update` (backup automatico antes de `pull`/`up`) completam o ciclo. `pz server casaos (status|plan|install)` e um gate de compatibilidade para CasaOS real: detecta distro/arquitetura, bloqueia Arch/SteamOS/BigLinux/Manjaro, e mesmo em host compativel (Debian/Ubuntu/Raspberry Pi OS) a instalacao exige `--yes` explicito — o caminho padrao do PhaseZero continua sendo a stack Docker Compose + Portainer acima.

IA e agentes no Linux: `pz ai opencode free-model` corrige o "Interrompido" do OpenCode (CLI e desktop) definindo um modelo free keyless do OpenCode Zen (`deepseek-v4-flash-free`) como padrao, mantendo o Ollama como provider offline. `pz ai proxies configure-ides` conecta os proxies pedrofariasx (kimi/qwen/deeps/mimo, portas 3010-3013) ao opencode, opencode-desktop e zcode; o chat via proxy exige um `npm run login` unico por proxy (mesma trava do Windows). Caverman, RTK, ai-memory e Headroom sao suportados e configurados (`pz ai compat status`). A Central de Controle nativa (Qt6/PySide6, `pz ui`) foi redesenhada no estilo EmuDeck: dashboard "Welcome back" com cards de acao, sidebar agrupada, badges de estado por cor, tema escuro roxo e toasts de conclusao.

Conversao NSZ para NSP usa `nsz==4.6.1` isolado. Processamento sequencial reduz pico de disco. Saida nasce em staging no mesmo filesystem, passa por verificacao upstream, cabecalho PFS0 e SHA-256, depois recebe publicacao atomica em `~/Emulation/roms/switch/nsp`. Fonte permanece por padrao. `--delete-source --yes` remove cada NSZ somente depois da verificacao e registro JSON em `~/Emulation/metadata/switch/nsz-conversions`. `apply --yes` normaliza sufixos de tamanho, confirma duplicatas por SHA-256, remove apenas copias identicas e converte toda a biblioteca sob lock exclusivo. Conflitos permanecem intactos. Somente dumps locais proprios.

Boot direto estilo SteamOS:

```bash
linux/pz steamdeck boot dry-run
sudo linux/steamdeck/install-steamos-boot.sh install
sudo linux/pz boot install-safe-menu
linux/pz boot menu
sudo linux/pz boot choose steamos --reboot
```

Isso adiciona uma entrada GRUB `PhaseZero SteamOS Console`. Ela inicializa o mesmo Linux com `phasezero.steamos=1`; um servico antes do SDDM seleciona `phasezero-steamos.desktop`. Ao escolher Desktop na Steam, o hook `steamos-session-select` encerra gamescope e inicia Plasma na mesma sessao, sem novo login. `linux/pz boot install-safe-menu` deixa o menu GRUB visivel com timeout seguro, sem alterar input/video global. As entradas PhaseZero usam IDs estaveis e hotkeys de teclado (`s`, `w`, `a`, `e`), mas D-pad/analogico do Steam Deck em GRUB depende de firmware e nao e confiavel. Prefira `linux/pz boot menu` ou launchers one-shot no Linux antes de reiniciar.

Boot direto Windows VM:

```bash
linux/pz windows-vm install --iso /path/to/Win11.iso
linux/pz windows-vm discover
sudo linux/windows-vm/windows-vm.sh adopt --disk /path/to/existing/windows.qcow2
linux/pz windows-vm launch --dry-run
sudo linux/windows-vm/windows-vm.sh boot install
sudo linux/windows-vm/windows-vm.sh boot next-reboot
```

Isso adiciona uma entrada GRUB `PhaseZero Windows VM`. Ela inicializa o mesmo Linux com `phasezero.windowsvm=1`; um servico antes do SDDM seleciona `phasezero-windows-vm.desktop`, que inicia o dominio libvirt descoberto ou o QEMU direto em tela cheia. Saida fica em `~/.local/state/phasezero/windows-vm/session.log`; falha retorna ao Plasma. Em QEMU direto, use `\\10.0.2.4\qemu`. Em dominio libvirt, SPICE WebDAV usa o mesmo diretorio de links.

Se `discover` encontrar uma instalacao existente sem leitura para o usuario, `adopt` aplica ACL/chmod quando executado com root e grava essa imagem como default. Sem instalacao existente legivel, `install --iso` cria o qcow2 novo e segue o fluxo normal.

Boot direto Waydroid:

```bash
linux/pz waydroid install
linux/pz waydroid repair --init
sudo linux/waydroid/waydroid.sh boot install
sudo linux/waydroid/waydroid.sh boot next-reboot
```

Isso adiciona uma entrada GRUB `PhaseZero Waydroid`. Ela inicializa o mesmo Linux com `phasezero.waydroid=1`; um servico antes do SDDM aplica tuning, prepara binder, inicia `waydroid-container` e seleciona a sessao `phasezero-waydroid.desktop` sem login manual. A sessao abre Waydroid em modo kiosk e tenta reiniciar a UI algumas vezes antes de cair para o desktop. Boot normal remove a configuracao SDDM gerenciada.

Hydra:

```bash
linux/pz emulation hydra install
linux/pz emulation hydra configure
linux/pz emulation hydra steam-shortcut
```

Hydra entra como AppImage local, launcher desktop, atalho Steam, flags Hydra Classic e `emulators_config.json` para DuckStation/PCSX2/RPCS3 quando detectados. PhaseZero nao configura fontes de download, repacks, torrents, cracks ou bypasses; integra apenas biblioteca/launcher para jogos do usuario.

Steam ROM Manager:

```bash
linux/pz emulation srm configure
linux/pz emulation srm status
```

SRM usa o AppImage/`steamrommanager.sh` do EmuDeck quando disponivel, aponta `steamDirectory` para a Steam local, `romsDirectory` para `~/Emulation/roms`, `retroarchPath` para o launcher EmuDeck e importa todos os parsers validos do template EmuDeck. Caminhos absolutos antigos sao tornados portaveis. Switch usa exclusivamente a view segura gerada pelo PhaseZero; `Nintendo Switch (Update)`, `Nintendo Switch (DLC)`, `Mods`, `Firmware`, `_backup` e `Torrent` nunca entram no parser Ryujinx.

Launchers SteamOS:

```bash
linux/pz steamdeck conveniences plan
linux/pz steamdeck conveniences install
linux/pz emulation frontends repair
```

Instala Return to Gaming Mode, Windows VM e Waydroid em `~/.local/bin` e `~/.local/share/applications`. Os tres sao propagados para Steam, ES-DE, SRM, Heroic e LaunchBox junto aos demais frontends. `Return.desktop` chama `phasezero-return`, que usa o seletor de sessao SteamOS do PhaseZero.

Otimizacoes por jogo:

```bash
linux/pz emulation optimizer status
linux/pz emulation optimizer plan
linux/pz emulation optimizer apply <game-id>
linux/pz emulation optimizer apply-all
```

As 14 entradas documentadas escrevem configuracoes nativas idempotentes em DuckStation, PCSX2 e Dolphin. Roots XDG e Flatpak sao detectados. `emulation setup` aplica a biblioteca automaticamente; dry-run apenas mostra o plano. Detalhes em `docs/emulation-game-optimizer-plan.md`.

Suite Linux de proxies de IA:

```bash
linux/pz ai proxies plan all
linux/pz ai proxies install all
linux/pz ai proxies status all
linux/pz ai proxies start <id>
linux/pz ai proxies stop <id>
```

Os dez repositorios suportados ficam em `~/.local/share/phasezero/ai-proxies`. Projetos Node usam runtime Node 24 isolado; projetos Go recebem binario nativo. Servicos systemd de usuario sao instalados, mas permanecem desativados ate configuracao explicita de credenciais. Veja `docs/linux-ai-proxies.md`.

PS3/RPCS3:

```bash
linux/pz emulation ps3 configure
linux/pz emulation ps3 import-game /path/to/local/ps3-dump
linux/pz emulation ps3 import-firmware /path/to/local/PS3UPDAT.PUP
linux/pz emulation ps3 import-pkg /path/to/local/pkg-or-folder
linux/pz emulation ps3 import-rap /path/to/local/rap-or-folder
```

PS3 e local-only: dumps, PKG, RAP e firmware devem vir do usuario. PhaseZero configura VFS RPCS3, instala firmware/PKG via RPCS3 quando possivel e reconfigura Hydra/SRM; nao adiciona fontes remotas de jogos.

## Uso Seguro

UI:

```cmd
bootstrap-ui.bat
```

Smoke test da UI, sem abrir janela:

```cmd
cmd /c bootstrap-ui.bat -SmokeTest
```

CLI dry-run de componente isolado:

```powershell
.\bootstrap-tools.ps1 -Component notepadpp -DryRun -NonInteractive -HostHealth off -AppTuning off
```

Perfil seguro:

```powershell
.\bootstrap-tools.ps1 -Profile safe-base -DryRun -NonInteractive
```

Perfil beta publico:

```powershell
.\bootstrap-tools.ps1 -Profile public-beta -DryRun -NonInteractive
```

Perfil amplo, somente escolha explicita:

```powershell
.\bootstrap-tools.ps1 -Profile full-workstation -DryRun -NonInteractive
```

Auditoria:

```powershell
.\bootstrap-tools.ps1 -Audit -DryRun -NonInteractive
```

Diagnostico local:

```powershell
.\bootstrap-tools.ps1 -Doctor -DryRun -NonInteractive
.\bootstrap-tools.ps1 -SupportBundle -DryRun -NonInteractive
.\bootstrap-tools.ps1 -RepairPlan -DryRun -NonInteractive
```

`-Doctor` inclui `doctor.deck` com diagnostico read-only do Steam Deck quando aplicavel: hardware, AMD driver, bateria/power plan, display, input, streaming/conectividade e libraries Steam. `-SupportBundle` adiciona `deck-doctor.json`, `deck-power.json`, `deck-display.json` e `deck-libraries.json`; HTML bruto de `powercfg` nao entra no zip por padrao.

## Perfis

- `safe-base`: base pequena para maquina limpa. Inclui runtime/dev essencial e Notepad++. Nao inclui desktops de IA, containers, jogos, HostHealth ou AppTuning.
- `recommended`: alias seguro/compat para `safe-base`.
- `public-beta`: primeira instalacao confiavel; inclui base segura, PowerShell, PowerToys, Brave, VS Code, secrets e MCPs. Nao inclui WSL/Docker/IA desktop/gaming.
- `dev-ai`: pilha de IA/dev por escolha explicita.
- `steamdeck-linux`: expansao Linux opt-in para experiencia SteamOS-like em Steam Deck/handhelds: hotkeys, teclado virtual, Big Picture/Gamepad UI e tuning de jogos.
- `emulation-linux`: expansao Linux opt-in para EmuDeck/Eden/Citron/Hydra/SRM, Lua, Steam helper tools, launchers desktop e layout de emulacao com conteudo do usuario importado localmente.
- `full-workstation`: perfil amplo com stacks desktop, IA, containers, creator, social e utilitarios. Nunca deve ser default silencioso.
- `legacy`: compatibilidade com fluxo historico.

### Servidor caseiro (mantem o Windows; nao e Umbrel/DietPi)

Familia de perfis que transforma o PC **mantendo o Windows** (homelab via Docker/WSL2 + Tailscale; o SO **nao** e substituido). 6 modos:

- `server-llm`: LLM local (Ollama) + Windows enxugado (menor RAM, reversivel).
- `server-homelab`: servidor caseiro (Drive/midia/cofre/monitor) via Docker/WSL2 + acesso remoto Tailscale.
- `server-homelab-hermes`: servidor caseiro + Hermes para atuacao remota.
- `server-llm-hermes`: LLM local + Hermes remoto, com SO enxugado.
- `server-llm-homelab`: LLM local + servidor caseiro, com SO enxugado.
- `server-llm-homelab-hermes`: tudo combinado, com SO enxugado.

Componentes envolvidos (opt-in): `os-slim-server` (enxuga RAM, reversivel via `-Rollback`), `homelab-stack` (core leve: Portainer/Jellyfin/Syncthing/Vaultwarden/Uptime Kuma; extras opt-in: Nextcloud/Grafana/Paperless-ngx/n8n), `hermes-remote` (Hermes + Tailscale), e o add-on opt-in `llamacpp-server` (offload hibrido GPU/CPU). Segredos sempre via `.env`/ambiente, nunca embutidos. Exponha os servicos apenas pela rede Tailscale.

**LLM local - perfis de performance e modelos:** o `llamacpp-server` baixa o binario do release oficial conforme a GPU (cuda/vulkan/cpu) e oferece 3 focos via `-PerfMode` no launcher `run-llamacpp.ps1`:

- `speed`: mais tokens/s (quant menor, KV cache `q4_0`, contexto curto).
- `capacity`: mais qualidade/contexto (quant maior, KV cache `f16`, contexto longo).
- `moderate`: equilibrio (KV cache `q8_0`, contexto medio).

O download do modelo GGUF e guiado: ha um catalogo curado por perfil (`Get-BootstrapGgufModelCatalog`) e download via `Install-BootstrapGgufModel`; rode `run-llamacpp.ps1 -ModelPath <gguf> -PerfMode <speed|capacity|moderate>`.

## Transcricoes tecnicas

- Matriz fechada: `docs/video-transcript-integration.md` cobre 58 titulos com Destino final definido.
- Apps novos ficam sob demanda: Zen Browser, Jan, Obsidian, KDE Connect, Godot, Krita, Audacity, Headroom AI, web apps v0/Bolt/Lovable.
- Itens experimentais ficam opt-in/manual: Printing Press, Odysseus, IndexTTS2, AnythingLLM, llama.cpp MTP e Headroom AI.
- Providers BYOK OpenAI-compatible novos: `minimax`, `nex`, `zhipu-glm`.
- AppTuning adiciona `agent-config`, `knowledge-vault`, `workflow-automation` e templates manuais.
- UI exibe badges por componente: Seguro, Experimental, Manual, Requer GPU, Requer login.

## Escopo UI/CLI

Quando usuario seleciona componente isolado, backend recebe somente o componente necessario:

```powershell
-Component notepadpp -HostHealth off -AppTuning off
```

O backend nao deve receber `-Profile recommended` nesse caso. Se perfis e componentes coexistem na UI, o botao principal exige confirmacao de escopo antes de executar:

- somente componentes selecionados;
- perfil atual + componentes;
- cancelar.

## Result JSON

Toda execucao deve deixar um `result.json` parseavel quando `ResultPath` existe ou quando o script escolhe caminho padrao. O envelope comum inclui:

- `status`: `success`, `warning`, `blocked` ou `error`;
- `exitCode`;
- `mode`;
- `artifactPaths.logPath`;
- `artifactPaths.resultPath`;
- `diagnostics[]`;
- `scope`;
- `rollback`;
- `auditSummary` e `auditResults[]` quando `mode = audit`.
- `doctor`, `supportBundle` e `repairPlan` quando os modos de suporte local forem usados.
- `doctor.deck` quando `mode = doctor` ou bundle de suporte gerar diagnostico Steam Deck.

UI e `install-cli.ps1` nao aceitam sucesso somente por exit code. Se processo elevado, crash fake ou backend morto nao escrever `result.json`, a camada chamadora cria fallback com stdout/stderr/log/result e acao recomendada.

## Auditoria

Severidades publicas:

- `Ready`
- `NeedsInstall`
- `NeedsRepair`
- `RequiresRestart`
- `ManualAction`
- `OptionalMissing`
- `UnsupportedAudit`

`UnsupportedAudit` nao entra em contagem critica. `Skipped` legado vira `UnsupportedAudit`. `GhostInstall` vira `NeedsRepair` quando ha reparo seguro; caso contrario, deve virar acao manual clara. Java valida JDK real por `javac.exe`/path de JDK, nao somente `java -version`. .NET SDK valida banda 8.x por `dotnet --list-sdks`.

## Logs e Artefatos

Locais comuns:

- `%USERPROFILE%\.bootstrap-tools\logs\`
- `%LOCALAPPDATA%\bootstrap-tools\logs\`
- `%TEMP%\bootstrap-tools\`

Campos importantes em falha:

- componente afetado;
- causa;
- `howToFix`;
- stdout/stderr quando houver processo filho;
- `rollback.available`;
- caminho de change manifest quando existir.

## Rollback e Limites

Rollback cobre mudancas registradas pelo projeto: registro, arquivos gerenciados, alguns servicos e exclusoes Defender controladas. Nao promete desfazer com seguranca todo pacote winget/npm/chocolatey/uv instalado fora do manifest. Quando rollback automatico nao e seguro, `result.json` deve marcar acao manual.

Limites atuais:

- alguns componentes ainda retornam `UnsupportedAudit` ate existir heuristica segura;
- alguns provedores/API exigem login, OAuth ou revisao manual;
- pacotes externos podem mudar IDs, instaladores e comportamento;
- WSL, MSI e winget podem exigir reboot antes de nova tentativa;
- UI WPF exige sessao desktop interativa.

## Verificacao Local

Parse PowerShell:

```powershell
$files = 'bootstrap-tools.ps1','bootstrap-ui.ps1','install-cli.ps1'
foreach ($f in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$tokens, [ref]$errors) > $null
  if ($errors) { $errors | Format-List; exit 1 }
}
```

Contrato e dry-runs minimos:

```powershell
.\bootstrap-tools.ps1 -UiContractJson -NonInteractive | ConvertFrom-Json | Out-Null
.\bootstrap-tools.ps1 -Component notepadpp -DryRun -NonInteractive -HostHealth off -AppTuning off
.\bootstrap-tools.ps1 -Profile safe-base -DryRun -NonInteractive
.\bootstrap-tools.ps1 -Audit -DryRun -NonInteractive
cmd /c bootstrap-ui.bat -SmokeTest
```

Suite. Em maquina limpa, o runner prepara Pester 3.4.0 em `CurrentUser` com timeout e retry controlado:

```powershell
.\tests\run-pester.ps1
```

Suite sem instalar dependencia ausente:

```powershell
.\tests\run-pester.ps1 -NoInstall
```

## Seguranca

- Nao versionar `.bootstrap-tools/`, `.mcp.json`, logs, dumps ou manifests com credenciais.
- Credenciais locais ficam fora do Git.
- Tokens vazados fora do gerenciador de segredos devem ser rotacionados.
- Componentes `manual-required` explicam motivo e instrucao, sem marcar sucesso automatico.
