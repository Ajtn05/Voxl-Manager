"""Runs as the Linux desktop user via SSH, or as the systemd service launcher."""
import base64
import fcntl
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import secrets
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time

HOME = Path.home()
STATE = HOME / ".local/share/voxl-manager"
UNIT = "voxl-manager.service"
UNIT_PATH = HOME / ".config/systemd/user" / UNIT
CONFIG = STATE / "server.json"
HELPER = "/usr/local/sbin/voxl-manager-serve"
MANAGER = ["systemctl", "--user"]
def has_flag(name, help_text):
    return bool(re.search(r"(?<![\w-])--" + name + r"(?=[\s=,]|$)", help_text))


class Problem(Exception):
    pass


def run(*args, timeout=4, env=None):
    try:
        return subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, errors="replace", timeout=timeout, env=env)
    except FileNotFoundError:
        raise Problem(f"Required Linux tool is missing: {args[0]}.")
    except subprocess.TimeoutExpired:
        raise Problem(f"{args[0]} timed out.")


def redacted(value):
    value = re.sub(r"(?i)(https?://[^\s?#]+)\?[^\s]+", r"\1?[redacted]", value)
    value = re.sub(r"(?i)((?:token|password|passphrase|authorization|cookie|secret)[^\n]{0,30}[:=]\s*)[^\n]+",
                   r"\1[redacted]", value)
    return value[-10000:]


def props(text):
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


def discover(config):
    override = config["executable"]
    candidates = [override] if override else [shutil.which("voxl"), HOME / ".cargo/bin/voxl",
        HOME / ".local/bin/voxl", "/usr/local/bin/voxl", "/usr/bin/voxl"]
    return next((str(Path(p).resolve()) for p in candidates
                 if p and os.path.isfile(p) and os.access(p, os.X_OK)), None)


def executable_details(config):
    binary = discover(config)
    if not binary:
        raise Problem("Voxl executable not found. Set its absolute path in Settings.")
    version = run(binary, "--version")
    help_result = run(binary, "--help")
    flags = help_result.stdout + help_result.stderr
    if help_result.returncode or not all(has_flag(name, flags) for name in ("allowed-hosts", "addr")):
        raise Problem("This Voxl binary must advertise --allowed-hosts and --addr in --help. "
                      "The managed service binds to loopback. Upgrade Voxl or use your existing manual setup.")
    if config["httpPort"] != 6901 and not has_flag("port", flags):
        raise Problem("This Voxl binary does not advertise --port. Use HTTP port 6901 or upgrade.")
    return binary, redacted((version.stdout or version.stderr).strip())[:160] if not version.returncode else "Version unavailable"


def desktop(config):
    try:
        result = run("loginctl", "list-sessions", "--no-legend", "--no-pager")
        if result.returncode:
            return "unknown", "Could not query Linux desktop sessions with loginctl."
        sessions = []
        for line in result.stdout.splitlines():
            fields = line.split()
            if len(fields) < 2 or fields[1] != str(os.getuid()):
                continue
            s = run("loginctl", "show-session", fields[0], "-p", "Type", "-p", "Remote",
                    "-p", "State", "-p", "Display")
            if not s.returncode:
                sessions.append(props(s.stdout))
        x11 = [s for s in sessions if s.get("Remote") == "no" and s.get("Type") == "x11"
               and s.get("State") in {"active", "online"}]
        if not x11:
            if any(s.get("Type") == "wayland" and s.get("Remote") == "no" for s in sessions):
                return "unavailable", "The desktop uses Wayland. Sign in to a local X11 session."
            return "loggedOut", "This SSH user has no local X11 desktop session. Sign in on the Linux desktop first."
        display = config["display"]
        if not any(s.get("Display", "") in {"", display, display.split(".")[0]} for s in x11):
            return "unavailable", f"The logged-in X11 session does not match {display}."
        display_number = display[1:].split(".")[0]
        try:
            is_socket = stat.S_ISSOCK(Path(f"/tmp/.X11-unix/X{display_number}").stat().st_mode)
        except OSError:
            is_socket = False
        if not is_socket:
            return "unavailable", f"X11 display {display} has no local X socket."
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                probe.settimeout(1)
                probe.connect(f"/tmp/.X11-unix/X{display_number}")
        except OSError:
            return "unavailable", f"X11 display {display} is not accepting connections."
        authority = Path(config["xauthority"])
        if not authority.is_file() or not os.access(authority, os.R_OK):
            return "credentials", "Xauthority is missing or unreadable. Check the Xauthority path in Settings."
        env = dict(os.environ, DISPLAY=display, XAUTHORITY=str(authority))
        result = run("xdpyinfo", "-display", display, env=env)
        if result.returncode:
            detail = result.stderr.lower()
            if any(word in detail for word in ("authoriz", "cookie", "authentic", "protocol specified")):
                return "credentials", f"X11 rejected the Xauthority credentials for {display}."
            return "unavailable", f"The socket for {display} is open, but xdpyinfo could not use the display. Check the session and Xauthority."
        return "ready", f"X11 {display} is accessible."
    except Problem as error:
        return "unknown", str(error)


