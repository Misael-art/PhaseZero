# ROM Optimizer (romopt) - Implementation Plan

> **Revision 2026-07-09** — validated against codebase + host. Corrections applied:
> (1) deps table: `dolphin-tool` is `dolphin-emu-tool` (not `dolphin-emu`); `maxcso` is a `pacman` binary (not pip); `file` is its own package (not coreutils). (2) NSZ: project's `nsz.sh` only *decompresses* (`-D`); `convert_nsz` (`nsz -C`) is net-new, not a reuse. (3) CHD/CUE: `chdman createcd` produces a self-contained .chd — delete .cue/.bin after verify, do NOT rewrite CUE to "point at" .chd. (4) DAT URLs: both `datomatic.redump.org` and No-Intro's GET `?file=` form are non-functional; v1 = user-supplied DATs only. (5) layout dirs note added (only `.phasezero/backups` is canonical today). (6) Phase numbering fixed (4/5/6 no longer reuse 3.x/4.x/5.x step numbers). (7) Duplicate manifest JSON block in §4.10 removed.

## 1. Problem Summary

Emulation users accumulate ROMs in mixed formats — raw ISOs/BINs in ZIP/7z archives, outdated compressed formats (CSO, WBFS), and uncompressed disc images. No single tool exists that:

- Scans directories recursively
- Detects platform per-ROM via magic bytes + filename + directory context
- Decides the optimal format per platform (CHD for disc systems, CSO/ZSO for PSP, RVZ for Wii/GC, NSZ for Switch)
- Converts atomically with integrity verification
- **Recompress ZIP archives of cartridge systems at max deflate level 9**
- Renames to Redump naming standard
- Cleans up source files only after full verification

## 2. Design Goals

| Goal | Priority |
|---|---|---|
| Zero data loss — never delete source before verify | P0 (hard) |
| Platform detection without user hints | P0 |
| Idempotent — skip already-optimal formats | P0 |
| Dry-run mode | P0 |
| Extensible format/decision table | P1 |
| Atomic staging + manifest journal | P1 |
| Profile system (speed/balanced/archive) | P2 |
| ZIP max compression for cartridge systems | P2 |
| Parallel conversion per platform | P3 |

## 3. Architecture

```
pz emulation rom-optimize <path> [--profile <speed|balanced|archive>]
                                [--dry-run] [--json <file>] [--keep-original]
                                [--platform ps1|psp|...]
```

Backed by `linux/emulation/romopt/` — Python CLI tool (`romopt.py`) wrapping CLI tools (`chdman`, `dolphin-tool`, `maxcso`, `nsz`), or shell script following `nsz.sh` pattern. **Recommendation: Python** — easier tool detection, JSON handling, decision tree, and parallel processing.

### 3.1 Entrypoint in pz

Add to `linux/pz` `cmd_emulation()`:

```bash
rom-optimize|romopt)
    bash "$PZ_ROOT/linux/emulation/romopt.sh" "${extra[@]}"
    ;;
```

And in `usage()`:

```
  pz emulation rom-optimize <path> [--profile speed|balanced|archive] [--dry-run]
                                     Optimize ROM compression format per-platform. See plans/romopt-implementation.md
```

### 3.2 File Tree

```
linux/emulation/romopt/
├── __init__.py
├── main.py                  # CLI entrypoint, arg parsing, orchestration
├── detect.py                # Platform detection (magic + ext + dir)
├── decision.py              # Decision tree: target format per platform + profile
├── convert.py               # Wrappers: chdman, dolphin-tool, maxcso, nsz
├── verify.py                # Post-conversion integrity checks
├── rename.py                # Redump naming + serial extraction
├── profile.py               # Speed/balanced/archive config classes
├── clean.py                 # Source removal after verified conversion
├── manifest.py              # JSON manifest read/write
└── tools.py                 # External tool discovery + version check
```

Optional: wrapper `linux/emulation/romopt.sh` for pz integration (similar to nsz.sh).

### 3.3 External Dependencies

| Tool | Package | Required For |
|---|---|---|
| `chdman` | `mame-tools` (arch `extra`; provides `/usr/bin/chdman`) | CHD create/verify — PS1, PS2, DC, Saturn |
| `dolphin-tool` | `dolphin-emu-tool` (arch `extra` — NOT `dolphin-emu`, which is the full emulator) | RVZ convert/verify — Wii, GC |
| `maxcso` | `maxcso` (arch `extra` 1.13.0-3 — compiled C binary, **NOT a pip package**) | CSO/ZSO create — PSP |
| `nsz` | `pip install nsz` | NSZ compress (`-C`) — Switch. NOTE: project's `nsz.sh` only *decompresses* (`-D`); compression is net-new here |
| `7z` | `p7zip` | Archive extraction |
| `file` | `file` (separate package, provides `libmagic.so=1-64` — **NOT coreutils**) | Magic byte detection |
| `sha256sum` | coreutils | Integrity verification |
| `zipfile` | stdlib (Python) | ZIP recompress (cartridge ROMs) |
| `ffmpeg` | `ffmpeg` | Lossy audio conversion (profile: archive) |

### 3.4 New Layout Directories

Add to `pz_emulation_layout_dirs()` in `linux/emulation/common.sh`:

```
$PZ_EMULATION_ROOT/metadata/rom-optimizer          # conversion manifests
$PZ_EMULATION_ROOT/.phasezero/staging/rom-optimizer # staging area
$PZ_EMULATION_ROOT/.phasezero/quarantine/rom-optimizer # failed sources
$PZ_EMULATION_ROOT/tools/rom-optimizer               # tool wrappers
```

**Note on existing state:** only `.phasezero/backups` is currently declared in `pz_emulation_layout_dirs()` (common.sh:232). `staging/` and `quarantine/` are NOT in the canonical layout — `nsz.sh` creates `.phasezero/quarantine/nsz` and a `.phasezero-staging/` (different name) ad-hoc at runtime. Adding these four rom-optimizer dirs to the declared canonical layout is net-new and consistent with the media-clean backup dir pattern already established. Reuse the `metadata/<tool>/` manifest convention from `metadata/switch/nsz-conversions/`.

---

## 4. Detailed Module Specs

### 4.1 `detect.py` — Platform Detection

Three-strategy cascade, returning `(platform: str, format: str, confidence: float)`.

**Strategy A: Magic Bytes** (highest confidence, ~0.95)

| Magic/Signature | Platform | Format |
|---|---|---|
| `PS-X` at offset 0x8000 (CD001 sector) | PS1 | ISO/BIN |
| `PLAYSTATION` header string | PS1 | BIN |
| `CISO` at offset 0 | PSP (CSO) | CSO |
| `ZISO` at offset 0 | PSP (ZSO) | ZSO |
| `PFS0` at offset 0 | Switch | NSP |
| `HEADER` at offset 0 (Wii disc) | Wii | ISO |
| `GCM` at offset 0 (GameCube) | GC | ISO |
| `SEGA SEGAKATANA` (Dreamcast) | DC | GDI |
| `Saturn` (SATURN header) | Saturn | ISO |
| `PSP GAME` at boot sector | PSP | ISO |
| `MComprHD` | PS2 | CHD |
| `MCompr` | any MAME | CHD |
| RVZ magic bytes `0x52 0x56 0x5A` | Wii/GC | RVZ |
| `WBFS` magic | Wii | WBFS |
| `NKit2` magic | Wii/GC/Switch | NKIT |
| ELF header `\x7fELF` + `NRO` at offset 0x10 | Switch | NRO |
| 3DS header `NCSD` | 3DS | 3DS |
| CIA header | 3DS | CIA |

