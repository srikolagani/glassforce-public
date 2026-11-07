import Foundation

/// The one path that opens a search result (mouse click, Return, `--open-first`). Logs only the
/// object kind and the URL's host+path shape, never tokens.
public struct RecordOpener: Sendable {
    public let openURL: @Sendable (URL) -> Void
    public init(openURL: @escaping @Sendable (URL) -> Void) { self.openURL = openURL }

    @discardableResult
    public func open(_ record: Record) -> URL? {
        guard let url = record.url else {
            CoreLog.info("Glassforce: \(record.kind) \(record.id) has no link (fake data)"); return nil
        }
        CoreLog.info("Glassforce: open \(record.kind) → \(url.absoluteString)")
        openURL(url)
        return url
    }
}
