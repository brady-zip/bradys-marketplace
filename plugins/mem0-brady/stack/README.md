# stack — the Docker stack

Qdrant + the mem0 MCP server, in Docker, for the `compose` stack mode. Lives here
rather than in a loose directory so the server image builds from the **vendored
fork at `../server`** — the same source the plugin installs the recall/capture
hooks from.

That is the entire reason this moved. Previously the image installed from
`git+https://github.com/brady-zip/mem0-mcp-selfhosted.git` (unpinned `main`)
while the hooks installed from `../server`. Both happened to be v0.11.0, but
nothing enforced it: a change to `hooks.py` would reach the hooks on the next
`/mem0-brady:setup` and the server only on the next image rebuild. Now there is
one source of truth, by construction.

## Run it

```bash
MEM0_BRADY_STACK=compose /mem0-brady:setup
```

That is the whole procedure. Setup renders `~/.config/mem0-brady/.env`, installs
the vendored server as a host tool for the hooks, then builds and starts this
stack from that same config.

### There is deliberately no `.env` beside this file

Config lives **only** in `~/.config/mem0-brady/.env` — the same file the hooks
`source`. Compose reads it twice: `--env-file` for its own interpolation (the
storage path, the host ports, the project name) and `env_file:` to inject the
server's half into the container.

That is not tidiness. A second copy in the source tree is how a live
`OPENAI_API_KEY` ends up committed-adjacent in a checkout, and how an edit lands
on the copy nothing reads — a failure that looks exactly like the edit not
working. One file cannot drift from itself.

**Quoting is load-bearing**, because two parsers read that one file and they
disagree about bare values. Compose accepts `K=two words`; `source` runs `words`
as a command and leaves `K` empty. Quote anything containing a space, `;`, `*`,
`{` or `#`. Quoted values come back byte-identical from both.

To drive it by hand instead of through setup:

```bash
docker compose --env-file ~/.config/mem0-brady/.env up -d --build
docker compose logs -f mem0-mcp          # confirm it binds :8081
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/mcp   # 406 = alive
```

`406` is success here: streamable-HTTP rejects a plain GET (it wants
`Accept: text/event-stream`), so any HTTP response proves the server is up.

### Restart after editing the config

A container keeps serving whatever it was started with. Editing the config
without `up -d` leaves a stale container that looks perfectly healthy while
using the old values — `/mem0-brady:doctor` compares the two and flags it.

## compose vs external

`compose` means *this plugin runs the server*. `external` means *somebody else
does* — a tunnelled server, or a cloud container booting from a shared config —
and the plugin then owns no containers, no storage, and no key. Both drive mem0
over MCP; only `compose` builds and starts anything.

## Qdrant does not need publishing

The plugin's hooks reach mem0 **through this server**, not around it, so the
host never contacts Qdrant. `MEM0_BRADY_QDRANT_HOST_PORT` publishes it on
loopback anyway because it is genuinely useful — `/mem0-brady:migrate` and any
direct inspection (`curl .../collections`) use it — but nothing in normal
operation depends on it. Drop the `ports:` entry from the `qdrant` service if
you would rather it stayed sealed inside the compose network.

Store identity lives here and **only** here: an external plugin install holds no
collection, no `user_id` and no API key, so there is no second copy to drift out
of sync.

## Storage

`MEM0_BRADY_QDRANT_STORAGE` is an absolute host path, on purpose: vendoring this
stack into the plugin repo must not move anybody's existing memories. Point it at
wherever your data already is. The compose project name likewise defaults to
`mem0-host` for continuity — renaming it creates a *second* set of containers
against the same data rather than adopting the existing ones.

## Tunnel + Access

`cloudflared/config.example.yml` exposes the server to Claude cloud
containers/routines. Gate it with a Cloudflare Access application — the endpoint
holds your OpenAI key and controls shared memory. Two ways in, and they coexist:

- **Service token** (`CF-Access-Client-Id` / `-Secret` headers) for local CLIs.
- **Managed OAuth** for claude.ai connectors, which cannot send those headers.
  Enabling it does not disturb the service-token path. Note that an app whose
  only policy is `decision: non_identity` (service auth) lets no human
  authenticate at all — the OAuth flow reaches the login page and is refused.

## Gotchas

- **DNS-rebinding protection.** The MCP SDK checks the `Host` header; the tunnel
  pins `httpHostHeader: localhost:8081` to satisfy it. Host-validation-looking
  400/403s are this knob.
- **Laptop availability.** Routines run unattended — if this machine is asleep or
  offline the endpoint is dead. `caffeinate`, or move to a small VPS, if
  unattended routines are a hard requirement.
- **Reranker.** Not installed in this image (`sentence-transformers` and its
  torch dependency are omitted). Embeddings and reranking are decoupled, so one
  can be added later as a post-retrieval step with no re-embedding.
