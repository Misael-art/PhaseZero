#!/usr/bin/env python3
"""PhaseZero UI Server - localhost-only web dashboard (Python stdlib only)."""

import argparse
import concurrent.futures
import hmac
import http.server
import http.cookies
import json
import os
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import urllib.parse
import secrets
import pathlib
import time
import threading

PZ_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
STATE_DIR = pathlib.Path(os.environ.get("XDG_STATE_HOME", "~/.local/state")).expanduser() / "phasezero"
TOKEN_FILE = STATE_DIR / "ui-token"
RUNTIME_ALLOWLIST_FILE = STATE_DIR / "ui-actions.json"
ALLOWLIST_FILE = RUNTIME_ALLOWLIST_FILE if RUNTIME_ALLOWLIST_FILE.is_file() else PZ_ROOT / "linux" / "ui" / "actions.json"
STATIC_DIR = PZ_ROOT / "linux" / "ui" / "static"
TEMPLATE_DIR = PZ_ROOT / "linux" / "ui" / "templates"
UI_PORT = 8080
UI_BIND = "127.0.0.1"
MAX_BODY_BYTES = 64 * 1024
MAX_LOG_CHARS = 2 * 1024 * 1024
STATUS_TIMEOUT = 30
ACTION_TIMEOUT = 30 * 60
MODULES = ("system", "steamdeck", "emulation", "server", "ai")
ACTION_LOCK = threading.Lock()


