#!/usr/bin/env python3
"""phasezero-agent: TLS+token allowlist in front of user `pz`. No docker.sock, no shell."""
from __future__ import annotations

import hashlib
import json
import os
import secrets
import shutil
import ssl
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlparse

SCHEMA = "1"
SERVICE = "phasezero-homelab._tcp"
PAIRING_TTL_SEC = 15 * 60
RATE_WINDOW_SEC = 60
RATE_MAX = 20
AUTH_FAIL_MAX = 5
CMD_TIMEOUT_SEC = 30

ALLOWLIST: dict[str, list[str]] = {
    "status": ["server", "homelab", "status", "--json"],
    "plan": ["server", "homelab", "plan", "--json"],
    "apps.list": ["server", "homelab", "apps", "list", "--json"],
    "apps.enable": ["server", "homelab", "apps", "enable", "{app}", "--json"],
    "apps.disable": ["server", "homelab", "apps", "disable", "{app}", "--json"],
    "apps.update": ["server", "homelab", "apps", "update", "{app}", "--json"],
    "backup": ["server", "homelab", "backup", "--json"],
    "restore.plan": ["server", "homelab", "restore", "--source", "{source}", "--plan"],
}

Invoker = Callable[[list[str]], tuple[int, str, str]]


def _state_dir() -> Path:
    override = os.environ.get("PZ_HOMELAB_AGENT_STATE")
    if override:
        return Path(override)
    xdg = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(xdg) / "phasezero" / "homelab-agent"


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _now() -> float:
    return time.time()


