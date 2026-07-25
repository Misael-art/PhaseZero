from __future__ import annotations
import hashlib
import re
import subprocess
import zipfile
from pathlib import Path

VerificationResult = tuple[bool, str]  # (passed, message)


def verify_chd(
    path: Path, *, chdman: str = "chdman", timeout: int = 300
) -> VerificationResult:
    try:
        r = subprocess.run([chdman, "verify", str(path)],
                           capture_output=True, text=True, stdin=subprocess.DEVNULL,
                           timeout=timeout)
        if r.returncode == 0:
            return True, "CHD verification passed"
        return False, r.stderr.strip() or r.stdout.strip()
    except FileNotFoundError:
        return False, f"chdman not found"
    except subprocess.TimeoutExpired:
        return False, "chdman verify timed out"


def verify_rvz(
    path: Path, *, tool: str = "dolphin-tool", timeout: int = 300
) -> VerificationResult:
    try:
        r = subprocess.run([tool, "verify", "-i", str(path)],
                           capture_output=True, text=True, stdin=subprocess.DEVNULL,
                           timeout=timeout)
        if r.returncode == 0:
            return True, "RVZ verification passed"
        return False, r.stderr.strip() or r.stdout.strip()
    except FileNotFoundError:
        return False, f"{tool} not found"
    except subprocess.TimeoutExpired:
        return False, "verify timed out"


def verify_nsz(
    path: Path, *, tool: str = "nsz", timeout: int = 300
) -> VerificationResult:
    try:
        r = subprocess.run([tool, "-V", str(path)],
                           capture_output=True, text=True, stdin=subprocess.DEVNULL,
                           timeout=timeout)
        if r.returncode == 0:
            return True, "NSZ verification passed"
        return False, r.stderr.strip() or r.stdout.strip()
    except FileNotFoundError:
        return False, "nsz not found"
    except subprocess.TimeoutExpired:
        return False, "nsz verify timed out"


def verify_sha256(path: Path, expected_hash: str = "") -> VerificationResult:
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        actual = h.hexdigest()
        if expected_hash and actual != expected_hash:
            return False, f"SHA256 mismatch: expected {expected_hash}, got {actual}"
        return True, actual
    except Exception as e:
        return False, str(e)


def verify_cso(
    path: Path,
    expected_crc32: str = "",
    *,
    tool: str = "maxcso",
    timeout: int = 300,
) -> VerificationResult:
    """Ask maxcso to read every compressed block and report source CRC32."""
    try:
        result = subprocess.run(
            [tool, "--crc", str(path)],
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=timeout,
        )
        output = f"{result.stdout}\n{result.stderr}"
        if result.returncode != 0:
            return False, output.strip()[-500:] or "maxcso CRC verification failed"
        matches = re.findall(r"\b[0-9a-fA-F]{8}\b", output)
        if not matches:
            return False, "maxcso did not report a CRC32"
        actual = matches[-1].lower()
        if expected_crc32 and actual != expected_crc32.lower():
            return False, f"CRC32 mismatch: expected {expected_crc32}, got {actual}"
        return True, f"source CRC32 {actual}"
    except FileNotFoundError:
        return False, f"{tool} not found"
    except subprocess.TimeoutExpired:
        return False, "maxcso CRC verification timed out"


def verify_zip_unzip(path: Path, *, timeout: int = 120) -> VerificationResult:
    try:
        r = subprocess.run(["unzip", "-t", str(path)],
                           capture_output=True, text=True, stdin=subprocess.DEVNULL,
                           timeout=timeout)
        if r.returncode == 0:
            # unzip -t prints "No errors detected in compressed data of ...".
            final = [l for l in r.stdout.split("\n") if "No errors detected" in l]
            return True, final[0].strip() if final else "ZIP verification passed"
        return False, r.stderr.strip() or r.stdout.strip()[-200:]
    except FileNotFoundError:
        return False, "unzip not found"
    except subprocess.TimeoutExpired:
        return False, "unzip -t timed out"


def verify_zip_python(path: Path) -> VerificationResult:
    try:
        with zipfile.ZipFile(path, "r") as zf:
            bad = zf.testzip()
            if bad:
                return False, f"corrupt entry: {bad}"
        return True, "ZIP integrity OK"
    except Exception as e:
        return False, str(e)


def verify_zip(path: Path, *, timeout: int = 120) -> VerificationResult:
    """Verify a ZIP/rezip archive. Prefer the external `unzip -t`; if unzip is
    absent, fall back to the in-process testzip(). Branch on the success flag
    rather than tuple truthiness (a non-empty tuple is always truthy)."""
    ok, msg = verify_zip_unzip(path, timeout=timeout)
    if ok:
        return True, msg
    # unzip missing or failed — try the pure-Python CRC check before giving up.
    py_ok, py_msg = verify_zip_python(path)
    if py_ok:
        return True, py_msg
    return False, msg if "not found" not in msg else py_msg


def verify_format(
    fmt: str,
    path: Path,
    expected_hash: str = "",
    *,
    timeout: int = 300,
) -> VerificationResult:
    match fmt:
        case "chd":
            return verify_chd(path, timeout=timeout)
        case "rvz":
            return verify_rvz(path, timeout=timeout)
        case "nsz" | "xcz":
            return verify_nsz(path, timeout=timeout)
        case "zip" | "rezip":
            return verify_zip(path, timeout=timeout)
        case "cso" | "zso":
            return verify_cso(path, expected_hash, timeout=timeout)
        case _:
            return verify_sha256(path, expected_hash)
