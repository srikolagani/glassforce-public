import AppKit
import Testing
@testable import GlassforceKit
import GlassforceCore

@Suite("Window input configuration", .serialized)
@MainActor
struct WindowInputConfigurationTests {
    @Test func searchPanelUsesActivatingKeyboardWindow() {
        _ = NSApplication.shared
        let model = CommandBarModel(store: RecordStore(records: []), preferences: MemoryPreferenceStore(domain: ProcessIdentity.qaDomain), egress: .loopbackOnly)
        let controller = PanelController(model: model)
        #expect(controller.panel.canBecomeKey)
        #expect(!controller.panel.styleMask.contains(.nonactivatingPanel))
        #expect(!controller.panel.isMovableByWindowBackground)
        #expect(controller.panel.contentView?.acceptsFirstMouse(for: nil) == true)
        controller.panel.close()
    }

    @Test func onboardingInitiallyDoesNotTakeHeldShortcutKey() {
        _ = NSApplication.shared
        let window = OnboardingWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        #expect(!window.canBecomeKey)
        window.isReleasedWhenClosed = false
        window.activateForUserInteraction()
        #expect(window.canBecomeKey)
        window.close()
    }

    @Test func repeatedShowHideRequestsFreshFocusAndPreservesQuery() {
        _ = NSApplication.shared
        let model = CommandBarModel(store: RecordStore(records: []), preferences: MemoryPreferenceStore(domain: ProcessIdentity.qaDomain), egress: .loopbackOnly)
        model.query = "fixture query"
        let controller = PanelController(model: model)
        defer { controller.hide(); controller.panel.close() }
        for expected in 1...3 {
            controller.show()
            #expect(controller.isVisible)
            #expect(model.focusRequest == expected)
            #expect(model.query == "fixture query")
            controller.hide()
            #expect(!controller.isVisible)
        }
    }
}
