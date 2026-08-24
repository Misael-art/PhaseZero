from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QGroupBox, QLabel, QPushButton

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.models import OperationResult
from linux.ui_native.operation_ledger import OperationLedger
from linux.ui_native.pages.ai_dev import AiDevPage
from linux.ui_native.pages.ai_proxies import AiProxiesPage, MimoTokenDialog
from linux.ui_native.pages.ai_routing import AiRoutingPage
from linux.ui_native.pages.results import ResultsPage
from linux.ui_native.pages.registry import PageRegistry
from linux.ui_native.proxy_models import ProxyState
from linux.ui_native.result_parser import severity_for
from linux.ui_native.widgets import PreviewDialog, ResultDialog


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def catalog():
    return build_catalog(ROOT)


@pytest.fixture
def by_id(catalog):
    return {a.id: a for a in catalog}


@pytest.fixture
def proxies_page(qapp, catalog, by_id):
    actions = [action for action in catalog if action.category == "Proxies IA"]
    page = AiProxiesPage(ROOT, CommandRunner(ROOT), actions, by_id=by_id)
    page.build()
    page.finalize_action_coverage()
    page.set_advanced_mode(False)
    return page, actions


@pytest.fixture
def ai_dev_page(qapp, catalog, by_id):
    actions = [action for action in catalog if action.category == "IA & Dev"]
    page = AiDevPage(ROOT, CommandRunner(ROOT), actions, by_id=by_id)
    page.build()
    page.finalize_action_coverage()
    page.set_advanced_mode(False)
    return page, actions


@pytest.fixture
def routing_page(qapp, catalog, by_id):
    actions = [action for action in catalog if action.category == "Roteamento IA"]
    page = AiRoutingPage(ROOT, CommandRunner(ROOT), actions, by_id=by_id)
    page.build()
    page.finalize_action_coverage()
    page.set_advanced_mode(False)
    return page, actions


def test_registry_uses_dedicated_ai_pages():
    assert PageRegistry._CATEGORY_PAGES["IA & Dev"] is AiDevPage
    assert PageRegistry._CATEGORY_PAGES["Proxies IA"] is AiProxiesPage
    assert PageRegistry._CATEGORY_PAGES["Roteamento IA"] is AiRoutingPage


def test_main_window_skips_preview_for_ensure():
    src = (ROOT / "linux/ui_native/main_window.py").read_text(encoding="utf-8")
    assert "ai.proxies-ensure" in src
    assert "preview=action.mutable and not skip_preview" in src


def test_ensure_actions_are_the_primary_proxy_flow(by_id):
    for action_id, proxy in (
        ("ai.proxies-ensure-kimi", "kimiproxy"),
        ("ai.proxies-ensure-qwen", "qwenproxy"),
        ("ai.proxies-ensure-deeps", "deepsproxy"),
        ("ai.proxies-ensure-mimo", "mimo-ai-proxy"),
        ("ai.proxies-ensure-all", "all"),
    ):
        action = by_id[action_id]
        assert action.mutable
        assert action.args == ("ai", "proxies", "ensure", proxy)
        assert action.preview_args == ("ai", "proxies", "ensure", proxy, "--dry-run")
        assert action.visibility != "advanced"
    assert by_id["ai.proxies"].visibility == "advanced"
    assert by_id["ai.proxies-start-qwen"].visibility == "advanced"
    assert by_id["ai.proxies-login-qwen"].visibility == "advanced"
    assert by_id["ai.proxies-open-qwen"].args == ("ai", "proxies", "open", "qwenproxy")
    assert not by_id["ai.proxies-open-qwen"].mutable
    assert by_id["ai.proxies-credentials-mimo"].stdin_parameter == "credentials"


def test_workspace_auth_and_provenance_actions_are_catalogued(by_id):
    assert by_id["ai.hermes-status"].args == ("ai", "hermes", "status")
    assert by_id["ai.hermes-doctor"].args == ("ai", "hermes", "doctor")
    assert by_id["ai.workspaces-doctor"].args == ("ai", "workspaces", "doctor")
    assert by_id["ai.workspaces-plan"].args == ("ai", "workspaces", "plan")
    assert by_id["ai.odysseus-install"].preview_args == ("ai", "odysseus", "plan")
    assert by_id["ai.auth-registry"].args == ("ai", "auth", "status")
    assert by_id["ai.auth-doctor"].args == ("ai", "auth", "doctor")
    assert by_id["ai.operations-status"].args == ("ai", "operations", "status")


