---
name: doctor
description: Diagnose Omni dashboard CLI, schema, profile, model, target, browser and Gemini health without installing or mutating configuration or dashboards.
argument-hint: "[path/to/dashboard.omni.jsonc]"
allowed-tools: Bash(bash:*), Read
---

# Diagnose Omni dashboards

## 0. Preflight — every invocation

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-setup.sh" --brief 2>&1 || true`

If absent, run manually. Read
@${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-contract.md. This skill never installs,
repairs, changes config, refreshes credentials, edits files or publishes content.
Chart-room's automatic schema writes are confined to a temporary diagnostic directory.

## 1. Scoped diagnostics

Read the source/profile selection if supplied and rerun the checker with `--file
FILE --profile PROFILE`; use `--model MODEL_UUID` before a source exists. `--offline`
probes only local capabilities. `--smoke` adds a tiny billable Gemini completion
containing no dashboard content. Otherwise model listing is reported separately
from API reachability. Do not equate a browser process with an attached MCP session.

Report failed dependencies separately from probes that could not run. Show the
code, consequence, exact remediation and the phase affected. Wrong-host profiles
stop before forwarding credentials. Expired credentials require official config
in the user's terminal; health output never includes tokens or raw API errors.
Preserve the distinction between authentication, model access, content read
access, publication policy and actual test-publish verification.

Print a completion ledger with **preflight, diagnostics**; each row has DONE,
SKIPPED or FAILED and a reason. A diagnostic may be DONE while reporting unhealthy
dependencies; say which remain blocked. Restate incomplete probes in prose and
recommend `/omni-dashboards:setup` only for repair. Do not perform repair here.
