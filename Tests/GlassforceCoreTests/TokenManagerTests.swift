import Foundation
import Testing
@testable import GlassforceCore

/// Scripted transport: counts requests, optionally delays, answers from a closure.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [HTTPRequest] = []
    let delay: TimeInterval
    let respond: @Sendable (HTTPRequest, Int) -> HTTPResponse

    init(delay: TimeInterval = 0, respond: @escaping @Sendable (HTTPRequest, Int) -> HTTPResponse) {
        self.delay = delay
        self.respond = respond
    }

    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return log }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let n: Int = { lock.lock(); defer { lock.unlock() }; log.append(request); return log.count }()
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return respond(request, n)
    }
}

func tokenJSON(access: String, refresh: String?) -> HTTPResponse {
    var body: [String: Any] = ["access_token": access, "instance_url": "https://acme.my.salesforce.com",
                               "id": "https://login.salesforce.com/id/00DORG/005USER"]
    if let refresh { body["refresh_token"] = refresh }
    return HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
}

func form(_ request: HTTPRequest) -> [String: String] {
    FormEncoding.decode(String(decoding: request.body ?? Data(), as: UTF8.self))
}

let orgKey = "00DORG:005USER"

func seededStore(refresh: String = "RT1") throws -> InMemorySecretStore {
    let store = InMemorySecretStore()
    let credentials = OrgCredentials(refreshToken: refresh, consumerKey: "KEY", loginURL: URL(string: "https://test.salesforce.com")!,
                                     instanceURL: URL(string: "https://acme.my.salesforce.com")!,
                                     idURL: URL(string: "https://login.salesforce.com/id/00DORG/005USER")!)
    try store.write(try JSONEncoder().encode(credentials), account: orgKey)
    return store
}

@Suite("Token store and refresh")
struct TokenManagerTests {
    @Test func signInExchangesCodeWithVerifierAndStoresOnlyTheRefreshToken() async throws {
        let transport = StubTransport { _, _ in tokenJSON(access: "AT1", refresh: "RT1") }
        let store = InMemorySecretStore()
        let tokens = TokenManager(transport: transport, store: store)
        let request = AuthorizationRequest(loginURL: LoginEnvironment.sandbox.loginURL, config: OAuthConfig(consumerKey: "KEY"))

        let signIn = try await tokens.completeSignIn(request, code: "CODE")

        #expect(signIn.identity.key == orgKey)
        let sent = form(transport.requests[0])
        #expect(transport.requests[0].url.absoluteString == "https://test.salesforce.com/services/oauth2/token")
        #expect(sent["grant_type"] == "authorization_code")
        #expect(sent["code_verifier"] == request.pkce.verifier)
        #expect(sent["client_secret"] == nil)
        let saved = try #require(try await tokens.credentials(for: orgKey))
        #expect(saved.refreshToken == "RT1")
        #expect(store.accounts == [orgKey])
        // The access token is served from memory; no refresh needed.
        #expect(try await tokens.accessToken(for: orgKey) == "AT1")
        #expect(transport.requests.count == 1)
        // Nothing but the refresh token JSON is persisted; the access token never is.
        let raw = String(decoding: try #require(try store.read(account: orgKey)), as: UTF8.self)
        #expect(!raw.contains("AT1"))
    }

    @Test func refreshRotationPersistsTheNewTokenBeforeUse() async throws {
        let store = try seededStore(refresh: "RT1")
        let transport = StubTransport { request, _ in
            form(request)["refresh_token"] == "RT1" ? tokenJSON(access: "AT2", refresh: "RT2") : HTTPResponse(status: 400)
        }
        let tokens = TokenManager(transport: transport, store: store)

        #expect(try await tokens.accessToken(for: orgKey) == "AT2")
        #expect(try await tokens.credentials(for: orgKey)?.refreshToken == "RT2")
        #expect(store.writeLog == [orgKey, orgKey])  // seed + rotated token
    }

    @Test func concurrentRefreshesShareOneRequest() async throws {
        let store = try seededStore()
        let transport = StubTransport(delay: 0.2) { _, n in tokenJSON(access: "AT\(n)", refresh: "RT\(n + 1)") }
        let tokens = TokenManager(transport: transport, store: store)

        async let a = tokens.refresh(orgKey)
        async let b = tokens.refresh(orgKey)
        async let c = tokens.accessToken(for: orgKey)
        let results = try await [a, b, c]

        #expect(transport.requests.count == 1)
        #expect(Set(results) == ["AT1"])
        #expect(await tokens.refreshRequestCount == 1)
    }

    @Test func invalidGrantMeansNeedsSignInAndForgetsTheToken() async throws {
        let store = try seededStore()
        let transport = StubTransport { _, _ in
            HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant","error_description":"expired access/refresh token"}"#.utf8))
        }
        let tokens = TokenManager(transport: transport, store: store)

        await #expect(throws: AuthError.needsSignIn) { try await tokens.accessToken(for: orgKey) }
        #expect(store.accounts.isEmpty)
        // No retry loop with the dead token.
        await #expect(throws: AuthError.needsSignIn) { try await tokens.accessToken(for: orgKey) }
        #expect(transport.requests.count == 1)
    }

    @Test func unauthorizedApiCallRefreshesOnceAndRetriesOnce() async throws {
        let store = try seededStore()
        let transport = StubTransport { request, _ in
            if request.url.path.hasSuffix("/token") { return tokenJSON(access: "FRESH", refresh: "RT2") }
            return request.headers["Authorization"] == "Bearer FRESH" ? HTTPResponse(status: 200) : HTTPResponse(status: 401)
        }
        let tokens = TokenManager(transport: transport, store: store)
        _ = try await tokens.accessToken(for: orgKey)   // FRESH
        // Pretend the session expired server side: first call 401s with a stale token.
        let staleTransport = StubTransport { request, n in
            if request.url.path.hasSuffix("/token") { return tokenJSON(access: "NEW", refresh: "RT3") }
            return request.headers["Authorization"] == "Bearer NEW" ? HTTPResponse(status: 200) : HTTPResponse(status: 401)
        }
        let tokens2 = TokenManager(transport: staleTransport, store: store)
        let response = try await tokens2.authorizedSend(orgKey, HTTPRequest(url: URL(string: "https://acme.my.salesforce.com/services/data")!))
        #expect(response.status == 200)
        // refresh (token) + API call; no extra retries.
        #expect(staleTransport.requests.count == 2)
    }

    @Test func persistent401AfterRefreshIsNeedsSignIn() async throws {
        let store = try seededStore()
        let transport = StubTransport { request, _ in
            request.url.path.hasSuffix("/token") ? tokenJSON(access: "AT", refresh: "RTn") : HTTPResponse(status: 401)
        }
        let tokens = TokenManager(transport: transport, store: store)
        await #expect(throws: AuthError.needsSignIn) {
            _ = try await tokens.authorizedSend(orgKey, HTTPRequest(url: URL(string: "https://x.my.salesforce.com/q")!))
        }
        // initial refresh, call, refresh, retry: exactly one retry.
        #expect(transport.requests.count == 4)
    }

