from __future__ import annotations

import json
from pathlib import Path

from .models import ActionSpec

CATEGORIES = (
    ("Visão geral", "view-dashboard", "Saúde, auditoria e suporte"),
    ("Perfis", "package-x-generic", "Instalações completas"),
    ("Steam Deck", "input-gaming", "Modos, controles e SteamOS UX"),
    ("Windows VM", "computer", "QEMU/KVM e boot direto"),
    ("Waydroid", "phone", "Android, reparo e kiosk"),
    ("Servidor", "network-server", "LLM local, homelab e Hermes"),
    ("Emulação", "applications-games", "Emuladores, mídia e integrações"),
    ("Boot Direto", "system-reboot", "GRUB, recuperação e próxima sessão"),
    ("Flatpak", "system-software-install", "Remotes, overrides e compatibilidade"),
    ("IA & Dev", "applications-development", "Agentes, MCPs e ferramentas"),
    ("Ajustes", "preferences-system", "Gaming, navegador e desenvolvimento"),
    ("Resultados", "text-x-log", "Histórico local de operações"),
)

# The dashboard "home" pseudo-category (Welcome back screen).
DASHBOARD = ("Início", "go-home", "Bem-vindo de volta ao PhaseZero")

# Sidebar sections group categories by context (EmuDeck-style grouping).
SIDEBAR_GROUPS = (
    ("Ações rápidas", ("Início", "Visão geral", "Perfis")),
    ("Plataformas", ("Steam Deck", "Windows VM", "Waydroid", "Servidor", "Emulação")),
    ("Sistema", ("Boot Direto", "Flatpak", "Ajustes")),
    ("IA & Dev", ("IA & Dev",)),
    ("Histórico", ("Resultados",)),
)

# Curated dashboard cards: hero "Quick actions" and quieter "Tools & stuff".
DASHBOARD_QUICK = ("system.doctor", "profile.safe-base", "emulation.setup", "ai.status")
DASHBOARD_TOOLS = (
    "boot.selector",
    "steamdeck.status",
    "ai.opencode-free",
    "emulation.controllers",
    "flatpak.audit",
    "server.status",
)


def _a(
    action_id: str,
    category: str,
    title: str,
    description: str,
    args: tuple[str, ...],
    icon: str,
    *,
    mutable: bool = False,
    preview: tuple[str, ...] | None = None,
    elevated: bool = False,
    badge: str = "",
    input_label: str = "",
    input_kind: str = "",
    keywords: tuple[str, ...] = (),
) -> ActionSpec:
    if mutable and preview is None:
        raise ValueError(f"mutable action lacks safe preview: {action_id}")
    return ActionSpec(
        action_id,
        category,
        title,
        description,
        args,
        icon,
        mutable,
        preview,
        elevated,
        badge,
        input_label,
        input_kind,
        keywords,
    )


