import Foundation
import Testing
@testable import GlassforceKit
import GlassforceCore

@MainActor
private final class FixturePresenter: AuthSessionPresenting {
    let mock: MockSalesforce
    init(_ mock: MockSalesforce) { self.mock = mock }
    func authenticate(url: URL, callbackScheme: String, ephemeral: Bool) async throws -> URL {
        _ = try await mock.send(HTTPRequest(url: url))
        var approve = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        approve.path = mock.loginURL(for: .production).path + "/mock/approve"
        let response = try await mock.send(HTTPRequest(url: approve.url!))
        return URL(string: try #require(response.headers["Location"]))!
    }
    func cancel() {}
}

@Suite("Onboarding confirmation integration")
@MainActor
struct OnboardingConfirmationIntegrationTests {
    @Test func authenticatedClickCommitsOnceAndCompletesSync() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        let secrets = InMemorySecretStore()
        let tokens = TokenManager(transport: mock, store: secrets)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glassforce-confirm-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = MemoryPreferenceStore(domain: ProcessIdentity.qaDomain)
        let model = CommandBarModel(store: RecordStore(records: []), preferences: prefs, egress: .loopbackOnly)
        let session = AppSession(mode: .mock, tokens: tokens, local: LocalStore(directory: root), mock: mock, searchModel: model, preferences: prefs, egress: .loopbackOnly)
        session.presenterFactory = { FixturePresenter(mock) }
        session.onboarding = Onboarding(step: .connect(.production))
        session.connectChosen(via: .mouseClick)
        for _ in 0..<200 {
            if session.pendingSignIn != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.pendingSignIn != nil)
        #expect(secrets.accounts.isEmpty)
        session.confirmPendingOrg(via: .mouseClick)
        session.confirmPendingOrg(via: .mouseClick)
        for _ in 0..<200 {
            if case .done = session.onboarding.step { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .done = session.onboarding.step else {
            Issue.record("Confirmation did not complete: \(session.onboarding.step)")
            return
        }
        #expect(secrets.writeLog.count == 1)
        #expect(session.directory.orgs.count == 1)
        #expect(mock.patchBodies.isEmpty)
    }
}
