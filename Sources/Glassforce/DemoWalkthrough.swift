import AppKit
import GlassforceCore

/// `--demo-walkthrough`: plays the first-run flow on its own for recordings, through the same code
/// paths a person uses (onboarding state machine, mock OAuth over real HTTP, sync, search panel).
/// It never takes keyboard focus. The ⌥Space press is simulated by calling the hot key's action.
@MainActor
struct DemoWalkthrough {
    let session: AppSession
    let panel: PanelController
    let model: CommandBarModel
    let onboarding: OnboardingWindowController?

    func run() {
        Task { @MainActor in
            await pause(2.6)                                 // Welcome
            session.onboarding.send(.next)
            await pause(2.6)                                 // ⌥Space hint
            session.onboarding.send(.next)
            await pause(1.6)                                 // Step 1: Install Glassforce in your org
            session.pick(.sandbox)
            await pause(1.4)
            gfLog("Glassforce demo: Install Package (Sandbox)")
            session.openInstallPage(via: .demoProgrammatic)                        // Mock install page in a sheet, auto-clicks Install
            while !session.installAcknowledged {
                await pause(0.2)
            }
            gfLog("Glassforce demo: installed → Next: Connect")
            await pause(1.4)
            session.goToConnect()
            await pause(1.8)                                 // Step 2: Connect your org
            gfLog("Glassforce demo: Connect")
            session.connectChosen(via: .demoProgrammatic)                          // Web view consent page auto-approves
            // Wait for the confirm step (or failure), then accept the org.
            while true {
                if case .confirming = session.onboarding.step { break }
                if case .failed(_, let error) = session.onboarding.step {
                    gfLog("Glassforce demo: sign-in failed: %@", error.title); return
                }
                if isDone(session.onboarding.step) { break }
                await pause(0.2)
            }
            if case .confirming = session.onboarding.step {
                await pause(1.2)
                gfLog("Glassforce demo: Use this org")
                session.confirmPendingOrg(via: .demoProgrammatic)
            }
            while !isDone(session.onboarding.step) {
                if case .failed(_, let error) = session.onboarding.step {
                    gfLog("Glassforce demo: sync failed: %@", error.title); return
                }
                await pause(0.2)
            }
            await pause(3.0)                                 // "You're all set"
            onboarding?.close()
            session.onboarding.send(.finish)
            await pause(1.2)

            gfLog("Glassforce demo: Option-Space")
            panel.show()
            await pause(1.0)
            for character in "acme" {
                model.query.append(character)
                await pause(0.22)
            }
            await pause(2.4)
            model.moveSelection(by: 1); await pause(0.7)
            model.moveSelection(by: 1); await pause(2.2)
            gfLog("Glassforce demo: done")
        }
    }

    private func isDone(_ step: OnboardingStep) -> Bool {
        if case .done = step { return true }
        return false
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
