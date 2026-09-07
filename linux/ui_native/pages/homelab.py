from __future__ import annotations

import json
import os
from pathlib import Path

from PySide6.QtCore import QProcess, Qt, QTimer
from PySide6.QtWidgets import (
    QComboBox, QFrame, QGridLayout, QGroupBox, QHBoxLayout, QHeaderView,
    QLabel, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton,
    QScrollArea, QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget,
)
from shiboken6 import isValid

from .base import BasePage

CMD_TIMEOUT_MS = 30 * 60 * 1000


class HomelabPage(BasePage):
    """Homelab Player: live stack status, profile slot, governor budget and
    one-click plan/up/down/backup/verify/restore backed by linux/pz.

    All external commands run through QProcess (never blocking subprocess in the
    GUI thread). ``_spawn_cmd`` is used for the status poll and short queries;
    ``run_cmd`` owns user-initiated actions with separated stdout/stderr,
    timeout and double-emit protection. The restore path never passes ``--yes``
    automatically; it asks the operator inside the Player instead.
    """

    def __init__(
        self,
        root,
        runner,
        actions,
        by_id=None,
        parent=None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self._green = QLabel("●")
        self._green.setObjectName("serviceState")
        self._proc: QProcess | None = None
        self._profile_map: dict[str, str] = {}
        self._last_status: dict = {}
        self._timeouts: dict[int, QTimer] = {}
        self._action_buttons: list[QPushButton] = []
        self._card_buttons: list[QPushButton] = []
        self._pending_confirm_file: Path | None = None
        self._cards_layout: QGridLayout | None = None
        self._cards_host: QWidget | None = None
        self._hosts: dict[str, dict] = {}
        self._host_combo: QComboBox | None = None
        self._host_badge: QLabel | None = None
        self._pair_btn: QPushButton | None = None
        self._dash_btn: QPushButton | None = None
        self._onboard_step = 0
        self._onboard_confirmed = False
        self._onboard_state: dict = {}
        self._pair_advance = False
        self._pair_host = ""
        self._onboard_label: QLabel | None = None
        self._onboard_next: QPushButton | None = None
        # UX-003: reflow state; built widgets arrive in build().
        self._narrow_layout: bool | None = None
        self._header_grid: QGridLayout | None = None
        self._profile_grid: QGridLayout | None = None
        self._actions_grid: QGridLayout | None = None

    # ------------------------------------------------------------- theming
    def resizeEvent(self, event) -> None:  # noqa: N802 (Qt override)
        super().resizeEvent(event)
        if self._header_grid is None:
            return
        self._apply_reflow(self.width() < 1000)

    def _apply_reflow(self, narrow: bool) -> None:
        if narrow == self._narrow_layout:
            return
        self._narrow_layout = narrow
        self._reflow_header(narrow)
        self._reflow_profile(narrow)
        self._reflow_actions(narrow)

    def _reflow_header(self, narrow: bool) -> None:
        g = self._header_grid
        if g is None:
            return
        if narrow:
            # two rows: status + refresh on top, host controls below
            g.addWidget(self._state_label, 0, 1)
            g.addWidget(self._green, 0, 2)
            g.addWidget(self.refresh_header_btn, 0, 3)
            g.addWidget(self._host_caption, 1, 0)
            g.addWidget(self._host_combo, 1, 1)
            g.addWidget(self._host_badge, 1, 2)
            g.addWidget(self._pair_btn, 1, 3)
            g.addWidget(self._dash_btn, 1, 4)
            g.setColumnStretch(0, 1)
            g.setColumnStretch(5, 1)
        else:
            g.addWidget(self._state_label, 0, 7)
            g.addWidget(self._green, 0, 8)
            g.addWidget(self.refresh_header_btn, 0, 9)
            g.addWidget(self._host_caption, 0, 1)
            g.addWidget(self._host_combo, 0, 2)
            g.addWidget(self._host_badge, 0, 3)
            g.addWidget(self._pair_btn, 0, 4)
            g.addWidget(self._dash_btn, 0, 5)
            g.setColumnStretch(6, 1)
            g.setColumnStretch(0, 0)

    def _reflow_profile(self, narrow: bool) -> None:
        g = self._profile_grid
        if g is None:
            return
        if narrow:
            g.addWidget(self._profile_caption, 0, 0)
            g.addWidget(self._profile_combo, 0, 1, 1, 3)
            g.addWidget(self._profile_set, 1, 0)
            g.addWidget(self._budget_caption, 1, 1)
            g.addWidget(self._budget_label, 1, 2)
            g.addWidget(self._policy_btn, 1, 3)
            g.setColumnStretch(1, 1)
            g.setColumnStretch(3, 1)
        else:
            g.addWidget(self._profile_caption, 0, 0)
            g.addWidget(self._profile_combo, 0, 1)
            g.addWidget(self._profile_set, 0, 2)
            g.addWidget(self._budget_caption, 0, 3)
            g.addWidget(self._budget_label, 0, 4)
            g.addWidget(self._policy_btn, 0, 5)
            g.setColumnStretch(1, 1)
            g.setColumnStretch(4, 0)

    def _reflow_actions(self, narrow: bool) -> None:
        g = self._actions_grid
        if g is None:
            return
        for index, btn in enumerate(self._action_buttons):
            if narrow:
                g.addWidget(btn, index // 3, index % 3)
            else:
                g.addWidget(btn, 0, index)

    def _set_state(self, state: str) -> None:
        """Cor via tema (objectName+property), nunca stylesheet cru."""
        for label in (self._state_label, self._green):
            label.setProperty("state", state)
            label.style().unpolish(label)
            label.style().polish(label)

    def build(self) -> None:
        # UX-003: the whole page lives in a vertical scroll area — at
        # 1280x800 and 800x600 every control stays reachable by scrolling;
        # no group is compressed and no horizontal scroll is needed.
        self._page_scroll = QScrollArea()
        self._page_scroll.setWidgetResizable(True)
        self._page_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self._page_scroll.setFrameShape(QFrame.NoFrame)
        self._page_scroll.setAccessibleName("Conteúdo do Homelab")
        page_host = QWidget()
        page_host.setObjectName("homelabPageHost")
        lay = QVBoxLayout(page_host)
        lay.setSpacing(12)
        self._layout.addSpacing(8)
        self._layout.addWidget(self._page_scroll, 1)
        self._layout = lay
        self._page_scroll.setWidget(page_host)

        # UX-003: header, profile and actions live in reflowable grids —
        # on narrow windows the rows wrap instead of dictating a minimum
        # width that would clip controls at 800x600 with the real theme.
        self._header_grid = QGridLayout()
        self._header_grid.setContentsMargins(0, 0, 0, 0)
        self._header_grid.setHorizontalSpacing(8)
        title = QLabel("Homelab Player")
        title.setStyleSheet("font-size:17px;font-weight:700")
        self._header_grid.addWidget(title, 0, 0)
        host_caption = QLabel("Host:")
        self._host_caption = host_caption
        self._host_combo = QComboBox()
        self._host_combo.setAccessibleName("Host Homelab")
        self._host_combo.addItem("Este computador (local)", "")
        host_caption.setBuddy(self._host_combo)
        self._host_badge = QLabel("Local")
        self._host_badge.setObjectName("serviceState")
        self._host_badge.setProperty("state", "success")
        self._pair_btn = QPushButton("Parear")
        self._pair_btn.setToolTip("Copia a chave SSH sem colocar senha na linha de comando.")
        self._pair_btn.setEnabled(False)
        self._pair_btn.clicked.connect(self.start_pair)
        self._dash_btn = QPushButton("Abrir dashboard")
        self._dash_btn.setToolTip("Abre o dashboard HTTPS do host Homelab selecionado.")
        self._dash_btn.setAccessibleName("Abrir dashboard")
        self._dash_btn.clicked.connect(self.open_dashboard)
        self._state_label = QLabel("—")
        self._state_label.setObjectName("serviceState")
        self._green = QLabel("●")
        self._green.setObjectName("serviceState")
        refresh = QPushButton("Atualizar")
        refresh.setAccessibleName("Atualizar status do Homelab")
        refresh.clicked.connect(self.refresh_status)
        self.refresh_header_btn = refresh
        self._reflow_header(bool(self._narrow_layout))
        self._host_combo.currentIndexChanged.connect(self._on_host_changed)
        lay.addLayout(self._header_grid)

        onboard = QGroupBox("Primeiros passos")
        onboard.setAccessibleName("Onboarding do Homelab")
        o_lay = QHBoxLayout()
        self._onboard_label = QLabel(self._onboard_prompt())
        self._onboard_label.setWordWrap(True)
        start = QPushButton("Começar")
        start.setAccessibleName("Começar onboarding")
        start.clicked.connect(self.start_onboarding)
        # UX-001: the review step has an explicit, reachable confirmation —
        # the state machine's onboard_confirm_review() is wired to a real
        # control instead of existing only for tests.
        self._onboard_confirm = QPushButton("Confirmar revisão")
        self._onboard_confirm.setAccessibleName("Confirmar revisão do Homelab")
        self._onboard_confirm.setToolTip("Aceita a política mostrada e libera a instalação.")
        self._onboard_confirm.clicked.connect(self._confirm_review_clicked)
        self._onboard_confirm.setVisible(False)
        self._onboard_next = QPushButton("Avançar")
        self._onboard_next.setAccessibleName("Avançar onboarding")
        self._onboard_next.clicked.connect(self.onboard_advance)
        o_lay.addWidget(self._onboard_label, 1)
        o_lay.addWidget(start)
        o_lay.addWidget(self._onboard_confirm)
        o_lay.addWidget(self._onboard_next)
        onboard.setLayout(o_lay)
        lay.addWidget(onboard)

        # App cards (one-click catalog) ------------------------------------
        cards_box = QGroupBox("Aplicativos")
        cards_box.setAccessibleName("Catálogo de aplicativos do Homelab")
        cards_outer = QVBoxLayout()
        self._cards_scroll = QScrollArea()
        self._cards_scroll.setWidgetResizable(True)
        self._cards_host = QWidget()
        self._cards_layout = QGridLayout(self._cards_host)
        self._cards_layout.setContentsMargins(4, 4, 4, 4)
        self._cards_scroll.setWidget(self._cards_host)
        self._cards_scroll.setMinimumHeight(200)
        cards_outer.addWidget(self._cards_scroll)
        cards_box.setLayout(cards_outer)
        lay.addWidget(cards_box)

        # Status table ------------------------------------------------------
        self._table = QTableWidget(0, 5)
        self._table.setHorizontalHeaderLabels(["Serviço", "Camada", "Endereço", "URL", "Rodando"])
        self._table.setAccessibleName("Serviços do Homelab")
        header_view = self._table.horizontalHeader()
        header_view.setSectionResizeMode(QHeaderView.ResizeToContents)
        self._table.setEditTriggers(QTableWidget.NoEditTriggers)
        self._table.setSelectionMode(QTableWidget.SingleSelection)
        self._table.setSelectionBehavior(QTableWidget.SelectRows)
        self._table.setAlternatingRowColors(True)
        self._table.verticalHeader().setVisible(False)
        self._table.setMinimumHeight(140)
        lay.addWidget(self._table, 1)

        # Profile + governor ------------------------------------------------
        profile_box = QGroupBox("Perfil e orçamento")
        self._profile_grid = QGridLayout()
        self._profile_grid.setContentsMargins(0, 0, 0, 0)
        self._profile_grid.setHorizontalSpacing(8)
        self._profile_combo = QComboBox()
        self._budget_label = QLabel("—")
        profile_caption = QLabel("Perfil:")
        self._profile_caption = profile_caption
        profile_caption.setBuddy(self._profile_combo)
        self._profile_grid.addWidget(profile_caption, 0, 0)
        self._profile_grid.addWidget(self._profile_combo, 0, 1)
        self._profile_set = QPushButton("Aplicar perfil")
        self._profile_set.clicked.connect(self.apply_profile)
        self._profile_grid.addWidget(self._profile_set, 0, 2)
        budget_caption = QLabel("Orçamento:")
        self._budget_caption = budget_caption
        budget_caption.setBuddy(self._budget_label)
        self._profile_grid.addWidget(budget_caption, 0, 3)
        self._profile_grid.addWidget(self._budget_label, 0, 4)
        policy = QPushButton("Política")
        self._policy_btn = policy
        policy.clicked.connect(self.show_policy)
        self._profile_grid.addWidget(policy, 0, 5)
        profile_box.setLayout(self._profile_grid)
        lay.addWidget(profile_box)
        self._reflow_profile(bool(self._narrow_layout))

        # Actions -----------------------------------------------------------
        actions_box = QGroupBox("Ações")
        self._actions_grid = QGridLayout()
        self._actions_grid.setContentsMargins(0, 0, 0, 0)
        for label, fn in (
            ("Planejar", lambda: self.run_cmd(["plan"])),
            ("Copiar segurança", lambda: self.run_cmd(["backup"])),
            ("Conferir backup", lambda: self.run_cmd(["backup", "verify", "--source", self._last_backup()])),
            ("Restaurar", self.pick_restore),
            ("Reparar", lambda: self.run_cmd(["repair"])),
            ("Subir", lambda: self.run_cmd(["up"])),
        ):
            btn = QPushButton(label)
            btn.setToolTip(
                {
                    "Planejar": "Mostra o plano de implantação sem alterar nada.",
                    "Copiar segurança": "Gera backup verificado dos volumes.",
                    "Conferir backup": "Valida o último backup (checksums e manifesto).",
                    "Restaurar": "Fluxo assistido: prévia, confirmação digitada e rollback.",
                    "Reparar": "Prepara/repara a configuração do Homelab.",
                    "Subir": "Liga os serviços; dados preservados.",
                }.get(label, "")
            )
            btn.clicked.connect(fn)
            self._action_buttons.append(btn)
            self._actions_grid.addWidget(btn, 0, len(self._action_buttons) - 1)
        actions_box.setLayout(self._actions_grid)
        lay.addWidget(actions_box)
        self._reflow_actions(bool(self._narrow_layout))

        # Output ------------------------------------------------------------
        out_group = QGroupBox("Saída")
        out_layout = QVBoxLayout(out_group)
        self._output = QPlainTextEdit()
        self._output.setReadOnly(True)
        self._output.setMaximumBlockCount(4000)
        self._output.setStyleSheet("font-family:monospace;font-size:12px")
        out_layout.addWidget(self._output)
        self._bar = QProgressBar()
        self._bar.setRange(0, 0)
        self._bar.hide()
        out_layout.addWidget(self._bar)
        self._output.setMinimumHeight(160)
        lay.addWidget(out_group, 1)
        lay.addStretch(0)

        QTimer.singleShot(0, self.refresh_hosts)

    # -- data ---------------------------------------------------------------
    def _setup_proc(self, proc: QProcess) -> None:
        proc.setProcessChannelMode(QProcess.SeparateChannels)
        timer = QTimer(self)
        timer.setSingleShot(True)
        timer.setInterval(CMD_TIMEOUT_MS)
        timer.timeout.connect(lambda: self._kill_timed_out(proc))
        self._timeouts[id(proc)] = timer
        timer.start()

    def _cancel_timeout(self, proc: QProcess) -> None:
        timer = self._timeouts.pop(id(proc), None)
        if timer is not None:
            timer.stop()

    def _kill_timed_out(self, proc: QProcess) -> None:
        self._cancel_timeout(proc)
        if proc.state() != QProcess.NotRunning:
            proc.kill()
        if self._proc is proc:
            self._proc = None
        self._state_label.setText("comando excedeu o tempo (processo terminado)")

    def _spawn(self, args: list[str], on_done) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        proc = QProcess(self)
        self._setup_proc(proc)

        def on_finished(code: int) -> None:
            self._cancel_timeout(proc)
            if not isValid(proc):
                if self._proc is proc:
                    self._proc = None
                return
            on_done(
                code,
                bytes(proc.readAllStandardOutput()),
                bytes(proc.readAllStandardError()),
            )

        proc.finished.connect(on_finished)
        proc.start(str(self.root / "linux" / "pz"), args)
        self._proc = proc

    def _selected_host(self) -> str:
        if self._host_combo is None:
            return ""
        data = self._host_combo.currentData()
        return str(data) if data else ""

    def dashboard_url(self) -> str:
        """HTTPS URL of the appliance dashboard for the selected host."""
        alias = self._selected_host()
        if alias:
            rec = self._hosts.get(alias) or {}
            host = str(rec.get("host") or "127.0.0.1")
            port = int(rec.get("webPort") or 17443)
            return f"https://{host}:{port}/"
        return "https://127.0.0.1:17443/"

    def open_dashboard(self) -> None:
        from PySide6.QtCore import QUrl
        from PySide6.QtGui import QDesktopServices

        QDesktopServices.openUrl(QUrl(self.dashboard_url()))

    ONBOARD_STEPS = ("discover", "pair", "profile", "review", "apply")

    def onboard_step_name(self) -> str:
        steps = self.ONBOARD_STEPS
        idx = min(max(self._onboard_step, 0), len(steps) - 1)
        return steps[idx]

    def _onboard_prompt(self) -> str:
        name = self.onboard_step_name()
        copy = {
            "discover": "Descobrir o host Homelab na rede (mDNS ou IP:porta).",
            "pair": "Parear a chave SSH. Senha nunca vai no argv.",
            "profile": "Escolher perfil e apps. Orçamento recusa host curto.",
            "review": "Revisão: bind local, sem UPnP, fora de casa só Tailscale.",
            "apply": "Aplicar gera o plano (dry-run), revisar e aplicar de novo executa. Nunca --yes.",
        }
        return copy[name]

    def _confirm_review_clicked(self) -> None:
        # UX-001: production path for the review confirmation.
        self.onboard_confirm_review()
        self._refresh_onboard_label()

    def _refresh_onboard_label(self) -> None:
        if self._onboard_label is not None:
            text = self._onboard_prompt()
            if self.onboard_step_name() == "review" and self._onboard_confirmed:
                text = "Revisão confirmada — Avançar gera o plano para instalação."
            self._onboard_label.setText(text)
        # UX-001: the confirm control exists only while the review step is
        # unconfirmed; after confirmation Avançar is the single next action.
        if self._onboard_confirm is not None:
            visible = self.onboard_step_name() == "review" and not self._onboard_confirmed
            self._onboard_confirm.setVisible(visible)
            self._onboard_confirm.setEnabled(visible)

    def start_onboarding(self) -> None:
        self._onboard_step = 0
        self._onboard_confirmed = False
        self._onboard_state = {}
        self._refresh_onboard_label()

    def onboard_ingest_discover(self, payload: dict) -> None:
        self._onboard_state["discover"] = payload if isinstance(payload, dict) else {}

    def onboard_ingest_pair(self, ok: bool, detail: dict | None = None) -> None:
        self._onboard_state["pair"] = bool(ok)
        if detail is not None:
            self._onboard_state["pair_detail"] = detail

    def onboard_confirm_review(self) -> None:
        self._onboard_confirmed = True
        self._onboard_state["review"] = {
            "lanBind": False,
            "upnp": False,
            "external": "tailscale",
        }

    def onboard_review_text(self) -> str:
        return (
            "Bind padrão 127.0.0.1. Sem UPnP. Acesso externo só via Tailscale. "
            "SMART/rede/disco ausentes aparecem como indisponível."
        )

    def onboard_advance(self) -> None:
        # PZ-AUD-013: every step executes something real. Nothing advances
        # on placeholders: discover runs agent discovery, pair needs a real
        # pairing result (or an explicit local host), profile records the
        # actual selection, review needs confirmation, apply needs a plan.
        current = self.onboard_step_name()
        if current == "discover" and "discover" not in self._onboard_state:
            self._run_discover()
            return
        elif current == "pair":
            # REV-005: only a real pairing success for THIS host advances.
            # pair=false / cancel / offline keep the operator on the step
            # with an actionable error; nothing auto-advances.
            pair_detail = self._onboard_state.get("pair_detail") or {}
            if pair_detail.get("local") is True:
                paired_for = ""
            else:
                paired_for = str(pair_detail.get("alias") or "")
            if self._onboard_state.get("pair") is not True \
                    or paired_for != self._selected_host():
                alias = self._selected_host()
                if not alias:
                    self.onboard_ingest_pair(True, {"local": True})
                else:
                    self._pair_advance = True
                    self.start_pair()
                    return
        elif current == "profile":
            combo = self._profile_combo
            self._onboard_state["profile"] = {
                "profile": combo.currentData() if combo is not None else "",
            }
        elif current == "review" and not self._onboard_confirmed:
            return
        elif current == "apply":
            self.onboard_apply()
            return
        if self._onboard_step < len(self.ONBOARD_STEPS) - 1:
            self._onboard_step += 1
        self._refresh_onboard_label()

    def _run_discover(self) -> None:
        self._state_label.setText("Descobrindo Homelab…")
        self._spawn(["server", "homelab", "agent", "discover", "--json"], self._on_discover_done)

    def _first_json_document(self, text: str) -> dict:
        decoder = json.JSONDecoder()
        for idx, ch in enumerate(text):
            if ch != "{":
                continue
            try:
                doc, _end = decoder.raw_decode(text, idx)
            except ValueError:
                continue
            if isinstance(doc, dict):
                return doc
        return {}

    def _parse_json_payload(self, raw: bytes) -> dict:
        """REV-004: one document parser for every Player command output.

        Accepts pretty or compact JSON anywhere in stdout (``jq -n`` emits
        multiline documents) instead of parsing line by line, and unwraps
        the remote-host envelope ``{hostAlias, rc, payload, ...}`` produced
        by ``--host`` so callers see the inner payload plus the bound
        ``hostAlias``.
        """
        doc = self._first_json_document(raw.decode("utf-8", "replace"))
        payload = doc.get("payload")
        if isinstance(payload, dict) and isinstance(doc.get("hostAlias"), str):
            merged = dict(payload)
            merged["hostAlias"] = doc["hostAlias"]
            return merged
        return doc

    def _on_discover_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        payload = self._parse_json_payload(raw)
        if code == 0 and payload:
            self.onboard_ingest_discover(payload)
            self.refresh_hosts()
            if self._onboard_step < len(self.ONBOARD_STEPS) - 1:
                self._onboard_step += 1
            self._refresh_onboard_label()
        else:
            detail = err.decode("utf-8", "replace").strip().splitlines()
            reason = detail[-1] if detail else f"exit {code}"
            self._state_label.setText(f"Descoberta falhou: {reason}")
        self._refresh_onboard_label()

    def onboard_apply(self) -> None:
        if not self._onboard_confirmed:
            return
        # PZ-AUD-002/013 + REV-006/007: apply is plan-then-execute, and the
        # plan is a typed document bound to the host and profile the
        # operator reviewed. The captured host — never the mutable combo —
        # is what execution may target.
        self._state_label.setText("Gerando plano…")
        profile = (self._onboard_state.get("profile") or {}).get("profile") or ""
        plan_args = ["prepare", "--dry-run", "--json"]
        if profile:
            plan_args += ["--profile", profile]
        self._onboard_state["plan_host"] = self._selected_host()
        self._onboard_state["plan_args"] = plan_args
        self._spawn(self._hl(*plan_args), self._on_apply_plan_done)

    def _on_apply_plan_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        payload = self._parse_json_payload(raw)
        if code != 0 or not payload:
            detail = err.decode("utf-8", "replace").strip().splitlines()
            reason = detail[-1] if detail else f"exit {code}"
            self._state_label.setText(f"Plano falhou: {reason}")
            return
        # REV-006: the plan must belong to the captured host. A late
        # callback generated for another target is dropped, and a host
        # switch while the plan ran invalidates the reviewed plan.
        captured_host = str(self._onboard_state.get("plan_host") or "")
        plan_host = str(payload.get("hostAlias") or payload.get("host") or "local")
        if plan_host != (captured_host or "local"):
            self._onboard_state.pop("review_plan", None)
            self._state_label.setText("Plano é de outro host — gere um novo plano para o host selecionado")
            return
        if self._selected_host() != captured_host:
            self._onboard_state.pop("review_plan", None)
            self._state_label.setText("Host mudou durante o plano — revise e gere um novo plano")
            return
        plan_hash = json.dumps(self._plan_intent(payload), sort_keys=True)
        previous = self._onboard_state.get("review_plan")
        if previous is None:
            self._onboard_state["review_plan"] = plan_hash
            self._render_onboard_plan(payload)
            self._state_label.setText("Plano pronto — revise acima e pressione Aplicar de novo para executar")
            return
        if previous != plan_hash:
            self._onboard_state["review_plan"] = plan_hash
            self._render_onboard_plan(payload)
            self._state_label.setText("Plano mudou — revise de novo e pressione Aplicar para executar")
            return
        # UX-002: intent is stable, but the observed budget may have crossed
        # a limit since the review — execution would fail downstream.
        budget = payload.get("budget") if isinstance(payload.get("budget"), dict) else {}
        if str(budget.get("verdict") or "") == "fail":
            self._state_label.setText(
                "Recursos insuficientes agora — libere memória/disco ou revise o plano"
            )
            return
        self._onboard_state.pop("review_plan", None)
        # REV-007: execute exactly the reviewed plan (same profile), not a
        # re-derivation from current widget state.
        exec_args = ["prepare", "--json"]
        profile = (self._onboard_state.get("profile") or {}).get("profile") or ""
        if profile:
            exec_args += ["--profile", profile]
        self.run_cmd(exec_args, host=captured_host)

    @staticmethod
    def _plan_intent(payload: dict) -> dict:
        """UX-002: what a confirmation binds to is the reviewed INTENT —
        host, profile, apps, access, policy — not volatile telemetry.
        availableMB/diskAvailableMB drift by megabytes between renders; a
        1 MiB RAM change must never revoke the operator's review. Material
        changes (apps/host/profile/access) stay in the intent and still
        force a new review; a crossed resource limit is caught separately
        by the budget verdict at execution time."""
        return {k: v for k, v in payload.items() if k != "budget"}

    def _render_onboard_plan(self, payload: dict) -> None:
        # R01-003: budget-only profiles are stated, never implied — the
        # operator sees that the profile's services are NOT installed by
        # this plan before pressing apply again.
        if payload.get("profileInstallable") is False:
            note = str(payload.get("profileNote") or "sem receita de instalação")
            self._append(
                f"[plano] Perfil '{payload.get('profile')}' é apenas ORÇAMENTO: "
                f"este plano NÃO instala os serviços do perfil ({note}). "
                "Aplicativos vêm do catálogo.\n"
            )
        self._append(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")

    def _hl_for(self, alias: str, *parts: str) -> list[str]:
        args = ["server", "homelab"]
        if alias:
            args += ["--host", alias]
        args.extend(parts)
        return args

    def _hl(self, *parts: str) -> list[str]:
        return self._hl_for(self._selected_host(), *parts)

    def _on_host_changed(self) -> None:
        alias = self._selected_host()
        # REV-005/006: pairing and plan confirmation are bound to one host.
        # Switching the target invalidates them — an authorization made for
        # host A must never apply to host B. The flow rewinds to the pair
        # step so the new host is verified on its own.
        self._onboard_state.pop("review_plan", None)
        self._onboard_state.pop("plan_host", None)
        self._onboard_state.pop("plan_args", None)
        self._onboard_state.pop("pair", None)
        self._onboard_state.pop("pair_detail", None)
        self._onboard_confirmed = False
        # R01-002: an in-flight pairing belongs to the old host — its late
        # callback will be dropped by the captured-alias check; kill the
        # auto-advance and the captured alias right away.
        self._pair_advance = False
        self._pair_host = ""
        if self._onboard_step >= 1:
            self._onboard_step = 1
            self._refresh_onboard_label()
        if self._host_badge is not None:
            if alias:
                self._host_badge.setText("Remoto")
                self._host_badge.setProperty("state", "warning")
            else:
                self._host_badge.setText("Local")
                self._host_badge.setProperty("state", "success")
            self._host_badge.style().unpolish(self._host_badge)
            self._host_badge.style().polish(self._host_badge)
        if self._pair_btn is not None:
            self._pair_btn.setEnabled(bool(alias))
        if self._proc is None or self._proc.state() == QProcess.NotRunning:
            self.refresh_status()

    def refresh_hosts(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._spawn(["server", "homelab", "hosts", "list", "--json"], self._on_hosts_done)

    def _on_hosts_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        payload = self._parse_json_payload(raw)
        hosts = payload.get("hosts") if isinstance(payload.get("hosts"), list) else []
        current = self._selected_host()
        if self._host_combo is not None:
            self._host_combo.blockSignals(True)
            self._host_combo.clear()
            self._host_combo.addItem("Este computador (local)", "")
            self._hosts = {}
            for host in hosts:
                if not isinstance(host, dict):
                    continue
                alias = str(host.get("alias") or "")
                if not alias:
                    continue
                self._hosts[alias] = host
                label = f"{alias} ({host.get('user')}@{host.get('host')})"
                self._host_combo.addItem(label, alias)
            idx = self._host_combo.findData(current)
            self._host_combo.setCurrentIndex(idx if idx >= 0 else 0)
            self._host_combo.blockSignals(False)
        self.refresh_status()

    def start_pair(self, generate: bool = False) -> None:
        # PZ-AUD-014: pairing runs through `hosts pair`, which honors the
        # registry port, reuses or generates keys explicitly, and reports
        # first-contact with the exact port-bearing command.
        alias = self._selected_host()
        if not alias:
            QMessageBox.information(self, "Parear", "Selecione um host remoto.")
            return
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            self._state_label.setText("Já existe operação em andamento — aguarde")
            return
        self._state_label.setText("Pareando chave SSH…")
        args = ["server", "homelab", "hosts", "pair", alias, "--json"]
        if generate:
            args.append("--generate")
        self._pair_host = alias
        proc = QProcess(self)
        self._setup_proc(proc)
        # R01-002: capture the alias the pairing was started for — the
        # combo selection may change while the process runs.
        proc.finished.connect(
            lambda code, p=proc, a=alias: self._on_pair_done(
                code, bytes(p.readAllStandardOutput()), bytes(p.readAllStandardError()), a
            )
        )
        proc.start(str(self.root / "linux" / "pz"), args)
        self._proc = proc

    def _on_pair_done(self, code: int, out: bytes, err: bytes, alias: str | None = None) -> None:
        if self._proc is not None:
            self._cancel_timeout(self._proc)
        self._proc = None
        payload = self._parse_json_payload(out)
        # R01-002: a late pairing result belongs to the host it was started
        # for (captured at spawn; the envelope hostAlias confirms it). If
        # the selection changed meanwhile, the result is dropped: nothing
        # is ingested, nothing advances, no follow-up runs on the new host.
        result_host = str(payload.get("hostAlias") or alias or "")
        selected = self._selected_host()
        if alias is not None and result_host != selected:
            self._pair_advance = False
            self._state_label.setText("Pareamento era para outro host — pareie o host selecionado")
            return
        state = str(payload.get("state", ""))
        if code == 0 and payload.get("paired"):
            self.onboard_ingest_pair(True, {"alias": result_host})
            if self._pair_advance:
                self._pair_advance = False
                if self._onboard_step < len(self.ONBOARD_STEPS) - 1:
                    self._onboard_step += 1
                self._refresh_onboard_label()
            self._state_label.setText("Chave copiada — testando…")
            self.run_cmd(["hosts", "ping", self._selected_host(), "--json"])
            return
        self._pair_advance = False
        self.onboard_ingest_pair(False)
        if state == "missing-key":
            want = QMessageBox.question(
                self, "Parear",
                "Nenhuma chave SSH encontrada.\n"
                "Gerar uma chave ed25519 nova (sem senha, só para automação)?",
                QMessageBox.Yes | QMessageBox.No,
            )
            if want == QMessageBox.Yes:
                self.start_pair(generate=True)
            else:
                self._state_label.setText("Pareamento cancelado — sem chave")
            return
        guidance = str(payload.get("guidance") or "")
        reason = str(payload.get("reason") or "")
        detail = "\n".join(part for part in (guidance, reason) if part)
        QMessageBox.warning(
            self, "Parear",
            "Não foi possível concluir o pareamento.\n"
            f"{detail}\n\nPrimeiro acesso sempre pede a senha no terminal.",
        )
        self._state_label.setText("Pareamento precisa de primeiro acesso")

    def refresh_status(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._state_label.setText("carregando…")
        self._spawn(self._hl("status", "--json"), self._on_status_done)

    def refresh_profiles(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._spawn(self._hl("profiles", "--json"), self._on_profiles_done)

    def refresh_apps(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._spawn(self._hl("apps", "list", "--json"), self._on_apps_done)

    def _on_apps_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        payload = self._parse_json_payload(raw)
        apps = payload.get("apps") if isinstance(payload.get("apps"), list) else []
        self._rebuild_cards(apps)
        self.refresh_profiles()

    def _clear_layout(self, layout: QGridLayout) -> None:
        while layout.count():
            item = layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()

    def _rebuild_cards(self, apps: list) -> None:
        if self._cards_layout is None:
            return
        self._clear_layout(self._cards_layout)
        self._card_buttons = []
        for index, app in enumerate(apps):
            if not isinstance(app, dict):
                continue
            self._cards_layout.addWidget(self._make_app_card(app), index // 2, index % 2)

    def _make_app_card(self, app: dict) -> QFrame:
        frame = QFrame()
        frame.setObjectName("homelabAppCard")
        frame.setFrameShape(QFrame.StyledPanel)
        frame.setAccessibleName(f"Aplicativo {app.get('title') or app.get('key')}")
        lay = QVBoxLayout(frame)
        title = QLabel(f"{app.get('title') or app.get('key')} · {app.get('layer', '')}")
        title.setStyleSheet("font-weight:700")
        lay.addWidget(title)
        running = bool(app.get("running"))
        enabled = bool(app.get("enabled"))
        if running:
            state = "ligado"
        elif enabled:
            state = "ativado · parado"
        else:
            state = "desligado"
        lay.addWidget(QLabel(f"{state} · {app.get('budgetMB', '—')} MiB"))
        url = str(app.get("url") or "")
        if url:
            lay.addWidget(QLabel(url))
        gov = app.get("governor") if isinstance(app.get("governor"), dict) else {}
        verdict = str(gov.get("verdict") or "")
        if verdict == "fail":
            reasons = gov.get("reasons") if isinstance(gov.get("reasons"), list) else []
            reason = str(reasons[0]) if reasons else "orçamento insuficiente"
            warn = QLabel(reason)
            warn.setWordWrap(True)
            warn.setObjectName("serviceState")
            warn.setProperty("state", "warning")
            lay.addWidget(warn)
        key = str(app.get("key") or "")
        row = QHBoxLayout()
        preview = QPushButton("Prévia")
        preview.setToolTip("Mostra o plano sem alterar o host.")
        action = "disable" if enabled else "enable"
        preview.clicked.connect(
            lambda _=False, k=key, a=action: self.run_cmd(
                ["apps", a, k, "--dry-run", "--json"]
            )
        )
        toggle = QPushButton("Desligar" if enabled else "Ligar")
        toggle.setToolTip("Ativa ou desativa só este aplicativo.")
        if verdict == "fail" and not enabled:
            toggle.setEnabled(False)
        toggle.clicked.connect(
            lambda _=False, k=key, a=action: self.run_cmd(["apps", a, k, "--json"])
        )
        update = QPushButton("Atualizar")
        update.setToolTip("Atualiza a imagem pinada deste aplicativo.")
        update.clicked.connect(
            lambda _=False, k=key: self.run_cmd(["apps", "update", k, "--json"])
        )
        for btn in (preview, toggle, update):
            row.addWidget(btn)
            self._card_buttons.append(btn)
        lay.addLayout(row)
        return frame

    def _last_backup(self) -> str:
        last = self._last_status.get("backupState", {}).get("lastBackup")
        return (last or {}).get("latest", "") if isinstance(last, dict) else ""

    def _apply_status(self, raw: bytes) -> None:
        payload = self._parse_json_payload(raw)
        if not payload:
            self._state_label.setText("falha ao ler status")
            return
        self._last_status = payload
        ready = bool(payload.get("ready"))
        degraded = bool(payload.get("degraded"))
        mode = (payload.get("accessMode") or {}).get("effective", "?")
        state_key = str(payload.get("state") or "")
        headline = {
            "ready": "Saudável",
            "needs-config": "Ainda não configurado",
            "stopped": "Desligado · dados preservados",
            "degraded": "Atenção necessária",
            "unhealthy": "Saúde insuficiente",
        }.get(state_key)
        if not headline:
            headline = "pronto" if ready else "não pronto"
            if degraded:
                headline += " · degradado"
        self._state_label.setText(f"{headline} · acesso={mode}")
        self._set_state(
            "success" if ready else "warning"
            if degraded or state_key in {"degraded", "unhealthy"} else "error"
        )

        reasons = payload.get("reasons") or []
        if reasons and not ready:
            bullets = "\n".join(f"- {r}" for r in reasons[:4])
            self._append(f"[status] Motivos:\n{bullets}\n")
        next_action = payload.get("nextAction")
        if isinstance(next_action, str) and next_action.strip():
            self._append(f"[status] Próximo passo: {next_action}\n")

        apps = (payload.get("stack") or {}).get("apps", [])
        if not apps:
            self._table.setRowCount(1)
            placeholder = QTableWidgetItem(
                "Nada rodando ainda — clique Subir para preparar o servidor."
            )
            placeholder.setFlags(Qt.ItemIsEnabled)
            self._table.setItem(0, 0, placeholder)
            for col in range(1, 5):
                self._table.setItem(0, col, QTableWidgetItem(""))
            return
        self._table.setRowCount(len(apps))
        for row, app in enumerate(apps):
            for col, key in enumerate(("key", "layer", "bind", "url", "running")):
                item = QTableWidgetItem(str(app.get(key, "—")))
                if key == "running" and item.text() == "True":
                    item.setText("sim")
                    item.setForeground(Qt.GlobalColor.green)
                elif key == "running":
                    item.setText("não")
                    item.setForeground(Qt.GlobalColor.red)
                self._table.setItem(row, col, item)

        budget = payload.get("resourceBudget")
        if budget:
            self._budget_label.setText(
                f"{budget.get('budgetMB')} / {budget.get('availableMB')} MiB "
                f"[{budget.get('verdict')}]"
            )
        else:
            self._budget_label.setText("sem perfil ativo")
        self.refresh_apps()

    def _on_status_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        if b"{" in raw:
            self._apply_status(raw)
            return
        self._state_label.setText("não foi possível diagnosticar agora")
        detail = err.decode("utf-8", "replace").strip().splitlines()
        reason = detail[-1] if detail else f"exit {code}"
        self._append(
            f"[status] Diagnóstico falhou ({reason}).\n"
            "Verifique se o Docker está ativo e clique Atualizar.\n"
        )

    def _on_profiles_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        try:
            payload: dict = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            return
        profiles = payload.get("profiles", []) or []
        current = self._last_status.get("profile") or ""
        if profiles and self._profile_combo.count() != len(profiles):
            self._profile_combo.clear()
            self._profile_map.clear()
            for p in profiles:
                key = str(p.get("key", ""))
                maturity = str(p.get("maturity", ""))
                installable = bool(p.get("installable", False))
                self._profile_map[key] = str(p.get("title", key))
                label = f"{p['title']} ({key})"
                if maturity and maturity not in ("stable",):
                    label += f" [{maturity}]"
                self._profile_combo.addItem(label, key)
                if not installable:
                    self._profile_map[key + ":note"] = str(
                        p.get("installNote", "preview: budget only, no install recipe yet")
                    )
        idx = self._profile_combo.findData(current)
        if idx >= 0:
            self._profile_combo.setCurrentIndex(idx)

    # -- profile ------------------------------------------------------------
    def apply_profile(self) -> None:
        key = self._profile_combo.currentData()
        if not key:
            QMessageBox.warning(self, "Perfil", "Selecione um perfil.")
            return
        # PZ-AUD-022: applying sets the RAM budget; installable=false
        # profiles have no install recipe, and the user must know that.
        note = self._profile_map.get(key + ":note", "")
        if note:
            QMessageBox.information(
                self, "Perfil",
                f"Perfil '{key}' aplicado como orçamento. {note}",
            )
        self.run_cmd(["profile", "set", key])

    def show_policy(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        proc = QProcess(self)
        self._setup_proc(proc)

        def on_finished(code: int) -> None:
            self._cancel_timeout(proc)
            if self._proc is proc:
                self._proc = None
            self._render_policy(code, bytes(proc.readAllStandardOutput()))

        proc.finished.connect(on_finished)
        proc.start(str(self.root / "linux" / "server" / "ai-policy-broker.sh"), ["status"])
        self._proc = proc

    def _render_policy(self, code: int, raw: bytes) -> None:
        try:
            payload: dict = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            QMessageBox.warning(
                self, "Política",
                "Policy broker indisponível agora.\n\n"
                "Tente novamente; se persistir, execute:\n"
                "linux/pz server ai-policy status",
            )
            return
        denied = ", ".join(payload.get("deniedActions", []) or []) or "nenhuma"
        QMessageBox.information(
            self, "Política AI",
            f"modo: {payload.get('mode')}\nnegadas: {denied}",
        )

    # -- actions ------------------------------------------------------------
    def run_cmd(self, args: list[str], host: str | None = None) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            self._state_label.setText("Já existe operação em andamento — aguarde")
            return
        if getattr(getattr(self, "runner", None), "running", False):
            self._state_label.setText("Já existe operação global em andamento — aguarde")
            return
        self._output.clear()
        self._bar.show()
        proc = QProcess(self)
        self._setup_proc(proc)
        proc.readyReadStandardOutput.connect(
            lambda: self._append(str(bytes(proc.readAllStandardOutput()), "utf-8", "replace"))
        )
        proc.readyReadStandardError.connect(
            lambda: self._append_log(bytes(proc.readAllStandardError()))
        )
        proc.finished.connect(self._on_cmd_done)
        proc.errorOccurred.connect(lambda err: self._on_cmd_error(err, proc))
        if args and args[0] == "hosts":
            argv = ["server", "homelab", *args]
        else:
            argv = self._hl_for(self._selected_host() if host is None else host, *args)
        proc.start(str(self.root / "linux" / "pz"), argv)
        self._proc = proc

    def block_while_running(self, running: bool) -> None:
        for btn in self._action_buttons:
            btn.setEnabled(not running)
        for btn in self._card_buttons:
            btn.setEnabled(not running)
        self._profile_set.setEnabled(not running)

    def _on_cmd_done(self, code: int) -> None:
        proc = self._proc
        if proc is not None:
            self._cancel_timeout(proc)
            if proc.state() == QProcess.NotRunning:
                err = bytes(proc.readAllStandardError())
                if err.strip():
                    self._append_log(err)
        self._bar.hide()
        confirm = self._pending_confirm_file
        if confirm is not None:
            # A frase digitada vive só o necessário; nada de segredo-restos.
            try:
                confirm.unlink(missing_ok=True)
            except OSError:
                pass
            self._pending_confirm_file = None
        if code == 0:
            self._state_label.setText("Concluído")
            self._set_state("success")
        else:
            self._state_label.setText("Falhou — veja a saída abaixo")
            self._set_state("error")
        QTimer.singleShot(300, self.refresh_status)

    def _on_cmd_error(self, error: QProcess.ProcessError, proc: QProcess) -> None:
        if error == QProcess.FailedToStart:
            self._bar.hide()
            self._state_label.setText("não foi possível iniciar o comando")
            if self._proc is proc:
                self._proc = None

    def _append_log(self, data: bytes) -> None:
        text = str(data, "utf-8", "replace").strip()
        if text:
            self._append(f"[stderr] {text}\n")

    def _append(self, text: str) -> None:
        self._output.insertPlainText(text)
        self._output.verticalScrollBar().setValue(self._output.verticalScrollBar().maximum())

    def pick_restore(self) -> None:
        last = self._last_backup()
        if not last:
            QMessageBox.warning(
                self, "Restaurar",
                "Nenhum backup anterior localizado.\n"
                "Clique em Copiar segurança para criar o primeiro.",
            )
            return
        self._start_restore_flow(last)

    # ------------------------------------------------- restore assistido
    @staticmethod
    def _confirmation_phrase(source: str) -> str:
        return f"RESTAURAR {Path(source).name}"

    def _start_restore_flow(self, source: str) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            self._state_label.setText("Já existe operação em andamento — aguarde")
            return
        self._state_label.setText("Restaurar · verificando backup…")
        self._bar.show()
        proc = QProcess(self)
        self._setup_proc(proc)
        proc.finished.connect(
            lambda code, p=proc, src=source: self._on_restore_plan_done(
                code, bytes(p.readAllStandardOutput()), src
            )
        )
        proc.errorOccurred.connect(lambda _e, p=proc: self._restore_failed(p, "não iniciou"))
        proc.start(str(self.root / "linux" / "pz"),
                   self._hl("restore", "--source", source, "--plan"))
        self._proc = proc

    def _restore_failed(self, proc: QProcess, why: str) -> None:
        self._cancel_timeout(proc)
        if self._proc is proc:
            self._proc = None
        self._bar.hide()
        self._set_state("error")
        self._state_label.setText("Restaurar · falhou antes da prévia")
        self._append(f"[restore] {why}\n")

    def _parse_plan(self, raw: bytes) -> dict:
        payload = self._parse_json_payload(raw)
        if isinstance(payload, dict) and payload.get("action") == "restore":
            return payload
        return {}

    def _restore_summary_text(self, plan: dict, source: str) -> str:
        checks = plan.get("checks") or []
        passed = sum(1 for c in checks if isinstance(c, dict) and c.get("ok"))
        volumes = [str(v) for v in (plan.get("volumesAffected") or [])]
        lines = [
            f"Origem: {source}",
            f"Verificação: {'aprovada' if plan.get('verified') else 'FALHOU'}"
            f" ({passed}/{len(checks)} provas)",
            f"Arquivos de volume: {len(plan.get('archives') or [])}",
            "Volumes substituídos: " + (", ".join(volumes[:6]) or "—")
            + ("…" if len(volumes) > 6 else ""),
            "",
            "Antes de aplicar, o PhaseZero faz um pré-backup automático",
            "dos volumes atuais (rollback possível em caso de falha).",
        ]
        return "\n".join(lines)

    def _on_restore_plan_done(self, code: int, raw: bytes, source: str) -> None:
        self._cancel_timeout(self._proc) if self._proc is not None else None
        if self._proc is not None and self._proc.state() == QProcess.NotRunning:
            self._proc = None
        self._bar.hide()
        plan = self._parse_plan(raw)
        if code != 0 or not plan:
            self._set_state("error")
            self._state_label.setText("Restaurar · prévia indisponível")
            self._append("[restore] Não foi possível gerar a prévia do restore.\n")
            return
        if not plan.get("verified"):
            QMessageBox.critical(
                self, "Restaurar",
                "Este backup NÃO passou na verificação (checksums/manifesto).\n"
                "Nada foi alterado. Gere um novo backup com Copiar segurança.",
            )
            return

        phrase = self._confirmation_phrase(source)
        dialog = QMessageBox(self)
        dialog.setIcon(QMessageBox.Warning)
        dialog.setWindowTitle("Restaurar Homelab")
        dialog.setText("Restauração assistida — os volumes serão SUBSTITUÍDOS.")
        dialog.setInformativeText(self._restore_summary_text(plan, source))
        confirmation = QPlainTextEdit()
        confirmation.setPlaceholderText(f"Digite exatamente: {phrase}")
        confirmation.setAccessibleName("Confirmação da restauração")
        confirmation.setMaximumHeight(64)
        dialog.layout().addWidget(confirmation)
        cancel = dialog.addButton("Voltar", QMessageBox.RejectRole)
        apply_btn = dialog.addButton("Aplicar restauração", QMessageBox.AcceptRole)
        apply_btn.setObjectName("dangerButton")
        apply_btn.setEnabled(False)
        confirmation.textChanged.connect(
            lambda: apply_btn.setEnabled(confirmation.toPlainText().strip() == phrase)
        )
        dialog.setDefaultButton(cancel)
        dialog.exec()
        if dialog.clickedButton() is not apply_btn:
            self._state_label.setText("Restaurar · cancelado")
            return
        confirm_file = self._write_confirm_file(source, phrase)
        if confirm_file is None:
            QMessageBox.critical(self, "Restaurar", "Não foi possível gravar o arquivo de confirmação.")
            return
        self._pending_confirm_file = confirm_file
        self.run_cmd(["restore", "--source", source, "--confirm-file", str(confirm_file)])

    def _write_confirm_file(self, source: str, phrase: str) -> Path | None:
        state_dir = (
            Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
            / "phasezero" / "homelab"
        )
        try:
            state_dir.mkdir(parents=True, exist_ok=True)
            target = state_dir / f"confirm-{Path(source).name}.txt"
            target.write_text(f"{phrase}\n", encoding="utf-8")
            target.chmod(0o600)
            return target
        except OSError:
            return None
