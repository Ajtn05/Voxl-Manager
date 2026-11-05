import Foundation

enum ConnectionStatus: String, Sendable {
    case unchecked = "Not checked"
    case notInstalled = "Tailscale not installed"
    case tailscaleUnavailable = "Tailscale CLI unavailable"
    case disconnected = "Tailscale disconnected"
    case unreachable = "Server unreachable"
    case sshUnavailable = "SSH unavailable"
    case ready = "SSH ready"
}

struct ConnectionReport: Sendable {
    var status: ConnectionStatus = .unchecked
    var detail = "Refresh to check the server."
    var tailscale = "Not checked"
    var server = "Not checked"
    var ssh = "Not checked"
}

enum X11State: String, Codable, Sendable {
    case ready, loggedOut, credentials, unavailable, unknown
    var label: String {
        switch self {
        case .ready: "Accessible"
        case .loggedOut: "Desktop logged out"
        case .credentials: "Xauthority problem"
        case .unavailable: "Display unavailable"
        case .unknown: "Could not check"
        }
    }
}

enum VoxlHealth: String, Codable, Sendable {
    case ready, stopped, starting, conflict, rejected, unhealthy
    var label: String {
        switch self {
        case .ready: "Running · HTTP ready"
        case .stopped: "Stopped"
        case .starting: "Running · port not listening"
        case .conflict: "HTTP port conflict"
        case .rejected: "Voxl rejected the host"
        case .unhealthy: "Running · HTTP unhealthy"
        }
    }
}

enum ServeKind: String, Codable, Sendable {
    case matched, disabled, conflict, mismatch, unknown, policyMismatch
    case publicExposure = "public"

    var label: String {
        switch self {
        case .matched: "Enabled · private"
        case .disabled: "Disabled"
        case .conflict: "HTTPS port conflict"
        case .mismatch: "Upstream mismatch"
        case .publicExposure: "Funnel detected"
        case .unknown: "Could not check"
        case .policyMismatch: "Administrator policy mismatch"
        }
    }
}

struct ServeStatus: Codable, Sendable {
    var kind: ServeKind
    var upstream: String? = nil
    var detail: String? = nil
    var ownedPorts: [Int]? = nil
    var allowedPorts: [Int]? = nil

    func requireMatch() throws {
        switch kind {
        case .matched: return
        case .disabled: throw ManagerError("No private Voxl proxy exists on the selected HTTPS port. Use Start Remote Desktop.")
        case .conflict: throw ManagerError("The selected HTTPS port is already configured for another route. Select a free port.")
        case .mismatch: throw ManagerError("The existing proxy targets \(upstream ?? "a different upstream"). Check the Voxl HTTP port or select another HTTPS port.")
        case .publicExposure: throw ManagerError("Funnel is configured on this port. Select a private Serve port or have the administrator review the public configuration.")
        case .unknown, .policyMismatch: throw ManagerError(detail ?? "Could not verify the Serve configuration.")
        }
    }
}

struct ServerSnapshot: Codable, Sendable {
    var voxl: VoxlHealth
    var x11: X11State
    var x11Detail: String
    var unit: String
    var executable: String?
    var serve: ServeStatus

    var serviceLabel: String {
        switch unit {
        case "active": "Active"
        case "inactive": "Installed · inactive"
        case "failed": "Failed · see diagnostics"
        case "missing": "Not installed"
        case "unavailable": "User manager unavailable"
        case "foreign": "Unmanaged unit"
        default: unit.capitalized
        }
    }
}
