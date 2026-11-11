import Testing
@testable import GlassforceCore

@Suite("Onboarding confirmation recovery")
struct OnboardingConfirmationFailureTests {
    @Test func failedCommitOrSyncLeavesSpinnerAndCanRetry() {
        let error = AuthError.server("Fixture storage failure")
        var flow = Onboarding(step: .syncing(org: "fixture", progress: .starting))
        let failed = flow.send(.syncFailed(.sandbox, error)); #expect(failed)
        #expect(flow.step == .failed(.sandbox, error))
        let retry = flow.send(.connect); #expect(retry)
        #expect(flow.step == .connecting(.sandbox))
    }
    @Test func staleSyncFailureDoesNotReplaceAnotherStep() {
        var flow = Onboarding(step: .connect(.production))
        let stale = flow.send(.syncFailed(.sandbox, .cancelled)); #expect(!stale)
        #expect(flow.step == .connect(.production))
    }
}
