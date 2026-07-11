from __future__ import annotations

import json
from pathlib import Path

from PySide6.QtCore import QProcess, Qt
from PySide6.QtWidgets import (
    QAbstractItemView,
    QButtonGroup,
    QComboBox,
    QFileDialog,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QRadioButton,
    QScrollArea,
    QStackedWidget,
    QTableWidget,
    QTableWidgetItem,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import ActionListRow, AdvancedActionsPanel, SectionHeader
from .base import BasePage


_JOURNEYS = (
    (
        "Biblioteca de jogos",
        "Analisar, preparar, instalar e validar jogos por sistema.",
        "Abrir biblioteca",
    ),
    (
        "Emuladores e frontends",
        "Instalar, integrar e testar launchers e emuladores.",
        "Gerenciar emuladores",
    ),
    (
        "Arquivos do sistema",
        "Importar BIOS, firmware, keys e licenças obtidas legalmente.",
        "Gerenciar arquivos",
    ),
    (
        "Saúde e manutenção",
        "Diagnosticar integrações, reparar mídia e ajustar desempenho.",
        "Verificar ambiente",
    ),
)


class EmulationPage(BasePage):
    """Task-oriented emulation experience with a native library workflow."""

    def __init__(
        self,
        root: Path,
        runner: CommandRunner,
        actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.stack = QStackedWidget()
        self.stack.setObjectName("emulationJourneyStack")
        self.process: QProcess | None = None
        self.operation = ""
        self.scan_payload: dict = {}
        self.plan_payload: dict = {}
        self.operation_payload: dict = {}
        self.selected_files: list[str] = []
        self.source_path: QLineEdit | None = None
        self.source_stack: QStackedWidget | None = None
        self.source_group: QButtonGroup | None = None
        self.step_labels: list[QLabel] = []
        self.summary_labels: dict[str, QLabel] = {}
        self.table: QTableWidget | None = None
        self.filter_combo: QComboBox | None = None
        self.detail: QFrame | None = None
        self.detail_title: QLabel | None = None
        self.detail_body: QLabel | None = None
        self.workflow_status: QLabel | None = None
        self.progress: QProgressBar | None = None
        self.analyze_button: QPushButton | None = None
        self.plan_button: QPushButton | None = None
        self.apply_button: QPushButton | None = None
        self.verify_button: QPushButton | None = None
        self.rollback_button: QPushButton | None = None
        self.cancel_button: QPushButton | None = None
        self.health_status: QLabel | None = None
        self.status_loader.status_ready.connect(self._health_ready)
        self.status_loader.status_failed.connect(self._health_failed)

    def build(self) -> None:
        self.stack.addWidget(self._landing())
        self.stack.addWidget(self._library_workspace())
        self.stack.addWidget(self._action_workspace(
            "Emuladores e frontends",
            ("frontend", "emudeck", "retrodeck", "launchbox", "srm", "eden", "citron", "hydra"),
        ))
        self.stack.addWidget(self._action_workspace(
            "Arquivos do sistema",
            ("bios", "keys", "firmware", "ps3-game", "ps3-pkg", "ps3-rap"),
        ))
        self.stack.addWidget(self._action_workspace(
            "Saúde e manutenção",
            ("status", "doctor", "fix", "media", "performance", "controller", "shortcut", "shared"),
        ))
        self._layout.addWidget(self.stack, 1)
        # Every public action remains discoverable through global search. The
        # task workspaces represent common actions; the collapsed advanced
        # panel owns the remainder without adding another button wall.
        for action in self.actions:
            self.mark_represented(action)

    def _landing(self) -> QWidget:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(2, 2, 10, 16)
        layout.setSpacing(18)

        health = QFrame()
        health.setObjectName("contextStatus")
        health_row = QHBoxLayout(health)
        health_row.setContentsMargins(16, 10, 16, 10)
        heading = QLabel("Ecossistema de emulação")
        heading.setObjectName("contextStatusHeading")
        status = QLabel("Saúde: aguardando verificação")
        status.setObjectName("contextStatusText")
        status.setWordWrap(True)
        self.health_status = status
        health_row.addWidget(heading)
        health_row.addWidget(status, 1)
        doctor = QPushButton("Executar diagnóstico")
        doctor.setObjectName("secondaryButton")
        doctor.setMinimumHeight(48)
        doctor.clicked.connect(lambda: self._request_by_id("emulation.doctor"))
        health_row.addWidget(doctor)
        layout.addWidget(health)

        layout.addWidget(SectionHeader(
            "O que você quer fazer?",
            "Escolha uma jornada. Comandos técnicos continuam disponíveis em Avançado e na busca.",
        ))
        grid = QGridLayout()
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        for index, (title, description, cta) in enumerate(_JOURNEYS):
            card = QFrame()
            card.setObjectName("journeyCard")
            card_layout = QVBoxLayout(card)
            card_layout.setContentsMargins(18, 16, 18, 16)
            card_layout.setSpacing(8)
            title_label = QLabel(title)
            title_label.setObjectName("cardTitle")
            copy = QLabel(description)
            copy.setObjectName("cardDescription")
            copy.setWordWrap(True)
            button = QPushButton(cta)
            button.setObjectName("primaryButton" if index == 0 else "secondaryButton")
            button.setMinimumHeight(48)
            button.setAccessibleDescription(description)
            button.clicked.connect(lambda _checked=False, target=index + 1: self.stack.setCurrentIndex(target))
            card_layout.addWidget(title_label)
            card_layout.addWidget(copy, 1)
            card_layout.addWidget(button, 0, Qt.AlignLeft)
            grid.addWidget(card, index // 2, index % 2)
        grid.setColumnStretch(0, 1)
        grid.setColumnStretch(1, 1)
        layout.addLayout(grid)

        legacy = [action for action in self.actions if ".library." not in action.id]
        advanced = AdvancedActionsPanel(legacy)
        advanced.requested.connect(self._select_legacy)
        layout.addWidget(advanced)
        layout.addStretch()
        scroll.setWidget(page)
        return scroll

    def finalize_action_coverage(self) -> None:
        """Journeys, advanced disclosure and global search own coverage."""

    def reload(self) -> None:
        action = self.by_id.get("emulation.status")
        if action is None or self.status_loader.running(action.id):
            return
        if self.health_status is not None:
            self.health_status.setText("Saúde: verificando…")
        self.status_loader.fetch_action(action)

    def _health_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if action_id != "emulation.status" or self.health_status is None:
            return
        status = "OK"
        if isinstance(parsed, dict):
            raw = str(parsed.get("status") or parsed.get("health") or "").casefold()
            if raw in {"fail", "error", "critical"}:
                status = "Requer atenção"
            elif raw in {"warn", "warning", "degraded"}:
                status = "Atenção"
        self.health_status.setText(f"Saúde: {status} · biblioteca e integrações verificadas")

    def _health_failed(self, action_id: str, message: str) -> None:
        if action_id == "emulation.status" and self.health_status is not None:
            self.health_status.setText(f"Saúde indisponível · {message[:160]}")

    def _back_header(self, title: str, description: str) -> tuple[QWidget, QVBoxLayout]:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(2, 2, 10, 14)
        layout.setSpacing(14)
        bar = QHBoxLayout()
        back = QPushButton("Voltar")
        back.setObjectName("secondaryButton")
        back.setMinimumHeight(48)
        back.clicked.connect(lambda: self.stack.setCurrentIndex(0))
        bar.addWidget(back)
        header = SectionHeader(title, description)
        bar.addWidget(header, 1)
        layout.addLayout(bar)
        return page, layout

    def _action_workspace(self, title: str, terms: tuple[str, ...]) -> QWidget:
        page, layout = self._back_header(title, "Ações agrupadas por objetivo e impacto.")
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        rows = QVBoxLayout(content)
        rows.setContentsMargins(0, 0, 6, 12)
        rows.setSpacing(0)
        matching = [
            action for action in self.actions
            if action.visibility != "advanced"
            and any(term in f"{action.id} {action.title}".casefold() for term in terms)
        ]
        for action in matching:
            row = ActionListRow(action)
            row.selected.connect(self._select_legacy)
            rows.addWidget(row)
        rows.addStretch()
        scroll.setWidget(content)
        layout.addWidget(scroll, 1)
        return page

    def _library_workspace(self) -> QWidget:
        page, layout = self._back_header(
            "Biblioteca de jogos",
            "Origem → análise segura → plano → execução → validação.",
        )

        stepper = QFrame()
        stepper.setObjectName("libraryStepper")
        steps = QHBoxLayout(stepper)
        steps.setContentsMargins(12, 8, 12, 8)
        for index, title in enumerate(("1  Origem", "2  Análise", "3  Plano", "4  Execução", "5  Validação")):
            label = QLabel(title)
            label.setObjectName("libraryStep")
            label.setProperty("state", "active" if index == 0 else "pending")
            label.setAlignment(Qt.AlignCenter)
            label.setMinimumHeight(38)
            steps.addWidget(label, 1)
            self.step_labels.append(label)
        layout.addWidget(stepper)

        origin = QFrame()
        origin.setObjectName("libraryOrigin")
        origin_layout = QVBoxLayout(origin)
        origin_layout.setContentsMargins(16, 14, 16, 14)
        origin_layout.setSpacing(10)
        origin_layout.addWidget(QLabel("Origem dos jogos", objectName="sectionHeading"))
        choices = QHBoxLayout()
        self.source_group = QButtonGroup(origin)
        for index, text in enumerate(("Toda biblioteca", "Uma pasta", "Arquivos específicos")):
            radio = QRadioButton(text)
            radio.setMinimumHeight(48)
            radio.setAccessibleName(text)
            self.source_group.addButton(radio, index)
            choices.addWidget(radio)
            radio.toggled.connect(lambda checked, value=index: self._source_changed(value) if checked else None)
            if index == 0:
                radio.setChecked(True)
        origin_layout.addLayout(choices)
        self.source_stack = QStackedWidget()
        library_note = QLabel("Usará ~/Emulation/roms e integrações detectadas.")
        library_note.setObjectName("cardDescription")
        self.source_stack.addWidget(library_note)
        self.source_path = QLineEdit()
        self.source_path.setObjectName("librarySourcePath")
        self.source_path.setReadOnly(True)
        self.source_path.setPlaceholderText("Nenhuma pasta selecionada")
        self.source_stack.addWidget(self._picker_row(self.source_path, False))
        files_path = QLineEdit()
        files_path.setObjectName("libraryFilesPath")
        files_path.setReadOnly(True)
        files_path.setPlaceholderText("Nenhum arquivo selecionado")
        self.source_stack.addWidget(self._picker_row(files_path, True))
        origin_layout.addWidget(self.source_stack)
        run_row = QHBoxLayout()
        self.workflow_status = QLabel("Pronto para analisar sem alterar arquivos.")
        self.workflow_status.setObjectName("contextStatusText")
        self.workflow_status.setWordWrap(True)
        self.analyze_button = QPushButton("Analisar")
        self.analyze_button.setObjectName("primaryButton")
        self.analyze_button.setMinimumHeight(48)
        self.analyze_button.clicked.connect(self._scan)
        self.cancel_button = QPushButton("Cancelar")
        self.cancel_button.setObjectName("secondaryButton")
        self.cancel_button.setMinimumHeight(48)
        self.cancel_button.setEnabled(False)
        self.cancel_button.clicked.connect(self._cancel_process)
        run_row.addWidget(self.workflow_status, 1)
        run_row.addWidget(self.cancel_button)
        run_row.addWidget(self.analyze_button)
        origin_layout.addLayout(run_row)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.hide()
        origin_layout.addWidget(self.progress)
        layout.addWidget(origin)

        summary = QFrame()
        summary.setObjectName("moduleFacts")
        summary_layout = QHBoxLayout(summary)
        summary_layout.setContentsMargins(10, 8, 10, 8)
        for key, title in (
            ("games", "Jogos"), ("ready", "Prontos"),
            ("actionsRecommended", "Requer ação"), ("blocked", "Bloqueados"),
            ("unknown", "Não reconhecidos"),
        ):
            cell = QWidget()
            cell_layout = QVBoxLayout(cell)
            cell_layout.setContentsMargins(6, 0, 6, 0)
            value = QLabel("—")
            value.setObjectName("moduleFactValue")
            label = QLabel(title)
            label.setObjectName("moduleFactLabel")
            cell_layout.addWidget(value)
            cell_layout.addWidget(label)
            summary_layout.addWidget(cell, 1)
            self.summary_labels[key] = value
        layout.addWidget(summary)

        controls = QHBoxLayout()
        controls.addWidget(QLabel("Mostrar:"))
        self.filter_combo = QComboBox()
        self.filter_combo.addItem("Todos", "all")
        self.filter_combo.addItem("Prontos", "ready")
        self.filter_combo.addItem("Requer ação", "action")
        self.filter_combo.addItem("Bloqueados", "blocked")
        self.filter_combo.addItem("Não reconhecidos", "unknown")
        self.filter_combo.currentIndexChanged.connect(self._filter_rows)
        controls.addWidget(self.filter_combo)
        controls.addStretch()
        self.plan_button = QPushButton("Criar plano")
        self.plan_button.setObjectName("secondaryButton")
        self.plan_button.setMinimumHeight(48)
        self.plan_button.setEnabled(False)
        self.plan_button.clicked.connect(self._plan)
        self.apply_button = QPushButton("Aplicar plano")
        self.apply_button.setObjectName("primaryButton")
        self.apply_button.setMinimumHeight(48)
        self.apply_button.setEnabled(False)
        self.apply_button.clicked.connect(self._apply)
        controls.addWidget(self.plan_button)
        controls.addWidget(self.apply_button)
        layout.addLayout(controls)

        body = QHBoxLayout()
        self.table = QTableWidget()
        self.table.setObjectName("historyTable")
        self.table.setColumnCount(5)
        self.table.setHorizontalHeaderLabels(("Jogo", "Sistema", "Origem", "Destino", "Estado"))
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.setAlternatingRowColors(True)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for column in range(1, 5):
            self.table.horizontalHeader().setSectionResizeMode(column, QHeaderView.ResizeToContents)
        self.table.itemSelectionChanged.connect(self._show_detail)
        body.addWidget(self.table, 1)
        self.detail = QFrame()
        self.detail.setObjectName("actionInspector")
        self.detail.setFixedWidth(300)
        detail_layout = QVBoxLayout(self.detail)
        detail_layout.setContentsMargins(16, 16, 16, 16)
        self.detail_title = QLabel("Detalhes")
        self.detail_title.setObjectName("inspectorTitle")
        self.detail_title.setWordWrap(True)
        self.detail_body = QLabel("")
        self.detail_body.setObjectName("inspectorDescription")
        self.detail_body.setWordWrap(True)
        self.detail_body.setTextInteractionFlags(Qt.TextSelectableByMouse)
        detail_layout.addWidget(self.detail_title)
        detail_layout.addWidget(self.detail_body)
        detail_layout.addStretch()
        self.detail.hide()
        body.addWidget(self.detail)
        layout.addLayout(body, 1)

        result_row = QHBoxLayout()
        result_row.addStretch()
        self.verify_button = QPushButton("Validar resultado")
        self.verify_button.setObjectName("secondaryButton")
        self.verify_button.setMinimumHeight(48)
        self.verify_button.setEnabled(False)
        self.verify_button.clicked.connect(self._verify)
        self.rollback_button = QPushButton("Reverter")
        self.rollback_button.setObjectName("dangerButton")
        self.rollback_button.setMinimumHeight(48)
        self.rollback_button.setEnabled(False)
        self.rollback_button.clicked.connect(self._rollback)
        result_row.addWidget(self.verify_button)
        result_row.addWidget(self.rollback_button)
        layout.addLayout(result_row)
        return page

    def _picker_row(self, field: QLineEdit, multiple: bool) -> QWidget:
        row = QWidget()
        layout = QHBoxLayout(row)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(field, 1)
        button = QPushButton("Selecionar…")
        button.setObjectName("secondaryButton")
        button.setMinimumHeight(48)
        if multiple:
            button.clicked.connect(lambda: self._pick_files(field))
        else:
            button.clicked.connect(self._pick_directory)
        layout.addWidget(button)
        return row

    def _source_changed(self, index: int) -> None:
        if self.source_stack is not None:
            self.source_stack.setCurrentIndex(index)

    def _pick_directory(self) -> None:
        value = QFileDialog.getExistingDirectory(self, "Selecionar pasta de jogos")
        if value and self.source_path is not None:
            self.source_path.setText(value)

    def _pick_files(self, field: QLineEdit) -> None:
        values, _ = QFileDialog.getOpenFileNames(self, "Selecionar jogos ou pacotes")
        if values:
            self.selected_files = values
            field.setText(f"{len(values)} arquivo(s) selecionado(s)")

    def _scan(self) -> None:
        scope_index = self.source_group.checkedId() if self.source_group is not None else 0
        args = ["emulation", "library", "scan", "--json"]
        if scope_index == 0:
            args += ["--scope", "library"]
        elif scope_index == 1:
            value = self.source_path.text().strip() if self.source_path is not None else ""
            if not value:
                self._set_status("Selecione uma pasta antes de analisar.", "warning")
                return
            args += ["--scope", "directory", "--input", value]
        else:
            if not self.selected_files:
                self._set_status("Selecione ao menos um arquivo antes de analisar.", "warning")
                return
            args += ["--scope", "files"]
            for value in self.selected_files:
                args += ["--input", value]
        self._run_library("scan", args)

    def _plan(self) -> None:
        scan_id = self.scan_payload.get("scanId")
        if scan_id:
            self._run_library("plan", ["emulation", "library", "plan", "--scan-id", scan_id, "--json"])

    def _apply(self) -> None:
        plan_id = self.plan_payload.get("planId")
        token = self.plan_payload.get("confirmToken")
        if not plan_id or not token:
            return
        executable = int((self.plan_payload.get("summary") or {}).get("executable") or 0)
        answer = QMessageBox.question(
            self,
            "Aplicar plano seguro",
            f"Executar {executable} ação(ões)? Arquivos originais serão preservados.",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if answer != QMessageBox.Yes:
            return
        self._run_library("apply", [
            "emulation", "library", "apply", "--plan-id", plan_id,
            "--confirm", token, "--json",
        ])

    def _verify(self) -> None:
        operation_id = self.operation_payload.get("operationId")
        if operation_id:
            self._run_library("verify", ["emulation", "library", "verify", "--operation-id", operation_id, "--json"])

    def _rollback(self) -> None:
        operation_id = self.operation_payload.get("operationId")
        if not operation_id:
            return
        answer = QMessageBox.question(
            self, "Reverter operação", "Remover destinos criados por esta operação? As origens serão mantidas.",
            QMessageBox.Yes | QMessageBox.No, QMessageBox.No,
        )
        if answer == QMessageBox.Yes:
            self._run_library("rollback", ["emulation", "library", "rollback", "--operation-id", operation_id, "--json"])

    def _run_library(self, operation: str, args: list[str]) -> None:
        if self.process is not None:
            return
        process = QProcess(self)
        process.setWorkingDirectory(str(self.root))
        process.setProgram(str(self.root / "linux" / "pz"))
        process.setArguments(args)
        process.setProcessChannelMode(QProcess.SeparateChannels)
        process.finished.connect(self._process_finished)
        process.errorOccurred.connect(self._process_error)
        self.process = process
        self.operation = operation
        self._set_busy(True)
        copy = {
            "scan": "Analisando biblioteca sem alterar arquivos…",
            "plan": "Construindo plano e verificando pré-requisitos…",
            "apply": "Executando plano com staging seguro…",
            "verify": "Validando arquivos instalados…",
            "rollback": "Revertendo destinos criados…",
        }[operation]
        self._set_status(copy, "running")
        process.start()

    def _cancel_process(self) -> None:
        if self.process is not None and self.process.state() != QProcess.NotRunning:
            self.process.kill()
            self._set_status("Operação cancelada; origens preservadas.", "warning")

    def _process_error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.FailedToStart:
            self._set_status("Não foi possível iniciar o comando da biblioteca.", "error")
            self._finish_process()

    def _process_finished(self, exit_code: int, _status: QProcess.ExitStatus) -> None:
        process = self.process
        if process is None:
            return
        stdout = bytes(process.readAllStandardOutput()).decode("utf-8", errors="replace")
        stderr = bytes(process.readAllStandardError()).decode("utf-8", errors="replace")
        operation = self.operation
        payload = self._json_payload(stdout)
        self._finish_process()
        if exit_code != 0 or payload.get("status") == "fail":
            detail = payload.get("error") or stderr.strip() or f"código de saída {exit_code}"
            self._set_status(f"Falha: {str(detail)[:400]}", "error")
            return
        if operation == "scan":
            self.scan_payload = payload
            self.plan_payload = {}
            self.operation_payload = {}
            self._render_scan(payload)
            self._set_step(1)
            self._set_status("Análise concluída. Revise itens e crie o plano.", "success")
        elif operation == "plan":
            self.plan_payload = payload
            summary = payload.get("summary") or {}
            count = int(summary.get("executable") or 0)
            self.apply_button.setEnabled(count > 0)
            self._set_step(2)
            self._set_status(f"Plano pronto: {count} ação(ões) executável(is).", "success" if count else "warning")
        elif operation == "apply":
            self.operation_payload = payload
            self.verify_button.setEnabled(bool(payload.get("operationId")))
            self.rollback_button.setEnabled(bool(payload.get("operationId")))
            self._set_step(3)
            self._set_status("Execução concluída. Valide o resultado antes de encerrar.", "success")
        elif operation == "verify":
            self._set_step(4)
            self._set_status("Validação concluída: instalação íntegra.", "success")
        elif operation == "rollback":
            self.rollback_button.setEnabled(False)
            self.verify_button.setEnabled(False)
            self._set_status("Operação revertida; origens preservadas.", "success")

    @staticmethod
    def _json_payload(stdout: str) -> dict:
        for line in reversed(stdout.splitlines()):
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                return payload
        return {}

    def _finish_process(self) -> None:
        process = self.process
        self.process = None
        self.operation = ""
        self._set_busy(False)
        if process is not None:
            process.deleteLater()

    def _set_busy(self, busy: bool) -> None:
        if self.progress is not None:
            self.progress.setVisible(busy)
        if self.cancel_button is not None:
            self.cancel_button.setEnabled(busy)
        for button in (self.analyze_button, self.plan_button, self.apply_button, self.verify_button, self.rollback_button):
            if button is not None and busy:
                button.setEnabled(False)
        if not busy:
            if self.analyze_button is not None:
                self.analyze_button.setEnabled(True)
            if self.plan_button is not None:
                self.plan_button.setEnabled(bool(self.scan_payload.get("scanId")))
            if self.apply_button is not None:
                self.apply_button.setEnabled(bool((self.plan_payload.get("summary") or {}).get("executable")))
            operation_id = bool(self.operation_payload.get("operationId"))
            if self.verify_button is not None:
                self.verify_button.setEnabled(operation_id)
            if self.rollback_button is not None:
                self.rollback_button.setEnabled(operation_id)

    def _render_scan(self, payload: dict) -> None:
        summary = payload.get("summary") or {}
        for key, label in self.summary_labels.items():
            label.setText(str(summary.get(key, 0)))
        if self.table is None:
            return
        items = payload.get("items") or []
        self.table.setRowCount(len(items))
        states = {
            "ready": "Pronto", "action": "Requer ação",
            "blocked": "Bloqueado", "unknown": "Não reconhecido",
        }
        for row, item in enumerate(items):
            values = (
                item.get("game") or Path(item.get("path", "")).stem,
                item.get("systemName") or "Desconhecido",
                item.get("origin") or item.get("format") or "—",
                item.get("destination") or "—",
                states.get(item.get("state"), item.get("state") or "—"),
            )
            for column, value in enumerate(values):
                cell = QTableWidgetItem(str(value))
                cell.setData(Qt.UserRole, row)
                self.table.setItem(row, column, cell)
        self.plan_button.setEnabled(bool(payload.get("scanId")))
        self.apply_button.setEnabled(False)
        self.verify_button.setEnabled(False)
        self.rollback_button.setEnabled(False)
        self._filter_rows()

    def _filter_rows(self) -> None:
        if self.table is None:
            return
        wanted = self.filter_combo.currentData() if self.filter_combo is not None else "all"
        items = self.scan_payload.get("items") or []
        for row, item in enumerate(items):
            self.table.setRowHidden(row, wanted != "all" and item.get("state") != wanted)

    def _show_detail(self) -> None:
        if self.table is None or self.detail is None:
            return
        selected = self.table.selectedItems()
        if not selected:
            self.detail.hide()
            return
        index = selected[0].data(Qt.UserRole)
        items = self.scan_payload.get("items") or []
        if not isinstance(index, int) or not 0 <= index < len(items):
            self.detail.hide()
            return
        item = items[index]
        self.detail_title.setText(item.get("game") or "Detalhes")
        detection = item.get("detection") or {}
        notes = (item.get("vita") or {}).get("notes") or []
        body = [
            f"Sistema: {item.get('systemName') or 'Não reconhecido'}",
            f"Formato: {item.get('origin') or item.get('format') or '—'}",
            f"Destino: {item.get('destination') or '—'}",
            f"Detecção: {detection.get('method', '—')} · confiança {detection.get('confidence', 0):.0%}",
            "",
            str(item.get("recommendation") or "Origem preservada."),
        ]
        if notes:
            body += ["", *[f"• {note}" for note in notes]]
        self.detail_body.setText("\n".join(body))
        self.detail.show()

    def _set_step(self, active: int) -> None:
        for index, label in enumerate(self.step_labels):
            label.setProperty("state", "complete" if index < active else "active" if index == active else "pending")
            label.style().unpolish(label)
            label.style().polish(label)

    def _set_status(self, message: str, state: str) -> None:
        if self.workflow_status is None:
            return
        self.workflow_status.setText(message)
        self.workflow_status.setProperty("state", state)
        self.workflow_status.style().unpolish(self.workflow_status)
        self.workflow_status.style().polish(self.workflow_status)

    def _request_by_id(self, action_id: str) -> None:
        action = self.by_id.get(action_id)
        if action is not None:
            self.action_selected.emit(action)
            self.request_action(action)

    def _select_legacy(self, action: ActionSpec) -> None:
        self.action_selected.emit(action)

    def block_while_running(self, running: bool) -> None:
        if self.process is None:
            self.setEnabled(not running)

    def cancel_status(self) -> None:
        self._cancel_process()
        super().cancel_status()
