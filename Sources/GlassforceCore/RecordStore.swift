import Foundation

/// In-memory search index over one org's records. Text is folded once at load; each keystroke
/// scores every record with `FuzzyMatcher` (a few ms for 10k records, see SearchBenchmarkTests).
public struct RecordStore: Sendable {
    public let records: [Record]
    private let titles: [SearchText]
    private let subtitles: [SearchText]
    /// Object names per result group ("Accounts Account", "Leads Lead"), indexed by group rank.
    private let groupTexts: [SearchText]
    /// Each record's group rank: kind order first, then object label for `.other` groups.
    private let groupRank: [Int]

    public init(records: [Record] = FakeData.records) {
        self.records = records
        self.titles = records.map { SearchText($0.title) }
        self.subtitles = records.map { SearchText($0.subtitle) }
        var firsts: [String: Record] = [:]
        for record in records where firsts[record.groupKey] == nil { firsts[record.groupKey] = record }
        let ordered = firsts.values.sorted { ($0.kind.sortIndex, $0.groupTitle, $0.groupKey) < ($1.kind.sortIndex, $1.groupTitle, $1.groupKey) }
        var rank: [String: Int] = [:]
        for (i, r) in ordered.enumerated() { rank[r.groupKey] = i }
        self.groupTexts = ordered.map { SearchText("\($0.groupTitle) \($0.typeLabel)") }
        self.groupRank = records.map { rank[$0.groupKey]! }
    }

    /// Fuzzy search, Spotlight-style.
    ///
    /// - Every query word has to match the title, the subtitle, or the object name ("opp", "reports").
    /// - Title matches beat subtitle matches; whole words beat prefixes, prefixes beat substrings,
    ///   acronym-like subsequences beat typos. Typos are tolerated in titles and object names only.
    /// - `boosts` (record id → small integer, e.g. how often it was opened) nudges ranking.
    /// - Groups come back best group first; inside a group, best record first.
    ///
    /// An empty or whitespace-only query returns everything grouped in kind order.
    public func search(_ query: String, limit: Int? = nil, boosts: [String: Int] = [:]) -> [Record] {
        let tokens = QueryToken.tokens(query)
        if tokens.isEmpty {
            let all = orderedByGroup()
            return limit.map { Array(all.prefix($0)) } ?? all
        }
        let folded = SearchText(query).bytes

        var scored: [(index: Int, score: Int)] = []
        for i in records.indices {
            var total = 0
            var matchedAll = true
            for token in tokens {
                let title = FuzzyMatcher.score(token, in: titles[i])
                var best = title * 10
                if title < FuzzyMatcher.exactWord {
                    best = max(best, FuzzyMatcher.score(token, in: subtitles[i], typos: false) * 4)
                    // Object names ("Setup", "Cases") are short and shared by every record of a kind, so
                    // only guess typos there for longer words ("opprtunity"), or "pset" pulls in all Setup.
                    best = max(best, FuzzyMatcher.score(token, in: groupTexts[groupRank[i]], typos: token.bytes.count >= 6) * 7)
                }
                if best == 0 { matchedAll = false; break }
                total += best
            }
            guard matchedAll else { continue }
            // Whole query equals the title, or starts it on a word boundary: "pipeline by stage", "acme corp".
            let title = titles[i].bytes
            if title == folded { total += 600 }
            else if FuzzyMatcher.hasPrefix(title, folded), title[folded.count] == SearchText.space { total += 300 }
            // Shorter titles win ties ("Users" over "Users by Role"), lightly.
            total -= min(titles[i].bytes.count, 60)
            total += min(boosts[records[i].id] ?? 0, 10) * 25
            scored.append((i, total))
        }

        // Rank groups by their best record, then records inside each group.
        var groupBest = [Int](repeating: .min, count: groupTexts.count)
        for entry in scored {
            let g = groupRank[entry.index]
            groupBest[g] = max(groupBest[g], entry.score)
        }
        scored.sort { lhs, rhs in
            let lg = groupRank[lhs.index], rg = groupRank[rhs.index]
            if lg != rg {
                let lb = groupBest[lg], rb = groupBest[rg]
                return lb != rb ? lb > rb : lg < rg
            }
            return lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index
        }
        let ranked = scored.map { records[$0.index] }
        return limit.map { Array(ranked.prefix($0)) } ?? ranked
    }

    /// Groups already-ordered results by kind (and object, for `.other`), keeping the order in which groups first appear.
    public static func grouped(_ results: [Record]) -> [RecordGroup] {
        var order: [String] = []
        var rows: [String: [Record]] = [:]
        for record in results {
            if rows[record.groupKey] == nil { order.append(record.groupKey) }
            rows[record.groupKey, default: []].append(record)
        }
        return order.map { key in
            let first = rows[key]![0]
            return RecordGroup(key: key, kind: first.kind, title: first.groupTitle, records: rows[key]!)
        }
    }

    func orderedByGroup() -> [Record] {
        records.indices
            .sorted { (groupRank[$0], $0) < (groupRank[$1], $1) }
            .map { records[$0] }
    }
}

/// Keyboard selection over a flat result list. Clamps at both ends.
public enum Selection {
    public static func move(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }
}
