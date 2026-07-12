from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def profile_data(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_runtime_source_has_no_ghost_files():
    result = subprocess.run(
        ["git", "ls-files", "-oi", "--exclude-standard", "linux", "profiles", "assets"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    )
    ghosts = [line for line in result.stdout.splitlines() if "/.ghost-" in line]
    assert ghosts == []


def test_profile_package_managers_are_disjoint():
    for path in (ROOT / "profiles").glob("*.json"):
        linux = profile_data(path).get("packages", {}).get("linux", {})
        pacman = set(linux.get("pacman", ()))
        yay = set(linux.get("yay", ()))
        assert pacman.isdisjoint(yay), f"{path.name}: {sorted(pacman & yay)}"


def test_profiles_do_not_install_same_desktop_app_native_and_flatpak():
    equivalents = {
        "steam": "com.valvesoftware.Steam",
        "lutris": "net.lutris.Lutris",
        "heroic-games-launcher-bin": "com.heroicgameslauncher.hgl",
        "prismlauncher": "org.prismlauncher.PrismLauncher",
    }
    for path in (ROOT / "profiles").glob("*.json"):
        linux = profile_data(path).get("packages", {}).get("linux", {})
        native = set(linux.get("pacman", ())) | set(linux.get("yay", ()))
        flatpak = linux.get("flatpak", ())
        if isinstance(flatpak, dict):
            flatpak = flatpak.get("packages", ())
        flatpak = set(flatpak)
        duplicates = [package for package, app_id in equivalents.items() if package in native and app_id in flatpak]
        assert duplicates == [], f"{path.name}: {duplicates}"


def test_release_metadata_matches_version_json():
    version = profile_data(ROOT / "version.json")["version"]
    checks = {
        "deb": (ROOT / "packaging/linux/deb/control", r"^Version:\s*(\S+)"),
        "rpm": (ROOT / "packaging/linux/rpm/phasezero-control-center.spec", r"^Version:\s*(\S+)"),
        "aur": (ROOT / "packaging/linux/aur/PKGBUILD", r"^pkgver=(\S+)"),
        "srcinfo": (ROOT / "packaging/linux/aur/.SRCINFO", r"^\s*pkgver\s*=\s*(\S+)"),
        "flatpak": (ROOT / "packaging/linux/flatpak/io.phasezero.ControlCenter.yml", r"^\s*tag:\s*v(\S+)"),
        "appstream": (ROOT / "packaging/linux/io.phasezero.ControlCenter.metainfo.xml", r'<release version="([^"]+)"'),
    }
    for name, (path, pattern) in checks.items():
        match = re.search(pattern, path.read_text(encoding="utf-8"), re.MULTILINE)
        assert match and match.group(1) == version, name


def test_every_builder_uses_canonical_git_export():
    builders = (
        "install-user.sh", "deb/build-deb.sh", "rpm/build-rpm.sh",
        "arch/build-arch.sh", "appimage/build-appimage.sh", "flatpak/build-flatpak.sh",
    )
    for relative in builders:
        text = (ROOT / "packaging/linux" / relative).read_text(encoding="utf-8")
        assert "export-source.sh" in text, relative


def test_static_action_snapshot_matches_native_catalog():
    from linux.ui_native.catalog import build_catalog

    expected = {action.id for action in build_catalog(ROOT)}
    static = {
        action["name"]
        for action in json.loads((ROOT / "linux/ui/actions.json").read_text(encoding="utf-8"))["actions"]
    }
    assert static == expected
