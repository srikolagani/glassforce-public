import Foundation
import Testing
@testable import GlassforceCore

private final class MutableTransport: HTTPTransport, @unchecked Sendable {
    var hits = 0
    var response: HTTPResponse
    init(response: HTTPResponse) { self.response = response }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        hits += 1
        return response
    }
}

private struct KeychainLikeStore: SecretStore {
    var persistsInLoginKeychain: Bool { true }
    func read(account: String) throws -> Data? { nil }
    func write(_ data: Data, account: String) throws {}
    func delete(account: String) throws {}
}

@Suite("QA isolation")
struct IsolationTests {
    @Test func preferenceWritesStayInTheirDomain() {
        let production = MemoryPreferenceStore(domain: ProcessIdentity.productionDomain)
        let qa = MemoryPreferenceStore(domain: ProcessIdentity.qaDomain)
        production.set("live", forKey: PreferenceKeys.consumerKeyOverride)
        production.set(["001": 3], forKey: PreferenceKeys.recordOpens)
        qa.set("qa", forKey: PreferenceKeys.consumerKeyOverride)
        qa.set(["006": 1], forKey: PreferenceKeys.recordOpens)
        #expect(production.string(forKey: PreferenceKeys.consumerKeyOverride) == "live")
        #expect(qa.string(forKey: PreferenceKeys.consumerKeyOverride) == "qa")
        #expect(production.dictionary(forKey: PreferenceKeys.recordOpens)?["001"] == 3)
        #expect(qa.dictionary(forKey: PreferenceKeys.recordOpens)?["006"] == 1)
        #expect(production.dictionary(forKey: PreferenceKeys.recordOpens)?["006"] == nil)
        #expect(qa.dictionary(forKey: PreferenceKeys.recordOpens)?["001"] == nil)
    }

    @Test func qaRejectsProductionFilesDomainAndKeychain() {
        let production = URL(fileURLWithPath: "/tmp/Library/Application Support/Glassforce", isDirectory: true)
        let qaRoot = URL(fileURLWithPath: "/tmp/gf-qa-root", isDirectory: true)
        let prefs = MemoryPreferenceStore(domain: ProcessIdentity.qaDomain)
        let memory = InMemorySecretStore()
        let trap = MutableTransport(response: HTTPResponse(status: 200))
        #expect(QAIsolation.make(fileRoot: production, productionRoot: production, preferences: prefs, secrets: memory, innerTransport: trap).error == .overlapsProductionFiles)
        let inside = production.appendingPathComponent("cache", isDirectory: true)
        #expect(QAIsolation.make(fileRoot: inside, productionRoot: production, preferences: prefs, secrets: memory, innerTransport: trap).error == .overlapsProductionFiles)
        let parent = URL(fileURLWithPath: "/tmp/Library/Application Support", isDirectory: true)
        #expect(QAIsolation.make(fileRoot: parent, productionRoot: production, preferences: prefs, secrets: memory, innerTransport: trap).error == .overlapsProductionFiles)
        let livePrefs = MemoryPreferenceStore(domain: ProcessIdentity.productionDomain)
        #expect(QAIsolation.make(fileRoot: qaRoot, productionRoot: production, preferences: livePrefs, secrets: memory, innerTransport: trap).error == .productionPreferenceDomain)
        #expect(QAIsolation.make(fileRoot: qaRoot, productionRoot: production, preferences: prefs, secrets: KeychainLikeStore(), innerTransport: trap).error == .loginKeychainNotAllowed)
        let outside = FolderSecretStore(directory: URL(fileURLWithPath: "/tmp/other-secrets", isDirectory: true))
        #expect(QAIsolation.make(fileRoot: qaRoot, productionRoot: production, preferences: prefs, secrets: outside, innerTransport: trap).error == .credentialFolderOutsideRoot)
        #expect(QAIsolation.make(fileRoot: URL(string: "https://login.salesforce.com")!, productionRoot: production, preferences: prefs, secrets: memory, innerTransport: trap).error == .notAFileURL)
    }

