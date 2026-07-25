"""PhaseZero Linux native control center."""

import json
from pathlib import Path


def _project_version() -> str:
    try:
        value = json.loads(
            Path(__file__).resolve().parents[2].joinpath("version.json").read_text(encoding="utf-8")
        )
        version = value.get("version")
        return version if isinstance(version, str) and version else "0+unknown"
    except (AttributeError, OSError, TypeError, json.JSONDecodeError):
        return "0+unknown"


__version__ = _project_version()
