# Implementação: Otimizador por Jogo (Emulator-Specific Config Writer)

## Objetivo

Criar sistema que escreve arquivos de configuração nativos de emuladores (INI, YAML, .pnach) por jogo, aplicando otimizações documentadas em 14 entradas de análise de vídeos.

## Escopo

- **Não** criar CLI unificada ou presets
- **Não** modificar sistema de perfil adaptativo existente (`performance.sh`/`performance-launch.sh`)
- **Sim** criar scripts que escrevem configs diretamente nos formatos nativos de cada emulador (DuckStation `.ini`, PCSX2 `.ini`, Dolphin `.ini`)

## Arquitetura

### Árvore de diretórios a criar

```
linux/emulation/
  optimizers/                    <-- NOVO diretório
    duckstation.sh               # Lógica DuckStation (PS1)
    pcsx2.sh                     # Lógica PCSX2 (PS2)
    dolphin.sh                   # Lógica Dolphin (Wii)
  optimizers.sh                  <-- NOVO entrypoint que delega para os acima
```

### Integração CLI (`linux/pz`)

Adicionar ao `cmd_emulation()` em `linux/pz`:

```bash
optimizer|optimize|game-optimizer)
    bash "$PZ_ROOT/linux/emulation/optimizers.sh" "${target:-status}" "${extra[@]}"
    ;;
```

Isso permite:

```bash
pz emulation optimizer status          # listar configs por jogo
pz emulation optimizer apply <game-id> # aplicar config de um jogo
pz emulation optimizer apply-all       # aplicar todos registrados
```

## Estrutura do Script

### `optimizers.sh` — Entrypoint

Segue padrão PhaseZero: `source common.sh`, dispatch por ACTION.

```bash
#!/usr/bin/env bash
# optimizers.sh - game-specific emulator optimization configs
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
GAME_ID="${2:-}"

OPTIMIZERS_DIR="$PZ_ROOT/linux/emulation/optimizers"

case "$ACTION" in
    status|list)      list_optimizations ;;
    apply)            apply_optimization "$GAME_ID" ;;
    apply-all)        apply_all_optimizations ;;
    *)                pz_error "usage: optimizers.sh (status|list|apply <game-id>|apply-all)"; exit 2 ;;
esac
```

### `optimizers/duckstation.sh` — DuckStation (PS1)

Contém:
- `duckstation_game_config_path(serial)` → `GameSettings/<SERIAL>.ini`
- `duckstation_apply(serial, settings)` — usa `ini_set()` do `sony.sh`

