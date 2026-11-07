import Testing
@testable import GlassforceCore

@Suite("Launch options")
struct LaunchOptionsTests {
    @Test func defaultsWithNoFlags() {
        let options = LaunchOptions(arguments: ["Glassforce"])
        #expect(options == LaunchOptions())
        #expect(options.appearance == nil)
        #expect(!options.showPanel && !options.pin && !options.backdrop)
    }

    @Test func parsesEveryFlag() {
        let options = LaunchOptions(arguments: [
            "Glassforce", "--show-panel", "--query", "acme", "--pin", "--backdrop", "--appearance", "dark",
        ])
        #expect(options.showPanel)
        #expect(options.query == "acme")
        #expect(options.pin)
        #expect(options.backdrop)
        #expect(options.appearance == .dark)
    }

    @Test func ignoresUnknownFlagsAndBadValues() {
        let options = LaunchOptions(arguments: ["Glassforce", "-NSDocumentRevisionsDebugMode", "YES", "--appearance", "sepia"])
        #expect(options.appearance == nil)
        #expect(options.query == nil)
    }

    @Test func demoWalkthroughImpliesMockAndWebView() {
        let options = LaunchOptions(arguments: ["Glassforce", "--demo-walkthrough", "--reset-state"])
        #expect(options.demoWalkthrough && options.mockSalesforce && options.authWebView && options.resetState)
        #expect(!LaunchOptions(arguments: ["Glassforce", "--mock-salesforce"]).authWebView)
        #expect(LaunchOptions(arguments: ["Glassforce", "--fake-data", "--onboarding"]).fakeData)
    }

    @Test func queryWithoutValueIsNil() {
        #expect(LaunchOptions(arguments: ["Glassforce", "--query"]).query == nil)
    }

    @Test func onboardingStepValues() {
        #expect(LaunchOptions(arguments: ["Glassforce", "--onboarding-step", "install"]).onboardingStep == "install")
        #expect(LaunchOptions(arguments: ["Glassforce", "--onboarding-step", "install-opened"]).onboardingStep == "install-opened")
        #expect(LaunchOptions(arguments: ["Glassforce", "--onboarding-step", "install-opened"]).forceOnboarding)
        #expect(LaunchOptions(arguments: ["Glassforce", "--onboarding-step", "welcome"]).onboardingStep == "welcome")
        #expect(LaunchOptions(arguments: ["Glassforce", "--onboarding-step", "hotkey"]).onboardingStep == "hotkey")
        #expect(LaunchOptions(arguments: ["Glassforce", "--onboarding-step", "confirm"]).onboardingStep == "confirm")
        #expect(LaunchOptions(arguments: ["Glassforce", "--onboarding-step", "confirm-mismatch"]).onboardingStep == "confirm-mismatch")
    }
}