def unit_status():
    result = run(*MANAGER, "show", UNIT, "-p", "LoadState", "-p", "ActiveState", "-p", "FragmentPath",
                 "-p", "ExecMainCode", "-p", "ExecMainStatus", "-p", "Result", "-p", "DropInPaths",
                 "-p", "ControlGroup")
    info = props(result.stdout)
    if not info.get("LoadState"):
        return "unavailable", info
    if info["LoadState"] == "not-found":
        return ("foreign" if os.path.lexists(UNIT_PATH) else "missing"), info
    try:
        ours = (info.get("FragmentPath") == str(UNIT_PATH) and not info.get("DropInPaths")
                and not UNIT_PATH.is_symlink() and UNIT_PATH.read_text().startswith("# Installed by Voxl Manager\n"))
    except OSError:
        ours = False
    return (info.get("ActiveState", "unknown") if ours else "foreign"), info


def voxl_pids(binary):
    pids = set()
    for proc in Path("/proc").iterdir():
        if not proc.name.isdecimal():
            continue
        try:
            exe = os.readlink(proc / "exe").removesuffix(" (deleted)")
            if exe == binary or Path(exe).name == "voxl":
                pids.add(int(proc.name))
        except OSError:
            pass
    return pids


def listener_lines(port):
    listeners = run("ss", "-H", "-ltnp", f"sport = :{port}")
    if listeners.returncode:
        raise Problem("Could not inspect Linux TCP listeners with ss.")
    return [line for line in listeners.stdout.splitlines() if line.strip()]


def listener_pids(line):
    return set(map(int, re.findall(r"pid=([0-9]+)", line)))


def inspect_voxl(config, binary):
    pids = voxl_pids(binary)
    port = config["httpPort"]
    lines = listener_lines(port)
    if not lines:
        return "starting" if pids else "stopped"
    capable = [line for line in lines if len(line.split()) >= 4 and
               line.split()[3].rsplit(":", 1)[0] in {"127.0.0.1", "0.0.0.0", "*", "[::]", "[::ffff:127.0.0.1]"}]
    if not capable or any(not (listener_pids(line) & pids) for line in capable):
        return "conflict"
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request("GET", "/", headers={"Host": config["hostname"]})
        response = connection.getresponse()
        if 200 <= response.status < 300:
            return "ready"
        if response.status == 401 and "basic" in (response.getheader("WWW-Authenticate") or "").lower():
            return "ready"
        return "rejected" if response.status == 403 else "unhealthy"
    except (OSError, http.client.HTTPException):
        return "unhealthy"
    finally:
        connection.close()


