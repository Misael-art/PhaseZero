# Otimizador por jogo — implementação Linux

Status: implementado e integrado.

## Contrato

`linux/emulation/optimizers.sh` registra 14 entradas e delega escrita nativa:

- DuckStation: `linux/emulation/optimizers/duckstation.sh`
- PCSX2: `linux/emulation/optimizers/pcsx2.sh`
- Dolphin: `linux/emulation/optimizers/dolphin.sh`

Escrita INI usa `pz_ini_set()` de `linux/emulation/common.sh`. A função preserva outras seções, atualiza chaves idempotentemente e cria diretórios ausentes. Configuração local nunca baixa ROM, BIOS, firmware, patch ou textura.

## CLI

```bash
linux/pz emulation optimizer status
linux/pz emulation optimizer plan
linux/pz emulation optimizer apply metal-gear-solid
linux/pz emulation optimizer apply-all
```

`status` retorna JSON. `plan` não altera arquivos. `apply` aceita um ID. `apply-all` é executado automaticamente por `linux/pz emulation setup`; o dry-run do setup apenas lista o plano.

## Registro

| ID | Emulador | Jogo / perfil |
|---|---|---|
| `jackie-chan` | DuckStation | Jackie Chan Stuntmaster (`SLUS-00684`) |
| `metal-gear-solid` | DuckStation | Metal Gear Solid (`SLUS-00594`, `SLUS-00776`) |
| `gta-san-andreas` | PCSX2 | GTA San Andreas (`SLUS-20946`) |
| `gta-san-andreas-module-2` | PCSX2 | GTA San Andreas Module II (`SLUS-20946`) |
| `god-of-war` | PCSX2 | God of War (`SCUS-97399`) |
| `resident-evil-4` | PCSX2 | Resident Evil 4 (`SLUS-21134`) |
| `god-of-war-2` | PCSX2 | God of War II (`SCUS-97481`) |
| `dbz-budokai-tenkaichi-3` | PCSX2 | DBZ Budokai Tenkaichi 3 (`SLUS-21678`) |
| `mk-shaolin-monks` | PCSX2 | Mortal Kombat Shaolin Monks (`SLUS-21087`) |
| `crash-twinsanity` | PCSX2 | Crash Twinsanity (`SLUS-20909`) |
| `onimusha-3` | PCSX2 | Onimusha 3 (`SLUS-20694`) |
| `super-mario-galaxy` | Dolphin | Super Mario Galaxy (`RMGE01`) |
| `super-mario-galaxy-2` | Dolphin | Super Mario Galaxy 2 (`SB4E01`) |
| `donkey-kong-country-returns` | Dolphin | Donkey Kong Country Returns (`SF8E01`) |

## Roots portáveis

Ordem de detecção:

- DuckStation: `$XDG_CONFIG_HOME/duckstation`, depois Flatpak `org.duckstation.DuckStation`.
- PCSX2: `$XDG_CONFIG_HOME/PCSX2`, depois Flatpak `net.pcsx2.PCSX2`.
- Dolphin: `$XDG_CONFIG_HOME/dolphin-emu`, depois Flatpak `org.DolphinEmu.dolphin-emu`.

Arquivos são gravados em `GameSettings/<serial>.ini` ou `inis/GameSettings/<serial>.ini`, conforme contrato do emulador.

## Garantias verificadas

- 14 entradas retornadas pelo registro.
- Aplicação individual e integral.
- Reaplicação sem duplicar chave.
- MGS cobre ambos os discos.
- SMG2 usa SSAA; MSAA não é habilitado.
- Resident Evil 4 mantém carregamento assíncrono desligado.
- Crash Twinsanity usa escala par 4x.

Teste automatizado: `tests/linux-emulation-optimizers.sh`.
