#!/usr/bin/env node

// Codex SessionStart adapter for h5i.
//
// `h5i hook codex prelude` prints the current shared context (goal, branch,
// milestones, recent trace) as plain text that BEGINS with "[" — which Codex
// tries to parse as JSON and rejects as a malformed SessionStart payload. This
// adapter runs the prelude and re-wraps its stdout in the documented
// `hookSpecificOutput.additionalContext` envelope that both Codex and Claude
// Code accept. It also forces H5I_AGENT=codex when unset so the prelude reads
// the correct identity.
//
// Requires a CommonJS boundary: this file is .cjs and ships next to a
// package.json declaring {"type":"commonjs"} so it loads even when the repo
// root package.json is {"type":"module"}.

const { spawnSync } = require("node:child_process");

const result = spawnSync("h5i", ["hook", "codex", "prelude"], {
  encoding: "utf8",
  env: {
    ...process.env,
    H5I_AGENT: process.env.H5I_AGENT || "codex",
  },
});

if (result.stderr) {
  process.stderr.write(result.stderr);
}

if (result.error) {
  process.stderr.write(`${result.error.message}\n`);
  process.exit(1);
}

if (result.status !== 0) {
  process.exit(result.status ?? 1);
}

const additionalContext = result.stdout.trimEnd();

if (additionalContext) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext,
      },
    }),
  );
}
