import AppKit
import Foundation

struct TailscaleService: Sendable {
    let runner: any ProcessRunning
    let candidates: [String]

    init(runner: any ProcessRunning, candidates: [String] = Self.defaultCandidates) {
        self.runner = runner
        self.candidates = candidates
    }

    static let defaultCandidates = [
        "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale", "/usr/local/bin/Tailscale",
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Tailscale.app/Contents/MacOS/Tailscale").path
    ]

    @MainActor static func openApplication() {
        let workspace = NSWorkspace.shared
        let app = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
            .compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }.first
        let standard = URL(fileURLWithPath: "/Applications/Tailscale.app")
        if let url = app ?? (FileManager.default.fileExists(atPath: standard.path) ? standard : nil) {
            workspace.openApplication(at: url, configuration: .init())
        }
    }

    func report(_ config: ServerConfiguration, ssh: SSHService) async throws -> ConnectionReport {
        guard !candidates.isEmpty else {
            return .init(status: .notInstalled, detail: "Install Tailscale on this Mac and sign in to the same tailnet as Mint.",
                         tailscale: "Not installed")
        }
        var cli: String?
        var status: String?
        var lastError = ""
        for binary in candidates {
            try Task.checkCancellation()
            do {
                let result = try await runner.run(binary, ["status", "--json"], input: nil, timeout: 4,
                                                  environment: ["TAILSCALE_BE_CLI": "1"])
                struct Status: Decodable {
                    let backendState: String
                    enum CodingKeys: String, CodingKey { case backendState = "BackendState" }
                }
                if let decoded = try? JSONDecoder().decode(Status.self, from: Data(result.stdout.utf8)) {
                    cli = binary
                    status = decoded.backendState
                    break
                }
                lastError = DiagnosticText.safe(result.stderr.isEmpty ? result.stdout : result.stderr)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error.localizedDescription
            }
        }
        guard let cli, let status else {
            return .init(status: .tailscaleUnavailable,
                         detail: "Open Tailscale and check that its CLI can read the active profile. \(lastError.prefix(350))",
                         tailscale: "CLI unavailable")
        }
        guard status == "Running" else {
            return .init(status: .disconnected, detail: "Open Tailscale, sign in, and connect. Current state: \(status).",
                         tailscale: "Disconnected")
        }

        async let ping = peerResponds(cli: cli, host: config.hostname)
        do {
            let result = try await ssh.probe(config)
            if result.exitCode == 0 {
                _ = await ping
                return .init(status: .ready, detail: "The Linux server accepts non-interactive SSH.",
                             tailscale: "Connected", server: "Reachable", ssh: "Authenticated")
            }
            let detail = DiagnosticText.safe(result.stderr)
            let lower = detail.lowercased()
            let peerResponded = await ping
            // ICMP/TSMP can be blocked independently of SSH. Only diagnose an unreachable node
            // when SSH also reports a routing, DNS, or timeout error.
            let transportFailed = ["resolve hostname", "nodename nor servname", "no route to host",
                                   "network is unreachable", "operation timed out", "connection timed out"]
                .contains(where: { lower.contains($0) })
            let unreachable = !peerResponded && transportFailed
            let advice = lower.contains("host key") ? "Verify the Linux host key in Terminal before trusting it." :
                lower.contains("permission denied") ? "Set up a working SSH key or agent for this destination." :
                unreachable ? "Check MagicDNS, the Linux server’s Tailscale connection, and tailnet access rules." :
                "Check sshd, the SSH config alias, and the tailnet’s SSH access rules."
            return .init(status: unreachable ? .unreachable : .sshUnavailable,
                         detail: "\(advice) \(detail.prefix(500))", tailscale: "Connected",
                         server: unreachable ? "Unreachable" : "Reachable", ssh: "Unavailable")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let responds = await ping
            return .init(status: responds ? .sshUnavailable : .unreachable,
                         detail: error.localizedDescription, tailscale: "Connected",
                         server: responds ? "Reachable" : "Unreachable", ssh: "Unavailable")
        }
    }

    private func peerResponds(cli: String, host: String) async -> Bool {
        let result = try? await runner.run(cli, ["ping", "--c=1", "--timeout=3s", host], input: nil,
                                           timeout: 4, environment: ["TAILSCALE_BE_CLI": "1"])
        return result?.exitCode == 0
    }
}
