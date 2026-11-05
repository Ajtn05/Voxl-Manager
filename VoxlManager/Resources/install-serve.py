"""One-time administrator installer for the app's restricted Serve helper."""
import base64
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import tempfile

HELPER = Path("/usr/local/sbin/voxl-manager-serve")
POLICY = Path("/etc/voxl-manager/serve.json")
STATE = Path("/var/lib/voxl-manager")
RULE = Path("/etc/sudoers.d/voxl-manager")
VISUDO = "/usr/sbin/visudo"


def trusted_directory(path, mode=0o755):
    if not path.exists():
        path.mkdir(mode=mode)
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise RuntimeError(f"Administrator must check the ownership and permissions of {path}.")


def existing_matches(path, data, mode):
    if not os.path.lexists(path):
        return False
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise RuntimeError(f"Administrator must check the ownership and permissions of {path}.")
    existing = path.read_bytes()
    if path == POLICY:
        matches = json.loads(existing) == json.loads(data)
    else:
        matches = existing == data
    if not matches or stat.S_IMODE(metadata.st_mode) != mode:
        raise RuntimeError(f"An existing configuration differs at {path}. Review it on Linux before replacing it.")
    return True


def install_file(path, data, mode):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".voxl-manager-", delete=False) as file:
        temporary = Path(file.name)
        try:
            os.fchmod(file.fileno(), mode)
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
            if path == RULE:
                subprocess.run([VISUDO, "-cf", str(temporary)], check=True)
            # Linking fails safely if another administrator created the destination.
            os.link(temporary, path)
        finally:
            temporary.unlink()


def main():
    helper, host, local_port, https_port, user = sys.argv[2:]
    if os.geteuid() != 0 or os.environ.get("SUDO_USER") != user:
        raise RuntimeError("Run the prepared command as the configured SSH user and approve Linux sudo.")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{0,63}", user) or pwd.getpwnam(user).pw_uid == 0:
        raise RuntimeError("Choose a non-root Linux desktop account.")
    if not re.fullmatch(r"[a-z0-9.-]+\.ts\.net", host):
        raise RuntimeError("Invalid Tailscale hostname.")
    local_port, https_port = int(local_port), int(https_port)
    if not all(1 <= p <= 65535 for p in (local_port, https_port)) or local_port == https_port:
        raise RuntimeError("Invalid ports.")
    os.umask(0o022)
    for directory in (Path("/usr"), Path("/usr/local"), HELPER.parent, Path("/etc"),
                      RULE.parent, Path("/var"), Path("/var/lib"), POLICY.parent):
        trusted_directory(directory)
    trusted_directory(STATE, 0o700)
    if stat.S_IMODE(STATE.stat().st_mode) != 0o700:
        raise RuntimeError(f"Administrator must set {STATE} to mode 0700.")
    policy = {
        "hostname": host, "upstreamPort": local_port,
        "httpsPorts": sorted({8443, 9443, 10443, https_port} - {local_port})
    }
    rule = f"{user} ALL=(root) NOPASSWD: {HELPER}\n".encode()
    files = [(HELPER, base64.b64decode(helper, validate=True), 0o755),
             (POLICY, (json.dumps(policy, indent=2) + "\n").encode(), 0o644),
             (RULE, rule, 0o440)]
    pending = [(path, data, mode) for path, data, mode in files if not existing_matches(path, data, mode)]
    subprocess.run([VISUDO, "-cf", "/etc/sudoers"], check=True)
    for path, data, mode in pending:
        install_file(path, data, mode)
    subprocess.run([VISUDO, "-cf", "/etc/sudoers"], check=True)
    print("Voxl Manager Serve helper is installed. Return to the app and click Check & Continue.")


try:
    main()
except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
    sys.exit(f"Voxl Manager setup: {error}")
