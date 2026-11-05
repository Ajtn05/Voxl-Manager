# Set up Voxl Manager on Mint

In the app, choose **Start Remote Desktop** and follow its prompts. The app can install the user service over SSH. If a new HTTPS route needs administrator approval, it prepares a single command for Terminal and resumes when you click **Check & Continue**. **Set Up Serve Management** also opens this prompt when you already have a working private proxy.

## 1. Verify SSH and the desktop

Keep both devices on the same tailnet. The Mac needs MagicDNS, an OpenSSH key or agent that works without an interactive prompt, and a trusted Linux host key. The Linux user must be the user who is signed into the physical X11 desktop. The commands below use the original Mint settings.

On the **Linux console** or another already trusted administration session, get its SSH host key fingerprint:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

On the **Mac**, compare the displayed fingerprint against that trusted value before answering the first-connection prompt. If OpenSSH negotiates a different key type, get that key's fingerprint on the console instead.

```sh
ssh -o StrictHostKeyChecking=ask aldrinnellas@mint-server.tail439626.ts.net
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes aldrinnellas@mint-server.tail439626.ts.net /usr/bin/true
```

If you use an SSH config alias, use the same alias in the app and in the Terminal check. The app honors SSH config, key paths, proxy hops, and agent authentication, while turning off forwarding and connection multiplexing for its commands. Leave the app's SSH port field blank to inherit the alias's port (normally 22). An agent must be available to apps launched by Finder or Xcode. If you use a shell-only custom agent, configure its socket via OpenSSH's `IdentityAgent` option.

On **Mint**, confirm the prerequisites from the graphical account:

```sh
command -v python3 systemctl loginctl xdpyinfo ss tailscale
systemctl --user show-environment >/dev/null
DISPLAY=:0 XAUTHORITY=/home/aldrinnellas/.Xauthority xdpyinfo >/dev/null
tailscale version
tailscale serve status --json
```

Use Linux Mint with Python 3.9 or later, systemd/logind, and a current Tailscale release with the LocalAPI Serve ETag. On Mint, `xdpyinfo` is provided by `x11-utils` and `ss` by `iproute2`. To inspect Voxl, run its actual binary with `--version` and `--help` (for example `~/Projects/voxl/target/release/voxl --help` if built from source). If the app cannot find it on the SSH PATH, in the Cargo or local bin directory, or in the project build directory, enter its absolute path in Settings.

