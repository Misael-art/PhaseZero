# Boot dinâmico de ISOs via GRUB — plano de implementação

**Data:** 2026-07-12  
**Estado:** implementado na v1.8.0  
**Alvo:** PhaseZero Linux, Arch/Manjaro/BigLinux, GRUB 2, UEFI x86_64  
**Escopo:** ISO local, chainload de mídia removível, GRUB2 File Manager opt-in, CLI e UI nativa

## 1. Resultado

PhaseZero passa a oferecer três rotas de boot sem editar `/boot/grub/grub.cfg` diretamente:

1. **ISO registrada:** inicia ISO em filesystem legível pelo GRUB usando `loopback` e perfil de distribuição explícito.
2. **EFI removível registrada:** transfere controle para `/EFI/BOOT/BOOTX64.EFI` usando UUID da mídia, nunca `(hdN,gptN)`.
3. **Explorador de arquivos:** chainload opcional de `grubfmx64.efi` armazenado na ESP local, para escolher ISO em USB/SD no boot.

Entradas serão geradas em scripts numéricos próprios:

- `/etc/grub.d/46_phasezero_iso_loopback`;
- `/etc/grub.d/47_phasezero_removable_efi`;
- `/etc/grub.d/48_phasezero_grubfm`.

Toda mutação executa preflight, backup, geração atômica, `grub-mkconfig -o /boot/grub/grub.cfg`, validação pós-escrita e rollback. `40_custom` permanece intocado. Numeração preserva entradas PhaseZero atuais `42`–`45`.

## 2. Correções de premissas

### 2.1 Loopback não carrega ISO inteira na RAM

`loopback` expõe conteúdo da ISO ao GRUB. Kernel/initramfs da distribuição precisam reencontrar arquivo ISO após assumirem controle. Parâmetros variam por família. Arquivo precisa permanecer acessível no filesystem original.

### 2.2 Não existe autodetecção universal segura

`grml-rescueboot` upstream gera entradas para **ISOs Grml** em `/boot/grml`. Não constitui parser universal para Ubuntu, Arch, Debian, Fedora ou Windows. PhaseZero não anunciará suporte genérico baseado nele.

MVP usa perfis tipados e versionados. Perfil `auto` somente detecta assinaturas conhecidas dentro da ISO; ambiguidade bloqueia registro e pede `--profile`.

### 2.3 Chainload genérico por nome pode recursar

`search --file /EFI/BOOT/BOOTX64.EFI` é ambíguo. Host atual já pode possuir `/EFI/boot/bootx64.efi`; busca pode localizar fallback local e reiniciar mesmo GRUB.

Rota segura v1 registra UUID da partição removível. Scanner genérico só entra após teste que prove exclusão da ESP e root do host. GRUB2 File Manager cobre uso realmente dinâmico.

### 2.4 GRUB2 File Manager exige classificação experimental

Repositório `a1ive/grub2-filemanager` foi arquivado em 2023 e declara fim de manutenção. Último release listado é antigo. Binário não será baixado, atualizado ou executado implicitamente.

Instalação exige artefato local, SHA-256 informado/confirmado, validação PE/COFF x86_64 e decisão explícita sobre Secure Boot. Estado UI: `Experimental / upstream arquivado`.

## 3. Princípios de segurança

- Nunca editar `/boot/grub/grub.cfg`.
- Nunca usar `(hd0,gpt2)`, `/dev/sdX` ou ordem firmware como identidade persistente.
- Usar UUID de filesystem e caminho GRUB derivado pelo host.
- Nunca interpolar nome/caminho fornecido pelo usuário sem escape GRUB.
- Nunca `source` manifestos controlados pelo usuário.
- Nunca baixar ISO, ROM, BIOS, chave, EFI ou payload automaticamente.
- Nunca assinar binário ou matricular chave MOK automaticamente.
- Nunca alterar entrada UEFI ativa ou `/EFI/BOOT/BOOTX64.EFI` do host para instalar grubfm.
- Nunca mudar default permanente. Boot sob demanda usa `grub-reboot`/`next_entry`.
- Nunca prometer boot antes de teste real da ISO/perfil.
- Mutação exige root via ponte admin PhaseZero; leitura e plano permanecem sem root quando permissões permitirem.
- `--target-root` continua fail-closed; gravação fora de `/` exige chroot correto.