**Strategy B: Extension** (medium confidence, ~0.80)

| Extension | Platform |
|---|---|
| `.psx.iso`, `.ps1.iso`, `.psx.bin` | PS1 |
| `.ps2.iso` | PS2 |
| `.psp.iso`, `.psp.cso`, `.psp.zso` | PSP |
| `.gc.iso`, `.gcm` | GC |
| `.wii.iso`, `.wbfs` | Wii |
| `.dc.iso`, `.gdi`, `.cdi` (size-based) | DC |
| `.wua`, `.wud`, `.wux` | Wii U |
| `.nsz` | Switch (NSZ) |
| `.nsp` | Switch (NSP) |
| `.xci` | Switch (XCI) |
| `.vpk` | Vita |
| `.pkg` (small file) | PS3/Vita |
| `.rvz` | Wii/GC (RVZ) |
| `.chd` | Universal (depends on size) |
| `.cso`, `.zso` | PSP |
| `.pbp` | PSP/PS1 |
| `.3ds`, `.cia` | 3DS |
| `.nds` | NDS |
| `.cue` with `.bin` > 400MB | PS1, DC, Saturn, Mega CD, PCE-CD, 3DO |
| `.mdf` | PS2, Saturn |
| `.nrg` | PS2 |
| `.ccd` + `.img` | PS1, DC |
| `.85` (FM Towns) | FM Towns |

**Strategy C: Parent Directory** (lower confidence, ~0.70 — fallback)

| Dir name pattern | Platform |
|---|---|
| `ps1`, `psx`, `playstation` | PS1 |
| `ps2` | PS2 |
| `ps3` | PS3 |
| `psp` | PSP |
| `psvita`, `vita`, `psv` | Vita |
| `dreamcast`, `dc` | Dreamcast |
| `saturn`, `ss` | Saturn |
| `megacd`, `segacd`, `megacdrom`, `segacdrom` | Mega CD / Sega CD |
| `pcengine`, `pce`, `pce-cd`, `tg-cd`, `tg16`, `turbografx` | PC Engine CD / TG16 |
| `neogeocd`, `ngcd` | Neo Geo CD |
| `3do` | 3DO |
| `pcfx` | PC-FX |
| `fmtowns`, `towns` | FM Towns |
| `jaguarcd`, `atarijaguarcd` | Atari Jaguar CD |
| `amigacd32`, `cd32` | Amiga CD32 |
| `gamecube`, `gc`, `ngc` | GC |
| `wii` | Wii |
| `wiiu` | Wii U |
| `switch`, `nsw` | Switch |
| `3ds` | 3DS |
| `nds`, `ds` | NDS |
| `ps4` | PS4 |

**Size heuristic** (low confidence, ~0.50 — used when nothing else matches raw .iso):

| Size Range | Platform |
|---|---|
| ~500-900 MB | PS1, DC, Saturn, PSP |
| ~1-2 GB | PSP (UMD), Saturn (extended) |
| ~4.37-4.7 GB (DVD) | PS2, Wii, Xbox |
| ~7-9 GB (double DVD) | Wii (some), Xbox 360 |
| ~15-50 GB (BD) | PS3, PS4, Xbox One |
| ~700 MB-8 GB | GC (varies by miniDVD) |

### 4.2 `decision.py` — Decision Tree

```python
# Systems with cartridge media — too small for CHD; ZIP deflate-9 is optimal
CARTRIDGE_SYSTEMS = {
    "nes", "snes", "n64", "n64dd",
    "gb", "gbc", "gba",
    "nds", "n3ds",
    "genesis", "megadrive", "mastersystem", "gamegear", "mark3",
    "fds", "famicom",
    "atari2600", "atari5200", "atari7800", "atarilynx", "atarijaguar",
    "colecovision", "vectrex", "intellivision",
    "msx", "msx2", "msxturbor",
    "ngp", "ws", "wsc",
    "c64", "zxspectrum",
    "pc88", "pc98", "x68000",
    "sg-1000", "atari7800portable",
    "vec", "prg",
}

# Systems with no compressed format available — skip
NO_COMPRESSION_SYSTEMS = {"ps3", "ps4", "psvita", "xbox", "xbox360", "wiiu", "windows", "steam"}

def target_format(platform: str, current_format: str,
                  profile: Profile, force: bool = False) -> Optional[str]:
    """Returns target format string or None if already optimal."""
    table = {
        'ps1': {
            'iso':     'chd',    # Always: CHD supports CDDA+subchannel+libcrypt
            'bin':     'chd',    # CHD bundles multi-track BINs
            'cue':     'chd',    # Same
            'img':     'chd',
            'pbp':     'chd',    # PBP loses subchannel; CHD superior
            'chd':     None,     # Already optimal
        },
        'ps2': {
            'iso':     'chd',
            'bin':     'chd',
            'img':     'chd',
            'cso':     'chd',    # PCSX2 dropped CSO; migrate to CHD
            'gz':      'chd',    # Scattered gz-compressed single files
            'chd':     None,
        },
        'psp': {
            'iso':     profile.psp_target,  # cso, zso, chd
            'cso':     profile.psp_target,  # Upgrade to ZSO if speed profile
            'zso':     None,                # Already fastest
            'pbp':     None,                # Already compressed (Sony format)
            'chd':     None,                # Already compressed (if user chose it)
        },
        'dreamcast': {
            'gdi':     'chd',
            'cdi':     'chd',
            'iso':     'chd',
            'bin':     'chd',
            'dax':     'chd',    # DAX legacy; CHD is current standard
            'chd':     None,
        },
        'saturn': {
            'iso':     'chd',
            'bin':     'chd',
            'cue':     'chd',
            'img':     'chd',
            'mdf':     'chd',
            'chd':     None,
        },
        'wii': {
            'iso':     'rvz',
            'wbfs':    'rvz',    # RVZ compresses better + purges padding
            'gcm':     'rvz',
            'ciso':    'rvz',    # CISO legacy; migrate
            'rvz':     None,
            'chd':     None,     # Legitimate alternative; leave unless force
        },
        'gc': {
            'iso':     'rvz',
            'gcm':     'rvz',
            'ciso':    'rvz',
            'gcz':     'rvz',    # Dolphin legacy format
            'rvz':     None,
            'chd':     None,
        },
        'megacd': {
            'iso':     'chd',
            'bin':     'chd',
            'cue':     'chd',
            'chd':     None,
        },
        'segacd': {},  # alias → megacd
        'pcengine': {
            'iso':     'chd',
            'bin':     'chd',
            'cue':     'chd',
            'chd':     None,
        },
        'tg16': {},      # alias → pcengine
        'neogeocd': {
            'iso':     'chd',
            'bin':     'chd',
            'cue':     'chd',
            'chd':     None,
        },
        '3do': {
            'iso':     'chd',
            'bin':     'chd',
            'cue':     'chd',
            'chd':     None,
        },
        'pcfx': {
            'iso':     'chd',
            'bin':     'chd',
            'cue':     'chd',
            'chd':     None,
        },
        'fmtowns': {
            'iso':     'chd',
            'bin':     'chd',
            'cue':     'chd',
            'chd':     None,
        },
        'jaguarcd': {
            'iso':     'chd',
            'bin':     'chd',
            'cue':     'chd',
            'chd':     None,
        },
        'amigacd32': {
            'iso':     'chd',
            'bin':     'chd',
            'cue':     'chd',
            'chd':     None,
        },
        'switch': {
            'nsp':     'nsz',    # NSP → NSZ compress (net-new; nsz.sh only decompresses)
            'xci':     'nsz',    # XCI → NSZ
            'nsz':     None,
        },
    }
    # ZIP cartridge fallback: if platform is cartridge (nes, snes, etc.)
    # and file is loose or zip with stored entries, target is 'zip:deflate:9'
    cartridge = CARTRIDGE_SYSTEMS
    if platform in cartridge:
        current = table.get(platform, {}).get(current_format)
        if current is not None:
            return current
        if current_format == 'zip':
            return None  # Already ZIP, handled by zip_optimize()
        return 'zip'     # Loose ROM → archive in ZIP
    return table.get(platform, {}).get(current_format)
```

