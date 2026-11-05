import Foundation

struct SSHService: Sendable {
    let runner: any ProcessRunning

    func arguments(_ config: ServerConfiguration, remote: [String]) -> [String] {
        var result = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                      "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
                      "-o", "ServerAliveInterval=4", "-o", "ServerAliveCountMax=2",
                      "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
                      "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "RemoteCommand=none",
                      "-o", "ForwardAgent=no", "-o", "ForwardX11=no"]
        if !config.sshPort.isEmpty { result += ["-p", config.sshPort] }
        result += ["--", config.destination, remote.map(Self.shellWord).joined(separator: " ")]
        return result
    }

    static func shellWord(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func probe(_ config: ServerConfiguration) async throws -> ProcessResult {
        try await runner.run("/usr/bin/ssh", arguments(config, remote: ["/usr/bin/true"]), timeout: 9)
    }

    func terminalSignIn(_ config: ServerConfiguration) -> String {
        var args = ["/usr/bin/ssh", "-o", "StrictHostKeyChecking=ask", "-o", "BatchMode=no",
                    "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no"]
        if !config.sshPort.isEmpty { args += ["-p", config.sshPort] }
        args += ["--", config.destination]
        return args.map(Self.shellWord).joined(separator: " ")
    }

    func terminalServeInstaller(_ config: ServerConfiguration) throws -> String {
        guard let installer = Bundle.main.url(forResource: "install-serve", withExtension: "py"),
              let helper = Bundle.main.url(forResource: "voxl-manager-serve", withExtension: nil)
        else { throw ManagerError("The administrator installer is missing from the app bundle.") }
        let bootstrap = "import base64,sys; exec(compile(base64.b64decode(sys.argv[1]), '<voxl-manager-installer>', 'exec'))"
        let remote = ["/usr/bin/sudo", "--", "/usr/bin/python3", "-I", "-c", bootstrap,
                      try Data(contentsOf: installer).base64EncodedString(),
                      try Data(contentsOf: helper).base64EncodedString(), config.hostname,
                      String(config.httpPort), String(config.httpsPort), config.username]
        var args = arguments(config, remote: remote)
        args[0] = "-tt" // Linux sudo prompts on the remote terminal.
        return (["/usr/bin/ssh"] + args).map(Self.shellWord).joined(separator: " ")
    }

    func script<T: Decodable & Sendable>(_ action: String, config: ServerConfiguration,
                                          timeout: TimeInterval, as type: T.Type) async throws -> T {
        guard let scriptURL = Bundle.main.url(forResource: "remote", withExtension: "py"),
              let unitURL = Bundle.main.url(forResource: "voxl-manager", withExtension: "service")
        else { throw ManagerError("The Linux service resources are missing from the app bundle.") }
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        let unit = try String(contentsOf: unitURL, encoding: .utf8)
        let input = try JSONSerialization.data(withJSONObject: [
            "source": source, "unit": unit, "config": try config.loadPayload()
        ])
        let bootstrap = "import json,sys; p=json.load(sys.stdin); s=p['source']; exec(compile(s,'<voxl-manager>','exec'),{'__name__':'__main__','SOURCE':s,'UNIT_SOURCE':p['unit'],'CONFIGURATION':p['config']})"
        let args = arguments(config, remote: ["/usr/bin/python3", "-I", "-u", "-c", bootstrap, action])
        let result = try await runner.run("/usr/bin/ssh", args, input: input, timeout: timeout, environment: [:])
        guard result.exitCode == 0 else {
            let detail = DiagnosticText.safe(result.stderr)
            throw ManagerError("Linux \(action) failed (exit \(result.exitCode)).\(detail.isEmpty ? "" : "\n" + detail)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(result.stdout.utf8))
        } catch {
            throw ManagerError("Linux \(action) returned unexpected data. Check that the SSH shell does not print startup text.")
        }
    }
}

struct RemoteMessage: Decodable, Sendable {
    let message: String
}
