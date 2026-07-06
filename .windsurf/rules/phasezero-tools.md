---
description: PhaseZero agent compatibility
trigger: always_on
---

<!-- BEGIN PHASEZERO TOOLS -->
Agent compatibility contract for PhaseZero workspaces.

- caveman: controls response style only. Keep terse technical output. Do not use it for command wrapping, memory, MCPs, or project architecture.
- rtk: wrap shell commands only when `rtk` resolves in PATH or the PhaseZero managed bin. If missing, run the command directly, record `rtk missing`, and continue. Never fail a task only because RTK is absent.
- ai-memory: use for persistent context and cross-agent handoff only when `ai-memory` resolves and wiring/server are healthy. If missing, continue with local context, record `ai-memory missing`, and do not invent memory writes.
- admin escalation: use `phasezero-admin` or `bigsudo` for commands requiring root/admin on Linux. Never configure passwordless sudo or store passwords. If absent, run `linux/pz ai setup admin`.
- Ponytail: apply schema/codegen/Tauri/Rust architecture rules only in detected Ponytail workspaces or explicit opt-in. Do not apply Ponytail rules globally.

Modes:
- ready: caveman rules present, RTK available, ai-memory available, admin bridge available.
- degraded: caveman rules present, RTK, ai-memory, or admin bridge absent. Continue safely and report missing tool.
- off: user disabled this block.

Conflict rules:
- one role per tool: style=caveman, shell compression=rtk, memory/handoff=ai-memory, project architecture=Ponytail.
- no duplicate wrappers: do not stack RTK with other shell proxies unless a command explicitly asks.
- admin escalation stays explicit: prefer `phasezero-admin`; use `sudo` only when user explicitly requests or host lacks graphical escalation.
- no secret writes: configs may reference managed secret stores, never paste keys into rules.

<!-- END PHASEZERO TOOLS -->

<!-- BEGIN PONYTAIL ARCHITECTURE -->
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

<!-- END PONYTAIL ARCHITECTURE -->
