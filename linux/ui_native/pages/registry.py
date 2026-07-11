from __future__ import annotations

from pathlib import Path

from ..catalog import CATEGORIES, DASHBOARD, build_catalog
from ..command_runner import CommandRunner

from .base import BasePage
from .dashboard import DashboardPage
from .overview import OverviewPage
from .profiles import ProfilesPage
from .steamdeck import SteamDeckPage
from .windows_vm import WindowsVMPage
from .waydroid import WaydroidPage
from .server import ServerPage
from .emulation import EmulationPage
from .boot import BootPage
from .flatpak import FlatpakPage
from .ai_dev import AiDevPage
from .applications import ApplicationsPage
from .tuning import TuningPage
from .results import ResultsPage
from .workspace import CatalogWorkspacePage


class PageRegistry:
    """Maps category names to page widget instances."""

    def __init__(self, root: Path, runner: CommandRunner) -> None:
        self.root = root
        self.runner = runner
        self.catalog = build_catalog(root)
        self.by_id = {a.id: a for a in self.catalog}
        self.cat_meta = {row[0]: row for row in (DASHBOARD, *CATEGORIES)}
        self._pages: dict[str, BasePage] = {}
        self._build()

    # Category -> page class mapping.
    _CATEGORY_PAGES: dict[str, type[BasePage]] = {
        "Início": DashboardPage,
        "Visão geral": OverviewPage,
        "Perfis": ProfilesPage,
        "Steam Deck": SteamDeckPage,
        "Windows VM": WindowsVMPage,
        "Waydroid": WaydroidPage,
        "Servidor": ServerPage,
        "Emulação": EmulationPage,
        "Boot Direto": BootPage,
        "Flatpak": FlatpakPage,
        "IA & Dev": AiDevPage,
        "Aplicativos": ApplicationsPage,
        "Ajustes": TuningPage,
        "Resultados": ResultsPage,
    }

    def _build(self) -> None:
        workspace_categories = {
            "Steam Deck", "Windows VM", "Waydroid", "Servidor", "Emulação",
            "Boot Direto", "Flatpak", "IA & Dev", "Aplicativos",
        }
        for category, page_cls in self._CATEGORY_PAGES.items():
            actions = [a for a in self.catalog if a.category == category]
            if category in workspace_categories and category != "Emulação":
                page_cls = CatalogWorkspacePage
            page = page_cls(self.root, self.runner, actions, by_id=self.by_id)
            page.build()
            page.finalize_action_coverage()
            self._pages[category] = page

    def page_for(self, category: str) -> BasePage | None:
        return self._pages.get(category)

    def pages(self) -> tuple[BasePage, ...]:
        return tuple(self._pages.values())

    def block_all(self, running: bool) -> None:
        for page in self._pages.values():
            page.block_while_running(running)
