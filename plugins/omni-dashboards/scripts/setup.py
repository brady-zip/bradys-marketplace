"""Install ordinary local dependencies; credentials remain in official stores."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

from common import INSTANCE, PINS, ROOT, run

OMNI_ARCHIVES = {
    "arm64": ("arm64", "3835aa54f1bf4addcb909d37cb3dacba83b163f7dcd091ffb476160b24bbdaca"),
    "x86_64": ("amd64", "3eb7703f98a083c14267c614e9a47efb3086a157ce3a2b10d3185f77c6ddafdc"),
}


def command(argv):
    print("Setup:", shlex.join(argv), flush=True)
    subprocess.run(argv, check=True)


def installer(url, destination, args):
    # Download fully before executing: a failed/truncated pipe cannot look green.
    urllib.request.urlretrieve(url, destination)
    command(["sh", str(destination), *args])


def install_omni(scratch):
    if platform.system() != "Darwin" or platform.machine() not in OMNI_ARCHIVES:
        raise RuntimeError("This setup supports macOS; install the official 1.3.1 archive for your platform.")
    arch, digest = OMNI_ARCHIVES[platform.machine()]
    archive = scratch / "omni.tar.gz"
    urllib.request.urlretrieve(
        f"https://github.com/exploreomni/cli/releases/download/v1.3.1/omni_1.3.1_darwin_{arch}.tar.gz", archive
    )
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError("Official Omni archive checksum mismatch; nothing installed.")
    # Extract only the expected regular binary, never arbitrary archive paths.
    with tarfile.open(archive) as tar:
        entry = tar.getmember("omni")
        if not entry.isfile():
            raise RuntimeError("Official archive has no regular omni binary.")
        binary = scratch / "omni"
        binary.write_bytes(tar.extractfile(entry).read())
        binary.chmod(0o755)
    if run([str(binary), "--version"]).stdout.strip() != "omni version 1.3.1":
        raise RuntimeError("Unexpected official Omni version; nothing installed.")
    target = Path.home() / ".local/bin/omni"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, target)
    print("Installed official Omni CLI 1.3.1 from its checksum-verified release.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--configure-auth", action="store_true")
    parser.add_argument("--profile", default="zip-omni")
    args = parser.parse_args()
    os.environ["PATH"] = str(Path.home() / ".local/bin") + os.pathsep + os.environ["PATH"]
    if args.install:
        with tempfile.TemporaryDirectory(prefix="omni-setup-") as temporary:
            scratch = Path(temporary)
            if not shutil.which("omni"):
                install_omni(scratch)
            elif run(["omni", "--version"]).stdout.strip() != "omni version " + PINS["omni_cli_version"]:
                raise RuntimeError("An untested omni executable exists. Select official CLI 1.3.1 explicitly; setup will not overwrite a different CLI.")
            if not shutil.which("uv"):
                installer("https://astral.sh/uv/install.sh", scratch / "uv.sh", [])
            if not shutil.which("llm"):
                command(["uv", "tool", "install", "llm", "--with", "llm-gemini", "--with", "httpx[socks]"])
            else:
                models = run(["llm", "models", "list"])
                if models.returncode or "gemini/" not in models.stdout:
                    # Preserve other installed llm plugins; never force-rebuild its env.
                    command(["llm", "install", "llm-gemini", "httpx[socks]"])
            if not shutil.which("mise"):
                installer("https://mise.run", scratch / "mise.sh", [])
            if run(["mise", "x", "node@22", "--", "node", "--version"]).returncode:
                command(["mise", "install", "node@22"])
    if args.configure_auth:
        if not sys.stdin.isatty():
            raise RuntimeError("Run setup --configure-auth in your terminal; never paste credentials into chat or arguments.")
        if not shutil.which("omni"):
            raise RuntimeError("Official Omni CLI missing; first run setup --install.")
        command(["omni", "config", "init", "--name", args.profile, "--endpoint", INSTANCE])
    print("Personal credentials:", shlex.join(["omni", "config", "init", "--name", args.profile, "--endpoint", INSTANCE]))
    print("Gemini credentials: llm keys set gemini (user terminal only).")
    print("Chrome Beta: sign into Omni and enable its supported remote debugging/autoConnect.")
    print(f"Chart-room: install a released {PINS['chart_room_min_version']}+ build with the pinned schema; local candidates are not release acceptance.")
    print("Setup cannot assign roles, mint credentials, enable AccessBoost, or change publication policy.")
    return subprocess.run(["bash", str(ROOT / "scripts/check-setup.sh"), "--profile", args.profile]).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Setup stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
