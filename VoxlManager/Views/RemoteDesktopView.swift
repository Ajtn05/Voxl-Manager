import AppKit
import SwiftUI
import WebKit

enum ViewerState: Equatable {
    case loading, signingIn, pageReady, connected, reconnecting, issue(String)
    var label: String {
        switch self {
        case .loading: "Loading Voxl"
        case .signingIn: "Signing in to Voxl"
        case .pageReady: "Page loaded · waiting for stream"
        case .connected: "Stream transport connected"
        case .reconnecting: "Reconnecting"
        case .issue(let message): message
        }
    }
    var color: Color {
        switch self {
        case .connected: .green
        case .issue: .orange
        default: .secondary
        }
    }
}

struct RemoteDesktopView: View {
    let model: ServerViewModel
    @State private var state: ViewerState = .loading
    @State private var reload = 0
    @State private var fullscreenRequest = 0

    var body: some View {
        if let url = model.viewerURL {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Circle().fill(state.color).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(state.label).font(.callout).lineLimit(2)
                    Spacer(minLength: 12)
                    Button { reload += 1 } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Button { model.openVerifiedURLInBrowser() } label: { Label("Browser", systemImage: "safari") }
                    Button { fullscreenRequest += 1 } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Capture the desktop. Press Control–Option–Esc to return to the Mac.")
                    .disabled(state != .connected)
                    Button("Disconnect", action: model.disconnect)
                }
                .padding(.horizontal, 15).padding(.vertical, 9)
                .background(.bar)
                Divider()
                EmbeddedDesktop(url: url, reload: reload, state: $state, fullscreenRequest: fullscreenRequest) {
                    await model.managedPassword(for: url)
                }
                .id(url)
            }
        } else {
            ContentUnavailableView {
                Label("Remote Desktop", systemImage: "macwindow")
            } description: {
                Text("Connect to a running desktop or start the Linux service from Overview.")
            } actions: {
                Button("Connect Viewer") { model.perform(.connect) }.buttonStyle(.borderedProminent)
                    .disabled(model.busy)
            }
        }
    }
}

