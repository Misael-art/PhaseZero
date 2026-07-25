#!/usr/bin/env bash

duckstation_root() {
    for path in \
        "${XDG_CONFIG_HOME:-$HOME/.config}/duckstation" \
        "$HOME/.var/app/org.duckstation.DuckStation/config/duckstation"; do
        [ -d "$path" ] && { echo "$path"; return; }
    done
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/duckstation"
}

duckstation_apply() {
    local serial="$1"; shift
    local file="$(duckstation_root)/GameSettings/$serial.ini" item section key value
    for item in "$@"; do
        section="${item%%.*}"; key="${item#*.}"; value="${key#*=}"; key="${key%%=*}"
        pz_ini_set "$file" "$section" "$key" "$value"
    done
}

duckstation_apply_jackie_chan() {
    duckstation_apply "SLUS-00684" Graphics.ResolutionScale=5 Graphics.PGXPEnable=true \
        Console.CpuOverclockEnable=true Console.CpuOverclockPercent=300
}

duckstation_apply_mgs() {
    local serial
    for serial in SLUS-00594 SLUS-00776; do
        duckstation_apply "$serial" Graphics.ResolutionScale=5 Graphics.AspectRatio=16:9 \
            Graphics.WidescreenHack=true Graphics.PGXPEnable=true Graphics.PGXPCpuMode=true \
            Graphics.Antialiasing=8 Console.CpuOverclockEnable=true Console.CpuOverclockPercent=200
    done
}
