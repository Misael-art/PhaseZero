from __future__ import annotations
import shutil
import subprocess
import sys
from dataclasses import replace
from dataclasses import dataclass, field


@dataclass
class ToolInfo:
    name: str
    binary: str
    present: bool = False
    version: str = ""
    path: str = ""
    packages: dict[str, str] = field(default_factory=dict)
    pip_package: str = ""


TOOL_DEFS: list[ToolInfo] = [
    ToolInfo("chdman", "chdman",
             packages={"arch": "mame-tools", "debian": "mame-tools", "fedora": "mame-tools"}),
    # dolphin-tool ships in the small dolphin-emu-tool package, NOT dolphin-emu
    # (which pulls the full emulator GUI).
    ToolInfo("dolphin-tool", "dolphin-tool",
             packages={"arch": "dolphin-emu-tool", "debian": "dolphin-emu", "fedora": "dolphin-emu"}),
    # maxcso is a compiled C binary in Arch extra (1.13.0-3), NOT a pip package.
    ToolInfo("maxcso", "maxcso",
             packages={"arch": "maxcso", "debian": "maxcso", "fedora": "maxcso"}),
    ToolInfo("nsz", "nsz",
             pip_package="nsz"),
    ToolInfo("7z", "7z",
             packages={"arch": "p7zip", "debian": "p7zip-full", "fedora": "p7zip"}),
    # `file` is its own package (provides libmagic.so), not coreutils.
    ToolInfo("file", "file",
             packages={"arch": "file", "debian": "file", "fedora": "file"}),
    ToolInfo("ffmpeg", "ffmpeg",
             packages={"arch": "ffmpeg", "debian": "ffmpeg", "fedora": "ffmpeg"}),
]


def discover_tools() -> dict[str, ToolInfo]:
    discovered: dict[str, ToolInfo] = {}
    for definition in TOOL_DEFS:
        t = replace(definition)
        path = shutil.which(t.binary)
        if path:
            t.present = True
            t.path = path
            # NSZ imports key material before argument parsing and may prompt
            # when prod.keys is absent. Presence detection must never trigger a
            # proprietary-key prompt.
            if t.name != "nsz":
                try:
                    out = subprocess.check_output(
                        [t.binary, "--version"],
                        stderr=subprocess.STDOUT,
                        stdin=subprocess.DEVNULL,
                        text=True,
                        timeout=5,
                    )
                    t.version = out.split("\n")[0].strip()
                except Exception:
                    t.version = "?"
        discovered[t.name] = t
    return discovered


def require_tools(tools: dict[str, ToolInfo], *names: str) -> list[str]:
    missing = [n for n in names if not tools.get(n, ToolInfo(n, n)).present]
    if missing:
        for n in missing:
            t = next((x for x in TOOL_DEFS if x.name == n), None)
            if t and t.pip_package:
                print(f"ERROR: {n} not found. Install: pip install {t.pip_package}", file=sys.stderr)
            elif t and t.packages:
                print(f"ERROR: {n} not found. Install: sudo pacman -S {t.packages.get('arch', n)}", file=sys.stderr)
            else:
                print(f"ERROR: {n} not found.", file=sys.stderr)
    return missing
