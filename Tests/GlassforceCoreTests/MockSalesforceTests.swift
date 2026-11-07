import Foundation
import Testing
@testable import GlassforceCore

/// End to end against the in-process mock: browser approve → code → tokens → identity → sync → relaunch.
@Suite("Mock Salesforce end to end")
struct MockSalesforceTests {
    func signIn(_ mock: MockSalesforce, _ tokens: TokenManager, env: LoginEnvironment, key: String = MockSalesforce.consumerKey) async throws -> TokenManager.SignIn {
        let request = AuthorizationRequest(loginURL: mock.loginURL(for: env), config: OAuthConfig(consumerKey: key))
        // The "browser": load the consent page, then follow the Allow link.
        let page = try await mock.send(HTTPRequest(url: request.url))
        #expect(page.status == 200)
        let html = String(decoding: page.body, as: UTF8.self)
        #expect(html.contains("Allow Glassforce"))
        // Follow the real Allow link the way a browser resolves it against the page URL.
        let approve = try #require(Self.link(id: "allow", in: html, relativeTo: request.url))
        let redirect = try await mock.send(HTTPRequest(url: approve))
        #expect(redirect.status == 302)
        let callback = URL(string: try #require(redirect.headers["Location"]))!
        let code = try request.parseCallback(callback).get()
        return try await tokens.completeSignIn(request, code: code)
    }

    static func link(id: String, in html: String, relativeTo base: URL) -> URL? {
        guard let idRange = html.range(of: "id=\"\(id)\" href=\"") else { return nil }
        let rest = html[idRange.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let href = String(rest[..<end]).replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: href, relativeTo: base)?.absoluteURL
    }

    @Test func consentLinksResolveToMockRoutes() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        let request = AuthorizationRequest(loginURL: mock.loginURL(for: .sandbox), config: OAuthConfig(consumerKey: MockSalesforce.consumerKey))
        let html = String(decoding: try await mock.send(HTTPRequest(url: request.url)).body, as: UTF8.self)
        let allow = try #require(Self.link(id: "allow", in: html, relativeTo: request.url))
        let deny = try #require(Self.link(id: "deny", in: html, relativeTo: request.url))
        #expect(allow.path == "/env/sandbox/mock/approve")
        #expect(deny.path == "/env/sandbox/mock/deny")
        let denied = try await mock.send(HTTPRequest(url: deny))
        let callback = URL(string: try #require(denied.headers["Location"]))!
        #expect(request.parseCallback(callback) == .failure(.accessDenied))
    }

    @Test func sandboxSignInSyncAndSilentRelaunch() async throws {
        let stateFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mock-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateFile) }
        let keychain = InMemorySecretStore()

        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!, stateFile: stateFile)
        let tokens = TokenManager(transport: mock, store: keychain)
        let result = try await signIn(mock, tokens, env: .sandbox)
        let client = SalesforceClient(tokens: tokens)

        let identity = try await client.identity(org: result.identity.key, idURL: result.credentials.idURL)
        #expect(identity.username == "sri@acme.example.uat")
        let facts = try await client.organization(org: result.identity.key, instanceURL: result.credentials.instanceURL)
        #expect(facts.kind == .sandbox)
        #expect(facts.name == "Acme Corp (UAT)")
        let records = try await client.syncIndex(org: result.identity.key, instanceURL: result.credentials.instanceURL) { _ in }.records
        #expect(records.contains { $0.title == "Acme Test Account (UAT)" })
        #expect(RecordStore(records: records).search("acme").count >= 5)

        // "Relaunch": new server process (state from disk) and a new token manager, same keychain.
        let mock2 = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!, stateFile: stateFile)
        let tokens2 = TokenManager(transport: mock2, store: keychain)
        let again = try await SalesforceClient(tokens: tokens2).syncIndex(org: result.identity.key, instanceURL: result.credentials.instanceURL) { _ in }.records
        #expect(again.count == records.count)
        #expect(await tokens2.refreshRequestCount == 1)
    }

    @Test func wrongVerifierIsRejected() async throws {
        let mock = MockSalesforce()
        let request = AuthorizationRequest(loginURL: mock.loginURL(for: .production), config: OAuthConfig(consumerKey: MockSalesforce.consumerKey))
        var approve = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        approve.path = mock.loginURL(for: .production).path + "/mock/approve"
        let redirect = try await mock.send(HTTPRequest(url: approve.url!))
        let code = try request.parseCallback(URL(string: redirect.headers["Location"]!)!).get()
        let forged = AuthorizationRequest(loginURL: request.loginURL, config: OAuthConfig(consumerKey: MockSalesforce.consumerKey), state: request.state)
        let tokens = TokenManager(transport: mock, store: InMemorySecretStore())
        await #expect(throws: AuthError.needsSignIn) { _ = try await tokens.completeSignIn(forged, code: code) }
    }

    @Test func rotatedOutTokenGetsInvalidGrant() async throws {
        let mock = MockSalesforce()
        let keychain = InMemorySecretStore()
        let tokens = TokenManager(transport: mock, store: keychain)
        let result = try await signIn(mock, tokens, env: .production)
        let first = result.credentials.refreshToken
        _ = try await tokens.refresh(result.identity.key)
        let rotated = try await tokens.credentials(for: result.identity.key)?.refreshToken
        #expect(rotated != nil && rotated != first)
        // Replaying the old token fails, like Salesforce RTR.
        let replay = try await mock.send(.form(mock.loginURL(for: .production).appendingPathComponent("services/oauth2/token"),
                                              [("grant_type", "refresh_token"), ("refresh_token", first), ("client_id", MockSalesforce.consumerKey)]))
        #expect(replay.status == 400)
        // An admin revoking access turns into "Needs sign-in".
        mock.revokeAllRefreshTokens()
        mock.expireAccessTokens()
        await #expect(throws: AuthError.needsSignIn) {
            _ = try await SalesforceClient(tokens: tokens).organization(org: result.identity.key, instanceURL: result.credentials.instanceURL)
        }
    }

    @Test func expiredSessionIsRefreshedTransparently() async throws {
        let mock = MockSalesforce()
        let tokens = TokenManager(transport: mock, store: InMemorySecretStore())
        let result = try await signIn(mock, tokens, env: .production)
        mock.expireAccessTokens()
        let facts = try await SalesforceClient(tokens: tokens).organization(org: result.identity.key, instanceURL: result.credentials.instanceURL)
        #expect(facts.kind == .production)
    }

    @Test func notInstalledAndDeniedPaths() async throws {
        let mock = MockSalesforce()
        let notInstalled = AuthorizationRequest(loginURL: mock.loginURL(for: .production), config: OAuthConfig(consumerKey: MockSalesforce.notInstalledConsumerKey))
        let page = try await mock.send(HTTPRequest(url: notInstalled.url))
        #expect(notInstalled.parseCallback(URL(string: page.headers["Location"]!)!) == .failure(.notInstalled))

        let request = AuthorizationRequest(loginURL: mock.loginURL(for: .sandbox), config: OAuthConfig(consumerKey: MockSalesforce.consumerKey))
        var deny = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        deny.path = mock.loginURL(for: .sandbox).path + "/mock/deny"
        let denied = try await mock.send(HTTPRequest(url: deny.url!))
        #expect(request.parseCallback(URL(string: denied.headers["Location"]!)!) == .failure(.accessDenied))
    }

    @Test func customMyDomainOrgIsStable() {
        let a = MockSalesforce.org(forSlug: "custom-acme--uat.sandbox.my.salesforce.com")
        let b = MockSalesforce.org(forSlug: "custom-acme--uat.sandbox.my.salesforce.com")
        #expect(a == b)
        #expect(a.isSandbox)
    }
}
