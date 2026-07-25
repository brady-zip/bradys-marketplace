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
This deliberately implements only ``search`` — the surface the *recall* hooks
use. The capture hooks (Stop / PreCompact) additionally need ``add`` and the raw
``mem.llm`` for handoff synthesis, and no MCP tool exposes an LLM completion.
Moving those needs a new server-side tool; until then they keep a direct client.
``search`` here is intentionally a duck-type of ``Memory.search`` so callers
(``_search_scoped``) cannot tell the difference.
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


def mcp_url() -> str:
    """Configured MCP endpoint, or "" when direct mode is wanted."""
    return os.environ.get(MCP_URL_ENV, "").strip()


def _timeout() -> float:
    raw = os.environ.get(_TIMEOUT_ENV, "").strip()
    try:
        return float(raw) if raw else _DEFAULT_TIMEOUT
    except ValueError:
        return _DEFAULT_TIMEOUT


async def _call_tool_async(url: str, name: str, arguments: dict, timeout: float) -> str:
    """One-shot MCP session: connect, initialize, call, return the text payload."""
    # Imported lazily so merely importing this module costs nothing on the
    # direct-client path.
    from datetime import timedelta

    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    async with streamablehttp_client(
        url, timeout=timedelta(seconds=timeout)
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
        for key in ("user_id", "agent_id", "run_id", "app_id"):
            value = filters.pop(key, None)
            if value:
                args[key] = value
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


def get_search_client() -> McpMemory | None:
    """An MCP-backed search client, or None when direct mode is configured."""
    return McpMemory() if mcp_url() else None
