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

```bash
linux/pz help
linux/pz install safe-base
linux/pz install steamdeck-linux
linux/pz steamdeck detect
linux/pz steamdeck hotkeys dry-run
linux/pz steamdeck keyboard
linux/pz steamdeck console
linux/pz steamdeck boot dry-run
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
linux/pz emulation ps3 import-game /path/to/local/ps3-dump
linux/pz emulation ps3 import-pkg /path/to/local/pkg
linux/pz emulation ps3 import-rap /path/to/local/rap
linux/pz emulation lua status
linux/pz emulation steam-tools status
linux/pz emulation fixes list
linux/pz emulation bios import /path/to/local/bios-dump
```

`steamdeck-linux` e opt-in. O foco inicial e experiencia estilo SteamOS: Steam Gamepad UI, atalhos `Ctrl+Alt+F1..F6`, teclado virtual por Steam/wvkbd/onboard/maliit, watcher de modo com debounce e tuning de jogos.

`windows-vm-linux` e opt-in. Automatiza VM Windows em QEMU/KVM a partir de uma ISO indicada pelo usuario. Antes de criar disco novo, detecta dominios Windows em `qemu:///system` e imagens instaladas; dominio libvirt existente vira default, preservando snapshot, firmware e hardware virtual originais. Sem dominio, usa QEMU direto com CPU `host`, KVM, OVMF, TPM 2.0, audio, SPICE USB redirection, SMB e virtiofs. O viewer SPICE compartilha os links de `HOME`, `/mnt/sdcard`, removiveis e `/mnt`; quatro canais USB cobrem pendrives, perifericos e leitores smartcard USB.

`waydroid-linux` e opt-in. Automatiza Waydroid como Android em container no host Linux, com detecao de binder, servico `waydroid-container`, compositor kiosk Wayland (`cage` preferido, `kwin_wayland` fallback), launchers do usuario e boot direto via GRUB/SDDM. `repair --init` baixa sistema/vendor por mirrors SourceForge com retry, valida tamanho e SHA-256, prepara runtime e inicializa Android; sem `--init`, nao baixa imagens.

`emulation-linux` e opt-in. Instala launchers do EmuDeck/Eden/Citron/Hydra, configura Hydra Classic e Steam ROM Manager com emuladores detectados, prepara Lua/LuaJIT, audita Steam helper tools e cria layout compartilhado `~/Emulation`. Em Steam Deck real (DMI Valve/Jupiter/Galileo/Sephiroth), EmuDeck usa o `EmuDeck.desktop` do desktop do usuario e PhaseZero cria um wrapper que chama esse launcher; em PC Linux generico, usa o AppImage direto. BIOS, firmware, keys, ROMs, updates e DLC nao sao baixados: use importacao local de dumps proprios.

Boot direto estilo SteamOS:

```bash
linux/pz steamdeck boot dry-run
sudo linux/steamdeck/install-steamos-boot.sh install
```

Isso adiciona uma entrada GRUB `PhaseZero SteamOS Console`. Ela inicializa o mesmo Linux com `phasezero.steamos=1`; um servico antes do SDDM seleciona `phasezero-steamos.desktop`. Ao escolher Desktop na Steam, o hook `steamos-session-select` encerra gamescope e inicia Plasma na mesma sessao, sem novo login. Em Valve Jupiter/Galileo, drop-in GRUB usa `800x600` landscape, timeout de 5 segundos e terminais `console`, `usb_keyboard` e `at_keyboard`. GRUB nao possui API de joystick analogico; boot one-shot pelos launchers evita depender de entrada pre-kernel.

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

SRM usa o AppImage/`steamrommanager.sh` do EmuDeck quando disponivel, aponta `steamDirectory` para a Steam local, `romsDirectory` para `~/Emulation/roms`, `retroarchPath` para o launcher EmuDeck e normaliza parsers Eden/Citron/DuckStation/PCSX2/RPCS3.

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
