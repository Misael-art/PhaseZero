from __future__ import annotations

import json
import time
from pathlib import Path

from PySide6.QtCore import QProcess, QTimer, Qt, Signal
from PySide6.QtGui import QAction, QCloseEvent, QIcon, QKeySequence, QTextCursor
from PySide6.QtWidgets import (
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
    QStackedWidget,
    QStyle,
    QVBoxLayout,
    QWidget,
)

from .catalog import CATEGORIES, DASHBOARD, SIDEBAR_GROUPS, build_catalog
from .command_runner import CommandRunner
from .models import ActionSpec, OperationResult
from .provision_player import ProvisionPlayerWindow
from .windows_install_dialog import WindowsInstallDialog
from .preferences import UiPreferences
from .pages.registry import PageRegistry
from .result_parser import severity_for
from .widgets import (
    ActionInspector,
    ActionListRow,
    Breadcrumb,
    HeaderBar,
    ParameterDialog,
    PreviewDialog,
    ProgressDialog,
    ResultDialog,
    SwitchControl,
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
        self.pending_values: dict[str, str] = {}
        self._action_queue: list[ActionSpec] = []
        self.sidebar_buttons: dict[str, QPushButton] = {}
        self.dark_theme = True
        self._maximized = False
        self._start_failed = False
        self._search_cards: list[QWidget] = []
        self._host_process: QProcess | None = None
        self._closing = False
        self.progress_dialog: ProgressDialog | None = None
        self._operation_started_at: float | None = None
        self._failure_count = 0
        self.preferences = UiPreferences(self)
        self._elapsed_timer = QTimer(self)
        self._elapsed_timer.setInterval(1000)
        self._elapsed_timer.timeout.connect(self._update_elapsed)
        self._search_relayout_timer = QTimer(self)
        self._search_relayout_timer.setSingleShot(True)
        self._search_relayout_timer.setInterval(120)
        self._search_relayout_timer.timeout.connect(self.rebuild_search)

        self.setWindowTitle("PhaseZero — Central de Controle")
        self.setMinimumSize(1100, 680)
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
                button.setAccessibleName(f"Abrir {category}")
                button.setAccessibleDescription(meta[2])
                fallback_icons = {
                    "Início": QStyle.SP_DirHomeIcon,
                    "Visão geral": QStyle.SP_DialogApplyButton,
                    "Perfis": QStyle.SP_FileDialogListView,
                    "Steam Deck": QStyle.SP_DriveDVDIcon,
                    "Windows VM": QStyle.SP_ComputerIcon,
                    "Waydroid": QStyle.SP_DriveHDIcon,
                    "Servidor": QStyle.SP_DriveNetIcon,
                    "Homelab": QStyle.SP_DriveNetIcon,
                    "Emulação": QStyle.SP_DriveDVDIcon,
                    "Boot Direto": QStyle.SP_BrowserReload,
                    "Flatpak": QStyle.SP_DriveHDIcon,
                    "Recursos": QStyle.SP_DesktopIcon,
                    "Ajustes": QStyle.SP_FileDialogDetailedView,
                    "IA & Dev": QStyle.SP_CommandLink,
                    "Proxies IA": QStyle.SP_DriveNetIcon,
                    "Aplicativos": QStyle.SP_DirIcon,
                    "Resultados": QStyle.SP_FileDialogInfoView,
                }
                button.setIcon(themed_icon(self, meta[1], fallback_icons.get(category, QStyle.SP_FileIcon)))
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

        self.breadcrumb = Breadcrumb()
        main_layout.addWidget(self.breadcrumb)

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
        mode_label = QLabel("Modo avançado")
        mode_label.setObjectName("modeSwitchLabel")
        top.addWidget(mode_label)
        self.mode_switch = SwitchControl()
        self.mode_switch.setObjectName("modeSwitch")
        self.mode_switch.setAccessibleName("Modo avançado")
        self.mode_switch.setToolTip("Revela comandos, logs e operações técnicas")
        self.mode_switch.setAccessibleDescription(
            "Desativado por padrão. Ative para mostrar comandos, logs e ações avançadas."
        )
        self.mode_switch.setChecked(self.preferences.advanced_mode)
        self.mode_switch.toggled.connect(self._set_advanced_mode)
        top.addWidget(self.mode_switch)
        theme = QPushButton()
        theme.setObjectName("iconButton")
        theme.setToolTip("Alternar tema")
        theme_icon = QIcon.fromTheme("weather-clear-night")
        if theme_icon.isNull():
            theme.setText("◐")
        else:
            theme.setIcon(theme_icon)
        theme.clicked.connect(self.toggle_theme)
        theme.setAccessibleName("Alternar tema claro ou escuro")
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

        self.registry = PageRegistry(self.root, self.runner)
        for page in self.registry.pages():
            page.action_requested.connect(self.request_action)
            page.actions_requested.connect(self.request_actions)
            page.action_selected.connect(self.inspect_action)
        self.stack = QStackedWidget()
        # Add every category page from the registry in sidebar order.
        seen: set[str] = set()
        for _group_title, categories in SIDEBAR_GROUPS:
            for category in categories:
                if category in seen:
                    continue
                seen.add(category)
                page = self.registry.page_for(category)
                if page is not None:
                    self.stack.addWidget(page)
        # Search results page (keeps old ActionCard grid for cross-category search).
        self.search_page = QWidget()
        sp_layout = QVBoxLayout(self.search_page)
        sp_layout.setContentsMargins(0, 0, 0, 0)
        self.search_scroll = QScrollArea()
        self.search_scroll.setWidgetResizable(True)
        self.search_scroll.setFrameShape(QFrame.NoFrame)
        self.search_host = QWidget()
        self.search_grid = QGridLayout(self.search_host)
        self.search_grid.setContentsMargins(0, 4, 6, 8)
        self.search_grid.setHorizontalSpacing(14)
        self.search_grid.setVerticalSpacing(14)
        self.search_scroll.setWidget(self.search_host)
        sp_layout.addWidget(self.search_scroll)
        self.stack.addWidget(self.search_page)
        self._search_page_idx = self.stack.count() - 1
        workspace = QHBoxLayout()
        workspace.setSpacing(14)
        workspace.addWidget(self.stack, 1)
        self.inspector = ActionInspector()
        self.inspector.requested.connect(self.request_action)
        self.inspector.hide()
        workspace.addWidget(self.inspector)
        main_layout.addLayout(workspace, 1)

        operation = QFrame()
        operation.setObjectName("operationPanel")
        operation.setAccessibleName("Operação atual")
        operation_layout = QVBoxLayout(operation)
        operation_layout.setContentsMargins(14, 10, 14, 10)
        operation_layout.setSpacing(8)
        status_row = QHBoxLayout()
        self.status_dot = QLabel("●")
        self.status_dot.setObjectName("statusIdle")
        self.status_text = QLabel("Pronto")
        self.status_text.setObjectName("statusText")
        self.elapsed_label = QLabel("")
        self.elapsed_label.setObjectName("operationElapsed")
        self.command_label = QLabel("")
        self.command_label.setObjectName("pathLabel")
        self.command_label.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.cancel_button = QPushButton("Cancelar")
        self.cancel_button.setObjectName("dangerButton")
        self.cancel_button.setEnabled(False)
        self.cancel_button.clicked.connect(self.runner.cancel)
        self.cancel_button.setAccessibleDescription("Interrompe processo em andamento")
        self.toggle_logs_button = QPushButton("Logs")
        self.toggle_logs_button.clicked.connect(self.toggle_logs)
        status_row.addWidget(self.status_dot)
        status_row.addWidget(self.status_text)
        status_row.addWidget(self.elapsed_label)
        status_row.addWidget(self.command_label, 1)
        status_row.addWidget(self.toggle_logs_button)
        status_row.addWidget(self.cancel_button)
        # Frameless window: QSizeGrip is the only mouse-resize affordance.
        status_row.addWidget(QSizeGrip(operation), 0, Qt.AlignBottom | Qt.AlignRight)
        operation_layout.addLayout(status_row)
        self.operation_status_row = status_row
        self.progress = QProgressBar()
        self.progress.setTextVisible(False)
        self.progress.setMaximumHeight(4)
        self.progress.hide()
        operation_layout.addWidget(self.progress)
        self.log_view = QPlainTextEdit()
        self.log_view.setObjectName("logView")
        self.log_view.setReadOnly(True)
        self.log_view.document().setMaximumBlockCount(10_000)
        self.log_view.setMaximumHeight(190)
        self.log_view.hide()
        operation_layout.addWidget(self.log_view)
        main_layout.addWidget(operation)
        self._build_global_status_bar()
        self._set_advanced_mode(self.preferences.advanced_mode, persist=False)
        QTimer.singleShot(0, self._host_summary)

    def _build_global_status_bar(self) -> None:
        self.global_state = QLabel("Pronto")
        self.global_state.setObjectName("globalState")
        self.global_state.setAccessibleName("Estado global")
        self.global_context = QLabel("Nenhuma falha pendente")
        self.global_context.setObjectName("globalContext")
        self.global_context.setAccessibleName("Resumo de falhas")
        self.operation_status_row.insertWidget(3, self.global_state, 1)
        self.operation_status_row.insertWidget(4, self.global_context)

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
        process = QProcess(self)
        process.setProgram(str(self.root / "linux" / "pz"))
        process.setArguments(["version"])
        process.setWorkingDirectory(str(self.root))
        process.finished.connect(self._host_summary_finished)
        process.errorOccurred.connect(self._host_summary_error)
        self._host_process = process
        process.start()
        QTimer.singleShot(4000, self._host_summary_timeout)

    def _host_summary_timeout(self) -> None:
        if self._host_process is not None and self._host_process.state() != QProcess.NotRunning:
            self._host_process.kill()

    def _host_summary_error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.FailedToStart:
            self._host_summary_finished()

    def _host_summary_finished(self, *_args) -> None:
        process = self._host_process
        if process is None:
            return
        text = bytes(process.readAllStandardOutput().data()).decode("utf-8", errors="replace").strip()
        if text:
            self.system_label.setText(text)
        else:
            self.system_label.setText("PhaseZero Linux")
        self._host_process = None
        process.deleteLater()

    def show_category(self, category: str) -> None:
        if self.registry.page_for(category) is None:
            category = DASHBOARD[0]
        self.current_category = category
        self.inspector.clear_action()
        self.inspector.hide()
        for name, button in self.sidebar_buttons.items():
            button.setChecked(name == category)
        if self.search.text().strip():
            self.search.clear()
        meta = self.cat_meta.get(category)
        section = next(
            (title for title, categories in SIDEBAR_GROUPS if category in categories),
            "Navegação",
        )
        self.breadcrumb.set_path(section, category)
        page = self.registry.page_for(category)
        if page is not None:
            self.stack.setCurrentWidget(page)
            self.page_title.setText(category)
            self.page_subtitle.setText(meta[2] if meta else "")
            if hasattr(page, "reload"):
                page.reload()
        self.global_state.setText(f"Página: {category}")

    def inspect_action(self, action: ActionSpec) -> None:
        self.inspector.set_action(action)
        self.inspector.show()
        self.global_state.setText(f"Selecionado: {action.title}")

    def on_search(self, text: str) -> None:
        if text.strip():
            self.stack.setCurrentIndex(self._search_page_idx)
            self.page_title.setText("Busca")
            self.page_subtitle.setText(f"Resultados para “{text.strip()}”")
            self.breadcrumb.set_path("Navegação", "Busca")
            self.global_state.setText("Busca global")
            self.rebuild_search()
        else:
            self.show_category(self.current_category)

    def rebuild_search(self) -> None:
        while self.search_grid.count():
            item = self.search_grid.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._search_cards.clear()
        query = self.search.text().strip().casefold()
        visible = [
            action for action in self.catalog
            if query and query in action.searchable_text
        ]
        columns = 1
        for index, action in enumerate(visible):
            row = ActionListRow(action)
            row.selected.connect(lambda item, widget=row: self._select_search_action(item, widget))
            row.setEnabled(not self.runner.running)
            self._search_cards.append(row)
            self.search_grid.addWidget(row, index, 0)
        for col in range(columns):
            self.search_grid.setColumnStretch(col, 1)
        if not visible:
            empty = QLabel("Nenhuma ação corresponde à busca.")
            empty.setObjectName("emptyState")
            self.search_grid.addWidget(empty, 0, 0, 1, columns)
        self.search_grid.setRowStretch((len(visible) + columns - 1) // columns, 1)

    def _select_search_action(self, action: ActionSpec, selected: ActionListRow) -> None:
        for row in self._search_cards:
            if isinstance(row, ActionListRow):
                row.set_selected(row is selected)
        self.inspect_action(action)

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        if self.stack.currentIndex() == self._search_page_idx:
            self._search_relayout_timer.start()

    def request_actions(self, actions: object) -> None:
        """Run a user-selected batch sequentially, retaining confirmation gates."""
        if self.runner.running:
            return
        selected = [action for action in list(actions) if isinstance(action, ActionSpec)]
        if not selected:
            self._toast("Nenhuma ação selecionada", "warning")
            return
        self._action_queue = selected[1:]
        self.request_action(selected[0])

    def request_action(self, action: ActionSpec) -> None:
        if self.runner.running:
            return
        values: dict[str, str] = {}
        if action.id == "windows.provision.player":
            dialog = WindowsInstallDialog(self)
            if dialog.exec() != WindowsInstallDialog.Accepted:
                return
            values = dialog.values()
            ProvisionPlayerWindow.open(
                self.root, self.runner, self,
                iso=values["input"],
                graphics=values["graphics"],
                image_index=values["image_index"],
                guest_login=values["guest_login"],
            )
            return
        if action.id == "windows.images.manage":
            from .image_manager_dialog import ImageManagerDialog
            dialog = ImageManagerDialog(
                self.root, self.runner, self.by_id, self,
                advanced=self.preferences.advanced_mode,
            )
            dialog.exec()
            pending = dialog.pending_action()
            if pending is not None:
                self.request_action(pending)
            return
        if action.parameters:
            dialog = ParameterDialog(action, self)
            if dialog.exec() != ParameterDialog.Accepted:
                return
            values = dialog.values()

        self.pending_action = action
        self.pending_value = values.get("input", "")
        self.pending_values = values
        self.log_view.clear()
        self.log_view.setVisible(self.preferences.advanced_mode)
        try:
            self.runner.start(action, preview=action.mutable, values=values)
        except (ValueError, RuntimeError) as exc:
            self.pending_action = None
            self.pending_value = ""
            self.pending_values = {}
            self._action_queue.clear()
            QMessageBox.warning(self, "Não foi possível iniciar", str(exc))

    def operation_started(self, command: str) -> None:
        self.status_text.setText("Pré-visualizando…" if self.runner.preview else "Executando…")
        self.status_dot.setObjectName("statusRunning")
        self.status_dot.style().unpolish(self.status_dot)
        self.status_dot.style().polish(self.status_dot)
        self.command_label.setText(command)
        self.command_label.setVisible(self.preferences.advanced_mode)
        self.cancel_button.setEnabled(True)
        self._operation_started_at = time.monotonic()
        self._elapsed_timer.start()
        self._update_elapsed()
        self.progress.setRange(0, 0)
        self.progress.show()
        self.registry.block_all(True)
        self.inspector.setEnabled(False)
        for card in self._search_cards:
            card.setEnabled(False)
        self.append_output(f"$ {command}\n", False)
        if not self.runner.preview:
            title = self.pending_action.title if self.pending_action is not None else "Executando operação"
            self.progress_dialog = ProgressDialog(
                title, command, self, advanced_mode=self.preferences.advanced_mode
            )
            self.progress_dialog.cancel_requested.connect(self.runner.cancel)
            self.progress_dialog.show()

    def append_output(self, text: str, error: bool) -> None:
        if error:
            self.log_view.appendPlainText("[stderr] " + text.rstrip())
        elif action is not None and action.mutable and result.ok and severity == "success":
            self._toast(f"{action_title} concluída com sucesso", "success")
        else:
            cursor = self.log_view.textCursor()
            cursor.movePosition(QTextCursor.MoveOperation.End)
            cursor.insertText(text)
            self.log_view.setTextCursor(cursor)
        scrollbar = self.log_view.verticalScrollBar()
        scrollbar.setValue(scrollbar.maximum())
        if self.progress_dialog is not None:
            self.progress_dialog.append_output(text, error)

    def update_progress(self, value: int) -> None:
        self.progress.setRange(0, 100)
        self.progress.setValue(value)
        if self.progress_dialog is not None:
            self.progress_dialog.set_progress(value)

    def operation_completed(self, result: OperationResult) -> None:
        start_failed = self._start_failed
        self._start_failed = False
        self.progress.hide()
        self._elapsed_timer.stop()
        self._update_elapsed(final=True)
        if self.progress_dialog is not None:
            self.progress_dialog.finish()
            self.progress_dialog.deleteLater()
            self.progress_dialog = None
        self.cancel_button.setEnabled(False)
        action = self.pending_action
        is_mutable = bool(action and action.mutable)
        severity = severity_for(result.parsed, result.exit_code, mutable=is_mutable)
        status_map = {"success": "Concluído", "warning": "Concluído com avisos", "error": "Falhou"}
        status_label = status_map.get(severity, "Falhou")
        self.status_text.setText(status_label)
        self.status_dot.setObjectName("statusSuccess" if severity == "success" else "statusWarning" if severity == "warning" else "statusError")
        self.status_dot.style().unpolish(self.status_dot)
        self.status_dot.style().polish(self.status_dot)
        self.registry.block_all(False)
        self.inspector.setEnabled(True)
        if not result.ok:
            self._failure_count += 1
        elif not result.preview:
            # A confirmed operation that succeeded clears the pending-failure
            # badge; preview runs must not clear it (no change was applied).
            self._failure_count = 0
        self._update_failure_summary()
        for card in self._search_cards:
            card.setEnabled(True)
        if self._closing:
            self.pending_action = None
            self.pending_value = ""
            self.pending_values = {}
            self._action_queue.clear()
            return
        action_title = action.title if action is not None else "Operação"
        if start_failed:
            pass  # operation_start_failed already told the user
        elif result.preview and action is not None:
            dialog = PreviewDialog(
                result, action, self, advanced_mode=self.preferences.advanced_mode
            )
            if dialog.exec() == PreviewDialog.Accepted:
                try:
                    self._bind_preview_result(action, result)
                except ValueError as exc:
                    self._action_queue.clear()
                    QMessageBox.warning(self, "Preview não aplicável", str(exc))
                    self._cancel_page_pending_action(action.id)
                    self.pending_action = None
                    self.pending_values = {}
                    return
                self.log_view.appendPlainText("\n--- execução confirmada ---\n")
                try:
                    self.runner.start(action, preview=False, values=self.pending_values)
                    return
                except (ValueError, RuntimeError) as exc:
                    self._action_queue.clear()
                    QMessageBox.warning(self, "Não foi possível iniciar", str(exc))
            self._cancel_page_pending_action(action.id)
            self._action_queue.clear()
        else:
            formatted = self._format_result(result)
            dialog = ResultDialog(
                result,
                formatted,
                self,
                severity=severity,
                advanced_mode=self.preferences.advanced_mode,
            )
            dialog.history_requested.connect(lambda: self.show_category("Resultados"))
            dialog.resolution_requested.connect(self._open_resolution)
            dialog.exec()
            verb_map = {"success": "concluída", "warning": "concluída com avisos", "error": "falhou"}
            verb = verb_map.get(severity, "falhou")
            self._toast(f"{action_title} {verb}", severity)
        self.pending_action = None
        self.pending_value = ""
        self.pending_values = {}
        if result.ok and self._action_queue:
            next_action = self._action_queue.pop(0)
            QTimer.singleShot(0, lambda: self.request_action(next_action))
        elif not result.ok:
            self._action_queue.clear()
        if not result.preview:
            page = self.registry.page_for(self.current_category)
            if page is not None:
                QTimer.singleShot(0, page.reload)

    def _bind_preview_result(self, action: ActionSpec, result: OperationResult) -> None:
        if not action.preview_bindings:
            return
        if not isinstance(result.parsed, dict):
            raise ValueError("preview não retornou resultado estruturado")
        blockers = result.parsed.get("blockers")
        if blockers:
            raise ValueError("plano contém bloqueios; revise compatibilidade e fontes")
        for parameter, result_key in action.preview_bindings:
            value = result.parsed.get(result_key)
            if not isinstance(value, (str, int)) or not str(value):
                raise ValueError(f"preview não retornou {result_key}")
            self.pending_values[parameter] = str(value)

    def _toast(self, message: str, state: str) -> None:
        toast = Toast(self, message, state)
        toast.popup()

    def _open_resolution(self, action_id: str) -> None:
        if action_id.startswith("windows."):
            self.show_category("Windows VM")
        elif action_id == "system.doctor":
            self.show_category("Visão geral")
        else:
            self.show_category("Visão geral")
            action = self.by_id.get("system.repair-plan")
            if action is not None:
                self.inspect_action(action)

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
        self._elapsed_timer.stop()
        self._operation_started_at = None
        self.elapsed_label.clear()
        self._failure_count += 1
        self._update_failure_summary()
        if self.pending_action is not None:
            self._cancel_page_pending_action(self.pending_action.id)
        QMessageBox.critical(self, "Falha ao iniciar", message)

    def _cancel_page_pending_action(self, action_id: str) -> None:
        page = self.registry.page_for(self.current_category)
        if page is not None:
            page.cancel_pending_action(action_id)

    def _update_elapsed(self, *, final: bool = False) -> None:
        if self._operation_started_at is None:
            if not final:
                self.elapsed_label.clear()
            return
        elapsed = max(0, int(time.monotonic() - self._operation_started_at))
        minutes, seconds = divmod(elapsed, 60)
        self.elapsed_label.setText(f"{minutes:02d}:{seconds:02d}")
        self.elapsed_label.setAccessibleName(f"Tempo decorrido: {minutes} minutos e {seconds} segundos")
        if final:
            self._operation_started_at = None

    def _update_failure_summary(self) -> None:
        if self._failure_count:
            text = f"{self._failure_count} falha{'s' if self._failure_count != 1 else ''} pendente{'s' if self._failure_count != 1 else ''}"
            self.global_context.setText(text)
            self.global_context.setProperty("state", "error")
            results = self.sidebar_buttons.get("Resultados")
            if results is not None:
                results.setText(f"Resultados ({self._failure_count})")
        else:
            self.global_context.setText("Nenhuma falha pendente")
            self.global_context.setProperty("state", "success")
        self.global_context.style().unpolish(self.global_context)
        self.global_context.style().polish(self.global_context)

    def cancel_or_clear(self) -> None:
        if self.runner.running:
            self.runner.cancel()
        elif self.search.text():
            self.search.clear()

    def toggle_logs(self) -> None:
        self.log_view.setVisible(not self.log_view.isVisible())

    def _set_advanced_mode(self, enabled: bool, *, persist: bool = True) -> None:
        enabled = bool(enabled)
        if persist:
            self.preferences.set_advanced_mode(enabled)
        self.mode_switch.blockSignals(True)
        self.mode_switch.setChecked(enabled)
        self.mode_switch.blockSignals(False)
        self.inspector.set_advanced_mode(enabled)
        self.registry.set_advanced_mode(enabled)
        self.command_label.setVisible(enabled and bool(self.command_label.text()))
        self.toggle_logs_button.setVisible(enabled or self._failure_count > 0)
        if not enabled:
            self.log_view.hide()

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
        self._closing = True
        self.runner.shutdown()
        if self._host_process is not None:
            self._host_process.kill()
            self._host_process.waitForFinished(500)
        event.accept()
