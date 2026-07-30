# Gap Analysis — 2026-07-28

## Scope
Security and reliability audit of `linux/` shell scripts and Python modules.

---

## 1. World-writable scripts (777 → 755)

10 files under `linux/ai/` have `chmod 777` — any local user/process can inject code.

Files: `9router-manager.sh`, `desktop-apps.sh`, `headroom-agent.sh`, `mcp-manager.sh`,
`menu.sh`, `odysseus-manager.sh`, `omniroute-manager.sh`, `proxy-suite.sh`,
`rotate-secrets.sh`, `setup-admin-bridge.sh`

**Fix:** `chmod 755`

---

## 2. `mktemp` without cleanup trap

29 files call `mktemp` but lack a `trap` handler to remove temp files on exit / crash.
Repeat runs fill `/tmp`.

---

## 3. `subprocess.run()` without `timeout` (Python)

8 call sites lack `timeout=` kwarg — can hang forever on network or device stall.

| File | Line |
|------|------|
| `linux/capabilities/providers.py` | 38, 52, 108 |
| `linux/capabilities/recipes.py` | 27, 32 |
| `linux/capabilities/platform.py` | 71, 86, 113 |
| `linux/emulation/romopt/convert.py` | 21 |
| `linux/emulation/romopt/tools.py` | 55 |
| `linux/emulation/romopt/verify.py` | 15, 31, 47, 82, 107 |

---

## 4. Missing `set -euo pipefail`

4 bash scripts lack strict mode — silently continue on error.

Files: `dolphin.sh`, `duckstation.sh`, `pcsx2.sh`, `display-session.sh`

---

## 5. Version pinning / reproducibility

`npm install -g` and `pip install` without pinned versions in 6 tool installers.
Non-reproducible across rebuilds.

---

## 6. Test coverage gaps

- AI shell scripts: 0 tests for 10 scripts
- Windows VM scripts: 0 tests for 6 scripts
- 160+ Pester tests only run on Windows — no Linux-equivalent suite
