import Foundation
import Testing
@testable import GlassforceCore

/// Latency budget for one keystroke: p95 under 50 ms over a 10k-record org, measured on an optimized
/// build (the app ships `-c release`): `scripts/bench.sh`. Unoptimized `swift test` builds are ~50–100x
/// slower, so there the test only guards against a pathological regression.
@Suite("Search benchmark")
struct SearchBenchmarkTests {
    /// Deterministic synthetic org: company names, people, deals, cases, reports and setup pages.
    static func syntheticRecords(count: Int = 10_000) -> [Record] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let words = ["Acme", "Globex", "Initech", "Umbrella", "Stark", "Wayne", "Hooli", "Vandelay", "Soylent",
                     "Cyberdyne", "Tyrell", "Wonka", "Gringotts", "Oscorp", "Pied", "Piper", "Monarch", "Aperture",
                     "Nakatomi", "Massive", "Dynamic", "Blue", "Sun", "North", "Pacific", "Atlas", "Zenith", "Quantum"]
        let suffixes = ["Corporation", "Industries", "Holdings", "Labs", "Group", "Systems", "Logistics", "Health"]
        let first = ["Maya", "Jordan", "Priya", "Elena", "Sam", "Alex", "Chen", "Fatima", "Diego", "Noor", "Olga", "Kenji"]
        let last = ["Patel", "Lee", "Raman", "Ortiz", "Nguyen", "Smith", "García", "Müller", "Okafor", "Kowalski"]
        let topics = ["Renewal", "Expansion", "Pilot", "Migration", "Upsell", "Rollout", "Platform", "Analytics"]
        let issues = ["SSO login failures", "Invoice PDF missing", "Data export timing out", "Sync error",
                      "Password reset loop", "Report not loading", "Duplicate contacts", "API limit reached"]
        let reportNames = ["Pipeline by Stage", "Open Cases by Priority", "Milestone Progress by User",
                           "Sample Report: Orchestration Runs", "Exercise Completion Status", "Win Rate by Rep"]
        var records = SyncObject.setupShortcuts(instanceURL: URL(string: "https://bench.my.salesforce.com")!)
        while records.count < count {
            let n = records.count
            let company = "\(words[next(words.count)]) \(words[next(words.count)]) \(suffixes[next(suffixes.count)])"
            switch next(5) {
            case 0: records.append(Record(id: "001\(n)", kind: .account, title: company, subtitle: "Manufacturing · Austin"))
            case 1: records.append(Record(id: "003\(n)", kind: .contact, title: "\(first[next(first.count)]) \(last[next(last.count)])", subtitle: "VP Sales · \(company)"))
            case 2: records.append(Record(id: "006\(n)", kind: .opportunity, title: "\(company) · \(topics[next(topics.count)]) FY\(26 + next(3))", subtitle: "$\(next(900))k · Proposal"))
            case 3: records.append(Record(id: "500\(n)", kind: .supportCase, title: "\(10_000_000 + n) · \(issues[next(issues.count)])", subtitle: "High priority · \(company)"))
            default: records.append(Record(id: "00O\(n)", kind: .report, title: "\(reportNames[next(reportNames.count)]) \(n % 97)", subtitle: "Sales Reports"))
            }
        }
        return records
    }

    @Test func p95UnderFiftyMillisecondsOnTenThousandRecords() {
        let records = Self.syntheticRecords()
        let indexStart = DispatchTime.now().uptimeNanoseconds
        let store = RecordStore(records: records)
        let indexMs = Double(DispatchTime.now().uptimeNanoseconds - indexStart) / 1e6

        // Every keystroke of a few realistic queries, including typos and misses (misses are the
        // slow path: every record runs through every tier).
        let queries = ["acme corporation", "acmee", "opprtunity", "perm st", "pset", "usr", "pipline by stage",
                       "maya patel", "müller", "sso login", "orchestraton", "zzzz qqqq"]
        let keystrokes = queries.flatMap { q in (1...q.count).map { String(q.prefix($0)) } }
        var samples: [Double] = []
        var slowest: [(String, Double)] = []
        for _ in 0..<3 {
            for query in keystrokes {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = store.search(query, limit: 80)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                samples.append(ms)
                slowest.append((query, ms))
            }
        }
        slowest.sort { $0.1 > $1.1 }
        print("slowest: " + slowest.prefix(6).map { String(format: "%@ %.1fms", $0.0, $0.1) }.joined(separator: ", "))
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        let worst = samples.last!
        #if DEBUG
        let build = "debug"
        #else
        let build = "optimized"
        #endif
        print(String(format: "search benchmark (%@): %d records, %d searches, index %.1f ms, p50 %.2f ms, p95 %.2f ms, max %.2f ms",
                     build, records.count, samples.count, indexMs, p50, p95, worst))
        #expect(records.count == 10_000)
        #if DEBUG
        let budget = 1_000.0
        #else
        let budget = 50.0
        #endif
        #expect(p95 < budget)
        // Sanity: the synthetic set really matches things.
        #expect(store.search("acmee").first?.title.hasPrefix("Acme") == true)
        #expect(store.search("perm st").first?.id == "SETUP-PermSets")
    }
}
