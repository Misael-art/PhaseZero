# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
As versões seguem a data de build em `version.json`.

## [1.13.0] - 2026-07-30

### Adicionado
- Janela dedicada Provision Player (`windows.provision.player` na UI nativa):
  plano, confirmação, provisão com checkpoint e progresso, validação pós-boot,
  cancelamento, retomada, descarte, reparo, shutdown e reboot.
- `provision status --json` expõe vmDir, snapshotPath, snapshotExists, qemuPid,
  qemuRunning, libvirtRunning.
- `provision shutdown` via QGA guest-shutdown + PID waiting + libvirt fallback.
- `windows-vm.sh --json` emite bootReady e oneShotReady como booleanos estritos.
- `common.sh::checkpoint_progress_start`/`end`: sequência de progresso por
  checkpoint com pesos somando 100.
- ProvisionWorker com sleep interruptível (100ms) para fechamento rápido.
- AsyncProc: timeout dispara uma vez, FailedToStart aborta imediatamente,
  finished sinal com tupla (data, exit_code).
- Testes comportamentais (295 Python, 12 específicos do player).

### Corrigido
- Player não bloqueia o event loop Qt (sem waitForFinished/QThread.wait).
- `_finish_once` centraliza conclusão de AsyncProc (sem emissão dupla).
- Janela não destrói worker thread durante close (aborta primeiro).
- `_resume_state` não sobrescreve ISO/parâmetros explícitos em `open()`.
- Discard limpa disco sem salvar estado via `_discarding` flag.

## [Não lançado]

### Adicionado
- Inventário de VMs concluídas criadas pelo provisionador, com espaço real por
  operação e remoção explícita por instalação. A interface separa a VM atual
  das instalações legadas e oferece lixeira recuperável ou liberação imediata.
- Gerenciador de imagens Windows na Central de Controle (`Windows VM` →
  "Gerenciar imagens"): lista as ISOs registradas, mostra características
  básicas (tamanho, arquitetura, UEFI, SHA-256, validade), lista as edições
  por índice WIM marcando as já instaladas e reúne numa única tela reproduzir
  no player, habilitar no boot, restaurar o GRUB e remover.
- Registro versionado de imagens (`linux/ui_native/image_registry.py`,
  `images.json` sob o diretório de estado): `schemaVersion 1`, escrita atômica
  com modo 0600, idempotência por `sha256`, arquivo ausente ou corrompido
  degrada para lista vazia e versão futura falha fechada.
- `pz windows-vm media scan [--json]`: descoberta de ISOs do Windows nas bases
  canônicas (`~/Downloads`, `/mnt/sdcard/Steam`, `$HOME`, `/mnt/sdcard`), com
  deduplicação por caminho. O contrato de `media inspect` permanece inalterado.
- Modo simplificado padrão na Central de Controle: comandos, JSON e logs ficam
  recolhidos; a chave global "Modo avançado" revela detalhes técnicos sob
  demanda.
- Páginas visuais dedicadas para Windows VM, Waydroid e Servidor, com status,
  ações de ligar/desligar, sliders seguros, toggles explicativos e zona de
  perigo separada.
- Painel "Saúde do sistema" agrupa diagnóstico por categoria e converte
  `PASS`/`WARN`/`FAIL` em indicadores e ações compreensíveis.
- Resultados estruturados usam cards e fatos legíveis; sucessos mutáveis usam
  toast e falhas abrem diálogo orientado à correção.
- Comando `pz waydroid stop` idempotente para suportar o controle visual.
- Configurador de roteamento IA por tarefa (`linux/ai/routing_manager.py`,
  `pz ai routing`): inventário de conexões do 9Router com quota real
  (known/unknown/unavailable + confiança), recomendações por tarefa
  (code/analysis/plan) e política (quality/balanced/save-quota/privacy),
  plano transacional `phasezero-*` com manifesto, apply idempotente,
  rollback byte a byte (recusa drift sem `--force`), `run` com env de
  criança e `verify` (health, planMatches, userCombosPreserved,
  bonsaiIsolated). Redação obrigatória de segredos.
