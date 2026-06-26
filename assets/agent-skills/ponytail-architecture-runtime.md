Ponytail architecture runtime.

Scope:
- Use only inside detected Ponytail workspaces or explicit opt-in.
- Keep frontend declarative. UI sends typed payloads; Rust/Tauri owns file I/O, schema validation, and SGDK code generation.
- Treat Ledger Schema `sgdk-import/v4` as the source of truth. Avoid scattered imperative import paths.
- Generate C headers/sources from templates or typed renderers. Do not concatenate ad hoc code across UI handlers.
- Validate generated artifacts with tests or build probes before claiming success.

Tool boundaries:
- Caveman controls response style only.
- RTK wraps shell output only when installed.
- ai-memory handles persistent context only when available.
- Ponytail rules guide project architecture only.

Safety:
- No auto-download of ROMs, BIOS, console keys, or proprietary assets.
- No destructive migration without backup and schema version check.
- Prefer dry-run, manifest diff, and rollback notes for generated files.
