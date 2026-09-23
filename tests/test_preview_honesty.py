"""LUX-001 — prévia de estado não se passa por simulação."""
from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QLabel

from linux.ui_native.catalog import build_catalog
from linux.ui_native.models import OperationResult

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def by_id():
    return {action.id: action for action in build_catalog(ROOT)}


def _result(action):
    return OperationResult(
        action_id=action.id, command=["pz"], preview=True, exit_code=0,
        started_at="", finished_at="", stdout="{}", stderr="", parsed={},
    )


def _texts(dialog):
    return " ".join(label.text() for label in dialog.findChildren(QLabel))


def test_every_high_risk_action_has_plan_or_impact(by_id):
    missing = [
        action.id for action in by_id.values()
        if action.mutable and action.risk == "high"
        and action.preview_kind != "plan" and not action.impact
    ]
    assert missing == []


def test_preview_kind_inference(by_id):
    assert by_id["waydroid.boot.next-reboot"].preview_kind == "state"
    assert by_id["host.wipe"].preview_kind == "plan"
    assert by_id["waydroid.shares.enable"].preview_kind == "plan"


def test_state_preview_never_claims_simulation(qapp, by_id):
    from linux.ui_native.widgets import PreviewDialog

    action = by_id["waydroid.boot.next-reboot"]
    dialog = PreviewDialog(_result(action), action)
    text = _texts(dialog)
    assert "Preview concluído" not in text
    assert "não simula" in text
    assert "REINICIA o computador" in text
    # impacto aparece antes do campo CONFIRMAR
    assert dialog.body.indexOf(dialog.impact_label) < dialog.body.indexOf(dialog.confirmation)


def test_plan_preview_keeps_plan_copy(qapp, by_id):
    from linux.ui_native.widgets import PreviewDialog

    action = by_id["waydroid.shares.enable"]
    dialog = PreviewDialog(_result(action), action)
    assert "Preview concluído" in _texts(dialog)
    assert not hasattr(dialog, "impact_label")


def test_blocked_preview_explains_why(qapp, by_id):
    from linux.ui_native.widgets import PreviewDialog

    action = by_id["waydroid.shares.enable"]
    result = _result(action)
    result.parsed = {"blockers": ["Waydroid não está instalado"]}
    dialog = PreviewDialog(result, action)
    text = _texts(dialog)
    assert dialog.windowTitle() == "Não é seguro aplicar agora"
    assert "Preview concluído" not in text
    assert "Waydroid não está instalado" in text
    assert not dialog.confirm.isEnabled()
    assert dialog.blocked_reason.text()


def test_failed_preview_is_not_called_complete(qapp, by_id):
    from linux.ui_native.widgets import PreviewDialog

    action = by_id["waydroid.shares.enable"]
    result = _result(action)
    result.exit_code = 1
    result.parsed = None
    dialog = PreviewDialog(result, action)
    assert "Preview concluído" not in _texts(dialog)
    assert "falhou" in _texts(dialog)
