from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "linux/ai/opencode_9router_manager.py"
SPEC = importlib.util.spec_from_file_location("opencode_9router_manager", MODULE_PATH)
assert SPEC and SPEC.loader
OC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OC)


class OpenCode9RouterManagerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="pz-opencode-route-test-")
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.old_env = os.environ.copy()
        os.environ.update(
            {
                "HOME": str(self.home),
                "XDG_CONFIG_HOME": str(self.home / ".config"),
                "XDG_DATA_HOME": str(self.home / ".local/share"),
                "PZ_OPENCODE_ROUTE_ROOT": str(self.home / ".local/share/opencode-route-installer"),
                "PZ_OPENCODE_SKIP_SYNC": "1",
                "PZ_OPENCODE_ROUTER_STATUS_JSON": json.dumps(
                    {
                        "healthy": True,
                        "listener": {"loopbackOnly": True},
                        "combos": {
                            "total": 5,
                            "names": [
                                "Default",
                                "claude-Combo_Cleude",
                                "phasezero-code",
                                "phasezero-analysis",
                                "phasezero-plan",
                            ],
                        },
                    }
                ),
                "PATH": f"{self.bin}:/usr/bin:/bin",
            }
        )
        self.receipt = self.root / "opencode-env.json"
        self.opencode = self._script(
            "opencode",
            """#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'opencode 1.18.4'; exit 0; fi
if [ "${PZ_TEST_OPENCODE_429:-0}" = "1" ]; then echo '429 rate_limit fixture' >&2; exit 1; fi
export PZ_TEST_OPENCODE_ARGS="$*"
python3 - <<'PY'
import json, os
keys = ('ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_BASE_URL','OPENAI_API_KEY','OPENAI_BASE_URL','BONSAI_API_KEY')
with open(os.environ['PZ_TEST_OPENCODE_RECEIPT'], 'w', encoding='utf-8') as handle:
    json.dump({'environment': {key: os.environ.get(key) for key in keys}, 'args': os.environ.get('PZ_TEST_OPENCODE_ARGS')}, handle)
print('{"type":"tool_use","tool":"read"} OPENCODE_TOOL_OK')
PY
""",
        )
        self.pacman = self._script(
            "pacman",
            """#!/usr/bin/env bash
if [ "$*" = "-Q opencode-desktop-bin" ]; then echo 'opencode-desktop-bin 1.18.4-1'; exit 0; fi
exit 1
""",
        )
        os.environ["PZ_OPENCODE_COMMAND"] = str(self.opencode)
        os.environ["PZ_PACMAN_COMMAND"] = str(self.pacman)
        os.environ["PZ_TEST_OPENCODE_RECEIPT"] = str(self.receipt)

        proxy_dir = self.home / ".config/phasezero/ai-proxies"
        proxy_dir.mkdir(parents=True)
        self.secret = "pz-local-router-secret"
        (proxy_dir / "9router.env").write_text(
            f"PHASEZERO_9ROUTER_API_KEY={self.secret}\n", encoding="utf-8"
        )
        os.chmod(proxy_dir / "9router.env", 0o600)
        settings = self.home / ".config/phasezero/9router/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"activeCombo": "claude-Combo_Cleude"}), encoding="utf-8")

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temp.cleanup()

    def _script(self, name: str, body: str) -> Path:
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        os.chmod(path, 0o700)
        return path

    def test_jsonc_parser_preserves_comment_markers_inside_strings(self) -> None:
        value = OC.parse_jsonc('{// comment\n"url":"https://example.test/a//b",/*x*/"items":[1,],}')
        self.assertEqual("https://example.test/a//b", value["url"])
        self.assertEqual([1], value["items"])

    def test_install_merges_config_removes_embedded_key_and_is_rollback_safe(self) -> None:
        config_dir = self.home / ".config/opencode"
        config_dir.mkdir(parents=True)
        canonical = config_dir / "opencode.json"
        legacy = config_dir / "opencode.jsonc"
        canonical_before = b'{"provider":{"9router":{"options":{"apiKey":"embedded-old"}}},"model":"9router/Default"}\n'
        legacy_before = b'{// legacy\n"mcp":{"ai-memory":{"type":"http","url":"http://127.0.0.1:49374/mcp"}},}\n'
        canonical.write_bytes(canonical_before)
        legacy.write_bytes(legacy_before)

        manager = OC.OpenCodeManager()
        result = manager.install(dry_run=False, yes=True)
        self.assertEqual("complete", result["status"])
        configured = json.loads(canonical.read_text(encoding="utf-8"))
        rendered = json.dumps(configured)
        self.assertNotIn(self.secret, rendered)
        self.assertEqual("9router/Default", configured["model"])
        self.assertIn("ai-memory", configured["mcp"])
        # every 9Router combo (incl. phasezero-*) must be selectable
        models = set(configured["provider"]["9router"]["models"].keys())
        self.assertIn("phasezero-code", models)
        self.assertIn("phasezero-analysis", models)
        self.assertIn("phasezero-plan", models)
        self.assertIn("Default", models)
        self.assertIn("claude-Combo_Cleude", models)
        self.assertEqual(
            f"{{file:{manager.router_key}}}", configured["provider"]["9router"]["options"]["apiKey"]
        )
        self.assertEqual(0o600, stat.S_IMODE(canonical.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE(manager.router_key.stat().st_mode))
        self.assertFalse(legacy.exists())
        self.assertEqual(1, len(list(config_dir.glob("opencode.jsonc.phasezero-migrated-*.bak"))))
        self.assertTrue(manager.verify()["ok"])

        config_mtime = canonical.stat().st_mtime_ns
        key_mtime = manager.router_key.stat().st_mtime_ns
        second = manager.install(dry_run=False, yes=True)
        self.assertEqual("complete", second["status"])
        self.assertEqual(config_mtime, canonical.stat().st_mtime_ns)
        self.assertEqual(key_mtime, manager.router_key.stat().st_mtime_ns)

        OC.cc.restore_manifest(Path(result["manifest"]))
        self.assertEqual(canonical_before, canonical.read_bytes())
        self.assertEqual(legacy_before, legacy.read_bytes())
        self.assertFalse(manager.router_key.exists())
        self.assertFalse(list(config_dir.glob("opencode.jsonc.phasezero-migrated-*.bak")))

    def test_dry_run_leaves_no_trace(self) -> None:
        manager = OC.OpenCodeManager()
        result = manager.install(dry_run=True, yes=True)
        self.assertTrue(result["dryRun"])
        self.assertFalse(manager.data_root.exists())
        self.assertFalse(manager.router_key.exists())

    def test_run_uses_9router_without_global_provider_variables(self) -> None:
        manager = OC.OpenCodeManager()
        manager.install(dry_run=False, yes=True)
        for key in OC.ROUTE_ENV_KEYS | {"BONSAI_API_KEY"}:
            os.environ[key] = "must-not-reach-child"
        self.assertEqual(0, manager.run("9router", ["run", "probe"]))
        child_env = json.loads(self.receipt.read_text(encoding="utf-8"))
        self.assertTrue(all(value is None for value in child_env["environment"].values()))
        self.assertIn("--model 9router/claude-Combo_Cleude", child_env["args"])
        with self.assertRaisesRegex(RuntimeError, "unsupported in OpenCode"):
            manager.run("direct", [])

    def test_live_verify_uses_synthetic_fixture(self) -> None:
        manager = OC.OpenCodeManager()
        manager.install(dry_run=False, yes=True)
        result = manager.verify(live=True)
        self.assertTrue(result["ok"])
        self.assertTrue(result["live"]["passed"])

    def test_live_verify_classifies_provider_rate_limit(self) -> None:
        manager = OC.OpenCodeManager()
        manager.install(dry_run=False, yes=True)
        os.environ["PZ_TEST_OPENCODE_429"] = "1"
        result = manager.verify(live=True)
        self.assertTrue(result["ok"])
        self.assertIsNone(result["live"]["passed"])
        self.assertEqual("provider-rate-limit", result["live"]["blockedReason"])

    def test_sync_catalog_exposes_all_combos_idempotently(self) -> None:
        config_dir = self.home / ".config/opencode"
        config_dir.mkdir(parents=True)
        canonical = config_dir / "opencode.json"
        # provider exposes only Default -> out of sync with 9Router combos
        canonical.write_text(
            json.dumps({"provider": {"9router": {"models": {"Default": {"name": "Default"}}}}}),
            encoding="utf-8",
        )
        manager = OC.OpenCodeManager()
        first = manager.sync_catalog(dry_run=False)
        self.assertTrue(first["updated"])
        configured = json.loads(canonical.read_text(encoding="utf-8"))
        models = set(configured["provider"]["9router"]["models"].keys())
        self.assertEqual(
            {"Default", "claude-Combo_Cleude", "phasezero-code", "phasezero-analysis", "phasezero-plan"},
            models,
        )
        self.assertEqual(0o600, stat.S_IMODE(canonical.stat().st_mode))
        # idempotent: second run reports no change
        second = manager.sync_catalog(dry_run=False)
        self.assertFalse(second["updated"])
        # status reports catalog in sync
        status = manager.status()
        self.assertTrue(status["configuration"]["catalogInSync"])
        self.assertEqual(sorted(models), sorted(status["configuration"]["models"]))

    def test_sync_catalog_dry_run_leaves_no_trace(self) -> None:
        config_dir = self.home / ".config/opencode"
        config_dir.mkdir(parents=True)
        canonical = config_dir / "opencode.json"
        before = json.dumps({"provider": {"9router": {"models": {"Default": {"name": "Default"}}}}})
        canonical.write_text(before, encoding="utf-8")
        manager = OC.OpenCodeManager()
        result = manager.sync_catalog(dry_run=True)
        self.assertTrue(result["dryRun"])
        self.assertEqual(before, canonical.read_text(encoding="utf-8"))

    def test_env_combos_fixture_wins(self) -> None:
        os.environ["PZ_OPENCODE_ROUTER_COMBOS_JSON"] = json.dumps(
            {"combos": [{"name": "Default"}, {"name": "solo-combo"}]}
        )
        try:
            manager = OC.OpenCodeManager()
            self.assertEqual(["Default", "solo-combo"], manager._combo_names())
        finally:
            os.environ.pop("PZ_OPENCODE_ROUTER_COMBOS_JSON", None)


if __name__ == "__main__":
    unittest.main()
