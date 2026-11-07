import Foundation
import Testing
@testable import GlassforceCore

@Suite("Onboarding flow")
struct OnboardingTests {
    @Test func stepOrderInstallThenConnectThenConfirm() {
        var flow = Onboarding()
        #expect(flow.step == .welcome)
        _ = flow.send(.next); #expect(flow.step == .hotkey)
        _ = flow.send(.next); #expect(flow.step == .install)
        let early = flow.send(.connect); #expect(!early)    // no connecting before the install step
        _ = flow.send(.installStepDone(.sandbox)); #expect(flow.step == .connect(.sandbox))
        _ = flow.send(.connect); #expect(flow.step == .connecting(.sandbox))
        let pending = PendingOrg(
            orgKey: "O:U", orgName: "Acme", username: "u@acme", kind: .sandbox,
            instanceHost: "acme--uat.sandbox.my.salesforce.com",
            expectedLoginHost: "test.salesforce.com", hostMismatch: false
        )
        _ = flow.send(.orgDiscovered(pending)); #expect(flow.step == .confirming(.sandbox, pending))
        // Confirm is required before sync — reject goes back to Connect without syncing.
        var rejected = Onboarding(step: .confirming(.sandbox, pending))
        _ = rejected.send(.rejectOrg); #expect(rejected.step == .connect(.sandbox))
        _ = flow.send(.confirmOrg); #expect(flow.step == .syncing(org: "O:U", progress: .starting))
        let progress = SyncProgress(currentObject: "Accounts", recordsSynced: 5, objectsDone: 1, totalObjects: 5)
        _ = flow.send(.syncProgressed(progress)); #expect(flow.step == .syncing(org: "O:U", progress: progress))
        _ = flow.send(.syncFinished); #expect(flow.step == .done(org: "O:U"))
        _ = flow.send(.finish); #expect(flow.step == .finished)
    }

    @Test func confirmGatingIgnoresPrematureConfirm() {
        var flow = Onboarding(step: .connecting(.production))
        let applied = flow.send(.confirmOrg)
        #expect(!applied)
        #expect(flow.step == .connecting(.production))
    }

    @Test func cancellingTheBrowserReturnsToConnect() {
        var flow = Onboarding(step: .connecting(.production))
        flow.send(.signInFailed(.cancelled))
        #expect(flow.step == .connect(.production))
    }

    @Test func failuresShowAnErrorAndCanRetry() {
        var flow = Onboarding(step: .connecting(.production))
        flow.send(.signInFailed(.offline))
        #expect(flow.step == .failed(.production, .offline))
        #expect(!AuthError.offline.offersBackToInstall)
        flow.send(.connect)
        #expect(flow.step == .connecting(.production))
        flow.send(.signInFailed(.offline)); flow.send(.back)
        #expect(flow.step == .connect(.production))
    }

    @Test func addAnotherOrgStartsAtInstall() {
        var flow = Onboarding(step: .done(org: "A"))
        flow.send(.addAnotherOrg)
        #expect(flow.step == .install)
    }

    @Test func ignoresEventsThatDontApply() {
        var flow = Onboarding()
        let first = flow.send(.syncFinished)
        let second = flow.send(.installStepDone(.sandbox))
        #expect(!first && !second)
        #expect(flow.step == .welcome)
    }

    @Test func backNavigation() {
        var flow = Onboarding(step: .connect(.sandbox))
        flow.send(.back); #expect(flow.step == .install)
        flow.send(.back); #expect(flow.step == .hotkey)
        flow.send(.back); #expect(flow.step == .welcome)
    }
}

@Suite("Org directory")
struct OrgDirectoryTests {
    func profile(_ id: String, kind: OrgKind = .production) -> OrgProfile {
        OrgProfile(id: id, orgName: "Org \(id)", username: "u@\(id)", kind: kind,
                   loginURL: URL(string: "https://login.salesforce.com")!, instanceURL: URL(string: "https://x.my.salesforce.com")!)
    }

    @Test func firstOrgBecomesDefaultAndOnlyOneDefault() {
        var directory = OrgDirectory()
        directory.upsert(profile("A"))
        directory.upsert(profile("B", kind: .sandbox))
        #expect(directory.defaultOrg?.id == "A")
        directory.setDefault("B")
        #expect(directory.defaultOrg?.id == "B")
        #expect(directory.orgs.filter(\.isDefault).count == 1)
    }

    @Test func removingTheDefaultPromotesAnother() {
        var directory = OrgDirectory()
        directory.upsert(profile("A")); directory.upsert(profile("B"))
        directory.remove("A")
        #expect(directory.defaultOrg?.id == "B")
    }

    @Test func statusAndSyncBookkeeping() {
        var directory = OrgDirectory()
        directory.upsert(profile("A"))
        directory.setStatus(.needsSignIn, for: "A")
        #expect(directory.org("A")?.status == .needsSignIn)
        directory.recordSync("A", count: 42, at: Date(timeIntervalSince1970: 0))
        #expect(directory.org("A")?.status == .connected)
        #expect(directory.org("A")?.recordCount == 42)
    }

    @Test func persistsAsJSONWithoutTokens() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let local = LocalStore(directory: folder)
        var directory = OrgDirectory()
        directory.upsert(profile("A", kind: .sandbox))
        try local.saveDirectory(directory)
        #expect(local.loadDirectory() == directory)
        let raw = try String(contentsOf: folder.appendingPathComponent("orgs.json"), encoding: .utf8)
        #expect(!raw.lowercased().contains("token"))
        try? FileManager.default.removeItem(at: folder)
    }
}


@Suite("Org kind badges")
struct OrgKindBadgeTests {
    @Test func badgeTitlesAreSentenceCaseNotShoutyCaps() {
        #expect(OrgKind.production.badgeTitle == "Production")
        #expect(OrgKind.sandbox.badgeTitle == "Sandbox")
        #expect(OrgKind.developer.badgeTitle == "Developer")
        for kind in OrgKind.allCases {
            #expect(kind.badgeTitle != kind.badgeTitle.uppercased())
        }
    }
}
