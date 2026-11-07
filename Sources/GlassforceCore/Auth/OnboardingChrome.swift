import Foundation

/// Which onboarding primaries may be activated by Return (`.keyboardShortcut(.defaultAction)`).
/// Network / browser actions must never be keyboard-default — a stray Return after Option-Space
/// (or key repeat) was observed opening the install page and starting ASWebAuthenticationSession
/// with no click (QA round 3–4). Live network actions also require `NetworkActionGate` + a
/// click-only control; Cancel must end auth (no restart from a stale ASWebAuth completion).
public enum OnboardingChrome: Sendable {
    public enum PrimaryKind: String, Sendable {
        case welcomeGetStarted
        case hotkeyContinue
        case installPackage
        case installProceed
        case connect
        case connectingCancel
        case confirmUseOrg
        case failedRetry
        case doneStartSearching
    }

    /// Return may activate only local-only steps. Install / Proceed / Connect / Confirm require a click.
    public static func allowsKeyboardDefault(for kind: PrimaryKind) -> Bool {
        switch kind {
        case .welcomeGetStarted, .hotkeyContinue, .doneStartSearching, .connectingCancel:
            return true
        case .installPackage, .installProceed, .connect, .confirmUseOrg, .failedRetry:
            return false
        }
    }

    /// Steps whose primary can open a browser, start OAuth, or write the Keychain.
    public static func isNetworkOrBrowser(_ kind: PrimaryKind) -> Bool {
        switch kind {
        case .installPackage, .installProceed, .connect, .confirmUseOrg, .failedRetry:
            return true
        case .welcomeGetStarted, .hotkeyContinue, .connectingCancel, .doneStartSearching:
            return false
        }
    }
}
