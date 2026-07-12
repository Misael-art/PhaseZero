from __future__ import annotations

import json
import re
from pathlib import Path

from .models import ActionParameter, ActionSpec
from .platform import current_platform

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
    ("Recursos", "preferences-plugin", "Gaming, hardware, saúde e workstation"),
    ("IA & Dev", "applications-development", "Agentes, MCPs e ferramentas"),
    ("Aplicativos", "applications-other", "Web apps, jogos e menus do desktop"),
    ("Ajustes", "preferences-system", "Gaming, navegador e desenvolvimento"),
    ("Resultados", "text-x-log", "Histórico local de operações"),
)

# The dashboard "home" pseudo-category (Welcome back screen).
DASHBOARD = ("Início", "go-home", "Bem-vindo de volta ao PhaseZero")

# Sidebar sections group categories by context (EmuDeck-style grouping).
SIDEBAR_GROUPS = (
    ("Ações rápidas", ("Início", "Visão geral", "Perfis")),
    ("Plataformas", ("Steam Deck", "Windows VM", "Waydroid", "Servidor", "Emulação")),
    ("Sistema", ("Boot Direto", "Flatpak", "Recursos", "Ajustes")),
    ("IA & Dev", ("IA & Dev",)),
    ("Desktop", ("Aplicativos",)),
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
    group: str = "",
    visibility: str = "",
    platforms: tuple[str, ...] = ("linux",),
    risk: str = "",
    parameters: tuple[ActionParameter, ...] = (),
    preview_bindings: tuple[tuple[str, str], ...] = (),
    result_view: str = "auto",
) -> ActionSpec:
    if mutable and preview is None:
        raise ValueError(f"mutable action lacks safe preview: {action_id}")
    family = action_id.split(".", 1)[0]
    inferred_group = group or {
        "system": "Saúde e suporte",
        "profile": "Instalação",
        "steamdeck": "SteamOS",
        "windows": "Windows VM",
        "waydroid": "Android",
        "server": "Serviços",
        "emulation": "Emulação",
        "boot": "Boot e recuperação",
        "flatpak": "Aplicativos",
        "capability": "Recursos",
        "ai": "IA e agentes",
        "desktop": "Desktop",
        "tune": "Ajustes",
    }.get(family, "Geral")
    inferred_risk = risk or ("high" if badge in {"Alto risco", "Resgate"} else "elevated" if elevated else "normal")
    inferred_visibility = visibility or ("advanced" if inferred_risk in {"high", "elevated"} else "standard")
    inferred_parameters = parameters
    if input_kind and not inferred_parameters:
        inferred_parameters = (ActionParameter("input", input_label or "Entrada", input_kind),)
    return ActionSpec(
        id=action_id,
        category=category,
        title=title,
        description=description,
        args=args,
        icon=icon,
        mutable=mutable,
        preview_args=preview,
        elevated=elevated,
        badge=badge,
        input_label=input_label,
        input_kind=input_kind,
        keywords=keywords,
        group=inferred_group,
        visibility=inferred_visibility,
        platforms=platforms,
        risk=inferred_risk,
        status_args=preview if mutable else args,
        parameters=inferred_parameters,
        preview_bindings=preview_bindings,
        result_view=result_view,
    )


def _p(
    name: str,
    label: str,
    kind: str = "text",
    *,
    required: bool = True,
    choices: tuple[str, ...] = (),
    placeholder: str = "",
) -> ActionParameter:
    return ActionParameter(name, label, kind, required, choices, placeholder)


