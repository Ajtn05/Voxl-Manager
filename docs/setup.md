# Set up Voxl Manager on Linux

In **Settings**, enter your server's full Tailscale MagicDNS hostname and the Linux account signed into the X11 desktop. Save the settings, then choose **Start Remote Desktop** in **Overview** and follow its prompts. The app can install the user service over SSH. If a new HTTPS route needs administrator approval, it prepares a single command for Terminal and resumes when you click **Check & Continue**. **Set Up Serve Management** also opens this prompt when you already have a working private proxy.

## 1. Verify SSH and the desktop

Keep both devices on the same tailnet. The Mac needs MagicDNS, an OpenSSH key or agent that works without an interactive prompt, and a trusted Linux host key.

On the **Linux console** or another already trusted administration session, get its SSH host key fingerprint:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

On the **Mac**, replace the example hostname and username in the first two lines below. Compare the displayed fingerprint against the trusted value before answering the first-connection prompt. If OpenSSH negotiates a different key type, get that key's fingerprint on the console.

```sh
VOXL_HOST='server.your-tailnet.ts.net'
VOXL_SSH_USER='your-linux-user'
ssh -o StrictHostKeyChecking=ask "$VOXL_SSH_USER@$VOXL_HOST"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$VOXL_SSH_USER@$VOXL_HOST" /usr/bin/true
```

If you use an SSH config alias, use the same alias in the app and in the Terminal check. The app honors SSH config, key paths, proxy hops, and agent authentication, while turning off forwarding and connection multiplexing for its commands. Leave the app's SSH port field blank to inherit the alias's port (normally 22). An agent must be available to apps launched by Finder or Xcode. If you use a shell-only custom agent, configure its socket via OpenSSH's `IdentityAgent` option.

On **Linux**, run these commands from a terminal in the graphical session to check the prerequisites:

```sh
command -v python3 systemctl loginctl xdpyinfo ss tailscale
systemctl --user show-environment >/dev/null
DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" xdpyinfo >/dev/null
printf 'Display %s\nXauthority %s\n' "${DISPLAY:-:0}" "${XAUTHORITY:-$HOME/.Xauthority}"
tailscale version
tailscale serve status --json
```

Use a Linux system with Python 3.9 or later, systemd/logind, and a Tailscale release that supports the LocalAPI Serve ETag. Set the display and Xauthority path in Settings if they differ from `:0` and the Linux user's `~/.Xauthority`. To inspect Voxl, run its binary with `--version` and `--help`. If it is outside the SSH PATH or standard bin directories, enter its absolute Linux path in Settings.

