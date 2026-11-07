import AppKit
import SwiftUI
import Carbon.HIToolbox
import GlassforceCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController!
    private var hotKey: HotKey?
    private var session: AppSession?
    private var onboardingWindow: OnboardingWindowController?
    private var mockServer: MockServerHost?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var options = LaunchOptions()
    /// True until the user finishes setup. A plain launch does not raise a window while this is set.
    private var setupRequired = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        options = LaunchOptions(arguments: CommandLine.arguments)
#if DEBUG
        // QA: LSUIElement apps never report as frontmost to System Events. This flag makes the
        // app a regular, activatable app and keys the onboarding window so Return/Space tests work.
        // Release builds ignore the flag (LaunchForegroundPolicy).
        if CommandLine.arguments.contains("--qa-foreground") {
            options.qaForeground = true
        }
#endif
        let launchPresentation = LaunchForegroundPolicy.onLaunch(
            qaForeground: options.qaForeground,
            debugBuild: Self.isDebugBuild,
            explicitUI: options.forceOnboarding || options.onboardingStep != nil || options.backdrop || options.demoWalkthrough
        )
        if launchPresentation == .keyAndActive {
            NSApp.setActivationPolicy(.regular)
            gfLog("Glassforce: --qa-foreground (DEBUG) — regular activation policy for QA key targeting")
        } else if options.qaForeground {
            gfLog("Glassforce: --qa-foreground ignored (release, or not a debug build)")
        }
        switch options.appearance {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case nil: break
        }

        let model = CommandBarModel(store: RecordStore(records: options.fakeData ? FakeData.records : []))
        if options.fakeData {
            // Explicit demo launch only (--fake-data). Never used by a normal install.
            gfLog("Glassforce: DEMO --fake-data: showing fixture records (not a real org)")
            model.orgBadge = OrgBadge(title: "Demo · fixture data", color: Color.orange.opacity(0.75))
        }
        panelController = PanelController(model: model)
        panelController.pinned = options.pin || options.demoWalkthrough
        panelController.openSettings = { [weak self] in self?.openSettings() }
        installMenus()

        // Option-Space. Carbon hot keys need no Accessibility permission.
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.userRequestedInterface()
        }
        if hotKey == nil { gfLog("Glassforce: could not register Option-Space (already taken by another app?)") }

        if !options.fakeData {
            GFLog.installCoreSink()
            let session = makeSession(model: model)
            self.session = session
            model.performWrite = { [weak session] write in
                Task { await session?.applyConfirmed(write) }
            }
            if let host = options.seedSampleDataHost {
                Task {
                    await session.seedSampleData(allowedHost: host)
                    try? await Task.sleep(for: .seconds(1))
                    NSApp.terminate(nil)
                }
                return
            }
            if options.diagnoseSync {
                Task {
                    await session.diagnoseDefaultOrg()
                    try? await Task.sleep(for: .seconds(1)) // let the log file catch up
                    NSApp.terminate(nil)
                }
                return
            }
            model.connectAction = { [weak self, weak session] in
                guard let self, let session else { return }
                self.panelController.hide()
                self.setupRequired = true
                // The click or Return already happened on the panel. Show the wizard inactive
                // so that same key-up cannot land on Install / Connect.
                self.showOnboarding(session, presentation: .visibleInactive)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let needsOnboarding = await session.needsOnboarding()
                let needs = options.forceOnboarding || needsOnboarding
                self.setupRequired = needs
                if needs {
                if options.onboardingStep != nil { session.suppressDevChrome = true }
                switch options.onboardingStep {
                case "welcome": session.onboarding = Onboarding(step: .welcome)
                case "hotkey": session.onboarding = Onboarding(step: .hotkey)
                case "install":
                    session.onboarding = Onboarding(step: .install)
                case "install-opened":
                    session.onboarding = Onboarding(step: .install)
                    session.pickedEnvironment = .production
                    session.installOpened = true
                    session.installFeedback = "Opened the install page in your browser. Finish the install there, then continue."
                case "connect": session.onboarding = Onboarding(step: .connect(.production))
                case "confirm":
                    let pending = PendingOrg(
                        orgKey: "00DDEMO:005USER",
                        orgName: "Demo · Acme Sandbox",
                        username: "user@example.com",
                        kind: .sandbox,
                        instanceHost: "acme--uat.sandbox.my.salesforce.com",
                        expectedLoginHost: "test.salesforce.com",
                        hostMismatch: false
                    )
                    session.onboarding = Onboarding(step: .confirming(.sandbox, pending))
                    gfLog("Glassforce: DEMO --onboarding-step confirm (fixture identity, not live OAuth)")
                case "confirm-mismatch":
                    // Screenshot only. The names are reserved (.example) and are not a Salesforce
                    // login host. The environment stays the public sandbox endpoint, so this flag
                    // does not aim OAuth at a developer org.
                    let pending = PendingOrg(
                        orgKey: "00DWRONG:005USER",
                        orgName: "Fixture mismatch",
                        username: "user@example.com",
                        kind: .developer,
                        instanceHost: "instance.example",
                        expectedLoginHost: "login.example",
                        hostMismatch: true
                    )
                    session.onboarding = Onboarding(step: .confirming(.sandbox, pending))
                    gfLog("Glassforce: DEMO --onboarding-step confirm-mismatch (reserved fixture hosts, not live OAuth)")
                case "done", "panel-badge":
                    // Screenshot-only: seed an in-memory mock org so Done / the panel badge can render.
                    var demo = OrgProfile(
                        id: "00DDEMO:user@example.com",
                        orgName: "Acme Demo",
                        username: "user@example.com",
                        kind: .sandbox,
                        loginURL: URL(string: "https://test.salesforce.com")!,
                        instanceURL: URL(string: "https://acme--uat.sandbox.my.salesforce.com")!
                    )
                    demo.status = .connected
                    demo.isDefault = true
                    session.seedScreenshotOrg(demo)
                    if options.onboardingStep == "panel-badge" {
                        // Skip the wizard; show the command bar with the quiet org chip.
                        break
                    }
                    session.onboarding = Onboarding(step: .done(org: demo.id))
                default: break
                }
                if options.onboardingStep != "panel-badge" {
                    if launchPresentation == .hidden {
                        gfLog("Glassforce: setup waiting — no window, no auth, no browser until you click the menu or press Option-Space")
                    } else {
                        showOnboarding(session, presentation: launchPresentation)
                    }
                }
                // panel-badge: keep the seeded org + badge; do not resumeDefaultOrg (that marks needs-sign-in without tokens).
                } else {
                    session.resumeDefaultOrg()
                    gfLog("Glassforce: signed in to %d org(s); default %@, no prompt", session.directory.orgs.count, session.directory.defaultOrg?.label ?? "-")
                }
                if self.options.openSettings { self.openSettings() }
                if self.options.demoWalkthrough {
                    DemoWalkthrough(session: session, panel: self.panelController, model: model, onboarding: self.onboardingWindow).run()
                }
            }
        }

        if let query = options.query { model.query = query }
        if options.backdrop { panelController.showDemoBackdrop() }
        if options.showPanel { panelController.show() }
        if let kind = options.openFirst {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6)) // let the background sync land
                if let record = model.results.first(where: { $0.kind.rawValue == kind }) { model.open(record) }
                else { gfLog("Glassforce: --open-first: no %@ result for the current query", kind) }
            }
        }
    }

    /// Menu bar and Option-Space. Setup never starts from launch itself.
    private func userRequestedInterface() {
        if setupRequired, let session {
            showOnboarding(session, presentation: .visibleInactive)
            return
        }
        panelController.toggle()
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    // MARK: Menus

    /// A menu bar item (Search, Settings…, Quit) plus a main menu so ⌘, and the standard edit keys work
    /// whenever a Glassforce window is frontmost. It's an accessory app, so the main menu itself stays hidden.
    private func installMenus() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Bolt mark reads as Glassforce; magnifyingglass was indistinguishable from Spotlight.
        let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Glassforce")
        bolt?.isTemplate = true
        item.button?.image = bolt
        let menu = NSMenu()
        let search = NSMenuItem(title: "Search Salesforce", action: #selector(showSearchFromMenu), keyEquivalent: " ")
        search.keyEquivalentModifierMask = [.option]
        menu.addItem(search)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Glassforce", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for entry in menu.items where entry.action != #selector(NSApplication.terminate(_:)) { entry.target = self }
        item.menu = menu
        statusItem = item

        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Glassforce")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(title: "Quit Glassforce", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func showSearchFromMenu() { userRequestedInterface() }
    @objc private func openSettingsFromMenu() { openSettings() }

    func openSettings() {
        guard let session else { gfLog("Glassforce: settings need a session (not available with --fake-data)"); return }
        if settingsWindow == nil { settingsWindow = SettingsWindowController(session: session) }
        settingsWindow?.show()
    }

    private func makeSession(model: CommandBarModel) -> AppSession {
        let buildID = Bundle.main.object(forInfoDictionaryKey: "GlassforceBuildID") as? String ?? "dev"
        if options.mockSalesforce {
            // Mock mode is fully separate from real sign-ins: its own folder and Keychain service,
            // namespaced per build so ad-hoc rebuilds never trigger Keychain access prompts.
            let local = LocalStore.applicationSupport(subfolder: "Glassforce-Mock/\(buildID)")
            let keychain = KeychainSecretStore(service: "dev.glassforce.oauth.mock.\(buildID)")
            let stateFile = local.directory.appendingPathComponent("mock-salesforce-state.json")
            if options.resetState {
                keychain.deleteAll()
                try? FileManager.default.removeItem(at: local.directory)
                gfLog("Glassforce: mock state reset")
            }
            let mock = MockSalesforce(stateFile: stateFile, queryDelay: 0.7)
            mock.requireInstall = !options.mockPreinstalled
            mock.installerIsAdmin = !options.mockNonAdmin
            let host = MockServerHost(mock: mock)
            do {
                let base = try host.start()
                gfLog("Glassforce: mock Salesforce listening on %@", base.absoluteString)
            } catch {
                gfLog("Glassforce: mock server failed to start: %@", "\(error)")
            }
            mockServer = host
            // Proof / --onboarding-step shots: stay off the Keychain so Allow dialogs never cover the UI.
            let store: any SecretStore = (options.onboardingStep != nil) ? InMemorySecretStore() : keychain
            let session = AppSession(mode: .mock, tokens: TokenManager(transport: mock, store: store), local: local, mock: mock, searchModel: model)
            wirePresenter(session)
            return session
        }
        let keychain = KeychainSecretStore(service: "dev.glassforce.oauth")
        let session = AppSession(mode: .live, tokens: TokenManager(transport: URLSessionTransport(), store: keychain),
                                 local: .applicationSupport(), mock: nil, searchModel: model)
        wirePresenter(session)
        return session
    }

    private func wirePresenter(_ session: AppSession) {
        let useWebView = options.authWebView && session.mode == .mock
        let autoApprove: TimeInterval? = options.demoWalkthrough ? 2.2 : nil
        if options.demoWalkthrough {
            session.allowsProgrammaticNetworkActions = true
            // Demo only: in-app mock install sheet (not the real browser). Live installs use
            // NSWorkspace → default browser on click — that page needs the user's normal
            // browser session to complete a package install; ephemeral ASWebAuth would be wrong.
            session.installPresenter = { [weak self] url in
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "return", value: "dev.glassforce.app://install/done")]
                let presenter = WebViewAuthPresenter(anchor: { self?.onboardingWindow?.window }, autoApproveAfter: 2.4, autoClickID: "install")
                // Demo sheet only. Live installs use NSWorkspace (InstallOpen.systemBrowser), never this presenter.
                return (try? await presenter.authenticate(url: components.url!, callbackScheme: OAuthConfig.callbackScheme, ephemeral: true)) != nil
            }
        }
        session.presenterFactory = { [weak self] in
            let anchor = { self?.onboardingWindow?.window }
            return useWebView
                ? WebViewAuthPresenter(anchor: anchor, autoApproveAfter: autoApprove)
                : WebAuthSessionPresenter(anchor: anchor)
        }
    }

    private func showOnboarding(_ session: AppSession, presentation: WindowPresentation) {
        guard presentation != .hidden else { return }
        if let existing = onboardingWindow {
            // Do not skip Welcome or jump to Install. A second show must not move the step.
            existing.show(presentation: presentation)
            return
        }
        let controller = OnboardingWindowController(session: session) { [weak self] in
            session.onboarding.send(.finish)
            self?.setupRequired = false
            self?.onboardingWindow?.close()
            gfLog("Glassforce: onboarding finished; press Option-Space to search")
        }
        onboardingWindow = controller
        if options.backdrop { controller.showProofBackdrop() }
        controller.show(presentation: presentation)
        // Network actions are click-gated (AuthFlow). No arming timer, no auto-retry.
        if options.backdrop {
            let r = controller.captureRect
            gfLog("Glassforce: onboarding capture rect=%d,%d,%d,%d", r.x, r.y, r.w, r.h)
        }
    }
}