def serve_info(config, verb="inspect"):
    port = str(config["httpsPort"]) if verb != "disable" else "0"
    policy = [config["hostname"], str(config["httpPort"])] if verb in {"enable", "prune"} else []
    result = run("/usr/bin/sudo", "-n", "--", HELPER, verb, port, *policy, timeout=19)
    if not result.returncode:
        value = json.loads(result.stdout)
        if verb != "disable" and (value["host"] != config["hostname"] or value["approvedUpstream"] != config["httpPort"]):
            return dict(value, kind="policyMismatch", detail="The app hostname or Voxl HTTP port differs from the administrator's Serve policy.")
        return value
    if verb != "inspect":
        raise Problem("Serve helper: " + (redacted(result.stderr.strip()) or "operation failed"))
    # A correctly configured, pre-existing manual proxy can still be used without sudo.
    try:
        cli = run("tailscale", "serve", "status", "--json", timeout=5)
        if cli.returncode:
            raise ValueError
        current = json.loads(cli.stdout) or {}
        key = config["hostname"] + ":" + port
        layers = [current, *(current.get("Foreground") or {}).values()]
        kind, target = "disabled", None
        if any(any(v and k.endswith(":" + port) for k, v in (layer.get("AllowFunnel") or {}).items())
               for layer in layers):
            kind = "public"
        elif any(port in (layer.get("TCP") or {}) or
                 any(k.endswith(":" + port) for k in (layer.get("Web") or {})) for layer in layers):
            kind = "conflict"
            web = current.get("Web") or {}
            handlers = (web.get(key) or {}).get("Handlers") or {}
            root = handlers.get("/") or {}
            if ((current.get("TCP") or {}).get(port) == {"HTTPS": True}
                    and sum(k.endswith(":" + port) for k in web) == 1
                    and not any(port in (layer.get("TCP") or {}) or
                                any(k.endswith(":" + port) for k in (layer.get("Web") or {}))
                                for layer in layers[1:])
                    and set(handlers) == {"/"} and set(root) == {"Proxy"}):
                match = re.fullmatch(r"http://(?:127\.0\.0\.1|localhost):([0-9]{1,5})/?", root["Proxy"])
                if match:
                    kind = "matched" if int(match[1]) == config["httpPort"] else "mismatch"
                    target = "http://127.0.0.1:" + match[1]
    except (Problem, ValueError, TypeError, AttributeError):
        kind, target = "unknown", None
    return {"kind": kind, "upstream": target,
            "detail": "Managed Serve unavailable: " + redacted(result.stderr.strip())[:500]}


def current(config):
    binary = discover(config)
    state, detail = desktop(config)
    unit, info = unit_status()
    return {"voxl": inspect_voxl(config, binary), "x11": state, "x11Detail": detail,
            "unit": unit, "executable": binary, "serve": serve_info(config)}


def atomic(path, contents):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as handle:
        try:
            handle.write(contents)
            handle.flush()
            os.fsync(handle.fileno())
            os.replace(handle.name, path)
        finally:
            if os.path.exists(handle.name):
                os.unlink(handle.name)


def managed_config(config, binary):
    return {"hostname": config["hostname"], "display": config["display"],
            "xauthority": config["xauthority"], "httpPort": config["httpPort"], "binary": binary}


