# design-ops

Design ops commands for the UX team.

## Commands

| Command | Purpose |
|---|---|
| `/design-ops:ux-ticket-pr-completion-table [date range]` | Generates the UX Quality ticket completion table from Linear: pulls Done/Merged tickets carrying the "UX Quality" label for the current Zip fiscal quarter (or an explicit range), attributes each to a designer via an attached GitHub PR they authored — or one Z\* authored and assigned to them — and sweeps each designer's merged PRs to surface tracking gaps. |

## Requirements

- **Claude Code 2.x** (`claude --version`). Plugins are a Claude Code feature — see the note about
  the Claude desktop chat app below.
- **`python3`** — 3.9+, standard library only. Nothing to `pip install`.
- **`gh` authenticated** to an account with read access to `Greenbax/evergreen`: `gh auth status`.
  Required either way — GitHub is always read through `gh`.
- **Linear access, by one of two routes** (the command probes and picks automatically):
  - **`LINEAR_API_KEY`** in the environment, for an account that can read the `ziphq` workspace.
    Create one at Linear → Settings → Security & access → Personal API keys. Fastest, and the only
    route that works when running the script standalone.
  - **A Linear MCP server connected to Claude Code** — the claude.ai connector, a plugin-provided
    one, or a directly-configured server all work. No API key needed: the command fetches the
    tickets through the MCP and feeds them to the script, which still does the attribution. Check
    which route is live with:

    ```bash
    python3 scripts/ux_pr_table.py --probe   # prints "api" or "mcp" plus the reason
    ```

## Install — Claude Code CLI

```bash
# 1. add this marketplace (public repo; once per machine)
claude plugin marketplace add brady-zip/bradys-marketplace

# 2. install the plugin
claude plugin install design-ops@bradys-marketplace

# 3. confirm
claude plugin list | grep design-ops
```

Then start (or restart) `claude` and run `/design-ops:ux-ticket-pr-completion-table`.

Scope: `claude plugin install` defaults to `--scope user`, which enables the plugin for every
project on the machine. Use `--scope project` to commit the dependency into a repo's
`.claude/settings.json` so teammates get it automatically, or `--scope local` for just your own
checkout of one repo.

The marketplace is a monorepo, so a narrower checkout is available if you only want this plugin:

```bash
claude plugin marketplace add brady-zip/bradys-marketplace --sparse .claude-plugin plugins/design-ops
```

## Install — Claude Code desktop app

The desktop app runs the same Claude Code engine and reads the same `~/.claude` config, so there are
two equivalent routes:

- **Already installed via the CLI at user scope?** Nothing more to do — the desktop app picks it up
  on next launch.
- **Installing from inside the app:** open a session and run `/plugin`. Choose *Add marketplace*,
  enter `brady-zip/bradys-marketplace`, then *Install* → `design-ops`. The direct forms
  `/plugin marketplace add brady-zip/bradys-marketplace` and
  `/plugin install design-ops@bradys-marketplace` work the same way.

One caveat specific to the desktop app: because it launches from the GUI rather than your terminal,
it does not always inherit environment variables exported from `~/.zshrc` — and this plugin needs
`LINEAR_API_KEY`. If the command reports `LINEAR_API_KEY is not set` in the app but works in the
terminal, that is the cause. Fix it by declaring the key where Claude Code itself will apply it,
in `~/.claude/settings.json`:

```json
{
  "env": {
    "LINEAR_API_KEY": "lin_api_..."
  }
}
```

That file is read by the CLI, the desktop app, and the IDE extensions alike. Treat it as a secret —
it is plaintext on disk, so keep it out of any dotfiles repo you sync.

> **Claude desktop *chat* app vs. Claude Code desktop app.** These install steps are for **Claude
> Code**. The Claude chat desktop app (claude.ai) does not load Claude Code plugins — its
> Extensions/Connectors are MCP servers, a different mechanism. To get this report without Claude
> Code, run the script directly as shown below.

## Verify

```bash
claude plugin details design-ops   # component inventory: the command + its scripts

# self-checks — from a clone of this repo:
python3 plugins/design-ops/scripts/test_ux_pr_table.py
# or against the installed copy:
python3 ~/.claude/plugins/marketplaces/bradys-marketplace/plugins/design-ops/scripts/test_ux_pr_table.py
```

13 self-checks, no network and no pytest needed. If they pass, the attribution logic is intact; if
the command still fails, the problem is credentials (`gh auth status`, `LINEAR_API_KEY`).

Installing from a local checkout instead of GitHub — useful while developing, and the only route
before changes are pushed:

```bash
claude plugin marketplace add /path/to/bradys-marketplace   # a directory works as a source
claude plugin install design-ops@bradys-marketplace
```

## Update / uninstall

```bash
claude plugin marketplace update bradys-marketplace   # pull the latest version
claude plugin disable design-ops                      # keep installed, stop loading it
claude plugin uninstall design-ops                    # remove entirely
```

## Scripts

`scripts/ux_pr_table.py` does the deterministic work behind the command, so it is also usable on its
own — no Claude Code required. Stdlib-only Python; needs an authenticated `gh`, plus either
`LINEAR_API_KEY` or an `--issues-file`.

```bash
python3 scripts/ux_pr_table.py                    # current Zip fiscal quarter
python3 scripts/ux_pr_table.py 2026-05-01..today  # explicit window
python3 scripts/ux_pr_table.py --json --no-sweep  # machine-readable, skip the gap sweep
python3 scripts/ux_pr_table.py --probe            # which Linear source is usable
python3 scripts/test_ux_pr_table.py               # self-checks (no pytest needed)

# Linear issues fetched elsewhere (what the MCP route does under the hood):
python3 scripts/ux_pr_table.py --issues-file ux_issues.json
```

`--issues-file` takes a JSON list of issues with permissively-matched field names — see `--help` for
the shape. Both routes produce a byte-identical table; only the Linear fetch differs.

The designer roster (Linear user id + GitHub handle) lives in `DESIGNERS` at the top of the script.
Z\* is matched by the exact login `z-star-agent` / `app/z-star-agent`, never a `z` prefix — several
real people have z-prefixed handles.