struct EmbeddedDesktop: NSViewRepresentable {
    let url: URL
    let reload: Int
    @Binding var state: ViewerState
    var fullscreenRequest = 0
    var managedPassword: @MainActor () async -> String? = { nil }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, state: $state, reload: reload, fullscreenRequest: fullscreenRequest,
                    managedPassword: managedPassword)
    }

    func makeNSView(context: Context) -> DesktopHostView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = true
        let controller = configuration.userContentController
        controller.add(WeakScriptHandler(context.coordinator), name: "voxlTransport")
        controller.addUserScript(.init(source: Self.observer, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let host = DesktopHostView(webView: webView)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.open(webView, reset: true)
        return host
    }

    func updateNSView(_ host: DesktopHostView, context: Context) {
        if context.coordinator.reload != reload {
            context.coordinator.reload = reload
            context.coordinator.open(host.webView, reset: true)
        }
        if context.coordinator.fullscreenRequest != fullscreenRequest {
            context.coordinator.fullscreenRequest = fullscreenRequest
            context.coordinator.fullscreen.enter(from: host)
        }
    }

    static func dismantleNSView(_ host: DesktopHostView, coordinator: Coordinator) {
        coordinator.invalidate()
        let webView = host.webView
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "voxlTransport")
    }

    // Observe connection messages in both current worker-based Voxl and older page-based clients.
    private static let observer = """
    (() => {
      const notify = kind => window.webkit.messageHandlers.voxlTransport.postMessage(kind);
      if (typeof Worker === "function") {
        window.Worker = new Proxy(window.Worker, {
          construct(target, args, receiver) {
            const worker = Reflect.construct(target, args, receiver);
            const endpoint = new URL(args[0], location.href);
            if (endpoint.origin !== location.origin || !endpoint.pathname.endsWith("/worker.js")) return worker;
            worker.addEventListener("message", ({data}) => {
              if (data?.t === "hello") notify("connected");
              if (data?.t === "status" && data.s === "closed") notify("worker-reconnecting");
            });
            worker.addEventListener("error", () => notify("worker-failed"));
            return worker;
          }
        });
      }
      const live = new Set();
      const Native = window.WebSocket;
      window.WebSocket = new Proxy(Native, {
        construct(target, args, receiver) {
          const socket = Reflect.construct(target, args, receiver);
          const endpoint = new URL(socket.url);
          if (endpoint.protocol !== "wss:" || endpoint.host !== location.host) return socket;
          socket.addEventListener("open", () => { live.add(socket); notify("connected"); });
          const ended = () => {
            live.delete(socket);
            if (!live.size) notify("lost");
          };
          socket.addEventListener("close", ended);
          socket.addEventListener("error", ended);
          return socket;
        }
      });
      if (typeof VideoDecoder !== "function") notify("unsupported");
    })();
    """

    @MainActor
    final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
        weak var receiver: Coordinator?
        init(_ receiver: Coordinator) { self.receiver = receiver }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            receiver?.received(message)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let url: URL
        let state: Binding<ViewerState>
        var reload: Int
        var fullscreenRequest: Int
        let fullscreen = DesktopFullscreen()
        let managedPassword: @MainActor () async -> String?
        private var retry: Task<Void, Never>?
        private var workerRecovery: Task<Void, Never>?
        private var attempts = 0
        private var invalidated = false
        private var unsupported = false
        private var authenticating = false

        init(url: URL, state: Binding<ViewerState>, reload: Int, fullscreenRequest: Int = 0,
             managedPassword: @escaping @MainActor () async -> String? = { nil }) {
            self.url = url
            self.state = state
            self.reload = reload
            self.fullscreenRequest = fullscreenRequest
            self.managedPassword = managedPassword
        }

        func invalidate() {
            invalidated = true
            retry?.cancel()
            workerRecovery?.cancel()
            fullscreen.exit()
        }

        func open(_ webView: WKWebView, reset: Bool) {
            guard !invalidated else { return }
            if reset {
                retry?.cancel()
                retry = nil
                workerRecovery?.cancel()
                workerRecovery = nil
                attempts = 0
                set(.loading)
            }
            unsupported = false
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18))
        }

        private func set(_ value: ViewerState) {
            // AppKit can call delegates while SwiftUI is applying a view update.
            Task { @MainActor [weak self] in
                guard let self, !invalidated else { return }
                state.wrappedValue = value
            }
        }

        private func matches(_ candidate: URL?) -> Bool {
            guard let candidate else { return false }
            return candidate.scheme == "https" && candidate.host?.lowercased() == url.host?.lowercased()
                && (candidate.port ?? 443) == (url.port ?? 443)
                && candidate.user == nil && candidate.password == nil
        }

        func received(_ message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, matches(message.frameInfo.request.url),
                  let webView = message.webView, let kind = message.body as? String else { return }
            switch kind {
            case "connected":
                retry?.cancel()
                retry = nil
                workerRecovery?.cancel()
                workerRecovery = nil
                attempts = 0
                if !unsupported { set(.connected) }
            case "lost":
                if !unsupported && !authenticating { scheduleRetry(webView, reason: "The stream disconnected.") }
            case "worker-reconnecting":
                if !unsupported && !authenticating && workerRecovery == nil {
                    set(.reconnecting)
                    // Voxl's worker retries the socket itself. Keep the same page open while it recovers.
                    workerRecovery = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                        self?.fullscreen.exit()
                        self?.showIssue("Voxl is still trying to reconnect. Reload or open in your browser.")
                    }
                }
            case "worker-failed":
                if !unsupported { showIssue("Voxl’s stream worker failed. Reload or open in your browser.") }
            case "unsupported":
                unsupported = true
                set(.issue("WebKit cannot decode this stream. Open it in your browser."))
            default: break
            }
        }

        private func scheduleRetry(_ webView: WKWebView, reason: String) {
            guard retry == nil, !invalidated else { return }
            guard attempts < 3 else {
                set(.issue(reason + " Reload or open in your browser."))
                return
            }
            attempts += 1
            let delay = [4, 8, 15][attempts - 1]
            set(.reconnecting)
            retry = Task { [weak self, weak webView] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, let webView, !authenticating else { self?.retry = nil; return }
                retry = nil
                open(webView, reset: false)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            matches(navigationAction.request.url) && navigationAction.targetFrame != nil ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            guard matches(navigationResponse.response.url) else { return .cancel }
            if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                if response.statusCode == 401 || response.statusCode == 403 {
                    showIssue("Voxl requires authentication or rejected the request. Reload or use your browser.")
                } else {
                    scheduleRetry(webView, reason: "Voxl returned HTTP \(response.statusCode).")
                }
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !unsupported, retry == nil, state.wrappedValue != .connected { set(.pageReady) }
            fullscreen.refreshPage()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            failed(webView, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            failed(webView, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            scheduleRetry(webView, reason: "The WebKit viewer closed unexpectedly.")
        }

        private func failed(_ webView: WKWebView, error: any Error) {
            let network = error as NSError
            // WebKit reports this after the response policy intentionally cancels a load.
            if network.domain == "WebKitErrorDomain", network.code == 102 { return }
            if network.domain == NSURLErrorDomain {
                if network.code == NSURLErrorCancelled || network.code == NSURLErrorUserCancelledAuthentication { return }
                if (NSURLErrorClientCertificateRequired...NSURLErrorSecureConnectionFailed).contains(network.code) {
                    showIssue("HTTPS certificate or TLS connection could not be verified.")
                    return
                }
            }
            scheduleRetry(webView, reason: "The HTTPS viewer could not load.")
        }

        private func showIssue(_ message: String) {
            retry?.cancel()
            retry = nil
            set(.issue(message))
        }

        func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            let protection = challenge.protectionSpace
            if protection.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                return (.performDefaultHandling, nil)
            }
            guard protection.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
                  !protection.isProxy(), protection.protocol == "https",
                  protection.host.lowercased() == url.host?.lowercased(), protection.port == (url.port ?? 443) else {
                return (.rejectProtectionSpace, nil)
            }
            guard challenge.previousFailureCount < 3 else {
                showIssue("Voxl rejected the username or password. Reload to try again.")
                return (.cancelAuthenticationChallenge, nil)
            }
            guard !authenticating else {
                showIssue("Voxl needs you to sign in. Reload to open the sign-in prompt.")
                return (.cancelAuthenticationChallenge, nil)
            }
            retry?.cancel()
            retry = nil
            authenticating = true
            defer { authenticating = false }
            if protection.realm == "voxl", challenge.previousFailureCount == 0 {
                set(.signingIn)
                if let password = await managedPassword(), !invalidated {
                    return (.useCredential, URLCredential(user: "voxl", password: password, persistence: .forSession))
                }
            }
            fullscreen.exit()
            guard !invalidated, let window = webView.window else { return (.cancelAuthenticationChallenge, nil) }
            let alert = NSAlert()
            alert.messageText = "Sign in to Voxl"
            alert.informativeText = challenge.previousFailureCount == 0
                ? "Enter the username and password for this Voxl server."
                : "Voxl rejected the previous credentials. Use your Voxl password."
            alert.addButton(withTitle: "Sign In")
            alert.addButton(withTitle: "Cancel")
            let user = NSTextField(string: "voxl")
            user.placeholderString = "Username"
            user.setAccessibilityLabel("Voxl username")
            let secret = NSSecureTextField()
            secret.placeholderString = "Voxl password"
            secret.setAccessibilityLabel("Voxl password")
            let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 94))
            let userLabel = NSTextField(labelWithString: "Username")
            let passwordLabel = NSTextField(labelWithString: "Password")
            userLabel.frame = NSRect(x: 0, y: 75, width: 300, height: 16)
            user.frame = NSRect(x: 0, y: 49, width: 300, height: 24)
            passwordLabel.frame = NSRect(x: 0, y: 28, width: 300, height: 16)
            secret.frame = NSRect(x: 0, y: 2, width: 300, height: 24)
            for view in [userLabel, user, passwordLabel, secret] { fields.addSubview(view) }
            user.nextKeyView = secret
            secret.nextKeyView = user
            alert.accessoryView = fields
            alert.window.initialFirstResponder = secret
            let response = await alert.beginSheetModal(for: window)
            guard response == .alertFirstButtonReturn, !invalidated else {
                showIssue("Voxl sign-in cancelled. Reload to try again.")
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(user: user.stringValue, password: secret.stringValue, persistence: .forSession))
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo) async {
            guard frame.isMainFrame, matches(frame.request.url), let window = webView.window else { return }
            let alert = makeAlert(message)
            alert.addButton(withTitle: "OK")
            _ = await alert.beginSheetModal(for: window)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo) async -> Bool {
            guard frame.isMainFrame, matches(frame.request.url), let window = webView.window else { return false }
            let alert = makeAlert(message)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
            guard frame.isMainFrame, matches(frame.request.url), let window = webView.window else { return nil }
            let alert = makeAlert(prompt)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = prompt.localizedCaseInsensitiveContains("password") ? NSSecureTextField() : NSTextField()
            field.stringValue = defaultText ?? ""
            field.frame = NSRect(x: 0, y: 0, width: 265, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? field.stringValue : nil
        }

        private func makeAlert(_ message: String) -> NSAlert {
            let alert = NSAlert()
            alert.messageText = "Voxl"
            alert.informativeText = String(message.prefix(1000))
            return alert
        }
    }
}