## 4. Arquitetura

### 4.1 Backend único

Criar `linux/boot/iso-boot.sh`. `linux/boot/recovery.sh` permanece coordenador do seletor e delega operações ISO ao novo backend.

Responsabilidades:

- inventariar ISOs e mídias;
- validar filesystem, UUID, caminho e conteúdo ISO;
- manter manifesto;
- renderizar scripts GRUB;
- instalar/remover grubfm;
- atualizar GRUB uma única vez por transação;
- validar IDs no `grub.cfg` gerado;
- agendar boot one-shot;
- emitir status humano e JSON versionado.

### 4.2 Estado persistente

Arquivos:

```text
/etc/phasezero/boot-isos.json
/var/lib/phasezero/boot/iso-artifacts.json
/var/lib/phasezero/boot-backups/<timestamp>/
/boot/efi/EFI/PhaseZero/grubfm/grubfmx64.efi
```

`boot-isos.json` contém dados declarativos. Escrita por arquivo temporário + `fsync` quando disponível + rename atômico. Permissões `0644`; diretório `0755`; nenhum segredo.

Schema v1:

```json
{
  "schemaVersion": 1,
  "entries": [
    {
      "id": "archlinux-2026-07",
      "title": "Arch Linux 2026.07",
      "kind": "iso",
      "profile": "archiso",
      "fsUuid": "UUID",
      "grubPath": "/isos/archlinux.iso",
      "sha256": "HEX",
      "isoLabel": "ARCH_202607",
      "enabled": true
    },
    {
      "id": "ventoy-rescue",
      "title": "USB Ventoy Rescue",
      "kind": "removable-efi",
      "fsUuid": "UUID",
      "efiPath": "/EFI/BOOT/BOOTX64.EFI",
      "enabled": true
    }
  ]
}
```

Regras:

- `id`: `[a-z0-9][a-z0-9-]{0,62}`;
- título: sem newline, controle ou sintaxe GRUB;
- caminhos: absolutos no filesystem, sem newline/NUL, normalizados, sem `..`;
- UUID obtido por `findmnt`/`lsblk`/`blkid`, nunca aceito cegamente;
- `sha256` detecta troca da ISO; divergência bloqueia one-shot até `refresh` explícito;
- JSON desconhecido ou schema futuro degrada para read-only.

### 4.3 Renderização GRUB

Adicionar helpers em `linux/lib/common.sh`:

- `pz_boot_grub_quote`;
- `pz_boot_fs_module_for_fstype`;
- `pz_boot_resolve_file_identity`;
- `pz_boot_validate_registered_path`;
- `pz_boot_secure_boot_state`;
- `pz_boot_atomic_install`.

Gerador produz `#!/usr/bin/env bash` + `exec tail -n +3 "$0"`, seguindo entradas existentes. Cada menuentry possui ID estável:

```text
phasezero-iso-<id>
phasezero-removable-<id>
phasezero-grubfm
```

Cada entrada:

- carrega somente módulos necessários;
- usa `search --no-floppy --fs-uuid --set=... UUID`;
- testa existência antes de `loopback`/`chainloader`;
- mostra erro útil e retorna ao menu quando mídia sumiu;
- não muda `prefix`, root global, terminal ou vídeo;
- não contém ordinal de disco.

## 5. Função 1 — ISO local por loopback

### 5.1 Contrato CLI

```text
linux/pz boot iso status [--json]
linux/pz boot iso scan [DIR] [--json]
linux/pz boot iso inspect PATH [--json]
linux/pz boot iso add PATH --profile PROFILE [--id ID] [--title TITLE] [--dry-run]
linux/pz boot iso refresh ID [--dry-run]
linux/pz boot iso remove ID [--dry-run]
linux/pz boot iso install [--dry-run]
linux/pz boot iso next ID [--reboot]
```

`add` registra arquivo em seu local atual. Não copia ISO. Diretório recomendado para disco local: `/boot/iso`, somente quando espaço livre e política de montagem permitem. `/mnt/sdcard` funciona como mídia externa, não como armazenamento local confiável; manifesto registra UUID real da partição.

