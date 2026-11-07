import Foundation

/// How Glassforce may present a window at launch.
///
/// A normal launch stays in the menu bar. Raising a window and making it key is
/// what let launch-loop keystrokes (Space / Return, including a repeat about
/// every few seconds) hit Install and Connect. Only two launches may show UI
/// without a later click: an explicit screenshot/demo flag (inactive, not key)
/// and a Debug `--qa-foreground` run (key, so System Events can target it).
public enum WindowPresentation: Equatable, Sendable {
    /// Menu bar only. No window is created or ordered front.
    case hidden
    /// Window may be ordered front. The app stays accessory and the window is not key,
    /// so Space and Return keep going to whatever app was frontmost.
    case visibleInactive
    /// Debug `--qa-foreground` only. Regular activation policy, window is key.
    case keyAndActive
}

public enum LaunchForegroundPolicy: Sendable {
    /// `explicitUI` is an opt-in flag (`--onboarding`, `--onboarding-step`, `--backdrop`,
    /// `--demo-walkthrough`), not a plain launch.
    public static func onLaunch(qaForeground: Bool, debugBuild: Bool, explicitUI: Bool) -> WindowPresentation {
        if qaForeground && debugBuild { return .keyAndActive }
        if explicitUI { return .visibleInactive }
        return .hidden
    }

    /// Release builds never activate, even if the flag was parsed.
    public static func mayActivateAndKey(qaForeground: Bool, debugBuild: Bool) -> Bool {
        qaForeground && debugBuild
    }
}

/// Where the install page is allowed to open. Live installs use the default browser
/// (the admin page needs that session). They never use an auth sheet, ephemeral or not.
/// The in-app sheet exists only for `--demo-walkthrough`.
public enum InstallOpen: Equatable, Sendable {
    case systemBrowser
    case demoSheet

    public static func choose(demoMode: Bool) -> InstallOpen {
        demoMode ? .demoSheet : .systemBrowser
    }
}

/// Click-gate for install, connect, confirm, and retry.
///
/// Time passing never produces a network action. Cancel ends the in-flight attempt;
/// a later browser callback is ignored and does not start another one. A new attempt
/// starts only when `beginConnect` is called again with an allowed trigger.
public struct AuthFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case inFlight(UUID)
        case ended
    }

    public private(set) var phase: Phase = .idle
    /// How many OAuth attempts have been started. Cancel and timers do not increment this.
    public private(set) var connectStarts = 0

    public init() {}

    public func authorize(_ trigger: NetworkActionTrigger, demoMode: Bool) -> Bool {
        NetworkActionGate.allows(trigger, demoMode: demoMode)
    }

    /// Starts an OAuth attempt. Replaces any in-flight id. Returns nil when `trigger`
    /// is not a real click (or a demo trigger outside demo mode).
    @discardableResult
    public mutating func beginConnect(_ trigger: NetworkActionTrigger, demoMode: Bool) -> UUID? {
        guard authorize(trigger, demoMode: demoMode) else { return nil }
        let id = UUID()
        phase = .inFlight(id)
        connectStarts += 1
        return id
    }

    /// User cancel, or a failure that must not continue. Does not start a replacement attempt.
    public mutating func cancel() {
        phase = .ended
    }

    /// A browser callback may continue only while this exact attempt is still in flight.
    public func acceptsCallback(_ id: UUID) -> Bool {
        if case .inFlight(let current) = phase { return current == id }
        return false
    }

    /// Polled by anything that looks like a timer. Always empty: there is no retry schedule.
    public func actionsDue(at date: Date, since start: Date) -> [String] {
        _ = date
        _ = start
        return []
    }
}
