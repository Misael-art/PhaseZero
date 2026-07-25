"""`pz help` e afins não podem tocar o host (correção 5).

Antes desta série, `source linux/lib/common.sh` criava `$PZ_STATE` e
`$PZ_STATE/operations` e escrevia `pz.log` — ou seja, `pz help` já sujava o
host do usuário. O estado agora é criado sob demanda.
"""
from __future__ import annotations

from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("args", [("help",), ("--help",), ("-h",), ()])
def test_help_produces_no_filesystem_delta(host_sandbox, args):
    before = host_sandbox.snapshot()
    result = host_sandbox.pz(*args)
    assert result.returncode == 0, result.stderr
    assert "PhaseZero Linux" in result.stdout
    assert host_sandbox.delta(before) == set()


def test_sourcing_common_sh_creates_no_state(host_sandbox):
    before = host_sandbox.snapshot()
    result = host_sandbox.run(
        "bash", "-c", f'source "{ROOT}/linux/lib/common.sh"'
    )
    assert result.returncode == 0, result.stderr
    assert host_sandbox.delta(before) == set()
    assert not host_sandbox.state.exists()


def test_sourcing_common_sh_still_exports_the_state_paths(host_sandbox):
    """Lazy init não pode quebrar quem lê $PZ_STATE/$PZ_LOG no source."""
    result = host_sandbox.bash_lib('printf "%s\\n%s\\n%s\\n" "$PZ_STATE" "$PZ_LOG" "$PZ_BACKUP_ROOT"')
    lines = result.stdout.strip().splitlines()
    assert lines[0] == str(host_sandbox.state)
    assert lines[1] == str(host_sandbox.state / "pz.log")
    assert lines[2] == str(host_sandbox.backups)


def test_first_log_write_creates_the_state_namespace(host_sandbox):
    assert not host_sandbox.state.exists()
    host_sandbox.bash_lib('pz_info "primeira mutação"')
    assert host_sandbox.state.is_dir()
    assert (host_sandbox.state / "pz.log").is_file()


def test_state_namespace_is_private(host_sandbox):
    host_sandbox.bash_lib('pz_info "cria estado"')
    assert oct(host_sandbox.state.stat().st_mode)[-3:] == "700"
    assert oct((host_sandbox.state / "pz.log").stat().st_mode)[-3:] == "600"


def test_host_status_stays_inside_the_namespace(host_sandbox):
    """Comando informativo pode criar estado, mas só dentro de $PZ_STATE."""
    before = host_sandbox.snapshot()
    result = host_sandbox.pz("host", "status")
    assert result.returncode == 0, result.stderr
    assert host_sandbox.delta_outside_state(before) == set()


def test_version_does_not_touch_the_host(host_sandbox):
    before = host_sandbox.snapshot()
    result = host_sandbox.pz("version")
    assert result.returncode == 0, result.stderr
    assert host_sandbox.delta(before) == set()


def test_no_test_ever_reaches_the_real_sudo(host_sandbox):
    """O stub de sudo do harness precisa estar realmente na frente do PATH."""
    result = host_sandbox.run("bash", "-c", "sudo true")
    assert result.returncode == 99
    assert "TESTE CHAMOU SUDO REAL" in result.stderr
