#!/usr/bin/env python3
"""Adapt Cursor hook payloads to the shared Mem0 hook scripts.

Cursor's plugin hooks use different event names and a different JSON shape
than Claude Code. The scripts under hooks/ stay the one implementation of
scope resolution, recall, capture, and the metadata guard. This adapter
reshapes Cursor's payload, runs those scripts, and translates their Claude
responses back into the fields Cursor actually reads.

It fails open. A missing script, bad payload, or timed-out search prints a
response that lets the session continue, and never echoes the payload.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TextIO

PLUGIN_ROOT = Path(__file__).resolve().parent.parent

# (script relative to the plugin root, subprocess timeout in seconds).
# The hooks.json timeout for the same handler must be larger than the sum.
SCRIPTS: dict[str, tuple[tuple[str, int], ...]] = {
    "session": (("hooks/steer.sh", 9), ("hooks/run-context.sh", 19)),
    "prompt": (("hooks/run-prompt.sh", 14),),
    "stop": (("hooks/run-stop.sh", 59),),
    "precompact": (("hooks/run-precompact.sh", 59),),
    "metadata": (("hooks/enforce-metadata.sh", 9),),
    "blockwrite": (("hooks/block-memory-write.sh", 9),),
    "filecontext": (("hooks/run-filecontext.sh", 12),),
    "audit": (("hooks/on-post-tool-use.sh", 9),),
}

# Leaves the mem0 MCP server exposes. Cursor names them MCP:<leaf> or the
# bare leaf, while the shared guards match Claude's mcp__mem0__* form.
MEM0_TOOL_LEAVES = {
    "add",
    "add_memory",
    "add_memories",
    "search_memories",
    "get_memories",
    "get_memory",
    "update_memory",
    "delete_memory",
    "delete_all_memories",
    "list_entities",
    "delete_entities",
    "synthesize_handoff",
    "mcp_search_graph",
    "mcp_get_entity",
}

WRITE_TOOL_NAMES = {
    "Write": "Write",
    "Edit": "Edit",
    "MultiEdit": "MultiEdit",
    "NotebookEdit": "NotebookEdit",
    "StrReplace": "Edit",
}

CLAUDE_EVENTS = {
    "sessionStart": "SessionStart",
    "beforeSubmitPrompt": "UserPromptSubmit",
    "stop": "Stop",
    "preCompact": "PreCompact",
    "preToolUse": "PreToolUse",
    "postToolUse": "PostToolUse",
    "afterMCPExecution": "PostToolUse",
}

TEXT_BLOCK_TYPES = {"text", "input_text", "output_text"}


def budget(handler: str) -> int:
    return sum(timeout for _, timeout in SCRIPTS[handler])


def timeout_floor(handler: str) -> int:
    """The hooks.json timeout has to outlast every script this handler can run.

    Cursor Cloud does not fire sessionStart. The first beforeSubmitPrompt runs
    the session scripts when that event did not, so the prompt timeout has to
    cover both.
    """
    total = budget(handler)
    if handler == "prompt":
        total += budget("session")
    return total


def sessions_dir() -> Path:
    override = os.environ.get("MEM0_BRADY_SESSIONS_DIR", "").strip()
    if override:
        return Path(override)
    xdg = os.environ.get("XDG_DATA_HOME", "").strip()
    root = Path(xdg) if xdg else Path.home() / ".local" / "share"
    return root / "mem0-brady" / "sessions"


def cwd_session_marker_matches(session_id: str, cwd: str) -> bool:
    """True when steer.sh already recorded this session for this checkout.

    The path matches hooks/lib-recall-log.sh: sessions/<sha1(cwd)[:8]>.json.
    The IDE's sessionStart writes it, so a later prompt does not recall twice.
    Cloud never writes it until this prompt does.
    """
    if not session_id or not cwd:
        return False
    digest = hashlib.sha1(cwd.encode()).hexdigest()[:8]
    path = sessions_dir() / f"{digest}.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return isinstance(data, dict) and data.get("session_id") == session_id


def resolve_cwd(payload: dict[str, object]) -> str:
    cwd = payload.get("cwd")
    if isinstance(cwd, str) and Path(cwd).is_dir():
        return cwd
    roots = payload.get("workspace_roots")
    candidates = [
        root
        for root in roots
        if isinstance(root, str) and Path(root).is_dir()
    ] if isinstance(roots, list) else []
    for key in ("CURSOR_PROJECT_DIR", "CLAUDE_PROJECT_DIR"):
        env_root = os.environ.get(key, "")
        if env_root and Path(env_root).is_dir() and (not candidates or env_root in candidates):
            return env_root
    for root in candidates:
        if (Path(root) / ".mem0-brady.json").is_file():
            return root
    if candidates:
        return candidates[0]
    return os.getcwd()


def claude_payload(payload: dict[str, object]) -> dict[str, object]:
    """Copy Cursor's input into the field names the shared scripts read."""
    forwarded = dict(payload)
    if not isinstance(forwarded.get("session_id"), str) or not forwarded.get("session_id"):
        for key in ("conversation_id", "generation_id"):
            value = forwarded.get(key)
            if isinstance(value, str) and value:
                forwarded["session_id"] = value
                break
    forwarded["cwd"] = resolve_cwd(forwarded)
    event = forwarded.get("hook_event_name")
    if isinstance(event, str) and event in CLAUDE_EVENTS:
        forwarded["hook_event_name"] = CLAUDE_EVENTS[event]
    tool_input = forwarded.get("tool_input")
    if isinstance(tool_input, str):
        try:
            parsed: object = json.loads(tool_input)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            tool_input = parsed
            forwarded["tool_input"] = parsed
    if not isinstance(tool_input, dict):
        tool_input = {}
    if "file_path" not in tool_input and "path" not in tool_input:
        for key in ("file_path", "path", "target_file", "filePath"):
            value = forwarded.get(key)
            if isinstance(value, str) and value:
                tool_input = {**tool_input, "file_path": value}
                forwarded["tool_input"] = tool_input
                break
    return forwarded