### 5.2 Perfis MVP

Criar renderizadores em `linux/boot/iso-profiles/`:

| Perfil | Detecção mínima | Estratégia |
|---|---|---|
| `archiso` | kernel/initramfs ArchISO e label | `img_dev`/`img_loop`, basedir e label derivados |
| `ubuntu-casper` | `/casper/vmlinuz` + initrd | `boot=casper` + caminho ISO |
| `debian-live` | `/live/vmlinuz*` + initrd | `boot=live` + `findiso` |
| `grml` | layout/label Grml | parâmetros Grml compatíveis com upstream |
| `systemrescue` | layout ArchISO/SystemRescue | adaptador dedicado, não alias cego de Arch |

Perfis Fedora/openSUSE/Windows ficam fora do MVP até fixture e boot real. Windows installer por loopback costuma exigir tratamento próprio; não declarar suporte por analogia.

Cada perfil implementa:

- `detect` com evidências;
- `validate` de arquivos internos;
- `render` de kernel, initrd e cmdline;
- `capabilities` e limitações;
- fixtures com nomes contendo espaço, aspas e Unicode.

`grml-rescueboot` será compatibilidade opcional:

- detectar pacote/script existente;
- importar apenas entradas Grml;
- não instalar pacote Debian em Arch;
- não duplicar ISO já gerenciada pelo PhaseZero.

### 5.3 Preflight

Bloquear registro quando:

- ISO não é arquivo regular;
- filesystem não possui UUID estável;
- filesystem/módulo não é legível pelo GRUB instalado;
- caminho passa por FUSE, overlay, GVFS ou montagem de rede;
- arquivo reside dentro de filesystem criptografado indisponível no preboot;
- kernel/initrd esperados não existem na ISO;
- perfil automático tem zero ou múltiplos matches;
- espaço/fragmentação apresenta limitação conhecida do módulo GRUB;
- hash mudou desde registro.

`inspect` usa `bsdtar`/`xorriso`/`isoinfo` de modo read-only. Dependência ausente vira blocker explícito, não instalação silenciosa.

## 6. Função 2 — chainload de mídia removível

### 6.1 Contrato CLI

```text
linux/pz boot usb status [--json]
linux/pz boot usb discover [--json]
linux/pz boot usb add DEVICE_OR_MOUNT [--id ID] [--title TITLE] [--dry-run]
linux/pz boot usb remove ID [--dry-run]
linux/pz boot usb install [--dry-run]
linux/pz boot usb next ID [--reboot]
```

`discover` mostra somente partições removíveis com `/EFI/BOOT/BOOTX64.EFI`. Sinal de removível combina `lsblk RM/TRAN/HOTPLUG`, árvore de blocos e mount source. Usuário escolhe uma. `add` registra UUID e hash do binário EFI para auditoria.

Entrada gerada:

- módulos de partição + filesystem detectado + `chain`;
- `search --fs-uuid` pelo UUID registrado;
- `chainloader ($removable)/EFI/BOOT/BOOTX64.EFI`;
- falha legível quando mídia ausente ou EFI alterado.

FAT32 recebe suporte principal. NTFS depende de módulo presente e teste. exFAT não será assumido suportado pelo GRUB host. Para mídia genérica exFAT/NTFS com ISOs soltas, usar Função 3.

### 6.2 Scanner genérico futuro

Somente promover após prova em QEMU/OVMF e hardware de que:

- ESP/root do host são excluídos por UUID;
- múltiplas mídias geram seleção determinística;
- fallback local não causa recursão;
- discos internos secundários não são tratados como removíveis;
- ausência de mídia retorna ao menu.

Até então, UUID registrado é comportamento suportado.

## 7. Função 3 — GRUB2 File Manager

### 7.1 Contrato CLI

```text
linux/pz boot grubfm status [--json]
linux/pz boot grubfm inspect PATH [--sha256 HEX] [--json]
linux/pz boot grubfm install --source PATH --sha256 HEX [--dry-run]
linux/pz boot grubfm remove [--dry-run]
linux/pz boot grubfm next [--reboot]
```

Sem subcomando `download` no MVP.

### 7.2 Instalação

