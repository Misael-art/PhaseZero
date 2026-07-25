"""Unified game library pipeline: scan -> plan -> apply -> verify -> rollback.

Declarative system registry consumed by CLI and UI. Envelopes are versioned
JSON (schema pz.emulation.library/v1); stdout human text is never a contract.
"""

SCHEMA = "pz.emulation.library/v1"