def mem0_tool_name(payload: dict[str, object]) -> str | None:
    raw = payload.get("tool_name")
    if not isinstance(raw, str) or not raw:
        return None
    if raw.startswith("mcp__mem0__") or raw.startswith("mcp__claude_ai_mem0__"):
        return raw
    server = payload.get("mcp_server_name")
    server_name = server if isinstance(server, str) else ""
    if server_name and "mem0" not in server_name.lower():
        return None
    leaf = raw.split(":", 1)[1] if raw.startswith("MCP:") else raw
    if leaf not in MEM0_TOOL_LEAVES and "mem0" not in server_name.lower():
        return None
    if leaf not in MEM0_TOOL_LEAVES:
        return None
    prefix = "mcp__claude_ai_mem0__" if "claude_ai_mem0" in server_name else "mcp__mem0__"
    return prefix + leaf


def convert_transcript(source: TextIO, destination: TextIO) -> None:
    """Flatten Cursor's JSONL into the {role, content} records capture reads.

    Cursor stores the role on the envelope and the text under message.content.
    The shared reader takes role from message when that object exists, so a
    Cursor transcript handed over raw contributes zero turns.
    """
    for line in source:
        try:
            entry: object = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict) or entry.get("isSidechain"):
            continue
        message = entry.get("message")
        if isinstance(message, dict):
            role = message.get("role") or entry.get("role")
            content = message.get("content")
        else:
            role = entry.get("role")
            content = entry.get("content")
        if role not in ("user", "assistant"):
            continue
        if isinstance(content, list):
            content = " ".join(
                block["text"]
                for block in content
                if isinstance(block, dict)
                and block.get("type") in TEXT_BLOCK_TYPES
                and isinstance(block.get("text"), str)
            )
        if isinstance(content, str) and content.strip():
            destination.write(json.dumps({"role": role, "content": content}) + "\n")


def extract_context(output: str) -> str:
    if not output.strip():
        return ""
    response: object = json.loads(output)
    if not isinstance(response, dict):
        raise TypeError("Expected a hook response object")
    chunks: list[str] = []
    for source in (response, response.get("hookSpecificOutput")):
        if not isinstance(source, dict):
            continue
        for key in ("additionalContext", "additional_context"):
            value = source.get(key)
            if isinstance(value, str) and value.strip() and value.strip() not in chunks:
                chunks.append(value.strip())
    return "\n\n".join(chunks)


def permission_response(output: str) -> dict[str, object]:
    """preToolUse must always return a schema-valid permission decision.

    Empty stdout is a schema failure, and Cursor blocks the tool.
    """
    if not output.strip():
        return {"permission": "allow"}
    response: object = json.loads(output)
    if not isinstance(response, dict):
        raise TypeError("Expected a hook response object")
    specific = response.get("hookSpecificOutput")
    source = specific if isinstance(specific, dict) else response
    decision = source.get("permissionDecision") or source.get("permission") or "allow"
    if decision not in ("allow", "deny", "ask"):
        decision = "allow"
    result: dict[str, object] = {"permission": decision}
    reason = source.get("permissionDecisionReason") or source.get("user_message")
    if isinstance(reason, str) and reason:
        result["user_message"] = reason
        result["agent_message"] = reason
    updated = source.get("updatedInput") or source.get("updated_input")
    if isinstance(updated, dict):
        result["updated_input"] = updated
    return result


