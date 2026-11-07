import Foundation

/// The fields describe (`GET /sobjects/<Name>/describe`) tells Glassforce about one object.
public struct SObjectDescribe: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public let name: String
        public let type: String
        public let nameField: Bool
        public let autoNumber: Bool
        public init(name: String, type: String = "string", nameField: Bool = false, autoNumber: Bool = false) {
            self.name = name; self.type = type; self.nameField = nameField; self.autoNumber = autoNumber
        }
    }

    public let name: String
    public let label: String
    public let labelPlural: String
    public let custom: Bool
    public let queryable: Bool
    public let fields: [Field]

    public init(name: String, label: String, labelPlural: String, custom: Bool, queryable: Bool, fields: [Field]) {
        self.name = name; self.label = label; self.labelPlural = labelPlural
        self.custom = custom; self.queryable = queryable; self.fields = fields
    }

    public init?(json: [String: Any]) {
        guard let name = json["name"] as? String else { return nil }
        let label = json["label"] as? String ?? name
        self.init(
            name: name, label: label, labelPlural: json["labelPlural"] as? String ?? label,
            custom: json["custom"] as? Bool ?? name.hasSuffix("__c"), queryable: json["queryable"] as? Bool ?? false,
            fields: (json["fields"] as? [[String: Any]] ?? []).compactMap { f in
                guard let n = f["name"] as? String else { return nil }
                return Field(name: n, type: f["type"] as? String ?? "", nameField: f["nameField"] as? Bool ?? false,
                             autoNumber: f["autoNumber"] as? Bool ?? false)
            })
    }
}

/// One object in the search index: which fields to select and how a row becomes a `Record`.
public struct SyncObject: Sendable, Equatable {
    public let name: String
    public let label: String
    public let plural: String
    public let kind: RecordKind
    /// Selected besides Id (and LastModifiedDate when the object has it). Only what the row needs.
    public let fields: [String]
    public let titleFields: [String]
    public let subtitleFields: [String]
    public let ordersByLastModified: Bool

    public init(name: String, label: String, plural: String, kind: RecordKind, fields: [String],
                titleFields: [String], subtitleFields: [String], ordersByLastModified: Bool = true) {
        self.name = name; self.label = label; self.plural = plural; self.kind = kind; self.fields = fields
        self.titleFields = titleFields; self.subtitleFields = subtitleFields; self.ordersByLastModified = ordersByLastModified
    }

    /// Newest first, capped. `since` (a SOQL datetime literal) asks only for rows changed since the last sync.
    public func soql(cap: Int, since: String? = nil) -> String {
        var select = ["Id"]
        for f in fields + (ordersByLastModified ? ["LastModifiedDate"] : []) where !select.contains(f) { select.append(f) }
        var q = "SELECT \(select.joined(separator: ", ")) FROM \(name)"
        if ordersByLastModified {
            if let since { q += " WHERE LastModifiedDate >= \(since)" }
            q += " ORDER BY LastModifiedDate DESC"
        }
        return q + " LIMIT \(cap)"
    }

    // MARK: Built-in objects (hand-picked subtitles)

    public static let account = SyncObject(name: "Account", label: "Account", plural: "Accounts", kind: .account,
                                           fields: ["Name", "Industry", "BillingCity"], titleFields: ["Name"], subtitleFields: ["Industry", "BillingCity"])
    public static let contact = SyncObject(name: "Contact", label: "Contact", plural: "Contacts", kind: .contact,
                                           fields: ["Name", "Title", "Account.Name"], titleFields: ["Name"], subtitleFields: ["Title", "Account.Name"])
    public static let opportunity = SyncObject(name: "Opportunity", label: "Opportunity", plural: "Opportunities", kind: .opportunity,
                                               fields: ["Name", "Amount", "StageName"], titleFields: ["Name"], subtitleFields: ["Amount", "StageName"])
    public static let supportCase = SyncObject(name: "Case", label: "Case", plural: "Cases", kind: .supportCase,
                                               fields: ["CaseNumber", "Subject", "Priority"], titleFields: ["CaseNumber", "Subject"], subtitleFields: ["Priority"])
    public static let report = SyncObject(name: "Report", label: "Report", plural: "Reports", kind: .report,
                                          fields: ["Name", "FolderName"], titleFields: ["Name"], subtitleFields: ["FolderName"])

    public static let builtIns: [SyncObject] = [account, contact, opportunity, supportCase, report]
    public static func builtIn(_ name: String) -> SyncObject? { builtIns.first { $0.name == name } }

