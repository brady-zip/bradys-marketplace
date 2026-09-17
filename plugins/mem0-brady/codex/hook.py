"""Adapt Codex hook payloads to the shared Mem0 hook scripts."""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TextIO

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
HANDLERS = {
    "steer": ("codex/steer.sh", 9),
    "context": ("hooks/run-context.sh", 19),
    "prompt": ("hooks/run-prompt.sh", 14),
    "stop": ("hooks/run-stop.sh", 59),
    "precompact": ("hooks/run-precompact.sh", 59),
    "metadata": ("hooks/enforce-metadata.sh", 9),
    "audit": ("hooks/on-post-tool-use.sh", 9),
}


def convert_transcript(source: TextIO, destination: TextIO) -> None:
    for line in source:
        try:
            entry: object = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict) or entry.get("isSidechain"):
            continue
        if entry.get("type") == "response_item":
            message = entry.get("payload")
            if not isinstance(message, dict) or message.get("type") != "message":
                continue
        else:
            message = entry.get("message", entry)
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        if role not in ("user", "assistant"):
            continue
        if message.get("channel") not in (None, "final", "commentary"):
            continue
        content = message.get("content")
        if isinstance(content, list):
            content = " ".join(
                block["text"]
                for block in content
                if isinstance(block, dict)
                and block.get("type") in ("text", "input_text", "output_text")
                and isinstance(block.get("text"), str)
            )
        if isinstance(content, str) and content.strip():
            destination.write(json.dumps({"role": role, "content": content}) + "\n")


def normalize_output(output: str, event: str) -> str:
    if not output.strip():
        return ""
    response: object = json.loads(output)
    if not isinstance(response, dict):
        raise TypeError("Expected a hook response object")
    context = response.pop("additionalContext", None)
    if isinstance(context, str) and context:
        specific = response.get("hookSpecificOutput", {})
        if not isinstance(specific, dict):
            raise TypeError("Expected hookSpecificOutput to be an object")
        response["hookSpecificOutput"] = {
            **specific,
            "hookEventName": event,
            "additionalContext": context,
        }
    if event == "PreToolUse":
        for field in ("continue", "stopReason", "suppressOutput"):
            response.pop(field, None)
    return json.dumps(response)


def run_hook(handler: str, payload: dict[str, object]) -> str:
    event = payload.get("hook_event_name")
    if not isinstance(event, str):
        raise TypeError("Missing hook_event_name")
    script, timeout = HANDLERS[handler]
    environment = dict(os.environ)
    if not environment.get("MEM0_SCOPE_AGENT_ID", "").strip():
        environment["MEM0_SCOPE_AGENT_ID"] = "codex"
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not Path(cwd).is_dir():
        cwd = os.getcwd()
    environment["CLAUDE_PROJECT_DIR"] = cwd

    with tempfile.TemporaryDirectory(prefix="mem0-codex-") as temp_dir:
        transcript = payload.get("transcript_path")
        if (
            handler in ("stop", "precompact")
            and isinstance(transcript, str)
            and Path(transcript).is_file()
        ):
            converted = Path(temp_dir) / "transcript.jsonl"
            with (
                open(transcript, encoding="utf-8") as source,
                converted.open("w", encoding="utf-8") as destination,
            ):
                convert_transcript(source, destination)
            payload = {**payload, "transcript_path": str(converted)}
        result = subprocess.run(
            ["bash", str(PLUGIN_ROOT / script)],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            cwd=cwd,
            env=environment,
            timeout=timeout,
            check=True,
        )
    return normalize_output(result.stdout, event)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("handler", choices=HANDLERS)
    args = parser.parse_args()
    try:
        payload: object = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise TypeError("Expected a hook input object")
        output = run_hook(args.handler, payload)
        if output:
            print(output)
    except (OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        print(
            f"mem0-brady: {args.handler} hook skipped ({type(exc).__name__})",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
