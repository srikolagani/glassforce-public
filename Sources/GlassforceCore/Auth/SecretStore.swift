import Foundation

/// Where refresh tokens live. The app uses the macOS Keychain; tests use `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    /// Every write, in order. Lets tests prove the rotated token was saved before use.
    public private(set) var writeLog: [String] = []

    public init() {}

    public func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    public func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = data
        writeLog.append(account)
    }

    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
    }

    public var accounts: [String] {
        lock.lock(); defer { lock.unlock() }
        return items.keys.sorted()
    }
}
