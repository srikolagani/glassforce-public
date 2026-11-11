import Foundation
import Testing
@testable import GlassforceKit
import GlassforceCore

@Suite("Confirmed write app integration")
@MainActor
struct ConfirmedWriteIntegrationTests {
    @Test func duplicateConfirmSendsOnceAndRefreshesTheCache() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        let tokens = TokenManager(transport: mock, store: InMemorySecretStore())
        let request = AuthorizationRequest(loginURL: mock.loginURL(for: .production), config: OAuthConfig(consumerKey: MockSalesforce.consumerKey))
        _ = try await mock.send(HTTPRequest(url: request.url))
        var approve = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        approve.path = mock.loginURL(for: .production).path + "/mock/approve"
        let redirect = try await mock.send(HTTPRequest(url: approve.url!))
        let callback = URL(string: try #require(redirect.headers["Location"]))!
        let code = try request.parseCallback(callback).get()
        let signIn = try await tokens.completeSignIn(request, code: code)
        let org = OrgProfile(id: signIn.identity.key, orgName: "Fixture", username: "user@example.com", kind: .production,
                             loginURL: request.loginURL, instanceURL: signIn.credentials.instanceURL, isDefault: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glassforce-write-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = LocalStore(directory: root)
        try local.saveDirectory(OrgDirectory(orgs: [org]))
        let prefs = MemoryPreferenceStore(domain: ProcessIdentity.qaDomain)
        let model = CommandBarModel(store: RecordStore(records: FakeData.records), preferences: prefs, egress: .loopbackOnly)
        let session = AppSession(mode: .mock, tokens: tokens, local: local, mock: mock, searchModel: model, preferences: prefs, egress: .loopbackOnly)
        var pending = PendingWrite()
        pending.setOrg(org.id)
        pending.stage(query: "move acme deal to closed won", records: FakeData.records)
        let write = try #require(pending.confirmed())
        let first = Task { await session.applyConfirmed(write) }
        let second = Task { await session.applyConfirmed(write) }
        await first.value
        await second.value
        #expect(mock.patchBodies.count == 1)
        let patchIndex = try #require(mock.dataRequests.firstIndex(where: { $0.hasPrefix("PATCH ") }))
        #expect(mock.dataRequests.dropFirst(patchIndex + 1).contains { $0.hasPrefix("GET /query") },
                "A successful write must refresh the local cache, not leave the old stage on screen")
        #expect(model.notice?.hasPrefix("Updated ") == true)
    }
}