def _valid_token(value):
    return len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def ensure_token():
    """Create a private, non-symlink token file and repair legacy permissions."""
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_info = STATE_DIR.lstat()
    if not stat.S_ISDIR(state_info.st_mode) or STATE_DIR.is_symlink():
        raise RuntimeError(f"unsafe UI state path: {STATE_DIR}")
    if state_info.st_uid != os.geteuid():
        raise RuntimeError(f"UI state path is not owned by current user: {STATE_DIR}")
    try:
        STATE_DIR.chmod(0o700)
    except OSError:
        pass

    if TOKEN_FILE.exists() or TOKEN_FILE.is_symlink():
        info = TOKEN_FILE.lstat()
        if not stat.S_ISREG(info.st_mode) or TOKEN_FILE.is_symlink():
            raise RuntimeError(f"unsafe UI token path: {TOKEN_FILE}")
        if info.st_uid != os.geteuid():
            raise RuntimeError(f"UI token is not owned by current user: {TOKEN_FILE}")
        token = TOKEN_FILE.read_text(encoding="ascii").strip()
        if _valid_token(token):
            try:
                TOKEN_FILE.chmod(0o600)
            except OSError:
                pass
            return token

    token = secrets.token_hex(32)
    temporary = TOKEN_FILE.with_name(
        f".{TOKEN_FILE.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    )
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            handle.write(token + "\n")
        temporary.replace(TOKEN_FILE)
        TOKEN_FILE.chmod(0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return token


def _actions_from_catalog():
    """Build the web/TUI allowlist from the live native catalog.

    The native UI (linux/ui_native/catalog.py) is the single source of truth for
    the action set. Mapping ActionSpec -> the legacy web schema (name/label/
    command/module/mutable) keeps every implemented function reachable from the
    web and TUI surfaces, which previously read a hand-maintained snapshot
    (linux/ui/actions.json) that had drifted behind the catalog.
    """
    import sys as _sys
    if str(PZ_ROOT) not in _sys.path:
        _sys.path.insert(0, str(PZ_ROOT))
    try:
        from linux.ui_native.catalog import build_catalog
    except Exception:
        return None
    actions = {}
    for spec in build_catalog(PZ_ROOT):
        argv = [str(PZ_ROOT / "linux" / "pz"), *spec.args]
        preview_argv = (
            [str(PZ_ROOT / "linux" / "pz"), *spec.preview_args]
            if spec.preview_args is not None else None
        )
        actions[spec.id] = {
            "name": spec.id,
            "label": spec.title,
            "command": shlex.join(["linux/pz", *spec.args]),
            "argv": argv,
            "preview_argv": preview_argv,
            "mutable": bool(spec.mutable),
            "require_plan": bool(spec.mutable),
            "module": spec.category,
            "elevated": bool(spec.elevated),
            "input_kind": spec.input_kind,
            "input_label": spec.input_label,
        }
    return actions


def load_actions():
    live = _actions_from_catalog()
    if live is not None:
        return live
    # Fallback: the static allowlist snapshot (kept for environments where the
    # native catalog module cannot be imported).
    if ALLOWLIST_FILE.exists():
        data = json.loads(ALLOWLIST_FILE.read_text(encoding="utf-8"))
        actions = {}
        for action in data.get("actions", []):
            if not isinstance(action, dict) or not isinstance(action.get("name"), str):
                continue
            entry = dict(action)
            try:
                entry["argv"] = shlex.split(str(entry["command"]))
                plan = entry.get("plan_command")
                entry["preview_argv"] = shlex.split(str(plan)) if plan else None
            except ValueError:
                continue
            if "{input}" in entry["argv"]:
                entry.setdefault("input_kind", "path")
                entry.setdefault("input_label", "Caminho no host")
            actions[entry["name"]] = entry
        return actions
    return {}


def run_bash(cmd_list, timeout=STATUS_TIMEOUT):
    """Run an argv allowlist entry without a shell; kill descendants on timeout."""
    try:
        process = subprocess.Popen(
            cmd_list,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(PZ_ROOT),
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                process.kill()
            stdout, stderr = process.communicate()
            message = f"timeout after {timeout}s"
            stderr = f"{stderr}\n{message}" if stderr else message
            return False, stdout[-MAX_LOG_CHARS:], stderr[-MAX_LOG_CHARS:]
        return (
            process.returncode == 0,
            stdout[-MAX_LOG_CHARS:],
            stderr[-MAX_LOG_CHARS:],
        )
    except OSError as exc:
        return False, "", f"command failed to start: {exc}"


def build_envelope(module, status, checks=None, actions=None, blockers=None, logs=None):
    return {
        "ok": status == "ok",
        "module": module,
        "status": status,
        "checks": checks or [],
        "actions": actions or [],
        "blockers": blockers or [],
        "logs": logs or [],
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def run_module_status(module):
    """Run the status command for a module and return envelope JSON."""
    if module == "system":
        ok, out, err = run_bash(["env", "PZ_DOCTOR_SCOPE=system", "bash", "linux/audit/doctor.sh"])
        c = [{"name": "doctor", "status": "ok" if ok else "warn", "message": "exit " + str(0 if ok else 1)}]
        return build_envelope("system", "ok" if ok else "warn", checks=c)
    elif module == "steamdeck":
        ok, out, err = run_bash(["bash", "linux/steamdeck/status.sh"])
        c = [{"name": "steamdeck.status", "status": "ok" if ok else "warn", "message": ""}]
        return build_envelope("steamdeck", "ok" if ok else "warn", checks=c)
    elif module == "emulation":
        def probe(sub):
            ok, out, err = run_bash(["bash", f"linux/emulation/{sub[1]}", "status", "--json"])
            checks = []
            if ok and out.strip():
                try:
                    j = json.loads(out)
                    checks.extend(j.get("checks", []))
                except json.JSONDecodeError:
                    checks.append({"name": f"emulation.{sub[0]}", "status": "warn", "message": "json parse error"})
            else:
                checks.append({"name": f"emulation.{sub[0]}", "status": "warn", "message": "failed"})
            return checks

        checks = []
        probes = [("shared", "shared-content.sh"), ("media", "media.sh"), ("shortcuts", "shortcuts.sh")]
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(probes)) as executor:
            for probe_checks in executor.map(probe, probes):
                checks.extend(probe_checks)
        status = "ok" if all(c.get("status") in ("ok", "running") for c in checks) else "warn"
        return build_envelope("emulation", status, checks=checks)
    elif module == "ai":
        ok, out, err = run_bash(["bash", "linux/ai/status.sh"])
        c = [{"name": "ai.status", "status": "ok" if ok else "warn", "message": ""}]
        return build_envelope("ai", "ok" if ok else "warn", checks=c)
    elif module == "server":
        checks = []
        ok, out, err = run_bash(["bash", "linux/server/homelab-stack.sh", "status"])
        if ok and out.strip():
            try:
                homelab = json.loads(out)
                checks.append({"name": "homelab.docker", "status": "ok" if homelab.get("docker", {}).get("reachable") else "warn", "message": "Docker daemon"})
                checks.append({"name": "homelab.env", "status": "ok" if homelab.get("env", {}).get("exists") else "warn", "message": homelab.get("paths", {}).get("envFile", "")})
                blockers = homelab.get("blockers", [])
                checks.append({"name": "homelab.blockers", "status": "ok" if not blockers else "blocked", "message": ", ".join(blockers[:3])})
                for app in homelab.get("apps", [])[:8]:
                    checks.append({"name": f"homelab.{app.get('key')}", "status": "running" if app.get("running") else "warn", "message": app.get("url", "")})
            except json.JSONDecodeError:
                checks.append({"name": "homelab.status", "status": "warn", "message": "json parse error"})
        else:
            checks.append({"name": "homelab.status", "status": "warn", "message": err[:160]})

        ok, out, err = run_bash(["bash", "linux/server/casaos.sh", "status"])
        if ok and out.strip():
            try:
                casaos = json.loads(out)
                checks.append({"name": "casaos.status", "status": "ok" if casaos.get("status") in ("installed", "available") else "warn", "message": casaos.get("status", "")})
            except json.JSONDecodeError:
                checks.append({"name": "casaos.status", "status": "warn", "message": "json parse error"})
        else:
            checks.append({"name": "casaos.status", "status": "warn", "message": err[:160] or "failed"})
        status = "ok" if all(c.get("status") in ("ok", "running") for c in checks) else "warn"
        return build_envelope("server", status, checks=checks)
    else:
        return build_envelope(module, "warn", checks=[{"name": "unknown", "status": "warn", "message": f"unknown module: {module}"}])


def run_all_status():
    """Run independent status probes concurrently; isolate any probe crash."""
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(MODULES)) as executor:
        futures = {executor.submit(run_module_status, module): module for module in MODULES}
        for future in concurrent.futures.as_completed(futures):
            module = futures[future]
            try:
                results[module] = future.result()
            except Exception as exc:  # defensive API boundary; individual probe must not kill overview
                results[module] = build_envelope(
                    module,
                    "warn",
                    checks=[{"name": f"{module}.status", "status": "warn", "message": str(exc)[:160]}],
                )
    return {module: results[module] for module in MODULES}


class PZHTTPHandler(http.server.BaseHTTPRequestHandler):
    allowlist = load_actions()
    token = ensure_token()

    def log_message(self, fmt, *args):
        msg = fmt % args
        # redact token from logs
        redacted = msg.replace(self.token, "***redacted***")
        sys.stderr.write(f"{self.log_date_time_string()} {redacted}\n")

    def _security_headers(self, *, cache=False):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cache-Control", "private, max-age=300" if cache else "no-store")

    def _send_json(self, data, status=200):
        payload = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self._security_headers()
        self.end_headers()
        self.wfile.write(payload)

    def _send_html(self, html, status=200):
        payload = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; base-uri 'none'; connect-src 'self'; "
            "frame-ancestors 'none'; form-action 'none'; img-src 'self' data:; "
            "object-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'",
        )
        self._security_headers()
        self.end_headers()
        self.wfile.write(payload)

    def _bootstrap_cookie(self):
        self.send_response(303)
        self.send_header("Location", "/")
        self.send_header("Content-Length", "0")
        self.send_header(
            "Set-Cookie",
            f"pz_ui_token={self.token}; HttpOnly; SameSite=Strict; Path=/",
        )
        self._security_headers()
        self.end_headers()

    def _send_file(self, path, mime="application/octet-stream"):
        if not path.is_file():
            self.send_error(404)
            return
        payload = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(payload)))
        self._security_headers(cache=True)
        self.end_headers()
        self.wfile.write(payload)

    def _verify_token(self):
        auth = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        if auth and hmac.compare_digest(auth, self.token):
            return True
        cookie = http.cookies.SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
        except http.cookies.CookieError:
            return False
        supplied = cookie.get("pz_ui_token")
        return supplied is not None and hmac.compare_digest(supplied.value, self.token)

    def _same_origin(self):
        if self.headers.get("Sec-Fetch-Site", "") == "cross-site":
            return False
        origin = self.headers.get("Origin")
        if not origin:
            return True
        port = self.server.server_address[1]
        return origin in {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}

    def _valid_host(self):
        host = self.headers.get("Host", "")
        try:
            parsed = urllib.parse.urlsplit(f"//{host}")
            port = parsed.port
        except ValueError:
            return False
        expected_port = self.server.server_address[1]
        return parsed.hostname in {"127.0.0.1", "localhost"} and port in {None, expected_port}

    def _reject_invalid_host(self):
        if self._valid_host():
            return False
        self._send_json(build_envelope("system", "blocked", blockers=["invalid Host header"]), 421)
        return True

    def _read_body(self):
        if self.headers.get("Transfer-Encoding"):
            raise ValueError("transfer encoding unsupported")
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().casefold()
        if content_type != "application/json":
            raise TypeError("Content-Type must be application/json")
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if length < 0 or length > MAX_BODY_BYTES:
            raise OverflowError("request body too large")
        if length == 0:
            return {}
        try:
            value = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("invalid JSON body") from exc
        if not isinstance(value, dict):
            raise ValueError("JSON body must be an object")
        return value

    def _require_auth(self, module="system"):
        if self._verify_token():
            return True
        self._send_json(build_envelope(module, "blocked", blockers=["invalid token"]), 401)
        return False

    @staticmethod
    def _public_action(entry):
        return {
            "name": entry.get("name", ""),
            "label": entry.get("label", entry.get("name", "")),
            "mutable": bool(entry.get("mutable")),
            "module": entry.get("module", ""),
            "inputKind": entry.get("input_kind", ""),
            "inputLabel": entry.get("input_label", ""),
        }

    @staticmethod
    def _resolved_argv(entry, *, preview, input_value):
        source = entry.get("preview_argv") if preview else entry.get("argv")
        if not source:
            return None
        if not isinstance(input_value, str) or len(input_value) > 4096 or "\x00" in input_value:
            raise ValueError("invalid input value")
        if "{input}" in source and not input_value:
            raise ValueError("input path required")
        return [input_value if token == "{input}" else str(token) for token in source]

    def do_GET(self):
        if self._reject_invalid_host():
            return
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/" or path == "/index.html":
            tokens = urllib.parse.parse_qs(parsed.query, keep_blank_values=True).get("token", [])
            if tokens:
                if len(tokens) == 1 and hmac.compare_digest(tokens[0], self.token):
                    self._bootstrap_cookie()
                else:
                    self._send_html("<h1>PhaseZero</h1><p>Token inválido.</p>", 403)
                return
            if not self._verify_token():
                self._send_html(
                    "<h1>PhaseZero</h1><p>Autenticação necessária. Abra com <code>linux/pz ui web</code>.</p>",
                    401,
                )
                return
            tpl = TEMPLATE_DIR / "dashboard.html"
            if tpl.exists():
                html = tpl.read_text(encoding="utf-8").replace("{{TOKEN}}", "")
                self._send_html(html)
            else:
                self._send_html("<h1>PhaseZero UI</h1><p>Loading...</p>")
        elif path.startswith("/static/"):
            spath = urllib.parse.unquote(path.removeprefix("/static/"))
            static_root = STATIC_DIR.resolve()
            try:
                fpath = (static_root / spath).resolve()
                fpath.relative_to(static_root)
            except (OSError, ValueError):
                self.send_error(404)
                return
            mime_map = {".css": "text/css", ".js": "application/javascript", ".png": "image/png",
                        ".svg": "image/svg+xml", ".woff2": "font/woff2"}
            ext = fpath.suffix
            mime = mime_map.get(ext, "application/octet-stream")
            self._send_file(fpath, mime)
        elif path == "/api/modules":
            if self._require_auth():
                self._send_json({"modules": list(MODULES)})
        elif path.startswith("/api/status/"):
            module = path.removeprefix("/api/status/")
            if module not in MODULES:
                self._send_json(build_envelope(module, "blocked", blockers=["unknown module"]), 404)
                return
            if self._require_auth(module):
                self._send_json(run_module_status(module))
        elif path == "/api/status":
            if self._require_auth():
                self._send_json(run_all_status())
        elif path == "/api/actions":
            if self._require_auth():
                actions = [self._public_action(entry) for entry in self.allowlist.values()]
                self._send_json({"actions": actions})
        elif path == "/api/token-status":
            valid = self._verify_token()
            self._send_json({"valid": valid})
        else:
            self.send_error(404)

    def do_POST(self):
        if self._reject_invalid_host():
            return
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if not self._same_origin():
            self._send_json(build_envelope("system", "blocked", blockers=["cross-origin request"]), 403)
            return
        if not self._require_auth():
            return

        if path == "/api/action":
            try:
                body = self._read_body()
            except OverflowError as exc:
                self._send_json(build_envelope("system", "blocked", blockers=[str(exc)]), 413)
                return
            except TypeError as exc:
                self._send_json(build_envelope("system", "blocked", blockers=[str(exc)]), 415)
                return
            except ValueError as exc:
                self._send_json(build_envelope("system", "blocked", blockers=[str(exc)]), 400)
                return
            action_name = body.get("action", "")
            confirmed = body.get("confirmed") is True
            input_value = body.get("input", "")

            if not isinstance(action_name, str) or action_name not in self.allowlist:
                self._send_json(build_envelope("system", "blocked", blockers=[f"action not in allowlist: {action_name}"]), 403)
                return

            entry = self.allowlist[action_name]
            if entry.get("require_plan", False) and not confirmed:
                try:
                    plan_cmd = self._resolved_argv(entry, preview=True, input_value=input_value)
                except ValueError as exc:
                    self._send_json(build_envelope(entry["module"], "blocked", blockers=[str(exc)]), 400)
                    return
                if plan_cmd is None:
                    self._send_json(build_envelope(
                        entry["module"], "blocked",
                        blockers=["safe preview unavailable; action not executed"],
                    ), 409)
                    return
                ok, out, err = run_bash(plan_cmd, timeout=ACTION_TIMEOUT)
                logs = []
                if out:
                    logs.append({"level": "info", "message": out})
                if err:
                    logs.append({"level": "error", "message": err})
                self._send_json(build_envelope(
                    entry["module"], "ok" if ok else "warn",
                    logs=logs,
                    blockers=["confirmation required"],
                ))
                return

            try:
                cmd = self._resolved_argv(entry, preview=False, input_value=input_value)
            except ValueError as exc:
                self._send_json(build_envelope(entry["module"], "blocked", blockers=[str(exc)]), 400)
                return
            if cmd is None:
                self._send_json(build_envelope(entry["module"], "blocked", blockers=["command unavailable"]), 409)
                return
            if entry.get("elevated"):
                bridge = shutil.which("phasezero-admin") or shutil.which("bigsudo") or shutil.which("pkexec")
                if not bridge:
                    self._send_json(build_envelope(
                        entry["module"], "blocked",
                        blockers=["admin bridge unavailable; run `linux/pz ai setup admin`"],
                    ), 503)
                    return
                cmd = [bridge, *cmd]
            if not ACTION_LOCK.acquire(blocking=False):
                self._send_json(build_envelope(entry["module"], "blocked", blockers=["another action is running"]), 409)
                return
            try:
                ok, out, err = run_bash(cmd, timeout=ACTION_TIMEOUT)
            finally:
                ACTION_LOCK.release()
            status = "ok" if ok else "warn"
            logs = []
            if out:
                logs.append({"level": "info", "message": out})
            if err:
                logs.append({"level": "error", "message": err})
            self._send_json(build_envelope(entry["module"], status, logs=logs))
        else:
            self.send_error(404)

    def do_OPTIONS(self):
        if not self._reject_invalid_host():
            self.send_error(405)


class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 32


def _port(value):
    port = int(value)
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return port


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="PhaseZero localhost dashboard")
    parser.add_argument("--port", type=_port, default=UI_PORT)
    parser.add_argument("--daemon", nargs="?", const="", metavar="LOG_FILE")
    args = parser.parse_args()

    log_stream = None
    if args.daemon:
        log_path = pathlib.Path(args.daemon).expanduser()
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_stream = log_path.open("a", encoding="utf-8", buffering=1)
        sys.stdout = log_stream
        sys.stderr = log_stream

    server = ThreadingHTTPServer((UI_BIND, args.port), PZHTTPHandler)
    print(f"PhaseZero UI: http://{UI_BIND}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nserver stopped", flush=True)
    finally:
        server.server_close()
        if log_stream is not None:
            log_stream.close()


if __name__ == "__main__":
    main()
