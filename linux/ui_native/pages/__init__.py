from .base import BasePage
from .registry import PageRegistry
from .dashboard import DashboardPage
from .profiles import ProfilesPage
from .steamdeck import SteamDeckPage
from .windows_vm import WindowsVMPage
from .waydroid import WaydroidPage
from .server import ServerPage
from .emulation import EmulationPage
from .boot import BootPage
from .flatpak import FlatpakPage
from .ai_dev import AiDevPage
from .tuning import TuningPage
from .overview import OverviewPage
from .results import ResultsPage

__all__ = [
    "BasePage", "PageRegistry",
    "DashboardPage", "ProfilesPage", "SteamDeckPage",
    "WindowsVMPage", "WaydroidPage", "ServerPage",
    "EmulationPage", "BootPage", "FlatpakPage",
    "AiDevPage", "TuningPage", "OverviewPage", "ResultsPage",
]