- Página dedicada "Roteamento IA" na UI nativa: cards por tarefa com
  recomendação/cadeia/quota, seletor de política, editor de ordem de
  fallbacks, aplicar/reverter e isolamento Bonsai.
- Suíte de testes `tests/test_routing_manager.py` com 9Router fake
  (machine-id + CLI secret + API key), falhas injetadas, rollback
  transacional e e2e via `pz ai routing`.
- Smoke `pz ai routing` em `tests/linux-ai.sh` (degrada sem 9Router).

### Corrigido
- A sessão de boot direto não mata mais o Windows em execução ao ser
  encerrada. Todo fim de sessão (logout do SDDM, sinal, arquivo
  `shutdown.requested`) pede primeiro o desligamento do convidado via QGA
  (`guest-login shutdown`), espera até 120 s e só então escala TERM→KILL;
  fim forçado é registrado como desligamento sujo.
- Cada sessão grava `session-state.json` versionado (graceful, motivo,
  duração, display usado) e o `status --json` passa a expor `session` com os
  findings `guest-unclean-shutdown` (desligamento sujo — orientação de
  reparo) e `session-shutdown-hint` (saída não verificada — dica de
  encerramento correto), alimentando a UI com próximo passo claro.
- `fallback_desktop` ganha kill-switch `PZ_WINDOWS_VM_SESSION_DESKTOP_FALLBACK=0`
  para suítes de contrato rodarem dentro de uma sessão logada sem risco de
  subir um desktop aninhado.
- A janela do QEMU passa a pedir confirmação antes de fechar
  (`confirm-quit=on` nos perfis GTK): fechar sem querer com o Windows ligado
  derrubava o convidado na hora e sujava o disco.
- Descartar uma instalação interrompida antes de qualquer disco existir
  (checkpoints `validate`/`assets`) deixa de reportar
  `staging removal failed; preserved:` com caminho vazio. A operação nunca
  registrou diretório de staging, então não há nada a preservar e o descarte é
  concluído. O player ficava preso em "Descarte falhou" e impedia iniciar uma
  nova instalação.
- Remover a VM configurada deixa de ser impossível para toda VM criada pelo
  PhaseZero. `provision finalize` adota o próprio disco que acabou de construir,
  o que marcava a VM como `adopted-existing` e caía no bloqueio "somente VMs
  criadas pelo PhaseZero podem ser removidas aqui". `adopt` passa a registrar a
  procedência (`--source provisioned|adopted-existing`) e `remove` decide pela
  localização: discos dentro de `~/VirtualMachines/PhaseZero*` são removíveis,
  com aviso explícito quando a VM foi adotada em vez de criada. Procedência
  desconhecida vira bloqueio.
- A prévia de remoção da VM deixava de ficar pronta em qualquer host cujo
  `active.lock` já tivesse sido liberado: `provision_lock_clear` trunca o lock
  no lugar e nunca o apaga, então lock vazio é o estado normal de "nenhuma
  operação ativa", mas o leitor tratava o vazio como inconsistente e devolvia
  "estado do provisionamento é inconsistente; repare ou descarte a operação".
  Lock vazio volta a significar ociosidade; conteúdo inválido continua
  bloqueando.
- Remover uma imagem do Windows não é mais confundido com apagar a VM criada.
  Remoção legada valida o identificador, recusa VM em execução, revalida o alvo
  sob trava compartilhada com a finalização e libera o índice somente após
  remoção confirmada.
- Gerenciador de imagens: ISO válida cujas edições não são legíveis a partir
  do arquivo (caso comum em mídia de varejo, em que `media inspect` devolve
  `imageCount: 0`) passa a oferecer as edições 1 a 10, como a instalação já
  fazia, em vez de deixar a lista vazia e o botão de reproduzir desabilitado.
- Gerenciador de imagens: falha ao mover a ISO para a lixeira é reportada como
  falha (a sobrecarga estática do Qt devolve uma tupla, sempre verdadeira).