def test_proxies_page_covers_all_catalog_actions(proxies_page):
    page, actions = proxies_page
    assert {action.id for action in actions} <= page.represented_action_ids


def test_proxies_page_usar_is_one_click_ensure(proxies_page):
    page, _actions = proxies_page
    labels = []
    hero = page.prepare_button.parentWidget()
    for index in range(hero.layout().count()):
        widget = hero.layout().itemAt(index).widget()
        if isinstance(widget, QPushButton):
            labels.append(widget.text())
    assert labels == ["Atualizar", "Preparar todos"]
    qwen = page._cards["qwenproxy"]
    use = qwen["use"]
    assert isinstance(use, QPushButton)
    assert use.text() == "Usar"
    spy = []
    page.action_requested.connect(lambda action: spy.append(action.id))
    use.click()
    assert spy == ["ai.proxies-ensure-qwen"]


def test_proxies_page_hides_ports_in_simple_mode(proxies_page):
    page, _actions = proxies_page
    port = page._cards["qwenproxy"]["port"]
    assert isinstance(port, QLabel)
    assert port.isHidden()
    page.set_advanced_mode(True)
    assert not port.isHidden()


def test_ready_qwen_button_opens_opencode(proxies_page):
    page, _actions = proxies_page
    page._apply_proxies({
        "qwenproxy": ProxyState(
            id="qwenproxy", installed=True, service="active",
            auth_status="authenticated",
        ),
        "mimo-ai-proxy": ProxyState(
            id="mimo-ai-proxy", installed=True, service="active",
            auth_status="missing-credentials",
        ),
    })
    qwen_use = page._cards["qwenproxy"]["use"]
    mimo_use = page._cards["mimo-ai-proxy"]["use"]
    assert qwen_use.text() == "Abrir no OpenCode"
    assert mimo_use.text() == "Conectar conta"
    spy = []
    page.action_requested.connect(lambda action: spy.append(action.id))
    qwen_use.click()
    assert spy == ["ai.proxies-open-qwen"]


def test_proxies_page_translates_status_into_human_copy(proxies_page):
    page, _actions = proxies_page
    page._apply_proxies({
        "qwenproxy": ProxyState(
            id="qwenproxy", installed=False, service="inactive",
            auth_status="not-installed",
        ),
        "kimiproxy": ProxyState(
            id="kimiproxy", installed=True, service="active",
            auth_status="authenticated",
        ),
        "deepsproxy": ProxyState(
            id="deepsproxy", installed=True, service="inactive",
            auth_status="ready-for-login",
        ),
        "mimo-ai-proxy": ProxyState(
            id="mimo-ai-proxy", installed=True, service="active",
            auth_status="missing-credentials", auth_missing=("service-token-group",),
        ),
    })
    assert page._cards["qwenproxy"]["headline"].text() == "Precisa preparar"
    assert page._cards["kimiproxy"]["headline"].text() == "Pronto"
    assert page._cards["deepsproxy"]["headline"].text() == "Falta login"
    assert page._cards["mimo-ai-proxy"]["headline"].text() == "Falta token da conta"
    assert "Falta login" in page.state_label.text() or "Precisa preparar" in page.state_label.text()


def test_proxies_page_integrates_hermes_and_safe_odysseus_plan(proxies_page):
    page, _actions = proxies_page
    page._proxy_status_ready("ai.hermes-status", "", {
        "installed": True,
        "ready": False,
        "version": "0.20.5",
        "auth": {"configured": False},
    })
    hermes = page._gateway_rows["hermes"]
    assert hermes["use"].text() == "Diagnosticar"
    assert hermes["detail"].text() == "Autenticação pendente"
    page._proxy_status_ready("ai.odysseus-status", "", {
        "installed": False, "ready": False, "podmanRootless": True,
    })
    odysseus = page._gateway_rows["odysseus"]
    assert odysseus["use"].text() == "Ver plano"


