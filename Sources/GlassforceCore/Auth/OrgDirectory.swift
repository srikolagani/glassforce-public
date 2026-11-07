import Foundation

public enum OrgStatus: String, Codable, Sendable {
    case connected
    case needsSignIn
}

/// Non-secret facts about a connected org. Stored in Application Support, never tokens.
public struct OrgProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: String              // "<orgId>:<userId>"
    public var orgName: String
    public var username: String
    public var label: String
    public var kind: OrgKind
    public var loginURL: URL
    public var instanceURL: URL
    public var isDefault: Bool
    public var status: OrgStatus
    public var lastSync: Date?
    public var recordCount: Int

    public init(id: String, orgName: String, username: String, label: String? = nil, kind: OrgKind,
                loginURL: URL, instanceURL: URL, isDefault: Bool = false, status: OrgStatus = .connected,
                lastSync: Date? = nil, recordCount: Int = 0) {
        self.id = id
        self.orgName = orgName
        self.username = username
        self.label = label ?? orgName
        self.kind = kind
        self.loginURL = loginURL
        self.instanceURL = instanceURL
        self.isDefault = isDefault
        self.status = status
        self.lastSync = lastSync
        self.recordCount = recordCount
    }
}

public struct OrgDirectory: Codable, Sendable, Equatable {
    public private(set) var orgs: [OrgProfile] = []

    public init(orgs: [OrgProfile] = []) {
        self.orgs = orgs
        normalizeDefault()
    }

    public var defaultOrg: OrgProfile? { orgs.first(where: \.isDefault) }
    public var isEmpty: Bool { orgs.isEmpty }

    public func org(_ id: String) -> OrgProfile? { orgs.first { $0.id == id } }

    /// Adds or updates an org. The first org becomes the default.
    public mutating func upsert(_ profile: OrgProfile) {
        var profile = profile
        if let index = orgs.firstIndex(where: { $0.id == profile.id }) {
            profile.isDefault = orgs[index].isDefault || profile.isDefault
            profile.label = orgs[index].label
            orgs[index] = profile
        } else {
            orgs.append(profile)
        }
        if profile.isDefault { setDefault(profile.id) } else { normalizeDefault() }
    }

    public mutating func setDefault(_ id: String) {
        guard orgs.contains(where: { $0.id == id }) else { return }
        for index in orgs.indices { orgs[index].isDefault = orgs[index].id == id }
    }

    public mutating func setStatus(_ status: OrgStatus, for id: String) {
        guard let index = orgs.firstIndex(where: { $0.id == id }) else { return }
        orgs[index].status = status
    }

    public mutating func recordSync(_ id: String, count: Int, at date: Date) {
        guard let index = orgs.firstIndex(where: { $0.id == id }) else { return }
        orgs[index].recordCount = count
        orgs[index].lastSync = date
        orgs[index].status = .connected
    }

    public mutating func remove(_ id: String) {
        orgs.removeAll { $0.id == id }
        normalizeDefault()
    }

    private mutating func normalizeDefault() {
        let defaults = orgs.indices.filter { orgs[$0].isDefault }
        if defaults.isEmpty, !orgs.isEmpty { orgs[0].isDefault = true }
        for extra in defaults.dropFirst() { orgs[extra].isDefault = false }
    }
}

/// JSON files under ~/Library/Application Support/Glassforce (or a test directory).
public struct LocalStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func applicationSupport(subfolder: String = "Glassforce") -> LocalStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return LocalStore(directory: base.appendingPathComponent(subfolder, isDirectory: true))
    }

    public func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    public func save<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    public func loadDirectory() -> OrgDirectory { load(OrgDirectory.self, from: "orgs.json") ?? OrgDirectory() }
    public func saveDirectory(_ directory: OrgDirectory) throws { try save(directory, to: "orgs.json") }

    public static func cacheName(for org: String) -> String {
        "cache-" + org.replacingOccurrences(of: ":", with: "-") + ".json"
    }
}
