import Foundation

enum ServerCommand: String, Sendable {
    case refresh = "Refresh status"
    case connect = "Connect viewer"
    case browser = "Open in browser"
    case start = "Start remote desktop"
    case stop = "Stop remote desktop"
    case restart = "Restart Voxl"
    case applyServe = "Apply HTTPS port"
    case disableServe = "Disable managed Serve"
    case install = "Install user service"
    case logs = "Fetch service logs"
}

enum WorkflowEvent: Sendable {
    case step(String)
    case connection(ConnectionReport)
    case snapshot(ServerSnapshot)
    case serve(ServeStatus)
    case diagnostic(String)
}

enum SetupStep: Sendable {
    case ssh, desktop, executable, userService, serveAdmin, servePolicy
}

struct ServerSetupRequired: Error, Sendable {
    let step: SetupStep
    let detail: String
}

struct RemoteDesktopWorkflow: Sendable {
    let server: any ServerOperating

    func run(_ command: ServerCommand, config: ServerConfiguration, allowServiceInstall: Bool = false,
             emit: @MainActor @Sendable (WorkflowEvent) -> Void) async throws -> URL? {
        let settings = try config.validated()
        await emit(.step("Checking Tailscale and SSH…"))
        let report = try await server.connection(settings)
        await emit(.connection(report))
        guard report.status == .ready else {
            if command == .refresh { return nil }
            if report.status == .sshUnavailable {
                throw ServerSetupRequired(step: .ssh, detail: report.detail)
            }
            throw ManagerError(report.detail)
        }
        if command == .logs || command == .install {
            await emit(.step(command == .logs ? "Reading the user service journal…" : "Installing the systemd user service…"))
            try await emit(.diagnostic(server.voxl(command == .logs ? .logs : .install, settings)))
            if command == .install { try await emit(.snapshot(server.inspect(settings))) }
            return nil
        }
        if command == .disableServe {
            await emit(.step("Removing app-managed Serve routes…"))
            _ = try await server.serve(.disable, settings)
            await emit(.diagnostic("App-managed Serve routes are disabled."))
            try await emit(.snapshot(server.inspect(settings)))
            return nil
        }
        if command == .stop {
            var failures: [String] = []
            await emit(.step("Stopping the managed Voxl service…"))
            do { try await emit(.diagnostic(server.voxl(.stop, settings))) }
            catch is CancellationError { throw CancellationError() }
            catch { failures.append(error.localizedDescription) }
            await emit(.step("Removing app-managed Serve routes…"))
            do {
                _ = try await server.serve(.disable, settings)
                await emit(.diagnostic("App-managed Serve routes are disabled."))
            }
            catch is CancellationError { throw CancellationError() }
            catch { failures.append(error.localizedDescription) }
            if let snapshot = try? await server.inspect(settings) { await emit(.snapshot(snapshot)) }
            if !failures.isEmpty { throw ManagerError(failures.joined(separator: "\n\n")) }
            return nil
        }

        await emit(.step("Inspecting X11, Voxl, and Serve…"))
        let snapshot = try await server.inspect(settings)
        await emit(.snapshot(snapshot))
        if command == .refresh { return nil }
        if command == .restart {
            await emit(.step("Restarting the managed Voxl service…"))
            try await emit(.diagnostic(server.voxl(.restart, settings)))
            try await emit(.snapshot(server.inspect(settings)))
            return nil
        }
        var selected = snapshot.serve
        let appliesServe = command == .start || command == .applyServe
        if appliesServe {
            if command == .start, snapshot.x11 != .ready {
                throw ServerSetupRequired(step: .desktop, detail: snapshot.x11Detail)
            }
            if command == .applyServe, snapshot.voxl != .ready {
                throw ManagerError("Voxl is not ready on the selected local HTTP port. Use Start Remote Desktop.")
            }
            if command == .start, snapshot.voxl == .stopped, snapshot.unit == "unavailable" {
                throw ServerSetupRequired(step: .desktop,
                    detail: "SSH couldn’t reach your Linux systemd user manager. Check that you are signed in to the graphical session under the configured SSH account.")
            }
            if command == .start, snapshot.unit == "missing", snapshot.voxl == .stopped {
                guard let executable = snapshot.executable else {
                    throw ServerSetupRequired(step: .executable, detail: "The app couldn’t find the Voxl executable on Linux.")
                }
                guard allowServiceInstall else {
                    throw ServerSetupRequired(step: .userService,
                        detail: "Voxl Manager found \(executable). It can install a systemd user service for your Linux account and start the desktop.")
                }
                await emit(.step("Installing the Voxl user service…"))
                try await emit(.diagnostic(server.voxl(.install, settings)))
            }
            if selected.kind == .policyMismatch {
                throw ServerSetupRequired(step: .servePolicy, detail: selected.detail ?? "The Linux Serve policy differs from the app settings.")
            }
            if selected.kind != .disabled { try selected.requireMatch() }
            if selected.kind == .disabled {
                guard let allowed = selected.allowedPorts else {
                    throw ServerSetupRequired(step: .serveAdmin, detail: "An administrator on Linux must approve the Serve helper before the app can create a new private HTTPS route.")
                }
                guard allowed.contains(settings.httpsPort) else {
                    throw ServerSetupRequired(step: .servePolicy,
                        detail: "The administrator allows HTTPS ports \(allowed.map(String.init).joined(separator: ", ")).")
                }
            }
            if command == .start {
                await emit(.step("Starting or reusing Voxl and checking HTTP…"))
                try await emit(.diagnostic(server.voxl(.start, settings)))
            }
            await emit(.step("Checking and applying the private HTTPS proxy…"))
            selected = try await server.serve(.inspect, settings)
            if selected.kind == .disabled { selected = try await server.serve(.enable, settings) }
            await emit(.serve(selected))
        } else if snapshot.voxl != .ready {
            throw ManagerError("Voxl is not ready on HTTP port \(settings.httpPort): \(snapshot.voxl.label). Use Start Remote Desktop.")
        }
        try selected.requireMatch()
        guard let url = settings.remoteURL else { throw ManagerError("The remote URL is invalid.") }
        await emit(.step("Verifying HTTPS from this Mac…"))
        try await server.verify(url)
        if appliesServe, selected.ownedPorts?.contains(where: { $0 != settings.httpsPort }) == true {
            await emit(.step("Removing older app-managed Serve routes…"))
            try await emit(.serve(server.serve(.prune, settings)))
        }
        if appliesServe, let snapshot = try? await server.inspect(settings) {
            await emit(.snapshot(snapshot))
        }
        if command == .applyServe {
            await emit(.diagnostic("Verified the private HTTPS proxy."))
            return nil
        }
        return url
    }
}
