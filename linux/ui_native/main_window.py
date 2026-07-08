from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from PySide6.QtCore import QDir, QTimer, Qt, Signal
from PySide6.QtGui import QAction, QCloseEvent, QIcon, QKeySequence
from PySide6.QtWidgets import (
    QFileDialog,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSizeGrip,
    QSplitter,
    QStackedWidget,
    QStyle,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

from .catalog import (
    CATEGORIES,
    DASHBOARD,
    DASHBOARD_QUICK,
    DASHBOARD_TOOLS,
    SIDEBAR_GROUPS,
    build_catalog,
)
from .command_runner import CommandRunner, state_dir
from .models import ActionSpec, OperationResult
from .result_parser import severity_for
from .widgets import (
    ActionCard,
    HeaderBar,
    PreviewDialog,
    ResultDialog,
    SectionHeader,
    Toast,
    themed_icon,
)


class MainWindow(QMainWindow):
    theme_changed = Signal(str)

    def __init__(self, root: Path, *, initial_category: str = "") -> None:
        super().__init__()
        self.root = root
        self.catalog = build_catalog(root)
        self.by_id = {action.id: action for action in self.catalog}
        self.cat_meta = {row[0]: row for row in (DASHBOARD, *CATEGORIES)}
        self.runner = CommandRunner(root, self)
        self.current_category = initial_category or DASHBOARD[0]
        self.pending_action: ActionSpec | None = None
        self.pending_value = ""
        self.cards: list[ActionCard] = []
        self.dashboard_cards: list[ActionCard] = []
        self.sidebar_buttons: dict[str, QPushButton] = {}
        self.dark_theme = True
        self._maximized = False
        self._start_failed = False
        self._last_columns = 0
        self._relayout_timer = QTimer(self)
        self._relayout_timer.setSingleShot(True)
        self._relayout_timer.setInterval(120)
        self._relayout_timer.timeout.connect(self._relayout_after_resize)

        self.setWindowTitle("PhaseZero — Central de Controle")
        self.setMinimumSize(900, 600)
        self.resize(1280, 800)
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.Window)
        self._build_ui()
        self._connect_runner()
        self._install_shortcuts()
        self.show_category(self.current_category)

    def _build_ui(self) -> None:
        shell = QFrame()
        shell.setObjectName("appShell")
        self.setCentralWidget(shell)
        shell_layout = QVBoxLayout(shell)
        shell_layout.setContentsMargins(1, 1, 1, 1)
        shell_layout.setSpacing(0)

        header = HeaderBar()
        header.minimize_requested.connect(self.showMinimized)
        header.maximize_requested.connect(self.toggle_maximize)
        header.close_requested.connect(self.close)
        shell_layout.addWidget(header)

        body = QWidget()
        body_layout = QHBoxLayout(body)
        body_layout.setContentsMargins(0, 0, 0, 0)
        body_layout.setSpacing(0)
        shell_layout.addWidget(body, 1)

        sidebar = QFrame()
        sidebar.setObjectName("sidebar")
        sidebar.setFixedWidth(230)
        sidebar_scroll = QScrollArea()
        sidebar_scroll.setWidgetResizable(True)
        sidebar_scroll.setFrameShape(QFrame.NoFrame)
        sidebar_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        sidebar_inner = QWidget()
        sidebar_layout = QVBoxLayout(sidebar_inner)
        sidebar_layout.setContentsMargins(12, 8, 10, 12)
        sidebar_layout.setSpacing(3)
        # EmuDeck-style grouped sidebar: section captions + icon-and-text items.
        for group_title, categories in SIDEBAR_GROUPS:
            section = QLabel(group_title.upper())
            section.setObjectName("sectionLabel")
            sidebar_layout.addWidget(section)
            for category in categories:
                meta = self.cat_meta.get(category)
                if meta is None:
                    continue
                button = QPushButton(category.replace("&", "&&"))
                button.setObjectName("sidebarButton")
                button.setCheckable(True)
                button.setCursor(Qt.PointingHandCursor)
                button.setToolTip(meta[2])
                button.setIcon(themed_icon(self, meta[1], QStyle.SP_FileDialogDetailedView))
                button.clicked.connect(lambda _checked=False, name=category: self.show_category(name))
                self.sidebar_buttons[category] = button
                sidebar_layout.addWidget(button)
        sidebar_layout.addStretch()
        sidebar_scroll.setWidget(sidebar_inner)
        outer_sidebar_layout = QVBoxLayout(sidebar)
        outer_sidebar_layout.setContentsMargins(0, 10, 0, 0)
        outer_sidebar_layout.setSpacing(0)
        outer_sidebar_layout.addWidget(sidebar_scroll, 1)
        self.system_label = QLabel("Host: verificando…")
        self.system_label.setObjectName("sidebarStatus")
        self.system_label.setWordWrap(True)
        outer_sidebar_layout.addWidget(self.system_label)
        body_layout.addWidget(sidebar)

        main = QWidget()
        main.setObjectName("content")
        main_layout = QVBoxLayout(main)
        main_layout.setContentsMargins(24, 18, 24, 14)
        main_layout.setSpacing(14)
        body_layout.addWidget(main, 1)

        top = QHBoxLayout()
        title_box = QVBoxLayout()
        self.page_title = QLabel()
        self.page_title.setObjectName("pageTitle")
        self.page_subtitle = QLabel()
        self.page_subtitle.setObjectName("pageSubtitle")
        title_box.addWidget(self.page_title)
        title_box.addWidget(self.page_subtitle)
        top.addLayout(title_box)
        top.addStretch()
        self.search = QLineEdit()
        self.search.setObjectName("searchBox")
        self.search.setPlaceholderText("Buscar ação, perfil ou módulo…")
        self.search.setClearButtonEnabled(True)
        self.search.setMinimumWidth(320)
        self.search.setAccessibleName("Busca de ações")
        self.search.textChanged.connect(self.on_search)
        top.addWidget(self.search)
        theme = QPushButton()
        theme.setObjectName("iconButton")
        theme.setToolTip("Alternar tema")
        theme_icon = QIcon.fromTheme("weather-clear-night")
        if theme_icon.isNull():
            theme.setText("◐")
        else:
            theme.setIcon(theme_icon)
        theme.clicked.connect(self.toggle_theme)
        top.addWidget(theme)
        main_layout.addLayout(top)

        reboot_marker = Path("/run/reboot-required")
        if not reboot_marker.exists():
            reboot_marker = Path("/var/run/reboot-required")
        if reboot_marker.exists():
            banner = QFrame()
            banner.setObjectName("warningBanner")
            banner_layout = QHBoxLayout(banner)
            banner_layout.setContentsMargins(12, 8, 12, 8)
            warning = QLabel("Reboot pendente. Conclua reinicialização antes de mudanças de sistema.")
            warning.setObjectName("warningText")
            banner_layout.addWidget(warning)
            banner_layout.addStretch()
            main_layout.addWidget(banner)

        self.stack = QStackedWidget()
        self.dashboard_page = self._build_dashboard_page()
        self.stack.addWidget(self.dashboard_page)
        self.actions_page = QWidget()
        action_page_layout = QVBoxLayout(self.actions_page)
        action_page_layout.setContentsMargins(0, 0, 0, 0)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.NoFrame)
        self.cards_host = QWidget()
        self.grid = QGridLayout(self.cards_host)
        self.grid.setContentsMargins(0, 4, 6, 8)
        self.grid.setHorizontalSpacing(14)
        self.grid.setVerticalSpacing(14)
        self.scroll.setWidget(self.cards_host)
        action_page_layout.addWidget(self.scroll)
        self.stack.addWidget(self.actions_page)
        self.results_page = self._build_results_page()
        self.stack.addWidget(self.results_page)
        main_layout.addWidget(self.stack, 1)

        operation = QFrame()
        operation.setObjectName("operationPanel")
        operation_layout = QVBoxLayout(operation)
        operation_layout.setContentsMargins(14, 10, 14, 10)
        operation_layout.setSpacing(8)
        status_row = QHBoxLayout()
        self.status_dot = QLabel("●")
        self.status_dot.setObjectName("statusIdle")
        self.status_text = QLabel("Pronto")
        self.status_text.setObjectName("statusText")
        self.command_label = QLabel("")
        self.command_label.setObjectName("pathLabel")
        self.command_label.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.cancel_button = QPushButton("Cancelar")
        self.cancel_button.setObjectName("dangerButton")
        self.cancel_button.setEnabled(False)
        self.cancel_button.clicked.connect(self.runner.cancel)
        self.toggle_logs_button = QPushButton("Logs")
        self.toggle_logs_button.clicked.connect(self.toggle_logs)
        status_row.addWidget(self.status_dot)
        status_row.addWidget(self.status_text)
        status_row.addWidget(self.command_label, 1)
        status_row.addWidget(self.toggle_logs_button)
        status_row.addWidget(self.cancel_button)
        # Frameless window: QSizeGrip is the only mouse-resize affordance.
        status_row.addWidget(QSizeGrip(operation), 0, Qt.AlignBottom | Qt.AlignRight)
        operation_layout.addLayout(status_row)
        self.progress = QProgressBar()
        self.progress.setTextVisible(False)
        self.progress.setMaximumHeight(4)
        self.progress.hide()
        operation_layout.addWidget(self.progress)
        self.log_view = QPlainTextEdit()
        self.log_view.setObjectName("logView")
        self.log_view.setReadOnly(True)
        self.log_view.setMaximumHeight(190)
        self.log_view.hide()
        operation_layout.addWidget(self.log_view)
        main_layout.addWidget(operation)
        QTimer.singleShot(0, self._host_summary)

    def _build_dashboard_page(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        host = QWidget()
        host_layout = QVBoxLayout(host)
        host_layout.setContentsMargins(2, 2, 8, 8)
        host_layout.setSpacing(14)

        welcome = QLabel("Bem-vindo de volta ao PhaseZero 👋")
        welcome.setObjectName("welcomeTitle")
        host_layout.addWidget(welcome)
        subtitle = QLabel("Escaneie, escolha um card e execute — sem decorar caminhos de menu.")
        subtitle.setObjectName("welcomeSubtitle")
        host_layout.addWidget(subtitle)

        host_layout.addWidget(SectionHeader("Ações rápidas", "As tarefas mais comuns, em destaque."))
        host_layout.addWidget(self._dashboard_grid(DASHBOARD_QUICK, hero=True, columns=2))

        host_layout.addWidget(SectionHeader("Ferramentas & utilidades", "Atalhos para status e reparos."))
        host_layout.addWidget(self._dashboard_grid(DASHBOARD_TOOLS, hero=False, columns=3))
        host_layout.addStretch()

        scroll.setWidget(host)
        layout.addWidget(scroll)
        return page

    def _dashboard_grid(self, ids: tuple[str, ...], *, hero: bool, columns: int) -> QWidget:
        holder = QWidget()
        grid = QGridLayout(holder)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        actions = [self.by_id[a] for a in ids if a in self.by_id]
        for index, action in enumerate(actions):
            card = ActionCard(action, hero=hero)
            card.requested.connect(self.request_action)
            self.dashboard_cards.append(card)
            grid.addWidget(card, index // columns, index % columns)
        for column in range(columns):
            grid.setColumnStretch(column, 1)
        return holder

    def _build_results_page(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        toolbar = QHBoxLayout()
        refresh = QPushButton("Atualizar")
        refresh.clicked.connect(self.load_history)
        folder = QPushButton("Abrir pasta")
        folder.clicked.connect(self.open_results_folder)
        export = QPushButton("Exportar ZIP")
        export.clicked.connect(self.export_results)
        toolbar.addWidget(refresh)
        toolbar.addWidget(folder)
        toolbar.addWidget(export)
        toolbar.addStretch()
        layout.addLayout(toolbar)
        splitter = QSplitter()
        self.history = QTreeWidget()
        self.history.setHeaderLabels(["Operação", "Estado", "Data"])
        self.history.setAlternatingRowColors(True)
        self.history.itemSelectionChanged.connect(self.show_history_item)
        self.history_detail = QPlainTextEdit()
        self.history_detail.setReadOnly(True)
        self.history_detail.setObjectName("logView")
        splitter.addWidget(self.history)
        splitter.addWidget(self.history_detail)
        splitter.setSizes([360, 620])
        layout.addWidget(splitter, 1)
        return page

    def _connect_runner(self) -> None:
        self.runner.started.connect(self.operation_started)
        self.runner.output.connect(self.append_output)
        self.runner.progress.connect(self.update_progress)
        self.runner.completed.connect(self.operation_completed)
        self.runner.failed_to_start.connect(self.operation_start_failed)

    def _install_shortcuts(self) -> None:
        search_action = QAction(self)
        search_action.setShortcut(QKeySequence.Find)
        search_action.triggered.connect(self.search.setFocus)
        self.addAction(search_action)
        cancel_action = QAction(self)
        cancel_action.setShortcut(QKeySequence(Qt.Key_Escape))
        cancel_action.triggered.connect(self.cancel_or_clear)
        self.addAction(cancel_action)
        for index, (category, _icon, _hint) in enumerate(CATEGORIES[:9], start=1):
            action = QAction(self)
            action.setShortcut(QKeySequence(f"Ctrl+{index}"))
            action.triggered.connect(lambda _checked=False, name=category: self.show_category(name))
            self.addAction(action)

    def _host_summary(self) -> None:
        try:
            result = subprocess.run(
                [str(self.root / "linux" / "pz"), "version"],
                cwd=self.root,
                capture_output=True,
                text=True,
                timeout=4,
                check=False,
            )
            self.system_label.setText(result.stdout.strip() or "PhaseZero Linux")
        except (OSError, subprocess.TimeoutExpired):
            self.system_label.setText("PhaseZero Linux")

    def show_category(self, category: str) -> None:
        self.current_category = category
        for name, button in self.sidebar_buttons.items():
            button.setChecked(name == category)
        if self.search.text().strip():
            self.search.clear()  # leaving a category cancels an active search
        meta = self.cat_meta.get(category)
        if category == DASHBOARD[0]:
            self.stack.setCurrentWidget(self.dashboard_page)
            self.page_title.setText("Início")
            self.page_subtitle.setText(meta[2] if meta else "")
        elif category == "Resultados":
            self.stack.setCurrentWidget(self.results_page)
            self.page_title.setText("Resultados")
            self.page_subtitle.setText("Histórico, logs e result.json")
            self.load_history()
        else:
            self.stack.setCurrentWidget(self.actions_page)
            self.page_title.setText(category)
            self.page_subtitle.setText(meta[2] if meta else "")
            self.rebuild_cards()

    def on_search(self, text: str) -> None:
        if text.strip():
            self.stack.setCurrentWidget(self.actions_page)
            self.page_title.setText("Busca")
            self.page_subtitle.setText(f"Resultados para “{text.strip()}”")
            self.rebuild_cards()
        else:
            self.show_category(self.current_category)

    def rebuild_cards(self) -> None:
        if self.current_category in ("Resultados", DASHBOARD[0]) and not self.search.text().strip():
            return
        while self.grid.count():
            item = self.grid.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self.cards.clear()
        query = self.search.text().strip().casefold()
        visible = [
            action
            for action in self.catalog
            if (query and query in action.searchable_text)
            or (not query and action.category == self.current_category)
        ]
        columns = self._column_count()
        self._last_columns = columns
        for index, action in enumerate(visible):
            card = ActionCard(action)
            card.requested.connect(self.request_action)
            card.setEnabled(not self.runner.running)
            self.cards.append(card)
            self.grid.addWidget(card, index // columns, index % columns)
        for column in range(columns):
            self.grid.setColumnStretch(column, 1)
        if not visible:
            empty = QLabel("Nenhuma ação corresponde à busca.")
            empty.setObjectName("emptyState")
            self.grid.addWidget(empty, 0, 0, 1, columns)
        self.grid.setRowStretch((len(visible) + columns - 1) // columns, 1)

    def _column_count(self) -> int:
        width = self.scroll.viewport().width()
        if width >= 960:
            return 3
        if width >= 620:
            return 2
        return 1

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        self._relayout_timer.start()

    def _relayout_after_resize(self) -> None:
        if self._column_count() != self._last_columns:
            self.rebuild_cards()

    def request_action(self, action: ActionSpec) -> None:
        if self.runner.running:
            return
        value = ""
        if action.input_kind:
            value = self._request_input(action)
            if not value:
                return
        self.pending_action = action
        self.pending_value = value
        self.log_view.clear()
        self.log_view.show()
        try:
            self.runner.start(action, preview=action.mutable, value=value)
        except (ValueError, RuntimeError) as exc:
            self.pending_action = None
            self.pending_value = ""
            QMessageBox.warning(self, "Não foi possível iniciar", str(exc))

    def _request_input(self, action: ActionSpec) -> str:
        if action.input_kind == "file":
            value, _ = QFileDialog.getOpenFileName(self, action.input_label, QDir.homePath())
            return value
        if action.input_kind == "path":
            value = QFileDialog.getExistingDirectory(self, action.input_label, QDir.homePath())
            if value:
                return value
            value, _ = QFileDialog.getOpenFileName(self, action.input_label, QDir.homePath())
            return value
        return ""

    def operation_started(self, command: str) -> None:
        self.status_text.setText("Pré-visualizando…" if self.runner.preview else "Executando…")
        self.status_dot.setObjectName("statusRunning")
        self.status_dot.style().unpolish(self.status_dot)
        self.status_dot.style().polish(self.status_dot)
        self.command_label.setText(command)
        self.cancel_button.setEnabled(True)
        self.progress.setRange(0, 0)
        self.progress.show()
        for card in (*self.cards, *self.dashboard_cards):
            card.setEnabled(False)
        self.append_output(f"$ {command}\n", False)

    def append_output(self, text: str, error: bool) -> None:
        if error:
            self.log_view.appendPlainText("[stderr] " + text.rstrip())
        else:
            cursor = self.log_view.textCursor()
            cursor.movePosition(cursor.End)
            cursor.insertText(text)
            self.log_view.setTextCursor(cursor)
        scrollbar = self.log_view.verticalScrollBar()
        scrollbar.setValue(scrollbar.maximum())

    def update_progress(self, value: int) -> None:
        self.progress.setRange(0, 100)
        self.progress.setValue(value)

    def operation_completed(self, result: OperationResult) -> None:
        start_failed = self._start_failed
        self._start_failed = False
        self.progress.hide()
        self.cancel_button.setEnabled(False)
        self.status_text.setText("Concluído" if result.ok else "Falhou")
        severity = severity_for(result.parsed, result.exit_code)
        self.status_dot.setObjectName("statusSuccess" if severity == "success" else "statusWarning" if severity == "warning" else "statusError")
        self.status_dot.style().unpolish(self.status_dot)
        self.status_dot.style().polish(self.status_dot)
        for card in (*self.cards, *self.dashboard_cards):
            card.setEnabled(True)
        action_title = self.pending_action.title if self.pending_action is not None else "Operação"
        if start_failed:
            pass  # operation_start_failed already told the user
        elif result.preview and self.pending_action is not None:
            dialog = PreviewDialog(result, self)
            if dialog.exec() == PreviewDialog.Accepted:
                self.log_view.appendPlainText("\n--- execução confirmada ---\n")
                try:
                    self.runner.start(self.pending_action, preview=False, value=self.pending_value)
                    return
                except (ValueError, RuntimeError) as exc:
                    QMessageBox.warning(self, "Não foi possível iniciar", str(exc))
        else:
            formatted = self._format_result(result)
            ResultDialog(result, formatted, self).exec()
            toast_state = "success" if severity == "success" else "warning" if severity == "warning" else "error"
            verb = "concluída" if result.ok else "falhou"
            self._toast(f"{action_title} {verb}", toast_state)
        self.pending_action = None
        self.pending_value = ""

    def _toast(self, message: str, state: str) -> None:
        toast = Toast(self, message, state)
        toast.popup()

    def _format_result(self, result: OperationResult) -> str:
        blocks = []
        if result.parsed is not None:
            blocks.append("RESULTADO ESTRUTURADO\n" + json.dumps(result.parsed, ensure_ascii=False, indent=2))
        if result.stdout:
            blocks.append("STDOUT\n" + result.stdout)
        if result.stderr:
            blocks.append("STDERR\n" + result.stderr)
        if not blocks:
            blocks.append("Processo terminou sem saída.")
        return "\n\n".join(blocks)

    def operation_start_failed(self, message: str) -> None:
        self._start_failed = True
        self.progress.hide()
        self.cancel_button.setEnabled(False)
        self.status_text.setText("Falha ao iniciar")
        QMessageBox.critical(self, "Falha ao iniciar", message)

    def cancel_or_clear(self) -> None:
        if self.runner.running:
            self.runner.cancel()
        elif self.search.text():
            self.search.clear()

    def toggle_logs(self) -> None:
        self.log_view.setVisible(not self.log_view.isVisible())

    def toggle_maximize(self) -> None:
        if self.isMaximized():
            self.showNormal()
            self._maximized = False
        else:
            self.showMaximized()
            self._maximized = True

    def toggle_theme(self) -> None:
        self.dark_theme = not self.dark_theme
        self.theme_changed.emit("dark" if self.dark_theme else "light")

    def load_history(self) -> None:
        self.history.clear()
        result_dir = state_dir() / "results"
        if not result_dir.exists():
            return
        for path in sorted(result_dir.glob("*.json"), reverse=True)[:250]:
            try:
                data = json.loads(path.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            item = QTreeWidgetItem(
                [
                    str(data.get("action", path.stem)),
                    "OK" if data.get("ok") else "Falha",
                    str(data.get("finishedAt", "")),
                ]
            )
            item.setData(0, Qt.UserRole, str(path))
            self.history.addTopLevelItem(item)
        phasezero_state = state_dir().parent
        for path in sorted(phasezero_state.glob("*.log")):
            item = QTreeWidgetItem([path.name, "Log", ""])
            item.setData(0, Qt.UserRole, str(path))
            self.history.addTopLevelItem(item)
        self.history.resizeColumnToContents(0)

    def show_history_item(self) -> None:
        items = self.history.selectedItems()
        if not items:
            return
        path = Path(items[0].data(0, Qt.UserRole))
        try:
            if path.suffix == ".json":
                data = json.loads(path.read_text())
                text = json.dumps(data, ensure_ascii=False, indent=2)
            else:
                text = path.read_text(errors="replace")
            self.history_detail.setPlainText(text)
        except (OSError, json.JSONDecodeError) as exc:
            self.history_detail.setPlainText(str(exc))

    def open_results_folder(self) -> None:
        folder = state_dir().parent
        folder.mkdir(parents=True, exist_ok=True)
        subprocess.Popen(["xdg-open", str(folder)])

    def export_results(self) -> None:
        source = state_dir().parent
        source.mkdir(parents=True, exist_ok=True)
        target, _ = QFileDialog.getSaveFileName(
            self,
            "Exportar logs e resultados",
            str(Path.home() / "phasezero-results.zip"),
            "Arquivo ZIP (*.zip)",
        )
        if not target:
            return
        if target.endswith(".zip"):
            target = target[:-4]
        archive = shutil.make_archive(target, "zip", source)
        self.status_text.setText(f"Exportado: {archive}")

    def closeEvent(self, event: QCloseEvent) -> None:
        if self.runner.running:
            answer = QMessageBox.question(
                self,
                "Operação em andamento",
                "Cancelar operação e fechar?",
                QMessageBox.Yes | QMessageBox.No,
                QMessageBox.No,
            )
            if answer != QMessageBox.Yes:
                event.ignore()
                return
            self.runner.cancel()
        event.accept()
