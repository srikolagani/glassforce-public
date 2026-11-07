import Foundation

/// A natural-language change that has not been sent anywhere.
public struct WriteCommand: Equatable, Sendable {
    public var hint: String
    public var stage: String
    public var field: String
    public var fieldLabel: String
    public var object: String

    public init(hint: String, stage: String, field: String = "StageName", fieldLabel: String = "Stage", object: String = "Opportunity") {
        self.hint = hint
        self.stage = stage
        self.field = field
        self.fieldLabel = fieldLabel
        self.object = object
    }
}

public struct WriteDiff: Equatable, Sendable {
    public var recordID: String
    public var recordTitle: String
    public var object: String
    public var field: String
    public var fieldLabel: String
    public var before: String
    public var after: String

    public init(recordID: String, recordTitle: String, object: String, field: String, fieldLabel: String, before: String, after: String) {
        self.recordID = recordID
        self.recordTitle = recordTitle
        self.object = object
        self.field = field
        self.fieldLabel = fieldLabel
        self.before = before
        self.after = after
    }
}

/// One opportunity the typed hint matched. Not a write.
public struct WriteChoice: Equatable, Sendable {
    public var recordID: String
    public var recordTitle: String
    public var before: String

    public init(recordID: String, recordTitle: String, before: String) {
        self.recordID = recordID
        self.recordTitle = recordTitle
        self.before = before
    }
}

/// The only value a writer accepts. `make` returns nil until the caller has confirmed
/// one org, one record, and a before-value that is actually changing.
public struct ConfirmedWrite: Equatable, Sendable {
    public let orgID: String
    public let recordID: String
    public let before: String
    public let diff: WriteDiff

    public static func make(orgID: String, diff: WriteDiff, confirmed: Bool) -> ConfirmedWrite? {
        let org = orgID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard confirmed, !org.isEmpty, !diff.recordID.isEmpty else { return nil }
        guard diff.before != diff.after, diff.before != "—" else { return nil }
        return ConfirmedWrite(orgID: org, recordID: diff.recordID, before: diff.before, diff: diff)
    }
}

/// Refuses a confirmed intent that no longer matches the org and record on screen.
public enum WriteGuard {
    public static func allowsSend(_ write: ConfirmedWrite, orgID: String, record: Record?) -> Bool {
        guard write.orgID == orgID, let record, record.id == write.recordID else { return false }
        let stage = WritePlanner.currentStage(record.subtitle)
        return stage == write.before && stage != write.diff.after
    }
}

public struct PendingWrite: Equatable, Sendable {
    public private(set) var diff: WriteDiff?
    /// Set when the hint matches more than one deal. Confirm stays unavailable until `choose`.
    public private(set) var choices: [WriteChoice] = []
    /// Why nothing will be written. Nil when a unique change is ready to confirm.
    public private(set) var refusal: String?
    private var orgID = ""
    private var command: WriteCommand?

    public init() {}

    /// Drops a staged change when the signed-in org changes. Does not write.
    public mutating func setOrg(_ id: String) {
        guard id != orgID else { return }
        orgID = id
        clearPlan()
    }

    /// Parses the sentence and, only when one deal matches, stages that diff. Does not write.
    /// Several matches stay as `choices` so the top fuzzy hit is never confirmed by default.
    public mutating func stage(query: String, records: [Record]) {
        guard let command = WritePlanner.parse(query) else { clearPlan(); return }
        self.command = command
        let matches = WritePlanner.matches(command, records: records)
        if matches.isEmpty {
            clearPlan()
            return
        }
        if matches.count > 1 {
            diff = nil
            choices = matches
            refusal = "More than one deal matches “\(command.hint)”. Pick one. Nothing is saved until you confirm that deal."
            return
        }
        bind(matches[0], command: command, keepChoices: false)
    }

    /// Binds a deal the user picked from `choices`. Ignores any other id.
    public mutating func choose(recordID: String, records: [Record]) {
        guard let command, choices.contains(where: { $0.recordID == recordID }) else { return }
        guard let record = records.first(where: { $0.id == recordID && ($0.kind == .opportunity || $0.objectName == "Opportunity") }) else { return }
        let choice = WriteChoice(recordID: record.id, recordTitle: record.title, before: WritePlanner.currentStage(record.subtitle))
        bind(choice, command: command, keepChoices: true)
    }

