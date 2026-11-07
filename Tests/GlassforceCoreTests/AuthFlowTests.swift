import Foundation
import Testing
@testable import GlassforceCore

@Suite("Auth flow — click, cancel, no timer")
struct AuthFlowTests {
    @Test func plainLaunchShowsNothingAndDoesNotActivate() {
        let presentation = LaunchForegroundPolicy.onLaunch(qaForeground: false, debugBuild: false, explicitUI: false)
        #expect(presentation == .hidden)
        #expect(!LaunchForegroundPolicy.mayActivateAndKey(qaForeground: false, debugBuild: false))
        #expect(!LaunchForegroundPolicy.mayActivateAndKey(qaForeground: false, debugBuild: true))
    }

    @Test func qaForegroundActivatesOnlyInDebug() {
        #expect(LaunchForegroundPolicy.onLaunch(qaForeground: true, debugBuild: true, explicitUI: false) == .keyAndActive)
        #expect(LaunchForegroundPolicy.mayActivateAndKey(qaForeground: true, debugBuild: true))
        // Release parses the flag and ignores it.
        #expect(LaunchForegroundPolicy.onLaunch(qaForeground: true, debugBuild: false, explicitUI: false) == .hidden)
        #expect(!LaunchForegroundPolicy.mayActivateAndKey(qaForeground: true, debugBuild: false))
    }

    @Test func explicitScreenshotLaunchIsVisibleButNotKey() {
        let presentation = LaunchForegroundPolicy.onLaunch(qaForeground: false, debugBuild: true, explicitUI: true)
        #expect(presentation == .visibleInactive)
        #expect(presentation != .keyAndActive)
    }

    @Test func onlyAClickStartsConnect() {
        var flow = AuthFlow()
        #expect(flow.beginConnect(.demoProgrammatic, demoMode: false) == nil)
        #expect(flow.connectStarts == 0)
        #expect(flow.phase == .idle)
        let id = flow.beginConnect(.mouseClick, demoMode: false)
        #expect(id != nil)
        #expect(flow.connectStarts == 1)
        #expect(flow.acceptsCallback(id!))
        #expect(flow.beginConnect(.accessibility, demoMode: false) != nil)
        #expect(flow.connectStarts == 2)
    }

    @Test func cancelEndsTheAttemptAndDoesNotRestart() {
        var flow = AuthFlow()
        let id = flow.beginConnect(.mouseClick, demoMode: false)!
        let starts = flow.connectStarts
        flow.cancel()
        #expect(flow.phase == .ended)
        #expect(flow.connectStarts == starts)
        #expect(!flow.acceptsCallback(id))
        #expect(!flow.acceptsCallback(UUID()))
        // A stale callback must not be able to begin work. Only a new click can.
        #expect(flow.beginConnect(.demoProgrammatic, demoMode: false) == nil)
        #expect(flow.connectStarts == starts)
        #expect(flow.phase == .ended)
        let again = flow.beginConnect(.mouseClick, demoMode: false)
        #expect(again != nil)
        #expect(again != id)
        #expect(flow.connectStarts == starts + 1)
        #expect(flow.acceptsCallback(again!))
        #expect(!flow.acceptsCallback(id))
    }

    @Test func fourSecondTicksNeverStartOrRepeatWork() {
        var flow = AuthFlow()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(flow.beginConnect(.mouseClick, demoMode: false) != nil)
        let starts = flow.connectStarts
        // QA saw install / auth re-fire about every 4 seconds. Nothing on the clock may do that.
        for seconds in stride(from: 0, through: 20, by: 4) {
            let due = flow.actionsDue(at: start.addingTimeInterval(TimeInterval(seconds)), since: start)
            #expect(due.isEmpty)
            #expect(flow.connectStarts == starts)
        }
        flow.cancel()
        for seconds in stride(from: 0, through: 20, by: 4) {
            #expect(flow.actionsDue(at: start.addingTimeInterval(TimeInterval(seconds)), since: start).isEmpty)
        }
        #expect(flow.connectStarts == starts)
        #expect(flow.phase == .ended)
    }

    @Test func liveInstallUsesTheSystemBrowserNotAnAuthSheet() {
        #expect(InstallOpen.choose(demoMode: false) == .systemBrowser)
        #expect(InstallOpen.choose(demoMode: true) == .demoSheet)
    }

    @Test func buildScriptReadsTheShippedKeyAndDoesNotEmbedIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        let packaged = try String(contentsOf: root.appendingPathComponent("Sources/GlassforceCore/Auth/PackagedApp.swift"), encoding: .utf8)
        #expect(script.contains("shippedConsumerKey"))
        #expect(script.contains("shippedPackageVersionID"))
        #expect(!script.contains("3MVG"), "client id literal belongs only in PackagedApp.swift")
        #expect(packaged.contains("shippedConsumerKey"))
    }
}
