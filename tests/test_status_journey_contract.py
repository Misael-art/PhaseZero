"""Fase 1 do saneamento de jornadas: relatório válido nunca é erro.

Contrato fixado aqui (espelha decisions/homelab-status-diagnostico-nao-falha):
- status que produz JSON é um sucesso de relatório, mesmo com rc != 0;
- preview mutável com pendência (needs-*/resumable/state) vira warning;
- orientação (summary/nextAction/reasons) tem leitura única via guidance().
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from linux.ui_native.result_parser import guidance, is_pending_report, severity_for  # noqa: E402
from linux.ui_native.status_loader import redact, report_outcome  # noqa: E402


# --- report_outcome ---------------------------------------------------------

def test_report_with_json_is_ready_even_with_nonzero_exit():
    outcome, parsed, message = report_outcome(
        '{"state":"needs-config","ready":false}', "some stderr", 1
    )
    assert outcome == "ready"
    assert parsed["state"] == "needs-config"
    assert message == ""


def test_report_without_json_and_nonzero_exit_fails_redacted():
    outcome, parsed, message = report_outcome("", "token=abc123\nboom", 1)
    assert outcome == "failed"
    assert parsed is None
    assert "exit code 1" in message
    assert "boom" in message
    assert "abc123" not in message


def test_report_empty_output_zero_exit_still_ready_with_null_payload():
    outcome, parsed, _ = report_outcome("", "", 0)
    assert outcome == "ready"
    assert parsed is None


def test_redact_masks_secret_patterns():
    text = redact("api-key: sk-abcdefghijklmnopqrstuvwx and password = hunter2")
    assert "sk-abcdefghijklmnopqrstuvwx" not in text
    assert "hunter2" not in text


# --- is_pending_report / severity_for ---------------------------------------

def test_pending_report_detects_all_dialects():
    assert is_pending_report({"state": "needs-config"}) is True
    assert is_pending_report({"resumable": True}) is True
    assert is_pending_report({"nextAction": "linux/pz server homelab repair"}) is True
    assert is_pending_report({"status": "needs-login"}) is True
    assert is_pending_report({}) is False
    assert is_pending_report(None) is False
    assert is_pending_report({"state": "error"}) is False


def test_severity_mutable_preview_with_pending_payload_is_warning():
    assert severity_for({"state": "needs-config"}, 1, mutable=True) == "warning"
    assert severity_for({"resumable": True, "ok": False}, 1, mutable=True) == "warning"
    assert severity_for({"status": "gui-required"}, 1, mutable=True) == "warning"


def test_severity_real_failure_still_error_even_in_preview():
    assert severity_for({}, 1, mutable=True) == "error"
    assert severity_for(None, 1, mutable=True) == "error"
    assert severity_for({"status": "blocked"}, 0, mutable=True) == "error"


def test_severity_success_paths_unchanged():
    assert severity_for({"status": "ready"}, 0) == "success"
    assert severity_for({"status": "needs-login"}, 0) == "warning"
    assert severity_for({"status": "degraded"}, 0) == "warning"


# --- guidance ----------------------------------------------------------------

def test_guidance_unifies_nextaction_and_next_dialects():
    a = guidance({"summary": "S1", "nextAction": "run me", "reasons": ["r1", "r2"]})
    b = guidance({"message": "M2", "next": "do that"})
    assert a["summary"] == "S1" and a["next_action"] == "run me"
    assert a["reasons"] == ["r1", "r2"]
    assert b["summary"] == "M2" and b["next_action"] == "do that"


def test_guidance_caps_reasons_and_tolerates_garbage():
    out = guidance({"reasons": [f"r{i}" for i in range(10)], "summary": "  ", "next": "   "})
    assert len(out["reasons"]) == 6
    assert out["summary"] is None and out["next_action"] is None
    assert guidance("not-a-dict") == {"summary": None, "next_action": None, "reasons": []}
