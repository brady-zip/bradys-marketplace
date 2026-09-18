"""Offline release-artifact check, separate from the fake-tool unit suite.

Supply the recorded release binary and optionally its source schema. This runs
only version/help/schema probes in a temporary config directory; it never calls
Omni, Gemini, authentication or dashboard commands.
"""
from argparse import ArgumentParser, Namespace
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from common import Blocked, PINS, checked, schema_digest
from preflight import Preflight, validate_chart_room_schema


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=shutil.which("chart-room"))
    parser.add_argument("--source-schema", type=Path)
    args = parser.parse_args()
    if not args.binary:
        parser.error("Supply --binary with the tested chart-room release executable.")
    binary = Path(args.binary).resolve()
    release = PINS["chart_room_tested_release"]
    if hashlib.sha256(binary.read_bytes()).hexdigest() != release["sha256"]:
        raise Blocked("ARTIFACT_MISMATCH", "Executable differs from the recorded release asset; review its provenance before updating the pin.")
    print("PASS: release asset SHA-256 matches " + release["asset"])
    with TemporaryDirectory(prefix="omni-chart-room-compatibility-") as scratch:
        directory = Path(scratch)
        (directory / "bin").mkdir()
        (directory / "bin/chart-room").symlink_to(binary)
        (directory / "config").mkdir()
        os.environ["PATH"] = str(directory / "bin") + os.pathsep + os.environ.get("PATH", "")
        probe = Preflight(Namespace(profile=None, timeout=30), str(directory / "config"))
        version = checked(probe.call(["chart-room", "--version"])).strip()
        if version != release["version"]:
            raise Blocked("VERSION_MISMATCH", "Release executable reports a different version.")
        print("PASS: " + probe.chart_room())
        schema = json.loads((directory / "config/omni-dashboard.schema.json").read_bytes())
        if args.source_schema:
            source_schema = json.loads(args.source_schema.read_bytes())
            if schema_digest(source_schema) != schema_digest(schema):
                raise Blocked("SOURCE_SCHEMA_MISMATCH", "Source schema differs from the release executable's materialized schema.")
            print("PASS: release and source schemas match after semantic normalization")
        # Alter an actual native constraint, preserving the schema ID/envelope.
        # This reproduces the rejected candidate pin, not a fake CLI's schema.
        altered = copy.deepcopy(schema)
        del altered["components"]["schemas"]["QueryPresentationsPatchExternal"]["properties"]["data"]["minProperties"]
        try:
            validate_chart_room_schema(altered)
        except Blocked as error:
            if error.code != "SCHEMA_MISMATCH":
                raise
        else:
            raise Blocked("ALTERED_SCHEMA_ACCEPTED", "An altered native schema passed the plugin's enforcement.")
        print("PASS: altered native schema rejected with SCHEMA_MISMATCH")
        print("Accepted schema SHA-256: " + schema_digest(schema))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Blocked as error:
        print(error.code + ": " + error.message, file=sys.stderr)
        raise SystemExit(1)