def test_proxies_page_catalogues_redacted_auth_without_account_identity(proxies_page):
    page, _actions = proxies_page
    page._proxy_status_ready("ai.auth-registry", "", {
        "summary": {
            "total": 6, "ready": 3, "attention": 2,
            "missingEssential": 0, "accounts": 12,
        },
        "entries": [
            {"id": "gateway:9router", "label": "9Router", "ready": True},
            {"id": "client:opencode", "label": "OpenCode", "ready": True},
            {"id": "provider:xai", "label": "XAI", "ready": True},
            {"id": "provider:codex", "label": "CODEX", "ready": False},
            {"id": "proxy:mimo-ai-proxy", "label": "Mimo Proxy", "ready": False},
            {"id": "workspace:hermes", "label": "Hermes", "ready": False},
        ],
        "secretsRedacted": True,
    })
    assert "12 contas catalogadas" in page.auth_summary.text()
    assert "CODEX" in page._auth_group_labels["providers"].text()
    assert "Mimo Proxy" in page._auth_group_labels["proxies"].text()
    rendered = " ".join(label.text() for label in page._auth_group_labels.values())
    assert "@" not in rendered and "token" not in rendered.casefold()


def test_mimo_credentials_continue_to_opencode_automatically(
    proxies_page, monkeypatch,
):
    page, _actions = proxies_page
    monkeypatch.setattr(MimoTokenDialog, "exec", lambda _self: MimoTokenDialog.Accepted)
    monkeypatch.setattr(MimoTokenDialog, "payload", lambda _self: {
        "serviceToken": "secret", "userId": "user", "chatbotPh": "ph",
    })
    monkeypatch.setattr(
        "linux.ui_native.pages.ai_proxies.QDesktopServices.openUrl", lambda _url: True,
    )
    queued = []
    page.actions_requested.connect(
        lambda actions: queued.append([action.id for action in actions])
    )
    page._connect_mimo()
    assert queued == [["ai.proxies-credentials-mimo", "ai.proxies-open-mimo"]]


def test_interrupted_operation_can_retry_only_through_confirmation_flow(
    qapp, by_id, tmp_path, monkeypatch,
):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    operations = tmp_path / "state" / "phasezero" / "control-center" / "operations"
    ledger = OperationLedger(operations)
    ledger.begin(by_id["ai.proxies-ensure-mimo"], preview=False)
    ledger.finish(exit_code=1)
    page = ResultsPage(ROOT, CommandRunner(ROOT), [], by_id=by_id)
    page.build()
    page.reload()
    assert page.table is not None and page.table.rowCount() == 1
    page.table.selectRow(0)
    qapp.processEvents()
    assert page.retry_button is not None and page.retry_button.isEnabled()
    requested = []
    page.action_requested.connect(lambda action: requested.append(action.id))
    page.retry_button.click()
    assert requested == ["ai.proxies-ensure-mimo"]


def test_ai_dev_page_covers_all_catalog_actions(ai_dev_page):
    page, actions = ai_dev_page
    assert page.represented_action_ids == {action.id for action in actions}


def test_ai_dev_page_hero_uses_status_payload(ai_dev_page):
    page, _actions = ai_dev_page
    page._on_status_ready("ai.status", "", {
        "mode": "degraded",
        "clis": {"opencode": {"available": False}, "claude": {"available": True}},
        "mcp": {},
        "agentCompat": {"mode": "degraded"},
        "recommendations": ["linux/pz ai setup opencode"],
    })
    assert page.state_label.text() == "● Falta configurar"
    assert "Reparar ambiente" in page.repair_button.text()
    assert "não configurado" in page._status_labels["opencode"].text()
    assert "Instalado" in page._status_labels["claude"].text()
    assert "linux/pz" not in page.state_detail.text()


def test_ai_dev_optional_tools_do_not_make_essential_stack_incomplete(ai_dev_page):
    page, _actions = ai_dev_page
    page._on_status_ready("ai.status", "", {
        "mode": "degraded",
        "clis": {"opencode": {"available": True}, "claude": {"available": False}},
        "mcp": {},
        "agentCompat": {"mode": "degraded"},
        "recommendations": ["linux/pz ai setup hermes", "linux/pz ai odysseus install"],
        "setupCatalog": {
            "essentials": [
                {"label": "OpenCode", "state": "ready"},
                {"label": "9Router", "state": "ready"},
                {"label": "Memória", "state": "ready"},
                {"label": "MCPs", "state": "ready"},
            ],
            "optional": [
                {"label": "Hermes", "state": "optional"},
                {"label": "Odysseus", "state": "optional"},
            ],
        },
    })
    assert page.state_label.text() == "● Pronto"
    assert "opcionais" in page.state_detail.text()