### 4.3 `profile.py` — Profiles

```python
@dataclass
class Profile:
    name: str             # 'speed', 'balanced', 'archive'
    psp_target: str       # 'zso', 'cso' (level 6), 'cso' (level 9)
    chd_hunk_size: int    # 65536 (64KB), 16384 (16KB), 4096 (4KB)
    chd_compression: str  # 'zlib', 'zlib', 'lzma'
    rvz_compression: str  # 'zstd:1' (speed), 'zstd:5' (balanced), 'zstd:7' (archive)
    rvz_purge: bool       # True always
    zip_level: int = 9    # ZIP Deflate level (1-9)
    zip_method: str = 'deflate'  # 'deflate' or 'bzip2' (less compat)
    zip_force: bool = False      # Re-compress already-deflated entries

PROFILES = {
    'speed':     Profile('speed',     'zso',  65536, 'zlib',  'zstd:1', True, zip_level=6, zip_force=False),
    'balanced':  Profile('balanced',  'cso',  16384, 'zlib',  'zstd:5', True, zip_level=9, zip_force=False),
    'archive':   Profile('archive',   'cso',  16384, 'lzma',  'zstd:7', True, zip_level=9, zip_force=True),
}
```

### 4.4 `convert.py` — Conversion Wrappers

Each converter function follows the pattern:

```python
def convert_chd(source: Path, dest: Path, profile: Profile) -> int:
    # 1. Determine input type: chdman accepts iso/cue/gdi/bin
    # 2. Build chdman command:
    #    chdman createcd -i <source> -o <dest> \
    #      -hunksize <profile.chd_hunk_size> \
    #      -c <profile.chd_compression>
    #    # For DVD (PS2): createhd instead of createcd
    # 3. Return exit code
```

| Platform | chdman Subcommand | Input Type |
|---|---|---|
| PS1 | `createcd` | `.cue` (prefer) or `.bin` |
| PS2 | `createhd` | `.iso` |
| Dreamcast | `createcd` | `.gdi` (prefer) or `.cue` |
| Saturn | `createcd` | `.cue` |
| Mega CD / Sega CD | `createcd` | `.cue` |
| PC Engine CD / TG16 | `createcd` | `.cue` |
| Neo Geo CD | `createcd` | `.cue` |
| 3DO | `createcd` | `.cue` |
| PC-FX | `createcd` | `.cue` |
| FM Towns | `createcd` | `.cue` |
| Atari Jaguar CD | `createcd` | `.cue` |
| Amiga CD32 | `createcd` | `.cue` |

```python
def convert_rvz(source: Path, dest: Path, profile: Profile) -> int:
    # dolphin-tool convert -f rvz -c <profile.rvz_compression> \
    #   -b <profile.rvz_purge> -i <source> -o <dest>
```

```python
def convert_cso(source: Path, dest: Path, profile: Profile, fmt='cso') -> int:
    # maxcso --format <fmt> --level <level> <source> <dest>
    # level=6 for balanced, 9 for archive
```

```python
def convert_nsz(source: Path, dest: Path) -> int:
    # nsz -C -o <dest> <source>
    # (compress NSP/XCI → NSZ; reverse of existing nsz.sh)
```

```python
def convert_zip(roms: list[Path], dest_zip: Path, profile: Profile) -> int:
    """Recompress a set of cartridge ROMs into a single ZIP with deflate-9."""
    import zipfile
    with zipfile.ZipFile(dest_zip, 'w', zipfile.ZIP_DEFLATED, compresslevel=profile.zip_level) as zf:
        for rom in roms:
            zf.write(rom, arcname=rom.name)
    # Verify round-trip: extract to memory, compare hashes
    return 0
```

```python
def rezip_archive(source_zip: Path, dest_zip: Path, profile: Profile) -> int:
    """Rewrite existing ZIP replacing stored/imploded entries with deflate-9."""
    import zipfile
    with zipfile.ZipFile(source_zip, 'r') as zin:
        with zipfile.ZipFile(dest_zip, 'w', zipfile.ZIP_DEFLATED, compresslevel=profile.zip_level) as zout:
            for item in zin.infolist():
                if item.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_SHRUNK):
                    data = zin.read(item.filename)
                    zout.writestr(item, data)
                elif item.compress_type == zipfile.ZIP_DEFLATED:
                    if profile.zip_force:
                        data = zin.read(item.filename)
                        zout.writestr(item, data)
                    else:
                        zout.writestr(item, zin.read(item.filename),
                                      compress_type=zipfile.ZIP_DEFLATED)
                else:
                    zout.writestr(item, zin.read(item.filename),
                                  compress_type=getattr(zipfile, f'ZIP_{item.compress_type}', None))
    return 0
```

### 4.5 `verify.py` — Post-Conversion Integrity

| Format | Command | What It Checks |
|---|---|---|
| CHD | `chdman verify <file>` | Internal checksums per hunk |
| RVZ | `dolphin-tool verify <file>` | Block-level CRC32 |
| CSO/ZSO | `sha256sum <dest>` vs `sha256sum <source>` | Full volume hash |
| NSZ | `nsz -V <file>` | PFS0 header + content hash round-trip |
| ZIP | `unzip -t <file>` | Entry CRC32 + structure integrity |
| ZIP (recompress) | `sha256sum <entry>` after `unzip -p` vs original | Content verification per entry |

### 4.6 `rename.py` — No-Intro + Redump Naming

**Two naming standards**, selected by platform:

| Category | Standard | Source | Platforms |
|---|---|---|---|
| **Cartridge** | No-Intro | DAT files via `datomatic.no-intro.org` / `no-intro.org/dats` | NES, SNES, N64, GB, GBC, GBA, NDS, 3DS, Genesis, SMS, GG, Lynx, NGPC, WS, etc. |
| **Disc** | Redump | DAT files via `datomatic.redump.org` + header serial | PS1, PS2, PSP, DC, Saturn, Mega CD, PCE-CD, 3DO, etc. |
| **Wii/GC** | Redump | DAT + Game ID lookup | GC, Wii |
| **Switch** | No-Intro (NSP/XCI) | DAT + title ID | Switch |
| **Fallback** | CamelCase guess | Heuristic + country code | Unknown |

#### Naming Templates

**No-Intro** (cartridge):
```
{Game Name} ({Region}) ({Revision, if >0}).{ext}
Super Mario Bros (USA).nes
Super Mario Bros (Europe) (Rev 1).nes
Castlevania - Aria of Sorrow (USA) (Virtual Console).gba
```

**Redump** (disc):
```
{Game Name} ({Region}) ({Serial}).{ext}
Final Fantasy VII (USA) (SCUS-94163).chd
Sonic CD (Europe) (MegaCD-001).chd
```

#### DAT File Pipeline

DAT files are XML with this structure (No-Intro):

```xml
<game name="Super Mario Bros (USA)">
    <description>Super Mario Bros (USA)</description>
    <rom name="Super Mario Bros (USA).nes" size="40976" crc="D4E6F0C6" sha1="D4E6F0C6..." />
</game>
```

Redump:
```xml
<game name="Final Fantasy VII (USA) (SCUS-94163)">
    <description>Final Fantasy VII</description>
    <rom name="Final Fantasy VII (USA) (SCUS-94163).iso" size="..." crc="..." md5="..." sha1="..." serial="SCUS-94163"/>
</game>
```

Flow:

```
Step 1: Download DAT if missing (via curl/wget)
  ├── No-Intro: datomatic.no-intro.org is live, BUT the GET ?file= form returns
  │             404 — datomatic now uses a POST form. v1 strategy: let the user
  │             drop .dat files into metadata/rom-optimizer/dats/no-intro/
  │             manually; document the download flow. Auto-download (POST form
  │             scraping) is deferred to v2.
  └── Redump:   datomatic.redump.org is NOT serving datomatic (HTTPS refused,
                HTTP returns Apache default page, /files/ 404). Redump DATs
                require a forum account at redump.org. v1 strategy: user-supplied
                DATs only. v2: optional redump.org authenticated download.

Step 2: Parse XML → index by CRC32/SHA1
  └── index = { crc32_hex: (game_name, region, serial?, revision?), ... }

Step 3: Compute hash of input ROM
  └── crc32, sha1, (md5 for Redump)

Step 4: Match hash against DAT index
  ├── match → return canonical No-Intro name
  └── no match → fallback (see below)

Step 5: Cache results in metadata/rom-optimizer/naming/
  ├── {platform}.dat.xml         # raw DAT file
  └── {platform}-index.json       # pre-parsed index for fast load
```

#### DAT Index Generation

```python
def parse_no_intro_dat(xml_path: Path) -> dict[str, dict]:
    """Parse No-Intro DAT XML → {crc32: {name, region, revision, publisher}}"""
    import xml.etree.ElementTree as ET
    index = {}
    root = ET.parse(xml_path).getroot()
    for game in root.findall('.//game'):
        name = game.attrib['name']  # canonical No-Intro name
        for rom in game.findall('rom'):
            crc = rom.attrib.get('crc', '').lower()
            if crc:
                index[crc] = {
                    'name': name,
                    'size': int(rom.attrib.get('size', 0)),
                    'sha1': rom.attrib.get('sha1', '').lower(),
                }
    return index
```

#### Hash Matching Strategy

| Category | Primary | Secondary | Tertiary |
|---|---|---|---|
| Cartridge (No-Intro) | **CRC32** (fast) | SHA1 (disambiguation) | Size |
| Disc (Redump) | **SHA1** | MD5 (legacy) | CRC32 + size |
| CHD/compressed | SHA1 of raw image (extracted or from manifest) | — | — |

#### Fallback Rename (no DAT match)

When no DAT match, extract identifying info from ROM header + generate a clean name:

```python
FALLBACK_TEMPLATE = "{CleanTitle} ({Region}) ({PlatformKey}).{ext}"

def fallback_name(file: Path, platform: str, header: dict) -> str:
    title = header.get('title', file.stem)
    title = clean_no_intro_title(title)  # remove garbage suffixes
    region = header.get('region', detect_region(file, platform))
    return f"{title} ({region}) ({platform}).{file.suffix}"
```

**Region detection**: country code at ROM offset (NES/SNES byte, Genesis checksum region, etc.) or file path heuristics (`(USA)`, `(Europe)`, `(Japan)` in filename).

**Title cleaning**:
- Strip `[!]`, `[b1]`, `[f1]`, `(PD)`, `(Demo)`, `(Proto)` from filename → preserve in tags
- Capitalize first letters, normalize Unicode, remove redundant whitespace
- Replace underscores with spaces

#### Multi-file Discs

| Case | Rename Strategy |
|---|---|
| **.cue + .bin → .chd** | `chdman createcd` ingests the .cue + all .bin tracks and emits a **self-contained .chd**. The .cue/.bin are no longer needed after conversion — delete them (after verify), do NOT rewrite a .cue to "point at" a .chd (different container types). |
| **.m3u (multi-disc)** | Rename each `.chd` with disc suffix: `Game (Disc 1).chd`, `Game (Disc 2).chd`. Update `.m3u` entries (these DO reference .chd files legitimately). |
| **ZIP → cartridge** | ZIP filename = No-Intro name + `.zip`. ROM inside keeps original name or is named `rom.ext` |

#### CLI Integration

```bash
# Download/update DATs for all platforms
pz emulation rom-optimize dats update

# List DAT coverage stats
pz emulation rom-optimize dats status

# Rename-only mode (no compression)
pz emulation rom-optimize ~/roms/nes --rename-only --yes
```

Add to `romopt.sh`:
```bash
dats|dat|datfiles)
    python3 "$PZ_ROOT/linux/emulation/romopt/main.py" dats "${extra[@]}"
    ;;
rename|rename-only)
    python3 "$PZ_ROOT/linux/emulation/romopt/main.py" rename "${extra[@]}"
    ;;
sync-undo)
    python3 "$PZ_ROOT/linux/emulation/romopt/main.py" sync-undo "${extra[@]}"
    ;;
sync-status)
    python3 "$PZ_ROOT/linux/emulation/romopt/main.py" sync-status "${extra[@]}"
    ;;
```

#### Layout (DAT cache)

Add to `pz_emulation_layout_dirs()`:
```
$PZ_EMULATION_ROOT/metadata/rom-optimizer/dats/no-intro/
$PZ_EMULATION_ROOT/metadata/rom-optimizer/dats/redump/
$PZ_EMULATION_ROOT/metadata/rom-optimizer/naming/   # rename manifests
```

#### Open Questions for This Module

