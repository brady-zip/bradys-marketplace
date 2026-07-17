# dark-factory

A dual-runtime plugin for the **dark factory agent radio** pattern: a live peer-messaging
channel between an interactive **Claude Code** session and an interactive **Codex**
session over the git ref `refs/h5i/msg`, driven by the external
[`h5i`](https://h5i.dev/) CLI. It consolidates the hand-copied radio pattern from
several repos into one source, and adds per-session **identity locking** with
automatic cleanup.

This replaces the previously duplicated, drift-prone set of files
(`.claude/commands/radio.md`, `.codex/prompts/radio.md`, `.codex/skills/radio/…`)
that lived independently in each repo.

## What it provides

| Surface | Runtime | Invoke | Purpose |
|---|---|---|---|
| `radio` **command** | Claude | `/radio [identity]` | Operator **listen loop** — persistent Monitor streams inbound messages; you respond until stopped. |
| `radio` **prompt** | Codex | `/radio` (project prompt) | Operator **listen loop** — blocking `h5i msg wait` poll (Codex has no Monitor). |
| `radio-ask` **skill** | both | `$radio-ask` / by description | One-off **ask / consult** round-trip (ask → wait → reply once). |
| `radio-setup` **skill** | Claude | by description | Coordinated per-repo setup for both runtimes. |

### Why the one-off skill is named `radio-ask` (not `radio`)

Within a Claude plugin, commands and skills share the `plugin:name` namespace, so a
`radio` command and a `radio` skill would collide. The **operator loop keeps the
established `/radio` name** (as in every source repo and the common 3-terminal
setup), and the one-off skill is `radio-ask` (`$radio-ask` in Codex). To flip this,
rename `skills/radio-ask/` → `skills/radio/` and rename the command instead.

## Identity & locking

Every radio command passes identity explicitly — `--as <self>` on reads/waits and
`--from <self>` on writes — because the h5i stored default is intentionally
untrusted in shared clones. Identity resolves as **argument > `$H5I_AGENT` >
runtime default** (`claude` under Claude, `codex` under Codex). `/radio roadmap` or
`/radio claude-roadmap` claims a distinct identity.

`scripts/identity-lock.sh` gives the **operator loop** a repo-local lock so two live
sessions never share an identity (which would race the shared inbox cursor and reply
view). Lock state lives inside `.git` (per-clone, uncommitted):
`.git/dark-factory/locks/<identity>.lock`.

- **Simple by design:** create-on-start / remove-on-end. No heartbeat, no TTL.
- **Claude cleanup is automatic:** the plugin's `SessionEnd` hook releases the lock
  when the session ends. The deployed repo also registers a repo-level `SessionEnd`
  hook so cleanup works for teammates without the plugin installed.
- **Backstop:** if a lock records a real, long-lived pid (the Claude Monitor's) and
  that process is dead, the next `acquire` reclaims it — so a crash never blocks the
  identity forever.
- **Codex limitation:** Codex has **no SessionEnd hook**. Its radio prompt releases
  the lock at loop-exit; a killed Codex session can leave a stale lock. Clear it
  with `.dark-factory/identity-lock.sh release <identity> --force`, or just use a
  different identity.

```
identity-lock.sh acquire <identity> [pid]   # claim (pid enables stale-reclaim)
identity-lock.sh release [identity] [--force]
identity-lock.sh release-hook               # stdin {session_id,cwd} — SessionEnd
identity-lock.sh status                      # list held identities
```

## Setup (per repo)

Claude consumes this plugin directly once installed. **Codex cannot consume a
Claude plugin**, so the `radio-setup` skill deploys committed copies into the target
repo for both runtimes. From inside the repo you want to onboard:

```bash
# preview
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" --check
# apply
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"
```

or just ask Claude to "set up dark factory in this repo" (invokes the `radio-setup`
skill). It runs preflight (git/h5i/node/jq/npx), `h5i init`, deploys the assets,
provisions **GSD (get-shit-done core)** for Codex (`npx … @opengsd/gsd-core` — pinned,
idempotent, `--skip-gsd` to opt out), merges `env.H5I_AGENT=claude` + the SessionEnd
cleanup hook into `.claude/settings.json`, and merges the Codex SessionStart prelude
adapter (`.codex/hooks/dark-factory-codex-session-start.cjs` + a `{"type":"commonjs"}`
boundary — the fix for h5i's `[`-leading prelude output being rejected as JSON) into
`.codex/hooks.json` — created if absent, appended without clobbering GSD's own entries.

Then: launch Codex as `H5I_AGENT=codex codex`, trust project hooks via Codex's
`/hooks`, and **commit** the deployed files (GSD-style resets discard uncommitted
work, and Codex reads the committed `.codex/` copies).

## How to: spin up a new project

End-to-end, from a fresh machine to an autonomous Codex build loop with a Claude
operator on the radio:

1. **Add the marketplace** (once per machine):
   ```
   /plugin marketplace add brady-zip/bradys-marketplace
   ```
2. **Install the plugin**:
   ```
   /plugin install dark-factory@bradys-marketplace
   ```
3. **Run setup in the target repo** — ask Claude to *"set up dark factory in this
   repo"* (invokes the `radio-setup` skill), then **commit** the deployed `.claude/`
   + `.codex/` files. See [Setup (per repo)](#setup-per-repo) for what it deploys.
4. **Open the three terminals** — see [Typical session (3 terminals)](#typical-session-3-terminals)
   below: `claude` → `/radio`, `H5I_AGENT=codex codex` → the radio prompt, and
   `h5i msg watch --all --tui`.
5. **Scaffold the project** — in the **Codex** terminal:
   ```
   $gsd-new-project
   ```
6. **Go autonomous** — then hand Codex the build loop, wired to the radio for
   anything it needs to check:
   ```
   $gsd-autonomous use $radio-ask for any questions/clarification/discuss
   ```
   Codex works autonomously and pings the Claude operator over the radio
   (`$radio-ask` → your `/radio` loop) whenever it needs a decision, clarification,
   or a design discussion.

## Typical session (3 terminals)

```
Terminal 1:  claude                    then  /radio
Terminal 2:  H5I_AGENT=codex codex     then  the radio prompt
Terminal 3:  h5i msg watch --all --tui
```

Then from either agent: `h5i msg ask --from <self> <peer> "…"`.

## Dual-runtime notes

- The portable unit is `SKILL.md` (Agent Skills open standard) — the same file
  works in both runtimes. Codex-only UI metadata lives in the ignored-by-Claude
  `agents/openai.yaml` sidecar.
- The operator loop is intentionally **two files** (Monitor vs. blocking wait) —
  one per runtime — because Claude's Monitor primitive has no Codex equivalent.
- Never converse via a headless `claude -p` / `codex exec` / `h5i env run … claude`.
  The radio is between two *live, interactive* sessions; a headless subprocess is a
  puppet, not the peer.

## Files

```
.claude-plugin/plugin.json     manifest
commands/radio.md              Claude operator loop (/radio)
skills/radio-ask/SKILL.md      one-off ask/consult (+ agents/openai.yaml sidecar)
skills/radio-setup/SKILL.md    coordinated setup skill
hooks/hooks.json               plugin-level SessionEnd -> release-identity
hooks/release-identity         SessionEnd cleanup script
scripts/identity-lock.sh       identity lock library (shared, deployed to repos)
scripts/setup.sh               deploy engine (--check/--dry-run/--force)
scripts/check-setup.sh         preflight/doctor
codex/prompts/radio.md         Codex operator loop
codex/hooks.json               SessionStart adapter entry (merge template for .codex/hooks.json)
codex/hooks/*.cjs, package.json  Codex prelude adapter + commonjs boundary
deploy-manifest.json           source -> dest mappings + GSD config for setup.sh
```
