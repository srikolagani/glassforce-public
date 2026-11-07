import Foundation
import Testing
@testable import GlassforceCore

@Suite("Natural-language writes require confirm")
struct WriteCommandTests {
    let records = [
        Record(id: "006ACME", kind: .opportunity, title: "Acme · Platform Renewal", subtitle: "$240,000 · Negotiation",
               url: URL(string: "https://acme.lightning.force.com/lightning/r/Opportunity/006ACME/view"), objectName: "Opportunity"),
        Record(id: "006OTHER", kind: .opportunity, title: "Globex Expansion", subtitle: "$10,000 · Proposal", objectName: "Opportunity"),
        Record(id: "001", kind: .account, title: "Acme Corporation", subtitle: "Manufacturing", objectName: "Account"),
    ]

    @Test func moveAcmeDealShowsADiffAndDoesNotWrite() throws {
        var pending = PendingWrite()
        pending.setOrg("00DTEST")
        pending.stage(query: "move acme deal to closed won", records: records)
        let diff = try #require(pending.diff)
        #expect(diff.recordID == "006ACME")
        #expect(diff.recordTitle == "Acme · Platform Renewal")
        #expect(diff.object == "Opportunity")
        #expect(diff.field == "StageName")
        #expect(diff.before == "Negotiation")
        #expect(diff.after == "Closed Won")
        #expect(ConfirmedWrite.make(orgID: "00DTEST", diff: diff, confirmed: false) == nil)
        let confirmed = try #require(pending.confirmed())
        #expect(confirmed.diff == diff)
        #expect(confirmed.orgID == "00DTEST")
        #expect(confirmed.recordID == "006ACME")
        #expect(confirmed.before == "Negotiation")
        pending.setOrg("00DOTHER")
        #expect(pending.diff == nil)
        #expect(pending.confirmed() == nil)
    }

    @Test func fakeDataCloseDateIsNotTheStage() throws {
        var pending = PendingWrite()
        pending.setOrg("00DTEST")
        pending.stage(query: "move acme deal to closed won", records: FakeData.records)
        let diff = try #require(pending.diff)
        #expect(diff.recordID == "006A")
        #expect(diff.before == "Negotiation")
        #expect(diff.after == "Closed Won")
        #expect(WritePlanner.currentStage("$240,000 · Negotiation · Closes Dec12") == "Negotiation")
        #expect(WritePlanner.currentStage("$1 · Closed Won") == "Closed Won")
    }

    @Test func searchTextIsNotAWrite() {
        var pending = PendingWrite()
        pending.stage(query: "acme", records: records)
        #expect(pending.diff == nil)
        #expect(pending.confirmed() == nil)
    }

    @Test func cancelDropsTheDiff() {
        var pending = PendingWrite()
        pending.stage(query: "close acme deal as won", records: records)
        #expect(pending.diff?.after == "Closed Won")
        pending.cancel()
        #expect(pending.diff == nil)
        #expect(pending.confirmed() == nil)
    }

    @Test func unknownDealDoesNotInventARecord() {
        var pending = PendingWrite()
        pending.stage(query: "move zzzz deal to closed lost", records: records)
        #expect(pending.diff == nil)
    }

    @Test func mockPatchOnlyAfterConfirm() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        let tokens = TokenManager(transport: mock, store: InMemorySecretStore())
        let signIn = try await MockSalesforceTests().signIn(mock, tokens, env: .production)
        #expect(signIn.credentials.instanceURL.host == "127.0.0.1")
        let client = SalesforceClient(tokens: tokens)
        var pending = PendingWrite()
        pending.setOrg(signIn.identity.key)
        pending.stage(query: "move acme deal to closed won", records: records)
        let diff = try #require(pending.diff)
        #expect(mock.patchBodies.isEmpty, "staging a diff must not touch the mock org")
        #expect(ConfirmedWrite.make(orgID: signIn.identity.key, diff: diff, confirmed: false) == nil)

