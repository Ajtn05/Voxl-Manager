import SwiftUI

@main
struct VoxlManagerApp: App {
    @State private var model = ServerViewModel()

    var body: some Scene {
        Window("Voxl Manager", id: "manager") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 580)
                .task { model.launch() }
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Settings…") { model.selection = .settings }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Refresh Status") { model.perform(.refresh) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.busy)
            }
        }
        MenuBarExtra("Voxl Manager", systemImage: "display", isInserted: menuBarBinding) {
            ManagerMenu(model: model)
        }
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(get: { model.config.menuBar }, set: { inserted in
            var config = model.config
            config.menuBar = inserted
            try? model.save(config)
        })
    }
}

private struct ManagerMenu: View {
    @Environment(\.openWindow) private var openWindow
    let model: ServerViewModel
    var body: some View {
        Text(model.connection.status.rawValue)
        Divider()
        Button("Show Voxl Manager") { show(.overview) }
        Button("Connect Viewer") { show(.desktop); model.perform(.connect) }.disabled(model.busy)
        Button("Start Remote Desktop") { show(.overview); model.perform(.start) }.disabled(model.busy)
        Button("Disconnect Viewer") { model.disconnect() }.disabled(model.viewerURL == nil)
    }

    private func show(_ selection: Section) {
        model.selection = selection
        openWindow(id: "manager")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ContentView: View {
    @Bindable var model: ServerViewModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                SwiftUI.Section("Workspace") {
                    ForEach(Section.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon).tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 200, max: 230)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(model.connection.status == .ready ? .green : .secondary)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.config.hostname.split(separator: ".").first.map(String.init) ?? "Server")
                            .font(.callout.weight(.semibold))
                        Text(model.connection.status.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        } detail: {
            VStack(spacing: 0) {
                ZStack {
                    // Keep WebKit alive when switching to another sidebar page.
                    if model.viewerURL != nil || model.selection == .desktop {
                        RemoteDesktopView(model: model)
                            .opacity(model.selection == .desktop ? 1 : 0)
                            .allowsHitTesting(model.selection == .desktop)
                            .accessibilityHidden(model.selection != .desktop)
                    }
                    switch model.selection ?? .overview {
                    case .overview: DashboardView(model: model)
                    case .desktop: EmptyView()
                    case .diagnostics: LogsView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                if let progress = model.progress {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.callout)
                        Spacer()
                        Button("Cancel", action: model.cancel)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .background(.bar)
                }
                if let error = model.error, model.selection != .overview {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error.components(separatedBy: "\n").first ?? error)
                            .font(.callout).lineLimit(2)
                        Spacer()
                        if model.selection != .diagnostics {
                            Button("Diagnostics") { model.selection = .diagnostics }
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .background(.bar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle((model.selection ?? .overview).rawValue)
            .toolbar {
                ToolbarItem {
                    Button { model.perform(.refresh) } label: { Label("Refresh Status", systemImage: "arrow.clockwise") }
                        .disabled(model.busy)
                }
            }
        }
        .sheet(item: $model.setupPrompt) { prompt in
            ServerSetupView(model: model, prompt: prompt)
        }
    }
}
