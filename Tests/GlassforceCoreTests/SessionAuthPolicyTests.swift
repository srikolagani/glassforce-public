import Foundation
import Testing
@testable import GlassforceCore

@Suite("Session auth policy")
struct SessionAuthPolicyTests {
    func profile(_ id: String) -> OrgProfile {
        OrgProfile(
            id: id, orgName: "Org", username: "u@x", kind: .developer,
            loginURL: URL(string: "https://login.salesforce.com")!,
            instanceURL: URL(string: "https://example.my.salesforce.com")!,
            isDefault: true
        )
    }

    @Test func emptyDirectoryNeedsOnboarding() {
        #expect(SessionAuthPolicy.needsOnboarding(directory: OrgDirectory(), hasCredentials: { _ in true }))
    }

    @Test func directoryWithoutKeychainNeedsOnboarding() {
        var directory = OrgDirectory()
        directory.upsert(profile("00DA:005U"))
        #expect(SessionAuthPolicy.needsOnboarding(directory: directory, hasCredentials: { _ in false }))
    }

    @Test func keychainBackedDefaultSkipsOnboarding() {
        var directory = OrgDirectory()
        directory.upsert(profile("00DA:005U"))
        #expect(!SessionAuthPolicy.needsOnboarding(directory: directory, hasCredentials: { $0 == "00DA:005U" }))
    }

    @Test func cacheOnlyLoadsForAuthenticatedOrg() {
        #expect(!SessionAuthPolicy.mayLoadCache(for: "00DA:005U", authenticatedOrgID: nil))
        #expect(!SessionAuthPolicy.mayLoadCache(for: "00DA:005U", authenticatedOrgID: "00DB:005V"))
        #expect(SessionAuthPolicy.mayLoadCache(for: "00DA:005U", authenticatedOrgID: "00DA:005U"))
    }

    @Test func cacheFileNameIsBoundToOrgID() {
        let a = LocalStore.cacheName(for: "00DA:005U")
        let b = LocalStore.cacheName(for: "00DB:005V")
        #expect(a == "cache-00DA-005U.json")
        #expect(a != b)
        #expect(!a.contains(":"))
    }

    @Test func identityMustMatchTokenURL() throws {
        let org = OrgIdentity(idURL: URL(string: "https://login.salesforce.com/id/00DORG/005USER")!)!
        let good = try identityInfo(org: "00DORG", user: "005USER")
        let badOrg = try identityInfo(org: "00DOTHER", user: "005USER")
        let badUser = try identityInfo(org: "00DORG", user: "005OTHER")
        #expect(SessionAuthPolicy.identityMatches(good, org: org))
        #expect(!SessionAuthPolicy.identityMatches(badOrg, org: org))
        #expect(!SessionAuthPolicy.identityMatches(badUser, org: org))
    }

    @Test func pendingConfirmRequiresMatchingSignInKey() {
        #expect(SessionAuthPolicy.pendingMatchesSignIn(pendingOrgKey: "00DA:005U", signInKey: "00DA:005U"))
        #expect(!SessionAuthPolicy.pendingMatchesSignIn(pendingOrgKey: "00DA:005U", signInKey: "00DB:005V"))
        #expect(!SessionAuthPolicy.pendingMatchesSignIn(pendingOrgKey: "", signInKey: ""))
    }

    @Test func rejectLeavesStoreEmptyAndSkipsSync() async throws {
        let transport = StubTransport { _, _ in tokenJSON(access: "AT1", refresh: "RT1") }
        let store = InMemorySecretStore()
        let tokens = TokenManager(transport: transport, store: store)
        let request = AuthorizationRequest(loginURL: LoginEnvironment.sandbox.loginURL, config: OAuthConfig(consumerKey: "KEY"))
        let signIn = try await tokens.exchangeSignIn(request, code: "CODE")
        #expect(store.accounts.isEmpty)

        var flow = Onboarding(step: .confirming(.sandbox, PendingOrg(
            orgKey: signIn.identity.key, orgName: "Acme", username: "u@acme", kind: .sandbox,
            instanceHost: "acme--uat.sandbox.my.salesforce.com",
            expectedLoginHost: "test.salesforce.com", hostMismatch: false
        )))
        let rejected = flow.send(.rejectOrg)
        #expect(rejected)
        #expect(flow.step == .connect(.sandbox))
        await tokens.discard(signIn)
        #expect(store.accounts.isEmpty)
        // Premature confirm after reject must not apply.
        let premature = flow.send(.confirmOrg)
        #expect(!premature)
    }

    @Test func mismatchedIdentityBlocksCommitPath() async throws {
        let transport = StubTransport { _, _ in tokenJSON(access: "AT1", refresh: "RT1") }
        let store = InMemorySecretStore()
        let tokens = TokenManager(transport: transport, store: store)
        let request = AuthorizationRequest(loginURL: LoginEnvironment.production.loginURL, config: OAuthConfig(consumerKey: "KEY"))
        let signIn = try await tokens.exchangeSignIn(request, code: "CODE")
        let foreign = try identityInfo(org: "00DFOREIGN", user: "005USER", username: "x")
        #expect(!SessionAuthPolicy.identityMatches(foreign, org: signIn.identity))
        // App must discard and leave Keychain empty when identity mismatches.
        await tokens.discard(signIn)
        #expect(store.accounts.isEmpty)
        #expect(!SessionAuthPolicy.pendingMatchesSignIn(pendingOrgKey: "00DFOREIGN:005USER", signInKey: signIn.identity.key))
    }
}

func identityInfo(org: String, user: String, username: String = "u@x") throws -> IdentityInfo {
    let data = Data("""
    {"username":"\(username)","display_name":"U","organization_id":"\(org)","user_id":"\(user)"}
    """.utf8)
    return try JSONDecoder().decode(IdentityInfo.self, from: data)
}
