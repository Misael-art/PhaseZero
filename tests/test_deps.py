"""Contratos das dependências opcionais.

O ponto central: nunca oferecer uma correção que não pode funcionar, e nunca
declarar sucesso sem reconferir que a dependência passou a existir.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.deps import engine  # noqa: E402


@pytest.fixture()
def absent(monkeypatch):
    """Host onde nada está instalado."""
    monkeypatch.setattr(engine, "_present", lambda spec: False)


def test_status_lists_what_each_missing_dep_degrades(absent, monkeypatch):
    monkeypatch.setenv("PZ_DEPS_DISTRO_FAMILY", "arch")
    payload = engine.status()
    assert payload["missingCount"] == len(engine.DEPENDENCIES)
    for entry in payload["dependencies"]:
        # Uma dependência sem explicação vira um pedido de fé.
        assert entry["degrades"], entry["id"]


def test_unknown_distro_refuses_to_invent_a_package(absent, monkeypatch):
    monkeypatch.setenv("PZ_DEPS_DISTRO_FAMILY", "haiku")
    payload = engine.status()
    assert payload["installable"] == []
    for entry in payload["dependencies"]:
        assert entry["installable"] is False
        assert "manualmente" in entry["reason"] or "desconhecido" in entry["reason"]


def test_distro_family_follows_id_like(tmp_path, monkeypatch):
    """Derivadas trazem ID próprio e empacotam como a distribuição-mãe."""
    release = tmp_path / "os-release"
    release.write_text('ID=biglinux\nID_LIKE="arch"\n', encoding="utf-8")
    monkeypatch.delenv("PZ_DEPS_DISTRO_FAMILY", raising=False)
    monkeypatch.setenv("PZ_DEPS_OS_RELEASE", str(release))
    assert engine.distro_family() == "arch"


def test_install_reprobes_instead_of_trusting_exit_code(absent, monkeypatch):
    """Um pacote pode instalar e ainda não fornecer o que sondamos."""
    monkeypatch.setenv("PZ_DEPS_DISTRO_FAMILY", "arch")
    calls = []

    def runner(argv):
        calls.append(argv)
        return 0, "instalado com sucesso"

    result = engine.install(["pillow"], runner=runner)
    assert calls, "o instalador precisa ter sido chamado"
    # O gerenciador disse 0, mas a sonda continua negativa: isso é falha.
    assert result["status"] == "failed"
    assert result["unresolved"] == ["pillow"]
    assert result["installed"] == []


def test_install_reports_success_only_when_probe_turns_positive(monkeypatch):
    monkeypatch.setenv("PZ_DEPS_DISTRO_FAMILY", "arch")
    state = {"present": False}
    monkeypatch.setattr(engine, "_present", lambda spec: state["present"])

    def runner(argv):
        state["present"] = True
        return 0, ""

    result = engine.install(["pillow"], runner=runner)
    assert result["status"] == "complete"
    assert result["installed"] == ["pillow"]


def test_install_skips_what_is_already_present(monkeypatch):
    monkeypatch.setenv("PZ_DEPS_DISTRO_FAMILY", "arch")
    monkeypatch.setattr(engine, "_present", lambda spec: True)
    called = []
    result = engine.install(["pillow"], runner=lambda argv: called.append(argv) or (0, ""))
    assert result["status"] == "noop"
    assert not called, "não deve invocar o gerenciador para algo já instalado"


def test_install_refuses_unknown_dependency(monkeypatch):
    monkeypatch.setenv("PZ_DEPS_DISTRO_FAMILY", "arch")
    with pytest.raises(engine.DepsError):
        engine.install(["inexistente"], runner=lambda argv: (0, ""))


def test_cli_install_requires_explicit_confirmation():
    """Instalar pacote de sistema não pode ser efeito colateral de perguntar."""
    from linux.deps.__main__ import _parser

    with pytest.raises(SystemExit):
        _parser().parse_args(["install", "pillow"])
    args = _parser().parse_args(["install", "pillow", "--confirm"])
    assert args.confirm is True
