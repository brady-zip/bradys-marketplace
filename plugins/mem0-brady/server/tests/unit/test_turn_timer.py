"""Post-turn duration gating without clocks, network calls, or real state."""

import importlib
import json
import os
from io import StringIO
from unittest.mock import MagicMock, patch

import pytest

from mem0_mcp_selfhosted import hooks


def run_hook(handler, payload):
    with patch("sys.stdin", StringIO(json.dumps(payload))), patch("sys.stdout", new_callable=StringIO) as out:
        handler()
    return json.loads(out.getvalue())


@pytest.fixture
def turn(tmp_path, monkeypatch):
    monkeypatch.setattr(hooks.tempfile, "gettempdir", lambda: str(tmp_path))
    monkeypatch.setattr(hooks, "_CAPTURE_MIN_TURN_SECONDS", 120)
    monkeypatch.setattr(hooks, "_CAPTURE_ENABLED", True)
    monkeypatch.setattr(hooks, "_HANDOFF_ENABLED", True)
    monkeypatch.setattr(hooks, "_CAPTURE_MIN_INTERVAL", 0)
    monkeypatch.setenv("MEM0_HANDOFF_DIR", str(tmp_path / "handoffs"))
    monkeypatch.setenv("MEM0_WORKSTREAM_DIR", str(tmp_path / "workstreams"))
    transcript = tmp_path / "transcript.jsonl"
    transcript.write_text(json.dumps({"role": "assistant", "content": "Completed the task. " * 100}))
    payload = {"session_id": "timer-test", "cwd": "/project", "prompt": "go", "transcript_path": str(transcript)}
    clock = MagicMock(return_value=1000.0)
    monkeypatch.setattr(hooks.time, "monotonic", clock)
    mem = MagicMock()
    monkeypatch.setattr(hooks, "_get_client", lambda: mem)
    # A short prompt must still start a timer, before recall's length gate.
    run_hook(hooks.prompt_main, payload)
    return payload, clock, mem


@pytest.mark.parametrize("elapsed,expected", [(0, False), (119.9, False), (120, False), (120.1, True), (300, True)])
def test_stop_duration_boundary(turn, elapsed, expected):
    payload, clock, mem = turn
    clock.return_value += elapsed
    result = run_hook(hooks.stop_main, payload)
    assert result == {"continue": True, "suppressOutput": True}
    assert mem.add.call_count == int(expected)
    assert not hooks._turn_timer_path(payload).exists()
    if expected:
        assert mem.add.call_args.kwargs["infer"] is True


@pytest.mark.parametrize("raw,expected", [(None, 120), ("", 120), ("300", 300), ("0", 0), ("-1", 120), ("oops", 120)])
def test_configuration(raw, expected):
    # Load in an isolated module so default/override coverage doesn't disturb
    # the constants other tests monkeypatch on the shared hooks module.
    spec = importlib.util.spec_from_file_location("turn_timer_config_test", hooks.__file__)
    module = importlib.util.module_from_spec(spec)
    with patch.dict("os.environ", {}, clear=True), patch("dotenv.load_dotenv"):
        if raw is not None:
            os.environ["MEM0_CAPTURE_MIN_TURN_SECONDS"] = raw
        spec.loader.exec_module(module)
    assert module._CAPTURE_MIN_TURN_SECONDS == expected


@pytest.mark.parametrize("threshold,elapsed,expected", [(300, 121, False), (300, 301, True), (0, 0, True)])
def test_override_changes_capture(turn, monkeypatch, threshold, elapsed, expected):
    payload, clock, mem = turn
    monkeypatch.setattr(hooks, "_CAPTURE_MIN_TURN_SECONDS", threshold)
    clock.return_value += elapsed
    run_hook(hooks.stop_main, payload)
    assert mem.add.call_count == int(expected)


