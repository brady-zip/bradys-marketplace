"""Shared test fixtures for mem0-mcp-selfhosted."""

import os

import pytest


@pytest.fixture(autouse=True)
def suppress_telemetry():
    """Ensure telemetry is always disabled in tests."""
    os.environ["MEM0_TELEMETRY"] = "false"
