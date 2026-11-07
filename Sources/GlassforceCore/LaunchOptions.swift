/// Parsed command-line flags. Unknown flags are ignored so macOS-injected args don't break launch.
public struct LaunchOptions: Equatable, Sendable {
    public var showPanel = false
    public var query: String?
    /// Show without taking keyboard focus and never auto-hide (for screenshots).
    public var pin = false
    /// Draw a colorful backdrop window behind the panel (for screenshots / demos).
    public var backdrop = false
    /// Force light or dark appearance (screenshots); nil follows the system.
    public var appearance: Appearance?

    public enum Appearance: String, Sendable { case light, dark }

    /// Use the local fake Salesforce (OAuth + REST) instead of real orgs. Never touches a real org.
    public var mockSalesforce = false
    /// Wipe the (mock) sign-in state on launch, to start the first-run flow from scratch.
    public var resetState = false
    /// Drive onboarding → Sandbox → connect → sync → search automatically (implies mock + web view).
    public var demoWalkthrough = false
    /// Show the consent page in an in-app web view instead of ASWebAuthenticationSession (mock only).
    public var authWebView = false
    /// Show onboarding even when an org is already connected.
    public var forceOnboarding = false
    /// Search milestone 1's built-in fake records instead of a connected org.
    public var fakeData = false
    /// Mock: the packaged app is already installed (skip the install page).
    public var mockPreinstalled = false
    /// Mock: the person on the install page isn't an admin.
    public var mockNonAdmin = false
    /// Screenshots: open onboarding on a given step without clicking through.
    /// Values: `welcome`, `hotkey`, `install`, `install-opened`, `connect`, `confirm`, `confirm-mismatch`.
    public var onboardingStep: String?
    /// Read-only: explain why the default org's objects synced empty (counts/flags only, to the log), then quit.
    public var diagnoseSync = false
    /// DEV ONLY: create fictional sample records in the default org, only if its instance host equals this value.
    public var seedSampleDataHost: String?
    /// Proof hook: after sync, open the first result of this kind (e.g. `account`) through the normal open path.
    public var openFirst: String?
    /// Open Settings › Search objects on launch (screenshots; same window as ⌘, and the menu bar item).
    public var openSettings = false
    /// DEBUG / QA only: set activation policy to regular and key the onboarding window so
    /// System Events can target Return/Space. Parsed from `--qa-foreground`; AppDelegate
    /// honors it only under `#if DEBUG` (release ignores the flag).
    public var qaForeground = false

    public init() {}

    public init(arguments argv: [String]) {
        var it = argv.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--show-panel": showPanel = true
            case "--query": query = it.next()
            case "--pin": pin = true
            case "--backdrop": backdrop = true
            case "--mock-salesforce": mockSalesforce = true
            case "--reset-state": resetState = true
            case "--demo-walkthrough": demoWalkthrough = true; mockSalesforce = true; authWebView = true
            case "--auth-webview": authWebView = true
            case "--onboarding": forceOnboarding = true
            case "--fake-data": fakeData = true
            case "--mock-preinstalled": mockPreinstalled = true
            case "--mock-non-admin": mockNonAdmin = true
            case "--onboarding-step": onboardingStep = it.next(); forceOnboarding = true
            case "--diagnose-sync": diagnoseSync = true
            case "--open-first": openFirst = it.next()
            case "--seed-sample-data": seedSampleDataHost = it.next()
            case "--open-settings": openSettings = true
            case "--qa-foreground": qaForeground = true
            case "--appearance":
                if let value = it.next() { appearance = Appearance(rawValue: value) }
            default: break
            }
        }
    }
}
