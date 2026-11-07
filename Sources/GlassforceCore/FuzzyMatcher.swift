import Foundation

/// Text folded for matching: lowercase, no diacritics, punctuation collapsed to single spaces.
/// Stored as UTF-8 bytes with word boundaries and character-set masks precomputed, so the per-keystroke
/// loop is byte compares plus a cheap mask reject for records that can't possibly match.
struct SearchText: Sendable {
    let bytes: [UInt8]
    /// `isStart[i]`: byte `i` begins a word.
    let isStart: [Bool]
    let wordStarts: [Int]
    let wordEnds: [Int]
    /// Which characters occur (see `bit(for:)`), for the whole text and per word.
    let mask: UInt64
    let wordMasks: [UInt64]

    static let space: UInt8 = 0x20

    init(_ text: String) {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(folded.utf8.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                bytes.append(contentsOf: String(scalar).utf8)
            } else if let last = bytes.last, last != Self.space {
                bytes.append(Self.space)
            }
        }
        if bytes.last == Self.space { bytes.removeLast() }
        var isStart = [Bool](repeating: false, count: bytes.count)
        var starts: [Int] = [], ends: [Int] = [], wordMasks: [UInt64] = []
        var mask: UInt64 = 0, wordMask: UInt64 = 0
        for i in bytes.indices {
            if bytes[i] == Self.space {
                ends.append(i); wordMasks.append(wordMask); wordMask = 0
                continue
            }
            if i == 0 || bytes[i - 1] == Self.space { isStart[i] = true; starts.append(i) }
            wordMask |= Self.bit(for: bytes[i])
            mask |= Self.bit(for: bytes[i])
        }
        if !bytes.isEmpty { ends.append(bytes.count); wordMasks.append(wordMask) }
        self.bytes = bytes
        self.isStart = isStart
        self.wordStarts = starts
        self.wordEnds = ends
        self.mask = mask
        self.wordMasks = wordMasks
    }

    /// a–z → bits 0–25, 0–9 → 26–35, other (non-ASCII) bytes share bits 36–63.
    @inline(__always) static func bit(for b: UInt8) -> UInt64 {
        if b >= 0x61 && b <= 0x7A { return 1 << UInt64(b - 0x61) }
        if b >= 0x30 && b <= 0x39 { return 1 << UInt64(26 + b - 0x30) }
        return 1 << UInt64(36 + Int(b) % 28)
    }
}

/// One query word, folded the same way as the records.
struct QueryToken: Sendable {
    let bytes: [UInt8]
    let mask: UInt64

    static func tokens(_ query: String) -> [QueryToken] {
        let text = SearchText(query)
        return zip(text.wordStarts, text.wordEnds).enumerated().map { n, range in
            QueryToken(bytes: Array(text.bytes[range.0..<range.1]), mask: text.wordMasks[n])
        }
    }
}

/// Scores one query word against one field. Higher is better; 0 means no match.
///
/// Tiers, best first: whole word, word prefix (what you get while typing), acronym-style
/// subsequence that sticks to word starts and runs ("pset" → Permission Sets, "obj mgr" →
/// Object Manager), substring inside a word ("lobe" → Globex), then a bounded typo match
/// ("acmee" → Acme, "opprtunity" → Opportunity).
enum FuzzyMatcher {
    static let exactWord = 100
    static let wordPrefix = 80
    static let firstWordBonus = 10
    static let subsequenceMax = 60
    static let substring = 40
    static let typoBase = 34

    static func score(_ token: QueryToken, in field: SearchText, typos: Bool = true) -> Int {
        let m = token.bytes.count
        guard m > 0, !field.bytes.isEmpty else { return 0 }
        let missing = (token.mask & ~field.mask).nonzeroBitCount
        if missing == 0 {
            let s = token.bytes.withUnsafeBufferPointer { t in
                field.bytes.withUnsafeBufferPointer { f in exactOrPrefix(t, f, field) }
            }
            if s > 0 { return s }
            let sub = subsequence(token, in: field)
            if sub > 0 { return sub }
            if m >= 2, contains(field.bytes, token.bytes) { return substring }
        }
        guard typos, m >= 4, missing <= maxTypos(m), absentBytes(token, field.mask) <= maxTypos(m) else { return 0 }
        return typo(token, in: field)
    }

    /// Token bytes (with repeats) whose character never occurs in `mask`. Each one costs at least one
    /// edit, so it's a cheap lower bound on the typo distance ("zzzz" is 4 edits from anything z-less).
    @inline(__always) static func absentBytes(_ token: QueryToken, _ mask: UInt64) -> Int {
        if token.mask & ~mask == 0 { return 0 }
        var count = 0
        for b in token.bytes where SearchText.bit(for: b) & mask == 0 { count += 1 }
        return count
    }

    @inline(__always) static func maxTypos(_ m: Int) -> Int { m >= 8 ? 2 : 1 }

    private static func exactOrPrefix(_ t: UnsafeBufferPointer<UInt8>, _ f: UnsafeBufferPointer<UInt8>, _ field: SearchText) -> Int {
        let m = t.count
        var best = 0
        for w in 0..<field.wordStarts.count {
            let start = field.wordStarts[w], end = field.wordEnds[w]
            guard end - start >= m, f[start] == t[0] else { continue }
            var k = 1
            while k < m && f[start + k] == t[k] { k += 1 }
            guard k == m else { continue }
            var s = end - start == m ? exactWord : wordPrefix
            if w == 0 { s += firstWordBonus }
            if s > best { best = s }
        }
        return best
    }