    @Test func signOutRevokesAndDeletes() async throws {
        let store = try seededStore(refresh: "RT9")
        let transport = StubTransport { _, _ in HTTPResponse(status: 200) }
        let tokens = TokenManager(transport: transport, store: store)
        await tokens.signOut(orgKey)
        #expect(transport.requests.first?.url.path == "/services/oauth2/revoke")
        #expect(form(transport.requests[0])["token"] == "RT9")
        #expect(store.accounts.isEmpty)
    }

    @Test func networkFailureIsOfflineNotSignOut() async throws {
        struct Down: Error {}
        final class Failing: HTTPTransport { func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw Down() } }
        let store = try seededStore()
        let tokens = TokenManager(transport: Failing(), store: store)
        await #expect(throws: AuthError.offline) { try await tokens.accessToken(for: orgKey) }
        #expect(store.accounts == [orgKey])
    }

    @Test func exchangeDoesNotWriteUntilCommit() async throws {
        let transport = StubTransport { _, _ in tokenJSON(access: "AT1", refresh: "RT1") }
        let store = InMemorySecretStore()
        let tokens = TokenManager(transport: transport, store: store)
        let request = AuthorizationRequest(loginURL: LoginEnvironment.sandbox.loginURL, config: OAuthConfig(consumerKey: "KEY"))

        let signIn = try await tokens.exchangeSignIn(request, code: "CODE")
        #expect(store.accounts.isEmpty)
        #expect(try await tokens.credentials(for: orgKey) == nil)
        // Access token is served from memory so identity calls can run before confirm.
        #expect(try await tokens.accessToken(for: orgKey) == "AT1")

        try await tokens.commit(signIn)
        #expect(store.accounts == [orgKey])
        #expect(try await tokens.credentials(for: orgKey)?.refreshToken == "RT1")
        let raw = String(decoding: try #require(try store.read(account: orgKey)), as: UTF8.self)
        #expect(!raw.contains("AT1"))
    }

    @Test func discardDropsMemoryWithoutWriting() async throws {
        let transport = StubTransport { _, _ in tokenJSON(access: "AT1", refresh: "RT1") }
        let store = InMemorySecretStore()
        let tokens = TokenManager(transport: transport, store: store)
        let request = AuthorizationRequest(loginURL: LoginEnvironment.production.loginURL, config: OAuthConfig(consumerKey: "KEY"))
        let signIn = try await tokens.exchangeSignIn(request, code: "CODE")
        await tokens.discard(signIn)
        #expect(store.accounts.isEmpty)
        await #expect(throws: AuthError.needsSignIn) { _ = try await tokens.accessToken(for: orgKey) }
    }
}
