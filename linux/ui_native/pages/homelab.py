from __future__ import annotations

import json
import subprocess

from PySide6.QtCore import QProcess, Qt, QTimer
from PySide6.QtWidgets import (
    QComboBox, QFileDialog, QGroupBox, QHBoxLayout, QHeaderView,
    QLabel, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton,
    QTableWidget, QTableWidgetItem, QVBoxLayout,
)

from .base import BasePage


class HomelabPage(BasePage):
    """Homelab Player: live stack status, profile slot, governor budget and
    one-click plan/up/down/backup/verify/restore backed by linux/pz."""

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
            ("Up", lambda: self.run_cmd(["up"])),
            ("Down", lambda: self.run_cmd(["down"])),
            ("Backup", lambda: self.run_cmd(["backup"])),
            ("Verify", lambda: self.run_cmd(["backup", "verify", "--source", self._last_backup()])),
            ("Restore", self.pick_restore),
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
    def _pz(self, args: list[str]) -> bytes:
        return subprocess.run(
            [str(self.root / "linux" / "pz"), "server", "homelab", *args],
            capture_output=True,
        ).stdout

    def refresh_status(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._state_label.setText("carregando…")
        proc = QProcess(self)
        proc.setProcessChannelMode(QProcess.MergedChannels)
        proc.finished.connect(self._on_status_done)
        proc.start(str(self.root / "linux" / "pz"),
                   ["server", "homelab", "status", "--json"])
        self._proc = proc

    def _last_backup(self) -> str:
        data = self._latest_json()
        if not data:
            return ""
        last = data.get("backupState", {}).get("lastBackup")
        return (last or {}).get("latest", "") if isinstance(last, dict) else ""

    def _latest_json(self) -> dict:
        raw = self._pz(["status", "--json"])
        try:
            text = raw.decode("utf-8", "replace")
        except Exception:
            return {}
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("{"):
                try:
                    return json.loads(line)
                except Exception:
                    continue
        return {}

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
        self._populate_profiles()

    def _on_status_done(self, code: int) -> None:
        proc = self._proc
        self._proc = None
        raw = bytes(proc.readAll()) if proc else b""
        if code == 0 or b"{" in raw:
            self._apply_status(raw)
        else:
            self._state_label.setText("status indisponível")

    # -- profile ------------------------------------------------------------
    def _populate_profiles(self) -> None:
        raw = self._pz(["profile", "list"])
        try:
            payload = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            return
        current = (self._latest_json().get("profile") or "") or ""
        profiles = payload.get("profiles", [])
        if not profiles:
            return
        if self._profile_combo.count() != len(profiles):
            self._profile_combo.clear()
            for p in profiles:
                self._profile_map[str(p["key"])] = str(p["title"])
                self._profile_combo.addItem(f"{p['title']} ({p['key']})", p["key"])
        idx = self._profile_combo.findData(current)
        if idx >= 0:
            self._profile_combo.setCurrentIndex(idx)

    def apply_profile(self) -> None:
        key = self._profile_combo.currentData()
        if not key:
            QMessageBox.warning(self, "Perfil", "Selecione um perfil.")
            return
        self.run_cmd(["profile", "set", key])

    def show_policy(self) -> None:
        try:
            out = subprocess.run(
                [str(self.root / "linux" / "server" / "ai-policy-broker.sh"), "status"],
                capture_output=True, text=True,
            ).stdout
            payload = json.loads(out)
        except Exception:
            QMessageBox.warning(self, "Política", "policy broker indisponível")
            return
        denied = ", ".join(payload.get("deniedActions", [])) or "nenhuma"
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
        proc.setProcessChannelMode(QProcess.MergedChannels)
        proc.readyReadStandardOutput.connect(
            lambda: self._append(str(bytes(proc.readAllStandardOutput()), "utf-8", "replace"))
        )
        proc.finished.connect(self._on_cmd_done)
        proc.start(str(self.root / "linux" / "pz"),
                   ["server", "homelab", *args])
        self._proc = proc

    def _on_cmd_done(self, code: int) -> None:
        self._bar.hide()
        self._state_label.setText(f"comando concluído (exit {code})")
        QTimer.singleShot(300, self.refresh_status)

    def _append(self, text: str) -> None:
        self._output.insertPlainText(text)
        self._output.verticalScrollBar().setValue(self._output.verticalScrollBar().maximum())

    def pick_restore(self) -> None:
        path, _ = QFileDialog.getExistingDirectory(
            self, "Selecionar backup", self._last_backup()
        )
        if not path:
            return
        if QMessageBox.question(
            self, "Restaurar", f"Restaurar backup em {path}? Os volumes serão substituídos."
        ) != QMessageBox.StandardButton.Yes:
            return
        self.run_cmd(["restore", "--source", path, "--yes"])