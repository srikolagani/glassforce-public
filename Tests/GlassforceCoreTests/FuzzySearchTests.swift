import Foundation
import Testing
@testable import GlassforceCore

@Suite("Fuzzy search")
struct FuzzySearchTests {
    let store = RecordStore()

    func top(_ query: String, in store: RecordStore? = nil) -> String? {
        (store ?? self.store).search(query).first?.id
    }

    // MARK: Prefixes while typing

    @Test(arguments: ["a", "ac", "acm", "acme", "acme corp", "ACME CORPORATION"])
    func acmeWhileTyping(query: String) {
        #expect(top(query) == "001A")
    }

    @Test func prefixOfLaterWord() {
        #expect(top("indus") == "001B")   // Globex Industries
        #expect(top("procure") == "003C") // only in Priya's subtitle
    }

    // MARK: Typos

    @Test func extraLetter() {
        #expect(top("acmee") == "001A")
        #expect(!store.search("acmee").contains { $0.id == "001B" })
    }

    @Test func missingLetterInObjectName() {
        let results = store.search("opprtunity")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.kind == .opportunity })
    }

    @Test func typoInReportAndSetupNames() {
        #expect(top("pipline") == "00OA")
        #expect(top("permision sets") == "SETUP-PERMSETS")
        #expect(top("flwos") == "SETUP-FLOWS")   // transposition
    }

    @Test func shortQueriesDoNotTypoMatch() {
        // Three letters is too short to guess a typo: "zcm" must not become "acm".
        #expect(store.search("zcm").isEmpty)
    }

    // MARK: Acronyms and subsequences

    @Test func setupAcronyms() {
        #expect(top("pset") == "SETUP-PERMSETS")
        #expect(top("perm st") == "SETUP-PERMSETS")
        #expect(top("permset") == "SETUP-PERMSETS")
        #expect(top("usr") == "SETUP-USERS")
        #expect(store.search("pset").map(\.id) == ["SETUP-PERMSETS"])   // no typo match on "Setup"
    }

    @Test func objectNamesFindTheirRecords() {
        let groups = RecordStore.grouped(store.search("opp"))
        #expect(groups.first?.kind == .opportunity)
        #expect(RecordStore.grouped(store.search("reports")).first?.kind == .report)
    }

    @Test func scatteredLettersDoNotMatch() {
        // a…c…m scattered across unrelated words isn't an acronym.
        #expect(!store.search("acm").contains { $0.id == "006C" })
    }

    // MARK: Multi-word, punctuation, diacritics

    @Test func wordsInAnyPosition() {
        #expect(top("pipeline stage") == "00OA")
        #expect(top("stage pipeline") == "00OA")
        #expect(top("cases priority") == "00OB")
    }

    @Test func punctuationIsASeparator() {
        #expect(top("sso login") == "500A")
        #expect(top("00001042") == "500A")
        #expect(top("acme-platform") == "006A")
    }

    @Test func diacriticsFoldBothWays() {
        let store = RecordStore(records: [
            Record(id: "1", kind: .account, title: "Café Résumé GmbH", subtitle: ""),
            Record(id: "2", kind: .account, title: "Muller Bau", subtitle: ""),
        ])
        #expect(top("cafe resume", in: store) == "1")
        #expect(top("Müller", in: store) == "2")
    }

    // MARK: Ranking

    @Test func titleBeatsSubtitle() {
        let store = RecordStore(records: [
            Record(id: "body", kind: .account, title: "Wayne Enterprises", subtitle: "Partner of Stark Logistics"),
            Record(id: "title", kind: .account, title: "Stark Logistics", subtitle: "Transportation"),
        ])
        #expect(store.search("stark").map(\.id) == ["title", "body"])
    }

    @Test func exactBeatsPrefixBeatsTypo() {
        let store = RecordStore(records: [
            Record(id: "typo", kind: .report, title: "Flaws Review", subtitle: ""),
            Record(id: "prefix", kind: .report, title: "Flowsheet Audit", subtitle: ""),
            Record(id: "exact", kind: .report, title: "Active Flows", subtitle: ""),
        ])
        #expect(store.search("flows").map(\.id) == ["exact", "prefix", "typo"])
    }

    @Test func titleStartingWithTheQueryWins() {
        let store = RecordStore(records: [
            Record(id: "later", kind: .report, title: "Open Pipeline", subtitle: ""),
            Record(id: "start", kind: .report, title: "Pipeline Open", subtitle: ""),
        ])
        #expect(store.search("pipeline").first?.id == "start")
    }

    @Test func frequentlyOpenedRecordsRankHigher() {
        let store = RecordStore(records: [
            Record(id: "a", kind: .report, title: "Milestone Progress", subtitle: ""),
            Record(id: "b", kind: .report, title: "Milestone Progress", subtitle: ""),
        ])
        #expect(store.search("milestone").first?.id == "a")
        #expect(store.search("milestone", boosts: ["b": 3]).first?.id == "b")
    }

    @Test func bestGroupComesFirst() {
        // "Users" is a Setup page; that group should lead even though Accounts sort first normally.
        #expect(RecordStore.grouped(store.search("users")).first?.kind == .setup)
    }

    @Test func limitKeepsTheBest() {
        #expect(store.search("acme", limit: 2).map(\.id) == ["001A", "006A"])
        #expect(store.search("", limit: 3).count == 3)
    }

    // MARK: Real-org-shaped data (stock Salesforce sample report names)

    @Test func misspelledSampleReport() {
        let store = RecordStore(records: [
            Record(id: "r1", kind: .report, title: "Sample Report: Orchestration Runs", subtitle: "Sample Flow Reports"),
            Record(id: "r2", kind: .report, title: "Sample Report: Orchestration Stage Runs", subtitle: "Sample Flow Reports"),
            Record(id: "r3", kind: .report, title: "Milestone Progress by User", subtitle: "Program Reports"),
        ] + SyncObject.setupShortcuts(instanceURL: URL(string: "https://example.my.salesforce.com")!))
        #expect(top("orchestraton runs", in: store) == "r1")
        #expect(top("milstone progress", in: store) == "r3")
        #expect(top("perm st", in: store) == "SETUP-PermSets")
        #expect(top("usr", in: store) == "SETUP-ManageUsers")
        #expect(top("obj mgr", in: store) == "SETUP-ObjectManager")
    }
}

@Suite("Matcher internals")
struct MatcherTests {
    @Test func foldsAndSplits() {
        let text = SearchText("  Café–Résumé, FY27!  ")
        #expect(String(decoding: text.bytes, as: UTF8.self) == "cafe resume fy27")
        #expect(text.wordStarts == [0, 5, 12])
    }

    @Test func tiers() {
        let field = SearchText("Permission Sets")
        func s(_ q: String) -> Int { FuzzyMatcher.score(QueryToken.tokens(q)[0], in: field) }
        #expect(s("permission") > s("perm"))                            // whole word > prefix
        #expect(s("perm") > s("set"))                                   // first word > later word
        #expect(s("sets") > s("pset"))                                  // prefix > acronym
        #expect(s("pset") > s("miss"))                                  // acronym > mid-word substring
        #expect(s("miss") > s("pernission"))                            // substring > typo
        #expect(s("pernission") > 0)
        #expect(s("permision") >= 20)                                   // a dropped letter is a subsequence
        #expect(s("xyzw") == 0)
    }
}
