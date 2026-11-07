import AppKit
import SwiftUI
import GlassforceCore

/// Borderless floating panel that can take keyboard focus without activating the app,
/// the way Spotlight does.
final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let panelSize = NSSize(width: 720, height: 560)

    private let model: CommandBarModel
    private let panel: CommandPanel
    private var keyMonitor: Any?
    private var backdrop: NSWindow?
    var pinned = false
    /// ⌘, while the panel has focus.
    var openSettings: (() -> Void)?

    init(model: CommandBarModel) {
        self.model = model
        panel = CommandPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        model.afterOpen = { [weak self] in self?.hide() }
        model.settingsAction = { [weak self] in
            gfLog("Glassforce: open settings from panel")
            self?.hide(); self?.openSettings?()
        }

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI glass draws its own depth
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let hosting = NSHostingView(rootView: CommandBarView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        positionTopCenter()
        model.selectedIndex = 0
        panel.orderFrontRegardless()
        // Pinned (screenshot) mode never takes keyboard focus from whatever the user is doing.
        if !pinned {
            panel.makeKey()
            model.requestFocus()
        }
        installKeyMonitor()
        placeCaretAtEnd()
        logFrame("show")
    }

    /// SwiftUI selects the whole field when it takes focus, which paints a selection tint over
    /// the typed query. Put a plain caret at the end instead, like Spotlight.
    private func placeCaretAtEnd() {
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let editor = self?.panel.firstResponder as? NSTextView else { return }
                let end = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
    }

    func hide() {
        gfLog("Glassforce: hide")
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    // Click-away: another window took key focus.
    func windowDidResignKey(_ notification: Notification) {
        gfLog("Glassforce: panel resigned key (pinned=%d)", pinned ? 1 : 0)
        if !pinned { hide() }
    }

    /// A plain window under the panel that shows a colorful gradient, so demo screenshots
    /// show the real glass over something nicer than whatever is on screen.
    func showDemoBackdrop() {
        positionTopCenter()
        let frame = panel.frame.insetBy(dx: -80, dy: -60)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: DemoBackdropView())
        window.orderFrontRegardless()
        backdrop = window
        logFrame("backdrop", window.frame)
    }

    /// Logs a frame in screencapture -R coordinates (points, top-left origin of the main display).
    private func logFrame(_ label: String, _ rect: NSRect? = nil) {
        let r = rect ?? panel.frame
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - r.maxY
        gfLog("Glassforce: %@ rect=%d,%d,%d,%d key=%d", label,
              Int(r.minX), Int(top), Int(r.width), Int(r.height), panel.isKeyWindow ? 1 : 0)
    }

    private func positionTopCenter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = Self.panelSize
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - visible.height * 0.12
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "," {
                self.model.openSettings(); return nil
            }
            let key: CommandKey?
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
                key = .copyLink
            } else if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "k" {
                key = .commandK
            } else if flags.isEmpty {
                switch Int(event.keyCode) {
                case 53: key = .escape
                case 125: key = .down
                case 126: key = .up
                case 36, 76: key = .return
                default: key = nil
                }
            } else {
                key = nil
            }
            guard let key else { return event }
            switch CommandKeys.effect(key, menuOpen: self.model.actionMenu.isOpen) {
            case .moveSelection(let delta):
                self.model.moveSelection(by: delta)
                return nil
            case .openSelected:
                if self.model.results.isEmpty, self.model.status == .noOrg || { if case .failed = self.model.status { return true }; return false }() {
                    self.hide(); self.model.connectAction?(); return nil
                }
                if let record = self.model.selectedRecord { self.model.open(record) } else { self.hide() }
                return nil
            case .copySelectedLink:
                let length = (self.panel.firstResponder as? NSTextView)?.selectedRange().length ?? 0
                if self.model.copySelectedLink(fieldSelectionLength: length) != nil { return nil }
                return event
            case .toggleActionMenu:
                self.model.actionMenu.toggle()
                return nil
            case .closeMenu:
                self.model.actionMenu.close()
                return nil
            case .moveMenu(let delta):
                let count = self.model.selectedRecord.map { CommandAction.menu(for: $0).count } ?? 0
                self.model.actionMenu.move(delta, count: count)
                return nil
            case .runMenu:
                self.model.runMenuAction()
                return nil
            case .closePanel:
                self.hide(); return nil
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
