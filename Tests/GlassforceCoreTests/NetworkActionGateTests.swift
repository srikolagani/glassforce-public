import Testing
@testable import GlassforceCore

@Suite("Network action gate — click only")
struct NetworkActionGateTests {
    @Test func mouseClickAndAccessibilityAlwaysAllowed() {
        for trigger in [NetworkActionTrigger.mouseClick, .accessibility] {
            #expect(NetworkActionGate.allows(trigger, demoMode: false))
            #expect(NetworkActionGate.allows(trigger, demoMode: true))
        }
    }

    @Test func demoProgrammaticRejectedOutsideDemo() {
        #expect(!NetworkActionGate.allows(.demoProgrammatic, demoMode: false),
                "programmatic openInstall/connect must not run on a normal launch")
        #expect(NetworkActionGate.allows(.demoProgrammatic, demoMode: true))
    }

    @Test func everyTriggerIsClassified() {
        for trigger in [NetworkActionTrigger.mouseClick, .accessibility, .demoProgrammatic] {
            let allowedInDemo = NetworkActionGate.allows(trigger, demoMode: true)
            let allowedLive = NetworkActionGate.allows(trigger, demoMode: false)
            #expect(allowedInDemo)
            if trigger == .demoProgrammatic {
                #expect(!allowedLive)
            } else {
                #expect(allowedLive)
            }
        }
    }
}

@Suite("Cancel ends auth — no stale confirm")
struct CancelEndsAuthTests {
    private var pending: PendingOrg {
        PendingOrg(
            orgKey: "00DxxCANCELTEST",
            orgName: "Acme",
            username: "qa@example.com",
            kind: .developer,
            instanceHost: "example.my.salesforce.com",
            expectedLoginHost: "login.salesforce.com",
            hostMismatch: false
        )
    }

    @Test func cancelReturnsToConnectAndRejectsStaleOrgDiscovered() {
        var onboarding = Onboarding(step: .connecting(.production))
        let cancelled = onboarding.send(.signInFailed(.cancelled))
        #expect(cancelled)
        guard case .connect(.production) = onboarding.step else {
            Issue.record("cancel must return to connect, got \(onboarding.step)")
            return
        }
        // Late ASWebAuth completion after cancel must not enter confirm (QA round 4 L1).
        let stale = onboarding.send(.orgDiscovered(pending))
        #expect(!stale, "stale orgDiscovered after cancel must be rejected")
        guard case .connect(.production) = onboarding.step else {
            Issue.record("step must stay on connect after rejected stale discovery")
            return
        }
    }

    @Test func freshConnectAfterCancelCanConfirmOnlyWithNewConnect() {
        var onboarding = Onboarding(step: .connecting(.sandbox))
        let cancelled = onboarding.send(.signInFailed(.cancelled))
        #expect(cancelled)
        let stale = onboarding.send(.orgDiscovered(pending))
        #expect(!stale)
        let reconnect = onboarding.send(.connect)
        #expect(reconnect)
        guard case .connecting(.sandbox) = onboarding.step else {
            Issue.record("expected connecting after explicit reconnect")
            return
        }
        let discovered = onboarding.send(.orgDiscovered(pending))
        #expect(discovered)
        guard case .confirming = onboarding.step else {
            Issue.record("expected confirming after fresh connect + discovery")
            return
        }
    }

    @Test func coldLaunchFlagsStillDisableDemoAutoInstall() {
        let opts = LaunchOptions(arguments: ["Glassforce"])
        #expect(!opts.demoWalkthrough)
        #expect(!opts.qaForeground)
        #expect(!opts.mockSalesforce)
    }

    @Test func qaForegroundFlagParses() {
        let opts = LaunchOptions(arguments: ["Glassforce", "--qa-foreground"])
        #expect(opts.qaForeground)
    }
}
