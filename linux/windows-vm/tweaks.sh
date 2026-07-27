#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

DRY_RUN=0

apply_performance_safe_tweaks() {
    local dry=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry=1; shift ;;
            *) shift ;;
        esac
    done

    local changes='[]'
    changes="$(add_change "$changes" 'powerScheme' 'High performance' 'powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')"
    changes="$(add_change "$changes" 'hibernation' 'off' 'powercfg /h off')"
    changes="$(add_change "$changes" 'visualEffects' 'performance' 'Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects\" -Name \"VisualFXSetting\" -Value 2')"
    changes="$(add_change "$changes" 'backgroundApps' 'disabled' 'Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications\" -Name \"GlobalUserDisabled\" -Value 1')"
    changes="$(add_change "$changes" 'startupApps' 'minimize' 'Set-ItemProperty -Path \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\" -Name \"Start_TrackProgs\" -Value 0')"

    changes="$(build_appx_json "$changes")"

    changes="$(add_change "$changes" 'telemetry' '0 (security)' 'Set-ItemProperty -Path \"HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection\" -Name \"AllowTelemetry\" -Value 0')"
    changes="$(add_change "$changes" 'advertisingId' 'disabled' 'Set-ItemProperty -Path \"HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\AdvertisingInfo\" -Name \"DisabledByGroupPolicy\" -Value 1')"
    changes="$(add_change "$changes" 'feedback' 'disabled' 'Set-ItemProperty -Path \"HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection\" -Name \"DoNotShowFeedbackNotifications\" -Value 1')"
    changes="$(add_change "$changes" 'suggestions' 'disabled' 'Set-ItemProperty -Path \"HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent\" -Name \"DisableSoftLanding\" -Value 1')"
    changes="$(add_change "$changes" 'ceipTasks' 'disabled' 'schtasks /change /disable /tn \"\\Microsoft\\Windows\\Application Experience\\Microsoft Compatibility Appraiser\"')"
    changes="$(add_change "$changes" 'backgroundTasks' 'limited' 'Set-ItemProperty -Path \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System\" -Name \"EnableSmartScreen\" -Value 0')"

    jq -n \
        --argjson changes "$changes" \
        '{
            profile: "performance-safe",
            destructive: false,
            reversible: true,
            preserves: ["Defender", "Firewall", "WindowsUpdate", "Edge", "WebView", "VBS", "MemoryIntegrity"],
            changes: $changes
        }'
}

add_change() {
    local json="$1" key="$2" value="$3" command="$4"
    jq -c \
        --arg key "$key" \
        --arg value "$value" \
        --arg command "$command" \
        '. += [{"setting": $key, "value": $value, "command": $command, "previous": null}]' \
        <<< "$json"
}

build_appx_json() {
    local json="$1"
    local appx_json='[{"package":"Clipchamp","action":"remove"},{"package":"Microsoft.Clipchamp","action":"remove"},{"package":"Microsoft.BingWeather","action":"remove"},{"package":"Microsoft.BingNews","action":"remove"},{"package":"Microsoft.BingSports","action":"remove"},{"package":"Microsoft.BingFinance","action":"remove"},{"package":"Microsoft.MicrosoftSolitaireCollection","action":"remove"},{"package":"Microsoft.MixedReality.Portal","action":"remove"},{"package":"Microsoft.People","action":"remove"},{"package":"Microsoft.MSPaint","action":"remove"},{"package":"Microsoft.Todos","action":"remove"},{"package":"Microsoft.WindowsAlarms","action":"remove"},{"package":"Microsoft.WindowsCamera","action":"remove"},{"package":"Microsoft.WindowsCommunicationsApps","action":"remove"},{"package":"Microsoft.WindowsFeedbackHub","action":"remove"},{"package":"Microsoft.WindowsMaps","action":"remove"},{"package":"Microsoft.WindowsSoundRecorder","action":"remove"},{"package":"Microsoft.Xbox.TCUI","action":"remove"},{"package":"Microsoft.XboxApp","action":"remove"},{"package":"Microsoft.XboxGameCallableUI","action":"remove"},{"package":"Microsoft.XboxGamingOverlay","action":"remove"},{"package":"Microsoft.XboxIdentityProvider","action":"remove"},{"package":"Microsoft.XboxSpeechToTextOverlay","action":"remove"},{"package":"Microsoft.YourPhone","action":"remove"},{"package":"Microsoft.ZuneMusic","action":"remove"},{"package":"Microsoft.ZuneVideo","action":"remove"},{"package":"Microsoft.Windows.Photos","action":"keep"},{"package":"Microsoft.WindowsCalculator","action":"keep"},{"package":"Microsoft.WindowsNotepad","action":"keep"},{"package":"Microsoft.Paint","action":"keep"},{"package":"Microsoft.ScreenSketch","action":"keep"},{"package":"Microsoft.StorePurchaseApp","action":"keep"},{"package":"Microsoft.WindowsStore","action":"keep"}]'
    jq -c \
        --argjson appx "$appx_json" \
        '. += [{"setting": "appxRemoval", "value": "deny-list applied", "appx": $appx, "command": "Get-AppxPackage *$_* | Remove-AppxPackage", "destructive": true}]' \
        <<< "$json"
}

case "${1:-apply}" in
    apply) shift; apply_performance_safe_tweaks "$@" ;;
    *) echo "usage: tweaks apply [--dry-run]"; exit 1 ;;
esac
