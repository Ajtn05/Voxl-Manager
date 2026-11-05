import AppKit
import SwiftUI

struct ServerSetupView: View {
    let model: ServerViewModel
    let prompt: SetupPrompt
    @State private var feedback: String?

    private var title: String {
        switch prompt.step {
        case .ssh: "Set up SSH"
        case .desktop: "Make the Linux desktop available"
        case .executable: "Find the Voxl executable"
        case .userService: "Install the Voxl user service"
        case .serveAdmin: "Approve private Serve management"
        case .servePolicy: "Match the Linux Serve policy"
        }
    }

    private var instructions: String {
        switch prompt.step {
        case .ssh:
            "Copy the SSH command and run it in Terminal. If SSH asks you to trust a key, compare its fingerprint with the one shown on Linux by ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub. Then check that your SSH key or agent can sign in."
        case .desktop:
            "Sign in to the local X11 desktop as \(model.config.username). If X11 is already running, check the display and Xauthority path in Settings."
        case .executable:
            "If Voxl is installed outside the standard Linux locations, enter its absolute path in Settings. Otherwise, install Voxl on Linux and try again."
        case .userService:
            "The app will install voxl-manager.service in your Linux account, then continue connecting."
        case .serveAdmin:
            "Copy the prepared command, paste it into Terminal, and approve the sudo prompt on Linux. The command installs a root-owned helper, a policy for \(model.config.hostname), and a sudo rule for that helper. Then return here and click Check & Continue."
        case .servePolicy:
            "Choose an approved HTTPS port and match the upstream in Settings. A Linux administrator can edit /etc/voxl-manager/serve.json if you need a different port."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "wrench.and.screwdriver")
                .font(.title2.weight(.semibold))
            Text(prompt.detail).textSelection(.enabled)
            Text(instructions)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if prompt.step == .serveAdmin {
                LabeledContent("Voxl upstream", value: "127.0.0.1:\(model.config.httpPort)")
                LabeledContent("Selected HTTPS port", value: String(model.config.httpsPort))
            }
            if let feedback { Text(feedback).font(.callout).textSelection(.enabled) }
            HStack {
                Button("Cancel", role: .cancel) { model.setupPrompt = nil }
                Spacer()
                switch prompt.step {
                case .ssh, .serveAdmin:
                    Button("Copy Command & Open Terminal", action: copyCommand)
                    Button("Check & Continue", action: continueSetup)
                        .buttonStyle(.borderedProminent)
                case .desktop, .executable, .servePolicy:
                    Button("Open Settings") {
                        model.setupPrompt = nil
                        model.selection = .settings
                    }
                    Button("Try Again", action: continueSetup)
                        .buttonStyle(.borderedProminent)
                case .userService:
                    Button("Install & Continue", action: continueSetup)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 555)
    }

    private func continueSetup() {
        model.setupPrompt = nil
        model.perform(prompt.retry, allowServiceInstall: prompt.step == .userService)
    }

    private func copyCommand() {
        do {
            guard let command = try model.terminalCommand(for: prompt.step) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            feedback = "Command copied. Paste it into Terminal and press Return."
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.openApplication(at: terminal, configuration: .init())
            }
        } catch {
            feedback = error.localizedDescription
        }
    }
}
