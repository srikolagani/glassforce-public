import Foundation

/// Owns every org's tokens. Refresh tokens live only in the `SecretStore` (the Keychain);
/// access tokens live only in memory. Refreshes are serialized per org because Salesforce
/// rotates the refresh token on every use (RTR), so two parallel refreshes would race.
public actor TokenManager {
    public struct SignIn: Sendable, Equatable {
        public let identity: OrgIdentity
        public let credentials: OrgCredentials
        /// Access token held only in memory until `commit` (or discarded).
        public let accessToken: String
    }

    private let transport: HTTPTransport
    private let store: SecretStore
    private var accessTokens: [String: String] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]
    /// Number of refresh requests actually sent (tests use it to prove de-duplication).
    public private(set) var refreshRequestCount = 0

    public init(transport: HTTPTransport, store: SecretStore) {
        self.transport = transport
        self.store = store
    }

    // MARK: Sign-in

    /// Exchanges the authorization code for tokens. Puts the access token in memory so identity
    /// calls can run, but does **not** write the refresh token to the SecretStore. Call `commit`
    /// after the user confirms the org, or `discard` if they pick a different one.
    public func exchangeSignIn(_ request: AuthorizationRequest, code: String) async throws -> SignIn {
        let tokenURL = request.loginURL.appendingPathComponent("services/oauth2/token")
        let response = try await send(.form(tokenURL, [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", request.consumerKey),
            ("redirect_uri", OAuthConfig.redirectURI),
            ("code_verifier", request.pkce.verifier),
        ]))
        let token = try Self.decodeToken(response)
        guard let refresh = token.refreshToken else { throw AuthError.server("Salesforce didn't return a refresh token (is the refresh_token scope enabled?)") }
        guard let identity = OrgIdentity(idURL: token.id) else { throw AuthError.server("Unexpected identity URL") }

        let credentials = OrgCredentials(
            refreshToken: refresh, consumerKey: request.consumerKey,
            loginURL: request.loginURL, instanceURL: token.instanceURL, idURL: token.id
        )
        // Memory only — Keychain write waits for confirm.
        accessTokens[identity.key] = token.accessToken
        return SignIn(identity: identity, credentials: credentials, accessToken: token.accessToken)
    }

    /// Persists the refresh token after the user confirms this org.
    public func commit(_ signIn: SignIn) throws {
        try save(signIn.credentials, for: signIn.identity.key)
        accessTokens[signIn.identity.key] = signIn.accessToken
    }

    /// Drops an unconfirmed sign-in from memory. Never wrote to the SecretStore.
    public func discard(_ signIn: SignIn) {
        accessTokens[signIn.identity.key] = nil
    }

    /// Exchange + commit. Kept for tests and callers that don't need a confirmation step.
    public func completeSignIn(_ request: AuthorizationRequest, code: String) async throws -> SignIn {
        let signIn = try await exchangeSignIn(request, code: code)
        try commit(signIn)
        return signIn
    }

    // MARK: Access tokens

    public func credentials(for org: String) throws -> OrgCredentials? {
        guard let data = try store.read(account: org) else { return nil }
        return try JSONDecoder().decode(OrgCredentials.self, from: data)
    }

    public func hasCredentials(for org: String) -> Bool {
        ((try? store.read(account: org)) ?? nil) != nil
    }

    public func accessToken(for org: String) async throws -> String {
        if let token = accessTokens[org] { return token }
        return try await refresh(org)
    }

    /// Single-flight refresh: concurrent callers share one request.
    public func refresh(_ org: String) async throws -> String {
        if let running = inFlight[org] { return try await running.value }
        let task = Task { try await self.performRefresh(org) }
        inFlight[org] = task
        defer { inFlight[org] = nil }
        return try await task.value
    }

    private func performRefresh(_ org: String) async throws -> String {
        guard var credentials = try credentials(for: org) else { throw AuthError.needsSignIn }
        refreshRequestCount += 1
        let response: HTTPResponse
        do {
            response = try await send(.form(credentials.loginURL.appendingPathComponent("services/oauth2/token"), [
                ("grant_type", "refresh_token"),
                ("refresh_token", credentials.refreshToken),
                ("client_id", credentials.consumerKey),
            ]))
        }

        do {
            let token = try Self.decodeToken(response)
            if let rotated = token.refreshToken { credentials.refreshToken = rotated }
            credentials.instanceURL = token.instanceURL
            // RTR: persist the new refresh token BEFORE handing out the new access token.
            try save(credentials, for: org)
            accessTokens[org] = token.accessToken
            return token.accessToken
        } catch AuthError.needsSignIn {
            // invalid_grant: expired, revoked or rotated out. Never retry with the old token.
            accessTokens[org] = nil
            try? store.delete(account: org)
            throw AuthError.needsSignIn
        }
    }

    // MARK: Authorized API calls

    /// Sends an API request with a bearer token. On 401 it refreshes once and retries once.
    public func authorizedSend(_ org: String, _ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = request
        attempt.headers["Authorization"] = "Bearer \(try await accessToken(for: org))"
        let first = try await send(attempt)
        guard first.status == 401 else { return first }

        accessTokens[org] = nil
        attempt.headers["Authorization"] = "Bearer \(try await refresh(org))"
        let second = try await send(attempt)
        if second.status == 401 { throw AuthError.needsSignIn }
        return second
    }

    // MARK: Sign-out

    /// Revokes the refresh token with Salesforce (best effort) and deletes it from the Keychain.
    public func signOut(_ org: String) async {
        if let credentials = try? credentials(for: org) {
            _ = try? await send(.form(credentials.loginURL.appendingPathComponent("services/oauth2/revoke"), [
                ("token", credentials.refreshToken),
            ]))
        }
        accessTokens[org] = nil
        try? store.delete(account: org)
    }

    // MARK: Helpers

    private func save(_ credentials: OrgCredentials, for org: String) throws {
        try store.write(try JSONEncoder().encode(credentials), account: org)
    }

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.offline
        }
    }

    static func decodeToken(_ response: HTTPResponse) throws -> TokenResponse {
        if (200..<300).contains(response.status) {
            do { return try JSONDecoder().decode(TokenResponse.self, from: response.body) }
            catch { throw AuthError.server("Unreadable token response") }
        }
        if let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: response.body) {
            throw AuthError.fromOAuth(error: body.error, description: body.errorDescription)
        }
        throw AuthError.server("Token request failed (HTTP \(response.status))")
    }
}
