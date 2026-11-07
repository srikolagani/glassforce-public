import Testing
@testable import GlassforceCore

@Suite("Fake data")
struct FakeDataTests {
    @Test func hasAboutFifteenRecords() {
        #expect(FakeData.records.count >= 15)
    }

    @Test func coversEveryKind() {
        let kinds = Set(FakeData.records.map(\.kind))
        #expect(kinds == Set(RecordKind.allCases))
    }

    @Test func idsAreUnique() {
        let ids = FakeData.records.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test(arguments: RecordKind.allCases)
    func everyKindHasSymbolAndName(kind: RecordKind) {
        #expect(!kind.symbolName.isEmpty)
        #expect(!kind.displayName.isEmpty)
    }
}

@Suite("Search")
struct SearchTests {
    let store = RecordStore()

    @Test func emptyQueryReturnsEverything() {
        #expect(store.search("").count == FakeData.records.count)
        #expect(store.search("   \n").count == FakeData.records.count)
    }

    @Test func matchIsCaseInsensitive() {
        let lower = store.search("acme").map(\.id)
        let upper = store.search("ACME").map(\.id)
        #expect(!lower.isEmpty)
        #expect(lower == upper)
    }

    @Test func matchesSubtitleToo() {
        // "Acme" is in the account's and opportunity's titles but only the contact's and case's
        // subtitles, so title matches come first.
        let ids = store.search("acme").map(\.id)
        #expect(ids == ["001A", "006A", "003A", "500A"])
    }

    @Test func substringInsideWord() {
        #expect(store.search("lobe").map(\.id).contains("001B"))
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(store.search("  pipeline ").map(\.id) == ["00OA"])
    }

    @Test func noMatchReturnsEmpty() {
        #expect(store.search("zzz-not-there").isEmpty)
    }

    @Test func resultsAreOrderedByKind() {
        let shuffled = RecordStore(records: FakeData.records.reversed())
        let kinds = shuffled.search("").map { $0.kind.sortIndex }
        #expect(kinds == kinds.sorted())
    }

    @Test func groupingFollowsRankingAndSkipsEmptyKinds() {
        let groups = RecordStore.grouped(store.search("acme"))
        #expect(groups.map(\.kind) == [.account, .opportunity, .contact, .supportCase])
        #expect(groups.flatMap(\.records).map(\.id) == store.search("acme").map(\.id))
    }
}

@Suite("Selection")
struct SelectionTests {
    @Test func movesWithinBounds() {
        #expect(Selection.move(0, by: 1, count: 3) == 1)
        #expect(Selection.move(2, by: -1, count: 3) == 1)
    }

    @Test func clampsAtEnds() {
        #expect(Selection.move(0, by: -1, count: 3) == 0)
        #expect(Selection.move(2, by: 1, count: 3) == 2)
    }

    @Test func emptyListStaysAtZero() {
        #expect(Selection.move(4, by: 1, count: 0) == 0)
    }
}