The [Voxl upstream CLI](https://github.com/tembo/voxl#usage) documents default port 6901 and `--allowed-hosts`, `--addr`, and `--port`. The installer verifies the **installed** binary's help output. The service preserves the working display, Xauthority, allowed host, and default port, adding `--addr=127.0.0.1` so the managed HTTP server is reachable only through loopback. It passes `--port` only for a non-default HTTP port when that flag is present.

## 2. Install the Serve helper as a Linux administrator

Skip this step if you only want to connect to an already configured private proxy. Install it to let the app create, switch, or remove its own routes. Enable MagicDNS and [HTTPS certificates](https://tailscale.com/docs/how-to/set-up-https-certificates) in your tailnet, and ensure your access rules permit SSH and the chosen HTTPS ports from your Mac to Mint.

Copy the three files from this repository's `linux/` directory to a directory on Mint that you control. Review them before installation. From that directory on Mint, run:

```sh
sudo install -d -o root -g root -m 0755 /etc/voxl-manager
sudo install -d -o root -g root -m 0700 /var/lib/voxl-manager
sudo install -o root -g root -m 0755 voxl-manager-serve /usr/local/sbin/voxl-manager-serve
sudo install -o root -g root -m 0644 serve.json /etc/voxl-manager/serve.json
sudo visudo -f /etc/sudoers.d/voxl-manager
```

Paste the one rule from `voxl-manager.sudoers` into `visudo`:

```sudoers
aldrinnellas ALL=(root) NOPASSWD: /usr/local/sbin/voxl-manager-serve
```

Confirm that `/usr/local/sbin`, the helper, and the configuration and state directories are root-owned and not writable by the SSH user. Then run this **as the desktop user**:

```sh
sudo -n /usr/local/sbin/voxl-manager-serve inspect 8443
```

The example policy approves only this node's MagicDNS name, loopback upstream port 6901, and HTTPS ports 8443, 9443, and 10443. Edit the root-owned policy with `sudoedit /etc/voxl-manager/serve.json` if you need different ports. Use a fixed upstream dedicated to Voxl. The SSH user cannot use this rule to run arbitrary commands, proxy to another host, advertise Funnel, or choose an upstream outside the administrator policy.

The helper makes the equivalent of a background HTTPS Serve entry using the [Tailscale LocalAPI Serve configuration](https://github.com/tailscale/tailscale/blob/main/client/local/serve.go). It changes the selected node port and route using the daemon's ETag so it can refuse a stale write. It preserves unrelated node routes, Services, foreground routes, and Funnel settings. A port occupied by another route, an unexpected upstream, or any Funnel mapping on the selected port is rejected. It never runs `serve reset` or changes the Tailscale daemon or VPN. The LocalAPI is version dependent; if the daemon does not return an ETag, the helper refuses to write.

The root-only registry records the exact root proxy installed for the Tailscale node. A manual proxy is never claimed automatically. If an administrator edits a managed route, cleanup preserves a changed handler or listener and reports the affected port. Remove a managed route through the app **before** repurposing it by hand; an identical route recreated outside the app is indistinguishable from the recorded entry. If the helper is interrupted after applying a route but before saving ownership, the app treats that route as manual. Inspect it locally before removing it.

## 3. Install the user service from the Mac

1. Launch Voxl Manager. Open **Settings** and verify the hostname, SSH user, display, Xauthority path, executable, and ports.
2. Click **Install / Update User Service…** and confirm. This writes `~/.config/systemd/user/voxl-manager.service`, the launcher, and the resolved configuration under `~/.local/share/voxl-manager/`. It reloads the existing systemd user manager. It does not start Voxl or enable a boot unit.
3. With Mint signed in to X11, click **Start Remote Desktop** in **Overview**. A healthy Voxl process started by hand will be reused. To switch to app control, first shut down the manual Voxl process by the method you used to start it, then click **Start Remote Desktop**.
4. The viewer signs in with the managed password when it can verify the running user service and private proxy over SSH. The launcher honors `VOXL_PASSWORD` from the systemd user environment or creates a random password in `~/.local/share/voxl-manager/password` (mode 0600) on first launch. If the app asks you to sign in, use your existing Voxl password. With the default Voxl username policy, any username is accepted. The viewer keeps the credential only for the current session.

The unit uses the user's ordinary logind session and systemd process supervision. It starts only after confirming that the local X11 session and cookie work, and its launcher monitors the display after startup. The app does not use `xhost`, configure automatic login, or change the server's boot or lingering policy. A Voxl crash is reported with its exit status and journal output. There is no uncontrolled restart loop.

## Verify on your server

1. Start on the original port 8443. Confirm that the app shows a private proxy and Voxl HTTP readiness. In the viewer, sign in, move the pointer, type, scroll, and try Voxl's clipboard controls. If the page loads but the video does not, open the same URL with **Browser** to separate WebKit behavior from server issues.
2. Click **Disconnect Viewer**. Check that the private URL still works in your browser. Connect again without starting a second process.
3. Select another approved port (for example 9443), choose **Apply HTTPS Port**, then **Connect Viewer**. Confirm that your existing unrelated routes and any manually configured 8443 route remain present.
4. Use **Stop Remote Desktop**. Check that the managed unit stops and the app-created route disappears. A manual Voxl process and manual proxy, if present, should remain untouched.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Tailscale CLI unavailable | Open Tailscale from the dashboard and check the profile. Run `/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json` in a regular Mac Terminal. Restricted development sandboxes may not be able to load Tailscale preferences. |
| Tailscale connected; server unreachable | Check that Mint is on the same tailnet, that MagicDNS resolves the selected name, and that tailnet rules allow its traffic. Check `tailscale ping mint-server.tail439626.ts.net`. A ping may be blocked even when SSH works. |
| SSH host key or authentication failure | Verify the key in step 1. If the key changed unexpectedly, investigate before updating known hosts. Check the alias, `ssh-add -l`, and the non-interactive SSH command. |
| Desktop logged out or display unavailable | Sign into the physical Mint X11 desktop and check `loginctl list-sessions`. A Wayland session, SSH-only login, or a different display does not provide this X11 desktop. |
| Xauthority problem | Check the path as the graphical user and rerun the `xdpyinfo` command in step 1. Avoid changing X11 access controls. |
| Voxl process or port conflict | Check `ss -ltnp 'sport = :6901'` and existing Voxl launchers. The app refuses to proxy an unidentified listener. |
| Managed service failed | Use **Diagnostics → Fetch Voxl Logs** or run `journalctl --user -u voxl-manager.service -n 40 --no-pager` on Mint. If the display, executable, host, or HTTP port changed, stop the unit and reinstall from Settings. |
| Serve conflict or upstream mismatch | Run `tailscale serve status` on Mint. Choose a free approved port or have the administrator reconcile the mismatch. A pre-existing public Funnel route cannot be used by the app. |
| HTTPS verification fails | Verify tailnet permissions, MagicDNS, and certificate availability. Check the new route and keep using the old route if the new one does not verify. An added route remains recorded so you can retry or remove it. |
| Embedded viewer fails after the page loads | Try **Reload**, then **Browser**. WebKit behavior for codecs and clipboard varies by version and by Voxl build. A valid certificate and a successful page request do not prove live video playback. |

To uninstall, first stop the managed desktop and confirm that its routes are gone. On Mint, remove the app's user unit and launcher, then run `systemctl --user daemon-reload`. Keep or remove the user password file as you prefer. An administrator can then remove the app's sudoers file (using `visudo` to validate the remaining configuration), helper, and policy/state directories. Leave your other Serve and Tailscale settings in place.
