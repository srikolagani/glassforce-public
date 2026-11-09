import AppKit
import SwiftUI
import GlassforceCore

/// Real panel for isolated QA. Same `AppSession`, `CommandBarModel`, and `CommandBarView`
/// as the shipping app. No Option-Space registration, no login Keychain, no `URLSession`,
/// no production defaults. `--qa-root` is required; a bad root exits before `NSApp.run`.
public enum PanelQAMain {
    @MainActor
    public static func run(arguments: [String]) -> Never {
        let requirements = PanelQARequirements.current
        guard requirements.registersHotKey == false,
              requirements.presentsPanelOnLaunch,
              requirements.usesLoginKeychain == false,
              requirements.usesURLSession == false,
              requirements.egress == .loopbackOnly,
              requirements.bundleDomain == ProcessIdentity.qaDomain,
              requirements.preferenceDomain == ProcessIdentity.qaDomain
        else {
            FileHandle.standardError.write(Data("GlassforcePanelQA: panel requirements are not isolated\n".utf8))
            exit(2)
        }
        guard let rootArg = argument("--qa-root", in: arguments) else {
            FileHandle.standardError.write(Data("GlassforcePanelQA: --qa-root is required\n".utf8))
            exit(2)
        }
        let root = URL(fileURLWithPath: rootArg, isDirectory: true)
        let preferences = MemoryPreferenceStore(domain: requirements.preferenceDomain)
        let secrets: any SecretStore = requirements.usesLoginKeychain
            ? KeychainSecretStore(service: ProcessIdentity.productionKeychainService)
            : InMemorySecretStore()
        let inner: any HTTPTransport = requirements.usesURLSession
            ? URLSessionTransport()
            : RefusalTransport()
        switch QAIsolation.make(
            fileRoot: root,
            productionRoot: LocalStore.applicationSupport().directory,
            preferences: preferences,
            secrets: secrets,
            innerTransport: inner
        ) {
        case .failure(let error):
            FileHandle.standardError.write(Data("GlassforcePanelQA: \(error)\n".utf8))
            exit(2)
        case .success(let isolation):
            GFLog.useDirectory(isolation.fileRoot.appendingPathComponent("Logs", isDirectory: true))
            let model = CommandBarModel(
                store: RecordStore(records: LocalhostFixtures.records()),
                preferences: isolation.preferences,
                egress: requirements.egress
            )
            model.orgBadge = OrgBadge(title: LocalhostFixtures.badge, color: Color.orange.opacity(0.75))
            let session = AppSession(
                mode: .live,
                tokens: TokenManager(transport: isolation.transport, store: isolation.secrets),
                local: LocalStore(directory: isolation.fileRoot),
                mock: nil,
                searchModel: model,
                preferences: isolation.preferences,
                egress: requirements.egress
            )
            model.performWrite = { write in
                Task { await session.applyConfirmed(write) }
            }
            let panel = PanelController(model: model)
            let app = NSApplication.shared
            app.delegate = PanelQADelegate(session: session, panel: panel, presentOnLaunch: requirements.presentsPanelOnLaunch)
            app.setActivationPolicy(.regular)
            app.run()
            exit(0)
        }
    }

    private static func argument(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }
}

private final class PanelQADelegate: NSObject, NSApplicationDelegate {
    let session: AppSession
    let panel: PanelController
    let presentOnLaunch: Bool

    init(session: AppSession, panel: PanelController, presentOnLaunch: Bool) {
        self.session = session
        self.panel = panel
        self.presentOnLaunch = presentOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if presentOnLaunch {
            panel.show()
        }
    }
}