1. Verificar arquivo regular, tamanho plausível e SHA-256 exato.
2. Validar PE/COFF `x86-64 EFI application` com `file`/`objdump`/`pesign` quando disponíveis.
3. Registrar origem local, hash, tamanho e data em `iso-artifacts.json`.
4. Detectar Secure Boot com `mokutil --sb-state` e variáveis EFI.
5. Se Secure Boot ativo, exigir assinatura já confiável e verificável; caso contrário bloquear com instrução manual. Não desligar Secure Boot.
6. Copiar atomicamente para `/EFI/PhaseZero/grubfm/grubfmx64.efi`.
7. Gerar `/etc/grub.d/48_phasezero_grubfm` buscando ESP local por UUID.
8. Rodar `grub-mkconfig` e confirmar `phasezero-grubfm`.
9. Não alterar NVRAM, fallback EFI ou loader ativo.

UI mostra riscos:

- upstream arquivado;
- compatibilidade ISO não garantida;
- payload ganha acesso preboot aos discos visíveis;
- Secure Boot pode impedir chainload;
- teste obrigatório antes de depender dele como única recuperação.

## 8. Transação, validação e rollback

### 8.1 Fluxo de escrita

1. `pz_boot_require_current_root_target`.
2. `pz_boot_preflight_grub`.
3. `pz_boot_validate_active_efi_safe`.
4. Validar manifesto e artefatos.
5. `pz_boot_backup_bundle "iso-boot-<action>"`.
6. Renderizar todos scripts em staging.
7. Executar `bash -n` nos scripts shell geradores.
8. Instalar arquivos atomicamente e modos corretos.
9. `pz_boot_refresh_grub_config /boot/grub/grub.cfg`.
10. `pz_boot_validate_grub_cfg_safe`.
11. Confirmar todos IDs esperados e ausência de `(hdN,gptN)`.
12. Revalidar EFI ativo.
13. Persistir ledger somente após sucesso.

Falha entre 8–12 restaura scripts/manifestos do backup e recompila GRUB novamente. Se restauração também falhar, preservar ambos logs e emitir recuperação manual; nunca apagar backup.

### 8.2 Remoção

`iso remove`, `usb remove` e `grubfm remove`:

- preview obrigatório na UI;
- removem só artefatos gerenciados;
- limpam `next_entry` quando aponta para item removido;
- regeneram GRUB;
- confirmam ausência do ID removido;
- preservam ISO e mídia do usuário.

## 9. One-shot, CLI e UI

### 9.1 `recovery.sh`

Estender:

```text
linux/pz boot choose iso:<id>
linux/pz boot choose usb:<id>
linux/pz boot choose grubfm
```

Aliases fixos `iso`, `usb` sem ID só funcionam quando existe exatamente uma opção elegível. Mais de uma retorna lista e erro, sem escolher silenciosamente.

`boot_choice_id` passa a resolver IDs dinâmicos pelo backend. `validate_next_entry` permanece obrigatório. `--dry-run` não exige root e mostra ID, blockers e reboot.

### 9.2 UI nativa

Alterar `linux/ui_native/boot_selector.py` e `linux/ui_native/pages/boot.py`:

- carregar `boot iso status --json`, `boot usb status --json` e `boot grubfm status --json`;
- mostrar ISOs registradas dinamicamente;
- mostrar USB registrado como indisponível quando desconectado;
- mostrar grubfm somente quando instalado, com badge Experimental;
- desabilitar ação com motivo quando hash, mídia ou Secure Boot bloqueiam;
- manter Linux normal selecionado por padrão;
- confirmação extra para `Agendar + reiniciar` em payload experimental.

Catálogo recebe ações:

```text
boot.iso.status
boot.iso.add
boot.iso.install
boot.usb.discover
boot.usb.add
boot.usb.install
boot.grubfm.status
boot.grubfm.install
boot.grubfm.remove
```

Toda ação mutável exige preview. `linux/ui/actions.json` continua gerado por `linux/ui/generate_actions.py`; não editar saída isoladamente.

## 10. Doctor e diagnóstico

Adicionar checks em `linux/audit/doctor.sh`:

