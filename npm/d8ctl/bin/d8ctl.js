#!/usr/bin/env node
// Launcher for @camunda8/d8ctl. d8ctl is a native binary; npm installs the
// one for this machine as an optional dependency
// (@camunda8/d8ctl-<platform>-<arch>). This file only finds and runs it:
// no install scripts, no downloads.
"use strict";

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const pkg = `@camunda8/d8ctl-${process.platform}-${process.arch}`;
const exe = process.platform === "win32" ? "d8ctl.exe" : "d8ctl";

let bin;
try {
  bin = require.resolve(`${pkg}/bin/${exe}`);
} catch {
  const supported = ["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64", "win32-x64"];
  const here = `${process.platform}-${process.arch}`;
  process.stderr.write(
    supported.includes(here)
      ? `d8ctl: ${pkg} is not installed. It is an optional dependency; reinstall without ` +
          `--omit=optional / --no-optional:\n  npm install -g @camunda8/d8ctl\n`
      : `d8ctl: no prebuilt binary for ${here} (supported: ${supported.join(", ")}).\n` +
          `See https://github.com/camunda/d8ctl#install\n`,
  );
  process.exit(1);
}

const r = spawnSync(bin, process.argv.slice(2), { stdio: "inherit", windowsHide: false });
if (r.error) {
  process.stderr.write(`d8ctl: cannot run ${path.basename(bin)}: ${r.error.message}\n`);
  process.exit(1);
}
if (r.signal) {
  // Re-raise so the caller sees the same signal d8ctl died of.
  process.kill(process.pid, r.signal);
}
process.exit(r.status ?? 1);
