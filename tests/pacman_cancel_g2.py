"""Disposable Arch CI probe: real pacman cancellation boundary and recovery.

Not collected by pytest. The explicit guards prevent accidental package
transactions on a developer host.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.capabilities.engine import apply_plan, create_plan, rollback_operation
from linux.capabilities.platform import detect
from linux.capabilities.providers import Provider


def _assert_disposable_arch_ci() -> None:
    if (
        os.environ.get("PZ_ENABLE_ARCH_PACMAN_G2") != "1"
        or os.environ.get("GITHUB_ACTIONS") != "true"
        or os.environ.get("GITHUB_JOB") != "arch-clean-host"
        or os.geteuid() != 0
        or not Path("/etc/arch-release").is_file()
    ):
        raise SystemExit("requires the guarded arch-clean-host CI container")


def _facts():
    facts = replace(detect(), container=False)
    real_pacman = Path("/usr/bin/pacman").resolve()
    resolved_pacman = Path(shutil.which(facts.package_manager) or "/missing").resolve()
    if facts.package_family != "arch" or resolved_pacman != real_pacman:
        raise RuntimeError("real Arch pacman is unavailable")
    return facts


def _is_installed(name: str) -> bool:
    result = subprocess.run(
        ["pacman", "-Q", name], capture_output=True, text=True, timeout=20,
        check=False,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 1 and "was not found" in result.stderr.casefold():
        return False
    raise RuntimeError(f"pacman -Q {name} inconclusive: {result.stderr.strip()}")


def _running_install(target: str) -> int | None:
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            raw = (entry / "cmdline").read_bytes().split(b"\0")
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        argv = [os.fsdecode(value) for value in raw if value]
        if (
            argv
            and Path(argv[0]).name == "pacman"
            and argv[1:4] == ["-S", "--needed", "--noconfirm"]
            and argv[4:] == [target]
        ):
            return int(entry.name)
    return None


def _stop_process_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=10)


def _set_sandbox_paths(root: Path) -> None:
    home = root / "home"
    runtime = root / "runtime"
    home.mkdir(mode=0o700)
    runtime.mkdir(mode=0o700)
    (home / ".config").mkdir(mode=0o700)
    (home / ".local/share").mkdir(parents=True, mode=0o700)
    (home / ".local/state").mkdir(parents=True, mode=0o700)
    (home / ".cache").mkdir(mode=0o700)
    os.environ["HOME"] = str(home)
    os.environ["XDG_CONFIG_HOME"] = str(home / ".config")
    os.environ["XDG_DATA_HOME"] = str(home / ".local/share")
    os.environ["XDG_STATE_HOME"] = str(home / ".local/state")
    os.environ["XDG_CACHE_HOME"] = str(home / ".cache")
    os.environ["XDG_RUNTIME_DIR"] = str(runtime)
    os.environ["PZ_CAPABILITIES_STATE_DIR"] = str(root / "capabilities-state")
    os.environ["LANG"] = "C"
    os.environ["LC_ALL"] = "C"
    print(
        "Disposable Arch CI writes: root=/; pacman-db=/var/lib/pacman; "
        "cache=/var/cache/pacman/pkg; log=/var/log/pacman.log; "
        f"HOME={home}; PZ state={root / 'capabilities-state'}",
        flush=True,
    )


def _apply_child(plan_id: str, confirmation: str, cancel_path: Path) -> int:
    facts = _facts()
    record = apply_plan(
        plan_id,
        confirmation=confirmation,
        facts=facts,
        provider=Provider(facts),
        cancel_file=cancel_path,
    )
    print(json.dumps(record, separators=(",", ":")))
    return 0


def _wait_for_real_pacman(
    process: subprocess.Popen[str], target: str, cancel_path: Path,
) -> tuple[str, str]:
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        if _running_install(target) is not None:
            cancel_path.touch(mode=0o600)
            print(f"cancel request recorded during pacman install: {target}", flush=True)
            try:
                return process.communicate(timeout=900)
            except subprocess.TimeoutExpired as exc:
                _stop_process_group(process)
                raise RuntimeError(f"pacman install timed out: {target}") from exc
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise RuntimeError(
                f"apply exited before real pacman install for {target}: "
                f"stdout={stdout!r} stderr={stderr!r}"
            )
        time.sleep(0.05)
    _stop_process_group(process)
    raise RuntimeError(f"real pacman install did not start for {target}")


def _run() -> None:
    _assert_disposable_arch_ci()
    facts = _facts()
    provider = Provider(facts)
    for package in ("nodejs", "pnpm"):
        if _is_installed(package):
            raise RuntimeError(f"clean Arch container unexpectedly has {package}")

    temp_root = Path(tempfile.mkdtemp(prefix="pxa004-pacman-cancel-"))
    os.chmod(temp_root, 0o700)
    try:
        _set_sandbox_paths(temp_root)
        plan = create_plan(
            profile_ids=["development-web-js"], facts=facts, provider=provider,
        )
        if not plan.get("ok") or plan.get("status") != "ready":
            raise RuntimeError(f"Arch development profile did not plan: {plan!r}")
        expected = [
            (item["capabilityId"], item["source"]["name"])
            for item in plan["actions"]
        ]
        if expected != [("development.nodejs", "nodejs"), ("development.pnpm", "pnpm")]:
            raise RuntimeError(f"unexpected development-web-js plan: {expected!r}")

        cancel_path = temp_root / "cancel.request"
        child = subprocess.Popen(
            [
                sys.executable, str(Path(__file__).resolve()), "_apply",
                str(plan["id"]), str(plan["confirmToken"]), str(cancel_path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = _wait_for_real_pacman(child, "nodejs", cancel_path)
        except BaseException:
            _stop_process_group(child)
            raise
        if child.returncode != 0:
            raise RuntimeError(f"real apply failed: stdout={stdout!r} stderr={stderr!r}")
        cancelled = json.loads(stdout)
        if (
            cancelled.get("status") != "cancelled"
            or [item["capabilityId"] for item in cancelled["installedByOperation"]]
            != ["development.nodejs"]
            or not _is_installed("nodejs")
            or _is_installed("pnpm")
        ):
            raise RuntimeError(f"real cancellation boundary was incorrect: {cancelled!r}")

        cancel_path.unlink()
        resumed = apply_plan(
            plan["id"], confirmation=plan["confirmToken"],
            facts=facts, provider=provider,
        )
        if (
            resumed.get("status") != "complete"
            or [item["capabilityId"] for item in resumed["installedByOperation"]]
            != ["development.pnpm"]
            or not _is_installed("nodejs")
            or not _is_installed("pnpm")
        ):
            raise RuntimeError(f"real resume did not complete the profile: {resumed!r}")
        subprocess.run(["node", "--eval", "process.stdout.write('node-ok')"], check=True)
        subprocess.run(["pnpm", "--version"], check=True)

        repeated_plan = create_plan(
            profile_ids=["development-web-js"], facts=facts, provider=provider,
        )
        repeated = apply_plan(
            repeated_plan["id"], confirmation=repeated_plan["confirmToken"],
            facts=facts, provider=provider,
        )
        if (
            repeated.get("status") != "complete"
            or repeated.get("installedByOperation")
            or any(item.get("status") != "preexisting" for item in repeated["results"])
        ):
            raise RuntimeError(f"real repeat was not idempotent: {repeated!r}")

        rollback_pnpm = rollback_operation(
            resumed["id"], confirmation=resumed["rollbackToken"],
            facts=facts, provider=provider,
        )
        if (
            rollback_pnpm.get("status") != "complete"
            or not _is_installed("nodejs")
            or _is_installed("pnpm")
        ):
            raise RuntimeError(f"rollback removed shared Node.js or kept pnpm: {rollback_pnpm!r}")
        rollback_node = rollback_operation(
            cancelled["id"], confirmation=cancelled["rollbackToken"],
            facts=facts, provider=provider,
        )
        if (
            rollback_node.get("status") != "complete"
            or _is_installed("nodejs")
            or _is_installed("pnpm")
        ):
            raise RuntimeError(f"final rollback left packages installed: {rollback_node!r}")

        print(
            "PASS: real pacman completed active Node.js transaction, honored cancel "
            "at the safe boundary, resumed pnpm, repeated idempotently, and rolled back."
        )
    finally:
        shutil.rmtree(temp_root)


def main() -> int:
    _assert_disposable_arch_ci()
    os.environ["LANG"] = "C"
    os.environ["LC_ALL"] = "C"
    if len(sys.argv) == 5 and sys.argv[1] == "_apply":
        return _apply_child(sys.argv[2], sys.argv[3], Path(sys.argv[4]))
    if len(sys.argv) != 1:
        raise SystemExit("usage: pacman_cancel_g2.py")
    _run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