- `BOOTISO01`: manifesto válido;
- `BOOTISO02`: scripts gerados equivalem ao manifesto;
- `BOOTISO03`: ISOs acessíveis, hashes atuais e perfis válidos;
- `BOOTUSB01`: mídias registradas e EFI verificável;
- `BOOTFM01`: artefato/hash/arquitetura grubfm;
- `BOOTFM02`: compatibilidade Secure Boot;
- `BOOTCFG01`: IDs esperados presentes, sem ordinais de disco.

`repair-plan.sh` só sugere comandos PhaseZero com `--dry-run`. Nunca reinstala grubfm ou atualiza hash automaticamente.

## 11. Testes

### 11.1 Testes estáticos e unitários

Expandir `tests/linux-boot-recovery.sh` e criar `tests/linux-iso-boot.sh`:

- `bash -n` em backend e geradores;
- parse/schema v1 válido e inválido;
- escape de título/path com espaço, aspas, `$`, `;`, newline e Unicode;
- renderização por UUID;
- ausência de `(hd[0-9]`, `gpt[0-9]` e `/dev/sdX` no resultado;
- IDs estáveis e sem colisão;
- ISO alterada bloqueia `next`;
- USB ausente falha sem mudar `grubenv`;
- `/EFI/BOOT/BOOTX64.EFI` local não vira alvo USB;
- Secure Boot ativo bloqueia grubfm não confiável;
- dry-run não escreve;
- rollback restaura estado após falha simulada de `grub-mkconfig`;
- remoção preserva ISO do usuário.

Fixtures mínimas ISO podem ser árvores simuladas. Testes que exigem ISO real usam artefato pequeno produzido localmente; CI não baixa imagens de terceiros.

### 11.2 UI

Expandir `tests/test_linux_native_ui.py`:

- catálogo possui previews para mutações;
- lista dinâmica renderiza zero, uma e várias ISOs;
- mídia desconectada aparece desabilitada;
- grubfm mostra badge/aviso experimental;
- schema futuro cai para read-only;
- comando usa admin bridge e argumentos separados, nunca shell concatenado.

### 11.3 Integração QEMU/OVMF

Criar teste opcional marcado `requires-ovmf`:

- GRUB gerado inicia em OVMF;
- entrada ISO encontra UUID e abre kernel/initrd fixture;
- chainload EFI registrado transfere controle;
- mídia ausente retorna ao menu;
- grubfm é chainloaded somente com fixture explicitamente fornecida;
- host fallback não recursa.

### 11.4 Aceitação em hardware

Executar com backup e rota de recuperação já validada:

1. Boot normal permanece funcional.
2. ISO Arch conhecida inicia e encontra squashfs.
3. ISO Ubuntu conhecida inicia ambiente live.
4. USB preparado chainload por UUID inicia seu próprio loader.
5. grubfm lista USB/SD e inicia ao menos uma ISO compatível.
6. Remover USB mostra falha controlada.
7. Trocar ordem física dos discos não altera resultado.
8. `next_entry` é consumido uma vez; boot seguinte volta ao default.

Sucesso de menu/chainload não equivale a sucesso da ISO. Registrar resultado por perfil e versão.

## 12. Arquivos previstos

| Arquivo | Mudança |
|---|---|
| `linux/boot/iso-boot.sh` | backend, manifesto, renderização, transações e CLI |
| `linux/boot/iso-profiles/*.sh` | adaptadores tipados por família ISO |
| `linux/lib/common.sh` | identidade de arquivo, escape GRUB, Secure Boot, atomicidade |
| `linux/boot/recovery.sh` | dispatch e one-shot dinâmico |
| `linux/pz` | help e roteamento dos novos comandos |
| `linux/audit/doctor.sh` | checks BOOTISO/BOOTUSB/BOOTFM |
| `linux/audit/repair-plan.sh` | reparos seguros e previews |
| `linux/ui/generate_actions.py` | ações canônicas |
| `linux/ui/actions.json` | saída regenerada |
| `linux/ui_native/catalog.py` | ações, badges e previews |
| `linux/ui_native/boot_selector.py` | opções dinâmicas |
| `linux/ui_native/pages/boot.py` | gestão de ISO/USB/grubfm |
| `tests/linux-iso-boot.sh` | backend e segurança |
| `tests/linux-boot-recovery.sh` | dispatch, one-shot e invariantes |
| `tests/test_linux_native_ui.py` | catálogo e estados UI |
| `docs/capabilities.md` | comandos e limitações suportadas |

