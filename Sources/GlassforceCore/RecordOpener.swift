import Foundation

/// The one path that opens a search result (mouse click, Return, `--open-first`). Logs only the
/// object kind and the URL's host+path shape, never tokens.
public struct RecordOpener: Sendable {
    public var policy: EgressPolicy
    public let openURL: @Sendable (URL) -> Void
    public init(policy: EgressPolicy = .unrestricted, openURL: @escaping @Sendable (URL) -> Void) {
        self.policy = policy
        self.openURL = openURL
    }

    /// Click, Return, and `--open-first` all come here. The policy runs before `openURL`.
    @discardableResult
    public func open(_ record: Record) -> URL? {
        guard let url = record.url else {
            CoreLog.info("Glassforce: \(record.kind) \(record.id) has no link (fake data)"); return nil
        }
        guard URLOpenGate.allows(url, policy: policy) else {
            CoreLog.info("Glassforce: blocked open \(url.host ?? "no-host")")
            return nil
        }
        CoreLog.info("Glassforce: open \(record.kind) → \(url.absoluteString)")
        openURL(url)
        return url
    }
}
