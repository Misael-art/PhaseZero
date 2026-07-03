#!/usr/bin/env python3
"""PhaseZero UI Server - lightweight web dashboard backend (Python stdlib only)."""

import http.server
import json
import os
import subprocess
import sys
import urllib.parse
import secrets
import pathlib
import threading
import time

PZ_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
STATE_DIR = pathlib.Path(os.environ.get("XDG_STATE_HOME", "~/.local/state")).expanduser() / "phasezero"
TOKEN_FILE = STATE_DIR / "ui-token"
ALLOWLIST_FILE = PZ_ROOT / "linux" / "ui" / "actions.json"
STATIC_DIR = PZ_ROOT / "linux" / "ui" / "static"
TEMPLATE_DIR = PZ_ROOT / "linux" / "ui" / "templates"
UI_PORT = 8080
UI_BIND = "127.0.0.1"


def ensure_token():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not TOKEN_FILE.exists():
        TOKEN_FILE.write_text(secrets.token_hex(32))
    return TOKEN_FILE.read_text().strip()


def load_actions():
    if ALLOWLIST_FILE.exists():
        data = json.loads(ALLOWLIST_FILE.read_text())
        return {a["name"]: a for a in data.get("actions", [])}
    return {}


def run_bash(cmd_list, timeout=60):
    """Run a bash command and return (ok, stdout, stderr)."""
    try:
        r = subprocess.run(
            cmd_list,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(PZ_ROOT),
        )
        ok = r.returncode == 0
        return ok, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return False, "", "timeout"
    except FileNotFoundError as e:
        return False, "", f"command not found: {e}"


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
        ok, out, err = run_bash(["bash", "linux/audit/doctor.sh"])
        c = [{"name": "doctor", "status": "ok" if ok else "warn", "message": "exit " + str(0 if ok else 1)}]
        return build_envelope("system", "ok" if ok else "warn", checks=c)
    elif module == "steamdeck":
        ok, out, err = run_bash(["bash", "linux/steamdeck/status.sh"])
        c = [{"name": "steamdeck.status", "status": "ok" if ok else "warn", "message": ""}]
        return build_envelope("steamdeck", "ok" if ok else "warn", checks=c)
    elif module == "emulation":
        checks = []
        for sub in [("shared", "shared-content.sh"), ("media", "media.sh"), ("shortcuts", "shortcuts.sh")]:
            ok, out, err = run_bash(["bash", f"linux/emulation/{sub[1]}", "status", "--json"])
            if ok and out.strip():
                try:
                    j = json.loads(out)
                    checks.extend(j.get("checks", []))
                except json.JSONDecodeError:
                    checks.append({"name": f"emulation.{sub[0]}", "status": "warn", "message": "json parse error"})
            else:
                checks.append({"name": f"emulation.{sub[0]}", "status": "warn", "message": "failed"})
        return build_envelope("emulation", "ok", checks=checks)
    elif module == "ai":
        ok, out, err = run_bash(["bash", "linux/ai/status.sh"])
        c = [{"name": "ai.status", "status": "ok" if ok else "warn", "message": ""}]
        return build_envelope("ai", "ok" if ok else "warn", checks=c)
    else:
        return build_envelope(module, "warn", checks=[{"name": "unknown", "status": "warn", "message": f"unknown module: {module}"}])