1. **Auto-download DATs?** **No auto-download in v1.** Verified: `datomatic.redump.org` is non-functional (HTTPS refused, Apache default page); No-Intro datomatic's GET `?file=` form returns 404 (now POST-based). v1: user-supplied DATs in `metadata/rom-optimizer/dats/`. v2: No-Intro POST scraping + optional Redump authenticated download.
2. **DAT license**: No-Intro DATs are freely distributable. Redump DATs require attribution
3. **Rename-only mode**: Useful as standalone command to fix existing collections without re-compression
4. **Conflict resolution**: Two ROMs with same CRC32 but different DAT entries → interactive prompt or keep both with disambiguating suffix

### 4.7 `cartridge.py` — ZIP Optimizer for Cartridge Systems

Systems with cartridge media (NES, SNES, Genesis, GB, N64, etc.) don't benefit from CHD or RVZ — ROMs are already small. The optimization target is **ZIP with Deflate level 9**, which every emulator (RetroArch, MAME, Mesen, bsnes, etc.) reads natively without extraction.

#### Detection

```python
def check_zip_optimal(zip_path: Path) -> tuple[bool, list[str]]:
    """Check if all entries in a ZIP use deflate or better.
    Returns (is_optimal, list of entries needing recompression)."""
    import zipfile
    suboptimal = []
    with zipfile.ZipFile(zip_path, 'r') as zf:
        for info in zf.infolist():
            if info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_SHRUNK,
                                      1, 2, 3, 4, 5, 6, 7):
                suboptimal.append(info.filename)
    return len(suboptimal) == 0, suboptimal
```

| Entry Method | Code | Action |
|---|---|---|
| Stored (no compression) | 0 | Recompress → deflate-9 |
| Shrunk / Reduced / Imploded | 1-7 | Recompress → deflate-9 |
| Deflated | 8 | Skip (unless `--zip-force`) |
| Enhanced Deflated | 9 | Skip |
| BZIP2 | 12 | Skip (already optimal) |
| LZMA | 14 | Skip |
| Zstd | 93 | Skip |

#### Converting Loose ROMs → ZIP

```python
def archive_loose_roms(roms: list[Path], dest_dir: Path, profile: Profile) -> list[Path]:
    """Group loose cartridge ROMs by directory, create ZIP per batch."""
    created = []
    for group_key, group in group_by_stem_or_dir(roms).items():
        dest = dest_dir / f"{group_key}.zip"
        convert_zip(group, dest, profile)
        created.append(dest)
    return created
```

**Grouping heuristic**: ROMs in the same directory sharing the same game name stem are batched into one ZIP (e.g., `game.nes` + `game.sav` → `game.nes.zip`). Standalone ROMs are zipped individually.

#### Recompress Existing ZIP

Same pipeline as disc conversion: staging → rezip → verify `unzip -t` → atomic mv → write manifest → clean source.

#### 4.8 `clean.py` — Source Removal

```python
def clean_source(source: Path, dest: Path, manifest: dict):
    """Remove source only after ALL checks pass:
    1. Destination exists and passes verify
    2. Source unchanged since conversion started (inode+mtime match)
    3. Manifest written to metadata dir
    4. If source was in archive: remove archive too (if single-ROM) or append warning
    """
```

### 4.9 `manifest.py` — Journal

Follows same pattern as NSZ manifests (`metadata/rom-optimizer/`):

```json
{
    "schema": "https://phasezero.local/schemas/rom-optimizer.json",
    "status": "completed",
    "platform": "ps1",
    "source": "/path/to/final-fantasy-vii.iso",
    "destination": "/path/to/Final Fantasy VII (USA) (SCUS-94163).chd",
    "sourceBytes": 734003200,
    "outputBytes": 289406976,
    "sourceSha256": "abc123...",
    "outputSha256": "def456...",
    "profile": "balanced",
    "sourceRemoved": true,
    "tool": { "name": "chdman", "version": "0.268" },
    "convertedAt": "2026-07-09T12:00:00Z"
}
```

### 4.10 `sync.py` — Related Asset Synchronization

When a ROM is renamed (by No-Intro/Redump), all files referencing the old stem must be updated. This module scans the Emulation tree and syncs every asset category.

#### Asset Map

| Category | Directory | Extensions | Action |
|---|---|---|---|
| **.m3u** | same dir as ROM | `.m3u` | Update paths inside file |
| **Saves** | `saves/{platform}/` | `.sav`, `.srm`, `.dsv`, `.eep`, `.fra`, `.psv`, `.auto` | Rename file |
| **Memory cards** | `saves/{platform}/` | `.mcr`, `.ps2`, `.vmp`, `.card` | Rename file |
| **Save states** | `states/{platform}/` | `.state`, `.state.auto`, `.st`, `.st0`-`.st9`, `.net`, `.yaz0`, `.time`, `.png` (preview) | Rename file |
| **Media (ES-DE, LaunchBox)** | `tools/downloaded_media/{platform}/*/` | `.png`, `.jpg`, `.mp4`, `.webm`, `.pdf`, `.gif` in subdirs `covers/`, `screenshots/`, `videos/`, `titlescreens/`, `fanart/`, `manuals/`, `marquees/`, `miximages/`, `3dboxes/`, `backcovers/` | Rename file |
| **Gamelist** | `metadata/gamelists/frontends/{platform}/` | `gamelist.xml` | Update `<path>` element |
| **Playlists (RetroArch)** | `~/.config/retroarch/playlists/` | `.lpl` | Update `path` + `label` entries |
| **Cheats** | `cheats/{platform}/` | `.cht`, `.pnach`, `.ps2cht` | Rename file |
| **Patches** | `patches/{platform}/` | `.bps`, `.ips`, `.ppf`, `.xdelta`, `.ups` | Rename file |
| **Optimizer configs** | `optimizers/{emulator}/` | `.ini`, `.cfg`, `.conf` | Rename file (opt-in) |
| **Mods** | `mods/{platform}/` | various | Rename dir/file (opt-in) |

#### Sync Logic

```python
def sync_related_assets(old_stem: str, new_stem: str, platform: str, dry_run: bool):
    """Rename/update every asset referencing old_stem to new_stem."""
    renames = []  # list of (old_path, new_path)
    for category, config in CATEGORIES.items():
        if not config['enabled']:
            continue
        base = config['base_dir'].format(platform=platform)
        if config['action'] == 'rename':
            for file in base.glob(f"{old_stem}*"):
                suffix = file.name.removeprefix(old_stem)
                new_path = file.parent / f"{new_stem}{suffix}"
                renames.append((file, new_path))
        elif config['action'] == 'rewrite' and config['ext'] == 'm3u':
            rewrite_m3u(base / f"{old_stem}.m3u", old_stem, new_stem)
        elif config['action'] == 'rewrite' and config['ext'] == 'xml':
            update_gamelist_xml(base / 'gamelist.xml', old_stem, new_stem)
    apply_renames(renames, dry_run)
```

**.m3u rewrite** (must always run):

