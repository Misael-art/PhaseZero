<div align="center">
  <img src="https://img.shields.io/badge/Windows-0078D6?style=for-the-badge&logo=windows&logoColor=white" />
  <img src="https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" />
  <img src="https://img.shields.io/badge/Steam_Deck-151014?style=for-the-badge&logo=steamdeck&logoColor=white" />

  <h1>🚀 PhaseZero</h1>
  <p><strong>Bootstrap and post-install hub for Windows and Steam Deck</strong></p>
</div>

---

## What is PhaseZero?

PhaseZero is an on-demand orchestrator that forges a target environment from named profiles. Includes a CLI and a WPF UI. Targets Gamers, Developers, Content Creators and AI Enthusiasts.

## Features

- 🎮 **Steam Deck Essentials & Automation**: Custom setup for Steam Deck (LCD/OLED) running Windows. Display profile detection (Handheld, TV, Monitor), overlay, audio routing, hotkeys keyed by monitor family, full Steam Deck Tools support.
- 🤖 **AI Profile**: Quick deploy of contemporary AI stacks: Claude Desktop, Cursor, Trae, Gemini CLI, Ollama and more.
- 🛠️ **DevForge Hub**: SDKs, Winget, WSL/Docker, Node LTS, Python 3.13+, Git LFS and key utilities installed silently.
- 🎨 **Optional UI**: WPF wizard (`bootstrap-ui.bat`) for users who prefer clicks over flags.
- 🧹 **Host Health**: Resource monitor, kill background apps while gaming, system cleanup.
- 🔁 **Resume on retry**: Set `BOOTSTRAP_RESUME=1` to skip components already completed in `~/.bootstrap-tools/progress.json`.

## Built-in profiles

* **base** — universal kit (browsers, git, robust terminals).
* **containers** + **game-dev** — WSL2, Docker, CMake/Unity.
* **ai** — local cognitive cluster.
* **steamdeck-recommended** / **steamdeck-full** — handheld/dock automation, display profiles by monitor family with generic fallback.
* **recommended** / **full** — bundled selections.

## Usage

```powershell
git clone https://github.com/Misael-art/PhaseZero.git
cd PhaseZero
```

Through the wizard:

```cmd
.\bootstrap-ui.bat
```

Direct CLI:

```powershell
.\bootstrap-tools.ps1 -ProfileName recommended -HostHealth conservador
.\bootstrap-tools.ps1 -ListProfiles
.\bootstrap-tools.ps1 -DryRun -ProfileName steamdeck-full
```

## Customization

Add components in `bootstrap-tools.ps1` via `New-BootstrapComponentDefinition`, passing winget IDs, npm packages or direct download URLs (use `Invoke-BootstrapDownloadVerified` for SHA256-checked downloads).

## Environment flags

| Variable | Effect |
|----------|--------|
| `BOOTSTRAP_RESUME=1` | Skip components persisted in progress.json |
| `BOOTSTRAP_REMOVE_WINDOWS_OLD=1` | Authorize HostHealth to remove `C:\Windows.old` |
| `BOOTSTRAP_HOOKS_DEEP_SCAN=1` | Enable extended scan for Claude hook config files |

## License

See repository.
