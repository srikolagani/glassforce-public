import Foundation
import os
import GlassforceCore

/// Unified logging (subsystem com.srikolagani.glassforce) plus ~/Library/Logs/Glassforce/glassforce.log.
/// Only non-secret strings are logged: never tokens, codes, verifiers or keys.
enum GFLog {
    enum Category: String { case auth, sync, ui, app }

    private static let subsystem = "com.srikolagani.glassforce"
    private static let loggers: [Category: Logger] = [
        .auth: Logger(subsystem: subsystem, category: "auth"),
        .sync: Logger(subsystem: subsystem, category: "sync"),
        .ui: Logger(subsystem: subsystem, category: "ui"),
        .app: Logger(subsystem: subsystem, category: "app"),
    ]
    private static let queue = DispatchQueue(label: "glassforce.log")
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Glassforce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("glassforce.log")
    }()

    static func write(_ category: Category, _ message: String) {
        loggers[category]!.notice("\(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(category.rawValue)] \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    /// Lets the core library (which can't import os on Linux) log through the same sinks.
    static func installCoreSink() {
        CoreLog.sink = { message in GFLog.write(.sync, message) }
    }
}

/// printf-style wrapper so call sites read like the NSLog they replaced.
func gfLog(_ format: String, _ args: CVarArg...) {
    let message = String(format: format, arguments: args)
    let lower = message.lowercased()
    let category: GFLog.Category =
        lower.contains("sync") ? .sync :
        (lower.contains("sign") || lower.contains("install") || lower.contains("onboarding") || lower.contains("auth")) ? .auth :
        (lower.contains("rect") || lower.contains("hide") || lower.contains("panel")) ? .ui : .app
    GFLog.write(category, message)
}
