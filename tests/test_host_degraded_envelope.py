"""Fallback degradado + envelope result (correção 4) e wipe unificado.

Contrato testado aqui:

* Admin bridge ausente **degrada**, não crasha.
* Todo apply/preview termina com um envelope result legível — inclusive na
  recusa, inclusive na falha, inclusive em modo degradado.
* `pz host wipe` é dirigido pelo ledger e nunca toca ``~/Emulation``.

O fixture ``host_sandbox`` já isola HOME/XDG, stuba `systemctl`/`flatpak`/
`pacman` e faz `sudo` falhar ruidosamente.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "PHASEZERO-WIPE"

RESULT_FIELDS = {"ok", "code", "summary", "howToFix", "ledgerRef", "logPath"}
VALID_CODES = {"ok", "degraded", "blocked", "failed", "refused"}


def envelope(result) -> dict:
    """Extrai o envelope JSON do stdout, falhando com contexto se não houver."""
    assert result.stdout.strip(), (
        f"comando terminou sem envelope result (rc={result.returncode})\n"
        f"stderr: {result.stderr}"
    )
    payload = json.loads(result.stdout)
    assert RESULT_FIELDS <= set(payload), (
        f"envelope incompleto, faltam {RESULT_FIELDS - set(payload)}: {payload}"
    )
    assert payload["code"] in VALID_CODES, f"code fora do vocabulário: {payload['code']}"
    assert isinstance(payload["howToFix"], list)
    return payload


# O fixture `host_sandbox` já nasce SEM admin bridge (PATH saneado pelo
# conftest), então "degradado" é o estado default aqui. `with_admin_bridge()`
# devolve o caminho privilegiado quando o teste precisa dele.


# --- envelope result ------------------------------------------------------


def test_wipe_preview_emits_a_result_envelope(host_sandbox):
    seed_footprint(host_sandbox)
    payload = envelope(host_sandbox.pz("host", "wipe"))
    assert payload["ok"] is True
    assert payload["code"] == "ok"
    assert payload["dryRun"] is True
    assert TOKEN in " ".join(payload["howToFix"])


def test_refusal_still_emits_a_result_envelope(host_sandbox):
    """Recusa é resposta, não silêncio."""
    seed_footprint(host_sandbox)
    result = host_sandbox.pz("host", "wipe", "--apply")
    assert result.returncode == 2
    payload = envelope(result)
    assert payload["ok"] is False
    assert payload["code"] == "refused"
    assert payload["howToFix"], "recusa sem instrução acionável"


def test_wrong_token_is_refused_with_an_envelope(host_sandbox):
    seed_footprint(host_sandbox)
    result = host_sandbox.pz("host", "wipe", "--apply", "--confirm=SIM")
    payload = envelope(result)
    assert payload["code"] == "refused"


def test_envelope_carries_ledger_ref_and_log_path(host_sandbox):
    seed_footprint(host_sandbox)
    payload = envelope(host_sandbox.pz("host", "wipe"))
    assert str(host_sandbox.ledger) in payload["ledgerRef"]
    assert payload["logPath"] == str(host_sandbox.state / "pz.log")


def test_prune_emits_a_result_envelope(host_sandbox):
    seed_footprint(host_sandbox)
    payload = envelope(host_sandbox.pz("host", "prune", "--keep", "2"))
    assert payload["ok"] is True
    assert payload["code"] == "ok"


def test_result_guard_emits_an_envelope_on_unexpected_failure(host_sandbox):
    """Mesmo uma saída não tratada produz result legível."""
    script = (
        f'source "{ROOT}/linux/lib/common.sh"\n'
        f'source "{ROOT}/linux/lib/json-envelope.sh"\n'
        "pz_result_guard_install teste-explosao\n"
        "false\n"
    )
    result = host_sandbox.run("bash", "-c", script)
    assert result.returncode != 0
    payload = envelope(result)
    assert payload["ok"] is False
    assert payload["code"] == "failed"
    assert payload["module"] == "teste-explosao"


@pytest.mark.parametrize("code", sorted(VALID_CODES))
def test_every_result_code_serializes(host_sandbox, code):
    script = (
        f'source "{ROOT}/linux/lib/common.sh"\n'
        f'source "{ROOT}/linux/lib/json-envelope.sh"\n'
        f'pz_result_envelope {code} "resumo de teste" "passo um" "passo dois"\n'
    )
    payload = envelope(host_sandbox.run("bash", "-c", script))
    assert payload["code"] == code
    assert payload["ok"] is (code in {"ok", "degraded"})
    assert payload["howToFix"] == ["passo um", "passo dois"]


def test_unknown_code_falls_back_to_failed(host_sandbox):
    script = (
        f'source "{ROOT}/linux/lib/common.sh"\n'
        f'source "{ROOT}/linux/lib/json-envelope.sh"\n'
        'pz_result_envelope inventado "resumo"\n'
    )
    assert envelope(host_sandbox.run("bash", "-c", script))["code"] == "failed"


# --- admin bridge ausente = degrade, não crash ----------------------------


def test_admin_mode_reports_degraded_without_a_bridge(host_sandbox):
    result = host_sandbox.run(
        "bash", "-c", f'source "{ROOT}/linux/lib/common.sh"; pz_admin_mode'
    )
    assert result.stdout.strip() == "degraded"


def test_admin_mode_reports_ready_with_a_bridge(host_sandbox):
    """Contraprova: o mesmo sandbox vira `ready` só por ganhar a bridge."""
    sandbox = host_sandbox.with_admin_bridge()
    result = sandbox.run(
        "bash", "-c", f'source "{ROOT}/linux/lib/common.sh"; pz_admin_mode'
    )
    assert result.stdout.strip() == "ready"


def test_admin_run_degrades_instead_of_crashing(host_sandbox):
    """Sem bridge, pz_admin_run devolve 77 e avisa — não mata o processo.

    O alvo fica DENTRO do sandbox de propósito. Uma versão anterior deste
    teste apontava para `/etc/...`; num runner com a bridge real no PATH ela
    escalava privilégio de verdade e criava o arquivo no host. Nenhum teste
    deve nomear um path de sistema, nem para afirmar que ele não existe.
    """
    target = host_sandbox.home / "fake-etc/phasezero-teste"
    script = (
        f'source "{ROOT}/linux/lib/common.sh"\n'
        f'pz_admin_run install -D -m 0644 /dev/null "{target}" || rc=$?\n'
        'echo "rc=${rc:-0}"\n'
        'pz_degraded && echo "degraded=yes" || echo "degraded=no"\n'
        'echo "sobrevivi"\n'
    )
    result = host_sandbox.run("bash", "-c", script)
    assert "rc=77" in result.stdout
    assert "degraded=yes" in result.stdout
    assert "sobrevivi" in result.stdout, "o processo morreu em vez de degradar"
    assert not target.exists(), "mutação root aconteceu apesar da degradação"


def test_no_test_can_reach_the_real_admin_bridge(host_sandbox):
    """Guarda do harness: a bridge real do runner não pode vazar pro sandbox."""
    for name in ("phasezero-admin", "bigsudo"):
        found = host_sandbox.run("bash", "-c", f"command -v {name} || true")
        assert found.stdout.strip() == "", (
            f"{name} real acessível dentro do sandbox: {found.stdout.strip()}"
        )


def test_degraded_mode_still_produces_a_result_envelope(host_sandbox):
    sandbox = host_sandbox
    script = (
        f'source "{ROOT}/linux/lib/common.sh"\n'
        f'source "{ROOT}/linux/lib/json-envelope.sh"\n'
        "pz_result_guard_install teste\n"
        'pz_admin_run systemctl-inexistente enable foo || true\n'
        'if pz_degraded; then\n'
        '  pz_result_degraded_admin "mutação de sistema não aplicada"\n'
        "else\n"
        '  pz_result_envelope ok "aplicado"\n'
        "fi\n"
        "pz_result_emitted\n"
    )
    payload = envelope(sandbox.run("bash", "-c", script))
    assert payload["code"] == "degraded"
    assert payload["ok"] is True, "degradado não é falha"
    assert payload["howToFix"], "degradado sem instrução acionável"
    assert any("ai setup admin" in step for step in payload["howToFix"]), (
        f"instruções quebradas em palavras soltas? howToFix={payload['howToFix']}"
    )


def test_degraded_admin_helper_keeps_instructions_whole(host_sandbox):
    """Regressão: `$(pz_admin_howtofix)` sem aspas vira palavras soltas."""
    script = (
        f'source "{ROOT}/linux/lib/common.sh"\n'
        f'source "{ROOT}/linux/lib/json-envelope.sh"\n'
        'pz_result_degraded_admin "resumo" "instrução extra do módulo"\n'
    )
    payload = envelope(host_sandbox.run("bash", "-c", script))
    assert payload["howToFix"][0] == "Instale a admin bridge: linux/pz ai setup admin"
    assert payload["howToFix"][-1] == "instrução extra do módulo"
    assert all(" " in step for step in payload["howToFix"]), (
        "instruções foram quebradas em palavras"
    )


def test_admin_howtofix_names_the_exact_command(host_sandbox):
    result = host_sandbox.run(
        "bash", "-c", f'source "{ROOT}/linux/lib/common.sh"; pz_admin_howtofix'
    )
    assert "linux/pz ai setup admin" in result.stdout


def test_host_status_reports_the_admin_mode(host_sandbox):
    payload = json.loads(host_sandbox.pz("host", "status").stdout)
    assert payload["adminMode"] == "degraded"
    assert payload["code"] == "degraded"
    assert payload["howToFix"], "status degradado sem instrução acionável"

    ready = json.loads(host_sandbox.with_admin_bridge().pz("host", "status").stdout)
    assert ready["adminMode"] == "ready"
    assert ready["code"] == "ok"


# --- wipe dirigido pelo ledger --------------------------------------------


def seed_footprint(sandbox) -> list[Path]:
    paths = [
        sandbox.home / ".local/bin/phasezero-demo",
        sandbox.home / ".local/share/applications/phasezero-demo.desktop",
        sandbox.home / ".config/phasezero/settings.json",
    ]
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
    sandbox.bash_lib(
        "\n".join(
            [
                'printf \'wrapper\\n\' | pz_write_managed_file "$HOME/.local/bin/phasezero-demo" user',
                'printf \'[Desktop Entry]\\n\' | pz_write_managed_file "$HOME/.local/share/applications/phasezero-demo.desktop" user',
                'printf \'{"_managedBy":"phasezero"}\\n\' | pz_write_managed_file "$HOME/.config/phasezero/settings.json" user',
            ]
        )
    )
    return paths


def test_wipe_preview_changes_nothing(host_sandbox):
    paths = seed_footprint(host_sandbox)
    before = host_sandbox.snapshot()

    host_sandbox.pz("host", "wipe")

    assert host_sandbox.delta_outside_state(before) == set()
    for path in paths:
        assert path.exists()
    host_sandbox.assert_emulation_intact()


def test_wipe_apply_removes_every_ledger_path(host_sandbox):
    paths = seed_footprint(host_sandbox)
    payload = envelope(host_sandbox.pz("host", "wipe", "--apply", f"--confirm={TOKEN}"))

    assert payload["ok"] is True
    for path in paths:
        assert not path.exists(), f"sobreviveu ao wipe: {path}"
    assert not host_sandbox.state.exists(), "$PZ_STATE sobreviveu ao wipe"


def test_wipe_never_touches_emulation(host_sandbox):
    seed_footprint(host_sandbox)
    rom = host_sandbox.emulation / "roms/snes/jogo.sfc"
    rom.parent.mkdir(parents=True, exist_ok=True)
    rom.write_text("ROM do usuário\n", encoding="utf-8")

    host_sandbox.pz("host", "wipe", "--apply", f"--confirm={TOKEN}")

    assert rom.is_file()
    assert rom.read_text(encoding="utf-8") == "ROM do usuário\n"
    host_sandbox.assert_emulation_intact()


def test_wipe_refuses_a_ledger_path_that_points_into_emulation(host_sandbox):
    """Guarda absoluta: nem um ledger corrompido consegue apagar ~/Emulation."""
    seed_footprint(host_sandbox)
    hostile = host_sandbox.emulation / "roms/snes"
    with host_sandbox.ledger.open("a", encoding="utf-8") as handle:
        handle.write(
            json.dumps(
                {
                    "operation_id": "hostil",
                    "module": "ai",
                    "action": "create-path",
                    "timestamp": "2026-01-01T00:00:00+00:00",
                    "created": [str(hostile), str(host_sandbox.emulation), str(host_sandbox.home)],
                    "modified": [],
                    "backups": [],
                    "services": [],
                    "packages": [],
                    "scope": "user",
                    "reversible": True,
                    "rollback_cmd": "",
                }
            )
            + "\n"
        )

    host_sandbox.pz("host", "wipe", "--apply", f"--confirm={TOKEN}")

    assert hostile.is_dir(), "wipe seguiu um path hostil do ledger para dentro de ~/Emulation"
    host_sandbox.assert_emulation_intact()
    assert host_sandbox.home.is_dir()


def test_wipe_leaves_unrelated_user_data_alone(host_sandbox):
    seed_footprint(host_sandbox)
    foreign = host_sandbox.home / ".config/outro-app/config.json"
    foreign.parent.mkdir(parents=True, exist_ok=True)
    foreign.write_text("{}\n", encoding="utf-8")

    host_sandbox.pz("host", "wipe", "--apply", f"--confirm={TOKEN}")

    assert foreign.is_file()


def test_wipe_disables_recorded_services_via_stub_only(host_sandbox):
    seed_footprint(host_sandbox)
    host_sandbox.bash_lib(
        'ledger_record --module ai --action enable-service '
        '--service "user:phasezero-demo.service" --scope user --reversible true'
    )

    host_sandbox.pz("host", "wipe", "--apply", f"--confirm={TOKEN}")

    calls = host_sandbox.stub_calls()
    assert any("systemctl --user disable --now phasezero-demo.service" in call for call in calls), (
        f"serviço do ledger não foi desabilitado; chamadas: {calls}"
    )


def test_wipe_is_idempotent(host_sandbox):
    seed_footprint(host_sandbox)
    host_sandbox.pz("host", "wipe", "--apply", f"--confirm={TOKEN}")
    payload = envelope(host_sandbox.pz("host", "wipe", "--apply", f"--confirm={TOKEN}"))
    assert payload["ok"] is True
    host_sandbox.assert_emulation_intact()