def test_routing_hides_technical_surfaces_in_simple_mode(routing_page):
    page, _actions = routing_page
    boxes = page.findChildren(QGroupBox)
    titles = {box.title() for box in boxes}
    assert "Ordem avançada de fallbacks" in titles
    assert "Rollback transacional" in titles
    for widget in page._technical_widgets:
        assert widget.isHidden()
    page.set_advanced_mode(True)
    for widget in page._technical_widgets:
        assert not widget.isHidden()


def test_routing_preview_and_apply_keep_selected_policy(routing_page):
    page, _actions = routing_page
    policy = page._policy_combo
    policy.setCurrentIndex(policy.findData("privacy"))
    requested = []
    page.action_requested.connect(lambda action: requested.append(action))
    page._task_preview("code")
    page._task_apply("code")
    assert requested[0].args == (
        "ai", "routing", "apply", "--task", "code", "--policy", "privacy", "--dry-run",
    )
    assert requested[1].args == (
        "ai", "routing", "apply", "--task", "code", "--policy", "privacy", "--yes",
    )
    assert requested[1].preview_args[-1] == "--dry-run"


def test_routing_dynamic_success_populates_fallback_and_enables_apply(routing_page):
    page, _actions = routing_page
    recommendation = [
            {
                "model_id": "provider/model-a", "score": 0.9,
                "justifications": ["boa qualidade"], "quota_state": "known",
                "quota": 0.8, "quota_confidence": 1.0,
            },
            {
                "model_id": "provider/model-b", "score": 0.7,
                "justifications": [], "quota_state": "unknown",
                "quota": 0.5, "quota_confidence": 0.4,
            },
        ]
    for task in ("code", "analysis", "plan"):
        page._routing_status_ready(
            f"routing.dynamic.{task}.balanced", "", {"recommendation": recommendation},
        )
    card = page._task_cards["code"]
    assert page._apply_all_button.isEnabled()
    assert page._chain_editor.count() == 2
    assert page._chain_editor.item(0).text() == "provider/model-a"
    assert "cota: conhecida" in card["quota"].text()


def test_routing_dynamic_failure_never_stays_verifying(routing_page):
    page, _actions = routing_page
    page._routing_status_failed("routing.dynamic.analysis.quality", "timeout")
    card = page._task_cards["analysis"]
    assert card["recommended"].text() == "Recomendação indisponível"
    assert not page._apply_all_button.isEnabled()


def test_ensure_status_severity_is_honest():
    assert severity_for({"status": "ready"}, 0) == "success"
    assert severity_for({"status": "needs-login"}, 0) == "warning"
    assert severity_for({"status": "needs-credentials"}, 0) == "warning"
    assert severity_for({"status": "gui-required"}, 0) == "warning"
    assert severity_for({"status": "error"}, 0) == "error"


def test_result_dialog_prefers_json_summary(qapp):
    result = OperationResult(
        action_id="ai.proxies-ensure-qwen",
        command=["pz", "ai", "proxies", "ensure", "qwenproxy"],
        preview=False,
        exit_code=0,
        started_at="t0",
        finished_at="t1",
        stdout='{"summary":"Uma janela do navegador abriu para o login do Qwen.","next":"Conclua o login."}',
        stderr="INFO: npm ci",
        parsed={
            "summary": "Uma janela do navegador abriu para o login do Qwen.",
            "next": "Conclua o login.",
            "status": "needs-login",
        },
    )
    dialog = ResultDialog(result, "raw", None, severity="warning", advanced_mode=False)
    assert "Uma janela do navegador abriu" in dialog.summary_label.text()
    assert "Conclua o login" in dialog.summary_label.text()
    assert "npm ci" not in dialog.summary_label.text()


def test_preview_dialog_uses_ensure_summary(qapp):
    result = OperationResult(
        action_id="ai.proxies-ensure-qwen",
        command=["pz", "ai", "proxies", "ensure", "qwenproxy", "--dry-run"],
        preview=True,
        exit_code=0,
        started_at="t0",
        finished_at="t1",
        stdout="",
        stderr="",
        parsed={
            "summary": "Vai instalar o Qwen, abrir o navegador para login e iniciar o serviço.",
            "next": "Uma janela do Chromium abre para você entrar na conta.",
            "dryRun": True,
        },
    )
    dialog = PreviewDialog(result, None, None, advanced_mode=False)
    labels = [child.text() for child in dialog.findChildren(QLabel) if child.text()]
    assert any("Vai instalar o Qwen" in text for text in labels)
    assert dialog.technical.isHidden()
