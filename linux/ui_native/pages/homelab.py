from __future__ import annotations

import json

from PySide6.QtCore import QProcess, Qt, QTimer
from PySide6.QtWidgets import (
    QComboBox, QGroupBox, QHBoxLayout, QHeaderView,
    QLabel, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton,
    QTableWidget, QTableWidgetItem, QVBoxLayout,
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
        self._green = QLabel()
        self._green.setStyleSheet("color:#7CFC98;font-weight:600")
        self._green.setText("●")
        self._proc: QProcess | None = None
        self._profile_map: dict[str, str] = {}
        self._last_status: dict = {}
        self._timeouts: dict[int, QTimer] = {}

    def build(self) -> None:
        self._layout.setSpacing(12)

        header = QHBoxLayout()
        title = QLabel("Homelab Player")
        title.setStyleSheet("font-size:17px;font-weight:700")
        header.addWidget(title)
        header.addStretch(1)
        self._state_label = QLabel("—")
        self._state_label.setStyleSheet("color:#a0b0c0")
        header.addWidget(self._state_label)
        header.addWidget(self._green)
        refresh = QPushButton("Atualizar")
        refresh.clicked.connect(self.refresh_status)
        header.addWidget(refresh)
        self._layout.addLayout(header)

        # Status table ------------------------------------------------------
        self._table = QTableWidget(0, 5)
        self._table.setHorizontalHeaderLabels(["Serviço", "Layer", "Bind", "URL", "Rodando"])
        header_view = self._table.horizontalHeader()
        header_view.setSectionResizeMode(QHeaderView.ResizeToContents)
        self._table.setEditTriggers(QTableWidget.NoEditTriggers)
        self._table.setSelectionMode(QTableWidget.NoSelection)
        self._layout.addWidget(self._table, 1)

        # Profile + governor ------------------------------------------------
        profile_box = QGroupBox("Perfil e orçamento")
        pslot = QHBoxLayout()
        self._profile_combo = QComboBox()
        pslot.addWidget(QLabel("Perfil:"))
        pslot.addWidget(self._profile_combo, 1)
        self._profile_set = QPushButton("Aplicar")
        self._profile_set.clicked.connect(self.apply_profile)
        pslot.addWidget(self._profile_set)
        pslot.addWidget(QLabel("Orçamento:"))
        self._budget_label = QLabel("—")
        pslot.addWidget(self._budget_label)
        policy = QPushButton("Política")
        policy.clicked.connect(self.show_policy)
        pslot.addWidget(policy)
        profile_box.setLayout(pslot)
        self._layout.addWidget(profile_box)

        # Actions -----------------------------------------------------------
        actions_box = QGroupBox("Ações")
        arow = QHBoxLayout()
        for label, fn in (
            ("Plan", lambda: self.run_cmd(["plan"])),
            ("Backup", lambda: self.run_cmd(["backup"])),
            ("Verify", lambda: self.run_cmd(["backup", "verify", "--source", self._last_backup()])),
            ("Restore", self.pick_restore),
            ("Repair", lambda: self.run_cmd(["repair"])),
            ("Resume", lambda: self.run_cmd(["up", "--resume"])),
        ):
            btn = QPushButton(label)
            btn.clicked.connect(fn)
            arow.addWidget(btn)
        actions_box.setLayout(arow)
        self._layout.addWidget(actions_box)

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
        self._layout.addWidget(out_group, 1)

        QTimer.singleShot(0, self.refresh_status)

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

    def refresh_status(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._state_label.setText("carregando…")
        self._spawn(["server", "homelab", "status", "--json"], self._on_status_done)

    def refresh_profiles(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._spawn(["server", "homelab", "profiles", "--json"], self._on_profiles_done)

    def _last_backup(self) -> str:
        last = self._last_status.get("backupState", {}).get("lastBackup")
        return (last or {}).get("latest", "") if isinstance(last, dict) else ""

    def _apply_status(self, raw: bytes) -> None:
        text = raw.decode("utf-8", "replace")
        payload: dict = {}
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("{"):
                try:
                    payload = json.loads(line)
                    break
                except Exception:
                    continue
        if not payload:
            self._state_label.setText("falha ao ler status")
            return
        self._last_status = payload
        ready = bool(payload.get("ready"))
        degraded = bool(payload.get("degraded"))
        mode = (payload.get("accessMode") or {}).get("effective", "?")
        state = f"{'ready' if ready else 'não pronto'} · acesso={mode}"
        if degraded:
            state += " · degradado"
        self._state_label.setText(state)
        self._green.setStyleSheet(
            "color:#7CFC98" if ready else "color:#e0a040" if degraded else "color:#e05555"
        )

        apps = (payload.get("stack") or {}).get("apps", [])
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
        self.refresh_profiles()

    def _on_status_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        if code == 0 or b"{" in raw:
            self._apply_status(raw)
        else:
            self._state_label.setText(f"status indisponível (exit {code})")

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
                self._profile_map[key] = str(p.get("title", key))
                self._profile_combo.addItem(f"{p['title']} ({key})", key)
        idx = self._profile_combo.findData(current)
        if idx >= 0:
            self._profile_combo.setCurrentIndex(idx)

    # -- profile ------------------------------------------------------------
    def apply_profile(self) -> None:
        key = self._profile_combo.currentData()
        if not key:
            QMessageBox.warning(self, "Perfil", "Selecione um perfil.")
            return
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
            QMessageBox.warning(self, "Política", "policy broker indisponível")
            return
        denied = ", ".join(payload.get("deniedActions", []) or []) or "nenhuma"
        QMessageBox.information(
            self, "Política AI",
            f"modo: {payload.get('mode')}\nnegadas: {denied}",
        )

    # -- actions ------------------------------------------------------------
    def run_cmd(self, args: list[str]) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
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
        proc.start(str(self.root / "linux" / "pz"), ["server", "homelab", *args])
        self._proc = proc

    def _on_cmd_done(self, code: int) -> None:
        proc = self._proc
        if proc is not None:
            self._cancel_timeout(proc)
            if proc.state() == QProcess.NotRunning:
                err = bytes(proc.readAllStandardError())
                if err.strip():
                    self._append_log(err)
        self._bar.hide()
        self._state_label.setText(f"comando concluído (exit {code})")
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
            QMessageBox.warning(self, "Restaurar", "Nenhum backup anterior localizado.")
            return
        path = last
        answer = QMessageBox.question(
            self, "Restaurar",
            f"Restaurar o backup verificado em:\n{path}\n\n"
            "Os volumes serão substituídos após validação de schema e checksums.",
            QMessageBox.Yes | QMessageBox.No, QMessageBox.No,
        )
        if answer != QMessageBox.Yes:
            return
        # restore runs in plan mode first; the CLI refuses to apply without an
        # explicit operator-written confirmation file. We never pass --yes.
        self.run_cmd(["restore", "--source", path, "--plan"])
