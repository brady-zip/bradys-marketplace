---
name: setup
description: Set up local dependencies for Omni dashboard authoring and delegate personal authentication to the official Omni CLI. Does not grant permissions or configure CI credentials.
allowed-tools: Bash(bash:*), Read, AskUserQuestion
---

# Set up Omni dashboards

## 0. Preflight — every invocation

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill setup --offline --brief 2>&1 || true`

Run manually if absent. Setup is the remediation workflow: use failures to select
repairs, rather than claiming setup is complete. Read
@${CLAUDE_PLUGIN_ROOT}/knowledge/workflow-contract.md.

## 1. Local dependencies

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" --install`. It uses official
installers for ordinary dependencies, the checksum-pinned official Omni 1.3.1
archive on macOS, persistent llm with llm-gemini, and mise/Node 22. Existing llm
plugins are preserved. Explain exactly what changed. Unsupported platforms and an
existing untested Omni version are surfaced, not overwritten. An installed
chart-room executable is insufficient: require a released Omni-capable build and
the pinned schema. Never install the unreleased candidate as an accepted release.

## 2. Personal credentials and browser

The user enters secrets only in their terminal, through official tooling:

```bash
omni config init --name zip-omni --endpoint https://zip.omniapp.co
llm keys set gemini
```

Alternatively, the user may run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"
--configure-auth --profile zip-omni` interactively; it delegates to official config.
The pinned CLI has no top-level login command. Do not ask for tokens in chat, put
them in command arguments, or copy them into this plugin, source or reports.
Securely injected `OMNI_API_TOKEN` is supported. Never reuse a CI deploy token for
personal local authoring. No plugin-specific credential file is created.

Have the user attach their supported authenticated Chrome Beta session with remote
debugging enabled. Browser access does not prove API publishing authority. Resolve
model/content access through the owner; setup cannot mint credentials, grant roles,
enable AccessBoost or change organization publication policy.

## 3. Verify and report

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-setup.sh" --profile zip-omni` and then
include `--model MODEL_UUID` or `--file FILE` when that context exists. A Gemini
smoke check is explicit via `--smoke`; iteration always requires it. Use the
checker output, not the installer's exit code, as health evidence.

Print a ledger with **preflight, dependencies, credentials, verification** in that
order. Every row needs DONE, SKIPPED or FAILED and a reason. Restate incomplete
phases and exact next commands. Unknown/deferred probes do not count as validated
publishing. Give `/omni-dashboards:create-dashboard` as the next workflow when ready.
