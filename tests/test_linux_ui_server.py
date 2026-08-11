from __future__ import annotations

import http.client
import json
import os
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def ui_server(tmp_path_factory):
    temp = tmp_path_factory.mktemp("ui-server")
    state = temp / "state"
    home = temp / "home"
    home.mkdir()
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = os.environ.copy()
    env.update({"XDG_STATE_HOME": str(state), "HOME": str(home)})
    process = subprocess.Popen(
        [sys.executable, str(ROOT / "linux" / "ui" / "server.py"), "--port", str(port)],
        cwd=ROOT,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    token_file = state / "phasezero" / "ui-token"
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            pytest.fail(f"UI server exited early: {process.stderr.read()}")
        if token_file.exists():
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                pass
        time.sleep(0.05)
    else:
        process.kill()
        pytest.fail("UI server did not become ready")
    yield {
        "port": port,
        "token": token_file.read_text(encoding="ascii").strip(),
        "token_file": token_file,
        "home": home,
    }
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def request(server, method, path, *, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", server["port"], timeout=40)
    connection.request(method, path, body=body, headers=headers or {})
    response = connection.getresponse()
    payload = response.read()
    response_headers = {key.casefold(): value for key, value in response.getheaders()}
    connection.close()
    return response.status, response_headers, payload


def auth_headers(server):
    return {"Authorization": f"Bearer {server['token']}"}


def test_root_uses_private_cookie_and_token_file(ui_server):
    status_code, headers, payload = request(ui_server, "GET", "/")
    assert status_code == 401
    assert "set-cookie" not in headers
    assert ui_server["token"].encode() not in payload

    status_code, headers, payload = request(
        ui_server, "GET", f"/?token={ui_server['token']}",
    )
    assert status_code == 303
    assert headers["location"] == "/"
    assert "httponly" in headers["set-cookie"].casefold()
    assert "samesite=strict" in headers["set-cookie"].casefold()
    cookie = headers["set-cookie"].split(";", 1)[0]
    status_code, headers, payload = request(
        ui_server, "GET", "/", headers={"Cookie": cookie},
    )
    assert status_code == 200
    assert ui_server["token"].encode() not in payload
    assert "frame-ancestors 'none'" in headers["content-security-policy"]
    mode = stat.S_IMODE(ui_server["token_file"].stat().st_mode)
    assert mode == 0o600


def test_actions_require_auth_and_hide_internal_argv(ui_server):
    status_code, _, _ = request(ui_server, "GET", "/api/actions")
    assert status_code == 401
    status_code, _, payload = request(
        ui_server, "GET", "/api/actions", headers=auth_headers(ui_server),
    )
    assert status_code == 200
    actions = json.loads(payload)["actions"]
    assert actions
    assert all("argv" not in action and "command" not in action for action in actions)
    assert any(action["name"] == "emulation.rom-optimize" and action["inputKind"] == "path" for action in actions)


def test_static_traversal_and_malformed_requests_are_blocked(ui_server):
    status_code, _, _ = request(
        ui_server, "GET", "/static/%2e%2e/%2e%2e/%2e%2e/version.json",
    )
    assert status_code == 404
    headers = {**auth_headers(ui_server), "Content-Type": "application/json"}
    status_code, _, payload = request(
        ui_server, "POST", "/api/action", body=b"{broken", headers=headers,
    )
    assert status_code == 400
    assert json.loads(payload)["status"] == "blocked"
    cross_site = {**headers, "Origin": "https://attacker.invalid"}
    status_code, _, _ = request(
        ui_server,
        "POST",
        "/api/action",
        body=json.dumps({"action": "system.version", "confirmed": True}),
        headers=cross_site,
    )
    assert status_code == 403
    bad_host = {**headers, "Host": "attacker.invalid"}
    status_code, _, _ = request(
        ui_server,
        "POST",
        "/api/action",
        body=json.dumps({"action": "system.version", "confirmed": True}),
        headers=bad_host,
    )
    assert status_code == 421


def test_mutation_without_confirmation_runs_only_safe_preview(ui_server):
    headers = {**auth_headers(ui_server), "Content-Type": "application/json"}
    status_code, _, payload = request(
        ui_server,
        "POST",
        "/api/action",
        body=json.dumps({"action": "profile.safe-base", "confirmed": False}),
        headers=headers,
    )
    assert status_code == 200
    result = json.loads(payload)
    assert result["status"] == "ok"
    assert "confirmation required" in result["blockers"]
    assert not (ui_server["home"] / ".config").exists()


def test_input_action_is_never_run_with_missing_path(ui_server):
    headers = {**auth_headers(ui_server), "Content-Type": "application/json"}
    status_code, _, payload = request(
        ui_server,
        "POST",
        "/api/action",
        body=json.dumps({"action": "windows.plan", "confirmed": True}),
        headers=headers,
    )
    assert status_code == 400
    assert "input path required" in json.loads(payload)["blockers"]


def test_server_refuses_symlink_token_path(tmp_path):
    state = tmp_path / "state" / "phasezero"
    state.mkdir(parents=True)
    sentinel = tmp_path / "sentinel"
    sentinel.write_text("do-not-touch\n", encoding="utf-8")
    (state / "ui-token").symlink_to(sentinel)
    env = os.environ.copy()
    env.update({"XDG_STATE_HOME": str(tmp_path / "state"), "HOME": str(tmp_path / "home")})
    result = subprocess.run(
        [sys.executable, str(ROOT / "linux" / "ui" / "server.py"), "--port", "18080"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode != 0
    assert "unsafe UI token path" in result.stderr
    assert sentinel.read_text(encoding="utf-8") == "do-not-touch\n"


def test_overview_status_contains_every_module(ui_server):
    status_code, _, payload = request(
        ui_server, "GET", "/api/status", headers=auth_headers(ui_server),
    )
    assert status_code == 200
    data = json.loads(payload)
    assert tuple(data) == ("system", "steamdeck", "emulation", "server", "ai", "themes")
    assert all(value["module"] == key for key, value in data.items())


def test_themes_module_status_returns_envelope(ui_server):
    status_code, _, payload = request(
        ui_server, "GET", "/api/status/themes", headers=auth_headers(ui_server),
    )
    assert status_code == 200
    data = json.loads(payload)
    assert data["module"] == "themes"
    assert data["status"] in ("ok", "warn")
    names = [check["name"] for check in data["checks"]]
    assert "themes.plasma" in names
    assert "themes.theme.phasezero" in names
    assert "themes.access.text-size" in names


def test_themes_actions_present_in_allowlist(ui_server):
    status_code, _, payload = request(
        ui_server, "GET", "/api/actions", headers=auth_headers(ui_server),
    )
    assert status_code == 200
    names = {entry["name"] for entry in json.loads(payload)["actions"]}
    for required in (
        "themes.status", "themes.undo", "themes.history",
        "themes.feature.access.text-size.on", "themes.profile.essencial",
        "themes.wallpaper.pz.geo-dark",
    ):
        assert required in names, required


def test_dashboard_html_contains_themes_section(ui_server):
    status_code, _, payload = request(
        ui_server, "GET", "/", headers=auth_headers(ui_server),
    )
    assert status_code == 200
    html = payload.decode("utf-8", errors="replace")
    assert 'id="themes"' in html
    assert 'href="#themes"' in html