- Gerenciador de imagens: uma ISO ilegível não interrompe mais a análise das
  demais imagens selecionadas na busca.
- `verify` considera isolamento Bonsai por combos, não por conexão.
- Redação preserva booleanos em chaves como `secretsRedacted`.
- Atribuição de modelo a provider por prefixo (`cc/`, `cx/`, ...).
- Página dedicada "Proxies IA" na UI nativa: gateways 9Router/Odysseus, cards
  por proxy com iniciar/parar, autenticação OAuth por navegador, integração com
  IDEs e polling passivo de status.
- `pz ai proxies detailed-status` (JSON consolidado de instalação, serviços,
  autenticação e IDEs), `restart` e `login all` sequencial para proxies com
  sessão de navegador.
- 9Router com pacote verificado, atualização atômica, perfil de clientes e
  watchdog passivo.
- Odysseus fixado em commit oficial, provisionado com Podman rootless,
  autenticação obrigatória e rollback.
- Inventário unificado e timer check-only para updates PhaseZero, apps e host.
- Qwen Code Desktop oficial `desktop-latest`, instalado por usuário com digest
  SHA-256, launcher Wayland e diretório de configuração privado.
- WinBoat e WinPodX oficiais com Podman rootless, recursos adequados aos 14 GiB
  do Steam Deck, FreeRDP, multitouch e política de um guest Windows por vez.
- Compartilhamento `PZExchange`, canal SPICE WebDAV e diagnóstico da rede/NIC
  libvirt.

### Homelab v1.15.1 (remediação, merge PR #37)

### Adicionado
- Port do Homelab v1.15.1: stack, status, boot-prepare, compose core/extras e
  operations com lock de exclusão, crash/resume/cancel e rollback; estado nunca
  em `/root` (HOME/XDG explícitos via runuser).
- Resource governor com 6 perfis públicos (`homelab-profiles.json`):
  assistant-private, assistant-multichannel, automation, ai-studio (blocked),
  developer e edge (default), com classe, maturidade e pesos por imagem;
  `pz server homelab profile set` com gate de RAM e fail-closed.
- AI policy broker (modos, allowlist de ações, redação de segredos).
- CLI `pz server homelab` (status/plan/verify/repair/backup/restore/logs,
  `profiles --json`) e Player nativo async QProcess com UI de controle.
- Portainer alcança o Docker somente via `socket-proxy` read-only
  (tecnativa/docker-socket-proxy:0.2.0, allowlist CONTAINERS/TASKS); nenhum
  container monta `/var/run/docker.sock`.
- Suíte hermética `tests/linux-homelab.sh`, smoke `packaging/install-root-smoke.sh`
  e jobs dedicados de CI (`homelab-shell-test`, `homelab-python-test`,
  `compose-validate`, `package-smoke`, `security-secret-scan` com gitleaks).
- Testes do contrato WinVM no governor (stub de status, fail-closed, plano de
  impacto, execução graciosa, resume) e de rollback do restore (falha parcial
  com volume envenenado) na suíte hermética.
- Documentação de operação (docs/linux-homelab.md): arquitetura e perfis,
  matriz de suporte, threat model (socket-proxy, no-new-privileges, limits),
  segredos/rede/acesso, backup/restore/DR com snapshot prévio e rollback,
  contrato WinVM, operação sem UI/troubleshooting e limitações honestas.

### Corrigido
- Restore recusa aplicar sem `--yes` explícito; verify-then-apply e manifest
  schemaVersion 2 com tamper fail-closed.
- Restore cria snapshot prévio `<source>.pre-restore` (verificável, mesmo
  schema) e em falha parcial devolve cada volume tocado ao estado prévio
  (`rollbackApplied`); `status` ignora diretórios `*.pre-restore`.
- Governor desconta WinVM ativa do orçamento (`winvmMB`) e expõe contrato
  `winvm-status`/`winvm-suspend [--dry-run]`/`winvm-resume` com suspensão
  somente graciosa via QGA (`killUsed:"never"`, nenhum arquivo da VM tocado).
