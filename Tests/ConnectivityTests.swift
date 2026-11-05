import Foundation
import SwiftUI
import XCTest
@testable import Voxl_Manager

@MainActor
final class ConnectivityTests: XCTestCase {
    func testWebKitCanDispatchTheViewerAuthenticationChallenge() throws {
        let url = try XCTUnwrap(ServerConfiguration().remoteURL)
        let coordinator = EmbeddedDesktop.Coordinator(url: url, state: .constant(.loading), reload: 0)
        let callback = NSSelectorFromString("webView:didReceiveAuthenticationChallenge:completionHandler:")
        XCTAssertTrue(coordinator.responds(to: callback))
    }

    func testConnectivityStates() async throws {
        let cases: [(String?, Bool, String?, ConnectionStatus)] = [
            (nil, false, nil, .notInstalled),
            ("NeedsLogin", false, nil, .disconnected),
            ("Running", false, "ssh: Could not resolve hostname", .unreachable),
            ("Running", true, "Host key verification failed.", .sshUnavailable),
            ("Running", false, "Permission denied (publickey).", .sshUnavailable),
            ("Running", false, nil, .ready),
        ]
        for (status, ping, sshFailure, expected) in cases {
            let process = MockCLI(status: status, ping: ping, sshFailure: sshFailure)
            let service = TailscaleService(runner: process, candidates: status == nil ? [] : ["/tailscale"])
            let report = try await service.report(.init(), ssh: .init(runner: process))
            XCTAssertEqual(report.status, expected)
        }
    }

    func testSSHSettingsRejectOptionInjectionAndPreserveHostVerification() throws {
        var configuration = ServerConfiguration()
        configuration.sshAlias = "-oProxyCommand=oops"
        XCTAssertThrowsError(try configuration.validated())
        configuration.sshAlias = "mint"
        configuration.sshPort = "2222"
        let ssh = SSHService(runner: ProcessRunner())
        let arguments = ssh.arguments(try configuration.validated(), remote: ["/bin/printf", "a'b;\"$HOME\""])
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments.contains("2222"))
        XCTAssertEqual(Array(arguments.suffix(3)), ["--", "aldrinnellas@mint", #"'/bin/printf' 'a'\''b;"$HOME"'"#])
    }

    func testProcessDrainsBothPipesAndSendsLargeInput() async throws {
        let input = Data(repeating: 65, count: 200_000)
        let output = try await ProcessRunner().run("/bin/sh", ["-c", "/bin/cat; /usr/bin/printf 'diagnostic' >&2; exit 7"],
                                                   input: input, timeout: 5, environment: [:])
        XCTAssertEqual(Data(output.stdout.utf8), input)
        XCTAssertEqual(output.stderr, "diagnostic")
        XCTAssertEqual(output.exitCode, 7)
    }

    func testProcessTimeoutAndCancellation() async throws {
        let runner = ProcessRunner()
        do {
            _ = try await runner.run("/bin/sleep", ["8"], timeout: 0.1)
            XCTFail("The process should time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        let task = Task { try await runner.run("/bin/sleep", ["8"], timeout: 5) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("The process should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private struct MockCLI: ProcessRunning {
    let status: String?
    let ping: Bool
    let sshFailure: String?

    func run(_ executable: String, _ arguments: [String], input: Data?, timeout: TimeInterval,
             environment: [String: String]) async throws -> ProcessResult {
        if executable == "/usr/bin/ssh" {
            return .init(exitCode: sshFailure == nil ? 0 : 255, stdout: "", stderr: sshFailure ?? "")
        }
        if arguments.first == "status" {
            return .init(exitCode: 0, stdout: "{\"BackendState\":\"\(status ?? "")\"}", stderr: "")
        }
        return .init(exitCode: ping ? 0 : 1, stdout: "", stderr: "")
    }
}
