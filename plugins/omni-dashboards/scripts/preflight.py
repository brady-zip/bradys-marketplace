"""Read-only diagnostics behind preflight.sh and check-setup.sh.

Help/schema probes precede credentials. Chart-room materializes its schema even
for --help: use a disposable config directory so doctor never alters user state.
No green dependency probe claims API publishing or rendered query acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

from common import (Blocked, INSTANCE, PINS, checked, credentials, definition,
                    identifier, object_output, run, schema_digest)

DOCUMENT_COMMANDS = (
    "v2-create", "v2-get", "list-drafts", "v2-patch-draft",
    "v2-patch-draft-by-identifier", "v2-get-draft", "v2-publish-draft",
    "get-permissions",
)


def validate_chart_room_schema(schema):
    if (schema.get("$id") != PINS["schema_id"] or
            schema_digest(schema) != PINS["schema_sha256"]):
        raise Blocked("SCHEMA_MISMATCH", "Omni envelope/native schema differs from the tested pin; reconcile the contract before authoring.")


class Preflight:
    def __init__(self, args, scratch):
        self.args, self.checks = args, []
        self.env = dict(os.environ, CHART_ROOM_CONFIG_DIR=scratch,
                        CHART_ROOM_NO_UPDATE="1", OMNI_NO_UPDATE_NOTIFIER="1")
        self.profile = args.profile
        self.omni = ["omni", "--base-url", INSTANCE, "--format", "json"]

    def record(self, name, status, reason, code=None):
        self.checks.append(dict(check=name, status=status, reason=reason, code=code))

    def probe(self, name, action):
        try:
            reason = action()
            self.record(name, "OK", reason)
            return True
        except Blocked as error:
            # A timeout/sandbox failure is an unknown result, not a missing tool.
            status = "DEFERRED" if error.code == "PROBE_UNAVAILABLE" else "FAILED"
            self.record(name, status, error.message, error.code)
            return False
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            self.record(name, "FAILED", "Malformed response or unreadable dependency.", "INVALID_RESPONSE")
            return False

    def call(self, argv):
        return run(argv, env=self.env, timeout=self.args.timeout)

    def chart_room(self):
        minimum = PINS["chart_room_min_version"]
        if not shutil.which("chart-room"):
            raise Blocked("MISSING_CHART_ROOM", f"Install the released Omni-capable chart-room {minimum} or later.")
        version = checked(self.call(["chart-room", "--version"])).strip()
        if not re.fullmatch(r"\d+\.\d+\.\d+", version) or (
            tuple(map(int, version.split("."))) < tuple(map(int, minimum.split(".")))
        ):
            raise Blocked("OUTDATED_CHART_ROOM", f"chart-room {minimum}+ with contract v1 is required; executable presence is insufficient.")
        requirements = [
            (["--help"], ["--provider", "--profile", "--format", "omni", "validate", "import"]),
            (["init", "--help"], ["--model", "--prod-folder", "--test-folder"]),
            (["validate", "--help"], ["--remote"]),
            (["status", "--help"], ["--json"]),
            (["omni", "--help"], ["models", "topics", "fields"]),
            (["auth", "--help"], ["status", "login"]),
        ]
        for command, expected in requirements:
            help_text = checked(self.call(["chart-room", *command]))
            if not all(word in help_text for word in expected):
                raise Blocked("OUTDATED_CAPABILITIES", "chart-room is missing required Omni commands/options.")
        schema_path = Path(self.env["CHART_ROOM_CONFIG_DIR"]) / "omni-dashboard.schema.json"
        if not schema_path.exists():
            raise Blocked("MISSING_SCHEMA", "chart-room did not materialize its Omni contract schema.")
        schema_bytes = schema_path.read_bytes()
        schema = json.loads(schema_bytes)
        validate_chart_room_schema(schema)
        return f"chart-room {version}; pinned native/envelope schema, contract v1."

    def omni_capabilities(self):
        if not shutil.which("omni"):
            raise Blocked("MISSING_OMNI_CLI", "Install official Omni CLI 1.3.1 with /omni-dashboards:setup.")
        if checked(self.call(["omni", "--version"])).strip() != "omni version " + PINS["omni_cli_version"]:
            raise Blocked("OUTDATED_OMNI_CLI", "Use the tested official Omni CLI 1.3.1; other versions need contract verification.")
        help_text = checked(self.call(["omni", "documents", "--help"]))
        if not all(cmd in help_text.split() for cmd in DOCUMENT_COMMANDS):
            raise Blocked("OUTDATED_CAPABILITIES", "Official Omni CLI is missing Documents v2 capabilities.")
        for command, endpoint in [
            (["documents", "v2-create"], "/api/v2/documents"),
            (["query", "run"], "/api/v1/query/run"),
            (["whoami", "whoami"], "/api/v1/whoami"),
        ]:
            schema = object_output(self.call(["omni", *command, "--schema"]))
            if schema.get("path") != endpoint:
                raise Blocked("OUTDATED_CAPABILITIES", "Official command schema does not match the pinned API.")
        return "Official Omni CLI 1.3.1; Documents v2, query and whoami schemas verified offline."

    def auth(self):
        self.profile, token = credentials(self.profile)
        self.env["OMNI_API_TOKEN"] = token
        self.env["OMNI_CONFIG_PATH"] = str(Path(self.env["CHART_ROOM_CONFIG_DIR"]) / "absent-omni-config.json")
        identity = object_output(self.call(self.omni + ["whoami", "whoami"]))
        if not all(k in identity for k in ("user", "keyScope", "orgRole", "rolesByModel")):
            raise Blocked("MALFORMED_RESPONSE", "whoami did not return a complete identity.")
        return "whoami succeeded for the selected profile/environment credential and Zip instance."

    def model(self, model):
        identifier(model)
        identity = object_output(self.call(self.omni + ["whoami", "whoami", "--model-id", model]))
        permissions = identity.get("rolesByModel", {}).get(model, {}).get("permissions", [])
        if not (isinstance(permissions, list) and "USE_WORKBOOKS" in permissions and (
            "QUERY_TOPICS" in permissions or "QUERY_FULL_MODEL" in permissions
        )):
            raise Blocked("MODEL_PERMISSION_DENIED", "Selected model lacks workbook/topic-query permissions; ask its owner.")
        models = object_output(self.call(self.omni + [
            "models", "list", "--model-id", model, "--explorable", "true", "--page-size", "100",
        ]))
        if not any(row.get("id") == model and row.get("deletedAt") is None
                   and row.get("modelKind") in ("SHARED", "SHARED_EXTENSION")
                   for row in models.get("records", [])):
            raise Blocked("MODEL_INACCESSIBLE", "Selected shared model is unavailable to this identity; this is not missing-field evidence.")
        return "Shared model is explorable; scoped whoami confirms resolved authoring permissions."

    def targets(self, value):
        for target in ("test", "prod"):
            target_id = value["targets"][target]
            document = object_output(self.call(self.omni + ["documents", "v2-get", target_id]))
            if document.get("modelId") != value["document"]["modelId"]:
                raise Blocked("MODEL_MISMATCH", "Remote target uses a different base model.")
            policy = object_output(self.call(self.omni + ["documents", "get-permissions", target_id]))
            required = policy.get("abilities", {}).get("requirePullRequestToPublish")
            if required is True:
                raise Blocked("PR_REQUIRED", "Target requires native Omni PR publication; stop without changing policy or AccessBoost.")
            if required is not False:
                raise Blocked("UNKNOWN_POLICY", "Could not establish target publication policy.")
            drafts = json.loads(checked(self.call(self.omni + ["documents", "list-drafts", target_id])))
            if not isinstance(drafts, list) or any(not isinstance(d, dict) or "branch" not in d for d in drafts):
                raise Blocked("MALFORMED_RESPONSE", "Draft inventory is incomplete.")
            if any(d["branch"] is None for d in drafts):
                raise Blocked("DRAFT_CONFLICT", "A main draft exists; inspect it with its owner before publication.")
        # Read and policy checks cannot prove a future write will be authorized.
        return "Both targets readable; model/policy/drafts checked. Actual publish authorization is proved by chart-room test."

    def native_validation(self):
        result = object_output(self.call([
            "chart-room", "validate", str(Path(self.args.file).resolve()), "--format", "json",
        ]))
        if (result.get("outcome") != "VALIDATED" or result.get("provider") != "omni"
                or result.get("contractVersion") != 1 or result.get("remote") is not False):
            raise Blocked("INVALID_VALIDATION", "chart-room did not confirm offline contract v1 native validation.")
        return "Native envelope, visualization, control and container validation passed offline."

    def llm(self):
        if not shutil.which("llm"):
            raise Blocked("MISSING_LLM", "Run setup to install persistent llm with llm-gemini.")
        models = checked(self.call(["llm", "models", "list"]))
        if self.args.gemini_model not in models:
            raise Blocked("MISSING_GEMINI_MODEL", "Installed llm does not expose the selected Gemini model; install llm-gemini or select an available model.")
        if not self.args.gemini_model.startswith("gemini/"):
            raise Blocked("NOT_GEMINI", "Independent evaluation requires a Gemini model.")
        if self.args.offline or self.args.skill not in ("iterate", "all") and not self.args.smoke:
            self.record("Gemini reachability", "DEFERRED", "No API smoke call requested; model listing is not reachability evidence.")
        else:
            result = self.call_llm_smoke()
            if result.returncode:
                if result.returncode == 124:
                    raise Blocked("PROBE_UNAVAILABLE", "Gemini probe timed out; no rating or reachability claim is available.")
                raise Blocked("GEMINI_UNAVAILABLE", "Gemini smoke call failed; check llm's gemini key and network. No author score may substitute.")
            if result.stdout.strip() != "OK":
                raise Blocked("GEMINI_MALFORMED", "Gemini smoke response was unexpected; evaluation is not ready.")
        return "Installed llm exposes the selected Gemini model."

    def call_llm_smoke(self):
        return run(["llm", "-m", self.args.gemini_model, "--no-stream", "--no-log"],
                   env=self.env, stdin="Reply with exactly OK, no punctuation.",
                   timeout=self.args.timeout)

    def browser(self):
        if not Path(PINS["chrome_binary"]).is_file():
            raise Blocked("BROWSER_ABSENT", "Install Chrome Beta, sign into Omni, and enable supported remote debugging/autoConnect.")
        if not shutil.which("mise"):
            raise Blocked("MISSING_MISE", "Run setup to install mise and Node 22 for the browser MCP.")
        # mise exec can auto-install. where only locates an already installed runtime.
        node_root = checked(self.call(["mise", "where", "node@22"])).strip()
        checked(self.call([str(Path(node_root) / "bin/node"), "--version"]))
        result = self.call(["pgrep", "-f", PINS["chrome_binary"]])
        if result.returncode == 1:
            raise Blocked("BROWSER_NOT_RUNNING", "Start your authenticated Chrome Beta session.")
        if result.returncode != 0 or not result.stdout.strip():
            raise Blocked("PROBE_UNAVAILABLE", "Process inspection could not run; confirm browser attachment through MCP.")
        self.record("Browser attachment", "DEFERRED", "Process presence is not attachment/authentication proof; dashboard-browser must verify the exact test URL through MCP.")
        return "Chrome Beta process and Node runtime available."

    def execute(self):
        chart_ok = self.probe("chart-room/schema", self.chart_room)
        omni_ok = self.probe("Official CLI capabilities", self.omni_capabilities)
        value = None
        if self.args.file:
            def read_definition():
                nonlocal value
                value = definition(self.args.file)
                if self.args.model and self.args.model != value["document"]["modelId"]:
                    raise Blocked("MODEL_MISMATCH", "--model conflicts with the source file.")
                return "Contract envelope and distinct target identifiers read."
            self.probe("Definition", read_definition)
            if chart_ok and value:
                self.probe("Native validation", self.native_validation)
        if self.args.offline:
            self.record("Authentication/model/targets", "DEFERRED", "Offline mode: no remote probes; this is not publishing readiness.")
        elif omni_ok and self.probe("Authentication", self.auth):
            model = value["document"]["modelId"] if value else self.args.model
            if model:
                model_ok = self.probe("Model permissions", lambda: self.model(model))
            else:
                model_ok = False
                self.record("Model permissions", "DEFERRED", "Select an existing shared model, then rerun with --model or --file.")
            if value and model_ok:
                self.probe("Target access", lambda: self.targets(value))
            else:
                self.record("Target access", "DEFERRED", "No verified source/model pair; rerun --file before test publication.")
        else:
            self.record("Remote probes", "DEFERRED", "Prerequisite CLI/authentication failed; no resource-existence conclusion is possible.")
        if self.args.skill in ("iterate", "doctor", "all", "setup") or self.args.smoke:
            self.probe("Gemini", self.llm)
            self.probe("Browser", self.browser)
        else:
            self.record("Browser/Gemini", "DEFERRED", "Not required for this scope; iterate runs its own live checks.")
        if self.args.require_context and (not value or self.args.offline):
            self.record("Publishing context", "FAILED", "Require a valid --file and live checks before publication.", "MISSING_CONTEXT")
        failures = sum(row["status"] == "FAILED" for row in self.checks)
        deferred = sum(row["status"] == "DEFERRED" for row in self.checks)
        required_unknown = self.args.require_context and any(
            row["status"] == "DEFERRED" and row["check"] not in (
                "Browser attachment", "Browser/Gemini", "Gemini reachability",
            ) for row in self.checks
        )
        result = dict(status="BLOCKED" if failures else "DEFERRED" if required_unknown else "OK", failed=failures,
                      deferred=deferred, checks=self.checks)
        if self.args.json:
            print(json.dumps(result, indent=2))
        else:
            for row in self.checks:
                if not self.args.brief or row["status"] != "OK":
                    print(f'{row["status"]}: {row["check"]}: {row["reason"]}' +
                          (f' [{row["code"]}]' if row["code"] else ""))
            print(f'PREFLIGHT_STATUS: {result["status"]}')
            print(f'PREFLIGHT_FAILED: {failures}')
            print(f'PREFLIGHT_DEFERRED: {deferred}')
        return 1 if failures else 2 if required_unknown else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skill", choices=["create", "expand", "iterate", "setup", "doctor", "all"], default="doctor")
    parser.add_argument("--file")
    parser.add_argument("--model")
    parser.add_argument("--profile")
    parser.add_argument("--gemini-model", default=PINS["gemini_model"])
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--smoke", action="store_true", help="Tiny billable Gemini call; implied by iterate/all.")
    parser.add_argument("--require-context", action="store_true")
    parser.add_argument("--brief", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 60:
        parser.error("--timeout must be between 1 and 60 seconds")
    with tempfile.TemporaryDirectory(prefix="omni-preflight-") as scratch:
        return Preflight(args, scratch).execute()


if __name__ == "__main__":
    raise SystemExit(main())
