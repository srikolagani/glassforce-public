import Testing
@testable import GlassforceCore

@Suite("Onboarding chrome — no keyboard-default network actions")
struct OnboardingChromeTests {
    @Test func networkOrBrowserPrimariesRejectKeyboardDefault() {
        let network: [OnboardingChrome.PrimaryKind] = [
            .installPackage, .installProceed, .connect, .confirmUseOrg, .failedRetry
        ]
        for kind in network {
            #expect(OnboardingChrome.isNetworkOrBrowser(kind))
            #expect(!OnboardingChrome.allowsKeyboardDefault(for: kind),
                    "\(kind) must not be Return-activated (QA round 3 auto-open)")
        }
    }

    @Test func localOnlyPrimariesMayUseKeyboardDefault() {
        let local: [OnboardingChrome.PrimaryKind] = [
            .welcomeGetStarted, .hotkeyContinue, .doneStartSearching, .connectingCancel
        ]
        for kind in local {
            #expect(!OnboardingChrome.isNetworkOrBrowser(kind))
            #expect(OnboardingChrome.allowsKeyboardDefault(for: kind))
        }
    }

    @Test func everyPrimaryKindIsClassified() {
        for kind in [OnboardingChrome.PrimaryKind.welcomeGetStarted, .hotkeyContinue, .installPackage,
                     .installProceed, .connect, .connectingCancel, .confirmUseOrg, .failedRetry, .doneStartSearching] {
            // Network kinds never allow keyboard default; local kinds may.
            if OnboardingChrome.isNetworkOrBrowser(kind) {
                #expect(!OnboardingChrome.allowsKeyboardDefault(for: kind))
            } else {
                #expect(OnboardingChrome.allowsKeyboardDefault(for: kind))
            }
        }
    }

    @Test func coldLaunchFlagsDoNotEnableDemoAutoInstall() {
        let opts = LaunchOptions(arguments: ["Glassforce"])
        #expect(!opts.demoWalkthrough)
        #expect(!opts.mockSalesforce)
        #expect(opts.onboardingStep == nil)
        #expect(!opts.forceOnboarding)
        #expect(!opts.fakeData)
    }
}
