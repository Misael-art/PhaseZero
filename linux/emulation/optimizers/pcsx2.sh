#!/usr/bin/env bash
set -euo pipefail

pcsx2_root() {
    for path in \
        "${XDG_CONFIG_HOME:-$HOME/.config}/PCSX2" \
        "$HOME/.var/app/net.pcsx2.PCSX2/config/PCSX2"; do
        [ -d "$path" ] && { echo "$path"; return; }
    done
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/PCSX2"
}

pcsx2_apply() {
    local serial="$1"; shift
    local file="$(pcsx2_root)/inis/GameSettings/$serial.ini" item section key value
    for item in "$@"; do
        section="${item%%.*}"; key="${item#*.}"; value="${key#*=}"; key="${key%%=*}"
        pz_ini_set "$file" "$section" "$key" "$value"
    done
}

pcsx2_standard() {
    local serial="$1" upscale="$2" async="$3"; shift 3
    pcsx2_apply "$serial" EmuCore.EnableWideScreenPatches=true \
        EmuCore.EnableNoInterlacingPatches=true Graphics.UpscaleMultiplier="$upscale" \
        Graphics.FXAA=true Graphics.LoadTextures=true Graphics.AsyncTextureLoading="$async" \
        Graphics.AspectRatio=Widescreen169 "$@"
}

pcsx2_apply_gta_sa() { pcsx2_standard SLUS-20946 4 true EmuCore.EECycleRate=1 Graphics.ColorBoostBrightness=60 Graphics.ColorBoostSaturation=45; }
pcsx2_apply_gow1() { pcsx2_standard SCUS-97399 4 true EmuCore.EnableWideScreenPatches=false; }
pcsx2_apply_re4() { pcsx2_standard SLUS-21134 4 false Graphics.Mipmapping=false; }
pcsx2_apply_gow2() { pcsx2_standard SCUS-97481 4 true EmuCore.EnableWideScreenPatches=false; }
pcsx2_apply_dbzbt3() { pcsx2_standard SLUS-21678 4 true EmuCore.EECycleRate=3 Graphics.SkipDrawStart=3 Graphics.SkipDrawEnd=3 EmuCore.EnableCheats=true; }
pcsx2_apply_mk_shaolin() { pcsx2_standard SLUS-21087 4 true Graphics.SkipDrawStart=1 Graphics.SkipDrawEnd=1 Graphics.ColorBoostBrightness=60 Graphics.ColorBoostGamma=60; }
pcsx2_apply_crash_twinsanity() { pcsx2_standard SLUS-20909 4 true Graphics.Dithering=2; }
pcsx2_apply_onimusha3() { pcsx2_standard SLUS-20694 4 true Graphics.ColorClipBoost=true Graphics.Brightness=55; }
