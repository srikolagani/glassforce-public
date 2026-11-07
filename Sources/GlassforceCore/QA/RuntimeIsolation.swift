import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Two ways to keep a QA run off the installed app were compared.
///
/// Flag-on-the-shipping-binary: one process, and a switch that picks stores.
/// Call sites already read `UserDefaults.standard` and the login Keychain by
/// concrete type, so a missed call still hits the installed app. The bundle
/// id does not change.
///
/// Chosen: `QAIsolation` fails closed. `GlassforceQA` is a console check.
/// `GlassforcePanelQA` is the Mac panel: real `AppSession`, `CommandBarModel`,
/// and `CommandBarView`, with this value's stores, and no global hotkey.
/// The shipping app denies `--qa-isolated`. Mock and `--fake-data` in that
/// app use an in-memory preference domain and credential store, but they
/// still register Option-Space and keep the shipping bundle id.
public enum ProcessIdentity {
    public static let productionDomain = "com.srikolagani.glassforce"
    public static let qaDomain = "com.srikolagani.glassforce.qa"
    public static let productionKeychainService = "dev.glassforce.oauth"

    /// Last path component of the installed app's Application Support directory.
    public static let productionFolderName = "Glassforce"
}

public enum IsolationError: Error, Equatable, Sendable {
    case emptyRoot
    case notAFileURL
    case overlapsProductionFiles
    case productionPreferenceDomain
    case loginKeychainNotAllowed
    case credentialFolderOutsideRoot
    case unresolvedPath
    case missingRoot
    case missingCommand
    case unexpectedNetwork
}

public protocol PreferenceStore: Sendable {
    var domain: String { get }
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func integer(forKey key: String) -> Int
    func dictionary(forKey key: String) -> [String: Int]?
    func set(_ value: [String: Int]?, forKey key: String)
}

public enum PreferenceKeys {
    public static let recordOpens = "recordOpens"
    public static let consumerKeyOverride = "consumerKeyOverride"
    public static let syncObjectCap = "syncObjectCap"
}

public final class MemoryPreferenceStore: PreferenceStore, @unchecked Sendable {
    public let domain: String
    private var strings: [String: String] = [:]
    private var ints: [String: Int] = [:]
    private var dicts: [String: [String: Int]] = [:]
    private let lock = NSLock()

    public init(domain: String) { self.domain = domain }

    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return strings[key]
    }

    public func set(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        strings[key] = value
    }

    public func integer(forKey key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return ints[key] ?? 0
    }

    public func dictionary(forKey key: String) -> [String: Int]? {
        lock.lock(); defer { lock.unlock() }
        return dicts[key]
    }

    public func set(_ value: [String: Int]?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        dicts[key] = value
    }
}

public enum EgressPolicy: Sendable, Equatable {
    case unrestricted
    case loopbackOnly

    public func allows(_ url: URL) -> Bool {
        switch self {
        case .unrestricted:
            return true
        case .loopbackOnly:
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
            guard url.user == nil, url.password == nil else { return false }
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }
    }
}

public enum EgressError: Error, Equatable, Sendable {
    case blockedHost
    case blockedRedirect
    case unexpectedNetwork
}

public struct URLOpenGate {
    public static func allows(_ url: URL, policy: EgressPolicy) -> Bool { policy.allows(url) }
}

/// Checks the URL before the inner send, and refuses a redirect off the policy.
public struct GuardingTransport: HTTPTransport {
    public var inner: HTTPTransport
    public var policy: EgressPolicy

    public init(inner: HTTPTransport, policy: EgressPolicy) {
        self.inner = inner
        self.policy = policy
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard policy.allows(request.url) else { throw EgressError.blockedHost }
        let response = try await inner.send(request)
        if let location = response.headers.first(where: { $0.key.caseInsensitiveCompare("Location") == .orderedSame })?.value,
           let next = URL(string: location, relativeTo: request.url)?.absoluteURL,
           !policy.allows(next) {
            throw EgressError.blockedRedirect
        }
        return response
    }
}

