import Foundation

/// One entry of describeGlobal (`GET /services/data/vXX.X/sobjects`): just the flags Glassforce filters on.
public struct SObjectSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let label: String
    public let labelPlural: String
    public let custom: Bool
    public let queryable: Bool
    public let searchable: Bool
    public let deprecatedAndHidden: Bool
    public let customSetting: Bool
    /// Has page layouts, i.e. a Lightning record page to open (/lightning/r/<Object>/<Id>/view).
    public let layoutable: Bool
    public let keyPrefix: String?
    public let associateEntityType: String?

    public init(name: String, label: String, labelPlural: String? = nil, custom: Bool = false, queryable: Bool = true,
                searchable: Bool = true, deprecatedAndHidden: Bool = false, customSetting: Bool = false, layoutable: Bool = true,
                keyPrefix: String? = "a00", associateEntityType: String? = nil) {
        self.name = name; self.label = label; self.labelPlural = labelPlural ?? label + "s"
        self.custom = custom; self.queryable = queryable; self.searchable = searchable
        self.deprecatedAndHidden = deprecatedAndHidden; self.customSetting = customSetting; self.layoutable = layoutable
        self.keyPrefix = keyPrefix; self.associateEntityType = associateEntityType
    }

    enum CodingKeys: String, CodingKey {
        case name, label, labelPlural, custom, queryable, searchable, deprecatedAndHidden, customSetting, layoutable, keyPrefix, associateEntityType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? name
        labelPlural = try c.decodeIfPresent(String.self, forKey: .labelPlural) ?? label
        custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? name.hasSuffix("__c")
        queryable = try c.decodeIfPresent(Bool.self, forKey: .queryable) ?? false
        searchable = try c.decodeIfPresent(Bool.self, forKey: .searchable) ?? false
        deprecatedAndHidden = try c.decodeIfPresent(Bool.self, forKey: .deprecatedAndHidden) ?? false
        customSetting = try c.decodeIfPresent(Bool.self, forKey: .customSetting) ?? false
        layoutable = try c.decodeIfPresent(Bool.self, forKey: .layoutable) ?? true
        keyPrefix = try c.decodeIfPresent(String.self, forKey: .keyPrefix)
        associateEntityType = try c.decodeIfPresent(String.self, forKey: .associateEntityType)
    }
}

/// Which org objects the Settings picker offers.
public enum ObjectCatalog {
    /// Companion/system objects Salesforce generates for real objects: field history, sharing rows, Chatter
    /// feeds, change events, tags; plus custom metadata, platform events, big objects and history-tracking tables.
    static let systemSuffixes = ["History", "Share", "Feed", "ChangeEvent", "Tag", "__mdt", "__e", "__b", "__hd"]

    /// Objects a person would search for: queryable, searchable, not deprecated/hidden, not a custom setting,
    /// not a companion table (associateEntityType or a system suffix), with a record page to open (a key
    /// prefix and page layouts; this drops metadata-ish objects like FieldDefinition, Profile, RecordType, ListView).
    /// Report is left out because Settings always offers it as its own row. Sorted by label.
    public static func searchObjects(_ all: [SObjectSummary]) -> [SObjectSummary] {
        all.filter { o in
            o.queryable && o.searchable && o.layoutable && !o.deprecatedAndHidden && !o.customSetting
                && o.associateEntityType == nil && o.keyPrefix != nil
                && o.name != "Report"
                && !systemSuffixes.contains { o.name.hasSuffix($0) }
                && SyncObject.isSafeName(o.name)
        }
        .sorted { ($0.label.localizedLowercase, $0.name) < ($1.label.localizedLowercase, $1.name) }
    }
}

/// Which objects one org syncs into search. Stored per org id (the 00D…), so every user of that org on this Mac shares it.
public struct ObjectSelection: Codable, Equatable, Sendable {
    /// Not an sObject: the built-in Setup shortcuts row.
    public static let setup = "glassforce:Setup"
    public static let defaultNames: [String] = ["Account", "Contact", "Opportunity", "Case", "Lead", "Report", setup]
    public static let defaults = ObjectSelection(enabled: defaultNames)

    public private(set) var enabled: [String]

    public init(enabled: some Sequence<String>) { self.enabled = Array(Set(enabled)).sorted() }

    public func isEnabled(_ name: String) -> Bool { enabled.contains(name) }

    public mutating func set(_ name: String, enabled on: Bool) {
        var names = Set(enabled)
        if on { names.insert(name) } else { names.remove(name) }
        enabled = names.sorted()
    }
}

/// `search-objects-<orgId>.json` next to the org directory. Missing file = the defaults.
public struct ObjectSelectionStore: Sendable {
    public let local: LocalStore
    public init(local: LocalStore) { self.local = local }

    /// "00D…:005…" (the org directory key) → "00D…".
    public static func orgID(fromKey key: String) -> String { String(key.split(separator: ":").first ?? Substring(key)) }
    public static func fileName(orgID: String) -> String { "search-objects-\(orgID).json" }

    public func load(orgID: String) -> ObjectSelection { local.load(ObjectSelection.self, from: Self.fileName(orgID: orgID)) ?? .defaults }
    public func hasSaved(orgID: String) -> Bool { local.load(ObjectSelection.self, from: Self.fileName(orgID: orgID)) != nil }
    public func save(_ selection: ObjectSelection, orgID: String) throws { try local.save(selection, to: Self.fileName(orgID: orgID)) }
}
