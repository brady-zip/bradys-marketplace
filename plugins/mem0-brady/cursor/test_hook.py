import hashlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import hook


class CursorHookTest(unittest.TestCase):
    def test_converts_cursor_transcript_and_drops_tool_blocks(self) -> None:
        entries = [
            {
                "role": "user",
                "message": {
                    "content": [{"type": "text", "text": "Remember the port"}],
                },
            },
            {
                "role": "assistant",
                "message": {
                    "content": [{"type": "tool_use", "name": "Shell"}],
                },
            },
            {
                "role": "assistant",
                "message": {
                    "content": [{"type": "text", "text": "Port is 8081"}],
                },
            },
            {"role": "system", "message": {"content": "skip"}},
            {"isSidechain": True, "role": "assistant", "message": {"content": "skip"}},
        ]
        destination = io.StringIO()
        hook.convert_transcript(
            io.StringIO("\n".join(map(json.dumps, entries)) + "\n{broken\n"),
            destination,
        )
        self.assertEqual(
            [json.loads(line) for line in destination.getvalue().splitlines()],
            [
                {"role": "user", "content": "Remember the port"},
                {"role": "assistant", "content": "Port is 8081"},
            ],
        )

    def test_session_joins_steer_and_recall_into_additional_context(self) -> None:
        answers = iter(
            [
                '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Scopes"}}',
                '{"continue":true,"additionalContext":"Remember this"}',
            ]
        )

        def fake_run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            self.assertEqual(kwargs["env"]["MEM0_CURSOR_ADAPTER"], "1")
            self.assertEqual(kwargs["env"]["MEM0_SCOPE_AGENT_ID"], "cursor")
            forwarded = json.loads(str(kwargs["input"]))
            self.assertEqual(forwarded["session_id"], "conv-1")
            self.assertEqual(forwarded["hook_event_name"], "SessionStart")
            self.assertEqual(forwarded["cwd"], os.getcwd())
            return subprocess.CompletedProcess(command, 0, stdout=next(answers))

        with (
            patch.dict(os.environ, {}, clear=True),
            patch("hook.subprocess.run", side_effect=fake_run),
        ):
            output = json.loads(
                hook.run_hook(
                    "session",
                    {
                        "hook_event_name": "sessionStart",
                        "conversation_id": "conv-1",
                        "workspace_roots": [os.getcwd()],
                    },
                )
            )
        self.assertEqual(output, {"additional_context": "Scopes\n\nRemember this"})

    def test_prompt_keeps_submission_open_and_forwards_context(self) -> None:
        cwd = os.getcwd()
        with tempfile.TemporaryDirectory() as directory:
            digest = hashlib.sha1(cwd.encode()).hexdigest()[:8]
            (Path(directory) / f"{digest}.json").write_text(
                json.dumps({"session_id": "conv-1", "cwd": cwd}),
                encoding="utf-8",
            )
            with (
                patch.dict(os.environ, {"MEM0_BRADY_SESSIONS_DIR": directory}),
                patch(
                    "hook.subprocess.run",
                    return_value=subprocess.CompletedProcess(
                        [],
                        0,
                        stdout='{"hookSpecificOutput":{"additionalContext":"Search first"}}',
                    ),
                ) as run,
            ):
                output = json.loads(
                    hook.run_hook(
                        "prompt",
                        {
                            "hook_event_name": "beforeSubmitPrompt",
                            "prompt": "resume the mem0 work",
                            "conversation_id": "conv-1",
                            "cwd": cwd,
                        },
                    )
                )
        run.assert_called_once()
        self.assertEqual(
            output,
            {"continue": True, "additional_context": "Search first"},
        )

    def test_prompt_runs_session_scripts_when_session_start_did_not(self) -> None:
        calls: list[str] = []

        def capture(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            name = Path(command[-1]).name
            calls.append(name)
            text = {
                "steer.sh": "Scopes",
                "run-context.sh": "Remember this",
                "run-prompt.sh": "Search first",
            }[name]
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=json.dumps({"additionalContext": text}),
            )

        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict(os.environ, {"MEM0_BRADY_SESSIONS_DIR": directory}),
            patch("hook.subprocess.run", side_effect=capture),
        ):
            output = json.loads(
                hook.run_hook(
                    "prompt",
                    {
                        "hook_event_name": "beforeSubmitPrompt",
                        "prompt": "resume the mem0 work",
                        "conversation_id": "conv-1",
                        "cwd": os.getcwd(),
                    },
                )
            )
        self.assertEqual(calls, ["steer.sh", "run-context.sh", "run-prompt.sh"])
        self.assertEqual(
            output,
            {
                "continue": True,
                "additional_context": "Scopes\n\nRemember this\n\nSearch first",
            },
        )

    def test_stop_converts_transcript_and_does_not_follow_up(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "agent.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "role": "user",
                        "message": {
                            "content": [{"type": "text", "text": "Persist this decision"}]
                        },
                    }
                )
                + "\n"
            )

            def capture(
                command: list[str], **kwargs: object
            ) -> subprocess.CompletedProcess[str]:
                forwarded = json.loads(str(kwargs["input"]))
                path = Path(forwarded["transcript_path"])
                self.assertNotEqual(path, transcript)
                self.assertEqual(
                    json.loads(path.read_text()),
                    {"role": "user", "content": "Persist this decision"},
                )
                return subprocess.CompletedProcess(
                    command, 0, stdout='{"continue":true,"suppressOutput":true}'
                )

            with patch("hook.subprocess.run", side_effect=capture):
                self.assertEqual(
                    hook.run_hook(
                        "stop",
                        {
                            "hook_event_name": "stop",
                            "cwd": directory,
                            "conversation_id": "conv-1",
                            "transcript_path": str(transcript),
                        },
                    ),
                    "",
                )
            self.assertTrue(transcript.exists())

    def test_metadata_rewrites_tool_name_and_updated_input(self) -> None:
        def capture(
            command: list[str], **kwargs: object
        ) -> subprocess.CompletedProcess[str]:
            forwarded = json.loads(str(kwargs["input"]))
            self.assertEqual(forwarded["tool_name"], "mcp__mem0__add_memory")
            self.assertEqual(forwarded["tool_input"]["text"], "port 8081")
            self.assertEqual(forwarded["session_id"], "conv-1")
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=json.dumps(
                    {
                        "hookSpecificOutput": {
                            "hookEventName": "PreToolUse",
                            "permissionDecision": "allow",
                            "updatedInput": {"text": "port 8081", "app_id": "mem0-brady"},
                        }
                    }
                ),
            )

        with patch("hook.subprocess.run", side_effect=capture):
            output = json.loads(
                hook.run_hook(
                    "metadata",
                    {
                        "hook_event_name": "preToolUse",
                        "tool_name": "MCP:add_memory",
                        "tool_input": '{"text":"port 8081"}',
                        "conversation_id": "conv-1",
                        "cwd": os.getcwd(),
                    },
                )
            )
        self.assertEqual(
            output,
            {
                "permission": "allow",
                "updated_input": {"text": "port 8081", "app_id": "mem0-brady"},
            },
        )

    def test_unrelated_tool_is_allowed_without_calling_the_guard(self) -> None:
        with patch("hook.subprocess.run") as run:
            output = hook.run_hook(
                "metadata",
                {
                    "hook_event_name": "preToolUse",
                    "tool_name": "MCP:search",
                    "mcp_server_name": "github",
                    "cwd": os.getcwd(),
                },
            )
        run.assert_not_called()
        self.assertEqual(json.loads(output), {"permission": "allow"})

    def test_blockwrite_maps_a_deny(self) -> None:
        with patch(
            "hook.subprocess.run",
            return_value=subprocess.CompletedProcess(
                [],
                0,
                stdout=json.dumps(
                    {
                        "hookSpecificOutput": {
                            "permissionDecision": "deny",
                            "permissionDecisionReason": "Use Mem0",
                        }
                    }
                ),
            ),
        ):
            output = json.loads(
                hook.run_hook(
                    "blockwrite",
                    {
                        "hook_event_name": "preToolUse",
                        "tool_name": "StrReplace",
                        "tool_input": {"path": "/tmp/MEMORY.md"},
                        "cwd": os.getcwd(),
                    },
                )
            )
        self.assertEqual(output["permission"], "deny")
        self.assertIn("Use Mem0", output["agent_message"])

    def test_empty_guard_output_still_allows(self) -> None:
        self.assertEqual(hook.permission_response(""), {"permission": "allow"})

    def test_cursor_identity_preserves_an_explicit_override(self) -> None:
        for explicit, expected in (
            (None, "cursor"),
            ("", "cursor"),
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
                        "audit",
                        {
                            "cwd": os.getcwd(),
                            "hook_event_name": "afterMCPExecution",
                            "tool_name": "add_memory",
                            "mcp_server_name": "mem0",
                        },
                    )
                self.assertEqual(
                    run.call_args.kwargs["env"]["MEM0_SCOPE_AGENT_ID"], expected
                )

    def test_invalid_input_fails_open_without_echoing_it(self) -> None:
        for handler, expected in (
            ("session", ""),
            ("prompt", '{"continue":true}\n'),
            ("metadata", '{"permission":"allow"}\n'),
        ):
            with (
                self.subTest(handler=handler),
                patch("sys.argv", ["hook.py", handler]),
                patch("sys.stdin", io.StringIO("secret")),
                patch("sys.stdout", new_callable=io.StringIO) as out,
                patch("sys.stderr", new_callable=io.StringIO) as err,
            ):
                hook.main()
            self.assertEqual(out.getvalue(), expected)
            self.assertIn("hook skipped", err.getvalue())
            self.assertNotIn("secret", err.getvalue())

    def test_direct_claude_hook_under_cursor_allows_and_returns(self) -> None:
        script = hook.PLUGIN_ROOT / "hooks" / "lib-scope.sh"
        skipped = subprocess.run(
            ["bash", "-c", f'. "{script}"'],
            capture_output=True,
            text=True,
            env={"CURSOR_VERSION": "1.0.0", "PATH": os.environ.get("PATH", "")},
            check=False,
        )
        self.assertEqual(skipped.returncode, 0)
        self.assertEqual(
            json.loads(skipped.stdout),
            {"continue": True, "permission": "allow", "suppressOutput": True},
        )
        adapted = subprocess.run(
            ["bash", "-c", f'. "{script}"'],
            capture_output=True,
            text=True,
            env={
                "CURSOR_VERSION": "1.0.0",
                "MEM0_CURSOR_ADAPTER": "1",
                "PATH": os.environ.get("PATH", ""),
            },
            check=False,
        )
        self.assertEqual(adapted.returncode, 0)
        self.assertEqual(adapted.stdout, "")

    def test_manifest_selects_cursor_hooks_and_second_timeouts(self) -> None:
        manifest = json.loads(
            (hook.PLUGIN_ROOT / ".cursor-plugin/plugin.json").read_text()
        )
        self.assertEqual(manifest["version"], "261016.1")
        configuration = json.loads((hook.PLUGIN_ROOT / manifest["hooks"]).read_text())
        self.assertEqual(configuration["version"], 1)
        registered = set()
        for groups in configuration["hooks"].values():
            for group in groups:
                name = group["command"].rsplit(" ", 1)[1]
                registered.add(name)
                self.assertGreater(group["timeout"], hook.timeout_floor(name))
                self.assertLessEqual(group["timeout"], 60)
        self.assertEqual(registered, set(hook.SCRIPTS))
        self.assertNotIn("afterMCPExecution", configuration["hooks"])
        audit = [
            group["command"]
            for group in configuration["hooks"]["postToolUse"]
            if group["command"].endswith(" audit")
        ]
        self.assertEqual(audit, ["./cursor/hook.py audit"])


if __name__ == "__main__":
    unittest.main()