    static func hasPrefix(_ text: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard prefix.count <= text.count else { return false }
        for k in 0..<prefix.count where text[k] != prefix[k] { return false }
        return true
    }

    static func contains(_ text: [UInt8], _ token: [UInt8]) -> Bool {
        text.withUnsafeBufferPointer { f in
            token.withUnsafeBufferPointer { t in
                let m = t.count, n = f.count
                guard m <= n else { return false }
                var i = 0
                while i <= n - m {
                    if f[i] == t[0] {
                        var k = 1
                        while k < m && f[i + k] == t[k] { k += 1 }
                        if k == m { return true }
                    }
                    i += 1
                }
                return false
            }
        }
    }

    /// Best alignment where the first character lands on a word start and every later character is
    /// the next byte (+8, a run), a later word start (+6), or further inside the same word (+1).
    /// So "pset" prefers P(ermission) S(ets) over scattered letters, and "mgr" fits "manager".
    static func subsequence(_ token: QueryToken, in field: SearchText) -> Int {
        let n = field.bytes.count, m = token.bytes.count
        guard m >= 2, m <= n else { return 0 }
        return field.bytes.withUnsafeBufferPointer { text in
            token.bytes.withUnsafeBufferPointer { q in
                field.isStart.withUnsafeBufferPointer { isStart in
                    // Cheap reject: in-order greedy containment with the first letter on a word start.
                    var k = 0
                    for j in 0..<n where text[j] == q[k] && (k > 0 || isStart[j]) { k += 1; if k == m { break } }
                    guard k == m else { return 0 }

                    let none = Int.min / 2
                    return withUnsafeTemporaryAllocation(of: Int.self, capacity: 2 * n) { buffer in
                        var prev = UnsafeMutableBufferPointer(rebasing: buffer[0..<n])
                        var cur = UnsafeMutableBufferPointer(rebasing: buffer[n..<(2 * n)])
                        for j in 0..<n { prev[j] = text[j] == q[0] && isStart[j] ? (j == 0 ? 12 : 10) : none }
                        for i in 1..<m {
                            let c = q[i]
                            var anyBefore = none   // best prev[j'] for j' <= j-2 (word-start jumps)
                            var inWord = none      // same, but only within the current word
                            for j in 0..<n {
                                if j >= 2 {
                                    let p = prev[j - 2]
                                    if p > anyBefore { anyBefore = p }
                                    if p > inWord { inWord = p }
                                }
                                if text[j] == SearchText.space { inWord = none }
                                var s = none
                                if text[j] == c {
                                    if j >= 1, prev[j - 1] > none { s = prev[j - 1] + 8 }
                                    if isStart[j], anyBefore > none, anyBefore + 6 > s { s = anyBefore + 6 }
                                    if inWord > none, inWord + 1 > s { s = inWord + 1 }
                                }
                                cur[j] = s
                            }
                            swap(&prev, &cur)
                        }
                        var raw = none
                        for j in 0..<n where prev[j] > raw { raw = prev[j] }
                        guard raw > 0 else { return 0 }
                        // ~8–10 per character for clean acronyms and runs, ~1–3 for loose skips.
                        return min(subsequenceMax, 20 + raw * 4 / m)
                    }
                }
            }
        }
    }

    /// Optimal-string-alignment distance from the token to the closest prefix of any word, within
    /// 1 edit (4–7 characters) or 2 (8+). Prefixes keep it working mid-typing ("opprtun").
    static func typo(_ token: QueryToken, in field: SearchText) -> Int {
        let m = token.bytes.count
        let k = maxTypos(m)
        let width = m + k + 1
        var bestDistance = k + 1
        token.bytes.withUnsafeBufferPointer { t in
            field.bytes.withUnsafeBufferPointer { text in
                withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * width) { rows in
                    for w in 0..<field.wordStarts.count {
                        let start = field.wordStarts[w], wordLen = field.wordEnds[w] - start
                        guard wordLen >= m - k, absentBytes(token, field.wordMasks[w]) <= k else { continue }
                        let n = min(wordLen, m + k)
                        var r0 = 0, r1 = width, r2 = 2 * width   // rows i-2, i-1, i
                        for j in 0...n { rows[r1 + j] = j }
                        var rowMin = 0
                        for i in 1...m {
                            rows[r2] = i
                            rowMin = i
                            let ti = t[i - 1]
                            for j in 1...n {
                                let cj = text[start + j - 1]
                                var d = rows[r1 + j - 1] + (ti == cj ? 0 : 1)
                                let del = rows[r1 + j] + 1, ins = rows[r2 + j - 1] + 1
                                if del < d { d = del }
                                if ins < d { d = ins }
                                if i > 1, j > 1, ti == text[start + j - 2], t[i - 2] == cj, rows[r0 + j - 2] + 1 < d {
                                    d = rows[r0 + j - 2] + 1
                                }
                                rows[r2 + j] = d
                                if d < rowMin { rowMin = d }
                            }
                            if rowMin > k { break }
                            (r0, r1, r2) = (r1, r2, r0)
                        }
                        guard rowMin <= k else { continue }
                        for j in max(0, m - k)...n where rows[r1 + j] < bestDistance { bestDistance = rows[r1 + j] }
                        if bestDistance <= 1 { break }
                    }
                }
            }
        }
        guard bestDistance <= k else { return 0 }
        return typoBase - (bestDistance - 1) * 8
    }
}