        let confirmed = try #require(pending.confirmed())
        try await client.updateField(
            org: signIn.identity.key,
            instanceURL: signIn.credentials.instanceURL,
            object: confirmed.diff.object,
            id: confirmed.diff.recordID,
            field: confirmed.diff.field,
            value: confirmed.diff.after
        )
        #expect(mock.patchBodies == ["{\"StageName\":\"Closed Won\"}"])
        #expect(mock.dataRequests.contains { $0.hasPrefix("PATCH /sobjects/Opportunity/006ACME") })
        let readsBeforeReject = mock.dataRequests.count
        await #expect(throws: QueryError.self) {
            try await client.updateField(org: signIn.identity.key, instanceURL: signIn.credentials.instanceURL,
                                         object: "Opportunity", id: "006ACME", field: "Stage Name", value: "Closed Won")
        }
        #expect(mock.dataRequests.count == readsBeforeReject)
        #expect(mock.patchBodies.count == 1)
    }

    @Test func ambiguousAcmeDealsDoNotPatchUntilOneIsChosen() async throws {
        let uat = Record(id: "006UAT", kind: .opportunity, title: "Acme · UAT Renewal Scenario", subtitle: "$1 · Closed Won", objectName: "Opportunity")
        let renewal = Record(id: "006PLAT", kind: .opportunity, title: "Acme · Platform Renewal FY27", subtitle: "$240,000 · Negotiation", objectName: "Opportunity")
        let both = [uat, renewal]
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        let tokens = TokenManager(transport: mock, store: InMemorySecretStore())
        let signIn = try await MockSalesforceTests().signIn(mock, tokens, env: .production)
        let client = SalesforceClient(tokens: tokens)
        var pending = PendingWrite()
        pending.setOrg(signIn.identity.key)
        pending.stage(query: "move acme deal to closed won", records: both)
        #expect(pending.diff == nil)
        #expect(pending.confirmed() == nil)
        #expect(Set(pending.choices.map(\.recordID)) == ["006UAT", "006PLAT"])
        #expect(mock.patchBodies.isEmpty)

        pending.choose(recordID: "006UAT", records: both)
        #expect(pending.diff == nil, "already Closed Won is not a write")
        #expect(pending.confirmed() == nil)
        #expect(mock.patchBodies.isEmpty)

        pending.choose(recordID: "006NOPE", records: both)
        #expect(pending.diff == nil)
        pending.noteSelection("006UAT")
        #expect(pending.diff == nil)

        pending.choose(recordID: "006PLAT", records: both)
        let diff = try #require(pending.diff)
        #expect(diff.recordID == "006PLAT")
        #expect(diff.before == "Negotiation")
        #expect(diff.after == "Closed Won")
        pending.noteSelection("006UAT")
        #expect(pending.diff == nil, "moving off the chosen row drops the bound write")
        #expect(mock.patchBodies.isEmpty)
        pending.choose(recordID: "006PLAT", records: both)
        let confirmed = try #require(pending.confirmed())
        #expect(confirmed.orgID == signIn.identity.key)
        #expect(confirmed.recordID == "006PLAT")
        #expect(confirmed.before == "Negotiation")
        #expect(!WriteGuard.allowsSend(confirmed, orgID: "00DOTHER", record: renewal))
        #expect(!WriteGuard.allowsSend(confirmed, orgID: signIn.identity.key, record: uat))
        var moved = renewal
        moved = Record(id: renewal.id, kind: renewal.kind, title: renewal.title, subtitle: "$240,000 · Closed Won", objectName: renewal.objectName)
        #expect(!WriteGuard.allowsSend(confirmed, orgID: signIn.identity.key, record: moved))
        #expect(WriteGuard.allowsSend(confirmed, orgID: signIn.identity.key, record: renewal))
        #expect(mock.patchBodies.isEmpty)

        try await client.updateField(
            org: confirmed.orgID,
            instanceURL: signIn.credentials.instanceURL,
            object: confirmed.diff.object,
            id: confirmed.recordID,
            field: confirmed.diff.field,
            value: confirmed.diff.after
        )
        #expect(mock.patchBodies == ["{\"StageName\":\"Closed Won\"}"])
        #expect(mock.dataRequests.contains { $0.hasPrefix("PATCH /sobjects/Opportunity/006PLAT") })
        #expect(!mock.dataRequests.contains { $0.contains("006UAT") && $0.hasPrefix("PATCH") })
    }
}
