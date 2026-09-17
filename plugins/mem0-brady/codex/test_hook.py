import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import hook


class CodexHookTest(unittest.TestCase):
    def test_converts_messages_without_duplicate_events_or_tool_output(self) -> None:
        entries = [
            {
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": "Use the shared server"}
                    ],
                },
            },
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "Use the shared server",
                },
            },
            {
                "type": "response_item",
                "payload": {
                    "type": "function_call_output",
                    "output": "private tool output",
                },
            },
            {
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "channel": "analysis",
                    "content": [{"type": "output_text", "text": "internal reasoning"}],
                },
            },
            {
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "channel": "final",
                    "content": [{"type": "output_text", "text": "Connected"}],
                },
            },
        ]
        source = io.StringIO("\n".join(map(json.dumps, entries)) + "\n{broken\nnull\n")
        destination = io.StringIO()
        hook.convert_transcript(source, destination)
        self.assertEqual(
            [json.loads(line) for line in destination.getvalue().splitlines()],
            [
                {"role": "user", "content": "Use the shared server"},
                {"role": "assistant", "content": "Connected"},
            ],
        )

    def test_preserves_chat_transcripts_and_ignores_sidechains(self) -> None:
        entries = [
            {"message": {"role": "user", "content": "Question"}},
            {"role": "assistant", "content": [{"type": "text", "text": "Answer"}]},
            {"isSidechain": True, "role": "assistant", "content": "Skip"},
            {"role": "system", "content": "Skip"},
            {"role": "assistant", "content": [{"type": "tool_use", "text": "Skip"}]},
            {"message": None},
        ]
        destination = io.StringIO()
        hook.convert_transcript(
            io.StringIO("\n".join(map(json.dumps, entries))), destination
        )
        self.assertEqual(len(destination.getvalue().splitlines()), 2)

    def test_wraps_legacy_session_context(self) -> None:
        response = json.loads(
            hook.normalize_output(
                '{"continue":true,"additionalContext":"Remember this"}', "SessionStart"
            )
        )
        self.assertNotIn("additionalContext", response)
        self.assertEqual(
            response["hookSpecificOutput"],
            {
                "hookEventName": "SessionStart",
                "additionalContext": "Remember this",
            },
        )

    def test_preserves_guard_and_removes_unsupported_fields(self) -> None:
        specific = {"hookEventName": "PreToolUse", "permissionDecision": "deny"}
        response = json.loads(
            hook.normalize_output(
                json.dumps(
                    {
                        "continue": True,
                        "suppressOutput": True,
                        "stopReason": "",
                        "hookSpecificOutput": specific,
                    }
                ),
                "PreToolUse",
            )
        )
        self.assertEqual(response, {"hookSpecificOutput": specific})
        self.assertEqual(hook.normalize_output("", "PostToolUse"), "")

    def test_invalid_hook_output_is_rejected(self) -> None:
        for value in ("broken", "null", "[]"):
            with self.subTest(value=value), self.assertRaises((ValueError, TypeError)):
                hook.normalize_output(value, "SessionStart")

    def test_capture_converts_transcript_and_cleans_it_up(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "rollout.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "type": "response_item",
                        "payload": {
                            "type": "message",
                            "role": "user",
                            "content": [
                                {"type": "input_text", "text": "Persist this decision"}
                            ],
                        },
                    }
                )
                + "\n"
            )
            payload = {
                "cwd": directory,
                "session_id": "test",
                "hook_event_name": "Stop",
                "transcript_path": str(transcript),
            }
            paths = []

            def capture(
                command: list[str], **kwargs: object
            ) -> subprocess.CompletedProcess[str]:
                forwarded = json.loads(str(kwargs["input"]))
                path = Path(forwarded["transcript_path"])
                paths.append(path)
                self.assertNotEqual(path, transcript)
                self.assertEqual(
                    json.loads(path.read_text()),
                    {
                        "role": "user",
                        "content": "Persist this decision",
                    },
                )
                self.assertEqual(forwarded["session_id"], "test")
                return subprocess.CompletedProcess(
                    command, 0, stdout='{"continue":true}'
                )

            with patch("hook.subprocess.run", side_effect=capture):
                hook.run_hook("stop", payload)
            self.assertTrue(transcript.exists())
            self.assertFalse(paths[0].exists())

    def test_codex_identity_preserves_explicit_override(self) -> None:
        for explicit, expected in (
            (None, "codex"),
            ("", "codex"),
            ("custom-agent", "custom-agent"),
        ):
            with (
                self.subTest(explicit=explicit),
                patch.dict(os.environ, {}, clear=True),
            ):
                if explicit:
                    os.environ["MEM0_SCOPE_AGENT_ID"] = explicit
                with patch(
                    "hook.subprocess.run",
                    return_value=subprocess.CompletedProcess([], 0, stdout=""),
                ) as run:
                    hook.run_hook(
                        "metadata",
                        {"cwd": os.getcwd(), "hook_event_name": "PreToolUse"},
                    )
                self.assertEqual(
                    run.call_args.kwargs["env"]["MEM0_SCOPE_AGENT_ID"], expected
                )
                self.assertEqual(
                    run.call_args.kwargs["env"]["CLAUDE_PROJECT_DIR"], os.getcwd()
                )

    def test_invalid_input_fails_open_without_echoing_it(self) -> None:
        with (
            patch("sys.argv", ["hook.py", "context"]),
            patch("sys.stdin", io.StringIO("secret")),
            patch("sys.stdout", new_callable=io.StringIO) as out,
            patch("sys.stderr", new_callable=io.StringIO) as err,
        ):
            hook.main()
        self.assertEqual(out.getvalue(), "")
        self.assertIn("hook skipped", err.getvalue())
        self.assertNotIn("secret", err.getvalue())

    def test_manifest_selects_only_codex_hooks(self) -> None:
        manifest = json.loads(
            (hook.PLUGIN_ROOT / ".codex-plugin/plugin.json").read_text()
        )
        path = hook.PLUGIN_ROOT / manifest["hooks"]
        configuration = json.loads(path.read_text())
        registered = set()
        for groups in configuration["hooks"].values():
            for group in groups:
                for handler in group["hooks"]:
                    name = handler["command"].rsplit(" ", 1)[1]
                    registered.add(name)
                    self.assertGreater(handler["timeout"], hook.HANDLERS[name][1])
                    self.assertLessEqual(handler["timeout"], 60)
        self.assertEqual(registered, set(hook.HANDLERS))


if __name__ == "__main__":
    unittest.main()
