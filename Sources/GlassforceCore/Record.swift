import Foundation

/// The kinds of Salesforce things the command bar can surface.
/// Declaration order is the display order of result groups.
public enum RecordKind: String, CaseIterable, Sendable, Hashable, Codable {
    case account
    case contact
    case opportunity
    case supportCase = "case"
    /// Any other object picked in Settings (Lead, Campaign, custom `__c` objects…). Its labels live on the record.
    case other
    case report
    case setup

    public var displayName: String {
        switch self {
        case .account: "Accounts"
        case .contact: "Contacts"
        case .opportunity: "Opportunities"
        case .supportCase: "Cases"
        case .other: "Records"
        case .report: "Reports"
        case .setup: "Setup"
        }
    }

    public var singularName: String {
        switch self {
        case .account: "Account"
        case .contact: "Contact"
        case .opportunity: "Opportunity"
        case .supportCase: "Case"
        case .other: "Record"
        case .report: "Report"
        case .setup: "Setup"
        }
    }

    /// SF Symbol shown in the row's icon tile.
    public var symbolName: String {
        switch self {
        case .account: "building.2.fill"
        case .contact: "person.fill"
        case .opportunity: "dollarsign"
        case .supportCase: "lifepreserver.fill"
        case .other: "square.stack.3d.up.fill"
        case .report: "chart.bar.xaxis"
        case .setup: "gearshape.fill"
        }
    }

    var sortIndex: Int { Self.allCases.firstIndex(of: self)! }
}

public struct Record: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let kind: RecordKind
    public let title: String
    public let subtitle: String
    /// Where Return takes you (the record's Lightning page). Nil for built-in fake data.
    public let url: URL?
    /// Salesforce API name of the record's object ("Account", "Lead", "Invoice__c"). Nil for setup pages and fake data.
    public let objectName: String?
    /// Object labels from describe, for `.other` records ("Lead" / "Leads").
    public let objectLabel: String?
    public let objectPlural: String?

    public init(id: String, kind: RecordKind, title: String, subtitle: String, url: URL? = nil,
                objectName: String? = nil, objectLabel: String? = nil, objectPlural: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.objectName = objectName
        self.objectLabel = objectLabel
        self.objectPlural = objectPlural
    }

    public func with(url: URL?) -> Record {
        Record(id: id, kind: kind, title: title, subtitle: subtitle, url: url,
               objectName: objectName, objectLabel: objectLabel, objectPlural: objectPlural)
    }

    /// Results are grouped by this: the kind, or for `.other` the object itself (Leads apart from Invoices).
    public var groupKey: String { kind == .other ? "other:\(objectName ?? "")" : kind.rawValue }
    /// "Lead", "Invoice", "Account".
    public var typeLabel: String { kind == .other ? (objectLabel ?? objectName ?? kind.singularName) : kind.singularName }
    /// "Leads", "Invoices", "Accounts".
    public var groupTitle: String { kind == .other ? (objectPlural ?? objectLabel ?? objectName ?? kind.displayName) : kind.displayName }
}

public struct RecordGroup: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let kind: RecordKind
    public let title: String
    public let records: [Record]
}
