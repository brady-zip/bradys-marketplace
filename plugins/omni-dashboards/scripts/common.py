"""Small stdlib helpers; native validation belongs to chart-room's pinned schema."""
import json
import hashlib
import os
from pathlib import Path
import re
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / "knowledge/dependencies.json").read_text())
INSTANCE = "https://zip.omniapp.co"


def schema_digest(schema):
    # Bun materialization decodes Unicode escapes. Pin semantic JSON content,
    # including all native schemas, rather than the generator's whitespace.
    return hashlib.sha256(json.dumps(
        schema, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    ).encode()).hexdigest()


class Blocked(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message
        super().__init__(message)


def run(argv, *, env=None, stdin=None, timeout=30):
    """No shell interpolation, no raw CLI diagnostics in user-facing reports."""
    child = subprocess.Popen(
        argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env=env, start_new_session=True,
    )
    try:
        out, err = child.communicate(stdin, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        return subprocess.CompletedProcess(argv, 124, "", "")
    return subprocess.CompletedProcess(argv, child.returncode, out, err)


def checked(result):
    if result.returncode == 0:
        return result.stdout
    if result.returncode == 124:
        raise Blocked("PROBE_UNAVAILABLE", "Probe timed out; dependency health is unknown.")
    try:
        error = json.loads(result.stderr)
        status = error.get("status")
        nested = error.get("error")
        code = nested.get("code") if isinstance(nested, dict) else None
    except (ValueError, AttributeError):
        status, code = None, None
    # Error bodies may contain credentials or internal data. Only emit fixed text.
    messages = {
        401: ("UNAUTHENTICATED", "Credential rejected or expired; refresh the official CLI profile."),
        403: ("PERMISSION_DENIED", "API identity lacks access; ask the model/content owner."),
        404: ("NOT_FOUND_OR_HIDDEN", "Resource is absent or hidden from this identity; do not infer a missing field."),
        409: ("CONFLICT", "Inspect the existing draft/conflict before continuing."),
        429: ("RATE_LIMITED", "Probe rate limited; retry after the server cooldown."),
    }
    if status in messages:
        raise Blocked(*messages[status])
    if code in {"PERMISSION_DENIED", "PR_REQUIRED", "UNAUTHENTICATED", "WRONG_INSTANCE"}:
        raise Blocked(code, "Chart-room rejected this operation; resolve access or instance selection.")
    if re.search(r"unknown (command|flag)", result.stderr, re.I):
        raise Blocked("OUTDATED_CAPABILITIES", "Installed CLI lacks a required command or flag.")
    if re.search(r"no API token configured|profile .*not found", result.stderr, re.I):
        raise Blocked("MISSING_CREDENTIALS", "Run official omni config init in your own terminal.")
    raise Blocked("PROBE_FAILED", "Command failed; health was not established. Raw output withheld.")


def object_output(result):
    text = checked(result)
    try:
        data = json.loads(text)
    except ValueError:
        raise Blocked("MALFORMED_RESPONSE", "CLI did not return valid JSON.") from None
    if not isinstance(data, dict):
        raise Blocked("MALFORMED_RESPONSE", "CLI did not return a JSON object.")
    return data


def read_jsonc(path):
    """Read comments/trailing commas without changing source or string contents."""
    text = Path(path).read_text()
    # Strings are matched first, so URLs and comment-like text remain untouched.
    token = r'"(?:\\.|[^"\\])*"|//[^\n\r]*|/\*[\s\S]*?\*/'
    text = re.sub(token, lambda m: m[0] if m[0].startswith('"') else " ", text)
    text = re.sub(r'"(?:\\.|[^"\\])*"|,\s*(?=[}\]])',
                  lambda m: "" if m[0].startswith(",") else m[0], text)
    return json.loads(text)


def definition(path):
    if not str(path).endswith(".omni.jsonc"):
        raise Blocked("INVALID_DEFINITION", "Use a .omni.jsonc definition.")
    try:
        value = read_jsonc(path)
        if value["version"] != 1 or value["provider"] != "omni" or value["instance"] != INSTANCE:
            raise ValueError()
        for key in ("test", "prod"):
            identifier(value["targets"][key])
        if value["targets"]["test"] == value["targets"]["prod"]:
            raise ValueError()
        identifier(value["document"]["modelId"])
        return value
    except (ValueError, KeyError, TypeError, OSError):
        raise Blocked("INVALID_DEFINITION", "Invalid contract v1 envelope or target pair; run chart-room validate.") from None


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", value):
        raise Blocked("INVALID_IDENTIFIER", "Expected an identifier, not an option or URL.")
    return value


def config_path():
    return Path(os.environ.get("OMNI_CONFIG_PATH") or (
        Path(os.environ.get("OMNI_CONFIG_DIR") or (
            Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "omni-cli"
        )) / "config.json"
    ))


def credentials(profile=None):
    """Resolve official auth in memory; never persist or print secret values.

    Diagnostic API calls use the current token via the child environment with an
    empty config path. This prevents OAuth refresh from mutating the user's store
    during doctor. An expired token needs official setup/refresh outside doctor.
    """
    selected = {}
    try:
        config = json.loads(config_path().read_text()) if config_path().exists() else {}
        name = profile or config.get("defaultProfile")
        if name:
            selected = config.get("profiles", {}).get(name)
            if not isinstance(selected, dict):
                raise Blocked("MISSING_PROFILE", "Selected official CLI profile does not exist.")
            if selected.get("apiEndpoint", "").rstrip("/") != INSTANCE:
                raise Blocked("WRONG_PROFILE_HOST", "Selected profile points elsewhere; no credential was forwarded.")
        if os.environ.get("OMNI_BASE_URL", INSTANCE).rstrip("/") != INSTANCE:
            raise Blocked("WRONG_PROFILE_HOST", "OMNI_BASE_URL points elsewhere; no credential was forwarded.")
        token = os.environ.get("OMNI_API_TOKEN") or selected.get("apiKey") or selected.get("accessToken")
        if not token:
            raise Blocked("MISSING_CREDENTIALS", "Run omni config init; credentials belong in the official store.")
        return name, token
    except (OSError, ValueError, AttributeError, TypeError):
        raise Blocked("INVALID_CONFIG", "Cannot read official Omni config; repair with omni config init.") from None


def private_json(path, data):
    path = Path(path)
    with open(path, "w", opener=lambda p, flags: os.open(p, flags, 0o600)) as handle:
        json.dump(data, handle, indent=2, allow_nan=False)
        handle.write("\n")