```python
def rewrite_m3u(m3u_path: Path, old_stem: str, new_stem: str):
    """Replace old_stem with new_stem in every line of the .m3u file."""
    if not m3u_path.exists():
        return
    lines = m3u_path.read_text().splitlines(keepends=True)
    changed = 0
    new_lines = []
    for line in lines:
        if old_stem in line:
            new_lines.append(line.replace(old_stem, new_stem))
            changed += 1
        else:
            new_lines.append(line)
    if changed:
        tmp = m3u_path.with_suffix('.m3u.tmp')
        tmp.write_text(''.join(new_lines))
        tmp.rename(m3u_path)
```

**Gamelist XML update**:

```python
def update_gamelist_xml(xml_path: Path, old_stem: str, new_stem: str):
    """Update <path> elements referencing the old ROM path."""
    if not xml_path.exists():
        return
    import xml.etree.ElementTree as ET
    tree = ET.parse(xml_path)
    root = tree.getroot()
    changed = False
    for game in root.findall('.//game'):
        path_el = game.find('path')
        if path_el is not None and old_stem in path_el.text:
            path_el.text = path_el.text.replace(old_stem, new_stem)
            name_el = game.find('name')
            if name_el is not None and old_stem in name_el.text:
                name_el.text = name_el.text.replace(old_stem, new_stem)
            changed = True
    if changed:
        tmp = xml_path.with_suffix('.xml.tmp')
        tree.write(tmp, encoding='utf-8', xml_declaration=True)
        tmp.rename(xml_path)
```

#### Safety & Undo

```python
# Each rename is logged
RENAME_LOG = "metadata/rom-optimizer/naming/sync-manifest.json"

def log_rename_batch(batch: list[tuple[Path, Path]]):
    """Append to sync-manifest.json for undo capability."""
    entries = [{'old': str(o), 'new': str(n), 'ts': now()} for o, n in batch]
    manifest_path = RENAME_LOG
    existing = json.loads(manifest_path.read_text()) if manifest_path.exists() else []
    existing.extend(entries)
    manifest_path.write_text(json.dumps(existing, indent=2))

def undo_renames(timestamp: str):
    """Reverse all renames from a given batch timestamp."""
    manifest = json.loads(RENAME_LOG.read_text())
    for entry in manifest:
        if entry['ts'] == timestamp:
            Path(entry['new']).rename(Path(entry['old']))
```

#### Scope Configuration

```python
# sync.py
RELATED_SCOPE = {
    "m3u":        True,   # always update .m3u paths
    "saves":      True,   # rename save files + memory cards
    "states":     True,   # rename save states + previews
    "media":      True,   # rename all media (covers, screenshots, videos...)
    "gamelists":  True,   # update ES-DE gamelist.xml
    "playlists":  True,   # update RetroArch .lpl (detect path from config)
    "cheats":     True,   # rename cheat/patch files
    "configs":    False,  # opt-in: rename per-game config files
    "mods":       False,  # opt-in: rename mod directories
}
```

#### Undo CLI

```bash
pz emulation rom-optimize sync-undo <timestamp>
    # Reverse every rename from a previous sync batch

pz emulation rom-optimize sync-status
    # Show recent sync operations + rename count
```

The sync-manifest format mirrors the conversion manifest schema from §4.9 (one
JSON object per rename: `{old, new, ts}`). Undo reads the manifest by timestamp
and reverses each rename.

---

## 5. Pipeline Orchestration (`main.py`)

### 5.1 Flow

```
main()
  ├── parse_args()
  ├── discover_tools()           # Check all required binaries
  ├── scan(path)                 # Recursive file list
  ├── REMEMBER: if rename-only: skip compression, run rename block only
  ├── for each file:
  │     ├── detect_platform()    # (platform, current_format, confidence)
  │     ├── decision(platform, current_format, profile)
  │     │     └── if None → skip (already optimal)
  │     ├── extract_if_archive() # 7z x if source is .zip/.7z/.rar
  │     ├── staging(mktemp)
  │     ├── convert(source, staging_dest, profile)
  │     ├── verify(staging_dest, source)
  │     ├── rename(staging_dest) → final_name         # No-Intro / Redump
  │     ├── if verify OK:
  │     │     ├── write_manifest()
  │     │     ├── mv(staging_dest → final_path)
  │     │     ├── if not --keep-original:
  │     │     │     ├── rm(source)
  │     │     │     ├── rm(archive) if extracted from single-ROM archive
  │     │     │     └── update_manifest(sourceRemoved=true)
  │     │     ├── sync_related_assets(old_stem, new_stem, platform)  # ← NEW
  │     │     └── log success
  │     └── else:
  │           ├── rm(staging)     # no-op, just cleanup
  │           └── log error, keep source
  └── summary(stdout / --json)
```

### 5.2 Safety Guarantees

1. **Staging first**: all writes go to `.phasezero/staging/rom-optimizer/`
2. **Source unchanged check**: stat `source` before convert → stat again before delete; mismatch = abort
3. **Manifest before deletion**: manifest file written to `metadata/rom-optimizer/` BEFORE any `rm`
4. **Atomic move**: `mv staging_dest final_path` — single filesystem, no partial state
5. **Lock file**: single conversion at a time per platform (flock, same as nsz.sh)
6. **Quarantine**: failed conversions move original source to `.phasezero/quarantine/rom-optimizer/` (not deleted)
7. **Dry-run**: `--dry-run` prints plan JSON without any writes

### 5.3 Edge Cases

| Edge Case | Handling |
|---|---|
| Multi-track PS1 (.bin + .cue + .sub) | CHD (`chdman createcd`) ingests the .cue + all tracks into one self-contained .chd. Delete .cue/.bin/.sub after verify; no CUE rewrite (CHD is standalone). |
| Multi-disc (.m3u) | Convert each disc; update .m3u paths |
| Archive with 1 ROM | Extract → convert → delete archive |
| Archive with multi-ROM (e.g. zip of 2 games) | Extract all → convert each → keep archive (with log) |
| Source and dest same format but different compression | Only recompress if ratio gain > threshold (default: 10%) |
| ROM with no detectable platform | Skip with `--unknown` flag to force-platform |
| Disk full during conversion | Stage on same FS as dest; check `available > source * 4 + 5GB reserve` |
| chdman not installed | Install check + error message with `pacman -S mame-tools` |
| Symlink source | Readlink → warn → process real file |
| Read-only directory | Skip with warning |

---

## 6. CLI Reference