- CI: job `homelab-integration-disposable` prova em Docker real
  backup → destruição → restore → igualdade byte a byte em volumes
  descartáveis.
- Contrato CLI/Player alinhado (`pz server homelab profiles --json`); scripts
  novos marcados executáveis (core.filemode=false); suíte pinada ao checkout
  via `PZ_ROOT`; ShellCheck 0.9.0 e 0.11.x verdes com os mesmos excludes do CI.
- Auditoria deduplica aliases `/usr/lib` e `/usr/lib64` do mesmo inode.
- Shares Windows validam listagem real e criam diretório de intercâmbio como o
  usuário alvo.
- Runtime gráfico Steam Deck LCD documenta e aplica Gamescope 1280×800 com
  orientação `right`, evitando guest vertical no modo handheld.

## [1.8.4] - 2026-07-13

### Corrigido
- Backend ISO preserva modo executável nos pacotes e aparece disponível no
  status geral mesmo quando invocado explicitamente por `bash`.

## [1.8.3] - 2026-07-13

### Corrigido
- CI nativo instala `python-pip`, necessário para empacotar PySide6 no AppImage.
- Flatpak obtém wheels PySide6 por URLs fixas e valida SHA-256, sem depender de
  arquivos locais ausentes no checkout.

## [1.8.2] - 2026-07-13

### Corrigido
- Builders invocam `export-source.sh` via `bash`, funcionando em checkout CI
  onde scripts auxiliares preservados como modo `100644` não são executáveis.

## [1.8.1] - 2026-07-12

### Corrigido
- Release sincroniza `version.json` com metadados DEB, RPM, AUR, Flatpak e
  AppStream antes do commit/tag.
- Job de pacotes instala PySide6 antes do gate de coesão; job Flatpak usa imagem
  oficial existente `gnome-48` conforme documentação upstream.

## [1.8.0] - 2026-07-12

Foco: boot dinâmico seguro de ISOs e mídias removíveis pelo GRUB do host.

### Adicionado
- **ISO loopback tipada**: `pz boot iso` detecta e valida ArchISO,
  SystemRescue, Ubuntu Casper, Debian Live e Grml; registra UUID, caminho GRUB,
  kernel/initrd, metadados e SHA-256 antes de gerar entradas one-shot.
- **Chainload removível por UUID**: `pz boot usb` descobre USB/SD, valida
  `/EFI/BOOT/BOOTX64.EFI` em montagem somente leitura e evita ordinais
  `(hdN,gptN)` e recursão no fallback EFI do host.
- **GRUB2 File Manager opt-in**: `pz boot grubfm` aceita somente EFI x86_64
  local com SHA-256 explícito, bloqueia Secure Boot não confirmado/desativado e
  sinaliza upstream arquivado; nenhum payload é baixado automaticamente.
- **Integração completa**: seletor Qt carrega ISOs/mídias disponíveis, catálogo
  possui previews elevados, doctor/repair-plan auditam geradores e documentação
  cobre instalação, one-shot e rollback.

### Segurança
- Escrita transacional em `/etc/grub.d/46`–`48`, backup prévio, instalação
  atômica, recompilação obrigatória e restauração automática quando validação
  falha. `/boot/grub/grub.cfg` nunca é editado diretamente.
- Atualização GRUB diferencia erro fatal de aviso conhecido do `os-prober` para
  mídia ISO híbrida sem drive GRUB; demais mensagens `error:` continuam fatais.
- EFI ativo com prefixo ordinal foi reparado no host por bootstrap UUID antes
  da instalação. USB BigLinux `3339-E139` foi registrado e entrada passou
  `grub-script-check`; boot padrão permaneceu intacto.

### Validação
- `linux-iso-boot`, `linux-boot-recovery`, `linux-doctor`, `linux-menus` e
  `linux-ui` aprovados.
- 58 testes Python nativos aprovados; smoke Qt/UI adicional aprovou 23 testes.
- Fixture ArchISO local confirmou detecção automática de label, kernel e initrd.

## [1.6.0] - 2026-07-11