    @Test func qaAcceptsMemoryAndFolderUnderItsRoot() throws {
        let production = URL(fileURLWithPath: "/tmp/Library/Application Support/Glassforce", isDirectory: true)
        let qaRoot = URL(fileURLWithPath: "/tmp/gf-qa-root", isDirectory: true)
        let prefs = MemoryPreferenceStore(domain: ProcessIdentity.qaDomain)
        let trap = MutableTransport(response: HTTPResponse(status: 200))
        let memory = try QAIsolation.make(fileRoot: qaRoot, productionRoot: production, preferences: prefs, secrets: InMemorySecretStore(), innerTransport: trap).get()
        #expect(memory.preferences.domain == ProcessIdentity.qaDomain)
        #expect(memory.secrets.persistsInLoginKeychain == false)
        let folder = FolderSecretStore(directory: qaRoot.appendingPathComponent("secrets", isDirectory: true))
        let filed = try QAIsolation.make(fileRoot: qaRoot, productionRoot: production, preferences: prefs, secrets: folder, innerTransport: trap).get()
        try filed.secrets.write(Data("token".utf8), account: "org")
        #expect(try filed.secrets.read(account: "org") == Data("token".utf8))
        try? FileManager.default.removeItem(at: qaRoot.appendingPathComponent("secrets", isDirectory: true))
    }

