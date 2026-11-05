import Foundation

struct ServerConfiguration: Codable, Equatable, Sendable {
    var hostname = ""
    var username = ""
    var sshPort = "" // Empty inherits OpenSSH configuration, including port 22 by default.
    var sshAlias = ""
    var executable = ""
    var display = ":0"
    var xauthority = ""
    var httpPort = 6901
    var httpsPort = 8443
    var checkOnLaunch = true
    var connectOnLaunch = false
    var menuBar = false

    static let storageKey = "serverConfiguration"

    var isConfigured: Bool { !hostname.isEmpty && !username.isEmpty }

    func validated() throws -> Self {
        var value = self
        value.hostname = hostname.trimmingCharacters(in: .whitespaces).lowercased()
        value.username = username.trimmingCharacters(in: .whitespaces)
        value.sshAlias = sshAlias.trimmingCharacters(in: .whitespaces)
        value.sshPort = sshPort.trimmingCharacters(in: .whitespaces)
        let labels = value.hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, value.hostname.hasSuffix(".ts.net"), value.hostname.count <= 253,
              labels.allSatisfy({ $0.wholeMatch(of: /[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?/) != nil })
        else { throw ManagerError("Enter the server’s full Tailscale MagicDNS name ending in .ts.net.") }
        guard value.username.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_.-]{0,63}/) != nil else {
            throw ManagerError("Enter a valid Linux SSH username.")
        }
        guard value.sshAlias.isEmpty || value.sshAlias.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,252}/) != nil else {
            throw ManagerError("Enter an SSH config alias without spaces or special characters.")
        }
        if !value.sshPort.isEmpty {
            guard value.sshPort.wholeMatch(of: /[0-9]{1,5}/) != nil,
                  let port = Int(value.sshPort), (1...65535).contains(port) else {
                throw ManagerError("SSH port must be between 1 and 65535.")
            }
            value.sshPort = String(port)
        }
        guard (1...65535).contains(httpPort), (1...65535).contains(httpsPort), httpPort != httpsPort else {
            throw ManagerError("Use different HTTP and HTTPS ports between 1 and 65535.")
        }
        guard display.wholeMatch(of: /:[0-9]{1,5}(?:\.[0-9]{1,5})?/) != nil else {
            throw ManagerError("Enter a local X11 display such as :0.")
        }
        for path in [xauthority, executable] where !path.isEmpty {
            guard path.hasPrefix("/"), path.count <= 4096,
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ManagerError("Enter absolute Linux paths for the executable and Xauthority.")
            }
        }
        return value
    }

    var destination: String { "\(username)@\(sshAlias.isEmpty ? hostname : sshAlias)" }

    var remoteURL: URL? {
        guard isConfigured else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = hostname
        components.port = httpsPort == 443 ? nil : httpsPort
        components.path = "/"
        return components.url
    }

    func loadPayload() throws -> [String: Any] {
        ["hostname": hostname, "display": display, "xauthority": xauthority,
         "executable": executable, "httpPort": httpPort, "httpsPort": httpsPort]
    }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return settings
    }

    func save() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}

struct ManagerError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
