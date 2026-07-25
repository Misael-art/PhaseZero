"""Harness sandboxed para os testes de higiene de host.

Regras que este harness existe para garantir:

* Nenhum teste toca o ``$HOME`` real do runner. ``HOME`` e todos os
  ``XDG_*_HOME`` são redirecionados para um ``tmp_path``.
* Nenhum teste executa ``sudo``. ``PZ_USE_SUDO=0`` e o ``PATH`` recebe um
  ``sudo`` stub que falha ruidosamente se alguém tentar.
* Nenhum teste chega perto de ``~/Emulation``: o fake-home cria a pasta com um
  arquivo sentinela, e ``assert_emulation_intact`` verifica que continua lá.
* Asserção por diff: ``snapshot()`` antes/depois, ``delta_outside_state()``
  devolve só o que mudou FORA de ``$PZ_STATE`` — que é o conjunto que precisa
  estar documentado em ``docs/host-surface.md``.
"""
from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

SENTINEL_NAME = "DO-NOT-TOUCH.txt"
SENTINEL_BODY = "dados do usuário: ROMs e saves vivem aqui\n"


@dataclass
class HostSandbox:
    """Fake-home isolado com snapshot/diff de filesystem."""

    home: Path
    env: dict[str, str] = field(default_factory=dict)
    calls_log: Path | None = None

    def stub_calls(self) -> list[str]:
        """Chamadas capturadas pelos stubs (systemctl, flatpak, pacman, ...)."""
        if self.calls_log is None or not self.calls_log.exists():
            return []
        return self.calls_log.read_text(encoding="utf-8").splitlines()

    # --- paths --------------------------------------------------------
    @property
    def state(self) -> Path:
        return self.home / ".local/state/phasezero"

    @property
    def backups(self) -> Path:
        return self.state / "backups"

    @property
    def ledger(self) -> Path:
        return self.state / "ledger/ledger.jsonl"

    @property
    def emulation(self) -> Path:
        return self.home / "Emulation"

    # --- execução -----------------------------------------------------
    def run(self, *args: str, check: bool = False, cwd: Path | None = None) -> subprocess.CompletedProcess:
        """Executa um comando dentro do sandbox, nunca no host real."""
        return subprocess.run(
            list(args),
            cwd=str(cwd or ROOT),
            env=self.env,
            capture_output=True,
            text=True,
            check=check,
        )

    def pz(self, *args: str, check: bool = False) -> subprocess.CompletedProcess:
        return self.run("bash", str(ROOT / "linux/pz"), *args, check=check)

    def bash_lib(self, script: str, check: bool = True) -> subprocess.CompletedProcess:
        """Roda um trecho bash com linux/lib/common.sh já carregado."""
        prelude = f'source "{ROOT}/linux/lib/common.sh"\n'
        return self.run("bash", "-c", prelude + script, check=check)

    # --- snapshot / diff ----------------------------------------------
    def snapshot(self) -> set[str]:
        """Todos os paths sob o fake-home, relativos ao fake-home."""
        out: set[str] = set()
        for path in self.home.rglob("*"):
            out.add(str(path.relative_to(self.home)))
        return out

    def delta(self, before: set[str]) -> set[str]:
        return self.snapshot() - before

    def delta_outside_state(self, before: set[str]) -> set[str]:
        """Delta que NÃO está sob $PZ_STATE — o que precisa ser documentado."""
        state_rel = ".local/state/phasezero"
        return {
            item
            for item in self.delta(before)
            if not item.startswith(state_rel) and item not in _STATE_ANCESTORS
        }

    # --- invariantes ---------------------------------------------------
    def assert_emulation_intact(self) -> None:
        sentinel = self.emulation / SENTINEL_NAME
        assert sentinel.is_file(), f"~/Emulation foi removido: {sentinel}"
        assert sentinel.read_text(encoding="utf-8") == SENTINEL_BODY, (
            "conteúdo de ~/Emulation foi alterado"
        )

    def legacy_baks_outside_store(self) -> list[Path]:
        """Arquivos *.bak.* remanescentes fora do store central."""
        return [
            path
            for path in self.home.rglob("*.bak.*")
            if self.backups not in path.parents
        ]


# diretórios-pai de $PZ_STATE: criá-los não é "sujar o host", é criar o próprio
# namespace. Ficam fora da asserção de delta.
_STATE_ANCESTORS = {".local", ".local/state"}


@pytest.fixture
def host_sandbox(tmp_path: Path) -> HostSandbox:
    home = tmp_path / "fake-home"
    for rel in (
        ".config",
        ".local/bin",
        ".local/share",
        ".local/state",
        ".cache",
    ):
        (home / rel).mkdir(parents=True, exist_ok=True)

    # dados do usuário que NUNCA podem ser tocados
    emulation = home / "Emulation/roms/snes"
    emulation.mkdir(parents=True, exist_ok=True)
    (home / "Emulation" / SENTINEL_NAME).write_text(SENTINEL_BODY, encoding="utf-8")

    stub_bin = tmp_path / "stub-bin"
    stub_bin.mkdir(parents=True, exist_ok=True)
    calls_log = tmp_path / "stub-calls.log"

    # stub de sudo: qualquer tentativa de escalar privilégio falha o teste
    sudo_stub = stub_bin / "sudo"
    sudo_stub.write_text(
        "#!/usr/bin/env bash\n"
        'echo "TESTE CHAMOU SUDO REAL: $*" >&2\n'
        "exit 99\n",
        encoding="utf-8",
    )
    sudo_stub.chmod(0o755)

    # systemctl/flatpak/pacman falam com daemons e com o gerenciador de
    # pacotes REAIS do runner — HOME redirecionado não isola nada disso.
    # Stubs registram a chamada e saem com sucesso.
    for name in ("systemctl", "flatpak", "pacman", "yay", "phasezero-admin", "bigsudo"):
        stub = stub_bin / name
        stub.write_text(
            "#!/usr/bin/env bash\n"
            f'printf "%s %s\\n" "{name}" "$*" >> "{calls_log}"\n'
            "exit 0\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)

    env = dict(os.environ)
    env.update(
        {
            "HOME": str(home),
            "XDG_STATE_HOME": str(home / ".local/state"),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_DATA_HOME": str(home / ".local/share"),
            "XDG_CACHE_HOME": str(home / ".cache"),
            "PZ_USE_SUDO": "0",
            "PZ_OPERATION_ID": "test-operation",
            "PATH": f"{stub_bin}{os.pathsep}{env.get('PATH', '')}",
        }
    )
    # não vaza estado do host real para dentro do sandbox
    for leak in ("PZ_STATE", "PZ_MANIFEST", "PZ_BACKUP_ROOT", "PZ_LEDGER_FILE", "PZ_LEDGER_DIR"):
        env.pop(leak, None)

    return HostSandbox(home=home, env=env, calls_log=calls_log)