def followup_response(output: str) -> dict[str, object]:
    if not output.strip():
        return {}
    response: object = json.loads(output)
    if not isinstance(response, dict):
        raise TypeError("Expected a hook response object")
    specific = response.get("hookSpecificOutput")
    source = specific if isinstance(specific, dict) else response
    if source.get("decision") == "block" and isinstance(source.get("reason"), str):
        return {"followup_message": source["reason"]}
    return {}


def run_script(
    script: str,
    timeout: int,
    payload: dict[str, object],
    environment: dict[str, str],
) -> str:
    result = subprocess.run(
        ["bash", str(PLUGIN_ROOT / script)],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        cwd=str(payload.get("cwd") or os.getcwd()),
        env=environment,
        timeout=timeout,
        check=True,
    )
    return result.stdout


def hook_environment(cwd: str) -> dict[str, str]:
    environment = dict(os.environ)
    environment["MEM0_CURSOR_ADAPTER"] = "1"
    environment["CLAUDE_PROJECT_DIR"] = cwd
    if not environment.get("MEM0_SCOPE_AGENT_ID", "").strip():
        environment["MEM0_SCOPE_AGENT_ID"] = "cursor"
    return environment


def prepare_payload(handler: str, payload: dict[str, object]) -> dict[str, object]:
    forwarded = claude_payload(payload)
    if handler in ("metadata", "audit"):
        tool_name = mem0_tool_name(payload)
        if tool_name is None:
            return {}
        forwarded["tool_name"] = tool_name
    elif handler == "blockwrite":
        raw = payload.get("tool_name")
        if not isinstance(raw, str) or raw not in WRITE_TOOL_NAMES:
            return {}
        forwarded["tool_name"] = WRITE_TOOL_NAMES[raw]
    return forwarded


def run_hook(handler: str, payload: dict[str, object]) -> str:
    forwarded = prepare_payload(handler, payload)
    if handler in ("metadata", "audit", "blockwrite") and not forwarded:
        if handler == "audit":
            return ""
        return json.dumps({"permission": "allow"})
    cwd = str(forwarded.get("cwd") or os.getcwd())
    environment = hook_environment(cwd)
    script_plan = list(SCRIPTS[handler])
    if handler == "prompt":
        session_id = forwarded.get("session_id")
        if isinstance(session_id, str) and session_id and not cwd_session_marker_matches(
            session_id, cwd
        ):
            script_plan = [*SCRIPTS["session"], *script_plan]

    with tempfile.TemporaryDirectory(prefix="mem0-cursor-") as temp_dir:
        if handler in ("stop", "precompact"):
            transcript = forwarded.get("transcript_path")
            if isinstance(transcript, str) and Path(transcript).is_file():
                converted = Path(temp_dir) / "transcript.jsonl"
                with (
                    open(transcript, encoding="utf-8") as source,
                    converted.open("w", encoding="utf-8") as destination,
                ):
                    convert_transcript(source, destination)
                forwarded = {**forwarded, "transcript_path": str(converted)}
        outputs: list[str] = []
        for script, timeout in script_plan:
            outputs.append(run_script(script, timeout, forwarded, environment))

    if handler == "session":
        chunks = [extract_context(output) for output in outputs]
        text = "\n\n".join(chunk for chunk in chunks if chunk)
        return json.dumps({"additional_context": text}) if text else ""
    if handler == "prompt":
        result: dict[str, object] = {"continue": True}
        chunks = [extract_context(output) for output in outputs]
        text = "\n\n".join(chunk for chunk in chunks if chunk)
        if text:
            result["additional_context"] = text
        return json.dumps(result)
    if handler == "filecontext":
        text = extract_context(outputs[0])
        return json.dumps({"additional_context": text}) if text else ""
    if handler in ("metadata", "blockwrite"):
        return json.dumps(permission_response(outputs[0]))
    if handler == "stop":
        followup = followup_response(outputs[0])
        return json.dumps(followup) if followup else ""
    return ""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("handler", choices=SCRIPTS)
    args = parser.parse_args()
    try:
        payload: object = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise TypeError("Expected a hook input object")
        output = run_hook(args.handler, payload)
        if output:
            print(output)
    except (OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        fallback = ""
        if args.handler == "prompt":
            fallback = '{"continue":true}'
        elif args.handler in ("metadata", "blockwrite"):
            fallback = '{"permission":"allow"}'
        if fallback:
            print(fallback)
        print(
            f"mem0-brady: {args.handler} hook skipped ({type(exc).__name__})",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