@pytest.mark.parametrize("value", [None, "garbage", "nan", "-inf", "inf", "2000"])
def test_missing_or_invalid_timer_skips(turn, value):
    payload, clock, mem = turn
    marker = hooks._turn_timer_path(payload)
    if value is None:
        marker.unlink()
    else:
        marker.write_text(value)
    run_hook(hooks.stop_main, payload)
    mem.add.assert_not_called()


def test_zero_disables_gate_without_timer(turn, monkeypatch):
    payload, clock, mem = turn
    hooks._turn_timer_path(payload).unlink()
    monkeypatch.setattr(hooks, "_CAPTURE_MIN_TURN_SECONDS", 0)
    run_hook(hooks.stop_main, payload)
    mem.add.assert_called_once()


def test_new_prompt_resets_timer_and_duplicate_stop_skips(turn):
    payload, clock, mem = turn
    clock.return_value += 300
    run_hook(hooks.stop_main, payload)
    run_hook(hooks.stop_main, payload)
    mem.add.assert_called_once()
    clock.return_value += 3600  # Idle time between turns must not qualify.
    run_hook(hooks.prompt_main, payload)
    clock.return_value += 10
    run_hook(hooks.stop_main, payload)
    mem.add.assert_called_once()


def test_sessions_are_isolated(turn):
    payload, clock, mem = turn
    clock.return_value += 300
    run_hook(hooks.prompt_main, {**payload, "session_id": "other-session"})
    run_hook(hooks.stop_main, payload)
    mem.add.assert_called_once()
    run_hook(hooks.stop_main, {**payload, "session_id": "other-session"})
    mem.add.assert_called_once()


def test_agents_are_isolated(turn, monkeypatch):
    payload, clock, mem = turn
    clock.return_value += 300
    monkeypatch.setattr(hooks, "_get_agent_id", lambda: "another-agent")
    run_hook(hooks.stop_main, payload)
    mem.add.assert_not_called()


def test_timer_io_failure_is_nonfatal(turn):
    payload, clock, mem = turn
    with patch.object(hooks.Path, "write_text", side_effect=OSError("unavailable")):
        assert run_hook(hooks.prompt_main, payload)["continue"] is True
    with patch.object(hooks.Path, "read_text", side_effect=OSError("unavailable")):
        assert run_hook(hooks.stop_main, payload)["continue"] is True
    mem.add.assert_not_called()


def test_precompact_bypasses_gate_and_preserves_timer(turn):
    payload, clock, mem = turn
    run_hook(hooks.precompact_main, payload)
    mem.add.assert_called_once()
    assert hooks._turn_timer_path(payload).exists()


def test_short_turn_still_writes_workstream_handoff(turn, monkeypatch):
    payload, clock, mem = turn
    monkeypatch.setattr(hooks, "_active_workstream", lambda _: {"slug": "work"})
    with patch.object(hooks, "_write_handoff") as handoff:
        handoff.return_value = None
        run_hook(hooks.stop_main, payload)
    mem.add.assert_not_called()
    handoff.assert_called_once()


def test_short_untagged_turn_does_not_open_client_or_read_transcript(turn):
    payload, clock, mem = turn
    with patch.object(hooks, "_get_client") as client, patch.object(hooks, "_read_recent_messages") as read:
        run_hook(hooks.stop_main, payload)
    client.assert_not_called()
    read.assert_not_called()


def test_long_turn_preserves_capture_switch_and_cooldown(turn, monkeypatch):
    payload, clock, mem = turn
    clock.return_value += 300
    monkeypatch.setattr(hooks, "_CAPTURE_ENABLED", False)
    run_hook(hooks.stop_main, payload)
    mem.add.assert_not_called()
    monkeypatch.setattr(hooks, "_CAPTURE_ENABLED", True)
    monkeypatch.setattr(hooks, "_CAPTURE_MIN_INTERVAL", 900)
    run_hook(hooks.prompt_main, payload)
    hooks._mark_captured(payload["cwd"], "project")
    clock.return_value += 300
    run_hook(hooks.stop_main, payload)
    mem.add.assert_not_called()