Foco: biblioteca de jogos orientada por tarefas, instalação Vita3K resiliente e
menu do desktop consolidado.

### Adicionado
- **Biblioteca unificada**: workflow nativo em cinco etapas — origem, análise,
  plano, execução e validação — aceita biblioteca completa, pasta ou múltiplos
  arquivos, com filtros, detalhes contextuais, cancelamento e rollback.
- **Adapter PlayStation Vita**: identifica ZIP/VPK NoNpDrm pelo conteúdo e SFO,
  bloqueia dumps incompatíveis, instala atomicamente em Vita3K, preserva origem
  e verifica hashes. `PCSE01224.zip` foi instalado e validado no host real.
- **Menu PhaseZero único**: consolida jogos/emuladores, web apps e sessões sob
  uma raiz KDE; deduplica por comando, oculta jogos individuais não favoritos e
  mantém ledger privado reversível.
- **Diagnóstico gráfico Windows VM**: perfis compat/virtio-gl e planos seguros
  para Venus, rutabaga e VFIO/Looking Glass, sem alterar GRUB ou bind VFIO.

### Corrigido
- **UI em 1280×800**: inspetor de contexto fica oculto até uma seleção; quatro
  jornadas substituem a pilha de 71 ações da página principal de Emulação.
- **ROM Vita em ZIP**: `rom-optimize` deixa de falhar como arquivo não suportado
  e encaminha pacote instalável ao planner da biblioteca.
- **Menu iniciar duplicado**: raízes legadas Jogos/Web Apps são removidas com
  backup e launchers gerenciados deixam categorias globais.

### Validação
- 133 testes Python, suítes nativas/emulação/menu/Windows VM e smoke offscreen.
- Instalação real Vita3K: 392 arquivos verificados, fonte SHA-256 preservada.
- Menu KDE: 76 entradas únicas, 103 jogos/auxiliares ocultos e aplicação idempotente.

## [1.5.1] - 2026-07-11

### Corrigido
- **Atalho do menu iniciar**: o wrapper instalado no usuário agora resolve a própria
  release antes de `/usr/lib/phasezero`, evitando abrir UI antiga quando o pacote
  do sistema ainda está em versão anterior.

## [1.5.0] - 2026-07-11

Foco: reorganização completa da Central de Controle nativa para reduzir ruído,
agrupar jornadas e tornar impacto/risco explícitos antes da execução.

### Adicionado
- **Workspace contextual**: módulos operacionais usam navegação secundária por
  intenção (visão geral, sessão, biblioteca, frontends, controles, manutenção e
  avançado), preservando acesso às 250 ações do catálogo.
- **Inspetor de contexto**: seleção de uma ação mostra descrição, risco, resultado
  esperado e comando seguro. Apenas o inspetor oferece o CTA Executar/Pré-visualizar.
- **Componentes consistentes**: linhas semânticas, métricas reais do catálogo,
  radio buttons para modos exclusivos do Steam Deck e disclosure para ações raras.
- **Busca reorganizada**: resultados textuais agora usam lista selecionável e o
  mesmo inspetor, em vez de grids extensos de cards e botões.

### Corrigido
- **Hierarquia visual**: remove pilhas de botões com mesma ênfase, barras de status
  duplicadas, ícones genéricos repetidos e agrupamentos pouco claros.
- **Acessibilidade**: alvos mínimos de 48 px, foco visível, labels persistentes,
  descrições acessíveis e navegação completa por teclado.
- **Portabilidade visual**: componentes usam Qt/PySide6, tokens semânticos e ícones
  do tema/sistema com fallbacks, sem dependência de primitivas gráficas Linux.

### Validação
- Design QA comparado ao mock selecionado em 1586×992 e 1280×800.
- 97 testes Python e todas as suites `tests/linux*.sh` aprovados.

## [1.4.1] - 2026-07-10

Foco: correções de emulação e experiência SteamOS — Steam ROM Manager, centralização
de keys/firmware, pastas duplicadas, mídia órfã e robustez de sessão Game Mode.