    /// Drops a bound record when the highlighted row is no longer that record.
    public mutating func noteSelection(_ recordID: String?) {
        guard let diff, diff.recordID != recordID else { return }
        self.diff = nil
    }

    public mutating func cancel() { clearPlan() }

    public func confirmed() -> ConfirmedWrite? {
        guard let diff else { return nil }
        return ConfirmedWrite.make(orgID: orgID, diff: diff, confirmed: true)
    }

    private mutating func bind(_ choice: WriteChoice, command: WriteCommand, keepChoices: Bool) {
        if choice.before == "—" {
            diff = nil
            if !keepChoices { choices = [] }
            refusal = "Glassforce can't see the current \(command.fieldLabel) for \(choice.recordTitle). Nothing was changed."
            return
        }
        if choice.before == command.stage {
            diff = nil
            if !keepChoices { choices = [] }
            refusal = "\(choice.recordTitle) is already \(command.stage). Nothing to change."
            return
        }
        diff = WriteDiff(
            recordID: choice.recordID,
            recordTitle: choice.recordTitle,
            object: command.object,
            field: command.field,
            fieldLabel: command.fieldLabel,
            before: choice.before,
            after: command.stage
        )
        if !keepChoices { choices = [] }
        refusal = nil
    }

    private mutating func clearPlan() {
        diff = nil
        choices = []
        refusal = nil
        command = nil
    }
}

public enum WritePlanner {
    public static func parse(_ text: String) -> WriteCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parts = capture(#"^move\s+(.+?)\s+(?:deal|opportunity|opp)\s+to\s+(.+)$"#, trimmed) {
            return WriteCommand(hint: parts[0], stage: stageName(parts[1]))
        }
        if let parts = capture(#"^close\s+(.+?)\s+(?:deal|opportunity|opp)\s+as\s+(won|lost)$"#, trimmed) {
            let stage = parts[1].lowercased() == "won" ? "Closed Won" : "Closed Lost"
            return WriteCommand(hint: parts[0], stage: stage)
        }
        return nil
    }

    /// Every opportunity the hint matches, best first. Callers must not take `.first` when more than one comes back.
    public static func matches(_ command: WriteCommand, records: [Record]) -> [WriteChoice] {
        let opps = records.filter { $0.kind == .opportunity || $0.objectName == "Opportunity" }
        return RecordStore(records: opps).search(command.hint).map { record in
            WriteChoice(recordID: record.id, recordTitle: record.title, before: currentStage(record.subtitle))
        }
    }

    /// A diff only when the hint names one opportunity and its stage would change.
    public static func diff(_ command: WriteCommand, records: [Record]) -> WriteDiff? {
        let found = matches(command, records: records)
        guard found.count == 1, let only = found.first, only.before != command.stage, only.before != "—" else { return nil }
        return WriteDiff(
            recordID: only.recordID,
            recordTitle: only.recordTitle,
            object: command.object,
            field: command.field,
            fieldLabel: command.fieldLabel,
            before: only.before,
            after: command.stage
        )
    }

    static func stageName(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "closed won", "won": return "Closed Won"
        case "closed lost", "lost": return "Closed Lost"
        default:
            return raw.split(separator: " ").map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst().lowercased()
            }.joined(separator: " ")
        }
    }

    static func currentStage(_ subtitle: String) -> String {
        let parts = subtitle.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let stages = parts.filter { part in
            if part.hasPrefix("$") { return false }
            // Fake rows put the close date last ("Closes Dec 12"). That is not StageName.
            if part.lowercased().hasPrefix("closes") { return false }
            return true
        }
        return stages.first ?? "—"
    }

    private static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        var parts: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let part = Range(match.range(at: index), in: text) else { return nil }
            parts.append(String(text[part]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.allSatisfy { !$0.isEmpty } ? parts : nil
    }
}