class PZHTTPHandler(http.server.BaseHTTPRequestHandler):
    allowlist = load_actions()
    token = ensure_token()

    def log_message(self, fmt, *args):
        msg = fmt % args
        # redact token from logs
        redacted = msg.replace(self.token, "***redacted***")
        sys.stderr.write(f"{self.log_date_time_string()} {redacted}\n")

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode())

    def _send_html(self, html, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode())

    def _send_file(self, path, mime="application/octet-stream"):
        if not path.exists():
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.end_headers()
        self.wfile.write(path.read_bytes())

    def _verify_token(self):
        auth = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        return auth == self.token

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length))

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        params = urllib.parse.parse_qs(parsed.query)

        if path == "/" or path == "/index.html":
            tpl = TEMPLATE_DIR / "dashboard.html"
            if tpl.exists():
                html = tpl.read_text().replace("{{TOKEN}}", self.token)
                self._send_html(html)
            else:
                self._send_html("<h1>PhaseZero UI</h1><p>Loading...</p>")
        elif path.startswith("/static/"):
            spath = path.removeprefix("/static/")
            fpath = STATIC_DIR / spath
            mime_map = {".css": "text/css", ".js": "application/javascript", ".png": "image/png",
                        ".svg": "image/svg+xml", ".woff2": "font/woff2"}
            ext = fpath.suffix
            mime = mime_map.get(ext, "application/octet-stream")
            self._send_file(fpath, mime)
        elif path == "/api/modules":
            mods = ["system", "steamdeck", "emulation", "ai"]
            self._send_json({"modules": mods})
        elif path.startswith("/api/status/"):
            module = path.removeprefix("/api/status/")
            if not self._verify_token():
                self._send_json(build_envelope(module, "blocked", blockers=["invalid token"]), 401)
                return
            data = run_module_status(module)
            self._send_json(data)
        elif path == "/api/status":
            if not self._verify_token():
                self._send_json(build_envelope("system", "blocked", blockers=["invalid token"]), 401)
                return
            results = {}
            for mod in ["system", "steamdeck", "emulation", "ai"]:
                results[mod] = run_module_status(mod)
            self._send_json(results)
        elif path == "/api/actions":
            self._send_json({"actions": list(self.allowlist.values())})
        elif path == "/api/token-status":
            valid = self._verify_token()
            self._send_json({"valid": valid})
        else:
            self.send_error(404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if not self._verify_token():
            self._send_json(build_envelope("system", "blocked", blockers=["invalid token"]), 401)
            return

        if path == "/api/action":
            body = self._read_body()
            action_name = body.get("action", "")
            confirmed = body.get("confirmed", False)

            if action_name not in self.allowlist:
                self._send_json(build_envelope("system", "blocked", blockers=[f"action not in allowlist: {action_name}"]), 403)
                return

            entry = self.allowlist[action_name]
            if entry.get("require_plan", False) and not confirmed:
                # return plan first
                plan_cmd = entry["command"].split()
                ok, out, err = run_bash(plan_cmd)
                return self._send_json(build_envelope(
                    entry["module"], "ok" if ok else "warn",
                    logs=[{"level": "info", "message": out[:2000]}],
                    blockers=["confirmation required"] if entry["mutable"] else []
                ))

            cmd = entry["command"].split()
            ok, out, err = run_bash(cmd)
            status = "ok" if ok else "warn"
            logs = []
            if out:
                logs.append({"level": "info", "message": out[:2000]})
            if err:
                logs.append({"level": "error", "message": err[:2000]})
            self._send_json(build_envelope(entry["module"], status, logs=logs))
        else:
            self.send_error(404)


def main():
    global UI_PORT
    args = sys.argv[1:]
    daemon_mode = False
    log_file = None

    i = 0
    while i < len(args):
        if args[i] == "--port" and i + 1 < len(args):
            UI_PORT = int(args[i + 1])
            i += 2
        elif args[i] == "--daemon" and i + 1 < len(args):
            daemon_mode = True
            log_file = args[i + 1]
            i += 2
        elif args[i] == "--daemon":
            daemon_mode = True
            i += 1
        else:
            i += 1

    if daemon_mode and log_file:
        import logging
        logging.basicConfig(filename=log_file, level=logging.INFO,
                            format="%(asctime)s %(message)s")
        # redirect stdout/stderr to log
        sys.stdout = open(log_file, "a")
        sys.stderr = open(log_file, "a")

    server = http.server.HTTPServer((UI_BIND, UI_PORT), PZHTTPHandler)
    print(f"PhaseZero UI: http://{UI_BIND}:{UI_PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nserver stopped", flush=True)
        server.server_close()


if __name__ == "__main__":
    main()
