from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _fake_tools(tmp_path: Path, *, mode: str, curl_mode: str = "ok") -> tuple[dict[str, str], Path]:
    bindir = tmp_path / "bin"
    bindir.mkdir()
    docker = bindir / "docker"
    docker.write_text(
        "#!/bin/sh\n"
        "case \"$1\" in\n"
        "  ps)\n"
        "    case \"$FAKE_WEBUI_MODE:$2\" in\n"
        "      backend:*) exit 3 ;;\n"
        "      absent:*) exit 0 ;;\n"
        "      stopped:-a|healthy:-a) printf 'open-webui\\n' ;;\n"
        "      healthy:*) printf 'open-webui\\n' ;;\n"
        "    esac ;;\n"
        "  port) printf '127.0.0.1:3000\\n' ;;\n"
        "  *) exit 2 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    docker.chmod(0o755)
    curl = bindir / "curl"
    curl.write_text(
        "#!/bin/sh\n"
        "case \"$FAKE_WEBUI_CURL_MODE\" in\n"
        "  failed) printf '503'; exit 0 ;;\n"
        "  timeout) exit 28 ;;\n"
        "  *) printf '200' ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    curl.chmod(0o755)
    opened = tmp_path / "opened-url"
    opener = bindir / "xdg-open"
    opener.write_text(
        "#!/bin/sh\nprintf '%s' \"$1\" > \"$FAKE_WEBUI_OPENED\"\n",
        encoding="utf-8",
    )
    opener.chmod(0o755)
    env = os.environ.copy()
    env.update({
        "PATH": f"{bindir}:/usr/bin:/bin",
        "FAKE_WEBUI_MODE": mode,
        "FAKE_WEBUI_CURL_MODE": curl_mode,
        "FAKE_WEBUI_OPENED": str(opened),
        "HOME": str(tmp_path / "home"),
    })
    return env, opened


def _run(
    tmp_path: Path, mode: str, command: str, *, curl_mode: str = "ok",
) -> tuple[subprocess.CompletedProcess[str], Path]:
    env, opened = _fake_tools(tmp_path, mode=mode, curl_mode=curl_mode)
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "linux/pz"), "ai", "webui", command],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    return result, opened


def test_status_reports_absent_container_without_claiming_health(tmp_path):
    result, _opened = _run(tmp_path, "absent", "status")

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["hasStatus"] is True
    assert payload["installationState"] == "absent"
    assert payload["configurationState"] == "needed"
    assert payload["health"] == "unknown"
    assert payload["origin"] == "unknown"


def test_unavailable_docker_backend_stays_unknown(tmp_path):
    result, _opened = _run(tmp_path, "backend", "status")

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["hasStatus"] is False
    assert payload["installationState"] == "unknown"
    assert payload["configurationState"] == "unknown"
    assert payload["health"] == "unknown"
    assert payload["error"] == "backend-unavailable"


def test_status_reports_running_and_http_ready_container(tmp_path):
    result, _opened = _run(tmp_path, "healthy", "status")

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["installationState"] == "present"
    assert payload["configurationState"] == "ready"
    assert payload["health"] == "online"
    assert payload["dashboardUrl"] == "http://127.0.0.1:3000/"
    assert payload["origin"] == "unknown"


def test_http_failure_and_timeout_never_claim_online(tmp_path):
    failed_dir = tmp_path / "failed"
    failed_dir.mkdir()
    result, _opened = _run(failed_dir, "healthy", "status", curl_mode="failed")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["health"] == "failed"

    timeout_dir = tmp_path / "timeout"
    timeout_dir.mkdir()
    result, _opened = _run(timeout_dir, "healthy", "status", curl_mode="timeout")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["health"] == "unknown"

    for name, curl_mode in (("failed-open", "failed"), ("timeout-open", "timeout")):
        case_dir = tmp_path / name
        case_dir.mkdir()
        result, opened = _run(case_dir, "healthy", "open", curl_mode=curl_mode)
        assert result.returncode != 0
        assert not opened.exists()


def test_open_refuses_stopped_container_and_opens_only_observed_local_url(tmp_path):
    result, opened = _run(tmp_path, "stopped", "open")
    assert result.returncode != 0
    assert not opened.exists()

    healthy_dir = tmp_path / "healthy"
    healthy_dir.mkdir()
    result, opened = _run(healthy_dir, "healthy", "open")
    assert result.returncode == 0, result.stderr
    for _ in range(20):
        if opened.exists():
            break
        time.sleep(0.01)
    assert opened.read_text(encoding="utf-8") == "http://127.0.0.1:3000/"