## 13. Sequência de implementação

### Fase A — contrato e segurança

- [ ] Fixar schema JSON v1, IDs e códigos de saída.
- [ ] Implementar helpers de escape, identidade, filesystem e Secure Boot.
- [ ] Criar fixtures maliciosas e testes fail-closed antes do renderizador.
- [ ] Definir suporte real de módulos GRUB do host em status JSON.

### Fase B — ISO local

- [ ] Implementar `inspect/scan/add/remove/status` sem mutação GRUB.
- [ ] Implementar perfis ArchISO, Ubuntu Casper, Debian Live, Grml e SystemRescue.
- [ ] Implementar renderização `46_phasezero_iso_loopback`.
- [ ] Implementar transação install/refresh/rollback.
- [ ] Certificar duas famílias em QEMU antes de expor `next` na UI.

### Fase C — removível registrado

- [ ] Implementar descoberta de mídia e exclusão do host.
- [ ] Implementar registro por UUID e hash EFI.
- [ ] Renderizar `47_phasezero_removable_efi`.
- [ ] Testar ausência, múltiplas mídias e mudança de ordem.

### Fase D — grubfm experimental

- [ ] Implementar inspect local e política SHA-256.
- [ ] Implementar gate Secure Boot.
- [ ] Copiar artefato para namespace PhaseZero sem tocar fallback.
- [ ] Renderizar `48_phasezero_grubfm`.
- [ ] Testar chainload QEMU e hardware; manter opt-in mesmo após sucesso.

### Fase E — integração PhaseZero

- [ ] Estender `linux/pz`, `recovery.sh`, doctor e repair-plan.
- [ ] Estender catálogo, página Boot e seletor visual.
- [ ] Regenerar `actions.json`.
- [ ] Documentar matriz de suporte e procedimento de remoção.

### Fase F — certificação

- [ ] Rodar testes shell/UI existentes e novos.
- [ ] Rodar OVMF com fixtures.
- [ ] Fazer backup real e validar cartão/EFI fallback PhaseZero.
- [ ] Rodar aceitação em hardware sem mudar default permanente.
- [ ] Publicar relatório por ISO, perfil, filesystem e estado Secure Boot.

## 14. Defesa em profundidade Btrfs — trilha separada

Anexo propõe `snapper`, `snap-pac` e `grub-btrfs`. Valor alto, escopo diferente. Não misturar com MVP ISO porque envolve layout de subvolumes, retenção, rollback e pacotes do host.

Plano posterior deve:

- detectar Btrfs e confirmar `@`/`@home`; nunca presumir;
- bloquear migração destrutiva automática;
- snapshotar somente root quando objetivo é preservar `/home`;
- definir retenção, quota e limpeza antes de habilitar `snap-pac`;
- testar boot de snapshot e promoção/rollback separadamente;
- manter ISO de resgate como segunda camada;
- proibir script de reinstalação/format unattended;
- exigir confirmação humana por UUID antes de qualquer operação destrutiva.

Boot ISO funciona mesmo sem Btrfs. Snapshots não substituem recuperação contra corrupção física do disco.

## 15. Critérios de conclusão

Entrega só fica concluída quando:

- três funções possuem status, preview, install/remove e one-shot;
- nenhuma entrada usa ordinal de disco;
- nenhuma edição direta de `grub.cfg` existe;
- toda mutação recompila e valida GRUB;
- rollback foi testado com falha injetada;
- Secure Boot bloqueia payload não confiável;
- UI não oferece ação impossível;
- ISO local e USB chainload passam em hardware;
- grubfm permanece claramente experimental;
- boot normal e recuperação PhaseZero continuam certificados.

## 16. Referências verificadas

- GRUB2 File Manager upstream arquivado: <https://github.com/a1ive/grub2-filemanager>
- grml-rescueboot upstream: <https://github.com/grml/grml-rescueboot>
- ArchWiki GRUB: <https://wiki.archlinux.org/title/GRUB>
- ArchWiki systemd-boot, seção de imagem de recuperação/Secure Boot: <https://wiki.archlinux.org/title/Systemd-boot>