def _atomic_write(path: Path, data: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(data, encoding="utf-8")
    os.chmod(tmp, mode)
    tmp.replace(path)


class HomelabAgent:
    def __init__(
        self,
        state_dir: Path | None = None,
        pz_bin: str | None = None,
        invoker: Invoker | None = None,
        bind: str = "127.0.0.1",
        port: int = 17432,
    ) -> None:
        self.state_dir = state_dir or _state_dir()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state_dir, 0o700)
        self.pz_bin = pz_bin or os.environ.get(
            "PZ_HOMELAB_PZ_BIN",
            str(Path(__file__).resolve().parents[2] / "linux" / "pz"),
        )
        self.invoker = invoker or self._default_invoker
        self.bind = os.environ.get("PZ_HOMELAB_AGENT_BIND", bind)
        self.port = int(os.environ.get("PZ_HOMELAB_AGENT_PORT", str(port)))
        self._hits: dict[str, list[float]] = {}
        self._auth_fails: dict[str, list[float]] = {}
        self._shown_pairing = False

    def _path(self, name: str) -> Path:
        return self.state_dir / name

    def kill_switch_on(self) -> bool:
        return self._path("agent.kill").exists()

    def set_kill_switch(self, on: bool) -> None:
        p = self._path("agent.kill")
        if on:
            p.write_text("1\n", encoding="utf-8")
            os.chmod(p, 0o600)
        elif p.exists():
            p.unlink()

    def audit(self, action: str, result: str, peer: str = "") -> None:
        line = json.dumps(
            {
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "action": action,
                "result": result,
                "peer": peer,
            },
            separators=(",", ":"),
        )
        log = self._path("audit.log")
        with log.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        os.chmod(log, 0o600)

    def _load_json(self, name: str, default: dict) -> dict:
        path = self._path(name)
        if not path.is_file():
            return dict(default)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return dict(default)
        return data if isinstance(data, dict) else dict(default)

    def _save_json(self, name: str, data: dict) -> None:
        _atomic_write(self._path(name), json.dumps(data, indent=2) + "\n")

    def issue_pairing_token(self) -> str:
        token = secrets.token_urlsafe(24)
        self._save_json(
            "pairing.json",
            {
                "schemaVersion": SCHEMA,
                "tokenHash": _hash(token),
                "expiresAt": _now() + PAIRING_TTL_SEC,
                "consumed": False,
            },
        )
        self._shown_pairing = True
        self.audit("pairing.issue", "ok")
        return token

    def pair(self, token: str, peer: str = "") -> str | None:
        if self.kill_switch_on():
            self.audit("pair", "kill-switch", peer)
            return None
        rec = self._load_json("pairing.json", {})
        if not rec or rec.get("consumed") or _now() > float(rec.get("expiresAt") or 0):
            self.audit("pair", "denied-expired", peer)
            return None
        if _hash(token) != rec.get("tokenHash"):
            self.audit("pair", "denied-token", peer)
            return None
        rec["consumed"] = True
        self._save_json("pairing.json", rec)
        session = secrets.token_urlsafe(32)
        sessions = self._load_json("sessions.json", {"schemaVersion": SCHEMA, "sessions": []})
        sessions.setdefault("sessions", []).append(
            {"tokenHash": _hash(session), "createdAt": _now()}
        )
        self._save_json("sessions.json", sessions)
        self.audit("pair", "ok", peer)
        return session

    def authorize(self, token: str | None, peer: str = "") -> bool:
        if self.kill_switch_on():
            return False
        if not token:
            self.audit("auth", "denied-missing", peer)
            return False
        sessions = self._load_json("sessions.json", {"sessions": []}).get("sessions") or []
        digest = _hash(token)
        for item in sessions:
            if item.get("tokenHash") == digest:
                return True
        self.audit("auth", "denied-token", peer)
        return False

    def revoke(self, token: str | None, peer: str = "") -> bool:
        sessions = self._load_json("sessions.json", {"sessions": []})
        items = list(sessions.get("sessions") or [])
        digest = _hash(token or "")
        kept = [s for s in items if s.get("tokenHash") != digest]
        sessions["sessions"] = kept
        self._save_json("sessions.json", sessions)
        pairing = self._load_json("pairing.json", {})
        if pairing:
            pairing["consumed"] = True
            self._save_json("pairing.json", pairing)
        self.audit("revoke", "ok" if len(kept) != len(items) else "noop", peer)
        return len(kept) != len(items)

    def rate_limited(self, peer: str, failed_auth: bool = False) -> bool:
        now = _now()
        bucket = self._auth_fails if failed_auth else self._hits
        limit = AUTH_FAIL_MAX if failed_auth else RATE_MAX
        hits = [t for t in bucket.get(peer, []) if now - t < RATE_WINDOW_SEC]
        hits.append(now)
        bucket[peer] = hits
        return len(hits) > limit

    def _default_invoker(self, argv: list[str]) -> tuple[int, str, str]:
        proc = subprocess.run(
            [self.pz_bin, *argv],
            capture_output=True,
            text=True,
            timeout=CMD_TIMEOUT_SEC,
            shell=False,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def run_command(self, name: str, args: dict[str, str] | None, peer: str = "") -> dict[str, Any]:
        if self.kill_switch_on():
            self.audit(name, "kill-switch", peer)
            return {"ok": False, "error": "kill switch engaged", "code": 503}
        if name not in ALLOWLIST:
            self.audit(name, "denied-allowlist", peer)
            return {"ok": False, "error": "command not in allowlist", "code": 403}
        if name.startswith("restore") and args and args.get("yes"):
            self.audit(name, "denied-yes", peer)
            return {"ok": False, "error": "restore --yes is forbidden", "code": 403}
        template = list(ALLOWLIST[name])
        argv: list[str] = []
        for part in template:
            if part.startswith("{") and part.endswith("}"):
                key = part[1:-1]
                value = (args or {}).get(key, "")
                if not value or not _safe_arg(value):
                    self.audit(name, "denied-arg", peer)
                    return {"ok": False, "error": f"invalid argument: {key}", "code": 400}
                argv.append(value)
            else:
                argv.append(part)
        rc, stdout, stderr = self.invoker(argv)
        self.audit(name, "ok" if rc == 0 else "pz-error", peer)
        payload: Any = None
        try:
            payload = json.loads(stdout) if stdout.strip().startswith("{") else None
        except json.JSONDecodeError:
            payload = None
        return {
            "ok": rc == 0,
            "code": 200 if rc == 0 else 502,
            "rc": rc,
            "payload": payload,
            "error": None if rc == 0 else (stderr.strip().splitlines() or ["pz failed"])[-1],
        }

    def mdns_status(self) -> dict[str, Any]:
        avahi = shutil.which("avahi-browse") or shutil.which("avahi-daemon")
        unit_masked = Path("/etc/systemd/system/avahi-daemon.service").is_symlink()
        enabled = bool(avahi) and not unit_masked
        return {
            "schemaVersion": SCHEMA,
            "service": SERVICE,
            "advertised": False,
            "avahiPresent": bool(avahi),
            "wouldReenableAvahi": False,
            "manualFallback": "IP:17432",
            "reason": None
            if enabled
            else "avahi ausente ou desabilitado (os-slim); use IP:porta. Agente nao reativa avahi.",
        }

    def status(self) -> dict[str, Any]:
        pairing = self._load_json("pairing.json", {})
        sessions = self._load_json("sessions.json", {"sessions": []})
        return {
            "schemaVersion": SCHEMA,
            "tool": "homelab-agent",
            "bind": self.bind,
            "port": self.port,
            "killSwitch": self.kill_switch_on(),
            "pairingConsumed": bool(pairing.get("consumed")),
            "sessions": len(sessions.get("sessions") or []),
            "mdns": self.mdns_status(),
            "allowlist": sorted(ALLOWLIST),
        }


def _safe_arg(value: str) -> bool:
    if not value or len(value) > 256:
        return False
    if any(ch in value for ch in " \t\n;|&$`<>(){}[]\\\"'"):
        return False
    return True


def _json_bytes(payload: dict) -> bytes:
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


class AgentHTTPServer(ThreadingHTTPServer):
    agent: HomelabAgent


def _handler_for(agent: HomelabAgent):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args: Any) -> None:
            return

        def _peer(self) -> str:
            return self.client_address[0] if self.client_address else "unknown"

        def _read_json(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > 8192:
                return {}
            raw = self.rfile.read(length)
            try:
                data = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return {}
            return data if isinstance(data, dict) else {}

        def _send(self, code: int, payload: dict) -> None:
            body = _json_bytes(payload)
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _bearer(self) -> str | None:
            header = self.headers.get("Authorization") or ""
            if not header.startswith("Bearer "):
                return None
            token = header[7:].strip()
            return token or None

        def do_POST(self) -> None:  # noqa: N802
            peer = self._peer()
            if agent.rate_limited(peer):
                self._send(429, {"ok": False, "error": "rate limited"})
                return
            if agent.kill_switch_on():
                self._send(503, {"ok": False, "error": "kill switch engaged"})
                return
            path = urlparse(self.path).path
            body = self._read_json()
            if path == "/v1/pair":
                token = str(body.get("pairingToken") or "")
                session = agent.pair(token, peer)
                if not session:
                    limited = agent.rate_limited(peer, failed_auth=True)
                    self._send(
                        429 if limited else 401,
                        {"ok": False, "error": "rate limited" if limited else "pairing denied"},
                    )
                    return
                self._send(200, {"ok": True, "sessionToken": session})
                return
            token = self._bearer()
            if not agent.authorize(token, peer):
                agent.rate_limited(peer, failed_auth=True)
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            if path == "/v1/revoke":
                agent.revoke(token, peer)
                self._send(200, {"ok": True})
                return
            if path == "/v1/command":
                name = str(body.get("name") or "")
                args = body.get("args") if isinstance(body.get("args"), dict) else {}
                result = agent.run_command(name, {str(k): str(v) for k, v in args.items()}, peer)
                self._send(int(result.get("code") or 400), result)
                return
            self._send(404, {"ok": False, "error": "not found"})

        def do_GET(self) -> None:  # noqa: N802
            peer = self._peer()
            if agent.rate_limited(peer):
                self._send(429, {"ok": False, "error": "rate limited"})
                return
            if urlparse(self.path).path != "/v1/status":
                self._send(404, {"ok": False, "error": "not found"})
                return
            token = self._bearer()
            if not agent.authorize(token, peer):
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            self._send(200, {"ok": True, **agent.status()})

    return Handler


def serve(agent: HomelabAgent, tls: bool = True) -> ThreadingHTTPServer:
    httpd = AgentHTTPServer((agent.bind, agent.port), _handler_for(agent))
    httpd.agent = agent
    if tls:
        cert = agent._path("cert.pem")
        key = agent._path("key.pem")
        if not cert.is_file() or not key.is_file():
            raise RuntimeError("TLS cert missing; run install first")
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(cert), str(key))
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    return httpd