Jogos atendidos:
- Jackie Chan Stuntmaster (#007)
- Metal Gear Solid (#012)

### `optimizers/pcsx2.sh` — PCSX2 (PS2)

Contém:
- `pcsx2_game_config_path(crc)` → `inis/GameSettings/<CRC>.ini`
- `pcsx2_pnach_path(crc)` → `patches/<CRC>.pnach`
- `pcsx2_textures_path(serial)` → `storage/pcsx2/textures/<SERIAL>/`
- `pcsx2_apply(crc, serial, settings)`

Jogos atendidos:
- GTA San Andreas (#001, #002)
- God of War I (#003)
- Resident Evil 4 (#004)
- God of War II (#005)
- DBZ Budokai Tenkaichi 3 (#006)
- MK Shaolin Monks (#008)
- Crash Twinsanity (#009)
- Onimusha 3 (#013)

### `optimizers/dolphin.sh` — Dolphin (Wii)

Contém:
- `dolphin_game_config_path(game_id)` → `User/GameSettings/<GAME_ID>.ini`
- `dolphin_textures_path(game_id)` → `Load/Textures/<GAME_ID>/`
- `dolphin_wiimote_profile_path()` → `User/Config/Profiles/Wiimote/<profile>.ini`
- `dolphin_apply(game_id, settings)`

Jogos atendidos:
- Super Mario Galaxy (#010)
- Super Mario Galaxy 2 (#011)
- Donkey Kong Country Returns (#014)

## Funções Compartilhadas (usar `ini_set()` do `sony.sh` ou mover para `common.sh`)

**Recomendação:** Mover `ini_set()` de `sony.sh` (linhas 17-51) para `common.sh` como `pz_ini_set()` para todos os scripts consumirem.

```bash
# common.sh - adicionar:
pz_ini_set() {
    local file="$1" section="$2" key="$3" value="$4" tmp
    install -d "$(dirname "$file")"
    [ -f "$file" ] || printf '[%s]\n' "$section" > "$file"
    cp "$file" "${file}.bak.$(date +%s)" 2>/dev/null || true
    tmp="$(mktemp)"
    awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN { in_section = 0; done = 0 }
        $0 == "[" section "]" { in_section = 1; print; next }
        /^\[/ {
            if (in_section && !done) { print key " = " value; done = 1 }
            in_section = 0; print; next
        }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            print key " = " value; done = 1; next
        }
        { print }
        END {
            if (!done) {
                if (!in_section) { print "[" section "]" }
                print key " = " value
            }
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}
```

## Database de Configurações (14 Entradas)

Cada entrada deve ser registrada como função nomeada no optimizer do emulador correspondente.

### DuckStation (#007, #012)

```bash
duckstation_apply_jackie_chan() {
    local serial="${1:-SLUS-01234}"  # TODO: confirmar serial correto
    duckstation_apply "$serial" \
        "Graphics.ResolutionScale=5" \
        "Graphics.PGXPEnable=true" \
        "Console.CpuOverclockEnable=true" \
        "Console.CpuOverclockPercent=300"
}

duckstation_apply_mgs() {
    duckstation_apply "SLUS-00594" \
        "Graphics.ResolutionScale=5" \
        "Graphics.AspectRatio=16:9" \
        "Graphics.WidescreenHack=true" \
        "Graphics.PGXPEnable=true" \
        "Graphics.PGXPCpuMode=true" \
        "Graphics.Antialiasing=8" \
        "Console.CpuOverclockEnable=true" \
        "Console.CpuOverclockPercent=200"
    # Espelhar para disco 2
    duckstation_apply "SLUS-00776" \
        "Graphics.ResolutionScale=5" \
        "Graphics.AspectRatio=16:9" \
        "Graphics.WidescreenHack=true" \
        "Graphics.PGXPEnable=true" \
        "Graphics.PGXPCpuMode=true" \
        "Graphics.Antialiasing=8" \
        "Console.CpuOverclockEnable=true" \
        "Console.CpuOverclockPercent=200"
}
```

### PCSX2 (#001-006, #008, #009, #013)

```bash
pcsx2_apply_gta_sa() {
    # #001 GTA San Andreas baseline
    # #002 GTA SA Módulo II (pós-processamento)
    local crc="${1:-}" serial="${2:-SLUS-20946}"
    pcsx2_apply "$crc" "$serial" \
        "EmuCore.Speedhacks.EECycleRate=1" \
        "EmuCore.Speedhacks.EECycleSkip=0" \
        "EmuCore.Speedhacks.fastCDVD=true" \
        "EmuCore.Speedhacks.IntcStat=true" \
        "EmuCore.Speedhacks.WaitLoop=true" \
        "EmuCore.Speedhacks.vuFlagHack=true" \
        "EmuCore.Speedhacks.vuThread=true" \
        "EmuCore.Speedhacks.mvuFlag=true" \
        "Graphics.UpscaleMultiplier=4" \
        "Graphics.FXAA=true" \
        "Graphics.LoadTextures=true" \
        "Graphics.AspectRatio=Widescreen169"
}

# ... (idem para cada jogo)
```

### Dolphin (#010, #011, #014)

```bash
dolphin_apply_smg1() {
    local game_id="${1:-RMGE01}"
    dolphin_apply "$game_id" \
        "Video_Enhancements.InternalResolution=3" \
        "Video_Enhancements.MaxAnisotropy=4" \
        "Video_Enhancements.AASamples=3" \
        "Video_Hacks.EFBCopyTexturesSource=False" \
        "Video_Hardware.ShaderCompilationMode=2" \
        "Video_Textures.LoadCustomTextures=True" \
        "Video_Textures.PrefetchCustomTextures=True"
}

dolphin_apply_smg2() {
    local game_id="${1:-SB4E01}" has_gpu="${2:-true}"
    # ⚠️ CRÍTICO: SMG2 NUNCA usa MSAA!
    local aa_mode=0 aa_samples=0
    if [ "$has_gpu" = "true" ]; then
        aa_mode=1 aa_samples=2  # SSAA 4x
    fi
    dolphin_apply "$game_id" \
        "Video_Enhancements.InternalResolution=3" \
        "Video_Enhancements.MaxAnisotropy=4" \
        "Video_Enhancements.AAMode=$aa_mode" \
        "Video_Enhancements.AASamples=$aa_samples" \
        "Video_Hacks.XFBCopyTexturesSource=False" \
        "Video_Hardware.ShaderCompilationMode=2" \
        "Video_Textures.LoadCustomTextures=True" \
        "Video_Textures.PrefetchCustomTextures=True"
}

dolphin_apply_dkc_returns() {
    local game_id="${1:-SF8E01}"
    dolphin_apply "$game_id" \
        "Video_Enhancements.InternalResolution=3" \
        "Video_Enhancements.MaxAnisotropy=4" \
        "Video_Enhancements.AASamples=3" \
        "Video_Enhancements.AspectRatio=3" \
        "Video_Hardware.ShaderCompilationMode=2" \
        "Video_Textures.LoadCustomTextures=True" \
        "Video_Textures.PrefetchCustomTextures=True"
}
```

## Dados de Configuração (Registro Completo)

### #001 — GTA San Andreas (PCSX2, SLUS-20946)
- Upscale: 4x (1440p)
- EE: 180%
- FXAA: true
- Textures: LoadTextures=true
- Aspect: Widescreen 16:9
- Patches: widescreen.pnach, progressive.pnach

### #002 — GTA SA Módulo II (PCSX2, SLUS-20946)
Add ao #001:
- ColorBoostBrightness=60
- ColorBoostSaturation=45
- .pnach sem BOM

### #003 — God of War I (PCSX2, SCUS-97399)
- Upscale: 4x (1440p)
- Widescreen: true
- Progressive: true
- AsyncTextures: true (seguro)
- **Não** usar widescreen .pnatch

### #004 — Resident Evil 4 (PCSX2, SLUS-21134)
- MipMapping: OFF
- AsyncTextures: OFF (quebra engine)
- Widescreen: patch + in-game
- Aspect: Widescreen 16:9

### #005 — God of War II (PCSX2, SCUS-97481)
- AsyncTextures: true (seguro)
- **Não** usar widescreen patch (distorce framing)
- Progressive: true

### #006 — DBZ Budokai Tenkaichi 3 (PCSX2, SLUS-21678)
- Manual HW Fixes: CLUT, SkipDraw[3,3], TextureOffset 448/512
- EE: 300%
- Cheats dir: `/cheats/<CRC>.pnach` (não `/patches/`)
- EnableCheats: true

### #007 — Jackie Chan Stuntmaster (DuckStation)
- PGXP: true
- 5x native
- CPU OC: 300%
- Config: `settings.ini` formato DuckStation

### #008 — MK Shaolin Monks (PCSX2)
- SkipDraw[1,1]
- ColorBoostBrightness=60, ColorBoostGamma=60
- AsyncTextures: true (seguro)

### #009 — Crash Twinsanity (PCSX2)
- **Even multiplier only**: 2x ou 4x (nunca 3x/5x)
- DitherMode=2
- AsyncTextures: true (seguro)

### #010 — Super Mario Galaxy (Dolphin, RMGE01)
- InternalResolution: 3x (1080p)
- AASamples: 3 (8x MSAA)
- EFBCopyTexturesSource: false
- ShaderCompilationMode: 2
- LoadCustomTextures: true, Prefetch: true
- Input: Classic Controller, cursor = R Analog, star = R1

### #011 — Super Mario Galaxy 2 (Dolphin, SB4E01)
- InternalResolution: 3x
- **MSAA PROIBIDO** — usar SSAA ou Nenhum
- AAMode: 1 (SSAA), AASamples: 2 (4x) se GPU forte, senão 0
- XFBCopyTexturesSource: false
- Input: idêntico SMG1

### #012 — Metal Gear Solid (DuckStation, SLUS-00594 + SLUS-00776)
- ResolutionScale: 5
- AspectRatio: 16:9
- WidescreenHack: true
- PGXPEnable: true, PGXPCpuMode: true
- Antialiasing: 8 (8x MSAA)
- CPU OC: 200% (limite — exceder quebra IA)

### #013 — Onimusha 3: Demon Siege (PCSX2, SLUS-20694)
- Upscale: 4x (1440p)
- Aspect: Widescreen 16:9
- FXAA: true
- ColorClipBoost: true, Brightness: 55
- AsyncTextures: true (seguro)
- Patches: widescreen + no-interlacing

### #014 — Donkey Kong Country Returns (Dolphin, SF8E01)
- InternalResolution: 3x
- AASamples: 3 (8x MSAA)
- AspectRatio: 3 (Esticar)
- Input: Shaking → R2

## Ordern de Implementação

1. **Mover `ini_set()`** de `sony.sh` para `common.sh` como `pz_ini_set()`
2. **Criar `optimizers/duckstation.sh`** — mais simples (só 2 jogos)
3. **Criar `optimizers/pcsx2.sh`** — mais complexo (9 jogos, .pnach)
4. **Criar `optimizers/dolphin.sh`** — médio (3 jogos, input profile)
5. **Criar `optimizers.sh`** — entrypoint
6. **Registrar no `linux/pz`** — adicionar `optimizer` ao `cmd_emulation()`

## Verificação

```bash
# Testar sem modificar configs reais (dry-run inicial)
pz emulation optimizer list         # deve mostrar 14 entradas
pz emulation optimizer apply SMG1   # escreve RMGE01.ini
pz emulation optimizer apply-all    # escreve todos
```
