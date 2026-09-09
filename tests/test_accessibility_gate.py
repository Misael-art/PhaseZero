"""UX-011 — piso de acessibilidade verificável a cada entrega.

Este arquivo é o gate mecânico: contraste dos dois temas, nome acessível
em todo controle de toda página real, alcance por teclado e ausência de
overflow horizontal em 150% e 200%.

O que ele NÃO é: sessão de usabilidade. Nenhum teste aqui prova que uma
pessoa leiga conclui a jornada — isso continua pendente e só se mede com
participantes.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractButton, QApplication, QComboBox, QLineEdit, QPlainTextEdit,
)

from linux.ui_native.a11y import (
    AA_LARGE, AA_TEXT, accessible_label, contrast_failures, contrast_ratio,
    contrast_report, relative_luminance,
)
from linux.ui_native.catalog import CATEGORIES, DASHBOARD
from linux.ui_native.tokens import DARK, LIGHT

ROOT = Path(__file__).resolve().parents[1]
INTERACTIVE = (QAbstractButton, QComboBox, QLineEdit)


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def window(qapp):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        win = MainWindow(ROOT)
        yield win
        win.close()


# ------------------------------------------------------------------ contraste
def test_luminance_and_ratio_match_the_wcag_reference():
    # Âncoras conhecidas: preto/branco = 21:1; cor contra ela mesma = 1:1.
    assert round(contrast_ratio("#000000", "#ffffff"), 2) == 21.0
    assert round(contrast_ratio("#7c4dff", "#7c4dff"), 2) == 1.0
    assert relative_luminance("#ffffff") == pytest.approx(1.0)
    assert relative_luminance("#000000") == pytest.approx(0.0)
    # Forma curta e maiúsculas são a mesma cor.
    assert contrast_ratio("#FFF", "#000000") == contrast_ratio("#ffffff", "#000")


@pytest.mark.parametrize("theme_name,tokens", [("dark", DARK), ("light", LIGHT)])
def test_every_readable_pair_meets_wcag_aa(theme_name, tokens):
    failures = contrast_failures(tokens)
    assert not failures, "\n".join(
        f"{theme_name}: {desc} = {ratio:.2f}:1, mínimo {minimum}:1"
        for desc, ratio, minimum in failures
    )


@pytest.mark.parametrize("tokens", [DARK, LIGHT], ids=["dark", "light"])
def test_focus_ring_is_perceivable_on_every_surface(tokens):
    """O anel de foco é o que diz onde o teclado está — 3:1 em toda superfície."""
    focus_pairs = [entry for entry in contrast_report(tokens) if entry[0].startswith("foco")]
    assert len(focus_pairs) >= 4
    for description, ratio, _minimum in focus_pairs:
        assert ratio >= AA_LARGE, f"{description}: {ratio:.2f}:1"


def test_the_gate_would_catch_a_regression():
    """Um gate que nunca reprova não é gate."""
    from dataclasses import replace

    broken = replace(DARK, text_dim="#3a3a44")  # cinza escuro sobre fundo escuro
    failures = contrast_failures(broken)
    assert failures, "contraste ilegível passou pelo gate"
    assert any("secundário" in desc for desc, _r, _m in failures)


# ------------------------------------------------------- nomes acessíveis/foco
def _children(page, types) -> list:
    found: list = []
    for kind in types:
        found.extend(page.findChildren(kind))
    return found


def _interactive(page) -> list:
    # Widgets internos do Qt (nome com prefixo "qt_", como o botão de canto
    # do QTableView) não são controles do produto: não os escrevemos, não
    # os rotulamos e o usuário não os opera.
    return [
        widget for widget in _children(page, INTERACTIVE)
        if (widget.isVisible() or widget.isVisibleTo(page))
        and not widget.objectName().startswith("qt_")
    ]


CATEGORY_IDS = [DASHBOARD[0]] + [row[0] for row in CATEGORIES]


@pytest.mark.parametrize("category", CATEGORY_IDS)
def test_every_control_announces_itself(window, qapp, category):
    """Nenhum controle mudo: leitor de tela sempre tem o que anunciar."""
    window.show_category(category)
    qapp.processEvents()
    page = window.registry.page_for(window.current_category)
    if page is None:
        pytest.skip(f"categoria sem página construída: {category}")
    mute = [
        widget.objectName() or widget.__class__.__name__
        for widget in _interactive(page)
        if not accessible_label(widget)
    ]
    assert not mute, f"{category}: controles sem nome acessível: {mute}"


@pytest.mark.parametrize("category", CATEGORY_IDS)
def test_controls_are_reachable_by_keyboard(window, qapp, category):
    """Todo controle habilitado aceita foco por Tab — sem becos só de mouse."""
    window.show_category(category)
    qapp.processEvents()
    page = window.registry.page_for(window.current_category)
    if page is None:
        pytest.skip(f"categoria sem página construída: {category}")
    unreachable = [
        widget.objectName() or accessible_label(widget)
        for widget in _interactive(page)
        if widget.isEnabled() and widget.focusPolicy() == Qt.NoFocus
    ]
    assert not unreachable, f"{category}: fora do alcance do teclado: {unreachable}"


def test_the_sidebar_is_operable_without_a_mouse(window, qapp):
    for name, button in window.sidebar_buttons.items():
        assert button.focusPolicy() != Qt.NoFocus, f"{name} não recebe foco"
        assert accessible_label(button), f"{name} não se anuncia"


# ------------------------------------------------------------------- escalas
@pytest.mark.parametrize("scale,width,height", [
    (1.5, 1280, 800), (1.5, 800, 600), (2.0, 1280, 800), (2.0, 800, 600),
])
@pytest.mark.parametrize("category", ["Início", "Homelab", "Windows VM"])
def test_no_horizontal_overflow_at_150_and_200_percent(window, qapp, scale, width, height, category):
    """150% e 200%: nada escapa pela lateral, em janela larga e estreita.

    A escala é aplicada às fontes — é o que muda tamanho de controle e
    quebra layout —, e o conteúdo é medido contra a largura do viewport.
    """
    font = qapp.font()
    original = font.pointSizeF()
    if original <= 0:
        pytest.skip("fonte sem tamanho em pontos neste ambiente")
    scaled = qapp.font()
    scaled.setPointSizeF(original * scale)
    qapp.setFont(scaled)
    try:
        window.show()
        window.resize(width, height)
        window.show_category(category)
        qapp.processEvents()
        page = window.registry.page_for(window.current_category)
        if page is None:
            pytest.skip(f"categoria sem página construída: {category}")
        qapp.processEvents()
        limit = window.width()
        overflow = [
            (widget.objectName() or widget.__class__.__name__, widget.mapTo(window, widget.rect().topRight()).x())
            for widget in _children(page, INTERACTIVE + (QPlainTextEdit,))
            if widget.isVisible()
            and widget.mapTo(window, widget.rect().topRight()).x() > limit
        ]
        assert not overflow, (
            f"{category} @ {scale:.0%} {width}x{height}: sai do viewport ({limit}px): {overflow[:4]}"
        )
    finally:
        restored = qapp.font()
        restored.setPointSizeF(original)
        qapp.setFont(restored)
        qapp.processEvents()
