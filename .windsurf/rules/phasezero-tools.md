---
description: Caveman always-on mode
trigger: always_on
---

<!-- BEGIN PHASEZERO TOOLS -->
Agent compatibility contract for PhaseZero workspaces.

- caveman: controls response style only. Keep terse technical output. Do not use it for command wrapping, memory, MCPs, or project architecture.
- rtk: wrap shell commands only when `rtk` resolves in PATH or the PhaseZero managed bin. If missing, run the command directly, record `rtk missing`, and continue. Never fail a task only because RTK is absent.
- ai-memory: use for persistent context and cross-agent handoff only when `ai-memory` resolves and wiring/server are healthy. If missing, continue with local context, record `ai-memory missing`, and do not invent memory writes.
- Ponytail: apply schema/codegen/Tauri/Rust architecture rules only in detected Ponytail workspaces or explicit opt-in. Do not apply Ponytail rules globally.

Modes:
- ready: caveman rules present, RTK available, ai-memory available.
- degraded: caveman rules present, RTK or ai-memory absent. Continue safely and report missing tool.
- off: user disabled this block.

Conflict rules:
- one role per tool: style=caveman, shell compression=rtk, memory/handoff=ai-memory, project architecture=Ponytail.
- no duplicate wrappers: do not stack RTK with other shell proxies unless a command explicitly asks.
- no secret writes: configs may reference managed secret stores, never paste keys into rules.
<!-- END PHASEZERO TOOLS -->
