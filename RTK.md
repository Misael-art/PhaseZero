# RTK - Rust Token Killer (Codex CLI)

**Usage**: Token-optimized CLI proxy for shell commands.

## Rule

Use `rtk` for shell commands when the executable resolves in PATH or the
PhaseZero managed bin. If `rtk` is missing, run the command directly, report
`rtk missing`, and continue. Do not fail work only because RTK is absent.

Examples:

```bash
rtk git status
rtk cargo test
rtk npm run build
rtk pytest -q
```

Windows Codex Desktop fallback:

```powershell
C:\Users\misae\.local\bin\rtk.exe git status
```

Use fallback path when current Codex Desktop session has not inherited updated
user PATH yet. After restarting Codex Desktop, `rtk` should resolve normally.

## Meta Commands

```bash
rtk gain            # Token savings analytics
rtk gain --history  # Recent command savings history
rtk proxy <cmd>     # Run raw command without filtering
```

## Verification

```bash
rtk --version
rtk gain
which rtk
```