```
Usage:
  pz emulation rom-optimize <path> [options]

Arguments:
  <path>                        ROM file or directory to scan

Options:
  --profile <name>              Compression profile: speed, balanced, archive (default: balanced)
  --platform <name>             Force platform (disc or cartridge system key)
  --keep-original               Keep source files after successful conversion
  --rename-only                 Only rename files to standard; no format conversion
  --no-rename                   Skip renaming (keep original filename)
  --no-dats                     Skip DAT download/update (use local cache only)
  --dry-run, -n                 Print plan only; no changes
  --json <file>                 Write results as JSON
  --verbose, -v                 Verbose output (tool commands, timings)
  --yes, -y                     Confirm destructive operations (archive deletion, source deletion)
  --overwrite                   Re-convert even if destination already optimal
  --unknown                     Attempt conversion of ROMs with unknown platform
  --cartridge-only              Only process cartridge systems (skip disc/optical)
  --disc-only                   Only process disc-based systems (skip cartridge)
  --zip-level <1-9>             Override ZIP compression level (default: 9)
  --zip-force                   Recompress ZIP entries already using deflate (profile default: archive only)
  --related-all                 Sync all related assets on rename (saves, states, media, .m3u, gamelists, playlists, cheats)
  --related-saves               Sync save files + memory cards
  --related-states              Sync save states
  --related-media               Sync covers, screenshots, videos
  --related-gamelists           Update ES-DE gamelist.xml
  --related-playlists           Update RetroArch playlists
  --related-cheats              Sync cheat/patch files
  --related-opts                Rename per-game optimizer configs (opt-in)
  --no-related-m3u              Skip .m3u path update (enabled by default)
  --help, -h                    Show help

Examples:
  pz emulation rom-optimize ~/Emulation/roms/ps1/ --profile archive --dry-run
  pz emulation rom-optimize ~/Emulation/roms/psp/ --profile speed --yes
  pz emulation rom-optimize ~/Emulation/roms/ --json report.json
  pz emulation rom-optimize ~/Emulation/roms/wii/game.iso --profile speed
  pz emulation rom-optimize ~/Emulation/roms/nes/ --cartridge-only --dry-run
  pz emulation rom-optimize ~/Emulation/roms/ --cartridge-only --zip-force --yes
  pz emulation rom-optimize ~/Emulation/roms/nes/ --rename-only --yes
  pz emulation rom-optimize ~/Emulation/roms/nes/ --rename-only --related-all --yes
  pz emulation rom-optimize ~/Emulation/roms/ps1/ --rename-only --related-saves --related-media --yes
  pz emulation rom-optimize ~/Emulation/roms/nes/ --rename-only --related-all --dry-run --json preview.json
  pz emulation rom-optimize sync-undo 2026-07-09T12:30:00
  pz emulation rom-optimize sync-status
  pz emulation rom-optimize dats update
  pz emulation rom-optimize dats status
```

---

## 7. Implementation Phases

### Phase 1 — Core Framework (Python)

| Step | Files | Est. Time |
|---|---|---|
| 1.1 `main.py` + CLI arg parse | `main.py`, `__init__.py` | 1 day |
| 1.2 `detect.py` — magic bytes + ext + dir detection | `detect.py` | 2 days |
| 1.3 `decision.py` — decision table + profile.py | `decision.py`, `profile.py` | 1 day |
| 1.4 `tools.py` — tool discovery + version checks | `tools.py` | 0.5 day |
| 1.5 `convert.py` — chdman wrapper (PS1, PS2, DC, Saturn) | `convert.py` | 2 days |
| 1.6 `verify.py` — chdman verify + sha256 | `verify.py` | 0.5 day |
| 1.7 `manifest.py` — manifest read/write | `manifest.py` | 0.5 day |
| 1.8 `rename.py` — serial extraction + naming | `rename.py` | 1 day |
| 1.9 `clean.py` — safe source removal | `clean.py` | 0.5 day |
| 1.10 Pipeline orchestration | `main.py` (core logic) | 1 day |

**Total Phase 1: ~10 days**

### Phase 2 — Rename + Sync (No-Intro/Redump + Related Assets)

| Step | Est. Time |
|---|---|
| 2.1 `rename.py` — No-Intro DAT parser + CRC32 index builder | 1 day |
| 2.2 `rename.py` — Redump DAT parser + SHA1 serial extract | 1 day |
| 2.3 `rename.py` — Fallback rename (header serial + region) | 0.5 day |
| 2.4 `rename.py` — Multi-disc .m3u + CUE rewrite | 0.5 day |
| 2.5 `dats.py` — DAT download cache + update logic | 0.5 day |
| 2.6 `sync.py` — .m3u path rewrite + saves/states rename | 1 day |
| 2.7 `sync.py` — Media rename (covers, screenshots, videos) | 0.5 day |
| 2.8 `sync.py` — ES-DE gamelist.xml update | 0.5 day |
| 2.9 `sync.py` — RetroArch .lpl playlist update | 0.5 day |
| 2.10 `sync.py` — Cheat/patch rename + undo manifest | 0.5 day |

**Total Phase 2: ~6.5 days**

### Phase 3 — Disc Systems (CHD + RVZ + PSP + NSZ)

| Step | Est. Time |
|---|---|
| 3.1 Add 8 disc platforms to detect/decision/convert (Mega CD, PCE-CD, Neo Geo CD, 3DO, PC-FX, FM Towns, Jaguar CD, Amiga CD32) | 1 day |
| 3.2 RVZ conversion (dolphin-tool wrapper) | 1 day |
| 3.3 PSP: maxcso CSO/ZSO wrapper | 0.5 day |
| 3.4 NSZ compression (nsp/xci → nsz, reverse of existing) | 1 day |
| 3.5 Archive extraction (zip/7z/rar) → convert → clean | 1 day |
| 3.6 Multi-track CUE rewriting for CHD output | 0.5 day |

**Total Phase 3: ~5 days**

### Phase 4 — Cartridge ZIP Optimization

| Step | Est. Time |
|---|---|
| 4.1 `cartridge.py` — ZIP analysis (stored/imploded detection + grouping logic) | 1 day |
| 4.2 Loose ROM → ZIP archive routine | 0.5 day |
| 4.3 Recompress existing ZIP (staging → rezip → verify → mv → clean) | 1 day |
| 4.4 Platform mapping: 25+ cartridge systems → cartridge flag | 0.5 day |
| 4.5 Profile integration (zip_level, zip_force per profile) | 0.5 day |
| 4.6 Multi-ROM archive handling (keep/discard logic) | 0.5 day |

**Total Phase 4: ~4 days**

### Phase 5 — Integration

| Step | Est. Time |
|---|---|
| 5.1 `romopt.sh` — pz wrapper script | 0.5 day |
| 5.2 `pz` CLI integration + usage text | 0.5 day |
| 5.3 Layout directories in `common.sh` | 0.25 day |
| 5.4 Tool installer (`pz emulation rom-optimize install`) | 1 day |
| 5.5 Integration tests | 1 day |

**Total Phase 5: ~3.25 days**

### Phase 6 — Polish

| Step | Est. Time |
|---|---|
| 6.1 Dry-run JSON output | 0.5 day |
| 6.2 Summary report (compression ratio table) | 0.5 day |
| 6.3 Parallel conversion per platform (ThreadPoolExecutor) | 1 day |
| 6.4 Progress bar (tqdm or rich) | 0.5 day |

**Total Phase 6: ~2.5 days**

**Grand total: ~31.25 days**

---

## 8. Testing Strategy

### Unit Tests

| Module | Test |
|---|---|
| `detect.py` | Magic bytes for each platform; extension mapping; dir name mapping; ambiguous .iso size heuristic |
| `decision.py` | Every platform × format combination returns expected target or None; profile changes target |
| `profile.py` | Profile fields match spec |
| `rename.py` | Serial extraction from PS1/PS2/PSP headers; fallback naming |
| `verify.py` | Verify passes good file, fails corrupt file |
| `manifest.py` | Round-trip serialize → deserialize |
| `sync.py` | .m3u rewrite, save rename, gamelist XML update, undo manifest |

