"""CLI: pz deps status|install."""
from __future__ import annotations

import argparse
import json
import sys

from .engine import SCHEMA, DepsError, install, status


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pz deps",
        description="Dependências opcionais: o que falta e o que isso degrada.",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    report = commands.add_parser("status", help="Lista dependências e o que falta.")
    report.add_argument("--json", action="store_true")
    action = commands.add_parser("install", help="Instala dependências ausentes.")
    action.add_argument("ids", nargs="+", metavar="ID")
    # Installing system packages is privileged and not trivially undone, so it
    # never happens as a side effect of asking about it.
    action.add_argument("--confirm", action="store_true", required=True,
                        help="Obrigatório: confirma a instalação privilegiada.")
    action.add_argument("--json", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "status":
            payload = status()
            if args.json:
                print(json.dumps(payload, ensure_ascii=False, indent=2))
            else:
                print(f"distribuição: {payload['family']}")
                for entry in payload["dependencies"]:
                    mark = "ok " if entry["present"] else "AUSENTE"
                    print(f"  [{mark}] {entry['title']}")
                    if not entry["present"]:
                        print(f"          degrada: {entry['degrades']}")
                        print(f"          {entry.get('command') or entry['reason']}")
            return 0
        payload = install(args.ids)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 1 if payload["status"] == "failed" else 0
    except DepsError as exc:
        print(json.dumps({"schema": SCHEMA, "ok": False, "error": str(exc)}, ensure_ascii=False),
              file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
