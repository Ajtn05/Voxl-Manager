import SwiftUI

struct DashboardView: View {
    let model: ServerViewModel
    @State private var confirmsStop = false
    @State private var confirmsDisable = false

    private var serverName: String { model.config.hostname.split(separator: ".").first.map(String.init) ?? "Server" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = model.error {
                    notice("Action needs attention", error.components(separatedBy: "\n").first ?? error,
                           icon: "exclamationmark.triangle.fill", tint: .orange)
                } else if model.connection.status != .ready && model.connection.status != .unchecked {
                    notice(model.connection.status.rawValue, model.connection.detail,
                           icon: "network.slash", tint: .orange)
                }
                dashboardCard("Connection", icon: "point.3.connected.trianglepath.dotted") {
                    row("Tailscale", model.connection.tailscale, positive: model.connection.tailscale == "Connected")
                    row("Linux server", model.connection.server, positive: model.connection.server == "Reachable")
                    row("SSH", model.connection.ssh, positive: model.connection.ssh == "Authenticated")
                    row("Remote URL", model.config.remoteURL?.absoluteString ?? "—", monospace: true)
                }
                HStack(alignment: .top, spacing: 14) {
                    dashboardCard("Voxl", icon: "display") {
                        row("Process", model.snapshot?.voxl.label ?? "—", positive: model.snapshot?.voxl == .ready)
                        row("X11 \(model.config.display)", model.snapshot?.x11.label ?? "—", positive: model.snapshot?.x11 == .ready)
                        row("User service", model.snapshot?.serviceLabel ?? "—", positive: model.snapshot?.unit == "active")
                        row("Local HTTP port", String(model.config.httpPort), monospace: true)
                    }
                    dashboardCard("Tailscale Serve", icon: "lock.shield") {
                        row("Proxy", model.snapshot?.serve.kind.label ?? "—", positive: model.snapshot?.serve.kind == .matched)
                        HStack(alignment: .firstTextBaseline) {
                            Text("HTTPS port").foregroundStyle(.secondary)
                            Spacer(minLength: 10)
                            Menu(String(model.config.httpsPort)) {
                                ForEach(model.snapshot?.serve.allowedPorts ?? [8443, 9443, 10443], id: \.self) { port in
                                    Button(String(port)) { model.selectPort(port) }
                                }
                                Divider()
                                Button("Edit in Settings…") { model.selection = .settings }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(!model.config.isConfigured || model.busy)
                            .accessibilityLabel("HTTPS port")
                        }
                        row("Upstream", model.snapshot?.serve.upstream ?? "—", monospace: true)
                        row("Ownership", ownership)
                    }
                }
                if let detail = model.snapshot?.serve.detail {
                    HStack {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if model.snapshot?.serve.allowedPorts == nil {
                            Button("Set Up Serve Management…", action: model.guideServeSetup)
                                .disabled(model.busy)
                        }
                    }
                }
                if let detail = model.snapshot?.x11Detail, model.snapshot?.x11 != .ready {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                actions
            }
            .frame(maxWidth: 980)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Stop the remote desktop?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop Remote Desktop", role: .destructive) { model.perform(.stop) }
        } message: {
            Text("This stops the managed Linux service and removes Serve routes created by Voxl Manager. Other viewers using those routes will disconnect.")
        }
        .confirmationDialog("Disable managed Serve routes?", isPresented: $confirmsDisable, titleVisibility: .visible) {
            Button("Disable Managed Serve", role: .destructive) { model.perform(.disableServe) }
        } message: {
            Text("This removes Serve routes created by Voxl Manager and leaves the Linux Voxl process running.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 29, weight: .medium))
                    .frame(width: 62, height: 62)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(serverName).font(.system(size: 30, weight: .semibold))
                    Text(model.config.hostname).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if let date = model.lastChecked {
                    Text(date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("Last checked \(date.formatted(date: .omitted, time: .shortened))")
                }
            }
            HStack(spacing: 10) {
                if model.config.isConfigured {
                    Button { model.perform(.start) } label: {
                        Label("Start Remote Desktop", systemImage: "play.fill")
                    }.buttonStyle(.borderedProminent).disabled(model.busy)
                    if model.viewerURL != nil {
                        Button("Disconnect Viewer", action: model.disconnect)
                    } else {
                        Button("Connect Viewer") { model.perform(.connect) }.disabled(model.busy)
                    }
                } else {
                    Button("Configure Server") { model.selection = .settings }.buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
    }

    private var ownership: String {
        guard let serve = model.snapshot?.serve, serve.kind == .matched else { return "—" }
        guard let ports = serve.ownedPorts else { return "Ownership unverified" }
        return ports.contains(model.config.httpsPort) ? "Managed" : "Existing · reused"
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { model.openVerifiedURLInBrowser() } label: { Label("Open in Browser", systemImage: "safari") }
            Button { model.selection = .diagnostics } label: { Label("View Logs", systemImage: "text.alignleft") }
            if [.disconnected, .tailscaleUnavailable].contains(model.connection.status) {
                Button("Open Tailscale", action: TailscaleService.openApplication)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Refresh Status") { model.perform(.refresh) }
                Button("Restart Voxl") { model.perform(.restart) }
                Button("Apply HTTPS Port") { model.perform(.applyServe) }
                Button("Disable Managed Serve…") { confirmsDisable = true }
                Divider()
                Button("Stop Remote Desktop", role: .destructive) { confirmsStop = true }
            } label: { Label("More Actions", systemImage: "ellipsis.circle") }
            .fixedSize()
        }
        .disabled(model.busy)
    }

    private func dashboardCard<Content: View>(_ title: String, icon: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            Divider().padding(.bottom, 2)
            content()
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
    }

    private func row(_ title: String, _ value: String, positive: Bool = false, monospace: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            if positive { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            Text(value).font(monospace ? .callout.monospaced() : .callout.weight(.medium))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func notice(_ title: String, _ detail: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.bold())
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(13)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}
