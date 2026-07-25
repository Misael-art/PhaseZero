#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def payload(root: Path) -> dict:
    import sys

    sys.path.insert(0, str(root))
    from linux.ui_native.catalog import build_catalog

    actions = []
    for spec in build_catalog(root):
        entry = {
            "name": spec.id,
            "label": spec.title,
            "command": " ".join(["linux/pz", *spec.args]),
            "mutable": bool(spec.mutable),
            "require_plan": bool(spec.mutable),
            "module": spec.category,
            "elevated": bool(spec.elevated),
            "input_kind": spec.input_kind,
            "input_label": spec.input_label,
        }
        if spec.preview_args is not None:
            entry["plan_command"] = " ".join(["linux/pz", *spec.preview_args])
        actions.append(entry)
    return {"actions": actions}


def write(root: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload(root), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    write(args.root.resolve(), args.destination.expanduser().resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