### Corrigido
- **Decky no SteamOS**: preparação e validação transacional dos bundles impede
  carregar plugins incompletos (`frontend_bundle not OK`/imports dinâmicos);
  pacotes inválidos são preservados ou isolados sem substituir instalação válida.
- **Fundação visual**: temas claro/escuro usam tokens semânticos validados, sem
  hex residual no QSS, com contraste AA nos pares essenciais e shimmer sem vazamento.
- **Execução resiliente**: status assíncrono sanitiza stderr, expira, cancela e
  limpa processos deterministicamente; resultados ficam privados e argumentos
  continuam sem shell.
- **Portabilidade preparada**: estado, permissões, elevação, abertura de caminhos
  e encerramento de processos foram isolados; plataforma Windows simulada não
  expõe ações Linux nem seletor de boot.
- **Steam ROM Manager — parsers faltantes**: `normalize_srm_parsers` só cobria
  Switch/PSX/PS2/PS3/PS4/Xbox360. Adicionados parsers PhaseZero-managed para
  GameCube, Wii, Wii U, N64, SNES, NES, GBA, GB e PSP apontando para os launchers
  corretos (Dolphin, Cemu, RetroArch cores, PPSSPP). Essas ROMs agora viram
  shortcuts Steam e aparecem no Big Picture.
- **Keys/firmware centralizados quebrados no Game Mode**: `import_switch_keys`
  short-circuitava quando o Ryujinx já tinha keys, deixando o store central
  (`~/Emulation/firmware/switch/keys`) vazio; Eden/Citron linkavam ao Ryujinx em
  vez do central. Agora o store central é sempre populado e Eden/Citron/Ryujinx
  linkam a ele (prioridade central > Ryujinx > cópia). Corrige o prompt
  reincidente de keys/firmware ao abrir emuladores no SteamOS Game Mode.
- **Pastas Emulation duplicadas**: layout canônico não declarava `keys`,
  `hdpacks`, `texturepacks`. `pz_emulation_consolidate_aliases` agora cria
  symlinks de compatibilidade (`keys → firmware/switch/keys`,
  `texturepacks/hdpacks → texture_packs`) para dirs vazios, sem clobber de
  conteúdo real do usuário.
- **Mídia órfã não limpa**: o índice de mídia mapeava rom→mídia mas nunca
  computava o inverso. `media-index.py` agora emite `orphanedMedia` (mídia sem
  rom correspondente) e `media.sh clean [--apply]` move esses arquivos para
  `~/Emulation/.phasezero/backups/orphaned-media-<data>/` (backup, não delete).
- **Eden EmuDeck SRM glob recursivo**: o template opcional em
  `~/.config/EmuDeck/.../nintendo_switch_eden.json` usava glob `**/` recursivo,
  que descia em `Nintendo Switch (DLC)/(Update)`, `Mods`, `Firmware`, `_backup`,
  `Torrent`. Agora usa glob não-recursivo `${title}@`, alinhado ao SRM ativo.
- **SteamOS session robustez**: `steamos-session.sh` agora valida `steam` além
  de `gamescope-session-plus` e registra instruções de instalação quando algum
  falta, antes de cair para desktop (antes do fallback silencioso para Plasma).

