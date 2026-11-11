import AppKit

public enum GlassforceEntry {
    @MainActor
    public static func run() -> Never {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
        app.run()
        exit(0)
    }
}
