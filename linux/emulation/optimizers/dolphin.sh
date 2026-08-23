#!/usr/bin/env bash
set -euo pipefail

dolphin_root() {
    for path in \
        "${XDG_CONFIG_HOME:-$HOME/.config}/dolphin-emu" \
        "$HOME/.var/app/org.DolphinEmu.dolphin-emu/config/dolphin-emu"; do
        [ -d "$path" ] && { echo "$path"; return; }
    done
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/dolphin-emu"
}

dolphin_apply() {
    local game_id="$1"; shift
    local file="$(dolphin_root)/GameSettings/$game_id.ini" item section key value
    for item in "$@"; do
        section="${item%%.*}"; key="${item#*.}"; value="${key#*=}"; key="${key%%=*}"
        pz_ini_set "$file" "$section" "$key" "$value"
    done
}

dolphin_common() {
    dolphin_apply "$1" Video_Enhancements.InternalResolution=3 \
        Video_Enhancements.MaxAnisotropy=4 Video_Hardware.ShaderCompilationMode=2 \
        Video_Textures.LoadCustomTextures=true Video_Textures.PrefetchCustomTextures=true "${@:2}"
}

dolphin_apply_smg1() { dolphin_common RMGE01 Video_Enhancements.AASamples=3 Video_Hacks.EFBCopyTexturesSource=false; }
dolphin_apply_smg2() { dolphin_common SB4E01 Video_Enhancements.AAMode=1 Video_Enhancements.AASamples=2 Video_Hacks.XFBCopyTexturesSource=false; }
dolphin_apply_dkc_returns() { dolphin_common SF8E01 Video_Enhancements.AASamples=3 Video_Enhancements.AspectRatio=3; }
