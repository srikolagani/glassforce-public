import Foundation
import Testing
@testable import GlassforceCore

/// Regression for "search only finds Reports": every object's outcome is counted and explained,
/// never silently dropped (a mocked org answered HTTP 200 with zero Accounts/Contacts/Opportunities/Cases).
@Suite("Sync report (per-object outcomes)")
struct SyncReportTests {
    func syncedReport(_ mock: MockSalesforce) async throws -> SyncReport {
        let tokens = TokenManager(transport: mock, store: InMemorySecretStore())
        let signIn = try await MockSalesforceTests().signIn(mock, tokens, env: .production)
        return try await SalesforceClient(tokens: tokens).syncIndex(org: signIn.identity.key, instanceURL: signIn.credentials.instanceURL) { _ in }
    }

    @Test func healthyOrgCountsEveryObject() async throws {
        let report = try await syncedReport(MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!))
        for object in ["Accounts", "Contacts", "Opportunities", "Cases", "Reports"] {
            #expect((report.count(object) ?? 0) > 0, "\(object) should sync")
        }
        #expect(report.count("Setup") == 4)
        #expect(report.logLines.contains("Accounts: 5 (HTTP 200, totalSize 5)"))
        #expect(report.notice(org: "Acme") == nil)
        #expect(RecordStore(records: report.records).search("acme").contains { $0.kind == .account })
    }

    @Test func emptyObjectsAreCountedButNeverShownInPanel() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        mock.emptyObjects = ["Account", "Contact", "Opportunity", "Case"]
        let report = try await syncedReport(mock)
        #expect(report.records.allSatisfy { $0.kind == .report || $0.kind == .setup })
        #expect(report.emptyObjects == ["Accounts", "Contacts", "Opportunities", "Cases"])
        #expect(report.logLines.contains("Accounts: 0 (HTTP 200, totalSize 0)"))
        #expect(report.notice(org: "Acme") == nil)
        let zero = SyncReport.settingsLine(synced: 0, failure: nil, capped: nil)
        #expect(zero.text == "0 synced")
        #expect(!zero.problem)
        let failed = SyncReport.settingsLine(synced: 0, failure: "no access", capped: nil)
        #expect(failed.problem)
    }

    @Test func emptyObjectNextToFailingObjectOnlyNoticesTheFailure() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        mock.emptyObjects = ["Lead", "Contact"]
        mock.queryErrors["Case"] = QueryError(status: 403, errorCode: "INSUFFICIENT_ACCESS", message: "no access")
        let report = try await syncedReport(mock)
        let notice = try #require(report.notice(org: "Acme"))
        #expect(notice.contains("Cases"))
        #expect(!notice.contains("Contacts"))
        #expect(!notice.contains("Leads"))
    }

    @Test func oneObjectFailingIsNamedInPlainWords() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        mock.queryErrors["Case"] = QueryError(status: 400, errorCode: "INVALID_FIELD", message: "No such column 'Priority' on entity 'Case'")
        let report = try await syncedReport(mock)
        #expect(report.count("Accounts") == 5)
        #expect(report.count("Cases") == nil)
        #expect(report.logLines.contains { $0.hasPrefix("Cases: FAILED (HTTP 400), Salesforce rejected Glassforce's query (INVALID_FIELD: No such column") })
        let notice = try #require(report.notice(org: "Acme"))
        #expect(notice.hasPrefix("Couldn't sync Cases: Salesforce rejected Glassforce's query"))
    }

    @Test func keychainRefusalStopsTheSyncOnceInsteadOfPerObject() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        let store = RefusingSecretStore()
        // Fresh process: no access token in memory, so the first query needs the saved sign-in.
        let tokens = TokenManager(transport: mock, store: store)
        await #expect(throws: RefusingSecretStore.Refused.self) {
            _ = try await SalesforceClient(tokens: tokens).syncIndex(org: "00Dorg:005user", instanceURL: URL(string: "https://acme.my.salesforce.com")!) { _ in }
        }
        #expect(store.reads == 1)
    }
}

/// A Keychain whose access prompt was cancelled: every read fails.
final class RefusingSecretStore: SecretStore, @unchecked Sendable {
    struct Refused: Error {}
    private let lock = NSLock()
    private var _reads = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    func read(account: String) throws -> Data? { lock.lock(); _reads += 1; lock.unlock(); throw Refused() }
    func write(_ data: Data, account: String) throws { throw Refused() }
    func delete(account: String) throws {}
}