public final class FolderSecretStore: SecretStore, @unchecked Sendable {
    public let directory: URL
    public var persistsInLoginKeychain: Bool { false }
    public var folderURL: URL? { directory }
    private let lock = NSLock()

    public init(directory: URL) { self.directory = directory }

    private func file(account: String) -> URL {
        let name = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "account"
        return directory.appendingPathComponent(name + ".secret")
    }

    public func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: file(account: account))
    }

    public func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(account: account), options: .atomic)
    }

    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file(account: account))
    }
}

public struct QAIsolation: Sendable {
    public let fileRoot: URL
    public let preferences: PreferenceStore
    public let secrets: SecretStore
    public let transport: HTTPTransport

    public static func make(
        fileRoot: URL,
        productionRoot: URL,
        preferences: PreferenceStore,
        secrets: SecretStore,
        innerTransport: HTTPTransport
    ) -> Result<QAIsolation, IsolationError> {
        guard fileRoot.isFileURL, !fileRoot.path.isEmpty else { return .failure(.notAFileURL) }
        guard productionRoot.isFileURL else { return .failure(.notAFileURL) }
        // Resolve symlink parents before comparing. standardizedFileURL leaves them in place,
        // so a link such as /tmp/link -> /tmp/prod would otherwise accept /tmp/link/qa.
        guard let root = Self.resolved(fileRoot), let production = Self.resolved(productionRoot) else {
            return .failure(.unresolvedPath)
        }
        if root.path == "/" || root.path.isEmpty { return .failure(.emptyRoot) }
        if Self.overlaps(root, production) { return .failure(.overlapsProductionFiles) }
        if preferences.domain.isEmpty || preferences.domain == ProcessIdentity.productionDomain {
            return .failure(.productionPreferenceDomain)
        }
        if secrets.persistsInLoginKeychain { return .failure(.loginKeychainNotAllowed) }
        if let folder = secrets.folderURL {
            guard let resolvedFolder = Self.resolved(folder) else { return .failure(.unresolvedPath) }
            if !Self.contains(root, resolvedFolder) { return .failure(.credentialFolderOutsideRoot) }
        }
        let transport = GuardingTransport(inner: innerTransport, policy: .loopbackOnly)
        return .success(QAIsolation(fileRoot: root, preferences: preferences, secrets: secrets, transport: transport))
    }

    /// Lexical `.` and `..` first, then realpath on the longest existing prefix.
    /// A missing suffix stays on the end. A dangling symlink fails closed.
    static func resolved(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let lexical = url.standardizedFileURL.path
        guard !lexical.isEmpty else { return nil }
        var existing = lexical
        var missing: [String] = []
        while existing != "/" && !pathExists(existing) {
            let name = (existing as NSString).lastPathComponent
            if name.isEmpty || name == "." || name == ".." { return nil }
            missing.insert(name, at: 0)
            let parent = (existing as NSString).deletingLastPathComponent
            if parent == existing { return nil }
            existing = parent
        }
        guard let base = realPath(existing) else { return nil }
        var full = base
        for part in missing {
            if full.hasSuffix("/") { full += part } else { full += "/" + part }
        }
        return URL(fileURLWithPath: full, isDirectory: true)
    }

    private static func pathExists(_ path: String) -> Bool {
        #if canImport(Darwin)
        var info = Darwin.stat()
        #else
        var info = Glibc.stat()
        #endif
        return lstat(path, &info) == 0
    }

