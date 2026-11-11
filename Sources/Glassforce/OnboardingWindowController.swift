import AppKit
import SwiftUI
import GlassforceCore

/// Cannot become key until the user clicks it, unless a Debug `--qa-foreground` launch opts in.
/// A window that appears under a held Space key must not receive that key.
final class OnboardingWindow: NSWindow {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    /// Explicit clicks must activate the accessory app and its borderless window.
    /// Merely allowing key status does not transfer keyboard focus from the browser.
    func activateForUserInteraction() {
        acceptsKey = true
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            activateForUserInteraction()
        }
        super.sendEvent(event)
    }
}

/// The auth browser can leave this accessory window inactive. The explicit mouse
/// click must reach its tap-only controls rather than merely activate the window.
private final class OnboardingHostingView: NSHostingView<OnboardingView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless clear host so SwiftUI `.glassEffect` shows the desktop the way the command bar does.
@MainActor
final class OnboardingWindowController {
    let window: OnboardingWindow
    private var backdrop: NSWindow?

    init(session: AppSession, onFinish: @escaping () -> Void) {
        window = OnboardingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false // glass draws its own depth
        // Tap-only controls must receive the click, not start a background window drag.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Glassforce"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = OnboardingView(session: session, onFinish: onFinish)
        let host = OnboardingHostingView(rootView: root)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = host
        window.center()
    }

    func show(presentation: WindowPresentation) {
        switch presentation {
        case .hidden:
            gfLog("Glassforce: onboarding stays hidden until a click or Option-Space")
            return
        case .visibleInactive:
            window.acceptsKey = false
            centerOnActiveScreen()
            window.orderFrontRegardless()
        case .keyAndActive:
            window.acceptsKey = true
            centerOnActiveScreen()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        gfLog("Glassforce: onboarding rect=%@ presentation=%@", NSStringFromRect(window.frame), "\(presentation)")
    }

    func showProofBackdrop() {
        centerOnActiveScreen()
        let frame = window.frame.insetBy(dx: -140, dy: -120)
        let behind = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        behind.level = NSWindow.Level(rawValue: window.level.rawValue - 1)
        behind.isReleasedWhenClosed = false
        behind.ignoresMouseEvents = true
        behind.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        behind.isOpaque = false
        behind.backgroundColor = .clear
        behind.contentView = NSHostingView(rootView: DemoBackdropView())
        behind.orderFrontRegardless()
        backdrop = behind
        window.orderFrontRegardless()
    }

    func close() {
        backdrop?.orderOut(nil)
        backdrop = nil
        window.orderOut(nil)
    }

    var captureRect: (x: Int, y: Int, w: Int, h: Int) {
        let r = window.frame.insetBy(dx: -32, dy: -32)
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - r.maxY
        return (Int(r.minX), Int(top), Int(r.width), Int(r.height))
    }

    private func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.04))
    }
}