    @Test func loopbackGuardBlocksHostsRedirectsAndOpen() async throws {
        let inner = MutableTransport(response: HTTPResponse(status: 204))
        let guard_ = GuardingTransport(inner: inner, policy: .loopbackOnly)
        await #expect(throws: EgressError.blockedHost) {
            _ = try await guard_.send(HTTPRequest(url: URL(string: "https://login.salesforce.com/services/oauth2/authorize")!))
        }
        #expect(inner.hits == 0)
        await #expect(throws: EgressError.blockedHost) {
            _ = try await guard_.send(HTTPRequest(url: URL(string: "https://user:secret@127.0.0.1/token")!))
        }
        await #expect(throws: EgressError.blockedHost) {
            _ = try await guard_.send(HTTPRequest(url: URL(string: "dev.glassforce.app://oauth/callback")!))
        }
        inner.response = HTTPResponse(status: 302, headers: ["Location": "https://login.salesforce.com/evil"])
        await #expect(throws: EgressError.blockedRedirect) {
            _ = try await guard_.send(HTTPRequest(url: URL(string: "http://127.0.0.1:9/start")!))
        }
        #expect(inner.hits == 1)
        inner.response = HTTPResponse(status: 200)
        let ok = try await guard_.send(HTTPRequest(url: URL(string: "http://localhost:9/mock")!))
        #expect(ok.status == 200)
        #expect(URLOpenGate.allows(URL(string: "https://login.salesforce.com/packaging/installPackage.apexp")!, policy: .loopbackOnly) == false)
        #expect(URLOpenGate.allows(URL(string: "http://127.0.0.1:9/mock/install")!, policy: .loopbackOnly))
        #expect(URLOpenGate.allows(URL(string: "https://login.salesforce.com/")!, policy: .unrestricted))
    }

    @Test func symlinkParentAndMissingSuffixOverlapFailBeforeWrite() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gf-iso-\(UUID().uuidString)", isDirectory: true)
        let prod = base.appendingPathComponent("prod", isDirectory: true)
        try FileManager.default.createDirectory(at: prod, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let linkParent = base.appendingPathComponent("linkparent")
        try FileManager.default.createSymbolicLink(at: linkParent, withDestinationURL: prod)
        let qaRoot = linkParent.appendingPathComponent("qa-root", isDirectory: true)
        let secrets = qaRoot.appendingPathComponent("secrets", isDirectory: true)
        let prefs = MemoryPreferenceStore(domain: ProcessIdentity.qaDomain)
        let trap = MutableTransport(response: HTTPResponse(status: 200))
        let linked = QAIsolation.make(
            fileRoot: qaRoot,
            productionRoot: prod,
            preferences: prefs,
            secrets: FolderSecretStore(directory: secrets),
            innerTransport: trap
        )
        #expect(linked.error == .overlapsProductionFiles)
        #expect(FileManager.default.fileExists(atPath: prod.appendingPathComponent("qa-root/secrets/org.secret").path) == false)
        let missingInside = prod.appendingPathComponent("missing/qa-root", isDirectory: true)
        let inside = QAIsolation.make(fileRoot: missingInside, productionRoot: prod, preferences: prefs, secrets: InMemorySecretStore(), innerTransport: trap)
        #expect(inside.error == .overlapsProductionFiles)
        #expect(FileManager.default.fileExists(atPath: missingInside.path) == false)
        let sibling = base.appendingPathComponent("other/qa-root", isDirectory: true)
        let allowed = try QAIsolation.make(fileRoot: sibling, productionRoot: prod, preferences: prefs, secrets: InMemorySecretStore(), innerTransport: trap).get()
        #expect(allowed.fileRoot.path.hasSuffix("/other/qa-root"))
        #expect(FileManager.default.fileExists(atPath: sibling.path) == false)
    }

    @Test func openerBlocksSalesforceBeforeTheCallback() {
        final class Box: @unchecked Sendable { var opened: [URL] = [] }
        let box = Box()
        let opener = RecordOpener(policy: .loopbackOnly) { box.opened.append($0) }
        let salesforce = URL(string: "https://login.salesforce.com/lightning/r/Account/001/view")!
        let local = URL(string: "http://127.0.0.1:9/lightning/r/Account/001/view")!
        #expect(opener.open(Record(id: "001", kind: .account, title: "Acme", subtitle: "", url: salesforce)) == nil)
        #expect(box.opened.isEmpty)
        #expect(opener.open(Record(id: "001", kind: .account, title: "Acme", subtitle: "", url: local)) == local)
        #expect(box.opened == [local])
    }

    @Test func localhostFixturesStayOnLoopback() {
        let rows = LocalhostFixtures.records()
        #expect(rows.count == FakeData.records.count)
        #expect(LocalhostFixtures.badge.contains("127.0.0.1"))
        #expect(rows.allSatisfy { $0.url?.host == "127.0.0.1" })
        let opener = RecordOpener(policy: .loopbackOnly) { _ in }
        #expect(rows.allSatisfy { opener.open($0) != nil })
    }

    @Test func panelQARequirementsAreTheIsolatedPanel() {
        let requirements = PanelQARequirements.current
        #expect(requirements.bundleDomain == ProcessIdentity.qaDomain)
        #expect(requirements.preferenceDomain == ProcessIdentity.qaDomain)
        #expect(requirements.registersHotKey == false)
        #expect(requirements.presentsPanelOnLaunch)
        #expect(requirements.usesLoginKeychain == false)
        #expect(requirements.usesURLSession == false)
        #expect(requirements.egress == .loopbackOnly)
    }

    @Test func releaseDeniesQAActivationAndDoesNotSelectMock() {
        let plain = ["Glassforce"]
        #expect(ReleaseBoundary.activation(arguments: plain, channel: .release) == .notRequested)
        #expect(ReleaseBoundary.explicitlyRequestsMock(plain) == false)
        #expect(LaunchOptions(arguments: plain).mockSalesforce == false)
        #expect(LaunchOptions(arguments: plain).qaForeground == false)
        #expect(ReleaseBoundary.activation(arguments: plain + ["--qa-foreground"], channel: .release) == .ignored)
        #expect(ReleaseBoundary.activation(arguments: plain + ["--qa-foreground"], channel: .debug) == .presentationOnly)
        #expect(ReleaseBoundary.activation(arguments: plain + ["--qa-isolated"], channel: .release) == .denied)
        #expect(ReleaseBoundary.activation(arguments: plain + ["--qa-isolated"], channel: .debug) == .denied)
        #expect(ReleaseBoundary.explicitlyRequestsMock(plain + ["--mock-salesforce"]))
        #expect(ReleaseBoundary.explicitlyRequestsMock(plain + ["--demo-walkthrough"]))
    }

    @Test func qaCommandFailsClosedAndDoesNotUseProductionRoot() throws {
        let production = FileManager.default.temporaryDirectory.appendingPathComponent("gf-prod-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: production) }
        let marker = production.appendingPathComponent("recordOpens")
        try Data("live".utf8).write(to: marker)
        let denied = QACommandRunner.run(arguments: ["GlassforceQA", "--root", production.path, "--command", "check"], productionRoot: production)
        #expect(denied.error == .overlapsProductionFiles)
        #expect(try Data(contentsOf: marker) == Data("live".utf8))
        let missing = QACommandRunner.run(arguments: ["GlassforceQA", "--command", "check"], productionRoot: production)
        #expect(missing.error == .missingRoot)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gf-qa-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let check = try QACommandRunner.run(arguments: ["GlassforceQA", "--root", root.path, "--command", "check"], productionRoot: production).get()
        #expect(check.contains("identity=qa"))
        #expect(check.contains("secrets=memory"))
        #expect(check.contains("network=loopback"))
        let search = try QACommandRunner.run(arguments: ["GlassforceQA", "--root", root.path, "--command", "search", "--query", "acme"], productionRoot: production).get()
        #expect(search.hasPrefix("results="))
        #expect(search != "results=0")
        let stage = try QACommandRunner.run(
            arguments: ["GlassforceQA", "--root", root.path, "--command", "stage", "--sentence", "move acme deal to closed won"],
            productionRoot: production
        ).get()
        #expect(stage.contains("before=Negotiation"))
        #expect(!stage.contains("Closes"))
        #expect(try Data(contentsOf: marker) == Data("live".utf8))
    }
}

private extension Result where Failure == IsolationError {
    var error: IsolationError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