    private static func realPath(_ path: String) -> String? {
        guard let c = realpath(path, nil) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

    static func overlaps(_ a: URL, _ b: URL) -> Bool {
        contains(a, b) || contains(b, a)
    }

    static func contains(_ root: URL, _ child: URL) -> Bool {
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return child.path == root.path || child.path.hasPrefix(base)
    }
}

/// What the Mac panel QA process is required to wire. `GlassforcePanelQA` reads these
/// fields when it builds `AppSession` and the panel. Tests lock the safe values.
public struct PanelQARequirements: Equatable, Sendable {
    public var bundleDomain: String
    public var preferenceDomain: String
    public var registersHotKey: Bool
    public var presentsPanelOnLaunch: Bool
    public var usesLoginKeychain: Bool
    public var usesURLSession: Bool
    public var egress: EgressPolicy

    public static let current = PanelQARequirements(
        bundleDomain: ProcessIdentity.qaDomain,
        preferenceDomain: ProcessIdentity.qaDomain,
        registersHotKey: false,
        presentsPanelOnLaunch: true,
        usesLoginKeychain: false,
        usesURLSession: false,
        egress: .loopbackOnly
    )
}

/// Fixture rows for the real QA panel. Every link is loopback, so the preview host reads 127.0.0.1.
public enum LocalhostFixtures {
    public static let badge = "Localhost · 127.0.0.1 fixtures"

    public static func records(from source: [Record] = FakeData.records) -> [Record] {
        source.map { record in
            record.with(url: URL(string: "http://127.0.0.1/fixture/\(record.id)"))
        }
    }
}

public struct RefusalTransport: HTTPTransport {
    public init() {}
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw EgressError.unexpectedNetwork
    }
}

public enum BuildChannel: Sendable { case release, debug }

public enum QAActivation: Equatable, Sendable {
    case notRequested
    case ignored
    case denied
    /// Debug `--qa-foreground` only. Does not change stores.
    case presentationOnly
}

public enum ReleaseBoundary {
    public static func activation(arguments: [String], channel: BuildChannel) -> QAActivation {
        let isolated = arguments.contains("--qa-isolated")
        let foreground = arguments.contains("--qa-foreground")
        if isolated { return .denied }
        if foreground {
            return channel == .debug ? .presentationOnly : .ignored
        }
        return .notRequested
    }

    /// Mock mode is opt-in. A normal argument list does not select it.
    public static func explicitlyRequestsMock(_ arguments: [String]) -> Bool {
        arguments.contains("--mock-salesforce") || arguments.contains("--demo-walkthrough")
    }
}

public enum QACommand: Equatable, Sendable {
    case check
    case search(String)
    case stage(String)
}

public enum QACommandRunner {
    public static func run(
        arguments: [String],
        productionRoot: URL,
        records: [Record] = FakeData.records
    ) -> Result<String, IsolationError> {
        guard let rootArg = value(after: "--root", in: arguments) else { return .failure(.missingRoot) }
        let root = URL(fileURLWithPath: rootArg, isDirectory: true)
        let preferences = MemoryPreferenceStore(domain: ProcessIdentity.qaDomain)
        let secrets = InMemorySecretStore()
        let trap = TrapTransport()
        let isolation: QAIsolation
        switch QAIsolation.make(
            fileRoot: root,
            productionRoot: productionRoot,
            preferences: preferences,
            secrets: secrets,
            innerTransport: trap
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            isolation = value
        }
        guard let name = value(after: "--command", in: arguments) else { return .failure(.missingCommand) }
        switch name {
        case "check":
            return .success("identity=qa domain=\(isolation.preferences.domain) secrets=memory network=loopback")
        case "search":
            let query = value(after: "--query", in: arguments) ?? ""
            let count = RecordStore(records: records).search(query).count
            return .success("results=\(count)")
        case "stage":
            let sentence = value(after: "--sentence", in: arguments) ?? ""
            var pending = PendingWrite()
            pending.setOrg("qa-org")
            pending.stage(query: sentence, records: records)
            if let diff = pending.diff {
                return .success("diff=\(diff.recordID) before=\(diff.before)")
            }
            return .success("diff=none")
        default:
            return .failure(.missingCommand)
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }
}

private struct TrapTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw EgressError.unexpectedNetwork }
}
