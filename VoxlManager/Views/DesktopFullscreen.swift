import AppKit
import CoreGraphics
import WebKit

@MainActor
final class DesktopHostView: NSView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        restoreViewer()
    }

    required init?(coder: NSCoder) { nil }

    func restoreViewer() {
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

@MainActor
final class DesktopFullscreen: NSObject, NSWindowDelegate {
    private weak var host: DesktopHostView?
    private var window: CaptureWindow?
    private var previousPresentation: NSApplication.PresentationOptions = []
    private var cursorTimer: Timer?
    private var keyMonitor: Any?

    func enter(from host: DesktopHostView) {
        guard window == nil, let screen = host.window?.screen else { return }
        let capture = CaptureWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        capture.identifier = NSUserInterfaceItemIdentifier("VoxlFullscreen")
        capture.title = "Voxl Desktop Full Screen"
        capture.isReleasedWhenClosed = false
        capture.backgroundColor = .black
        capture.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        capture.acceptsMouseMovedEvents = true
        capture.delegate = self

        self.host = host
        window = capture
        previousPresentation = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let webView = host.webView
        webView.removeFromSuperview()
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        capture.contentView = content
        capture.setFrame(screen.frame, display: true)
        capture.makeKeyAndOrderFront(nil)
        capture.makeFirstResponder(webView)
        refreshPage()
        showReleaseHint(in: content)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self, weak capture] event in
            guard event.window === capture, Self.isReleaseShortcut(event) else { return event }
            self?.exit()
            return nil
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.constrainCursor() }
        }
        cursorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func refreshPage() {
        guard window != nil, let webView = host?.webView else { return }
        webView.evaluateJavaScript("""
        (() => {
          if (!document.getElementById('surface') || !document.getElementById('screen')) return;
          if (!document.getElementById('voxl-manager-fullscreen')) {
            const style = document.createElement('style');
            style.id = 'voxl-manager-fullscreen';
            // Scale the same box Voxl uses to convert pointer locations into Mint coordinates.
            style.textContent = '#surface { position:fixed !important; inset:0 !important; width:100% !important; height:100% !important; max-width:none !important; max-height:none !important; }';
            document.head.append(style);
          }
          document.getElementById('kbd')?.focus({preventScroll:true});
        })();
        """, completionHandler: nil)
    }

    func exit(restoreFocus: Bool = true) {
        guard let capture = window else { return }
        window = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let host {
            host.webView.evaluateJavaScript("""
            document.getElementById('voxl-manager-fullscreen')?.remove();
            window.dispatchEvent(new Event('blur'));
            """, completionHandler: nil)
            host.restoreViewer()
            if restoreFocus { host.window?.makeKeyAndOrderFront(nil) }
        }
        NSApp.presentationOptions = previousPresentation
        capture.delegate = nil
        capture.orderOut(nil)
        capture.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        exit(restoreFocus: false)
    }

    private func constrainCursor() {
        guard let window, window.isKeyWindow, window.attachedSheet == nil,
              let screen = window.screen,
              let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        let frame = screen.frame
        let location = NSEvent.mouseLocation
        guard !frame.contains(location) else { return }

        // AppKit's screen coordinates grow up. Quartz display coordinates grow down.
        let bounds = CGDisplayBounds(display.uint32Value)
        let x = min(max(location.x, frame.minX + 1), frame.maxX - 1)
        let y = min(max(location.y, frame.minY + 1), frame.maxY - 1)
        CGWarpMouseCursorPosition(CGPoint(
            x: bounds.minX + (x - frame.minX) * bounds.width / frame.width,
            y: bounds.minY + (frame.maxY - y) * bounds.height / frame.height
        ))
    }

    static func isReleaseShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        return event.keyCode == 53 && modifiers == [.control, .option]
    }

    private func showReleaseHint(in content: NSView) {
        let hint = ReleaseHint(frame: NSRect(x: (content.bounds.width - 310) / 2,
                                             y: content.bounds.height - 77, width: 310, height: 34))
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        hint.layer?.cornerRadius = 8
        let label = NSTextField(labelWithString: "Control + Option + Esc returns to the Mac")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 0, y: 8, width: 310, height: 18)
        hint.addSubview(label)
        content.addSubview(hint)
        Task { [weak hint] in
            try? await Task.sleep(for: .seconds(4))
            hint?.removeFromSuperview()
        }
    }
}

private final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let firstResponder {
            firstResponder.keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class ReleaseHint: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
