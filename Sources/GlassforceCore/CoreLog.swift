import Foundation

/// Log hook for the core library; the app routes it to os.Logger and a log file. Never pass secrets.
public enum CoreLog {
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?

    public static func info(_ message: String) {
        if let sink { sink(message) } else { NSLog("%@", message) }
    }
}
