import SwiftUI

struct SettingsView: View {
    let model: ServerViewModel
    @State private var draft = ServerConfiguration()
    @State private var feedback: String?
    @State private var invalid = false
    @State private var showInstall = false

    private var dirty: Bool { draft != model.config }

    var body: some View {
        Form {
            SwiftUI.Section("Server & SSH") {
                TextField("MagicDNS hostname", text: $draft.hostname, prompt: Text("server.your-tailnet.ts.net"))
                TextField("SSH username", text: $draft.username, prompt: Text("Linux desktop account"))
                TextField("SSH config alias (optional)", text: $draft.sshAlias, prompt: Text("Use MagicDNS hostname"))
                TextField("SSH port (optional)", text: $draft.sshPort, prompt: Text("Use SSH config · normally 22"))
            }
            SwiftUI.Section("Linux desktop") {
                TextField("Voxl executable", text: $draft.executable, prompt: Text("Discover automatically"))
                if let executable = model.snapshot?.executable {
                    LabeledContent("Detected executable") { Text(executable).textSelection(.enabled) }
                }
                TextField("X11 display", text: $draft.display)
                TextField("Xauthority path", text: $draft.xauthority, prompt: Text("~/.Xauthority on Linux"))
                TextField("Voxl HTTP port", value: $draft.httpPort, format: .number.grouping(.never))
                TextField("Serve HTTPS port", value: $draft.httpsPort, format: .number.grouping(.never))
                if let allowed = model.snapshot?.serve.allowedPorts {
                    LabeledContent("Administrator-approved HTTPS ports", value: allowed.map(String.init).joined(separator: ", "))
                }
            }
            SwiftUI.Section("Serve management") {
                Button("Set Up Serve Management…", action: model.guideServeSetup)
                    .disabled(!model.config.isConfigured || dirty || model.busy || model.snapshot?.serve.allowedPorts != nil)
                if model.snapshot?.serve.allowedPorts != nil {
                    Label("Administrator helper available", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            SwiftUI.Section("App behavior") {
                Toggle("Check status on launch", isOn: $draft.checkOnLaunch)
                Toggle("Connect to a running desktop on launch", isOn: $draft.connectOnLaunch)
                Toggle("Show menu bar controls", isOn: $draft.menuBar)
            }
            SwiftUI.Section {
                HStack {
                    Button("Install / Update User Service…") { showInstall = true }
                        .disabled(!model.config.isConfigured || dirty || model.busy)
                    Spacer()
                    if dirty { Button("Revert") { draft = model.config; feedback = nil } }
                    Button("Save Settings") { save() }.buttonStyle(.borderedProminent).disabled(!dirty || model.busy)
                }
                if let feedback {
                    Text(feedback).font(.callout)
                        .foregroundStyle(invalid ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Save settings before installing. Installation writes files for the Linux SSH user and reloads their systemd manager. It does not enable Voxl at boot.")
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = model.config }
        .confirmationDialog("Install the systemd user service?", isPresented: $showInstall, titleVisibility: .visible) {
            Button("Install User Service") { model.perform(.install) }
        } message: {
            Text("Install or update voxl-manager.service for \(model.config.destination). Voxl Manager will verify the executable and its command-line flags.")
        }
    }

    private func save() {
        do {
            try model.save(draft)
            draft = model.config
            invalid = false
            feedback = "Settings saved."
        } catch {
            invalid = true
            feedback = error.localizedDescription
        }
    }
}
