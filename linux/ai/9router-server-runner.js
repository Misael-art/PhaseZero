#!/usr/bin/env node
// PhaseZero systemd runner. Starts the packaged server without the upstream
// CLI lifecycle, whose startup intentionally SIGKILLs any listener on its port.
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const packageRoot = process.argv[2];
if (!packageRoot) {
  console.error("9Router package root missing");
  process.exit(2);
}

const hooksPath = path.join(packageRoot, "hooks", "sqliteRuntime.js");
const appRoot = path.join(packageRoot, "app");
const customServer = path.join(appRoot, "custom-server.js");
const server = fs.existsSync(customServer) ? customServer : path.join(appRoot, "server.js");
if (!fs.existsSync(server) || !fs.existsSync(hooksPath)) {
  console.error("9Router packaged server/runtime hooks missing");
  process.exit(1);
}

const { ensureSqliteRuntime, buildEnvWithRuntime } = require(hooksPath);
try {
  ensureSqliteRuntime({ silent: true });
} catch (error) {
  console.error(`9Router runtime preparation failed: ${error.message}`);
  process.exit(1);
}

const child = spawn(process.execPath, ["--dns-result-order=ipv4first", "--max-old-space-size=6144", server], {
  cwd: appRoot,
  stdio: "inherit",
  env: buildEnvWithRuntime(process.env),
});

for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(signal, () => {
    if (!child.killed) child.kill(signal);
  });
}
child.on("error", (error) => {
  console.error(`9Router server spawn failed: ${error.message}`);
  process.exit(1);
});
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 1);
});
