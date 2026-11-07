import Foundation

/// Git facts written into a newly built Glassforce.app.
/// An empty `sha` means the build could not read a real commit. Callers must not fill one in.
public struct SourceProvenance: Equatable, Sendable {
    public var sha: String
    public var dirty: Dirty

    public enum Dirty: String, Equatable, Sendable {
        case clean = "false"
        case dirty = "true"
        case unknown
    }

    public init(sha: String, dirty: Dirty) {
        self.sha = sha
        self.dirty = dirty
    }

    /// Accepts only a full lowercase git SHA. Anything else becomes an empty SHA and `unknown`,
    /// which is the honest "we do not know" record. This does not look at the filesystem.
    public static func resolve(head: String?, porcelain: String?, statusFailed: Bool = false) -> SourceProvenance {
        let trimmed = head?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.lowercaseLetters.contains($0) || ("0"..."9").contains(Character($0))) }),
              trimmed.count == 40 else {
            return SourceProvenance(sha: "", dirty: .unknown)
        }
        if statusFailed {
            return SourceProvenance(sha: trimmed, dirty: .unknown)
        }
        let dirty: Dirty = (porcelain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clean : .dirty
        return SourceProvenance(sha: trimmed, dirty: dirty)
    }

    /// Parses the two lines printed by `scripts/source-provenance.sh`.
    /// A SHA that is not 40 lowercase hex is dropped, even if the script printed one.
    public static func parse(scriptOutput: String) -> SourceProvenance {
        var sha = ""
        var dirty = ""
        for line in scriptOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("GlassforceSourceSHA ") || text == "GlassforceSourceSHA" {
                sha = String(text.dropFirst("GlassforceSourceSHA ".count)).trimmingCharacters(in: .whitespaces)
                if text == "GlassforceSourceSHA" { sha = "" }
            } else if text.hasPrefix("GlassforceSourceDirty ") {
                dirty = String(text.dropFirst("GlassforceSourceDirty ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let state: Dirty
        switch dirty {
        case Dirty.clean.rawValue: state = .clean
        case Dirty.dirty.rawValue: state = .dirty
        default: state = .unknown
        }
        let resolved = resolve(head: sha, porcelain: state == .dirty ? "M file" : "", statusFailed: state == .unknown && !sha.isEmpty)
        if state == .unknown && resolved.sha.isEmpty {
            return SourceProvenance(sha: "", dirty: .unknown)
        }
        if resolved.sha.isEmpty { return SourceProvenance(sha: "", dirty: .unknown) }
        return SourceProvenance(sha: resolved.sha, dirty: state == .unknown ? .unknown : state)
    }
}
