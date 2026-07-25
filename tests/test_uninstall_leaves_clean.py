"""Leave-no-trace: o uninstall remove a pegada do PhaseZero e só ela.

Escopo PR1: o contrato de segurança do `linux/uninstall.sh` existente
(dry-run default, token de confirmação, `~/Emulation` intocável) e a
consistência entre o que o ledger registra e o que o uninstall remove.

Tudo roda no fake-home do fixture ``host_sandbox``: `systemctl`, `flatpak` e
`pacman` são stubs, `sudo` falha ruidosamente e `~/Emulation` carrega um
sentinela verificado ao final de cada teste.
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "PHASEZERO-WIPE"


def seed_phasezero_footprint(sandbox) -> dict[str, Path]:
    """Cria uma pegada representativa via os próprios chokepoints do produto."""
    paths = {
        "wrapper": sandbox.home / ".local/bin/phasezero-demo",
        "unit": sandbox.home / ".config/systemd/user/phasezero-demo.service",
        "desktop": sandbox.home / ".local/share/applications/phasezero-demo.desktop",
        "config": sandbox.home / ".config/phasezero/settings.json",
    }
    for path in paths.values():
        path.parent.mkdir(parents=True, exist_ok=True)
    sandbox.bash_lib(
        "\n".join(
            [
                'printf \'#!/bin/sh\\necho demo\\n\' | pz_write_managed_file "$HOME/.local/bin/phasezero-demo" user',
                'printf \'[Unit]\\nDescription=demo\\n\' | pz_write_managed_file "$HOME/.config/systemd/user/phasezero-demo.service" user',
                'printf \'[Desktop Entry]\\nName=demo\\n\' | pz_write_managed_file "$HOME/.local/share/applications/phasezero-demo.desktop" user',
                'printf \'{"_managedBy":"phasezero"}\\n\' | pz_write_managed_file "$HOME/.config/phasezero/settings.json" user',
            ]
        )
    )
    return paths


def uninstall(sandbox, *args: str):
    return sandbox.run("bash", str(ROOT / "linux/uninstall.sh"), *args)


# --- contrato de segurança ------------------------------------------------


def test_uninstall_defaults_to_dry_run(host_sandbox):
    paths = seed_phasezero_footprint(host_sandbox)
    before = host_sandbox.snapshot()

    result = uninstall(host_sandbox)
    assert result.returncode == 0, result.stderr
    assert "DRY-RUN" in result.stdout

    assert host_sandbox.delta_outside_state(before) == set()
    for path in paths.values():
        assert path.exists(), f"dry-run removeu {path}"
    host_sandbox.assert_emulation_intact()


def test_apply_without_token_is_refused(host_sandbox):
    paths = seed_phasezero_footprint(host_sandbox)

    result = uninstall(host_sandbox, "--apply")
    assert result.returncode == 2
    assert TOKEN in result.stderr + result.stdout

    for path in paths.values():
        assert path.exists(), f"--apply sem token removeu {path}"
    host_sandbox.assert_emulation_intact()


def test_apply_with_wrong_token_is_refused(host_sandbox):
    seed_phasezero_footprint(host_sandbox)
    result = uninstall(host_sandbox, "--apply", "--confirm=SIM-PODE-APAGAR")
    assert result.returncode == 2
    host_sandbox.assert_emulation_intact()


# --- remoção efetiva ------------------------------------------------------


def test_apply_removes_the_phasezero_footprint(host_sandbox):
    paths = seed_phasezero_footprint(host_sandbox)

    result = uninstall(host_sandbox, "--apply", f"--confirm={TOKEN}")
    assert result.returncode == 0, result.stderr

    for name, path in paths.items():
        assert not path.exists(), f"{name} sobreviveu ao wipe: {path}"
    assert not host_sandbox.state.exists(), "$PZ_STATE sobreviveu ao wipe"


def test_apply_never_touches_emulation(host_sandbox):
    seed_phasezero_footprint(host_sandbox)
    rom = host_sandbox.emulation / "roms/snes/jogo.sfc"
    rom.write_text("ROM do usuário\n", encoding="utf-8")

    uninstall(host_sandbox, "--apply", f"--confirm={TOKEN}", "--all")

    assert rom.is_file(), "wipe apagou uma ROM"
    assert rom.read_text(encoding="utf-8") == "ROM do usuário\n"
    host_sandbox.assert_emulation_intact()


def test_apply_never_touches_unrelated_user_data(host_sandbox):
    seed_phasezero_footprint(host_sandbox)
    foreign = host_sandbox.home / ".config/outro-app/config.json"
    foreign.parent.mkdir(parents=True, exist_ok=True)
    foreign.write_text('{"nao":"phasezero"}\n', encoding="utf-8")
    documents = host_sandbox.home / "Documentos/tese.odt"
    documents.parent.mkdir(parents=True, exist_ok=True)
    documents.write_text("trabalho do usuário\n", encoding="utf-8")

    uninstall(host_sandbox, "--apply", f"--confirm={TOKEN}", "--all")

    assert foreign.is_file(), "wipe removeu config de outro app"
    assert documents.is_file(), "wipe removeu documento do usuário"


def test_apply_never_escalates_privilege(host_sandbox):
    """Itens root são impressos, nunca executados."""
    seed_phasezero_footprint(host_sandbox)
    result = uninstall(host_sandbox, "--apply", f"--confirm={TOKEN}")

    assert "TESTE CHAMOU SUDO REAL" not in result.stderr
    assert "ITENS ROOT" in result.stdout
    assert "sudo linux/pz steamdeck boot remove" in result.stdout


# --- ledger ↔ uninstall ---------------------------------------------------


def test_every_ledger_created_path_is_removed_by_the_wipe(host_sandbox):
    """O critério de 'leave no trace': o ledger é a lista do que sai."""
    seed_phasezero_footprint(host_sandbox)

    entries = [
        json.loads(line)
        for line in host_sandbox.ledger.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    created = sorted({path for entry in entries for path in entry["created"]})
    assert created, "ledger não registrou nenhuma criação"

    uninstall(host_sandbox, "--apply", f"--confirm={TOKEN}", "--all")

    survivors = [path for path in created if Path(path).exists()]
    assert survivors == [], (
        "paths registrados no ledger sobreviveram ao uninstall:\n"
        + "\n".join(survivors)
    )
    host_sandbox.assert_emulation_intact()


def test_backups_are_wiped_with_the_state_dir(host_sandbox):
    """Backups centralizados vivem em $PZ_STATE, logo saem junto."""
    target = host_sandbox.home / ".config/phasezero/settings.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("v1\n", encoding="utf-8")
    host_sandbox.bash_lib(
        'printf \'v2\\n\' | pz_write_managed_file "$HOME/.config/phasezero/settings.json" user'
    )
    assert list(host_sandbox.backups.rglob("*.bak.*"))

    uninstall(host_sandbox, "--apply", f"--confirm={TOKEN}")

    assert not host_sandbox.backups.exists()
    assert host_sandbox.legacy_baks_outside_store() == []


def test_dry_run_reports_what_apply_would_remove(host_sandbox):
    paths = seed_phasezero_footprint(host_sandbox)
    result = uninstall(host_sandbox)

    for path in paths.values():
        assert str(path) in result.stdout, f"dry-run não listou {path}"