def read_password():
    descriptor = os.open(STATE / "password", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as file:
        metadata = os.fstat(file.fileno())
        if (metadata.st_uid != os.getuid() or metadata.st_mode & 0o077
                or not stat.S_ISREG(metadata.st_mode)):
            raise Problem("The Voxl password file must be owned by this user and mode 0600.")
        data = file.read(4097)
    secret = data.decode("utf-8").rstrip("\r\n")
    if len(data) > 4096 or not secret or any(character in secret for character in "\r\n\0"):
        raise Problem("The Voxl password file must contain one nonempty line.")
    return secret


def managed_login(config):
    """Return a session credential only for our running Voxl and its verified private route."""
    state, info = unit_status()
    group = info.get("ControlGroup")
    binary = discover(config)
    if (state != "active" or not group or not binary or not CONFIG.is_file()
            or json.loads(CONFIG.read_text()) != managed_config(config, binary)):
        return {}
    lines = listener_lines(config["httpPort"])
    pids = set().union(*(listener_pids(line) for line in lines))
    if not pids or any(not listener_pids(line) for line in lines) or not pids <= voxl_pids(binary):
        return {}
    for pid in pids:
        groups = (Path("/proc") / str(pid) / "cgroup").read_text().splitlines()
        if not any(line.split(":", 2)[-1] == group for line in groups):
            return {}
    if serve_info(config)["kind"] != "matched":
        return {}
    secret = read_password()
    authorization = base64.b64encode(("voxl:" + secret).encode("utf-8")).decode("ascii")
    connection = http.client.HTTPConnection("127.0.0.1", config["httpPort"], timeout=3)
    try:
        connection.request("GET", "/", headers={"Host": config["hostname"],
                                                   "Authorization": "Basic " + authorization})
        if 200 <= connection.getresponse().status < 300:
            return {"password": secret}
        return {}
    finally:
        connection.close()


def install(config):
    state, _ = unit_status()
    if state not in {"missing", "inactive", "failed"}:
        raise Problem(f"Cannot install while the service is {state}. Stop the managed service first, "
                      "or check the systemd user manager and existing unit.")
    binary, version = executable_details(config)
    UNIT_PATH.parent.mkdir(parents=True, exist_ok=True)
    atomic(STATE / "remote.py", SOURCE)
    atomic(CONFIG, json.dumps(managed_config(config, binary)))
    atomic(UNIT_PATH, UNIT_SOURCE)
    result = run(*MANAGER, "daemon-reload", timeout=6)
    if result.returncode:
        raise Problem("Service files were written, but systemd daemon-reload failed: " + redacted(result.stderr))
    if unit_status()[0] not in {"inactive", "failed"}:
        raise Problem("The installed unit did not load from the expected path. Check systemd overrides.")
    return {"message": f"Installed the user service for {version} at {binary}. It was not enabled at boot."}


def journal():
    result = run("journalctl", "--user", "-u", UNIT, "-n", "40", "--no-pager", "-o", "cat")
    return redacted(result.stdout if result.returncode == 0 else result.stderr).strip()


def require_desktop(config):
    state, detail = desktop(config)
    if state != "ready":
        raise Problem(detail)


def start(config, restart=False):
    require_desktop(config)
    binary = discover(config)
    state, _ = unit_status()
    health = inspect_voxl(config, binary)
    if not restart and health == "ready":
        return {"message": "Reusing the running Voxl instance."}
    if state in {"missing", "unavailable", "foreign"}:
        raise Problem("Install the managed Voxl user service in Settings before starting it. "
                      f"Current unit status: {state}.")
    if not binary or not CONFIG.is_file() or json.loads(CONFIG.read_text()) != managed_config(config, binary):
        raise Problem("Voxl settings differ from the installed service. Stop it and reinstall it from Settings.")
    if not restart and state == "active":
        raise Problem("The managed service is running but the HTTP endpoint is unhealthy. Check logs or Restart Voxl.")
    if health in {"conflict", "rejected"} or (voxl_pids(binary) and state not in {"active", "activating"}):
        raise Problem("Voxl or another process already owns the configured port, or Voxl rejected the host. "
                      "Check the existing process and settings before retrying.")
    result = run(*MANAGER, "restart" if restart else "start", UNIT, timeout=10)
    deadline = time.monotonic() + 12
    while result.returncode == 0 and time.monotonic() < deadline:
        state, info = unit_status()
        if state in {"failed", "inactive"}:
            break
        if inspect_voxl(config, binary) == "ready":
            return {"message": "Managed Voxl is serving HTTP."}
        time.sleep(0.4)
    state, info = unit_status()
    raise Problem(f"Voxl failed to become ready. Unit: {state}, result: {info.get('Result', 'unknown')}, "
                  f"exit code: {info.get('ExecMainStatus', 'unknown')}.\n"
                  + redacted(result.stderr) + "\n" + journal())


def stop():
    state, _ = unit_status()
    if state == "missing":
        return {"message": "No managed Voxl service is installed."}
    if state in {"foreign", "unavailable"}:
        raise Problem(f"Cannot verify the managed user unit ({state}). No service was stopped.")
    result = run(*MANAGER, "stop", UNIT, timeout=12)
    if result.returncode:
        raise Problem("Could not stop the managed Voxl service: " + redacted(result.stderr))
    return {"message": "Managed Voxl service stopped."}


def launch():
    config = json.loads(CONFIG.read_text())
    require_desktop(config)
    binary = config["binary"]
    config["executable"] = binary
    if voxl_pids(binary) or inspect_voxl(config, binary) != "stopped":
        raise Problem("Voxl or another listener is already running. Refusing a second instance.")
    executable_details(config)  # Revalidate if the binary was upgraded after installation.
    args = [binary, "--allowed-hosts=" + config["hostname"], "--addr=127.0.0.1"]
    if config["httpPort"] != 6901:
        args.append("--port=" + str(config["httpPort"]))
    env = dict(os.environ, DISPLAY=config["display"], XAUTHORITY=config["xauthority"])
    password_file = STATE / "password"
    if not password_file.exists() and not env.get("VOXL_PASSWORD"):
        atomic(password_file, secrets.token_urlsafe(24) + "\n")
    if password_file.exists():
        env["VOXL_PASSWORD"] = read_password()
    with subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
        # Voxl may print a sign-in link. Keep both streams drained and redact before journald.
        def drain(pipe, output):
            while True:
                data = pipe.readline(16385)
                if not data:
                    return
                if len(data) == 16385 and not data.endswith(b"\n"):
                    while data and not data.endswith(b"\n"):
                        data = pipe.readline(16385)
                    print("[Oversized Voxl log line omitted]", file=output, flush=True)
                    continue
                text = data.decode("utf-8", errors="replace")
                if env.get("VOXL_PASSWORD"):
                    text = text.replace(env["VOXL_PASSWORD"], "[redacted]")
                print(redacted(text).rstrip(), file=output, flush=True)
        readers = [threading.Thread(target=drain, args=(pipe, output), daemon=True)
                   for pipe, output in [(child.stdout, sys.stdout), (child.stderr, sys.stderr)]]
        for reader in readers:
            reader.start()
        while True:
            try:
                code = child.wait(timeout=8)
                for reader in readers:
                    reader.join(timeout=1)
                if code < 0:
                    print(f"Voxl died from signal {-code}.", file=sys.stderr)
                return code if code >= 0 else 128 - code
            except subprocess.TimeoutExpired:
                state, detail = desktop(config)
                if state != "ready":
                    print(detail, file=sys.stderr)
                    child.terminate()
                    try:
                        child.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
                    return 78


def verify_node(config):
    result = run("tailscale", "status", "--json", "--peers=false", timeout=5)
    if result.returncode:
        raise Problem("Could not verify the SSH destination’s Tailscale identity.")
    status = json.loads(result.stdout)
    hostname = ((status.get("Self") or {}).get("DNSName") or "").rstrip(".").lower()
    if status.get("BackendState") != "Running" or hostname != config["hostname"]:
        raise Problem("The SSH destination is not the configured Tailscale node. Check the SSH alias and MagicDNS hostname.")


def main():
    action = sys.argv[1]
    if action == "launch":
        return launch()
    config = CONFIGURATION.copy()
    config["xauthority"] = config["xauthority"] or str(HOME / ".Xauthority")
    verify_node(config)
    if action == "inspect":
        value = current(config)
    elif action == "managed-login":
        try:
            value = managed_login(config)
        except (Problem, OSError, ValueError, KeyError, TypeError, http.client.HTTPException):
            # This response is used only for sign-in. Keep credential errors out of logs.
            value = {}
    elif action == "serve-status":
        value = serve_info(config)
    elif action == "logs":
        value = {"message": journal() or "The managed Voxl journal is empty."}
    else:
        STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (STATE / "operation.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Problem("Another Voxl Manager operation is running on this server. Try again.")
            if action == "install":
                value = install(config)
            elif action in {"start", "restart"}:
                value = start(config, action == "restart")
            elif action == "stop":
                value = stop()
            elif action in {"enable", "prune", "disable"}:
                value = serve_info(config, action)
            else:
                raise Problem("Unknown Voxl Manager operation.")
    print(json.dumps(value))
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    try:
        sys.exit(main())
    except (Problem, OSError, ValueError, KeyError, TypeError) as error:
        print(redacted(str(error)), file=sys.stderr)
        sys.exit(78 if len(sys.argv) > 1 and sys.argv[1] == "launch" else 1)
