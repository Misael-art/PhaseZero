from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import apply as apply_mod
from . import plan as plan_mod
from . import scan as scan_mod


def build_argparser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pz emulation library",
        description=(
            "Biblioteca de jogos unificada: scan -> plan -> apply -> verify "
            "-> rollback"
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    scan = sub.add_parser("scan", help="Analisar origem (somente leitura)")
    scan.add_argument(
        "--scope", choices=("library", "directory", "files"), default="library"
    )
    scan.add_argument("--input", type=Path, action="append", default=[])
    scan.add_argument("--json", action="store_true")

    plan = sub.add_parser("plan", help="Gerar plano a partir de um scan")
    plan.add_argument("--scan-id", required=True)
    plan.add_argument("--json", action="store_true")

    apply_cmd = sub.add_parser("apply", help="Executar ações de um plano")
    apply_cmd.add_argument("--plan-id", required=True)
    apply_cmd.add_argument("--confirm", default="")
    apply_cmd.add_argument("--dry-run", action="store_true")
    apply_cmd.add_argument("--json", action="store_true")

    verify = sub.add_parser("verify", help="Validar uma operação aplicada")
    verify.add_argument("--operation-id", required=True)
    verify.add_argument("--json", action="store_true")

    rollback = sub.add_parser("rollback", help="Reverter uma operação aplicada")
    rollback.add_argument("--operation-id", required=True)
    rollback.add_argument("--json", action="store_true")

    return parser


def _human_scan(payload: dict) -> None:
    summary = payload["summary"]
    print(
        f"Jogos: {summary['games']}  prontos: {summary['ready']}  "
        f"ações: {summary['actionsRecommended']}  bloqueados: {summary['blocked']}  "
        f"não reconhecidos: {summary['unknown']}"
    )
    for item in payload["items"]:
        system = item.get("systemName") or "desconhecido"
        origin = item.get("origin") or item.get("format", "")
        destination = item.get("destination") or "-"
        print(f"  {item['game']} · {system} · {origin} · {destination}")
        print(f"    {item['state']}: {item['recommendation']}")
    print(f"scanId: {payload['scanId']}")


def main(argv: list[str] | None = None) -> int:
    args = build_argparser().parse_args(argv)

    if args.command == "scan":
        payload = scan_mod.run(args.scope, list(args.input))
    elif args.command == "plan":
        payload = plan_mod.run(args.scan_id)
    elif args.command == "apply":
        payload = apply_mod.run(args.plan_id, args.confirm, args.dry_run)
    elif args.command == "verify":
        payload = apply_mod.verify(args.operation_id)
    else:
        payload = apply_mod.rollback(args.operation_id)

    if args.json:
        print(json.dumps(payload, ensure_ascii=False))
    elif payload.get("status") == "fail" and payload.get("error"):
        print(payload["error"], file=sys.stderr)
    elif payload["kind"] == "scan":
        _human_scan(payload)
    else:
        print(json.dumps(payload, ensure_ascii=False, indent=1))
    return 0 if payload.get("status") in ("ok", "partial") else 1


if __name__ == "__main__":
    sys.exit(main())
