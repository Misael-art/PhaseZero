#!/usr/bin/env bash
# steam-runtime-diagnose.sh - summarize Steam runtime diagnostics for SteamOS-like readiness
set -euo pipefail

ACTION="${1:-diagnose}"
INPUT="${2:-}"

repair_uri_handler() {
    if [ ! -f /usr/share/applications/steam.desktop ] && [ ! -f "$HOME/.local/share/applications/steam.desktop" ]; then
        echo "ERROR: steam.desktop not found" >&2
        return 1
    fi
    xdg-mime default steam.desktop x-scheme-handler/steam 2>/dev/null || true
    xdg-mime default steam.desktop x-scheme-handler/steamlink 2>/dev/null || true
    if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true; fi
    if command -v kbuildsycoca6 >/dev/null 2>&1; then kbuildsycoca6 --noincremental >/dev/null 2>&1 || true; fi
    if command -v kbuildsycoca5 >/dev/null 2>&1; then kbuildsycoca5 --noincremental >/dev/null 2>&1 || true; fi
    echo "steam_uri_handler=$(xdg-mime query default x-scheme-handler/steam 2>/dev/null || true)"
    echo "steamlink_uri_handler=$(xdg-mime query default x-scheme-handler/steamlink 2>/dev/null || true)"
}

case "$ACTION" in
    repair-uri-handler|repair-uri|fix-uri)
        repair_uri_handler
        exit $?
        ;;
    diagnose|status|json)
        ;;
    *)
        INPUT="$ACTION"
        ACTION="diagnose"
        ;;
esac

if [ -n "$INPUT" ] && [ ! -f "$INPUT" ]; then
    echo "ERROR: file not found: $INPUT" >&2
    exit 1
fi

python3 - "$INPUT" <<'PY'
import json
import pathlib
import sys

path = sys.argv[1] if len(sys.argv) > 1 else ""
raw = pathlib.Path(path).read_text(errors="replace") if path else sys.stdin.read()
start = raw.find("{")
end = raw.rfind("}")
if start < 0 or end < start:
    raise SystemExit("ERROR: no JSON object found")

data = json.loads(raw[start:end + 1])

def find_values(obj, key):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                yield v
            yield from find_values(v, key)
    elif isinstance(obj, list):
        for item in obj:
            yield from find_values(item, key)

def check(name, status, message="", recommendation=""):
    checks.append({
        "name": name,
        "status": status,
        "message": message,
        "recommendation": recommendation,
    })

checks = []
steam = data.get("steam-installation", {})
runtime = data.get("runtime", {})
display = data.get("display", {})
vulkan = data.get("vulkan", {})
layers = vulkan.get("implicit_layers", []) + vulkan.get("explicit_layers", [])
layer_names = {layer.get("name", "") for layer in layers}
issues = steam.get("issues", [])
library_summaries = list(find_values(data.get("architectures", {}), "library-issues-summary"))
cannot_load = sum(1 for summary in library_summaries if isinstance(summary, list) and "cannot-load" in summary)
renderers = [v for v in find_values(data, "renderer") if isinstance(v, str)]

check("steam.runtime.ok", "ok" if runtime.get("ok") else "warn", f"version={runtime.get('version', '')}")
check("steam.uinput", "ok" if data.get("can-write-uinput") else "warn", str(data.get("can-write-uinput")),
      "fix steam-devices/uinput permissions")
check("steam.uri-handler", "warn" if "unexpected-steam-uri-handler" in issues else "ok",
      ",".join(issues) if issues else "default handler ok",
      "run kbuildsycoca6 and ensure /usr/share/applications/steam.desktop is default")
check("steam.display.wayland", "ok" if display.get("wayland-ok") else "warn",
      f"type={display.get('x11-type', '')}")
check("steam.portal", "ok" if data.get("xdg-portals", {}).get("ok") else "warn")
check("vulkan.renderer", "ok" if any("RADV VANGOGH" in r or "AMD Custom GPU 0405" in r for r in renderers) else "warn",
      renderers[0] if renderers else "not found")
check("vulkan.steam-overlay", "ok" if any("steam_overlay" in name for name in layer_names) else "warn")
check("vulkan.mangohud", "ok" if any("MANGOHUD" in name for name in layer_names) else "warn",
      "MangoHud Vulkan layer")
check("vulkan.gamescope-wsi", "ok" if any("gamescope_wsi" in name for name in layer_names) else "warn",
      "Gamescope WSI Vulkan layer")
check("steam.library-load", "warn" if cannot_load else "ok",
      f"{cannot_load} architecture summaries include cannot-load",
      "inspect steam-runtime-system-info library details if games fail")

for container in ("scout", "soldier", "sniper"):
    missing = f'"{container} runtime container" is not installed' in raw
    check(f"steam.container.{container}", "info" if missing else "ok",
          "not installed" if missing else "installed/available",
          "Steam downloads container runtimes on demand")

recommendations = []
if "unexpected-steam-uri-handler" in issues:
    recommendations.append("repair Steam URI handler/default desktop entry")
if not any("MANGOHUD" in name for name in layer_names):
    recommendations.append("install mangohud lib32-mangohud")
if not any("gamescope_wsi" in name for name in layer_names):
    recommendations.append("install gamescope and gamescope WSI layer")
if not data.get("can-write-uinput"):
    recommendations.append("install steam-devices and fix uinput permissions")
if cannot_load:
    recommendations.append("library cannot-load exists; usually harmless unless a specific game fails")

status = "ok"
if any(c["status"] == "warn" for c in checks):
    status = "warn"

print(json.dumps({
    "module": "steamdeck-runtime",
    "status": status,
    "checks": checks,
    "recommendations": recommendations,
}, indent=2))
PY
