import Foundation

protocol ServerOperating: Sendable {
    func connection(_ config: ServerConfiguration) async throws -> ConnectionReport
    func inspect(_ config: ServerConfiguration) async throws -> ServerSnapshot
    func voxl(_ action: VoxlAction, _ config: ServerConfiguration) async throws -> String
    func serve(_ action: ServeAction, _ config: ServerConfiguration) async throws -> ServeStatus
    func verify(_ url: URL) async throws
}

enum VoxlAction: String, Sendable { case start, restart, stop, install, logs }
enum ServeAction: String, Sendable { case inspect = "serve-status", enable, prune, disable }

struct ServerOperations: ServerOperating {
    let runner: any ProcessRunning
    var ssh: SSHService { SSHService(runner: runner) }

    func managedPassword(_ config: ServerConfiguration) async -> String? {
        struct Login: Decodable, Sendable { let password: String? }
        let login = try? await ssh.script("managed-login", config: config, timeout: 12, as: Login.self)
        return login?.password
    }

    func connection(_ config: ServerConfiguration) async throws -> ConnectionReport {
        let paths = TailscaleService.defaultCandidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
        return try await TailscaleService(runner: runner, candidates: paths).report(config, ssh: ssh)
    }

    func inspect(_ config: ServerConfiguration) async throws -> ServerSnapshot {
        try await ssh.script("inspect", config: config, timeout: 34, as: ServerSnapshot.self)
    }

    func voxl(_ action: VoxlAction, _ config: ServerConfiguration) async throws -> String {
        let timeout: TimeInterval = switch action {
        case .start, .restart: 40
        case .install: 22
        case .stop: 18
        case .logs: 10
        }
        return try await ssh.script(action.rawValue, config: config, timeout: timeout, as: RemoteMessage.self).message
    }

    func serve(_ action: ServeAction, _ config: ServerConfiguration) async throws -> ServeStatus {
        try await ssh.script(action.rawValue, config: config, timeout: 30, as: ServeStatus.self)
    }

    func verify(_ url: URL) async throws {
        // Do not follow redirects, send credentials, load ~/.curlrc, or inherit HTTP proxies.
        // Allow a first-time Tailscale certificate to take a little longer to provision.
        var detail = ""
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(attempt)) }
            let result = try await runner.run("/usr/bin/curl",
                ["-q", "--silent", "--show-error", "--noproxy", "*", "--proto", "=https",
                 "--connect-timeout", "5", "--max-time", "8", "--output", "/dev/null",
                 "--dump-header", "-", "--write-out", "\n%{http_code}", "--", url.absoluteString], timeout: 10)
            let code = Int(result.stdout.split(whereSeparator: \.isNewline).last ?? "") ?? 0
            if result.exitCode == 0, (200...299).contains(code) ||
                (code == 401 && result.stdout.lowercased().contains("www-authenticate: basic")) { return }
            detail = result.exitCode == 0 ? "The endpoint returned HTTP \(code)." : DiagnosticText.safe(result.stderr)
            if [6, 51, 60].contains(result.exitCode) || (400...499).contains(code) { break }
        }
        throw ManagerError("Could not verify the private HTTPS endpoint. Check MagicDNS, tailnet access rules, and the server’s HTTPS certificate. \(detail)")
    }
}