### Adicionado
- **Ação `emulation media clean`** exposta no `pz`, `catalog.py` (card "Limpar
  mídia órfã") e `actions.json` regenerado. Dry-run por padrão; `--apply` move
  para backup.
- **Central de Controle nativa completa**: catálogo canônico com 250 ações,
  parâmetros tipados, busca global e seção contextual Avançado cobre comandos
  Linux públicos e todos os perfis sem exigir descoberta pelo terminal.
- **UX operacional**: skeleton sem flash para respostas rápidas, saúde assíncrona,
  preview seguro, confirmação explícita para alto risco, progresso cancelável,
  resultado/histórico, breadcrumb, barra de estado persistente e navegação por teclado.
- **Contrato público**: `linux/pz commands --json` expõe o mesmo catálogo usado
  pela UI; gates detectam IDs/comandos duplicados, parâmetros ausentes, ações
  mutáveis sem preview e funções não renderizadas.

### Notas
- **SteamOS pré-requisitos**: a entrada GRUB `PhaseZero SteamOS Console` exige
  `gamescope-session-plus`, `steam` e `sddm` instalados (todos verificados no
  host). Sem eles, a sessão cai em Plasma com log de diagnóstico.

## [1.4.0] - 2026-07-09

Foco: fechamento de lacunas Linux/Windows — autenticação dos proxies de IA,
economia de contexto para Codex/Claude e release de pacotes atualizados.

### Adicionado
- **Proxies de IA Linux — auth/login**: `pz ai proxies auth [id]` retorna
  `webValidation` redigido compatível com o contrato Windows; Kimi/Qwen/DeepSeek
  usam `browser-session` e Mimo usa `env-session`.
- **Login real via UI/CLI**: `pz ai proxies login kimiproxy|qwenproxy|deepsproxy`
  abre Chromium visível, para o serviço user antes do login para evitar lock
  Playwright headless, grava log/estado em `~/.local/state/phasezero/ai-proxies/`
  e reinicia o serviço após o fluxo terminar.
- **Central de Controle**: novos cards "Auth proxies IA" e login dedicado para
  Kimi, Qwen e DeepSeek.
- **Token economy**: `pz ai token-economy status` como alias explícito de
  compatibilidade para validar RTK, ai-memory, Headroom e `ai-context-frugality`
  em Codex/Claude sem auto-wrappers.

### Corrigido
- **Portabilidade Windows→Linux**: o status de autenticação dos proxies agora
  espelha `webValidation.required/kind/status` sem vazar nomes ou valores de
  credenciais; Mimo reporta apenas grupos genéricos faltantes.
- **Bind seguro por padrão**: wrappers Linux definem `PZ_BIND_HOST=127.0.0.1`;
  Kimi/Deep/Mimo recebem patch compat local para não expor listeners em `0.0.0.0`
  quando executados como serviços PhaseZero.
- **Teste Linux de proxies**: `tests/linux-ai-proxies.sh` foi isolado de configs
  reais do usuário e corrigido para a porta Mimo 3013.
- **Documentação Linux/Windows**: README, `docs/ai-tools.md` e
  `docs/linux-ai-proxies.md` documentam login, auth, token economy e paridade
  Windows/Linux.

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
- **Empacotamento (Flatpak)**: `build-flatpak.sh` exigia que o `--state-dir` do
  `flatpak-builder` ficasse no mesmo filesystem do diretório de build/repo (ele
  usa hardlinks entre os dois); agora todos os três (`state`, `build`, `repo`)
  vão por padrão para um diretório `/tmp` (tmpfs) recém-criado.
- **Bit de execução perdido no git**: este repositório tem `core.fileMode=false`
  (necessário porque o checkout roda sobre um mount FUSE/NTFS-3g, que não reporta
  mudanças de permissão de forma confiável) — isso fez o modo rastreado pelo git
  de `linux/pz`, `linux/ui/native.sh` e outros scripts de entrada regredir para
  não-executável, embora funcionassem localmente (tudo aqui é chamado via
  `bash script.sh` explícito). O `.deb`/`.rpm`/AppImage não foram afetados (usam
  `cp -a` da árvore de trabalho local), mas o pacote AUR e o Flatpak buscam a
  fonte de um `git clone`/tarball da tag publicada — e um `git clone` limpo do
  GitHub também teria `linux/pz` sem permissão de execução, quebrando o uso
  documentado no README (`linux/pz <comando>`, sem prefixo `bash`). Corrigido o
  modo rastreado pelo git para os scripts que o README/empacotamento invocam
  diretamente; o manifesto do Flatpak ganhou um `chmod +x` defensivo adicional.

**Nota:** a tag `v1.3.0` foi movida (recriada apontando para o commit com esta
correção) pouco depois da publicação inicial, já que o bug do bit de execução
afeta a fonte buscada pelo AUR/Flatpak diretamente pela tag.

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
