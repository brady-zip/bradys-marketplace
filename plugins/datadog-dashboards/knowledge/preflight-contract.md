# Preflight and Completion Contract

Every skill in this plugin (`create-dashboard`, `expand-dashboard`, `iterate-dashboard`)
obeys the two rules below. They come from one real run that failed in two unrelated ways,
neither of which ever reached the user — they found out by looking at the result.

**Failure A — a diagnostic that was confidently wrong.** The old setup check probed
`uvx llm models | grep -i gemini` and reported no Gemini model on a machine that had
`llm`, `llm-gemini` and a valid key installed for three months. `uvx llm` runs an
ephemeral, plugin-less environment unless uv finds a persistent `llm` tool to reuse — and
whether it does depends on which `uv` wins the PATH race. Nothing was broken except the
question being asked. This is what Rule 1 fixes.

**Failure B — a handoff nobody enforced.** `create-dashboard` finished Phases 1–4, then
did not invoke `expand-dashboard`. No error, no context exhaustion. It had the queries in
hand and continuing inline felt like finishing work in progress. Because expand never ran,
iterate never ran either: no Gemini evaluation, no iteration report. **One skipped line
silently deleted two entire skills from the run.** This is what Rule 2 fixes.

**These two rules are not substitutes for each other.** Failure B was never
environment-blocked — preflight would have gone green and changed nothing about it. A
passing preflight says the machine is fine; it says nothing about whether the run was
complete. Do not let one stand in for the other.

## Rule 1 — Preflight runs on every invocation, and repairs what it can

Each SKILL.md carries this as an inline bash block in its Phase 0:

```
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill <create|expand|iterate> --brief 2>&1 || true`
```

Claude Code executes an inline `!` block when the skill is invoked and injects the output
into context, so the check runs whether or not anyone remembers to run it. That is
deliberate: the previous version was an instruction to run a command, and an instruction
is exactly the thing that got skipped.

`|| true` is also deliberate. A non-zero exit from an inline block aborts the entire skill
invocation and the model never sees the skill body — which would turn a BLOCKED preflight
into a bare "shell command failed" and throw away the remediation text. With `|| true` the
report is always injected, and the stop is driven by the `PREFLIGHT_STATUS` line, which
the model can actually read out to the user.

`--brief` exists so that paying this cost on every run is actually affordable in context: a
healthy machine reports two lines instead of forty. It elides only the list of checks that
*passed*. Whenever anything else was reported — repaired, deferred, or blocked — those blocks
print in full and the complete report is written to a log file whose path comes back as
`PREFLIGHT_LOG:`. Drop `--brief`, or `cat` that log, when a check itself looks wrong.

Note that **a deferral keeps the detail even though `PREFLIGHT_STATUS` stays `OK`**. Status
answers "can *this* skill run", and deferrals are by definition things this skill doesn't
need — so an OK status with deferrals is the normal shape of a `--skill create` run. It
briefly wasn't: `--brief` keyed its elision on `STATUS = OK` alone, so it dropped the
deferral block and deleted the log that held it, leaving the rule below ("warn the user
which dependency the next skill will hit") impossible to follow in the only mode the skills
actually invoke.

**Every time.** Not once per session, not "if it looks like it already passed", not
"the user just ran it". This plugin ships to people who don't know its internals, on
machines that drift between runs — a wiped `uv tool` directory, an expired Datadog key,
a Chrome Beta that isn't running today. A result from five minutes ago is not evidence
about now, and the script is deliberately cheap enough to pay for on each run.

The script installs what it can install without a human decision (`uv`, `llm` +
`llm-gemini`, `mise`, `node@22`, `jq`) and is idempotent, so a healthy machine no-ops.

### Reading the result

The last lines of output are machine-readable:

```
PREFLIGHT_STATUS: OK | REPAIRED | BLOCKED
PREFLIGHT_OK / PREFLIGHT_REPAIRED / PREFLIGHT_DEFERRED / PREFLIGHT_BLOCKED: <count>
```

| Status | What you do |
|---|---|
| `OK` | Say so in one line, then proceed. Still read `PREFLIGHT_DEFERRED` — see below. |
| `REPAIRED` | **Tell the user what was installed on their machine**, then proceed. Never install things silently — it is their machine. |
| `BLOCKED` | **STOP.** Show the user the `USER ACTION REQUIRED` block verbatim, including the exact fix commands. Do not start the workflow. Do not improvise a workaround. |

If `PREFLIGHT_DEFERRED > 0`, tell the user now which dependency the *next* skill in the
chain will hit, even though this one can proceed. Finding out at the handoff is the
failure this whole contract exists to prevent.

### When a check says it could not tell

Some checks report a third thing: not "healthy", not "broken", but **unanswerable in this
environment**. Preflight runs inside Claude Code's sandboxed Bash, where the process table
is unreadable (`pgrep` exits 3 with *"sysmond service not found"*, `ps` returns nothing) and
loopback probes get swallowed by a SOCKS `ALL_PROXY` unless they opt out. Those checks report
`DEFERRED` with wording that says so explicitly, and they never block.

That is deliberate, and it is the same lesson as Failure A: **an unanswerable question is not
a failed dependency.** Two checks used to get this wrong and hard-`BLOCKED` `--skill iterate`
on machines where both dependencies demonstrably worked — a `socksio` probe that shelled out
to `llm python`, which is not a subcommand and therefore failed identically whether or not
socksio was installed, and a `pgrep` for Chrome Beta that could never see a process. Both
were verified as false by the person they blocked. When you extend this script, a probe that
cannot distinguish "broken" from "cannot look" must report the latter.

And when you weaken a probe to stop it blocking, do not overshoot into believing it too
easily. The replacement Chrome check ordered its probes by how wrong each one can be rather
than by cost, because `curl` to the CDP port — the obvious test — returns rc=0 with a
zero-byte body in a sandboxed Bash whether or not anything is listening. Trusting that exit
status would report Chrome running having learned nothing. **A false positive here is worse
than the false negative it replaced**: a blocked run stops and tells the user, while a run
that wrongly believes it has a browser goes on to screenshot nothing and evaluate it — which
is the degraded-run-that-looks-successful the rule below forbids.

### The one thing you may never do

**Do not substitute your own judgement for a missing dependency.** If Gemini is
unavailable, you do not evaluate the dashboard yourself. If the browser MCP is
unavailable, you do not describe what you think the dashboard looks like. A degraded run
that looks successful is worse than a run that stops, because the user cannot tell the
difference.

## Rule 2 — Report every phase, including the ones you skipped

At the end of every skill invocation, print a completion ledger — one row per phase the
skill defines, no exceptions, in order:

```
## Completion ledger

| Phase | Status | Notes |
|---|---|---|
| 0. Preflight       | DONE    | OK — 15 checks passed |
| 1. Intent          | DONE    | 4 intent questions recorded |
| 2. Structure       | DONE    | 5 sections, layout_type=ordered |
| 3. chart-room init | DONE    | test + prod provisioned |
| 4. Record _meta    | DONE    | _meta written to checkout.dash.json |
| 5. Handoff         | SKIPPED | user asked to stop after init |
```

`Status` is `DONE`, `SKIPPED`, or `FAILED`. **A `SKIPPED` or `FAILED` row must carry a
reason in Notes.** Skipping a phase is allowed — a user can legitimately want to stop
early. Skipping it *without telling anyone* is what is forbidden.

Before printing the ledger, walk the skill's phase list and check each one against what
you actually did. Do not reconstruct it from memory of what you intended to do.

If any row is `SKIPPED` or `FAILED`, restate those rows in prose beneath the table so
they are visible to someone who skims past a markdown table, and say what the user should
do about each.
