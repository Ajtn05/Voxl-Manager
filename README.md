# Voxl Manager

Voxl Manager is a native SwiftUI app for a single Linux X11 desktop on your tailnet. It uses macOS OpenSSH for Linux commands, a systemd user service for Voxl, and WebKit for the viewer. No bundled Voxl binary or additional macOS runtime is required.

The default server is `aldrinnellas@mint-server.tail439626.ts.net`. Voxl uses display `:0`, `/home/aldrinnellas/.Xauthority`, and local HTTP port `6901`. The default viewer address is **https://mint-server.tail439626.ts.net:8443/**.

## Build and run

1. Open `VoxlManager.xcodeproj` in Xcode. Select the **VoxlManager** scheme and **My Mac**.
2. Press **⌘R**. The project targets macOS 14 or later and uses local ad hoc signing. Use your own signing identity for distribution.
3. Connect both machines to Tailscale and choose **Start Remote Desktop**. The app guides you through SSH trust, installing the user service, and approving the Serve helper when needed. The [Mint setup guide](docs/setup.md) also has manual setup and troubleshooting steps.

The checked-in Xcode project works without XcodeGen. If you add or remove files or edit `project.yml`, run `xcodegen generate` to refresh it. The app runs without administrator privileges. It is not App Sandbox restricted so it can use your OpenSSH configuration, host keys, and agent.

```sh
xcodebuild -project VoxlManager.xcodeproj -scheme VoxlManager \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build
open 'DerivedData/Build/Products/Debug/Voxl Manager.app'
```

## Controls

| Control | Effect |
| --- | --- |
| **Start Remote Desktop** | Checks Tailscale, SSH, X11, and the selected Serve port; starts or reuses Voxl; verifies HTTP and the private HTTPS endpoint; then opens the viewer. |
| **Connect Viewer** | Verifies an already running desktop and private proxy before opening WebKit. |
| **Disconnect Viewer** | Closes the embedded connection. The Linux service and proxy continue. |
| **Apply HTTPS Port** | Applies the selected port for an already running Voxl instance. Older app-owned routes are removed only after the replacement passes HTTPS verification. |
| **Disable Managed Serve** | Removes app-owned routes and leaves Voxl running. |
| **Stop Remote Desktop** | Stops the app's systemd user unit and removes its Serve routes. Reports a partial failure if only one step succeeds. |
| **Restart Voxl** | Restarts the managed user unit. An independently launched Voxl process is never killed by the app. |
| **Diagnostics** | Shows expandable connection and command details, plus a button to fetch the Linux user journal. |

The app reuses an existing, private root proxy with the correct loopback upstream, including the original port 8443 configuration. It does not take ownership of it. If you switch to a managed port, the old manual route remains until you choose to retire it yourself. The port picker is local configuration; choose **Apply HTTPS Port** or **Start Remote Desktop** to change the server.

The WebKit viewer uses Voxl's own page and WebSocket. It signs in automatically when it can verify the app-managed Linux service and its password over SSH. Other Voxl instances show a manual sign-in form. Use the page's clipboard controls where WebKit supports them, or **Browser** if the embedded viewer cannot decode or control the desktop.

**Full Screen** fills the current display and gives pointer and keyboard input to Voxl. Press **Control + Option + Esc** to return to the Mac. Switching apps also releases capture. Voxl scales the Linux desktop to the display, so different aspect ratios can stretch the picture.

## Persistence

| Event | What happens |
| --- | --- |
| SSH command ends, viewer disconnects, or Mac app closes | The user service and background Serve route stay active while the Linux graphical session is available. |
| Linux desktop locks | If X11 remains accessible, Voxl continues according to the desktop's lock-screen behavior. |
| Linux desktop logs out | The launcher stops its Voxl child when X11 or the matching desktop session disappears. The Serve route can remain configured and return an upstream error. Log in to X11 and click **Start Remote Desktop** again. |
| Linux reboots | The service files and settings persist; the app has not enabled Voxl at boot or enabled lingering. Tailscale normally restores background routes from its daemon state. Sign in to the X11 desktop before starting Voxl. |
| Mac loses its network | Linux keeps running. The viewer retries transient navigation and WebSocket interruptions with backoff. |

See [setup and troubleshooting](docs/setup.md) for the exact Linux commands, service ownership rules, and how to test your Mint installation.

## Tests

```sh
xcodebuild -project VoxlManager.xcodeproj -scheme VoxlManager \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData test
python3 -m unittest discover -s linux/tests -v
```

The Xcode suite exercises connectivity classification, SSH command construction, real subprocess input/output and cancellation, and the ordered startup and stop workflows with a simulated server. The Python suite exercises Serve port conflicts, ownership, preservation of unrelated routes, and conditional updates. Neither suite needs access to your Linux server. Follow the [live checklist](docs/setup.md#verify-on-your-server) to validate the stream, input, and clipboard on your exact versions.

The project separates SwiftUI and its view model from the connection workflow, OpenSSH, process execution, and Linux service orchestration. The user unit and the SSH Python driver are [bundled resources](VoxlManager/Resources); the administrator helper and example policy live in [linux](linux).
