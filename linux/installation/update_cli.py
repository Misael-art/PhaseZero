from __future__ import annotations

import argparse
import json
import sys

from .manager import InstallationError
from .self_update import apply_update, check, create_update_plan


def main() -> int:
    parser = argparse.ArgumentParser(prog="pz self-update")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    commands.add_parser("plan")
    apply = commands.add_parser("apply")
    apply.add_argument("--plan-id", required=True)
    apply.add_argument("--confirm", required=True)
    args = parser.parse_args()
    try:
        payload = check() if args.command == "check" else create_update_plan() if args.command == "plan" else apply_update(args.plan_id, args.confirm)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0
    except (InstallationError, OSError, ValueError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
