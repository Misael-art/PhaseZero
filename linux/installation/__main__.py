from __future__ import annotations

import argparse
import json
import sys

from .manager import InstallationError, apply, create_plan, prune, status


def main() -> int:
    parser = argparse.ArgumentParser(prog="pz installation")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    plan = commands.add_parser("plan")
    plan.add_argument("--channel", default="user")
    execute = commands.add_parser("apply")
    execute.add_argument("--plan-id", required=True)
    execute.add_argument("--confirm", required=True)
    commands.add_parser("prune")
    args = parser.parse_args()
    try:
        if args.command == "status":
            payload = status()
        elif args.command == "plan":
            payload = create_plan(args.channel)
        elif args.command == "apply":
            payload = apply(args.plan_id, args.confirm)
        else:
            payload = prune()
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0
    except (InstallationError, OSError, ValueError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
