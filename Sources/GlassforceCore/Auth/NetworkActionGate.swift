import Foundation

/// How a network / browser onboarding action was requested.
///
/// Only an explicit user mouse click (or VoiceOver activate) may open the install
/// page, start OAuth, or confirm into the Keychain. Demo walkthrough may pass
/// `demoProgrammatic` when `demoMode` is true. Space, Return, timers, and stale
/// Task completions must not qualify.
public enum NetworkActionTrigger: String, Sendable, Equatable {
    case mouseClick
    case accessibility
    case demoProgrammatic
}

public enum NetworkActionGate: Sendable {
    /// Whether `trigger` may run openInstallPage / skipInstall / connectChosen /
    /// confirmPendingOrg / proceedToNextStep / retry.
    public static func allows(_ trigger: NetworkActionTrigger, demoMode: Bool) -> Bool {
        switch trigger {
        case .mouseClick, .accessibility:
            return true
        case .demoProgrammatic:
            return demoMode
        }
    }
}
