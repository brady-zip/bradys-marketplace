# bradys-marketplace

B's personal [Claude Code](https://docs.claude.com/en/docs/claude-code) plugin marketplace.

## Install

Add the marketplace once per machine, then install whichever plugins you want:

```
/plugin marketplace add brady-zip/bradys-marketplace
/plugin install <plugin>@bradys-marketplace
```

## Plugins

| Plugin | What it does |
|--------|--------------|
| [`mem0-brady`](plugins/mem0-brady/) | Self-hosted [Mem0](https://github.com/mem0ai/mem0) memory backbone — explicit hard facts (`mcp__mem0__*` tools) **and** passive auto-capture/recall via hooks, partitioned by `app_id`. Bundles the `grill-me` skill. Native local Qdrant (no Docker) behind a launchd MCP server. See its [README](plugins/mem0-brady/README.md) and run `/mem0-brady:setup` once after install. |

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
