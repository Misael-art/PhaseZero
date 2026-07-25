from __future__ import annotations
from . import detect
from . import decision
from . import manifest
from . import convert
from . import verify
from . import rename
from . import cartridge
from . import clean
from . import sync as sync_
from . import dats
from .profile import Profile, PLATFORMS, PLATFORM_ALIASES

__all__ = [
    "Profile", "PLATFORMS", "PLATFORM_ALIASES",
    "detect", "decision", "manifest",
    "convert", "verify", "rename",
    "cartridge", "clean", "sync_", "dats",
]
