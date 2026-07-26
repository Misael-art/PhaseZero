# PhaseZero doctor.sh severity policy

| Severity | Meaning | Example |
|----------|---------|---------|
| FAIL     | Host-breaking / data-loss risk / core feature cannot run | Disk truly full, KVM missing on a VM feature |
| ERROR    | Check itself failed to parse or execute | free parse returned empty, df output malformed |
| WARN     | Degraded but functional; user action recommended | AI tool missing, git-lfs not configured |
| INFO     | Optional capability absent by design | Waydroid not opted-in, emulation subsystem not installed |
| PASS     | Present and healthy | git-lfs installed, RAM >= 4GB |

## Audit rules

1. Every `check` call in doctor.sh matches its category's severity per the table above.
2. ERROR is used ONLY for engine-level parse/execution failures, never for host findings.
3. "Not installed" for a never-opted-in subsystem -> INFO, not WARN (see subsystems.conf).
4. All FAIL/ERROR states must be actionable (user knows what to run).