def build_catalog(root: Path, platform_name: str | None = None) -> list[ActionSpec]:
    actions: list[ActionSpec] = [
        _a("system.doctor", "Visão geral", "Diagnóstico completo", "Audita host, boot, jogos, IA e integrações.", ("doctor",), "dialog-information", badge="Seguro"),
        _a("system.repair-plan", "Visão geral", "Plano de reparo", "Gera recomendações sem alterar sistema.", ("repair-plan",), "document-properties", badge="Seguro"),
        _a("system.support-bundle", "Visão geral", "Bundle de suporte", "Coleta logs sanitizados para diagnóstico.", ("support-bundle",), "folder-download", mutable=True, preview=("doctor",), badge="Coleta"),
        _a("system.version", "Visão geral", "Versão PhaseZero", "Mostra versão e canal instalados.", ("version",), "help-about"),
        _a("system.installation.status", "Visão geral", "Canais instalados", "Audita versões user, pacote nativo, Flatpak e raízes órfãs.", ("installation", "status"), "system-search", badge="JSON", group="Instalação PhaseZero", visibility="primary", result_view="table"),
        _a(
            "system.installation.converge", "Visão geral", "Convergir instalação",
            "Preserva backup e mantém somente o canal de usuário verificado.",
            ("installation", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
            "system-software-update", mutable=True,
            preview=("installation", "plan", "--channel", "user"),
            preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
            elevated=True, badge="Alto risco", risk="high", group="Instalação PhaseZero",
            visibility="advanced", result_view="table",
        ),
        _a("system.installation.prune", "Visão geral", "Aplicar retenção", "Mantém releases, resultados e backups recentes dentro dos limites.", ("installation", "prune"), "edit-clear", mutable=True, preview=("installation", "status"), badge="Reversível", group="Instalação PhaseZero", visibility="advanced"),
        _a("system.self-update.check", "Visão geral", "Verificar atualização", "Consulta release oficial sem instalar.", ("self-update", "check"), "system-software-update", group="Instalação PhaseZero", visibility="primary"),
        _a(
            "system.self-update.apply", "Visão geral", "Atualizar PhaseZero",
            "Baixa source bundle oficial, verifica dois SHA-256 e troca release atomicamente.",
            ("self-update", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
            "system-software-update", mutable=True, preview=("self-update", "plan"),
            preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
            badge="Protegido", group="Instalação PhaseZero", visibility="primary",
        ),
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
            _a("steamdeck.removable", "Steam Deck", "Montar removíveis", "Auto-mount USB (ignora durante Windows VM).", ("steamdeck", "removable", "install"), "drive-removable-media", mutable=True, preview=("steamdeck", "removable", "status"), elevated=True),
            _a("steamdeck.display", "Steam Deck", "Detectar display", "Resolução TV/monitor para Game Mode.", ("steamdeck", "display", "detect"), "video-display", mutable=True, preview=("steamdeck", "display", "status")),
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
            _a("windows.graphics.doctor", "Windows VM", "Diagnóstico gráfico", "Saúde consolidada de KVM, GPU, perfil, runtime e VFIO.", ("windows-vm", "graphics", "doctor", "--json"), "tools-report-bug", badge="JSON"),
            _a("windows.graphics.status", "Windows VM", "GPU status", "GPU, render nodes, IOMMU e perfis gráficos elegíveis.", ("windows-vm", "graphics", "status", "--json"), "video-display", badge="JSON"),
            _a("windows.graphics.plan-gl", "Windows VM", "Plano VirtIO GL", "Valida caminho GL experimental sem alterar a VM.", ("windows-vm", "graphics", "plan", "--profile", "virtio-gl", "--json"), "video-display", badge="Seguro"),
            _a("windows.graphics.test-gl", "Windows VM", "Validar comando GL", "Gera lançamento QEMU VirtIO GL completo em dry-run.", ("windows-vm", "launch", "--dry-run", "--raw-qemu", "--graphics", "virtio-gl", "--experimental", "--no-optimize"), "system-run", badge="Seguro"),
            _a("windows.graphics.plan-vfio", "Windows VM", "Plano VFIO", "Valida GPU, áudio e grupos IOMMU; não vincula drivers.", ("windows-vm", "graphics", "plan", "--profile", "vfio-looking-glass", "--pci-devices", "{input}", "--json"), "video-display", badge="Seguro", input_label="Dispositivos PCI (GPU, áudio)", input_kind="text"),
            _a("windows.graphics.compat", "Windows VM", "Restaurar gráfico compatível", "Define QXL/SPICE ou VirtIO VGA como perfil estável.", ("windows-vm", "graphics", "apply", "--profile", "compat"), "edit-undo", mutable=True, preview=("windows-vm", "graphics", "plan", "--profile", "compat", "--json"), badge="Reversível"),
            _a("windows.graphics.runtime-status", "Windows VM", "Status do runtime gráfico", "Compara byte a byte a sessão instalada com as fontes atuais.", ("windows-vm", "graphics", "runtime", "status", "--json"), "system-search", badge="JSON"),
            _a("windows.graphics.runtime-install", "Windows VM", "Atualizar runtime gráfico", "Sincroniza somente sessão e runtime Windows; cria backup e não toca GRUB.", ("windows-vm", "graphics", "runtime", "install", "--json"), "system-software-update", mutable=True, preview=("windows-vm", "graphics", "runtime", "install", "--dry-run", "--json"), elevated=True, badge="Reparo"),
            _a("windows.graphics.runtime-rollback", "Windows VM", "Reverter runtime gráfico", "Restaura backup anterior da sessão gráfica Windows.", ("windows-vm", "graphics", "runtime", "rollback", "--backup", "latest", "--json"), "edit-undo", mutable=True, preview=("windows-vm", "graphics", "runtime", "rollback", "--backup", "latest", "--dry-run", "--json"), elevated=True, badge="Reversível"),
            _a("windows.graphics.guest-guide", "Windows VM", "Guia guest", "Checklist de drivers gráficos no Windows guest.", ("windows-vm", "graphics", "guest-guide"), "help-contents"),
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
        (
            "rom-optimize", "Otimizar ROMs", "CHD/RVZ/CSO/NSZ/ZIP por plataforma.",
            ("emulation", "rom-optimize", "{input}"),
            ("emulation", "rom-optimize", "{input}", "--dry-run", "--json"),
        ),
        ("dualscreen", "Tela dupla Deck+TV", "Roteia 2 telas (3DS/Wii U/DS) p/ TV+Deck (Desktop Mode).", ("emulation", "dualscreen", "apply", "all"), ("emulation", "dualscreen", "detect")),
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
                input_label="Selecione a biblioteca de ROMs" if key == "rom-optimize" else "",
                input_kind="path" if key == "rom-optimize" else "",
            )
        )
    actions.extend(
        [
            _a(
                "emulation.library.scan", "Emulação", "Analisar biblioteca",
                "Varredura somente leitura da biblioteca canônica.",
                ("emulation", "library", "scan", "--scope", "library", "--json"),
                "system-search", badge="Somente leitura", group="Biblioteca de jogos",
                result_view="table",
            ),
            _a(
                "emulation.library.plan", "Emulação", "Criar plano da biblioteca",
                "Gera plano seguro a partir de uma análise salva.",
                ("emulation", "library", "plan", "--scan-id", "{scan_id}", "--json"),
                "document-preview", group="Biblioteca de jogos",
                parameters=(_p("scan_id", "ID da análise", placeholder="scan-…"),),
                result_view="table",
            ),
            _a(
                "emulation.library.apply", "Emulação", "Aplicar plano da biblioteca",
                "Executa ações verificadas com staging; preserva originais.",
                ("emulation", "library", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}", "--json"),
                "media-playback-start", mutable=True,
                preview=("emulation", "library", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}", "--dry-run", "--json"),
                badge="Reversível", group="Biblioteca de jogos",
                parameters=(
                    _p("plan_id", "ID do plano", placeholder="plan-…"),
                    _p("confirm", "Token de confirmação", placeholder="Gerado pelo plano"),
                ),
            ),
            _a(
                "emulation.library.verify", "Emulação", "Validar instalação",
                "Confere hashes e estrutura após execução.",
                ("emulation", "library", "verify", "--operation-id", "{operation_id}", "--json"),
                "task-complete", group="Biblioteca de jogos",
                parameters=(_p("operation_id", "ID da operação", placeholder="op-…"),),
            ),
            _a(
                "emulation.library.rollback", "Emulação", "Reverter instalação",
                "Remove somente destinos criados pela operação; preserva origens.",
                ("emulation", "library", "rollback", "--operation-id", "{operation_id}", "--json"),
                "edit-undo", mutable=True,
                preview=("emulation", "library", "verify", "--operation-id", "{operation_id}", "--json"),
                badge="Reversível", group="Biblioteca de jogos", visibility="advanced",
                parameters=(_p("operation_id", "ID da operação", placeholder="op-…"),),
            ),
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
        ("proxies-ides", "Configurar proxies nas IDEs", "Integra OpenCode, VS Code/Code-OSS e ZCode.", ("ai", "proxies", "configure-ides"), ("ai", "proxies", "status")),
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

    # Public CLI variants not promoted as primary flows. They remain fully
    # discoverable in the contextual Advanced panel for their category.
    actions.extend(
        [
            _a("steamdeck.keyboard.status", "Steam Deck", "Status do teclado", "Provider e configuração do teclado virtual.", ("steamdeck", "keyboard", "status"), "input-keyboard", visibility="advanced"),
            _a("steamdeck.watcher.status", "Steam Deck", "Status do watcher", "Estado do serviço de detecção de dock.", ("steamdeck", "watcher", "status"), "system-run", visibility="advanced"),
            _a("steamdeck.privileged.status", "Steam Deck", "Status privilegiado", "Estado da bridge TDP/GPU.", ("steamdeck", "privileged", "status"), "security-high", visibility="advanced"),
            _a("steamdeck.boot.status", "Steam Deck", "Status do boot SteamOS", "Audita entrada e sessão SteamOS.", ("steamdeck", "boot", "status"), "system-reboot", visibility="advanced"),
            _a("steamdeck.plugins.status", "Steam Deck", "Status Decky", "Saúde de loader, CEF e plugins.", ("steamdeck", "plugins", "status"), "application-x-addon", visibility="advanced"),
            _a("steamdeck.conveniences", "Steam Deck", "Instalar conveniências", "Atalhos Return, Windows VM e Waydroid.", ("steamdeck", "conveniences", "install"), "applications-system", mutable=True, preview=("steamdeck", "status"), visibility="advanced"),
            _a("steamdeck.removable.status", "Steam Deck", "Status de removíveis", "Audita auto-mount USB.", ("steamdeck", "removable", "status"), "drive-removable-media", visibility="advanced"),
            _a("steamdeck.display.status", "Steam Deck", "Status do display", "Audita TV/monitor para Game Mode.", ("steamdeck", "display", "status"), "video-display", visibility="advanced"),

            _a("windows.host-access.status", "Windows VM", "Status acesso ao disco", "Estado da montagem host→guest.", ("windows-vm", "host-access", "status"), "drive-harddisk", visibility="advanced"),
            _a("windows.host-access.unmount", "Windows VM", "Desmontar disco da VM", "Desmonta acesso host antes de iniciar Windows.", ("windows-vm", "host-access", "unmount"), "media-eject", mutable=True, preview=("windows-vm", "host-access", "status"), visibility="advanced"),
            _a("windows.boot.status", "Windows VM", "Status boot Windows", "Audita entrada de boot direto.", ("windows-vm", "boot", "status"), "system-reboot", visibility="advanced"),

            _a("waydroid.host.status", "Waydroid", "Status armazenamento Android", "Estado do link host→Android.", ("waydroid", "host-access", "status"), "folder-open", visibility="advanced"),
            _a("waydroid.host.unlink", "Waydroid", "Desvincular armazenamento", "Remove link host→Android sem apagar dados.", ("waydroid", "host-access", "unlink"), "edit-unlink", mutable=True, preview=("waydroid", "host-access", "status"), visibility="advanced"),
            _a("waydroid.boot.status", "Waydroid", "Status boot Waydroid", "Audita entrada de boot Android.", ("waydroid", "boot", "status"), "system-reboot", visibility="advanced"),

            _a("server.llm.status", "Servidor", "Status LLM", "Estado do Ollama e exposição de rede.", ("server", "llm", "status"), "network-server", visibility="advanced"),
            _a("server.llm.expose", "Servidor", "Expor LLM na LAN", "Habilita acesso LAN ao LLM local.", ("server", "llm", "expose-lan"), "network-wired", mutable=True, preview=("server", "llm", "status"), visibility="advanced"),
            _a("server.llm.restore", "Servidor", "Restaurar LLM local", "Remove exposição e restaura defaults.", ("server", "llm", "restore"), "edit-undo", mutable=True, preview=("server", "llm", "status"), visibility="advanced"),
            _a("server.hermes.status", "Servidor", "Status Hermes", "Estado da atuação remota.", ("server", "hermes", "status"), "network-transmit-receive", visibility="advanced"),
            _a("server.hermes.start", "Servidor", "Iniciar Hermes", "Inicia atuação remota configurada.", ("server", "hermes", "start"), "media-playback-start", mutable=True, preview=("server", "hermes", "status"), visibility="advanced"),
            _a("server.slim.status", "Servidor", "Status modo enxuto", "Serviços afetados pelo slimming.", ("server", "slim", "status"), "preferences-system-performance", visibility="advanced"),
            _a("server.boot.status", "Servidor", "Status boot servidor", "Audita entrada headless.", ("server", "boot", "status"), "system-reboot", visibility="advanced"),
            _a("server.boot.remove", "Servidor", "Remover boot servidor", "Remove entrada GRUB headless.", ("server", "boot", "remove"), "edit-delete", mutable=True, preview=("server", "boot", "status"), elevated=True, visibility="advanced"),

            _a("emulation.eden-integrate", "Emulação", "Integrar Eden", "Integra Eden com ES-DE, SRM e paths.", ("emulation", "eden", "integrate"), "applications-games", mutable=True, preview=("emulation", "eden", "dry-run"), visibility="advanced"),
            _a("emulation.citron-integrate", "Emulação", "Integrar Citron", "Integra Citron com ES-DE, SRM e paths.", ("emulation", "citron", "integrate"), "applications-games", mutable=True, preview=("emulation", "citron", "dry-run"), visibility="advanced"),
            _a("emulation.hydra-configure", "Emulação", "Configurar Hydra", "Configura Hydra Classic e emuladores.", ("emulation", "hydra", "configure"), "applications-games", mutable=True, preview=("emulation", "hydra", "status"), visibility="advanced"),
            _a("emulation.ps1", "Emulação", "Configurar PlayStation 1", "Configura paths DuckStation.", ("emulation", "ps1", "configure"), "applications-games", mutable=True, preview=("emulation", "status"), visibility="advanced"),
            _a("emulation.ps2", "Emulação", "Configurar PlayStation 2", "Configura paths PCSX2.", ("emulation", "ps2", "configure"), "applications-games", mutable=True, preview=("emulation", "status"), visibility="advanced"),
            _a("emulation.ps3-pkg", "Emulação", "Importar PKG PS3", "Importa PKG obtido legalmente.", ("emulation", "ps3", "import-pkg", "{input}"), "package-x-generic", mutable=True, preview=("emulation", "ps3", "dry-run"), parameters=(_p("input", "Selecione PKG PS3", "file"),), visibility="advanced"),
            _a("emulation.ps3-rap", "Emulação", "Importar RAP PS3", "Importa licença RAP própria.", ("emulation", "ps3", "import-rap", "{input}"), "dialog-password", mutable=True, preview=("emulation", "ps3", "dry-run"), parameters=(_p("input", "Selecione RAP", "file"),), visibility="advanced"),
            _a("emulation.performance.status", "Emulação", "Status performance", "Audita perfis adaptativos.", ("emulation", "performance", "status"), "utilities-system-monitor", visibility="advanced"),
            _a("emulation.dualscreen.status", "Emulação", "Detectar telas", "Detecta Deck e display externo.", ("emulation", "dualscreen", "detect"), "video-display", visibility="advanced"),
            _a("emulation.lua.status", "Emulação", "Status Lua", "Audita Lua, LuaJIT e LuaRocks.", ("emulation", "lua", "status"), "utilities-terminal", visibility="advanced"),
            _a("emulation.steam-tools.status", "Emulação", "Status Steam tools", "Audita ferramentas auxiliares Steam.", ("emulation", "steam-tools", "status"), "applications-games", visibility="advanced"),
            _a("emulation.retrodeck.status", "Emulação", "Status RetroDECK", "Audita ecossistema compartilhado.", ("emulation", "retrodeck", "status"), "applications-games", visibility="advanced"),
            _a("emulation.retrodeck.plan", "Emulação", "Plano RetroDECK", "Prévia de migrações e links.", ("emulation", "retrodeck", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.retrodeck.repair", "Emulação", "Reparar RetroDECK", "Repara links do ecossistema.", ("emulation", "retrodeck", "repair"), "tools-check-spelling", mutable=True, preview=("emulation", "retrodeck", "plan"), visibility="advanced"),
            _a("emulation.shared.status", "Emulação", "Status conteúdo compartilhado", "Audita ROMs, saves e BIOS.", ("emulation", "shared", "status"), "folder-sync", visibility="advanced"),
            _a("emulation.shared.plan", "Emulação", "Plano conteúdo compartilhado", "Prévia de links e cópias.", ("emulation", "shared", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.shared.repair", "Emulação", "Reparar conteúdo compartilhado", "Repara links entre consumidores.", ("emulation", "shared", "repair"), "tools-check-spelling", mutable=True, preview=("emulation", "shared", "plan"), visibility="advanced"),
            _a("emulation.media.status", "Emulação", "Status de mídia", "Audita capas e metadados.", ("emulation", "media", "status"), "image-x-generic", visibility="advanced"),
            _a("emulation.media.index", "Emulação", "Indexar mídia", "Reconstrói media-index.json.", ("emulation", "media", "index"), "view-refresh", mutable=True, preview=("emulation", "media", "status"), visibility="advanced"),
            _a("emulation.media.plan", "Emulação", "Plano de mídia", "Prévia de canonicalização.", ("emulation", "media", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.media.repair", "Emulação", "Reparar mídia", "Repara paths de mídia.", ("emulation", "media", "repair"), "tools-check-spelling", mutable=True, preview=("emulation", "media", "plan"), visibility="advanced"),
            _a("emulation.pc-games.status", "Emulação", "Status jogos PC", "Audita jogos locais e Steam.", ("emulation", "pc-games", "status"), "applications-games", visibility="advanced"),
            _a("emulation.pc-games.plan", "Emulação", "Plano jogos PC", "Prévia de launchers.", ("emulation", "pc-games", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.shortcuts.status", "Emulação", "Status atalhos", "Audita launchers AppImage.", ("emulation", "shortcuts", "status"), "application-x-desktop", visibility="advanced"),
            _a("emulation.shortcuts.plan", "Emulação", "Plano atalhos", "Prévia de limpeza de launchers.", ("emulation", "shortcuts", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.launchbox.status", "Emulação", "Status LaunchBox", "Audita integração Wine.", ("emulation", "launchbox", "status"), "applications-games", visibility="advanced"),
            _a("emulation.launchbox.plan", "Emulação", "Plano LaunchBox", "Prévia de bridges ROM/mídia.", ("emulation", "launchbox", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.launchbox.repair", "Emulação", "Reparar LaunchBox", "Repara Wine, ROMs e mídia.", ("emulation", "launchbox", "repair"), "tools-check-spelling", mutable=True, preview=("emulation", "launchbox", "plan"), visibility="advanced"),
            _a("emulation.controllers.status", "Emulação", "Status controles", "Audita perfis Ryujinx/RPCS3.", ("emulation", "controllers", "status"), "input-gaming", visibility="advanced"),
            _a("emulation.frontends.status", "Emulação", "Status frontends", "Audita switcher de frontends.", ("emulation", "frontends", "status"), "view-grid", visibility="advanced"),
            _a("emulation.frontends.plan", "Emulação", "Plano frontends", "Prévia da integração cruzada.", ("emulation", "frontends", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.nsz.status", "Emulação", "Status NSZ", "Audita conversor, keys e espaço.", ("emulation", "nsz", "status"), "document-export", visibility="advanced"),
            _a("emulation.nsz.plan", "Emulação", "Plano NSZ", "Prévia de conversão para arquivo ou pasta.", ("emulation", "nsz", "plan", "{input}"), "document-properties", parameters=(_p("input", "Selecione NSZ ou pasta", "path"),), visibility="advanced"),
            _a("emulation.nsz.install", "Emulação", "Instalar NSZ", "Instala conversor fixado para usuário.", ("emulation", "nsz", "install"), "system-software-install", mutable=True, preview=("emulation", "nsz", "status"), visibility="advanced"),
            _a("emulation.nsz.apply", "Emulação", "Converter todos NSZ", "Converte, deduplica e limpa fontes verificadas.", ("emulation", "nsz", "apply", "--yes"), "document-export", mutable=True, preview=("emulation", "nsz", "plan"), risk="high", visibility="advanced"),
            _a("emulation.optimizer.status", "Emulação", "Status configs por jogo", "Lista configurações documentadas.", ("emulation", "optimizer", "status"), "preferences-system-gaming", visibility="advanced"),

            _a("flatpak.remote.add", "Flatpak", "Adicionar remote", "Adiciona repositório Flatpak.", ("flatpak", "remote", "add", "{name}", "{url}"), "list-add", mutable=True, preview=("flatpak", "remotes"), parameters=(_p("name", "Nome do remote"), _p("url", "URL do remote", "text", placeholder="https://…")), visibility="advanced"),
            _a("flatpak.remote.remove", "Flatpak", "Remover remote", "Remove repositório Flatpak.", ("flatpak", "remote", "remove", "{name}"), "list-remove", mutable=True, preview=("flatpak", "remotes"), parameters=(_p("name", "Nome do remote"),), visibility="advanced"),
            _a("flatpak.overrides.apply", "Flatpak", "Aplicar overrides globais", "Aplica overrides gaming ao usuário.", ("flatpak", "overrides", "apply", "--global"), "preferences-system", mutable=True, preview=("flatpak", "audit"), visibility="advanced"),
            _a("flatpak.overrides.remove", "Flatpak", "Remover overrides globais", "Remove overrides PhaseZero.", ("flatpak", "overrides", "remove", "--global"), "edit-undo", mutable=True, preview=("flatpak", "audit"), visibility="advanced"),

            _a("ai.desktop.status", "IA & Dev", "Status apps IA", "Audita Claude/Codex desktop.", ("ai", "desktop", "status"), "applications-development", visibility="advanced"),
            _a("ai.desktop.claude", "IA & Dev", "Instalar Claude Desktop", "Instala app oficial para usuário.", ("ai", "desktop", "install-claude"), "system-software-install", mutable=True, preview=("ai", "desktop", "status"), visibility="advanced"),
            _a("ai.desktop.codex", "IA & Dev", "Reparar Codex Desktop", "Repara atualização local falha.", ("ai", "desktop", "repair-codex"), "tools-check-spelling", mutable=True, preview=("ai", "desktop", "status"), visibility="advanced"),
            _a("ai.token-economy", "IA & Dev", "Economia de tokens", "Audita contexto e runtime de agentes.", ("ai", "token-economy", "status"), "utilities-system-monitor", visibility="advanced"),
            _a("ai.admin.status", "IA & Dev", "Status admin bridge", "Audita elevação PhaseZero.", ("ai", "admin", "status"), "security-high", visibility="advanced"),
            _a("ai.omo.status", "IA & Dev", "Status OMO", "Audita oh-my-openagent.", ("ai", "omo", "status"), "applications-development", visibility="advanced"),
            _a("ai.omo.doctor", "IA & Dev", "Diagnóstico OMO", "Diagnostica plugin OpenCode.", ("ai", "omo", "doctor"), "system-search", visibility="advanced"),
            _a("ai.omo.enable", "IA & Dev", "Ativar OMO", "Ativa plugin OpenCode.", ("ai", "omo", "enable"), "media-playback-start", mutable=True, preview=("ai", "omo", "status"), visibility="advanced"),
            _a("ai.omo.disable", "IA & Dev", "Desativar OMO", "Desativa plugin sem remover.", ("ai", "omo", "disable"), "media-playback-pause", mutable=True, preview=("ai", "omo", "status"), visibility="advanced"),
            _a("ai.omo.uninstall", "IA & Dev", "Remover OMO", "Remove plugin OpenCode.", ("ai", "omo", "uninstall"), "edit-delete", mutable=True, preview=("ai", "omo", "status"), risk="high", visibility="advanced"),
            _a("ai.opencode.status", "IA & Dev", "Status OpenCode", "Audita CLI, desktop e modelos.", ("ai", "opencode", "status"), "applications-development", visibility="advanced"),
            _a("ai.opencode.local", "IA & Dev", "Modelo local OpenCode", "Configura modelo Ollama local.", ("ai", "opencode", "local-model"), "applications-development", mutable=True, preview=("ai", "opencode", "status"), visibility="advanced"),
            _a("ai.opencode.hook", "IA & Dev", "Instalar hook OpenCode", "Instala sincronização automática.", ("ai", "opencode", "install-hook"), "system-run", mutable=True, preview=("ai", "opencode", "status"), visibility="advanced"),
            _a("ai.secrets.rotate", "IA & Dev", "Rotacionar secrets IA", "Rotaciona chaves gerenciadas sem exibi-las.", ("ai", "secrets", "rotate"), "dialog-password", mutable=True, preview=("ai", "status"), risk="high", visibility="advanced"),
            _a("ai.mcp.status", "IA & Dev", "Status MCP", "Audita servidores MCP.", ("ai", "mcp", "status"), "network-server", visibility="advanced"),
            _a("ai.mcp.list", "IA & Dev", "Listar MCPs", "Lista servidores instalados.", ("ai", "mcp", "list"), "view-list-details", visibility="advanced"),
            _a("ai.mcp.install", "IA & Dev", "Instalar MCP", "Instala servidor MCP pelo identificador.", ("ai", "mcp", "install", "{server}"), "system-software-install", mutable=True, preview=("ai", "mcp", "status"), parameters=(_p("server", "Servidor MCP"),), visibility="advanced"),
            _a("ai.mcp.repair", "IA & Dev", "Reparar MCPs", "Remove quebrados e reinstala defaults seguros.", ("ai", "mcp", "repair", "all"), "tools-check-spelling", mutable=True, preview=("ai", "mcp", "status"), visibility="advanced"),
            _a("ai.proxies.status", "IA & Dev", "Status proxies IA", "Audita suite OpenAI-compatible.", ("ai", "proxies", "status"), "network-server", visibility="advanced"),
            _a("ai.setup.tool", "IA & Dev", "Instalar ferramenta IA", "Executa setup seguro para uma ferramenta pública.", ("ai", "setup", "{tool}"), "system-software-install", mutable=True, preview=("ai", "status"), parameters=(_p("tool", "Ferramenta", "choice", choices=("codex", "ollama", "webui", "claude", "desktop", "opencode", "omo", "hermes", "openclaw", "memory", "admin", "rtk", "caveman", "headroom", "compat", "ides", "ide-apps", "usagebar", "all")),), visibility="advanced"),
            _a("ai.mcp.sync-target", "IA & Dev", "Sincronizar MCP por cliente", "Sincroniza servidores seguros no cliente escolhido.", ("ai", "mcp", "sync", "{target}"), "folder-sync", mutable=True, preview=("ai", "mcp", "status"), parameters=(_p("target", "Cliente", "choice", choices=("all", "codex", "claude", "opencode", "vscode")),), visibility="advanced"),
            _a("ai.proxies.install-one", "IA & Dev", "Instalar proxy específico", "Instala ou atualiza um proxy da suite.", ("ai", "proxies", "install", "{proxy}"), "network-server", mutable=True, preview=("ai", "proxies", "status"), parameters=(_p("proxy", "Proxy", "choice", choices=("all", "kimiproxy", "qwenproxy", "deepsproxy")),), visibility="advanced"),

            _a("desktop.webapps.status", "Aplicativos", "Status web apps", "Lista launchers web instalados.", ("webapp", "status"), "applications-internet", visibility="standard"),
            _a("desktop.menu.scan", "Aplicativos", "Analisar menu PhaseZero", "Inventaria launchers, duplicatas e raízes legadas sem alterar o desktop.", ("ui", "menu", "scan", "--json"), "system-search", group="Menu PhaseZero", result_view="table", visibility="primary"),
            _a("desktop.menu.plan", "Aplicativos", "Prévia da organização", "Mostra a árvore única PhaseZero e entradas que serão consolidadas.", ("ui", "menu", "plan", "--json"), "document-preview", group="Menu PhaseZero", result_view="table", visibility="primary"),
            _a("desktop.menu.apply", "Aplicativos", "Organizar menu PhaseZero", "Cria uma raiz PhaseZero, consolida submenus e registra rollback.", ("ui", "menu", "apply", "--json"), "view-list-tree", mutable=True, preview=("ui", "menu", "plan", "--json"), badge="Reversível", group="Menu PhaseZero", visibility="primary"),
            _a("desktop.menu.rollback", "Aplicativos", "Restaurar menu anterior", "Restaura menus e diretórios do último ledger privado.", ("ui", "menu", "rollback", "--json"), "edit-undo", mutable=True, preview=("ui", "menu", "scan", "--json"), badge="Reversível", group="Menu PhaseZero", visibility="advanced"),
            _a("desktop.webapps.install", "Aplicativos", "Instalar web app", "Cria launcher isolado para serviço web.", ("webapp", "install", "{slug}"), "applications-internet", mutable=True, preview=("webapp", "status"), parameters=(_p("slug", "Identificador do web app"),), visibility="standard"),
            _a("desktop.webapps.all", "Aplicativos", "Instalar todos web apps", "Instala catálogo completo de launchers.", ("webapp", "install-all"), "applications-internet", mutable=True, preview=("webapp", "status"), visibility="advanced"),
            _a("desktop.games.status", "Aplicativos", "Status menu de jogos", "Lista jogos e emuladores detectados.", ("games", "status"), "applications-games", visibility="standard"),
            _a("desktop.games.scan", "Aplicativos", "Escanear jogos", "Detecta jogos, frontends e emuladores.", ("games", "scan"), "system-search", visibility="standard"),
            _a("desktop.games.install", "Aplicativos", "Instalar menus de jogos", "Cria launchers para itens detectados.", ("games", "install-all"), "applications-games", mutable=True, preview=("games", "status"), visibility="standard"),
        ]
    )

    # Capability expansion inspired by LinuxToys concepts, reimplemented as a
    # signed-repository/Flatpak-only plan/apply/verify/rollback contract.
    from linux.capabilities.catalog import CAPABILITIES, GROUPS, PROFILES

    actions.extend(
        [
            _a(
                "capability.detect", "Recursos", "Compatibilidade do host",
                "Detecta distribuição, imutabilidade, GPU, sessão e providers confiáveis.",
                ("capabilities", "detect"), "system-search",
                group="Visão geral", visibility="primary", result_view="table",
            ),
            _a(
                "capability.status", "Recursos", "Estado dos recursos",
                "Mostra disponibilidade e instalação no host atual.",
                ("capabilities", "status"), "view-list-details",
                group="Visão geral", visibility="primary", result_view="table",
            ),
            _a(
                "capability.profiles", "Recursos", "Perfis disponíveis",
                "Lista composições prontas por jornada.",
                ("capabilities", "profiles"), "view-list-tree",
                group="Visão geral", visibility="standard", result_view="table",
            ),
            _a(
                "capability.manifest.plan", "Recursos", "Planejar manifesto",
                "Valida manifesto JSON versionado sem executar alterações.",
                ("capabilities", "plan", "--manifest", "{manifest}"),
                "document-preview", group="Perfis prontos", visibility="standard",
                parameters=(_p("manifest", "Manifesto JSON", "file"),), result_view="table",
            ),
            _a(
                "capability.apply", "Recursos", "Aplicar plano confirmado",
                "Revalida fontes e aplica o plano pelo ID e token gerados.",
                ("capabilities", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
                "system-software-install", mutable=True,
                preview=("capabilities", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}", "--dry-run"),
                elevated=True, badge="Protegido", group="Operação e recuperação",
                visibility="standard", result_view="table",
                parameters=(
                    _p("plan_id", "ID do plano", placeholder="plan-…"),
                    _p("confirm", "Token de confirmação", placeholder="Gerado pelo plano"),
                ),
            ),
            _a(
                "capability.verify", "Recursos", "Verificar operação",
                "Confirma que cada recurso instalado pela operação continua presente.",
                ("capabilities", "verify", "--operation-id", "{operation_id}"),
                "dialog-ok", group="Operação e recuperação", visibility="standard",
                parameters=(_p("operation_id", "ID da operação", placeholder="operation-…"),),
                result_view="table",
            ),
            _a(
                "capability.rollback", "Recursos", "Reverter operação",
                "Remove somente recursos instalados pela operação; preserva preexistentes.",
                ("capabilities", "rollback", "--operation-id", "{operation_id}", "--confirm", "{confirm}"),
                "edit-undo", mutable=True,
                preview=("capabilities", "rollback", "--operation-id", "{operation_id}", "--confirm", "{confirm}", "--dry-run"),
                elevated=True, badge="Reversível", group="Operação e recuperação",
                visibility="advanced", result_view="table",
                parameters=(
                    _p("operation_id", "ID da operação", placeholder="operation-…"),
                    _p("confirm", "Token de rollback", placeholder="Gerado pela operação"),
                ),
            ),
        ]
    )
    for profile_id, capability_ids in PROFILES.items():
        actions.append(
            _a(
                f"capability.profile.{profile_id}", "Recursos",
                profile_id.replace("-", " ").title(),
                f"Cria plano seguro para {len(capability_ids)} recursos; nada é instalado nesta etapa.",
                ("capabilities", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
                "document-preview", mutable=True,
                preview=("capabilities", "plan", "--profile", profile_id),
                preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
                elevated=True, badge="Protegido", group="Perfis prontos", visibility="primary",
                keywords=(profile_id, "perfil", "workstation"), result_view="table",
            )
        )
    for capability in CAPABILITIES:
        actions.append(
            _a(
                f"capability.plan.{capability.id}", "Recursos", capability.title,
                capability.description,
                ("capabilities", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
                "document-preview", mutable=True,
                preview=("capabilities", "plan", "--capability", capability.id),
                preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
                elevated=True, group=GROUPS[capability.group],
                visibility="advanced" if capability.risk == "high" else "standard",
                risk=capability.risk, badge="Plano seguro",
                keywords=(capability.id, capability.group, *capability.keywords),
                result_view="table",
            )
        )

    validate_catalog(actions)
    selected_platform = current_platform(platform_name)
    return [action for action in actions if selected_platform in action.platforms]


def validate_catalog(actions: list[ActionSpec]) -> None:
    ids = [item.id for item in actions]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate action id in native UI catalog")
    categories = {row[0] for row in CATEGORIES}
    for item in actions:
        if item.category not in categories:
            raise ValueError(f"unknown category for {item.id}: {item.category}")
        if item.visibility not in {"primary", "standard", "advanced"}:
            raise ValueError(f"invalid visibility for {item.id}: {item.visibility}")
        if item.risk not in {"normal", "elevated", "high"}:
            raise ValueError(f"invalid risk for {item.id}: {item.risk}")
        if item.mutable and item.preview_args is None:
            raise ValueError(f"mutable action lacks preview: {item.id}")
        if not item.platforms:
            raise ValueError(f"action lacks platform: {item.id}")
        names = item.parameter_names
        if len(names) != len(set(names)):
            raise ValueError(f"duplicate parameter for {item.id}")
        placeholders = {
            match.group(1)
            for token in (*item.args, *(item.preview_args or ()))
            for match in [re.fullmatch(r"\{([A-Za-z0-9_-]+)\}", token)]
            if match
        }
        missing = placeholders - set(names)
        if missing:
            raise ValueError(f"action {item.id} lacks parameters: {sorted(missing)}")


def catalog_manifest(root: Path, platform_name: str | None = None) -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "categories": [row[0] for row in CATEGORIES],
        "actions": [
            {
                "id": item.id,
                "category": item.category,
                "title": item.title,
                "description": item.description,
                "args": list(item.args),
                "previewArgs": list(item.preview_args) if item.preview_args else None,
                "statusArgs": list(item.status_args) if item.status_args else None,
                "mutable": item.mutable,
                "elevated": item.elevated,
                "group": item.group,
                "visibility": item.visibility,
                "platforms": list(item.platforms),
                "risk": item.risk,
                "resultView": item.result_view,
                "parameters": [
                    {
                        "name": parameter.name,
                        "label": parameter.label,
                        "kind": parameter.kind,
                        "required": parameter.required,
                        "choices": list(parameter.choices),
                        "placeholder": parameter.placeholder,
                    }
                    for parameter in item.parameters
                ],
                "previewBindings": [
                    {"parameter": parameter, "resultKey": result_key}
                    for parameter, result_key in item.preview_bindings
                ],
            }
            for item in build_catalog(root, platform_name)
        ],
    }


def write_manifest(root: Path, destination: Path) -> None:
    destination.write_text(json.dumps(catalog_manifest(root), ensure_ascii=False, indent=2) + "\n")
