import AppKit
import Observation
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case desktop = "Remote Desktop"
    case diagnostics = "Diagnostics"
    case settings = "Settings"
    var id: Self { self }
    var icon: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .desktop: "macwindow"
        case .diagnostics: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }
}

struct DiagnosticEntry: Identifiable {
    let id = UUID()
    let date = Date()
    var message: String
    var isError = false
}

struct SetupPrompt: Identifiable {
    let id = UUID()
    let step: SetupStep
    let detail: String
    let retry: ServerCommand
}

@Observable @MainActor
final class ServerViewModel {
    var selection: Section? = .overview
    var setupPrompt: SetupPrompt?
    private(set) var config = ServerConfiguration.load()
    private(set) var connection = ConnectionReport()
    private(set) var snapshot: ServerSnapshot?
    private(set) var viewerURL: URL?
    private(set) var progress: String?
    private(set) var error: String?
    private(set) var logs: [DiagnosticEntry] = []
    private(set) var lastChecked: Date?
    private var didLaunch = false
    private var operation: Task<Void, Never>?
    private let server = ServerOperations(runner: ProcessRunner())
    private var workflow: RemoteDesktopWorkflow { .init(server: server) }

    var busy: Bool { operation != nil }

    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        guard config.isConfigured else {
            selection = .settings
            return
        }
        if config.connectOnLaunch { perform(.connect) }
        else if config.checkOnLaunch { perform(.refresh) }
    }

    func save(_ draft: ServerConfiguration) throws {
        guard !busy else { throw ManagerError("Wait for the current operation to finish.") }
        let valid = try draft.validated()
        try valid.save()
        let serverChanged = config.hostname != valid.hostname || config.destination != valid.destination ||
            config.sshPort != valid.sshPort || config.httpsPort != valid.httpsPort ||
            config.httpPort != valid.httpPort || config.executable != valid.executable ||
            config.display != valid.display || config.xauthority != valid.xauthority
        config = valid
        if serverChanged {
            viewerURL = nil
            snapshot = nil
            connection = .init()
            lastChecked = nil
            error = nil
            addLog("Server settings changed.")
        }
    }

    func selectPort(_ port: Int) {
        var draft = config
        draft.httpsPort = port
        do { try save(draft); perform(.refresh) }
        catch { self.error = error.localizedDescription }
    }

    func perform(_ command: ServerCommand, allowServiceInstall: Bool = false) {
        guard operation == nil else { return }
        guard config.isConfigured else {
            selection = .settings
            return
        }
        let settings = config
        error = nil
        progress = command.rawValue + "…"
        if command == .refresh || command == .start || command == .connect || command == .browser {
            snapshot = nil
        }
        addLog(command.rawValue)
        operation = Task { [weak self, workflow] in
            guard let self else { return }
            defer { self.operation = nil; self.progress = nil }
            do {
                let url = try await workflow.run(command, config: settings, allowServiceInstall: allowServiceInstall) { [weak self] event in
                    self?.handle(event)
                }
                try Task.checkCancellation()
                if let url {
                    if command == .browser { NSWorkspace.shared.open(url) }
                    else { viewerURL = url; selection = .desktop }
                    addLog("Private HTTPS endpoint verified.")
                } else if command == .stop || command == .disableServe {
                    disconnect()
                }
            } catch is CancellationError {
                snapshot = nil
                addLog("Check cancelled. Refresh to see any changes already made on Linux.")
            } catch let setup as ServerSetupRequired {
                setupPrompt = .init(step: setup.step, detail: setup.detail, retry: command)
                addLog(setup.detail)
            } catch {
                let message = DiagnosticText.safe(error.localizedDescription)
                self.error = message
                addLog(message, isError: true)
            }
        }
    }

    func cancel() { operation?.cancel() }

    func disconnect() {
        guard viewerURL != nil else { return }
        viewerURL = nil
        addLog("Viewer disconnected.")
    }

    func managedPassword(for url: URL) async -> String? {
        guard viewerURL == url, let settings = try? config.validated(), settings.remoteURL == url else { return nil }
        let password = await server.managedPassword(settings)
        return viewerURL == url && !Task.isCancelled ? password : nil
    }

    func guideServeSetup() {
        setupPrompt = .init(step: .serveAdmin, detail: "Install the restricted helper to let the app manage private Voxl HTTPS routes.", retry: .refresh)
    }

    func terminalCommand(for step: SetupStep) throws -> String? {
        let settings = try config.validated()
        switch step {
        case .ssh: return server.ssh.terminalSignIn(settings)
        case .serveAdmin: return try server.ssh.terminalServeInstaller(settings)
        default: return nil
        }
    }

    func openVerifiedURLInBrowser() {
        if let viewerURL { NSWorkspace.shared.open(viewerURL) }
        else { perform(.browser) }
    }

    func clearLogs() { logs.removeAll() }

    private func handle(_ event: WorkflowEvent) {
        switch event {
        case .step(let name): progress = name
        case .connection(let report):
            connection = report
            lastChecked = .now
            if report.status != .ready { snapshot = nil }
            addLog("\(report.status.rawValue): \(report.detail)", isError: report.status != .ready)
        case .snapshot(let snapshot):
            self.snapshot = snapshot
            lastChecked = .now
        case .serve(let serve):
            snapshot?.serve = serve
            addLog("Serve: \(serve.kind.label).")
        case .diagnostic(let text): addLog(text)
        }
    }

    private func addLog(_ message: String, isError: Bool = false) {
        logs.append(.init(message: DiagnosticText.safe(message), isError: isError))
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }
}
