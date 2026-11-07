import AppKit
import SwiftUI

/// Hosts `SettingsView` in a standard window with the same translucent backing as onboarding.
@MainActor
final class SettingsWindowController {
    let window: NSWindow
    let model: SettingsModel

    init(session: AppSession) {
        model = SettingsModel(session: session)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.title = "Glassforce Settings"
        window.minSize = NSSize(width: 560, height: 520)
        let backing = NSVisualEffectView()
        backing.material = .underWindowBackground
        backing.blendingMode = .behindWindow
        backing.state = .active
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        backing.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: backing.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: backing.trailingAnchor),
            host.topAnchor.constraint(equalTo: backing.topAnchor),
            host.bottomAnchor.constraint(equalTo: backing.bottomAnchor),
        ])
        window.contentView = backing
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Task { await model.load() }
        // windowNumber is the CGWindowID, for `screencapture -l <id>`.
        gfLog("Glassforce: settings window id=%d rect=%@", window.windowNumber, NSStringFromRect(window.frame))
    }
}