def _cli(argv: list[str]) -> int:
    json_out = "--json" in argv
    args = [a for a in argv if a != "--json"]
    action = args[0] if args else "status"
    agent = HomelabAgent()
    if action == "install":
        token = agent.issue_pairing_token()
        payload = {**agent.status(), "action": "install", "pairingToken": token, "shownOnce": True}
        print(json.dumps(payload, separators=(",", ":")))
        if not json_out:
            print("pairing token (shown once):", token, file=sys.stderr)
        return 0
    if action == "pair":
        token = ""
        if "--token" in args:
            token = args[args.index("--token") + 1]
        session = agent.pair(token)
        payload = {
            "schemaVersion": SCHEMA,
            "action": "pair",
            "ok": bool(session),
            "sessionToken": session,
        }
        print(json.dumps(payload, separators=(",", ":")))
        return 0 if session else 1
    if action == "revoke":
        token = ""
        if "--token" in args:
            token = args[args.index("--token") + 1]
        ok = agent.revoke(token)
        print(json.dumps({"schemaVersion": SCHEMA, "action": "revoke", "ok": ok}))
        return 0
    if action == "kill":
        agent.set_kill_switch(True)
        print(json.dumps({"schemaVersion": SCHEMA, "action": "kill", "ok": True}))
        return 0
    if action in {"unkill", "unkill-switch"}:
        agent.set_kill_switch(False)
        print(json.dumps({"schemaVersion": SCHEMA, "action": "unkill", "ok": True}))
        return 0
    if action == "discover":
        print(json.dumps({"schemaVersion": SCHEMA, "action": "discover", **agent.mdns_status()}))
        return 0
    if action == "status":
        print(json.dumps(agent.status(), separators=(",", ":")))
        return 0
    print("usage: homelab_agent.py (install|status|pair|revoke|discover|kill) [--json]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