def build_catalog(root: Path) -> list[ActionSpec]:
    actions: list[ActionSpec] = [
        _a("system.doctor", "Visão geral", "Diagnóstico completo", "Audita host, boot, jogos, IA e integrações.", ("doctor",), "dialog-information", badge="Seguro"),
        _a("system.repair-plan", "Visão geral", "Plano de reparo", "Gera recomendações sem alterar sistema.", ("repair-plan",), "document-properties", badge="Seguro"),
        _a("system.support-bundle", "Visão geral", "Bundle de suporte", "Coleta logs sanitizados para diagnóstico.", ("support-bundle",), "folder-download", mutable=True, preview=("doctor",), badge="Coleta"),
        _a("system.version", "Visão geral", "Versão PhaseZero", "Mostra versão e canal instalados.", ("version",), "help-about"),
    ]

    profile_meta = {
        "safe-base": ("Base segura", "Essenciais para uso diário.", "Seguro"),
        "dev-ai": ("Dev + IA", "Toolchain Python, Node, Rust, agentes e modelos.", "Dev"),
        "gaming": ("Gaming", "Steam, Heroic, Lutris e telemetria local.", "Jogos"),
        "steamdeck-linux": ("Steam Deck Linux", "UX SteamOS, hotkeys e Gamepad UI.", "Recomendado"),
        "windows-vm-linux": ("Windows VM", "QEMU/KVM, OVMF, TPM e compartilhamentos.", "VM"),
        "waydroid-linux": ("Waydroid Linux", "Android container e sessão kiosk.", "Android"),
        "emulation-linux": ("Emulação Linux", "EmuDeck, frontends e layout compartilhado.", "Emulação"),
        "homelab": ("Homelab", "Docker, mídia, nuvem e monitoramento.", "Servidor"),
        "server-llm": ("Servidor LLM", "Ollama local + boot enxuto reversível.", "Servidor"),
        "server-homelab": ("Servidor Homelab", "Docker + Tailscale: drive, mídia, cofre, monitor.", "Servidor"),
        "server-homelab-hermes": ("Homelab + Hermes", "Servidor caseiro com atuação remota Hermes.", "Servidor"),
        "server-llm-hermes": ("LLM + Hermes", "LLM local + Hermes remoto, SO enxuto.", "Servidor"),
        "server-llm-homelab": ("LLM + Homelab", "LLM local + servidor caseiro, SO enxuto.", "Servidor"),
        "server-llm-homelab-hermes": ("Servidor completo", "LLM + homelab + Hermes combinados.", "Servidor"),
        "full-workstation": ("Workstation completa", "Composição ampla; opt-in explícito.", "Abrangente"),
    }
    for profile_file in sorted((root / "profiles").glob("*.json")):
        profile = profile_file.stem
        title, description, badge = profile_meta.get(profile, (profile, "Perfil PhaseZero.", "Perfil"))
        actions.append(
            _a(
                f"profile.{profile}",
                "Perfis",
                title,
                description,
                ("install", profile),
                "package-x-generic",
                mutable=True,
                preview=("install", profile, "--dry-run"),
                badge=badge,
                keywords=(profile,),
            )
        )

    actions.extend(
        [
            _a("steamdeck.status", "Steam Deck", "Status geral", "Estado consolidado do modo Steam Deck.", ("steamdeck", "status"), "input-gaming", badge="JSON"),
            _a("steamdeck.detect", "Steam Deck", "Detectar modo", "Detecta portátil, dock TV ou monitor.", ("steamdeck", "detect"), "video-display"),
            _a("steamdeck.handheld", "Steam Deck", "Modo portátil", "Aplica perfil portátil.", ("steamdeck", "handheld"), "input-gaming", mutable=True, preview=("steamdeck", "detect"), badge="Sessão"),
            _a("steamdeck.docked-tv", "Steam Deck", "Dock TV", "Aplica perfil TV e controles.", ("steamdeck", "docked-tv"), "video-display", mutable=True, preview=("steamdeck", "detect"), badge="Sessão"),
            _a("steamdeck.docked-monitor", "Steam Deck", "Dock monitor", "Aplica perfil desktop externo.", ("steamdeck", "docked-monitor"), "computer", mutable=True, preview=("steamdeck", "detect"), badge="Sessão"),
            _a("steamdeck.keyboard.toggle", "Steam Deck", "Teclado virtual", "Alterna teclado Steam/KDE.", ("steamdeck", "keyboard"), "input-keyboard", mutable=True, preview=("steamdeck", "keyboard", "status")),
            _a("steamdeck.keyboard.repair", "Steam Deck", "Reparar teclado", "Configura Maliit/KDE e integração Steam.", ("steamdeck", "keyboard", "repair"), "input-keyboard", mutable=True, preview=("steamdeck", "keyboard", "status"), badge="Reparo"),
            _a("steamdeck.console", "Steam Deck", "Abrir console", "Inicia Steam Gamepad UI.", ("steamdeck", "console", "auto"), "applications-games", mutable=True, preview=("steamdeck", "status")),
            _a("steamdeck.desktop", "Steam Deck", "Abrir desktop", "Inicia sessão dev/desktop.", ("steamdeck", "dev", "docked-monitor"), "user-desktop", mutable=True, preview=("steamdeck", "status")),
            _a("steamdeck.hotkeys", "Steam Deck", "Instalar hotkeys", "Instala Ctrl+Alt+F1…F6 e ações SteamOS.", ("steamdeck", "hotkeys", "install"), "preferences-desktop-keyboard-shortcuts", mutable=True, preview=("steamdeck", "status")),
            _a("steamdeck.watcher", "Steam Deck", "Instalar watcher", "Serviço que reage a dock e tela.", ("steamdeck", "watcher", "install"), "system-run", mutable=True, preview=("steamdeck", "status")),
            _a("steamdeck.privileged", "Steam Deck", "Controles privilegiados", "Bridge seguro para TDP/GPU.", ("steamdeck", "privileged", "install"), "security-high", mutable=True, preview=("steamdeck", "privileged", "status"), elevated=True),
            _a("steamdeck.boot", "Steam Deck", "Boot SteamOS", "Instala entrada de boot Gamepad UI.", ("steamdeck", "boot", "install"), "system-reboot", mutable=True, preview=("steamdeck", "boot", "status"), elevated=True),
            _a("steamdeck.plugins", "Steam Deck", "Instalar Decky", "Decky Loader e plugins curados.", ("steamdeck", "plugins", "install"), "application-x-addon", mutable=True, preview=("steamdeck", "plugins", "status"), badge="Plugins"),
            _a("steamdeck.plugins.repair", "Steam Deck", "Reparar Decky", "Restaura loader e plugins.", ("steamdeck", "plugins", "repair"), "tools-check-spelling", mutable=True, preview=("steamdeck", "plugins", "status"), badge="Reparo"),
            _a("steamdeck.launch-options", "Steam Deck", "Launch options", "Lista presets para jogos Steam.", ("steamdeck", "launch-options"), "document-properties"),
            _a("steamdeck.runtime", "Steam Deck", "Diagnóstico runtime", "Analisa runtime Steam e bibliotecas.", ("steamdeck", "runtime-diagnose"), "utilities-terminal"),
        ]
    )

    actions.extend(
        [
            _a("windows.status", "Windows VM", "Status Windows VM", "Estado KVM, disco, domínio e boot.", ("windows-vm", "status"), "computer", badge="JSON"),
            _a("windows.discover", "Windows VM", "Descobrir instalações", "Procura discos Windows existentes.", ("windows-vm", "discover", "--json"), "drive-harddisk"),
            _a("windows.plan", "Windows VM", "Planejar instalação", "Prévia com ISO selecionada.", ("windows-vm", "plan", "--iso", "{input}"), "document-properties", input_label="Selecione ISO do Windows", input_kind="file"),
            _a("windows.install", "Windows VM", "Instalar Windows VM", "Cria disco, domínio e launchers.", ("windows-vm", "install", "--iso", "{input}"), "system-software-install", mutable=True, preview=("windows-vm", "plan", "--iso", "{input}"), input_label="Selecione ISO do Windows", input_kind="file", badge="Requer ISO"),
            _a("windows.adopt", "Windows VM", "Adotar disco Windows", "Integra instalação existente.", ("windows-vm", "adopt", "--disk", "{input}"), "drive-harddisk", mutable=True, preview=("windows-vm", "discover", "--json"), input_label="Selecione disco qcow2/raw", input_kind="file"),
            _a("windows.optimize", "Windows VM", "Otimizar host", "Ajustes temporários para QEMU.", ("windows-vm", "optimize"), "preferences-system-performance", mutable=True, preview=("windows-vm", "status")),
            _a("windows.launch", "Windows VM", "Abrir Windows", "Inicia VM configurada em tela cheia.", ("windows-vm", "launch", "--fullscreen"), "media-playback-start", mutable=True, preview=("windows-vm", "status")),
            _a("windows.boot.install", "Windows VM", "Instalar boot direto", "Entrada GRUB para Windows VM.", ("windows-vm", "boot", "install"), "system-reboot", mutable=True, preview=("windows-vm", "boot", "status"), elevated=True),
            _a("windows.boot.next", "Windows VM", "Próximo boot Windows", "Agenda uma sessão Windows VM.", ("windows-vm", "boot", "next-reboot"), "system-reboot", mutable=True, preview=("windows-vm", "boot", "status"), elevated=True),
        ]
    )

    actions.extend(
        [
            _a("waydroid.status", "Waydroid", "Status Waydroid", "Container, imagens, binder e sessão.", ("waydroid", "status", "--json"), "phone", badge="JSON"),
            _a("waydroid.plan", "Waydroid", "Plano Waydroid", "Prévia de instalação e kiosk.", ("waydroid", "plan"), "document-properties"),
            _a("waydroid.install", "Waydroid", "Instalar Waydroid", "Configura container e launchers.", ("waydroid", "install"), "system-software-install", mutable=True, preview=("waydroid", "plan"), elevated=True),
            _a("waydroid.repair", "Waydroid", "Reparar Waydroid", "Repara host, serviços e sessão.", ("waydroid", "repair"), "tools-check-spelling", mutable=True, preview=("waydroid", "plan"), elevated=True),
            _a("waydroid.launch", "Waydroid", "Abrir Waydroid", "Inicia sessão otimizada.", ("waydroid", "launch"), "media-playback-start", mutable=True, preview=("waydroid", "status", "--json")),
            _a("waydroid.boot.install", "Waydroid", "Instalar boot direto", "Entrada GRUB para sessão Android.", ("waydroid", "boot", "install"), "system-reboot", mutable=True, preview=("waydroid", "boot", "status"), elevated=True),
            _a("waydroid.boot.next", "Waydroid", "Próximo boot Android", "Agenda sessão Waydroid.", ("waydroid", "boot", "next-reboot"), "system-reboot", mutable=True, preview=("waydroid", "boot", "status"), elevated=True),
            _a("waydroid.host-access", "Waydroid", "Acesso host → Android", "Link para o armazenamento interno do Waydroid.", ("waydroid", "host-access", "link"), "folder-remote", mutable=True, preview=("waydroid", "host-access", "status")),
        ]
    )
    actions.append(
        _a("windows.host-access", "Windows VM", "Acesso host → disco VM", "Monta o disco da VM no host (libguestfs).", ("windows-vm", "host-access", "mount"), "drive-harddisk", mutable=True, preview=("windows-vm", "host-access", "status")),
    )

    actions.extend(
        [
            _a("server.status", "Servidor", "Status servidor", "LLM local, homelab e entrada GRUB.", ("server", "status"), "network-server", badge="JSON"),
            _a("server.llm", "Servidor", "Instalar LLM local", "Ollama como servidor (opcional LAN).", ("server", "llm", "install"), "applications-science", mutable=True, preview=("server", "llm", "status")),
            _a("server.homelab.status", "Servidor", "Status Homelab", "Docker, Tailscale, secrets, apps, portas e volumes.", ("server", "homelab", "status", "--json"), "server-database", badge="JSON", keywords=("homelab", "portainer", "casaos")),
            _a("server.homelab.plan", "Servidor", "Plano Homelab", "Mostra blockers e próximos passos sem alterar sistema.", ("server", "homelab", "plan"), "document-properties", badge="Seguro", keywords=("homelab", "secrets")),
            _a("server.homelab.repair", "Servidor", "Preparar Homelab", "Gera .env seguro, secrets locais e valida compose.", ("server", "homelab", "repair"), "tools-check-spelling", mutable=True, preview=("server", "homelab", "plan"), badge="Reparo"),
            _a("server.homelab.up", "Servidor", "Subir homelab local", "Stack Docker local-only: mídia, cofre, monitor.", ("server", "homelab", "up", "--access", "local"), "server-database", mutable=True, preview=("server", "homelab", "plan", "--access", "local"), badge="Docker"),
            _a("server.homelab.up-tailscale", "Servidor", "Subir via Tailscale", "Expõe apps no IP Tailscale quando autenticado.", ("server", "homelab", "up", "--access", "tailscale"), "network-server", mutable=True, preview=("server", "homelab", "plan", "--access", "tailscale"), badge="Docker"),
            _a("server.homelab.up-extras", "Servidor", "Subir extras Homelab", "Nextcloud, Grafana, Prometheus, Paperless e n8n.", ("server", "homelab", "up", "--extras", "--access", "tailscale"), "server-database", mutable=True, preview=("server", "homelab", "plan", "--extras", "--access", "tailscale"), badge="Pesado"),
            _a("server.homelab.down", "Servidor", "Parar homelab", "Encerra a stack (volumes preservados).", ("server", "homelab", "down"), "media-playback-stop", mutable=True, preview=("server", "homelab", "status")),
            _a("server.homelab.open-portainer", "Servidor", "Abrir Portainer", "Dashboard Docker local.", ("server", "homelab", "open", "portainer"), "utilities-system-monitor", keywords=("portainer",)),
            _a("server.homelab.open-jellyfin", "Servidor", "Abrir Jellyfin", "Biblioteca de mídia.", ("server", "homelab", "open", "jellyfin"), "applications-multimedia", keywords=("jellyfin",)),
            _a("server.homelab.open-vaultwarden", "Servidor", "Abrir Vaultwarden", "Cofre Bitwarden compatível.", ("server", "homelab", "open", "vaultwarden"), "dialog-password", keywords=("vaultwarden", "bitwarden")),
            _a("server.homelab.open-kuma", "Servidor", "Abrir Uptime Kuma", "Monitoramento de serviços.", ("server", "homelab", "open", "uptime-kuma"), "utilities-system-monitor", keywords=("uptime", "kuma")),
            _a("server.homelab.logs", "Servidor", "Logs Portainer", "Mostra logs recentes do dashboard Docker.", ("server", "homelab", "logs", "portainer"), "text-x-log", keywords=("logs",)),
            _a("server.homelab.backup", "Servidor", "Backup Homelab", "Salva volumes nomeados em arquivo tar.gz.", ("server", "homelab", "backup"), "document-save", mutable=True, preview=("server", "homelab", "backup", "--dry-run"), badge="Backup"),
            _a("server.homelab.restore", "Servidor", "Restaurar Homelab", "Restaura volumes a partir de backup local.", ("server", "homelab", "restore", "--source", "{input}", "--yes"), "document-revert", mutable=True, preview=("server", "homelab", "restore", "--source", "{input}", "--dry-run"), input_label="Selecione pasta de backup Homelab", input_kind="path", badge="Resgate"),
            _a("server.homelab.update", "Servidor", "Atualizar Homelab", "Backup antes de pull/up com tags fixas.", ("server", "homelab", "update"), "system-software-update", mutable=True, preview=("server", "homelab", "update", "--dry-run"), badge="Backup"),
            _a("server.homelab.tailscale", "Servidor", "Autenticar Tailscale", "Prepara acesso remoto privado para o Homelab.", ("server", "homelab", "tailscale"), "network-vpn", mutable=True, preview=("server", "homelab", "plan", "--access", "tailscale"), elevated=True),
            _a("server.casaos.status", "Servidor", "Status CasaOS", "Detecta instalação e compatibilidade.", ("server", "casaos", "status"), "network-server", badge="JSON", keywords=("casaos", "zimaos")),
            _a("server.casaos.plan", "Servidor", "Plano CasaOS", "Mostra bloqueios antes de qualquer install.", ("server", "casaos", "plan"), "document-properties", badge="Seguro", keywords=("casaos", "zimaos")),
            _a("server.casaos.install", "Servidor", "Instalar CasaOS", "Opt-in Linux compatível; bloqueia Steam Deck/Arch.", ("server", "casaos", "install", "--yes"), "system-software-install", mutable=True, preview=("server", "casaos", "plan"), elevated=True, badge="Alto risco", keywords=("casaos", "zimaos")),
            _a("server.hermes", "Servidor", "Configurar Hermes", "Atuação remota via Tailscale.", ("server", "hermes", "setup"), "network-transmit-receive", mutable=True, preview=("server", "hermes", "status")),
            _a("server.slim", "Servidor", "Enxugar SO", "Desliga serviços de desktop (reversível).", ("server", "slim", "apply"), "preferences-system-performance", mutable=True, preview=("server", "slim", "status"), elevated=True, badge="Reversível"),
            _a("server.slim.restore", "Servidor", "Reverter enxugamento", "Restaura serviços desligados.", ("server", "slim", "restore"), "edit-undo", mutable=True, preview=("server", "slim", "status"), elevated=True),
            _a("server.boot.install", "Servidor", "Instalar boot Homelab", "Entrada GRUB headless enxuta.", ("server", "boot", "install", "--llm", "--homelab"), "system-reboot", mutable=True, preview=("server", "boot", "dry-run", "--llm", "--homelab"), elevated=True),
            _a("server.boot.next", "Servidor", "Próximo boot Homelab", "Agenda sessão servidor headless.", ("server", "boot", "next-reboot"), "system-reboot", mutable=True, preview=("server", "boot", "status"), elevated=True),
        ]
    )

    emu_rows = [
        ("status", "Status emulação", "Auditoria geral.", ("emulation", "status"), None),
        ("setup", "Setup completo", "Stack completa de emulação.", ("emulation", "setup", "install"), ("emulation", "setup", "dry-run")),
        ("layout", "Criar layout", "Pastas compartilhadas de ROMs, BIOS e saves.", ("emulation", "layout"), ("emulation", "status")),
        ("emudeck", "Instalar EmuDeck", "Launcher AppImage e integração.", ("emulation", "emudeck", "install"), ("emulation", "emudeck", "dry-run")),
        ("eden", "Instalar Eden", "Emulador Switch AppImage.", ("emulation", "eden", "install"), ("emulation", "eden", "dry-run")),
        ("citron", "Instalar Citron", "Emulador Switch AppImage.", ("emulation", "citron", "install"), ("emulation", "citron", "dry-run")),
        ("hydra", "Instalar Hydra", "Hydra Classic e atalho SteamOS.", ("emulation", "hydra", "install"), ("emulation", "hydra", "dry-run")),
        ("srm", "Configurar SRM", "Paths e parsers Steam ROM Manager.", ("emulation", "srm", "configure"), ("emulation", "srm", "dry-run")),
        ("retrodeck", "Integrar RetroDECK", "Compartilha ROMs, BIOS, saves e mídia.", ("emulation", "retrodeck", "integrate"), ("emulation", "retrodeck", "plan")),
        ("shared", "Aplicar conteúdo compartilhado", "Links e cópias seguras entre frontends.", ("emulation", "shared", "apply"), ("emulation", "shared", "plan")),
        ("media", "Aplicar mídia canônica", "Normaliza capas e metadados.", ("emulation", "media", "apply"), ("emulation", "media", "plan")),
        ("media-clean", "Limpar mídia órfã", "Move capas de ROMs removidas para backup.", ("emulation", "media", "clean", "--apply"), ("emulation", "media", "clean")),
        ("pc-games", "Reparar jogos PC", "Integra Heroic, Hydra, SRM e ES-DE.", ("emulation", "pc-games", "repair"), ("emulation", "pc-games", "plan")),
        ("shortcuts", "Reparar atalhos", "Remove duplicatas e corrige AppImages.", ("emulation", "shortcuts", "repair"), ("emulation", "shortcuts", "plan")),
        ("launchbox-install", "Instalar LaunchBox 13.5", "Instalação limpa, transacional e isolada.", ("emulation", "launchbox", "install-clean"), ("emulation", "launchbox", "status")),
        ("launchbox-sync", "Sincronizar LaunchBox", "Reconstrói biblioteca usando ROMs e mídia do ES-DE.", ("emulation", "launchbox", "import-esde"), ("emulation", "launchbox", "status")),
        ("launchbox-verify", "Verificar LaunchBox", "Valida executáveis, XML, capas e contagens.", ("emulation", "launchbox", "verify"), ("emulation", "launchbox", "status")),
        ("bigbox-test", "Testar Big Box", "Confirma janela visível e imagem não preta.", ("emulation", "launchbox", "verify", "--real"), ("emulation", "launchbox", "status")),
        ("controllers", "Controles Steam Deck", "Perfil de gamepad para Ryujinx e RPCS3.", ("emulation", "controllers", "apply"), ("emulation", "controllers", "status")),
        ("frontends", "Reparar frontends", "Switcher BigBox, Steam, ES-DE e Heroic.", ("emulation", "frontends", "repair"), ("emulation", "frontends", "plan")),
        ("performance", "Aplicar performance", "Perfis adaptativos Switch/PS3/PS4.", ("emulation", "performance", "apply"), ("emulation", "performance", "plan")),
        ("lsfg", "Preparar LSFG", "Instala layer Vulkan verificada.", ("emulation", "performance", "prepare-lsfg"), ("emulation", "performance", "status")),
        ("lua", "Instalar Lua", "Lua, LuaJIT e LuaRocks.", ("emulation", "lua", "install"), ("emulation", "lua", "dry-run")),
        ("steam-tools", "Instalar Steam tools", "Ferramentas auxiliares e backups.", ("emulation", "steam-tools", "install"), ("emulation", "steam-tools", "dry-run")),
        ("heroic", "Reparar Heroic", "Defaults, biblioteca e menu KDE.", ("emulation", "heroic", "repair"), ("emulation", "heroic", "plan")),
        ("doctor", "Diagnóstico emulação", "Auditoria completa do ecossistema.", ("emulation", "doctor", "--json"), None),
        ("fixes", "Reparos amigáveis", "Lista correções disponíveis.", ("emulation", "fixes", "list"), None),
        ("optimizers", "Aplicar configs por jogo", "14 perfis DuckStation, PCSX2 e Dolphin.", ("emulation", "optimizer", "apply-all"), ("emulation", "optimizer", "plan")),
    ]
    for key, title, description, args, preview in emu_rows:
        actions.append(
            _a(
                f"emulation.{key}",
                "Emulação",
                title,
                description,
                args,
                "applications-games",
                mutable=preview is not None,
                preview=preview,
                badge="Preview" if preview else "",
            )
        )
    actions.extend(
        [
            _a("emulation.bios", "Emulação", "Importar BIOS", "Importa BIOS obtida legalmente.", ("emulation", "bios", "import", "{input}"), "folder-open", mutable=True, preview=("emulation", "bios", "status"), input_label="Selecione pasta/arquivo BIOS", input_kind="path", badge="Arquivo local"),
            _a("emulation.keys", "Emulação", "Importar Switch keys", "Importa keys próprias.", ("emulation", "switch", "import-keys", "{input}"), "dialog-password", mutable=True, preview=("emulation", "status"), input_label="Selecione prod.keys", input_kind="file", badge="Arquivo local"),
            _a("emulation.firmware", "Emulação", "Importar firmware", "Importa firmware próprio.", ("emulation", "switch", "import-firmware", "{input}"), "folder-open", mutable=True, preview=("emulation", "status"), input_label="Selecione firmware", input_kind="path", badge="Arquivo local"),
            _a("emulation.nsz", "Emulação", "Converter NSZ", "Conversão atômica NSZ → NSP.", ("emulation", "nsz", "convert", "{input}"), "document-export", mutable=True, preview=("emulation", "nsz", "plan", "{input}"), input_label="Selecione NSZ ou pasta", input_kind="path"),
            _a("emulation.ps3-game", "Emulação", "Importar jogo PS3", "Importa dump próprio.", ("emulation", "ps3", "import-game", "{input}"), "folder-open", mutable=True, preview=("emulation", "ps3", "dry-run"), input_label="Selecione dump PS3", input_kind="path"),
        ]
    )

    actions.extend(
        [
            _a("boot.status", "Boot Direto", "Status boot", "Audita GRUB, ESP e entradas PhaseZero.", ("boot", "status"), "system-reboot"),
            _a("boot.selector", "Boot Direto", "Seletor visual", "Escolhe próxima sessão antes do reboot.", ("boot", "selector"), "view-list-icons"),
            _a("boot.menu", "Boot Direto", "Abrir menu texto", "Lista escolhas de próxima sessão.", ("boot", "menu"), "view-list-icons"),
            _a("boot.safe-menu", "Boot Direto", "Instalar menu seguro", "Mantém GRUB visível com timeout.", ("boot", "install-safe-menu"), "security-high", mutable=True, preview=("boot", "safe-menu", "dry-run"), elevated=True, badge="Protegido"),
            _a("boot.card", "Boot Direto", "Cartão de recuperação", "Mostra comandos de resgate deste host.", ("boot", "card"), "help-browser"),
            _a("boot.install-card", "Boot Direto", "Salvar cartão", "Grava cartão no host e ESP.", ("boot", "install-card"), "document-save", mutable=True, preview=("boot", "card"), elevated=True),
            _a("boot.efi", "Boot Direto", "Instalar EFI fallback", "Instala EFI standalone por UUID.", ("boot", "install-efi-fallback", "--fallback"), "drive-harddisk", mutable=True, preview=("boot", "status"), elevated=True, badge="Alto risco"),
            _a("boot.normal", "Boot Direto", "Próximo: Linux normal", "Agenda boot normal.", ("boot", "choose", "normal"), "system-reboot", mutable=True, preview=("boot", "status"), elevated=True),
            _a("boot.steamos", "Boot Direto", "Próximo: SteamOS", "Agenda Steam Gamepad UI.", ("boot", "choose", "steamos"), "input-gaming", mutable=True, preview=("boot", "status"), elevated=True),
            _a("boot.windows", "Boot Direto", "Próximo: Windows VM", "Agenda Windows virtualizado.", ("boot", "choose", "windows"), "computer", mutable=True, preview=("boot", "status"), elevated=True),
            _a("boot.waydroid", "Boot Direto", "Próximo: Waydroid", "Agenda Android kiosk.", ("boot", "choose", "waydroid"), "phone", mutable=True, preview=("boot", "status"), elevated=True),
            _a("boot.emergency", "Boot Direto", "Próximo: emergência", "Agenda rescue.target.", ("boot", "emergency-shell", "next"), "dialog-warning", mutable=True, preview=("boot", "emergency-shell", "dry-run"), elevated=True, badge="Resgate"),
        ]
    )

    actions.extend(
        [
            _a("flatpak.status", "Flatpak", "Status Flatpak", "Estado da instalação e remotes.", ("flatpak", "status"), "system-software-install"),
            _a("flatpak.audit", "Flatpak", "Auditar Flatpak", "Conflitos de remote, override e runtime.", ("flatpak", "audit"), "system-search"),
            _a("flatpak.repair", "Flatpak", "Reparar Flatpak", "Corrige conflitos detectados.", ("flatpak", "audit", "--repair"), "tools-check-spelling", mutable=True, preview=("flatpak", "audit")),
            _a("flatpak.remotes", "Flatpak", "Listar remotes", "Repositórios configurados.", ("flatpak", "remotes"), "network-server"),
            _a("flatpak.steamdeck", "Flatpak", "Compatibilidade Steam Deck", "Overrides e runtimes gaming.", ("flatpak", "steamdeck-compat"), "input-gaming", mutable=True, preview=("flatpak", "audit")),
            _a("flatpak.rollback", "Flatpak", "Rollback", "Reverte alterações PhaseZero.", ("flatpak", "rollback"), "edit-undo", mutable=True, preview=("flatpak", "audit"), badge="Reversível"),
        ]
    )

    ai_rows = [
        ("status", "Status IA", "Stack local e agentes.", ("ai", "status"), None),
        ("doctor", "Diagnóstico MCP", "Audita integrações MCP.", ("ai", "doctor"), None),
        ("repair", "Reparar MCP/IDE", "Repara integrações seguras.", ("ai", "repair"), ("ai", "doctor")),
        ("desktop", "Reparar apps desktop", "Claude/Codex e atualizadores.", ("ai", "desktop", "repair"), ("ai", "desktop", "status")),
        ("compat", "Agent compatibility", "RTK, Caveman, Headroom e memória.", ("ai", "compat", "setup"), ("ai", "compat", "status")),
        ("admin", "Admin bridge", "Instala phasezero-admin/bigsudo.", ("ai", "setup", "admin"), ("ai", "admin", "status")),
        ("opencode", "Sincronizar OpenCode", "Alinha CLI e desktop.", ("ai", "opencode", "sync"), ("ai", "opencode", "status")),
        ("opencode-free", "Modelo free OpenCode", "Corrige 'Interrompido' com modelo free (deepseek-flash).", ("ai", "opencode", "free-model"), ("ai", "opencode", "status")),
        ("omo", "Instalar OMO", "Plugin oh-my-openagent.", ("ai", "omo", "setup"), ("ai", "omo", "status")),
        ("memory", "Instalar ai-memory", "Memória persistente de agentes.", ("ai", "setup", "memory"), ("ai", "status")),
        ("ollama", "Instalar Ollama", "Runtime local de modelos.", ("ai", "setup", "ollama"), ("ai", "status")),
        ("webui", "Instalar Open WebUI", "Interface local de modelos.", ("ai", "setup", "webui"), ("ai", "status")),
        ("usagebar", "Instalar UsageBar", "Uso de provedores no painel.", ("ai", "setup", "usagebar"), ("ai", "status")),
        ("ides", "Configurar IDEs", "Integrações de agentes.", ("ai", "setup", "ides"), ("ai", "status")),
        ("mcp-sync", "Sincronizar MCPs", "Sincroniza defaults seguros.", ("ai", "mcp", "sync", "all"), ("ai", "mcp", "status")),
        ("proxies", "Instalar proxies IA", "Suite Linux OpenAI-compatible.", ("ai", "proxies", "install", "all"), ("ai", "proxies", "status")),
        ("proxies-ides", "Configurar proxies nas IDEs", "Wire opencode/opencode-desktop/zcode.", ("ai", "proxies", "configure-ides"), ("ai", "proxies", "status")),
        ("proxies-auth", "Auth proxies IA", "Status redigido de login/sessão.", ("ai", "proxies", "auth", "all"), None),
        ("proxies-login-kimi", "Login Kimi", "Abre Chromium visível para salvar sessão.", ("ai", "proxies", "login", "kimiproxy"), ("ai", "proxies", "auth", "kimiproxy")),
        ("proxies-login-qwen", "Login Qwen", "Abre fluxo manual de browser do QwenProxy.", ("ai", "proxies", "login", "qwenproxy"), ("ai", "proxies", "auth", "qwenproxy")),
        ("proxies-login-deeps", "Login DeepSeek", "Abre Chromium visível para salvar sessão.", ("ai", "proxies", "login", "deepsproxy"), ("ai", "proxies", "auth", "deepsproxy")),
        ("proxies-test", "Testar proxies IA", "Probe honesto /v1/models + chat.", ("ai", "proxies", "test"), None),
    ]
    for key, title, description, args, preview in ai_rows:
        actions.append(
            _a(
                f"ai.{key}",
                "IA & Dev",
                title,
                description,
                args,
                "applications-development",
                mutable=preview is not None,
                preview=preview,
                badge="Preview" if preview else "",
            )
        )

    for area, title, description in [
        ("browser", "Hardening navegador", "Privacidade e segurança."),
        ("gaming", "Ajustes gaming", "Performance e latência."),
        ("dev", "Ajustes dev", "Toolchain e limites do host."),
    ]:
        actions.append(
            _a(
                f"tune.{area}",
                "Ajustes",
                title,
                description,
                ("tune", area),
                "preferences-system",
                mutable=True,
                preview=("doctor",),
                badge="Sistema",
            )
        )

    ids = [item.id for item in actions]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate action id in native UI catalog")
    return actions


def catalog_manifest(root: Path) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "categories": [row[0] for row in CATEGORIES],
        "actions": [
            {
                "id": item.id,
                "category": item.category,
                "title": item.title,
                "args": list(item.args),
                "previewArgs": list(item.preview_args) if item.preview_args else None,
                "mutable": item.mutable,
                "elevated": item.elevated,
            }
            for item in build_catalog(root)
        ],
    }


def write_manifest(root: Path, destination: Path) -> None:
    destination.write_text(json.dumps(catalog_manifest(root), ensure_ascii=False, indent=2) + "\n")
