from __future__ import annotations

import json
import os
from pathlib import Path

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
        self._green = QLabel("●")
        self._green.setObjectName("serviceState")
        self._proc: QProcess | None = None
        self._profile_map: dict[str, str] = {}
        self._last_status: dict = {}
        self._timeouts: dict[int, QTimer] = {}
        self._action_buttons: list[QPushButton] = []
        self._pending_confirm_file: Path | None = None

    # ------------------------------------------------------------- theming
    def _set_state(self, state: str) -> None:
        """Cor via tema (objectName+property), nunca stylesheet cru."""
        for label in (self._state_label, self._green):
            label.setProperty("state", state)
            label.style().unpolish(label)
            label.style().polish(label)

    def build(self) -> None:
        self._layout.setSpacing(12)

        header = QHBoxLayout()
        title = QLabel("Homelab Player")
        title.setStyleSheet("font-size:17px;font-weight:700")
        header.addWidget(title)
        header.addStretch(1)
        self._state_label = QLabel("—")
        self._state_label.setObjectName("serviceState")
        header.addWidget(self._state_label)
        header.addWidget(self._green)
        refresh = QPushButton("Atualizar")
        refresh.setAccessibleName("Atualizar status do Homelab")
        refresh.clicked.connect(self.refresh_status)
        header.addWidget(refresh)
        self._layout.addLayout(header)

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
        self._layout.addWidget(self._table, 1)

        # Profile + governor ------------------------------------------------
        profile_box = QGroupBox("Perfil e orçamento")
        pslot = QHBoxLayout()
        self._profile_combo = QComboBox()
        profile_caption = QLabel("Perfil:")
        profile_caption.setBuddy(self._profile_combo)
        pslot.addWidget(profile_caption)
        pslot.addWidget(self._profile_combo, 1)
        self._profile_set = QPushButton("Aplicar perfil")
        self._profile_set.clicked.connect(self.apply_profile)
        pslot.addWidget(self._profile_set)
        budget_caption = QLabel("Orçamento:")
        self._budget_label = QLabel("—")
        budget_caption.setBuddy(self._budget_label)
        pslot.addWidget(budget_caption)
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
        self.refresh_profiles()

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
    def run_cmd(self, args: list[str]) -> None:
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
        proc.start(str(self.root / "linux" / "pz"), ["server", "homelab", *args])
        self._proc = proc

    def block_while_running(self, running: bool) -> None:
        for btn in self._action_buttons:
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
                   ["server", "homelab", "restore", "--source", source, "--plan"])
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
        for line in raw.decode("utf-8", "replace").splitlines():
            line = line.strip()
            if line.startswith("{"):
                try:
                    payload = json.loads(line)
                    if isinstance(payload, dict) and payload.get("action") == "restore":
                        return payload
                except Exception:
                    continue
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
