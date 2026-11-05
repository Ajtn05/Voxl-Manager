import Foundation
import XCTest
@testable import Voxl_Manager

@MainActor
final class WorkflowTests: XCTestCase {
    func testFirstStartRequestsApprovalThenInstallsAndStartsTheUserService() async throws {
        let server = Fixture(voxlHealth: .stopped, unit: "missing")
        let workflow = RemoteDesktopWorkflow(server: server)
        do {
            _ = try await workflow.run(.start, config: .init()) { _ in }
            XCTFail("First start must ask before installing the Linux unit")
        } catch let setup as ServerSetupRequired {
            XCTAssertEqual(setup.step, .userService)
        }
        let beforeApproval = await server.calls
        XCTAssertEqual(beforeApproval, ["connection", "inspect"])

        let url = try await workflow.run(.start, config: .init(), allowServiceInstall: true) { _ in }
        XCTAssertNotNil(url)
        let calls = await server.calls
        XCTAssertEqual(Array(calls.dropFirst(beforeApproval.count).prefix(4)),
                       ["connection", "inspect", "voxl:install", "voxl:start"])
    }

    func testMissingServeHelperRequestsAdministratorWithoutStartingVoxl() async throws {
        let server = Fixture(hasHelper: false)
        do {
            _ = try await RemoteDesktopWorkflow(server: server).run(.start, config: .init()) { _ in }
            XCTFail("The app must wait for Linux administrator setup")
        } catch let setup as ServerSetupRequired {
            XCTAssertEqual(setup.step, .serveAdmin)
        }
        let calls = await server.calls
        XCTAssertEqual(calls, ["connection", "inspect"])
    }

    func testStartVerifiesReplacementBeforePruningOldPort() async throws {
        let server = Fixture()
        let settings = ServerConfiguration()
        let url = try await RemoteDesktopWorkflow(server: server).run(.start, config: settings) { _ in }
        XCTAssertEqual(url, settings.remoteURL)
        let calls = await server.calls
        XCTAssertEqual(calls, ["connection", "inspect", "voxl:start", "serve:serve-status",
                               "serve:enable", "verify", "serve:prune", "inspect"])
    }

    func testHTTPSFailurePreservesOldRoute() async {
        let server = Fixture(verifyFails: true)
        do {
            _ = try await RemoteDesktopWorkflow(server: server).run(.start, config: .init()) { _ in }
            XCTFail("Start must fail when HTTPS is not verified")
        } catch {
            XCTAssertEqual(error.localizedDescription, "TLS failed")
        }
        let calls = await server.calls
        XCTAssertEqual(calls.last, "verify")
        XCTAssertFalse(calls.contains("serve:prune"))
    }

    func testPrivateExistingEndpointConnectDoesNotMutateServer() async throws {
        let server = Fixture(kind: .matched)
        let url = try await RemoteDesktopWorkflow(server: server).run(.connect, config: .init()) { _ in }
        XCTAssertNotNil(url)
        let calls = await server.calls
        XCTAssertEqual(calls, ["connection", "inspect", "verify"])
    }

    func testStartStopsAtDisconnectedTailnetX11OrFunnel() async {
        let cases: [(Fixture, [String])] = [
            (Fixture(connection: .disconnected), ["connection"]),
            (Fixture(x11: .credentials), ["connection", "inspect"]),
            (Fixture(kind: .publicExposure), ["connection", "inspect"])
        ]
        for (server, expected) in cases {
            do {
                _ = try await RemoteDesktopWorkflow(server: server).run(.start, config: .init()) { _ in }
                XCTFail("Start should refuse to mutate the server")
            } catch { }
            let calls = await server.calls
            XCTAssertEqual(calls, expected)
        }
    }

    func testStopAttemptsProxyCleanupAfterServiceError() async {
        let server = Fixture(stopFails: true)
        do {
            _ = try await RemoteDesktopWorkflow(server: server).run(.stop, config: .init()) { _ in }
            XCTFail("Stop should report partial failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Service stop failed")
        }
        let calls = await server.calls
        XCTAssertEqual(calls, ["connection", "voxl:stop", "serve:disable", "inspect"])
    }
}

private actor Fixture: ServerOperating {
    var calls: [String] = []
    let connectionStatus: ConnectionStatus
    let x11: X11State
    let kind: ServeKind
    let verifyFails: Bool
    let stopFails: Bool
    let voxlHealth: VoxlHealth
    let unit: String
    let hasHelper: Bool

    init(connection: ConnectionStatus = .ready, x11: X11State = .ready, kind: ServeKind = .disabled,
         verifyFails: Bool = false, stopFails: Bool = false, voxlHealth: VoxlHealth = .ready,
         unit: String = "active", hasHelper: Bool = true) {
        self.connectionStatus = connection
        self.x11 = x11
        self.kind = kind
        self.verifyFails = verifyFails
        self.stopFails = stopFails
        self.voxlHealth = voxlHealth
        self.unit = unit
        self.hasHelper = hasHelper
    }

    func connection(_ config: ServerConfiguration) async throws -> ConnectionReport {
        calls.append("connection")
        return .init(status: connectionStatus)
    }

    func inspect(_ config: ServerConfiguration) async throws -> ServerSnapshot {
        calls.append("inspect")
        return .init(voxl: voxlHealth, x11: x11, x11Detail: "Check Xauthority.", unit: unit,
                     executable: "/usr/local/bin/voxl",
                     serve: .init(kind: kind, ownedPorts: [9443], allowedPorts: hasHelper ? [8443, 9443] : nil))
    }

    func voxl(_ action: VoxlAction, _ config: ServerConfiguration) async throws -> String {
        calls.append("voxl:\(action.rawValue)")
        if stopFails && action == .stop { throw ManagerError("Service stop failed") }
        return "OK"
    }

    func serve(_ action: ServeAction, _ config: ServerConfiguration) async throws -> ServeStatus {
        calls.append("serve:\(action.rawValue)")
        switch action {
        case .inspect: return .init(kind: kind)
        case .enable: return .init(kind: .matched, ownedPorts: [8443, 9443])
        case .prune: return .init(kind: .matched, ownedPorts: [8443])
        case .disable: return .init(kind: .disabled, ownedPorts: [])
        }
    }

    func verify(_ url: URL) async throws {
        calls.append("verify")
        if verifyFails { throw ManagerError("TLS failed") }
    }
}
