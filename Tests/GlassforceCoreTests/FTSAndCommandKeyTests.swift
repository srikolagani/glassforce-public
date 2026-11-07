import Foundation
import Testing
@testable import GlassforceCore

@Suite("FTS5 cache and command keys")
struct FTSAndCommandKeyTests {
    func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gf-fts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func sample() -> [Record] {
        [
            Record(id: "001", kind: .account, title: "Acme Corporation", subtitle: "Manufacturing",
                   url: URL(string: "https://acme.lightning.force.com/lightning/r/Account/001/view"), objectName: "Account"),
            Record(id: "003", kind: .contact, title: "Maya Patel", subtitle: "VP Sales · Acme",
                   url: URL(string: "https://acme.lightning.force.com/lightning/r/Contact/003/view"), objectName: "Contact"),
            Record(id: "006", kind: .opportunity, title: "Acme · Platform Renewal", subtitle: "$240,000 · Negotiation",
                   url: URL(string: "https://acme.lightning.force.com/lightning/r/Opportunity/006/view"), objectName: "Opportunity"),
            Record(id: "500", kind: .supportCase, title: "00001042 · SSO login failures", subtitle: "High priority",
                   url: URL(string: "https://acme.lightning.force.com/lightning/r/Case/500/view"), objectName: "Case"),
            Record(id: "00O", kind: .report, title: "Pipeline by Stage", subtitle: "Sales Reports",
                   url: URL(string: "https://acme.lightning.force.com/lightning/r/Report/00O/view"), objectName: "Report"),
            Record(id: "SETUP-PermSets", kind: .setup, title: "Permission Sets", subtitle: "Setup › Users › Permission Sets",
                   url: URL(string: "https://acme.lightning.force.com/lightning/setup/PermSets/home")),
        ]
    }

    @Test func roundTripMatchesFuzzySearch() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FTSRecordCache(directory: dir, orgID: "00DORG:005USER")
        let records = sample()
        try cache.replace(records)
        let again = try FTSRecordCache(directory: dir, orgID: "00DORG:005USER")
        let loaded = try again.records()
        #expect(loaded.map(\.id) == records.map(\.id))
        #expect(loaded.map(\.title) == records.map(\.title))
        #expect(loaded.map(\.url) == records.map(\.url))
        let store = RecordStore(records: records)
        for query in ["acme", "acmee", "maya", "pset", "pipeline", "sso"] {
            #expect(try again.search(query).map(\.id) == store.search(query).map(\.id))
        }
    }

    @Test func ftsPrefixHitsAcmeAndNotATypo() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FTSRecordCache(directory: dir, orgID: "00D1")
        try cache.replace(sample())
        let ids = try cache.matchingIDs(prefix: "acme")
        #expect(ids.contains("001"))
        #expect(ids.contains("006"))
        #expect(try cache.matchingIDs(prefix: "acmee").isEmpty)
        // Fuzzy search still fixes the typo from the same cache.
        #expect(try cache.search("acmee").first?.id == "001")
    }

    @Test func refusesAnotherOrgsFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FTSRecordCache(directory: dir, orgID: "00DAAA")
        try cache.replace(sample())
        #expect(throws: FTSRecordCacheError.wrongOrg(expected: "00DBBB", found: "00DAAA")) {
            _ = try FTSRecordCache(file: cache.fileURL, orgID: "00DBBB")
        }
    }

    @Test func fileNameIsBoundToOrgID() {
        let dir = URL(fileURLWithPath: "/tmp")
        #expect(FTSRecordCache.fileURL(directory: dir, orgID: "00D:005").lastPathComponent == "fts-00D_005.sqlite")
        #expect(FTSRecordCache.fileURL(directory: dir, orgID: "00DOTHER").lastPathComponent != "fts-00D_005.sqlite")
    }

    @Test func arrowsReturnAndCopyLink() {
        #expect(CommandKeys.effect(.down, menuOpen: false) == .moveSelection(1))
        #expect(CommandKeys.effect(.up, menuOpen: false) == .moveSelection(-1))
        #expect(CommandKeys.effect(.return, menuOpen: false) == .openSelected)
        #expect(CommandKeys.effect(.escape, menuOpen: false) == .closePanel)
        #expect(CommandKeys.effect(.copyLink, menuOpen: false) == .copySelectedLink)
        let record = sample()[0]
        let link = "https://acme.lightning.force.com/lightning/r/Account/001/view"
        #expect(CommandKeys.linkText(for: record, fieldSelectionLength: 0) == link)
        #expect(CommandKeys.linkText(for: record, fieldSelectionLength: 4) == nil)
        #expect(CommandKeys.linkText(for: Record(id: "f", kind: .account, title: "Fake", subtitle: ""), fieldSelectionLength: 0) == nil)
    }

    @Test func previewAndCommandKMenu() {
        let record = sample()[0]
        let preview = RecordPreview.make(record)
        #expect(preview.typeName == "Account")
        #expect(preview.title == "Acme Corporation")
        #expect(preview.host == "acme.lightning.force.com")
        #expect(preview.link?.contains("/lightning/r/Account/001/view") == true)

        let actions = CommandAction.menu(for: record)
        #expect(actions.map(\.kind) == [.open, .copyLink])
        let noLink = Record(id: "f", kind: .account, title: "Fake", subtitle: "")
        #expect(CommandAction.menu(for: noLink).map(\.kind) == [.open])

        #expect(CommandKeys.effect(.commandK, menuOpen: false) == .toggleActionMenu)
        #expect(CommandKeys.effect(.down, menuOpen: true) == .moveMenu(1))
        #expect(CommandKeys.effect(.up, menuOpen: true) == .moveMenu(-1))
        #expect(CommandKeys.effect(.return, menuOpen: true) == .runMenu)
        #expect(CommandKeys.effect(.escape, menuOpen: true) == .closeMenu)
        #expect(CommandKeys.effect(.escape, menuOpen: false) == .closePanel)

        var menu = ActionMenuState()
        menu.toggle()
        #expect(menu.isOpen && menu.index == 0)
        menu.move(1, count: actions.count)
        #expect(menu.selected(in: actions)?.kind == .copyLink)
        menu.move(5, count: actions.count)
        #expect(menu.index == actions.count - 1)
        menu.close()
        #expect(!menu.isOpen)
        #expect(menu.selected(in: actions) == nil)
    }

    @Test func tenThousandRowSearchStaysUnderBudget() throws {
        let records = SearchBenchmarkTests.syntheticRecords()
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FTSRecordCache(directory: dir, orgID: "00DBENCH")
        try cache.replace(records)
        let reopened = try FTSRecordCache(directory: dir, orgID: "00DBENCH")
        _ = try reopened.records()
        let queries = ["acme", "acmee", "pset", "maya", "zzzz"]
        var samples: [Double] = []
        for _ in 0..<20 {
            for query in queries {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try reopened.search(query, limit: 80)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        #if DEBUG
        let budget = 1_000.0
        #else
        let budget = 50.0
        #endif
        #expect(p95 < budget)
    }
}
