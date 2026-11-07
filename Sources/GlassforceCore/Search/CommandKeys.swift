import Foundation

/// Keys the command bar handles itself. The panel maps AppKit events onto these.
public enum CommandKey: Equatable, Sendable {
    case up
    case down
    case `return`
    case escape
    case copyLink
    case commandK
}

public enum CommandEffect: Equatable, Sendable {
    case moveSelection(Int)
    case openSelected
    case copySelectedLink
    case toggleActionMenu
    case closePanel
    case closeMenu
    case moveMenu(Int)
    case runMenu
}

public struct CommandAction: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case open, copyLink }
    public let kind: Kind
    public let title: String
    public let shortcut: String
    public var id: String { kind.rawValue }

    public init(kind: Kind, title: String, shortcut: String) {
        self.kind = kind
        self.title = title
        self.shortcut = shortcut
    }

    public static func menu(for record: Record) -> [CommandAction] {
        var actions = [CommandAction(kind: .open, title: "Open", shortcut: "↩")]
        if record.url != nil {
            actions.append(CommandAction(kind: .copyLink, title: "Copy Link", shortcut: "⌘C"))
        }
        return actions
    }
}

/// What the panel shows for the selected row without opening it. Local fields only.
public struct RecordPreview: Equatable, Sendable {
    public let title: String
    public let typeName: String
    public let subtitle: String
    public let host: String?
    public let link: String?

    public init(title: String, typeName: String, subtitle: String, host: String?, link: String?) {
        self.title = title
        self.typeName = typeName
        self.subtitle = subtitle
        self.host = host
        self.link = link
    }

    public static func make(_ record: Record) -> RecordPreview {
        RecordPreview(
            title: record.title,
            typeName: record.typeLabel,
            subtitle: record.subtitle,
            host: record.url?.host,
            link: record.url?.absoluteString
        )
    }
}

public struct ActionMenuState: Equatable, Sendable {
    public var isOpen = false
    public var index = 0
    public init() {}
    public mutating func toggle() { isOpen.toggle(); if isOpen { index = 0 } }
    public mutating func close() { isOpen = false; index = 0 }
    public mutating func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        index = min(max(index + delta, 0), count - 1)
    }
    public func selected(in actions: [CommandAction]) -> CommandAction? {
        guard isOpen, actions.indices.contains(index) else { return nil }
        return actions[index]
    }
}

public enum CommandKeys: Sendable {
    /// Arrow keys move the selection, or the Cmd-K menu when it is open.
    /// Return opens the record, or runs the menu item. Escape closes the menu first, then the panel.
    public static func effect(_ key: CommandKey, menuOpen: Bool) -> CommandEffect {
        switch key {
        case .up: return menuOpen ? .moveMenu(-1) : .moveSelection(-1)
        case .down: return menuOpen ? .moveMenu(1) : .moveSelection(1)
        case .return: return menuOpen ? .runMenu : .openSelected
        case .escape: return menuOpen ? .closeMenu : .closePanel
        case .copyLink: return .copySelectedLink
        case .commandK: return .toggleActionMenu
        }
    }

    /// Link to put on the pasteboard. Nil when the field has selected query text
    /// (that copy belongs to the field) or the record has no URL.
    public static func linkText(for record: Record?, fieldSelectionLength: Int) -> String? {
        guard fieldSelectionLength == 0, let url = record?.url else { return nil }
        return url.absoluteString
    }
}
