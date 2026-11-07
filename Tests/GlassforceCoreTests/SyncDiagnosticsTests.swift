import Foundation
import Testing
@testable import GlassforceCore

/// `--diagnose-sync` tells "no records", "no read permission" and "sharing hides them" apart, read-only, counts only.
@Suite("Sync diagnostics")
struct SyncDiagnosticsTests {
    static let instance = URL(string: "https://acme.my.salesforce.com")!
    static let userKey = "00DORG000000001:005USER00000001"

    static func ok(_ object: Any) -> HTTPResponse {
        HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: object))
    }

    func run(viewAllData: Bool) async throws -> SyncDiagnostics.Report {
        let transport = StubTransport { request, _ in
            if request.url.path.hasSuffix("/oauth2/token") { return tokenJSON(access: "AT1", refresh: nil) }
            if request.url.path.hasPrefix("/id/") { return Self.ok(["user_type": "STANDARD", "active": true]) }
            if request.url.path.hasSuffix("/describe") { return Self.ok(["queryable": true, "retrieveable": true]) }
            let q = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            if q.contains("FROM User WHERE") { return Self.ok(["totalSize": 1, "records": [["UserType": "Standard", "Profile": ["Name": "Standard User", "UserLicense": ["Name": "Salesforce"]]]]]) }
            if q.contains("PermissionsViewAllData") { return Self.ok(["totalSize": viewAllData ? 1 : 0, "records": []]) }
            if q.contains("FROM ObjectPermissions") {
                return Self.ok(["totalSize": 3, "records": [
                    ["SobjectType": "Account", "PermissionsRead": true, "PermissionsViewAllRecords": false],
                    ["SobjectType": "Opportunity", "PermissionsRead": true, "PermissionsViewAllRecords": false],
                    ["SobjectType": "Case", "PermissionsRead": true, "PermissionsViewAllRecords": false],
                ]])
            }
            if q.contains("FROM Organization") { return Self.ok(["totalSize": 1, "records": [["DefaultAccountAccess": "None", "DefaultOpportunityAccess": "None", "DefaultCaseAccess": "None", "DefaultContactAccess": "ControlledByParent"]]]) }
            if q.contains("FROM Case") && !q.contains("IsDeleted") { return Self.ok(["totalSize": 5, "records": []]) }
            if q.hasPrefix("SELECT COUNT()") { return Self.ok(["totalSize": 0, "records": []]) }
            return HTTPResponse(status: 400, body: Data(#"[{"errorCode":"MALFORMED_QUERY"}]"#.utf8))
        }
        let store = InMemorySecretStore()
        let credentials = OrgCredentials(refreshToken: "RT1", consumerKey: "KEY", loginURL: URL(string: "https://login.salesforce.com")!,
                                         instanceURL: Self.instance, idURL: URL(string: "https://login.salesforce.com/id/00DORG000000001/005USER00000001")!)
        try store.write(try JSONEncoder().encode(credentials), account: Self.userKey)
        let tokens = TokenManager(transport: transport, store: store)
        let report = await SyncDiagnostics(client: SalesforceClient(tokens: tokens)).run(org: Self.userKey, instanceURL: Self.instance)

        let dataCalls = transport.requests.filter { !$0.url.path.contains("/oauth2/") }
        #expect(dataCalls.allSatisfy { $0.method == "GET" && $0.body == nil })
        #expect(!report.lines.joined().contains("AT1") && !report.lines.joined().contains("RT1"))
        return report
    }

    func verdict(_ report: SyncDiagnostics.Report, _ object: String) -> String {
        report.findings.first { $0.object == object }!.verdict(viewAllData: report.viewAllData)
    }

    @Test func tellsTheThreeCausesApart() async throws {
        let report = try await run(viewAllData: false)
        #expect(verdict(report, "Contact").contains("lack Read on Contact"))
        #expect(verdict(report, "Account").contains("sharing"))
        #expect(verdict(report, "Case").hasPrefix("5 visible"))
        #expect(report.lines.contains { $0.contains("sync query: SELECT Id, Name, Industry, BillingCity, LastModifiedDate FROM Account") })
        #expect(report.lines.contains { $0 == "user: type Standard, profile Standard User, license Salesforce" })
    }

    @Test func viewAllDataWithZeroMeansNoRecordsExist() async throws {
        let report = try await run(viewAllData: true)
        #expect(verdict(report, "Account").hasPrefix("no Account records exist"))
        #expect(verdict(report, "Opportunity").hasPrefix("no Opportunity records exist"))
    }

    @Test func launchFlagParses() {
        #expect(LaunchOptions(arguments: ["Glassforce", "--diagnose-sync"]).diagnoseSync)
        #expect(!LaunchOptions(arguments: ["Glassforce"]).diagnoseSync)
    }
}
