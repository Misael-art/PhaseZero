from __future__ import annotations
from .profile import Profile
from .detect import (
    P_PS1, P_PS2, P_PSP, P_DC, P_SATURN, P_MEGACD, P_PCE, P_NGCD,
    P_3DO, P_PCFX, P_FMTOWNS, P_JAGCD, P_CD32, P_WII, P_GC, P_SWITCH,
    P_GENESIS, P_MD,
    CARTRIDGE_SYSTEMS, NO_COMPRESSION,
)

DECISION_TABLE: dict[str, dict[str, str | None]] = {
    P_PS1: {"iso": "chd", "bin": "chd", "cue": "chd", "img": "chd",
            "pbp": None, "chd": None},
    # chdman cannot consume CSO/GZ directly. Preserve those inputs instead of
    # starting a conversion which can never produce a valid CHD.
    P_PS2: {"iso": "chd", "bin": "chd", "img": "chd", "cso": None,
            "gz": None, "mdf": "chd", "nrg": "chd", "chd": None},

    P_DC: {"gdi": "chd", "cdi": "chd", "iso": "chd", "bin": "chd",
           "dax": "chd", "mdf": "chd", "chd": None},
    P_SATURN: {"iso": "chd", "bin": "chd", "cue": "chd", "img": "chd",
               "mdf": "chd", "chd": None},
    P_MEGACD: {"iso": "chd", "bin": "chd", "cue": "chd", "chd": None},
    P_PCE: {"iso": "chd", "bin": "chd", "cue": "chd", "chd": None},
    P_NGCD: {"iso": "chd", "bin": "chd", "cue": "chd", "chd": None},
    P_3DO: {"iso": "chd", "bin": "chd", "cue": "chd", "chd": None},
    P_PCFX: {"iso": "chd", "bin": "chd", "cue": "chd", "chd": None},
    P_FMTOWNS: {"iso": "chd", "bin": "chd", "cue": "chd", "chd": None},
    P_JAGCD: {"iso": "chd", "bin": "chd", "cue": "chd", "chd": None},
    P_CD32: {"iso": "chd", "bin": "chd", "cue": "chd", "chd": None},
    P_WII: {"iso": "rvz", "wbfs": "rvz", "gcm": "rvz", "ciso": "rvz",
            "gcz": "rvz", "rvz": None, "chd": None},
    P_GC: {"iso": "rvz", "gcm": "rvz", "ciso": "rvz", "gcz": "rvz",
           "rvz": None, "chd": None},
    P_SWITCH: {"nsp": "nsz", "xci": "xcz", "nsz": None, "xcz": None},
}

ALIAS_MAP: dict[str, str] = {
    "segacd": P_MEGACD, "tg16": P_PCE, "tg-cd": P_PCE,
    "turbografx": P_PCE, "genesis": P_GENESIS, "megadrive": P_MD,
}


def resolve_platform_alias(platform: str) -> str:
    return ALIAS_MAP.get(platform, platform)


def target_format(platform: str, current_format: str,
                  profile: Profile | None = None,
                  force: bool = False) -> str | None:
    plat = resolve_platform_alias(platform)

    # Systems with no compression format available
    if plat in NO_COMPRESSION:
        return None

    # Disc systems
    if plat in DECISION_TABLE:
        row = DECISION_TABLE[plat]
        result = row.get(current_format)
        if result is not None:
            return result
        # If current format not in table, map raw images to target
        if current_format in ("iso", "bin", "img", "raw", "mdf", "nrg", "gdi", "cue"):
            if plat in (P_PS1, P_DC, P_SATURN, P_MEGACD, P_PCE, P_NGCD,
                        P_3DO, P_PCFX, P_FMTOWNS, P_JAGCD, P_CD32):
                return "chd"
            if plat in (P_PS2,):
                return "chd"
            if plat in (P_WII, P_GC):
                return "rvz"
        return None

    # PSP: profile determines target
    if plat == P_PSP:
        if profile and current_format not in ("cso", "zso", "pbp", "chd"):
            return profile.psp_target
        return None

    # Cartridge: loose ROM -> zip; existing ZIP -> rezip (the orchestrator then
    # checks check_zip_optimal and skips already-deflated entries, preserving
    # idempotency unless --zip-force).
    if plat in CARTRIDGE_SYSTEMS:
        if current_format == "zip":
            return "rezip"
        return "zip"

    return None


def needs_psp_recompress(current_format: str, profile: Profile) -> bool:
    if current_format == profile.psp_target:
        return False
    if current_format in ("cso", "zso") and not profile.zip_force:
        return False
    return True
