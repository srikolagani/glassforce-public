import Foundation
import Testing
@testable import GlassforceCore

/// The real-org sync path against mocked HTTP: read-only GETs, Lightning links, partial permissions, 401 refresh.
@Suite("Real org sync (mocked HTTP)")
struct RealOrgSyncTests {
    static let instance = URL(string: "https://acme.my.salesforce.com")!

    static func queryResponse(_ request: HTTPRequest) -> HTTPResponse {
        let q = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        let rows: [[String: Any]]
        if q.contains("FROM Account") { rows = [["Id": "001AAA", "Name": "Real Account", "Industry": "Energy", "BillingCity": "Austin"]] }
        else if q.contains("FROM Contact") { rows = [["Id": "003CCC", "Name": "Pat Doe", "Title": "CFO", "Account": ["Name": "Real Account"]]] }
        else if q.contains("FROM Opportunity") { rows = [["Id": "006OOO", "Name": "Big Deal", "Amount": 2_500_000.0, "StageName": "Prospecting"]] }
        else if q.contains("FROM Case") {
            return HTTPResponse(status: 403, body: Data(#"[{"errorCode":"INSUFFICIENT_ACCESS"}]"#.utf8))
        } else { rows = [["Id": "00OREP", "Name": "Pipeline", "FolderName": "Sales"]] }
        return HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: ["records": rows, "done": true]))
    }

    @Test func syncIsReadOnlyAndLinksToLightning() async throws {
        let transport = StubTransport { request, _ in
            request.url.path.hasSuffix("/oauth2/token") ? tokenJSON(access: "AT1", refresh: nil) : Self.queryResponse(request)
        }
        let tokens = TokenManager(transport: transport, store: try seededStore())
        let records = try await SalesforceClient(tokens: tokens).syncIndex(org: orgKey, instanceURL: Self.instance) { _ in }.records

        let dataCalls = transport.requests.filter { !$0.url.path.contains("/oauth2/") }
        #expect(!dataCalls.isEmpty)
        #expect(dataCalls.allSatisfy { $0.method == "GET" && $0.body == nil })
        #expect(dataCalls.allSatisfy { $0.url.path == "/services/data/v62.0/query" })
        let soql = dataCalls.compactMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value }
        #expect(soql.allSatisfy { $0.hasPrefix("SELECT ") && $0.hasSuffix("ORDER BY LastModifiedDate DESC LIMIT 50000") })

        let account = try #require(records.first { $0.id == "001AAA" })
        #expect(account.url?.absoluteString == "https://acme.lightning.force.com/lightning/r/Account/001AAA/view")
        #expect(records.first { $0.id == "00OREP" }?.url?.absoluteString == "https://acme.lightning.force.com/lightning/r/Report/00OREP/view")
        #expect(records.contains { $0.title == "Big Deal" && $0.subtitle == "$2.5M · Prospecting" })
        // No Case permission: skipped, the rest still syncs.
        #expect(!records.contains { $0.kind == .supportCase })
        #expect(records.contains { $0.kind == .setup && $0.url?.path == "/lightning/setup/ManageUsers/home" })
    }

    @Test func expiredSessionMidSyncRefreshesOnceAndRetries() async throws {
        let transport = StubTransport { request, _ in
            if request.url.path.hasSuffix("/oauth2/token") {
                let refreshes = FormEncoding.decode(String(decoding: request.body ?? Data(), as: UTF8.self))["refresh_token"]
                // First refresh hands out a token the API then rejects; the 401 forces a second, rotated refresh.
                return refreshes == "RT1" ? tokenJSON(access: "AT-STALE", refresh: "RT2") : tokenJSON(access: "AT-NEW", refresh: "RT3")
            }
            if request.headers["Authorization"] != "Bearer AT-NEW" {
                return HTTPResponse(status: 401, body: Data(#"[{"errorCode":"INVALID_SESSION_ID"}]"#.utf8))
            }
            return Self.queryResponse(request)
        }
        let store = try seededStore()
        let tokens = TokenManager(transport: transport, store: store)
        let records = try await SalesforceClient(tokens: tokens).syncIndex(org: orgKey, instanceURL: Self.instance) { _ in }.records
        #expect(records.contains { $0.id == "001AAA" })
        #expect(await tokens.refreshRequestCount == 2)
        #expect(try await tokens.credentials(for: orgKey)?.refreshToken == "RT3")
    }

    @Test func revokedAccessDuringSyncNeedsSignIn() async throws {
        let transport = StubTransport { request, _ in
            request.url.path.hasSuffix("/oauth2/token")
                ? HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant","error_description":"expired access/refresh token"}"#.utf8))
                : HTTPResponse(status: 401, body: Data())
        }
        let tokens = TokenManager(transport: transport, store: try seededStore())
        await #expect(throws: AuthError.needsSignIn) {
            _ = try await SalesforceClient(tokens: tokens).syncIndex(org: orgKey, instanceURL: Self.instance) { _ in }.records
        }
    }
}