The [Voxl upstream CLI](https://github.com/tembo/voxl#usage) documents default port 6901 and `--allowed-hosts`, `--addr`, and `--port`. The installer verifies the **installed** binary's help output. The service preserves the working display, Xauthority, allowed host, and default port, adding `--addr=127.0.0.1` so the managed HTTP server is reachable only through loopback. It passes `--port` only for a non-default HTTP port when that flag is present.

## 2. Install the Serve helper as a Linux administrator

Skip this step if you only want to connect to an already configured private proxy. Install it to let the app create, switch, or remove its own routes. Enable MagicDNS and [HTTPS certificates](https://tailscale.com/docs/how-to/set-up-https-certificates) in your tailnet, and ensure your access rules permit SSH and the chosen HTTPS ports from your Mac to the Linux server.

Copy `voxl-manager-serve`, `serve.json`, and `voxl-manager.sudoers` from this repository's `linux/` directory to a directory you control on Linux. Review them and fill in your server's full MagicDNS hostname in `serve.json`. Update the upstream and HTTPS ports there if you use different ports in the app. From that directory, run:

```sh
sudo install -d -o root -g root -m 0755 /etc/voxl-manager
sudo install -d -o root -g root -m 0700 /var/lib/voxl-manager
sudo install -o root -g root -m 0755 voxl-manager-serve /usr/local/sbin/voxl-manager-serve
sudo install -o root -g root -m 0644 serve.json /etc/voxl-manager/serve.json
sudo visudo -f /etc/sudoers.d/voxl-manager
```

In `visudo`, enter the rule from `voxl-manager.sudoers` with your Linux desktop username in place of `YOUR_LINUX_USER`:

```sudoers
YOUR_LINUX_USER ALL=(root) NOPASSWD: /usr/local/sbin/voxl-manager-serve
```

Confirm that `/usr/local/sbin`, the helper, and the configuration and state directories are root-owned and not writable by the SSH user. Then run this **as the desktop user**:

```sh
sudo -n /usr/local/sbin/voxl-manager-serve inspect 8443
```

The policy limits the helper to the configured MagicDNS name, the Voxl loopback port, and the approved HTTPS ports. The example uses loopback port 6901 and HTTPS ports 8443, 9443, and 10443. Edit the installed policy with `sudoedit /etc/voxl-manager/serve.json` if your settings change. Use a fixed upstream dedicated to Voxl.

The helper makes the equivalent of a background HTTPS Serve entry using the [Tailscale LocalAPI Serve configuration](https://github.com/tailscale/tailscale/blob/main/client/local/serve.go). It changes the selected node port and route using the daemon's ETag so it can refuse a stale write. It preserves unrelated node routes, Services, foreground routes, and Funnel settings. A port occupied by another route, an unexpected upstream, or any Funnel mapping on the selected port is rejected. It never runs `serve reset` or changes the Tailscale daemon or VPN. The LocalAPI is version dependent; if the daemon does not return an ETag, the helper refuses to write.

The root-only registry records the exact root proxy installed for the Tailscale node. A manual proxy is never claimed automatically. If an administrator edits a managed route, cleanup preserves a changed handler or listener and reports the affected port. Remove a managed route through the app **before** repurposing it by hand; an identical route recreated outside the app is indistinguishable from the recorded entry. If the helper is interrupted after applying a route but before saving ownership, the app treats that route as manual. Inspect it locally before removing it.

## 3. Install the user service from the Mac

1. Launch Voxl Manager. Open **Settings** and verify the hostname, SSH user, display, Xauthority path, executable, and ports.
2. Click **Install / Update User Service…** and confirm. This writes `~/.config/systemd/user/voxl-manager.service`, the launcher, and the resolved configuration under `~/.local/share/voxl-manager/`. It reloads the existing systemd user manager. It does not start Voxl or enable a boot unit.
3. With your Linux desktop signed in to X11, click **Start Remote Desktop** in **Overview**. A healthy Voxl process started by hand will be reused. To switch to app control, first shut down the manual Voxl process by the method you used to start it, then click **Start Remote Desktop**.
4. The viewer signs in with the managed password when it can verify the running user service and private proxy over SSH. The launcher honors `VOXL_PASSWORD` from the systemd user environment or creates a random password in `~/.local/share/voxl-manager/password` (mode 0600) on first launch. If the app asks you to sign in, use your existing Voxl password. With the default Voxl username policy, any username is accepted. The viewer keeps the credential only for the current session.

The unit uses the user's ordinary logind session and systemd process supervision. It starts only after confirming that the local X11 session and cookie work, and its launcher monitors the display after startup. The app does not use `xhost`, configure automatic login, or change the server's boot or lingering policy. A Voxl crash is reported with its exit status and journal output. There is no uncontrolled restart loop.

## Verify on your server

1. Start on your selected HTTPS port (8443 by default). Confirm that the app shows a private proxy and Voxl HTTP readiness. In the viewer, sign in, move the pointer, type, scroll, and try Voxl's clipboard controls. If the page loads but the video does not, open the same URL with **Browser** to separate WebKit behavior from server issues.
2. Click **Disconnect Viewer**. Check that the private URL still works in your browser. Connect again without starting a second process.
3. Select another approved port (for example 9443), choose **Apply HTTPS Port**, then **Connect Viewer**. Confirm that your unrelated and manually configured routes remain present.
4. Use **Stop Remote Desktop**. Check that the managed unit stops and the app-created route disappears. A manual Voxl process and manual proxy, if present, should remain untouched.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Tailscale CLI unavailable | Open Tailscale from the dashboard and check the profile. Run `/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json` in a regular Mac Terminal. Restricted development sandboxes may not be able to load Tailscale preferences. |
| Tailscale connected; server unreachable | Check that the Linux server is on the same tailnet, that MagicDNS resolves the selected name, and that tailnet rules allow its traffic. Try `tailscale ping "$VOXL_HOST"` from the Mac terminal where you set the hostname. SSH can still work when the tailnet blocks ping. |
| SSH host key or authentication failure | Verify the key in step 1. If the key changed unexpectedly, investigate before updating known hosts. Check the alias, `ssh-add -l`, and the non-interactive SSH command. |
| Desktop logged out or display unavailable | Sign into a local X11 session with the display configured in Settings. Use `loginctl list-sessions` to check the session. |
| Xauthority problem | Check the path as the graphical user and rerun the `xdpyinfo` command in step 1. Avoid changing X11 access controls. |
| Voxl process or port conflict | Check `ss -ltnp 'sport = :6901'` and existing Voxl launchers. The app refuses to proxy an unidentified listener. |
| Managed service failed | Use **Diagnostics → Fetch Voxl Logs** or run `journalctl --user -u voxl-manager.service -n 40 --no-pager` on Linux. If the display, executable, host, or HTTP port changed, stop the unit and reinstall from Settings. |
| Serve conflict or upstream mismatch | Run `tailscale serve status` on Linux. Choose a free approved port for private Serve or have the administrator reconcile the mismatch. |
| HTTPS verification fails | Verify tailnet permissions, MagicDNS, and certificate availability. Check the new route and keep using the old route if the new one does not verify. An added route remains recorded so you can retry or remove it. |
| Embedded viewer fails after the page loads | Try **Reload**, then **Browser**. WebKit behavior for codecs and clipboard varies by version and by Voxl build. A valid certificate and a successful page request do not prove live video playback. |

To uninstall, first stop the managed desktop and confirm that its routes are gone. On Linux, remove the app's user unit and launcher, then run `systemctl --user daemon-reload`. Keep or remove the user password file as you prefer. An administrator can then remove the app's sudoers file (using `visudo` to validate the remaining configuration), helper, and policy/state directories.
