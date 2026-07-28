"""A stand-in for mem0's ``Memory`` that talks to the MCP server instead.

Why this exists
---------------
The recall hooks used to instantiate ``mem0.Memory`` in-process on every
invocation. That has two costs the MCP server does not:

1. **Configuration.** An in-process client needs its own Qdrant URL, collection,
   user_id and OpenAI key — duplicated on the host even when the server already
   has all four. Worse, it needs Qdrant reachable *from the host*, so a
   docker-compose stack has to publish a port that the server itself never needs
   published.
2. **Latency.** ``Memory.from_config()`` eagerly loads the spaCy and fastembed
   models. Each hook is a fresh, short-lived process, so recall paid that
   cold-load on every single SessionStart, prompt and file read — against a
   hook timeout measured in seconds.

Going through the server removes both: it already holds the config, and it is
long-lived, so its models are warm.

Scope
-----
Covers the whole surface the hooks use: ``search`` and ``add`` (duck-typed
against ``Memory``, so callers like ``_search_scoped`` cannot tell the
difference) plus ``synthesize_handoff``, which stands in for the raw
``mem.llm.generate_response`` the capture hooks used for handoff synthesis.

That last one is why the server grew a ``synthesize_handoff`` tool rather than a
general completion endpoint: this server is commonly published through a tunnel,
where "arbitrary prompt in, text out" would be an open LLM proxy for anyone past
the access layer.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Any

logger = logging.getLogger(__name__)

#: Endpoint of the mem0 MCP server. When unset, hooks use a direct mem0 client.
MCP_URL_ENV = "MEM0_MCP_URL"

#: Hooks run under a Claude Code timeout (8-15s). Stay well inside it: a slow
#: recall must fail open and let the session start, never hold it up.
_DEFAULT_TIMEOUT = 8.0
_TIMEOUT_ENV = "MEM0_MCP_TIMEOUT"

#: Extra HTTP headers, as a JSON object, sent on every request.
#:
#: Deployment auth. This server is commonly published through a tunnel (see the
#: module docstring), and the access layer in front of it authenticates by
#: header — a Cloudflare Access service token, a reverse-proxy bearer. Without
#: this the hooks can only reach a server that needs no authentication, i.e.
#: loopback, which silently excludes every remote or ephemeral host from passive
#: recall and capture: the request 401s, ``call_tool`` returns None, and the
#: session starts looking perfectly normal with memory doing nothing.
_HEADERS_ENV = "MEM0_MCP_HEADERS"


def mcp_url() -> str:
    """Configured MCP endpoint, or "" when direct mode is wanted."""
    return os.environ.get(MCP_URL_ENV, "").strip()


def explicit_user_id() -> str | None:
    """The user_id this host actually configured, or None to defer to the server.

    An external install has no MEM0_USER_ID on purpose — the server owns the
    namespace. But ``hooks._get_user_id()`` falls back to the literal "user"
    when it is unset, and forwarding that would filter recall to a namespace
    holding nothing and, worse, write captures into it. Detecting the unset
    case here lets the tool apply its own default, which is the whole point of
    the server owning identity.
    """
    return os.environ.get("MEM0_USER_ID", "").strip() or None


def _timeout() -> float:
    raw = os.environ.get(_TIMEOUT_ENV, "").strip()
    try:
        return float(raw) if raw else _DEFAULT_TIMEOUT
    except ValueError:
        return _DEFAULT_TIMEOUT


def _headers() -> dict[str, str] | None:
    """Extra request headers from the environment, or None when unset/invalid.

    Fails OPEN like everything else on this path: a malformed value degrades to
    "no extra headers" — and therefore, behind an access layer, to no recall —
    rather than raising inside a hook and taking the session down with it. It
    warns rather than staying silent, because the two failure modes look
    identical from the outside and only the log distinguishes "no auth
    configured" from "auth configured wrong".
    """
    raw = os.environ.get(_HEADERS_ENV, "").strip()
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except ValueError:
        logger.warning("%s is not valid JSON — sending no extra headers", _HEADERS_ENV)
        return None
    if not isinstance(parsed, dict):
        logger.warning("%s must be a JSON object — sending no extra headers", _HEADERS_ENV)
        return None
    # Coerce rather than reject: a token written unquoted in a .env parses as a
    # number or bool, and dropping the whole header set over that would disable
    # auth for a value that was very nearly right.
    return {str(key): str(value) for key, value in parsed.items()}


async def _call_tool_async(url: str, name: str, arguments: dict, timeout: float) -> str:
    """One-shot MCP session: connect, initialize, call, return the text payload."""
    # Imported lazily so merely importing this module costs nothing on the
    # direct-client path.
    from datetime import timedelta

    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    async with streamablehttp_client(
        url, headers=_headers(), timeout=timedelta(seconds=timeout)
    ) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(name, arguments)

    # The fork's tools funnel through helpers._mem0_call, which json.dumps() both
    # success and failure, so the payload is always a JSON string in a text block.
    for block in result.content:
        text = getattr(block, "text", None)
        if text:
            return text
    return ""


def call_tool(name: str, arguments: dict) -> Any:
    """Call an MCP tool and return the decoded JSON payload.

    Returns ``None`` on any failure — transport, protocol, timeout, or a tool
    that reported an error. Recall is best-effort by design: a memory backend
    that is down must degrade to "no memories recalled", never break the session.
    """
    url = mcp_url()
    if not url:
        return None
    try:
        raw = asyncio.run(_call_tool_async(url, name, arguments, _timeout()))
    except Exception as exc:  # noqa: BLE001 - fail open, see docstring
        logger.warning("MCP call %s failed: %s", name, exc)
        return None
    if not raw:
        return None
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        logger.warning("MCP call %s returned non-JSON payload", name)
        return None
    if isinstance(payload, dict) and "error" in payload:
        logger.warning("MCP call %s errored: %s", name, payload.get("error"))
        return None
    return payload


class McpMemory:
    """Duck-type of the slice of ``mem0.Memory`` the recall hooks touch."""

    def search(
        self,
        query: str,
        filters: dict | None = None,
        top_k: int | None = None,
        threshold: float | None = None,
        **_ignored: Any,
    ) -> Any:
        """Mirror ``Memory.search``, mapping its arguments onto search_memories.

        mem0 2.x carries entity scopes inside ``filters``; the MCP tool takes
        them as named parameters and rebuilds the same filter dict server-side,
        so user_id/app_id are lifted out and the remainder passed through.
        """
        filters = dict(filters or {})
        args: dict[str, Any] = {"query": query}
        filters.pop("user_id", None)  # resolved below, not passed through
        for key in ("agent_id", "run_id", "app_id"):
            value = filters.pop(key, None)
            if value:
                args[key] = value
        uid = explicit_user_id()
        if uid:
            args["user_id"] = uid
        if filters:
            args["filters"] = filters
        if top_k is not None:
            args["limit"] = top_k
        if threshold is not None:
            args["threshold"] = threshold
        # The tool reranks by default whenever the server has a reranker loaded.
        # Recall hooks never want it: it adds latency for an ordering they don't
        # use, and the direct-client path force-disables it too. Keep parity.
        args["rerank"] = False

        payload = call_tool("search_memories", args)
        # _extract_results() accepts {"results": [...]} or a bare list; None
        # falls through it to an empty list, which is the fail-open we want.
        return payload

    def add(
        self,
        messages: list | None = None,
        user_id: str | None = None,
        infer: bool | None = None,
        metadata: dict | None = None,
        agent_id: str | None = None,
        run_id: str | None = None,
        **_ignored: Any,
    ) -> Any:
        """Mirror ``Memory.add``, mapping its arguments onto add_memory.

        The hooks always pass a single user-role message, so it is flattened to
        the tool's ``text`` field.

        The entity scopes travel inside ``metadata`` (how the hooks pass them)
        or as named arguments (how ``Memory.add`` takes them), and the tool
        takes each as a named parameter, so all three are lifted out — leaving
        the rest of the metadata to travel as-is. ``search`` below has always
        lifted all three; ``add`` lifted only ``app_id``, which meant agent_id
        and run_id could be *filtered* on but never *written*, so under an
        external stack they silently vanished into ``**_ignored``.
        """
        text = ""
        for message in messages or []:
            content = (message or {}).get("content")
            if content:
                text = content
                break
        if not text:
            return None

        metadata = dict(metadata or {})
        args: dict[str, Any] = {"text": text}
        # An explicit keyword wins over the same key in metadata: it is the more
        # specific way to say it, and mirrors Memory.add's own signature.
        explicit = {"agent_id": agent_id, "run_id": run_id}
        for key in ("app_id", "agent_id", "run_id"):
            value = explicit.get(key) or metadata.pop(key, None)
            metadata.pop(key, None)
            if value:
                args[key] = value
        if metadata:
            args["metadata"] = metadata
        uid = explicit_user_id()
        if uid:
            args["user_id"] = uid
        if infer is not None:
            args["infer"] = infer
        return call_tool("add_memory", args)

    def synthesize_handoff(
        self,
        conversation: str,
        project_name: str,
        previous_handoff: str = "",
        recalled: str = "",
        workstream_overview: str = "",
        workstream_slug: str = "",
    ) -> str:
        """Ask the server to write the handoff recap.

        Returns "" on any failure, matching the direct path's contract so the
        caller simply skips writing the handoff file.
        """
        payload = call_tool(
            "synthesize_handoff",
            {
                "conversation": conversation,
                "project_name": project_name,
                "previous_handoff": previous_handoff or None,
                "recalled": recalled or None,
                "workstream_overview": workstream_overview or None,
                "workstream_slug": workstream_slug or None,
            },
        )
        return payload.strip() if isinstance(payload, str) else ""


def get_client() -> McpMemory | None:
    """An MCP-backed client, or None when direct mode is configured."""
    return McpMemory() if mcp_url() else None
