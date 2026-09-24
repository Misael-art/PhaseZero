"""Regenerate the checked-in PXA-001 action migration map."""

from __future__ import annotations

import json
from pathlib import Path

from linux.ui_native.product_inventory import inventory_manifest


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "linux" / "ui_native" / "product_inventory.json"


def main() -> None:
    payload = inventory_manifest(ROOT)
    compact = lambda item: json.dumps(item, ensure_ascii=False, separators=(",", ":"))
    lines = ["{", f'  "schemaVersion": {payload["schemaVersion"]},',
             f'  "source": {compact(payload["source"])},',
             f'  "platform": {compact(payload["platform"])},',
             f'  "actionCount": {payload["actionCount"]},',
             f'  "dynamicActionPatterns": {compact(payload["dynamicActionPatterns"])},',
             '  "products": [']
    lines.extend(f"    {compact(item)}{',' if index < len(payload['products']) - 1 else ''}"
                 for index, item in enumerate(payload["products"]))
    lines.append('  ],')
    lines.append('  "actions": [')
    lines.extend(f"    {compact(item)}{',' if index < len(payload['actions']) - 1 else ''}"
                 for index, item in enumerate(payload["actions"]))
    lines.extend(['  ]', '}'])
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{OUTPUT}: {payload['actionCount']} actions, {len(payload['products'])} products")


if __name__ == "__main__":
    main()
