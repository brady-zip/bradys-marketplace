# bradys-marketplace

B's personal [Claude Code](https://docs.claude.com/en/docs/claude-code) plugin marketplace.

## Install

Add the marketplace once per machine, then install whichever plugins you want — either from inside a Claude Code session or from the terminal:

<details>
<summary><strong>In Claude Code</strong> (slash commands)</summary>

```
/plugin marketplace add brady-zip/bradys-marketplace
/plugin install <plugin>@bradys-marketplace
```

</details>

<details>
<summary><strong>From the terminal</strong> (CLI)</summary>

```sh
claude plugin marketplace add brady-zip/bradys-marketplace
claude plugin install <plugin>@bradys-marketplace
```

</details>

## Plugins

| Plugin | What it does |
|--------|--------------|
| [`mem0-brady`](plugins/mem0-brady/) | Self-hosted [Mem0](https://github.com/mem0ai/mem0) memory backbone — explicit hard facts (`mcp__mem0__*` tools) **and** passive auto-capture/recall via hooks, partitioned by `app_id`. Bundles the `grill-me` skill. Native local Qdrant (no Docker) behind a launchd MCP server. See its [README](plugins/mem0-brady/README.md) and run `/mem0-brady:setup` once after install. |
| [`slack-bridge`](plugins/slack-bridge/) | Bridge to Slack's web API via browser session tokens (`xoxc`/`xoxd`) — surfaces what the hosted Slack MCP can't: true unread (Activity feed) with real bulk mark-read, and the saved-for-later "Later" list. Custom Python MCP server (13 tools) + skills: `/slack-triage`, `/slack-saved`, `/slack-unwrapped`, `/slack-setup`, `/slack-doctor`. See its [README](plugins/slack-bridge/README.md) and run `/slack-setup` once after install. Adapted from [@chuqian's slack-cleanup](https://github.com/Greenbax/evergreen/pull/112154). |
| [`dark-factory`](plugins/dark-factory/) | Dual-runtime **agent radio** — live peer messaging between an interactive **Claude Code** session and an interactive **Codex** session over the git ref `refs/h5i/msg` (via the [`h5i`](https://h5i.dev/) CLI), with per-session **identity locking** (auto-cleanup on `SessionEnd`). Claude `/radio` command (Monitor listen loop) + Codex `/radio` prompt (blocking wait), a one-off `radio-ask` skill for both, and a `radio-setup` skill that deploys committed copies + GSD into a target repo (Codex can't consume a Claude plugin). See its [README](plugins/dark-factory/README.md); ask Claude to "set up dark factory in this repo" per repo. |
| [`datadog-dashboards`](plugins/datadog-dashboards/) | Collaborative Datadog dashboard creation as three handoff skills — `create-dashboard` (intent discovery → `.dash.json` skeleton), `expand-dashboard` (instrument metrics *before* adding widgets), and `iterate-dashboard` (screenshot → Gemini rating loop until 7+/10). Dashboards sync to Datadog via the `chart-room` CLI; a bundled `datadog-dashboard-viewer` MCP server drives Chrome Beta for the screenshot loop. See its [README](plugins/datadog-dashboards/README.md) and ask Claude to run its `scripts/check-setup.sh` after install. |

## Layout

```
bradys-marketplace/
├── .claude-plugin/
│   └── marketplace.json     # marketplace manifest (lists every plugin + its source path)
└── plugins/
    └── mem0-brady/          # one self-contained plugin per directory
        ├── .claude-plugin/plugin.json
        ├── commands/  hooks/  scripts/  skills/
        └── README.md
```

Each plugin lives in its own directory under `plugins/`. To add a new one, create
`plugins/<name>/` with its own `.claude-plugin/plugin.json`, then add an entry to
`.claude-plugin/marketplace.json` with `"source": "./plugins/<name>"`.
