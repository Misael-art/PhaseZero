"""Ledger de mutações + store central de backups (correções 1 e 2).

Todos os testes rodam no fake-home do fixture ``host_sandbox``: sem sudo, sem
tocar o ``$HOME`` real e sem chegar perto de ``~/Emulation``.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def read_ledger(sandbox) -> list[dict]:
    if not sandbox.ledger.exists():
        return []
    return [
        json.loads(line)
        for line in sandbox.ledger.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


# --- schema ---------------------------------------------------------------

LEDGER_FIELDS = {
    "operation_id",
    "module",
    "action",
    "timestamp",
    "created",
    "modified",
    "backups",
    "services",
    "packages",
    "scope",
    "reversible",
    "rollback_cmd",
}


def test_ledger_record_writes_full_schema(host_sandbox):
    host_sandbox.bash_lib(
        'ledger_record --module steamdeck --action enable-service '
        '--service "user:phasezero-demo.service" --package "pacman:jq" '
        '--scope user --reversible true --rollback-cmd "systemctl --user disable demo"'
    )
    entries = read_ledger(host_sandbox)
    assert len(entries) == 1
    entry = entries[0]
    assert set(entry) == LEDGER_FIELDS
    assert entry["module"] == "steamdeck"
    assert entry["action"] == "enable-service"
    assert entry["services"] == ["user:phasezero-demo.service"]
    assert entry["packages"] == ["pacman:jq"]
    assert entry["scope"] == "user"
    assert entry["reversible"] is True
    assert entry["operation_id"] == "test-operation"


def test_ledger_is_silent_in_dry_run(host_sandbox):
    """Dry-run é leave-no-trace de verdade: não grava ledger."""
    host_sandbox.bash_lib(
        'PZ_DRY_RUN=1 ledger_record --module ai --action write-managed-file '
        '--created "$HOME/.config/never-written.json"'
    )
    assert read_ledger(host_sandbox) == []


def test_ledger_handles_paths_with_spaces_and_quotes(host_sandbox):
    host_sandbox.bash_lib(
        'ledger_record --module emulation --action write-managed-file '
        '--created "$HOME/.config/nome com espaço/arquivo \\"aspas\\".json"'
    )
    entries = read_ledger(host_sandbox)
    assert len(entries) == 1
    assert entries[0]["created"] == [
        f'{host_sandbox.home}/.config/nome com espaço/arquivo "aspas".json'
    ]


# --- pz_write_managed_file → ledger ---------------------------------------


def test_new_file_is_recorded_as_created(host_sandbox):
    host_sandbox.bash_lib(
        'printf \'{"_managedBy":"phasezero"}\\n\' '
        '| pz_write_managed_file "$HOME/.config/novo.json" user'
    )
    entries = [e for e in read_ledger(host_sandbox) if e["action"] == "write-managed-file"]
    assert len(entries) == 1
    assert entries[0]["created"] == [f"{host_sandbox.home}/.config/novo.json"]
    assert entries[0]["modified"] == []
    assert entries[0]["reversible"] is True
    assert entries[0]["rollback_cmd"].startswith("rm -f --")


def test_existing_file_is_recorded_as_modified_with_backup(host_sandbox):
    target = host_sandbox.home / ".config/existente.json"
    target.write_text("conteudo-original\n", encoding="utf-8")

    host_sandbox.bash_lib(
        'printf \'novo\\n\' | pz_write_managed_file "$HOME/.config/existente.json" user'
    )

    entries = [e for e in read_ledger(host_sandbox) if e["action"] == "write-managed-file"]
    assert len(entries) == 1
    entry = entries[0]
    assert entry["modified"] == [str(target)]
    assert entry["created"] == []
    assert len(entry["backups"]) == 1

    backup = Path(entry["backups"][0])
    assert backup.is_file()
    assert backup.read_text(encoding="utf-8") == "conteudo-original\n"
    # o backup vive no store central, NUNCA ao lado do original
    assert host_sandbox.backups in backup.parents
    assert not list(target.parent.glob("existente.json.bak.*"))


# --- store central de backups ---------------------------------------------


def test_backup_never_lands_next_to_the_original(host_sandbox):
    target = host_sandbox.home / ".config/algum.conf"
    target.write_text("v1\n", encoding="utf-8")
    host_sandbox.bash_lib('pz_backup_file "$HOME/.config/algum.conf" user >/dev/null')

    assert host_sandbox.legacy_baks_outside_store() == []
    group = next(host_sandbox.backups.iterdir())
    assert (group / "origin").read_text(encoding="utf-8").strip() == str(target)


def test_backup_is_dry_run_aware(host_sandbox):
    target = host_sandbox.home / ".config/algum.conf"
    target.write_text("v1\n", encoding="utf-8")
    before = host_sandbox.snapshot()

    result = host_sandbox.bash_lib(
        'PZ_DRY_RUN=1 pz_backup_file "$HOME/.config/algum.conf" user'
    )
    # planeja o destino sem criar nada
    assert "/backups/" in result.stdout
    assert not host_sandbox.backups.exists() or not any(host_sandbox.backups.iterdir())
    assert host_sandbox.delta(before) == set()


def test_restore_reads_the_central_store(host_sandbox):
    target = host_sandbox.home / ".config/algum.conf"
    target.write_text("original\n", encoding="utf-8")
    host_sandbox.bash_lib('pz_backup_file "$HOME/.config/algum.conf" user >/dev/null')
    target.write_text("estragado\n", encoding="utf-8")

    host_sandbox.bash_lib('pz_restore_file "$HOME/.config/algum.conf" user')
    assert target.read_text(encoding="utf-8") == "original\n"


def test_restore_dual_reads_legacy_backups(host_sandbox):
    """Backups feitos por versões anteriores continuam restauráveis."""
    target = host_sandbox.home / ".config/legado.conf"
    target.write_text("estragado\n", encoding="utf-8")
    # backup legado no formato antigo, ao lado do original
    legacy = target.with_name("legado.conf.bak.1700000000.42.7")
    legacy.write_text("conteudo-legado\n", encoding="utf-8")

    result = host_sandbox.bash_lib('pz_restore_file "$HOME/.config/legado.conf" user')
    assert result.returncode == 0, result.stderr
    assert target.read_text(encoding="utf-8") == "conteudo-legado\n"


def test_new_store_wins_over_legacy_backup(host_sandbox):
    target = host_sandbox.home / ".config/ambos.conf"
    target.write_text("atual\n", encoding="utf-8")
    legacy = target.with_name("ambos.conf.bak.1700000000")
    legacy.write_text("legado\n", encoding="utf-8")

    host_sandbox.bash_lib('pz_backup_file "$HOME/.config/ambos.conf" user >/dev/null')
    target.write_text("estragado\n", encoding="utf-8")
    host_sandbox.bash_lib('pz_restore_file "$HOME/.config/ambos.conf" user')

    assert target.read_text(encoding="utf-8") == "atual\n"


# --- migração de backups legados (correção 1) -----------------------------


def seed_legacy_baks(sandbox) -> dict[str, Path]:
    paths = {
        "wrapper": sandbox.home / ".local/bin/phasezero-demo.bak.1700000000.123.4567",
        "unit": sandbox.home / ".config/systemd/user/phasezero-x.service.bak.1700000001",
        "continue": sandbox.home / ".continue/config.json.bak.1700000002",
        "kwin": sandbox.home / ".config/kwinrulesrc.phasezero.bak.1700000003",
    }
    for path in paths.values():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("legado\n", encoding="utf-8")
    return paths


def test_migration_dry_run_moves_nothing(host_sandbox):
    seed_legacy_baks(host_sandbox)
    before = host_sandbox.snapshot()

    result = host_sandbox.pz("host", "backups", "migrate")
    assert result.returncode == 0, result.stderr
    assert "[dry] migrar" in result.stdout
    assert host_sandbox.delta_outside_state(before) == set()
    assert len(host_sandbox.legacy_baks_outside_store()) == 4


def test_migration_apply_centralizes_every_legacy_bak(host_sandbox):
    seed_legacy_baks(host_sandbox)

    result = host_sandbox.pz("host", "backups", "migrate", "--apply")
    assert result.returncode == 0, result.stderr

    # critério da correção 1: ZERO .bak PhaseZero fora do store
    assert host_sandbox.legacy_baks_outside_store() == []
    assert len(list(host_sandbox.backups.iterdir())) == 4
    host_sandbox.assert_emulation_intact()


def test_migration_is_idempotent(host_sandbox):
    seed_legacy_baks(host_sandbox)
    host_sandbox.pz("host", "backups", "migrate", "--apply")
    after_first = host_sandbox.snapshot()

    second = host_sandbox.pz("host", "backups", "migrate", "--apply")
    assert second.returncode == 0, second.stderr
    assert "0 movido(s)" in second.stderr + second.stdout

    # a segunda passada só pode ter acrescentado linhas de log
    new_paths = host_sandbox.snapshot() - after_first
    assert new_paths <= {".local/state/phasezero/pz.log.1"}


def test_migration_preserves_the_backed_up_content(host_sandbox):
    paths = seed_legacy_baks(host_sandbox)
    paths["continue"].write_text("conteudo-que-importa\n", encoding="utf-8")

    host_sandbox.pz("host", "backups", "migrate", "--apply")

    stored = list(host_sandbox.backups.rglob("config.json.bak.*"))
    assert len(stored) == 1
    assert stored[0].read_text(encoding="utf-8") == "conteudo-que-importa\n"


def test_migration_never_walks_into_emulation(host_sandbox):
    """Um .bak dentro de ~/Emulation é dado do usuário: intocável."""
    rom_bak = host_sandbox.emulation / "roms/snes/save.srm.bak.1700000000"
    rom_bak.write_text("save do usuário\n", encoding="utf-8")

    host_sandbox.pz("host", "backups", "migrate", "--apply")

    assert rom_bak.is_file()
    assert rom_bak.read_text(encoding="utf-8") == "save do usuário\n"
    host_sandbox.assert_emulation_intact()


def test_migration_ignores_unrelated_bak_files(host_sandbox):
    """Só varremos diretórios onde o PhaseZero comprovadamente grava."""
    foreign = host_sandbox.home / "Documentos/planilha.xlsx.bak.1700000000"
    foreign.parent.mkdir(parents=True, exist_ok=True)
    foreign.write_text("arquivo de outro app\n", encoding="utf-8")

    host_sandbox.pz("host", "backups", "migrate", "--apply")

    assert foreign.is_file(), "migração varreu fora das raízes curadas"


def test_migration_records_itself_in_the_ledger(host_sandbox):
    seed_legacy_baks(host_sandbox)
    host_sandbox.pz("host", "backups", "migrate", "--apply")

    actions = [e["action"] for e in read_ledger(host_sandbox)]
    assert actions.count("migrate-legacy-backup") == 4


# --- host status ----------------------------------------------------------


def test_host_status_emits_valid_json_and_flags_pending_legacy(host_sandbox):
    seed_legacy_baks(host_sandbox)
    result = host_sandbox.pz("host", "status")
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["ok"] is True
    assert payload["legacyBaksPending"] == 4
    assert payload["status"] == "attention"
    assert payload["preserved"] == [str(host_sandbox.emulation)]

    host_sandbox.pz("host", "backups", "migrate", "--apply")
    payload = json.loads(host_sandbox.pz("host", "status").stdout)
    assert payload["legacyBaksPending"] == 0
    assert payload["status"] == "ok"


# --- cobertura do ledger (correção 2) -------------------------------------


def test_host_surface_map_exists_and_lists_every_module(tmp_path):
    surface = ROOT / "docs/host-surface.md"
    assert surface.is_file(), "mapa docs/host-surface.md ausente (correção 2)"
    text = surface.read_text(encoding="utf-8")
    for module in (
        "steamdeck",
        "windows-vm",
        "waydroid",
        "emulation",
        "server",
        "ai",
        "boot",
        "capabilities",
    ):
        assert module in text, f"módulo ausente no mapa de host-surface: {module}"


@pytest.mark.parametrize(
    "script",
    [
        "linux/lib/common.sh",
        "linux/lib/ledger.sh",
        "linux/lib/systemd.sh",
        "linux/host.sh",
    ],
)
def test_hygiene_scripts_parse(host_sandbox, script):
    result = host_sandbox.run("bash", "-n", str(ROOT / script))
    assert result.returncode == 0, result.stderr


# Regressão: `"$X.bak.` / `"${X}.bak.` deriva o destino do PRÓPRIO path de
# origem — é exatamente o padrão "backup ao lado do original" que a correção 1
# eliminou. Destinos que partem de uma variável de diretório de backup
# (`$MCP_BACKUP_DIR/...`, `$backup_dir/...`) são legítimos.
SIDECAR_BACKUP = re.compile(
    r'"\$\{?(?P<var>\w+)\}?(?:\.phasezero)?\.bak\.\$\(date|'
    r'path\.with_name\(f"\{path\.name\}\.bak\.'
)

LIB_OWNERS = {"common.sh", "ledger.sh", "pz_hostbackup.py", "host.sh"}


def test_no_module_writes_backups_next_to_the_original():
    """Nenhum script pode voltar a gravar `.bak` ao lado do arquivo original."""
    offenders: list[str] = []
    for path in (ROOT / "linux").rglob("*"):
        if not path.is_file():
            continue
        if path.suffix not in (".sh", ".py") and path.name != "pz":
            continue
        if path.name in LIB_OWNERS:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for number, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if SIDECAR_BACKUP.search(stripped):
                offenders.append(f"{path.relative_to(ROOT)}:{number}: {stripped}")
    assert offenders == [], "backups gravados ao lado do original:\n" + "\n".join(offenders)


def test_sidecar_backup_detector_actually_detects(tmp_path):
    """O detector acima só vale se pegar o padrão que ele diz proibir."""
    assert SIDECAR_BACKUP.search('cp "$cfg" "${cfg}.bak.$(date +%s)"')
    assert SIDECAR_BACKUP.search('cp -p "$KWINRULES" "$KWINRULES.phasezero.bak.$(date +%s%N)"')
    assert SIDECAR_BACKUP.search(
        'shutil.copy2(path, path.with_name(f"{path.name}.bak.{int(time.time())}"))'
    )
    # destino em diretório de backup dedicado não é sidecar
    assert not SIDECAR_BACKUP.search('backup="$MCP_BACKUP_DIR/${label}.bak.$(date +%s%N)"')
    assert not SIDECAR_BACKUP.search('backup="$backup_dir/${name}.bak.$(date +%Y%m%d).$$"')