### Integration Tests (in `tests/`)

| Test | What |
|---|---|
| `test_romopt_detect_ps1.sh` | Create minimal PS1 ISO → detect platform |
| `test_romopt_detect_megacd.sh` | CUE+BIN in megacd dir → detect platform |
| `test_romopt_convert_ps1.sh` | Create PS1 ISO → convert to CHD → verify |
| `test_romopt_convert_pcecd.sh` | Create PCE-CD CUE+BIN → convert to CHD → verify |
| `test_romopt_convert_psp_cso.sh` | Create PSP ISO → convert to CSO → verify |
| `test_romopt_skip_optimal.sh` | Convert to CHD → run again → verify skip |
| `test_romopt_archive_ps1.sh` | ZIP with PS1 ISO → convert → verify archive deleted |
| `test_romopt_cartridge_zip.sh` | Create stored ZIP of NES ROMs → recompress → verify deflate-9 |
| `test_romopt_cartridge_loose.sh` | Loose .nes file → ZIP archive → verify |
| `test_romopt_rename_no_intro.sh` | NES ROM with known CRC → rename to No-Intro standard |
| `test_romopt_rename_redump.sh` | PS1 bin/cue with known serial → rename to Redump standard |
| `test_romopt_rename_fallback.sh` | Unknown ROM → fallback rename with header extraction |
| `test_romopt_rename_multi_disc.sh` | Multi-disc .m3u → rename each with (Disc N) suffix |
| `test_romopt_rename_dryrun.sh` | Rename preview dry-run without writing |
| `test_romopt_dats_parse.sh` | Parse sample no-intro DAT XML → build index → match |
| `test_romopt_sync_m3u.sh` | Rename disc → verify .m3u paths updated |
| `test_romopt_sync_saves.sh` | Rename ROM → verify save file renamed in saves/{platform}/ |
| `test_romopt_sync_states.sh` | Rename ROM → verify save state + preview renamed |
| `test_romopt_sync_media.sh` | Rename ROM → verify cover/screenshot/video renamed |
| `test_romopt_sync_gamelist.sh` | Rename ROM → verify gamelist.xml <path> updated |
| `test_romopt_sync_undo.sh` | Sync → undo → verify all files reverted to original names |
| `test_romopt_sync_dryrun.sh` | Dry-run sync → verify no files actually moved |
| `test_romopt_dryrun.sh` | Dry-run produces JSON plan, no files changed |

Follow existing test pattern in `tests/linux-emulation-shared.sh`.

---

## 9. Files Requiring Changes

| File | Changes |
|---|---|
| `linux/pz` | Add `rom-optimize`/`romopt` subcommand + usage entry |
| `linux/emulation/common.sh` | Add layout dirs for `metadata/rom-optimizer`, `staging/rom-optimizer`, `quarantine/rom-optimizer`, `tools/rom-optimizer` |
| `linux/emulation/romopt/__init__.py` | Package init |
| `linux/emulation/romopt/main.py` | CLI entrypoint, orchestration (cartridge branch + CLI opts) |
| `linux/emulation/romopt/detect.py` | Platform detection (add 8 disc + 25 cartridge systems) |
| `linux/emulation/romopt/decision.py` | Decision tree (add disc systems + cartridge fallback) |
| `linux/emulation/romopt/convert.py` | Conversion wrappers (add 8 disc platforms + convert_zip) |
| `linux/emulation/romopt/verify.py` | Integrity checks (add unzip -t) |
| `linux/emulation/romopt/rename.py` | No-Intro/Redump naming via DAT hashes + fallback |
| `linux/emulation/romopt/profile.py` | Profile dataclass (add zip_level, zip_method, zip_force) |
| `linux/emulation/romopt/cartridge.py` | ZIP analyzer + loose archiver + recompress |
| `linux/emulation/romopt/clean.py` | Source removal |
| `linux/emulation/romopt/manifest.py` | Manifest IO |
| `linux/emulation/romopt/tools.py` | External tool discovery |
| `linux/emulation/romopt/dats.py` | No-Intro/Redump DAT parser + index builder |
| `linux/emulation/romopt/sync.py` | Related asset sync (saves, states, media, .m3u, gamelists, playlists, cheats) + undo |
| `linux/emulation/romopt.sh` | pz wrapper script |
| `tests/test_romopt_*.sh` | Integration tests |

---

## 10. Open Questions

1. **Runtime**: Python foi escolhido sobre Rust por velocidade de implementação + já ter `nsz` Python no projeto. Confirmado?
2. **Profile default**: `balanced` como padrão? CHD zlib para discos, CSO nível 6 para PSP, RVZ zstd:5 para Wii/GC, ZIP deflate-9 para cartucho.
3. **Serial lookup**: Usar cache local somente (sem API externa) na v1? Download de datfiles Redump pode ser opcional na v2.
4. **Multi-ROM archives**: Manter o archive original após extrair múltiplas ROMs? Ou extrair e deletar sempre?
5. **PSP CHD**: PPSSPP suporta CHD desde 2025. Incluir como opção no profile `archive` ou deixar só CSO/ZSO?
6. **Cartridge ZIP grouping**: Um ZIP por ROM (`game.nes.zip`) ou um ZIP por série/grupo? RetroArch prefere ZIP com 1 ROM dentro.
7. **ZIP force default**: Só recompress entries stored, ou recompress tudo (stored + deflate)? `archive` faz force, `balanced` não — correto?
8. **Cartridge dir scanning**: Diretórios de cartucho já existem no layout (`nes/`, `snes/`, `gba/` etc.)? Ou o `romopt` só detecta pelo conteúdo?
9. **DAT source**: Usar `datomatic.no-intro.org` direto ou baixar de `no-intro.org/dats/` (mais estável, atualizado semanalmente)?
10. **Rename antes ou depois da compressão**: Renomear o RAW antes de converter (ideal — nome correto no CHD/ZIP) ou renomear o output? **Pré-rename** é melhor (serial/CRC extraído do raw, output herda nome)
11. **ROMs dentro de ZIP**: Para cartridge, deve extrair → rename → rezip, ou rename o ZIP mantendo entry interna? **Renomear só o ZIP** é mais rápido, mas entry interna fica com nome antigo. Extrair → rename → rezip é correto mas custa I/O
12. **m3u prioritário?** Sempre atualizar .m3u mesmo com `--no-related`? (Sim — .m3u quebra se não atualizar)
13. **Saves com nome diferente do ROM**: Muitos saves não batem com o stem do ROM (ex: serial-based em PCSX2). Deve escanear conteúdo ou confiar só no stem? **Só stem** na v1 (rápido, sem falsos positivos)
14. **Cross-platform saves**: Se um save de PS1 está em `saves/psx/` e também referenciado em outro lugar, deve sincronizar ambos? Escopo é o diretório da plataforma apenas
15. **Undo retenção**: Quantos dias manter o sync-manifest.json? Propriedade: 30 dias cleanup automático