    /// API names go into SOQL and URL paths, so only plain identifiers (Account, Invoice__c, ns__Thing__c).
    public static func isSafeName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first), name.count <= 80 else { return false }
        return name.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" }
    }

    // MARK: Any other object, from describe

    static let textTypes: Set<String> = ["string", "picklist", "email", "phone", "url", "combobox"]
    /// Common fields that make a good one-line subtitle, in order of preference.
    static let subtitleCandidates = ["Company", "Title", "Subject", "Status", "StageName", "Type", "Email", "Phone", "City"]

    /// Title: the field describe marks `nameField` (Name, CaseNumber, ContractNumber…), plus Subject when that
    /// name is an auto-number. Subtitle: up to two common text fields, else the first custom text field.
    public static func generic(_ d: SObjectDescribe) -> SyncObject {
        let byName = Dictionary(d.fields.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let nameField = d.fields.first { $0.nameField } ?? byName["Name"]
        var title = nameField.map { [$0.name] } ?? []
        if let nameField, nameField.autoNumber, byName["Subject"] != nil { title.append("Subject") }
        let textual = { (n: String) in byName[n].map { textTypes.contains($0.type) } ?? false }
        var subtitle = subtitleCandidates.filter { textual($0) && !title.contains($0) }.prefix(2).map { $0 }
        if subtitle.isEmpty, let custom = d.fields.first(where: { $0.name.hasSuffix("__c") && textTypes.contains($0.type) && !title.contains($0.name) }) {
            subtitle = [custom.name]
        }
        return SyncObject(name: d.name, label: d.label, plural: d.labelPlural, kind: .other,
                          fields: title + subtitle, titleFields: title, subtitleFields: subtitle,
                          ordersByLastModified: byName["LastModifiedDate"] != nil)
    }

    // MARK: Rows → records

    /// Lightning record page on the org's lightning.force.com host, e.g.
    /// https://acme-dev-ed.develop.lightning.force.com/lightning/r/Account/001.../view (see LightningHost).
    public static func lightningURL(instanceURL: URL, object: String, id: String) -> URL {
        LightningHost.base(for: instanceURL).appendingPathComponent("lightning/r/\(object)/\(id)/view")
    }

    public static func setupShortcuts(instanceURL: URL) -> [Record] {
        [("ManageUsers", "Users", "Setup › Administration › Users"),
         ("PermSets", "Permission Sets", "Setup › Users › Permission Sets"),
         ("Flows", "Flows", "Setup › Process Automation › Flows"),
         ("ObjectManager", "Object Manager", "Setup › Object Manager")].map { page, title, subtitle in
            Record(id: "SETUP-\(page)", kind: .setup, title: title, subtitle: subtitle,
                   url: LightningHost.base(for: instanceURL).appendingPathComponent("lightning/setup/\(page)/home"))
        }
    }

    func record(from row: [String: Any], instanceURL: URL) -> Record? {
        guard let base = record(from: row) else { return nil }
        return base.with(url: Self.lightningURL(instanceURL: instanceURL, object: name, id: base.id))
    }

    func record(from row: [String: Any]) -> Record? {
        guard let id = row["Id"] as? String else { return nil }
        func value(_ path: String) -> Any? {
            // "Account.Name" reads the nested relationship object.
            path.split(separator: ".").reduce(row as Any?) { ($0 as? [String: Any])?[String($1)] }
        }
        func s(_ key: String) -> String? {
            switch value(key) {
            case let v as String: return v.isEmpty ? nil : v
            case let v as NSNumber: return Self.numberText(v)
            default: return nil
            }
        }
        func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }

        let title = join(titleFields.map(s))
        let subtitle: String
        switch kind {
        case .opportunity: subtitle = join([(value("Amount") as? Double).map(Self.currency), s("StageName")])
        case .supportCase: subtitle = join([s("Priority").map { "\($0) priority" }])
        case .setup: return nil
        default: subtitle = join(subtitleFields.map(s))
        }
        return Record(id: id, kind: kind, title: title.isEmpty ? id : title, subtitle: subtitle, objectName: name,
                      objectLabel: kind == .other ? label : nil, objectPlural: kind == .other ? plural : nil)
    }

    /// JSON booleans are NSNumbers. They are not subtitle text.
    /// macOS delivers them as CFBooleans; Linux uses objC type "c" or "B". The macOS check is unchanged.
    static func numberText(_ number: NSNumber) -> String? {
        #if os(macOS)
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        return number.stringValue
        #else
        let code = String(cString: number.objCType)
        if code == "c" || code == "B" { return nil }
        return number.stringValue
        #endif
    }

    static func currency(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "$%.1fM", value / 1_000_000) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return "$" + (formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))")
    }
}

/// What one sync reads: objects in order, whether Setup shortcuts are in, and the per-object row cap.
public struct SyncPlan: Sendable, Equatable {
    public static let defaultCap = 50_000

    public var objects: [SyncObject]
    public var includeSetup: Bool
    public var cap: Int
    /// Picked objects that couldn't be planned (no longer queryable, describe refused): reported, not synced.
    public var skipped: [SyncReport.ObjectOutcome]

    public init(objects: [SyncObject], includeSetup: Bool = true, cap: Int = SyncPlan.defaultCap, skipped: [SyncReport.ObjectOutcome] = []) {
        self.objects = objects; self.includeSetup = includeSetup; self.cap = max(1, cap); self.skipped = skipped
    }

    /// Accounts, Contacts, Opportunities, Cases, Reports and Setup: no describe calls needed.
    public static func builtIns(cap: Int = defaultCap) -> SyncPlan { SyncPlan(objects: SyncObject.builtIns, cap: cap) }
}

/// Per object, what the last sync saw, so the next one can ask only for what changed.
/// Deletions and lost access only show up in a full read, so a full read runs at least once a day,
/// and whenever the query itself (fields, cap) changes.
public struct SyncState: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var query: String
        /// Newest LastModifiedDate seen, as a SOQL literal (2026-11-04T22:55:03Z).
        public var watermark: String?
        public var lastFullSync: Date
    }

    public var objects: [String: Entry]
    public init(objects: [String: Entry] = [:]) { self.objects = objects }

    public static func fileName(for org: String) -> String {
        "syncstate-" + org.replacingOccurrences(of: ":", with: "-") + ".json"
    }

    /// Salesforce returns `2026-11-04T22:55:03.000+0000` (always UTC); SOQL wants `2026-11-04T22:55:03Z`.
    /// Seconds precision is fine because the incremental query uses `>=` and merges by Id.
    static func literal(_ value: Any?) -> String? {
        guard let s = value as? String, s.count >= 19, s.hasSuffix("+0000") || s.hasSuffix("Z") else { return nil }
        let head = String(s.prefix(19))
        guard head.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return head + "Z"
    }

    static func newest(_ rows: [[String: Any]]) -> String? {
        rows.compactMap { literal($0["LastModifiedDate"]) }.max()
    }
}
