import AppKit
import SwiftUI
import GlassforceCore

/// Glue between the UI and the auth/sync core: owns the org directory, drives onboarding,
/// signs orgs in, syncs their index, and keeps the search panel pointed at the default org.
@MainActor
@Observable
final class AppSession {
    enum Mode { case live, mock }

    let mode: Mode
    private(set) var directory: OrgDirectory
    var onboarding = Onboarding()
    /// The card the user has picked on the environment step (also used by the demo to "click").
    var pickedEnvironment: PickedEnvironment = .production
    var customDomain = ""
    var customDomainError: String?
    /// Kept here rather than in `@State`: the Command Line Tools lack the SwiftUIMacros plugin.
    var showAdvanced = false
    /// Advanced: bring-your-own consumer key (public value, kept in UserDefaults).
    var consumerKeyOverride: String {
        didSet {
            let trimmed = consumerKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != consumerKeyOverride { consumerKeyOverride = trimmed; return }
            UserDefaults.standard.set(consumerKeyOverride, forKey: "consumerKeyOverride")
        }
    }
    private(set) var lastConnected: OrgProfile?

    enum PickedEnvironment: Hashable { case production, sandbox, custom }

    let tokens: TokenManager
    let client: SalesforceClient
    let local: LocalStore
    /// Which objects each org syncs (Settings › Search objects), per org id.
    let selections: ObjectSelectionStore
    /// The last sync of each org (counts and failures only), for Settings to show per object.
    private(set) var lastReports: [String: SyncReport] = [:]
    /// Orgs with a sync running now, and ones that asked for another sync while it ran.
    private(set) var syncingOrgs: Set<String> = []
    private var resyncQueued: Set<String> = []
    let mock: MockSalesforce?
    let searchModel: CommandBarModel
    var presenterFactory: (() -> AuthSessionPresenting)?
    private var signInTask: Task<Void, Never>?

    init(mode: Mode, tokens: TokenManager, local: LocalStore, mock: MockSalesforce?, searchModel: CommandBarModel) {
        self.mode = mode
        self.tokens = tokens
        self.client = SalesforceClient(tokens: tokens)
        self.local = local
        self.selections = ObjectSelectionStore(local: local)
        self.mock = mock
        self.searchModel = searchModel
        self.directory = local.loadDirectory()
        self.consumerKeyOverride = UserDefaults.standard.string(forKey: "consumerKeyOverride") ?? ""
        // Credential check happens in resumeDefaultOrg / needsOnboarding — never assume ready from orgs.json alone.
        searchModel.status = .noOrg
    }

    /// True when there is no Keychain-backed default org. Leftover orgs.json alone is not enough.
    func needsOnboarding() async -> Bool {
        var creds: [String: Bool] = [:]
        for org in directory.orgs {
            creds[org.id] = await tokens.hasCredentials(for: org.id)
        }
        return SessionAuthPolicy.needsOnboarding(directory: directory, hasCredentials: { creds[$0] ?? false })
    }

    // MARK: Launch

    /// Loads the default org's cached index only when Keychain credentials exist for that org id.
    /// Without credentials: honest empty "Connect a Salesforce org" — never show another org's cache.
    func resumeDefaultOrg() {
        Task { await resumeDefaultOrgAuthenticated() }
    }

    private func resumeDefaultOrgAuthenticated() async {
        guard let org = directory.defaultOrg else {
            searchModel.writeOrgID = ""
            searchModel.load(records: [])
            searchModel.status = .noOrg
            searchModel.orgBadge = nil
            return
        }
        let authenticated = await tokens.hasCredentials(for: org.id)
        guard SessionAuthPolicy.mayLoadCache(for: org.id, authenticatedOrgID: authenticated ? org.id : nil) else {
            gfLog("Glassforce: default org %@ has no Keychain credentials; showing Connect state", org.label)
            searchModel.writeOrgID = ""
            searchModel.load(records: [])
            searchModel.status = .noOrg
            searchModel.orgBadge = nil
            return
        }
        searchModel.writeOrgID = org.id
        searchModel.status = org.recordCount > 0 ? .ready : .syncing(org.label)
        let cached = loadCachedRecords(orgID: org.id)
        if !cached.isEmpty { searchModel.load(records: cached) }
        updateBadge()
        await syncSilently(org.id)
    }

    /// `--diagnose-sync`: read-only checks against the default org, logged as counts and flags only.
    func diagnoseDefaultOrg() async {
        guard let org = directory.defaultOrg else { gfLog("Glassforce: diagnose: no org connected"); return }
        gfLog("Glassforce: diagnose %@ (read-only)", org.label)
        let report = await SyncDiagnostics(client: client).run(org: org.id, instanceURL: org.instanceURL)
        for line in report.lines { gfLog("Glassforce: diagnose · %@", line) }
        gfLog("Glassforce: diagnose done")
    }

    /// DEV ONLY `--seed-sample-data <host>`: create-only, refuses unless the saved instance host matches.
    func seedSampleData(allowedHost: String) async {
        guard let org = directory.defaultOrg else { gfLog("Glassforce: seed: no org connected"); return }
        guard org.instanceURL.host?.lowercased() == allowedHost.lowercased() else {
            gfLog("Glassforce: seed: refusing, org directory host %@ is not %@", org.instanceURL.host ?? "?", allowedHost); return
        }
        do {
            if let totals = try await SampleDataSeeder(client: client).run(org: org.id, allowedHost: allowedHost) {
                for key in ["Account", "Contact", "Opportunity", "Case"] { gfLog("Glassforce: seed · created %d %@", totals[key] ?? 0, key) }
            } else { gfLog("Glassforce: seed: sample data already present, skipped") }
        } catch { gfLog("Glassforce: seed failed: %@", error.localizedDescription) }
    }

    /// Per-object row cap (default 50,000). Override: `defaults write com.srikolagani.glassforce syncObjectCap -int N`.
    var syncCap: Int {
        let value = UserDefaults.standard.integer(forKey: "syncObjectCap")
        return value > 0 ? value : SyncPlan.defaultCap
    }

    /// One sync of one org: plan from the saved object selection (describe for non-built-in objects), then page
    /// every object, incrementally where the last sync allows. Saves the index and the per-object watermarks.
    private func runSync(_ id: String, progress: @Sendable (SyncProgress) async -> Void = { _ in }) async throws -> SyncReport {
        guard let org = directory.org(id) else { throw AuthError.needsSignIn }
        let selection = selections.load(orgID: ObjectSelectionStore.orgID(fromKey: id))
        let plan = try await client.plan(org: id, instanceURL: org.instanceURL, selection: selection, cap: syncCap)
        gfLog("Glassforce: sync plan for %@: %@%@, cap %d per object", org.label,
              plan.objects.map(\.name).joined(separator: ", "), plan.includeSetup ? ", Setup" : "", plan.cap)
        let previous = loadCachedRecords(orgID: id)
        let state = local.load(SyncState.self, from: SyncState.fileName(for: id)) ?? SyncState()
        let started = Date()
        let report = try await client.syncIndex(org: id, instanceURL: org.instanceURL, plan: plan, previous: previous, state: state, progress: progress)
        storeCachedRecords(report.records, orgID: id)
        try? local.save(report.state, to: SyncState.fileName(for: id))
        lastReports[id] = report
        gfLog("Glassforce: sync of %@ took %.1fs", org.label, Date().timeIntervalSince(started))
        return report
    }

    /// Settings changed the object selection: sync again now (or right after the sync that's running).
    func resync(_ id: String) {
        guard !syncingOrgs.contains(id) else { resyncQueued.insert(id); return }
        Task { await syncSilently(id) }
    }

    private func syncSilently(_ id: String) async {
        guard let org = directory.org(id) else { return }
        guard !syncingOrgs.contains(id) else { resyncQueued.insert(id); return }
        syncingOrgs.insert(id)
        defer {
            syncingOrgs.remove(id)
            if resyncQueued.remove(id) != nil { Task { await syncSilently(id) } }
        }
        do {
            let report = try await runSync(id)
            let records = report.records
            logSync(report, org: org.label)
            directory.recordSync(id, count: records.count, at: Date())
            persist()
            if directory.defaultOrg?.id == id { searchModel.load(records: records); searchModel.status = .ready; searchModel.notice = report.notice(org: org.label) }
            gfLog("Glassforce: background sync OK for %@ (%d records), no sign-in needed", org.label, records.count)
        } catch AuthError.needsSignIn {
            directory.setStatus(.needsSignIn, for: id)
            persist()
            gfLog("Glassforce: %@ needs sign-in", org.label)
            searchModel.status = .failed("\(org.label) needs sign-in. Press Return to reconnect.")
        } catch {
            gfLog("Glassforce: background sync failed (%@); keeping cached results", "\(error)")
            searchModel.status = .failed("Couldn't sync \(org.label): \(Self.plainWords(error))")
            // With cached results on screen the status row is hidden, so say it under the results too.
            searchModel.notice = "Couldn't sync \(org.label) (\(Self.plainWords(error))). Showing results from the last sync."
        }
        updateBadge()
    }

    // MARK: Step 1: Install Glassforce in your org

    /// Clicked "Install Package" (the browser opened); primary becomes "Proceed to next step".
    var installOpened = false
    /// Acknowledged install (Proceed, Skip, or markInstalled); ready to advance to Connect.
    var installAcknowledged = false
    /// One-line feedback under the install actions, so every click visibly does something.
    var installFeedback: String?
    /// Hide mock/dev chrome in proof screenshots.
    var suppressDevChrome = false
    /// Demo walkthrough only: allows `NetworkActionTrigger.demoProgrammatic`.
    /// Normal / QA launches leave this false — network actions need a real click.
    var allowsProgrammaticNetworkActions = false
    /// Owns attempt ids. Cancel ends the attempt; a timer never starts another one.
    private var authFlow = AuthFlow()
    private var activeAuthPresenter: (any AuthSessionPresenting)?

    var gate: WizardGate {
        if mock != nil { return WizardGate(canInstall: true, canConnect: true) }
        return .live(oauth: OAuthConfig.resolve(userOverride: consumerKeyOverride, environment: ProcessInfo.processInfo.environment))
    }

    /// The picked card as a login environment; sets `customDomainError` (and returns nil) for a bad domain.
    func pickedLoginEnvironment() -> LoginEnvironment? {
        switch pickedEnvironment {
        case .production: customDomainError = nil; return .production
        case .sandbox: customDomainError = nil; return .sandbox
        case .custom:
            switch LoginHost.normalize(customDomain) {
            case .success(let url):
                customDomainError = nil
                return .custom(url)
            case .failure(let error):
                customDomainError = switch error {
                case .empty: "Enter your My Domain, like acme or acme--uat.sandbox."
                case .invalid: "That doesn't look like a domain."
                case .notSalesforce: "Use your Salesforce My Domain (….my.salesforce.com)."
                }
                return nil
            }
        }
    }

    func pick(_ environment: PickedEnvironment) {
        pickedEnvironment = environment
        customDomainError = nil
        installOpened = false
        installAcknowledged = false
        installFeedback = nil
    }

    /// Install page for this exact login host (login / test / My Domain).
    func installURL(for environment: LoginEnvironment) -> URL {
        if let mock { return PackagedApp.installURL(loginURL: mock.loginURL(for: environment), packageVersionID: "04tMOCKPACKAGE0001") }
        return PackagedApp.installURL(loginURL: environment.loginURL)
    }

    /// Demo only: shows the (mock) install page in a sheet and clicks Install. Real builds use the default browser.
    var installPresenter: ((URL) async -> Bool)?

    private func requireUserGesture(_ trigger: NetworkActionTrigger, action: String) -> Bool {
        guard authFlow.authorize(trigger, demoMode: allowsProgrammaticNetworkActions) else {
            gfLog("Glassforce: ignored %@ — need an explicit click (trigger=%@)", action, trigger.rawValue)
            return false
        }
        return true
    }

    /// Opens the packaged-app install page in the user's **default browser** (NSWorkspace).
    /// That page needs the normal browser session (cookies / SSO) so an admin can install the
    /// package — it is intentionally not an ephemeral ASWebAuth sheet. Still click-gated.
    func openInstallPage(via trigger: NetworkActionTrigger) {
        guard requireUserGesture(trigger, action: "openInstallPage") else { return }
        guard gate.canInstall else { installFeedback = WizardGate.noPackageNote; return }
        guard let env = pickedLoginEnvironment() else { return }
        let url = installURL(for: env)
        gfLog("Glassforce: opening install page %@", url.absoluteString)
        installOpened = true
        switch InstallOpen.choose(demoMode: allowsProgrammaticNetworkActions) {
        case .demoSheet:
            guard let installPresenter else {
                installFeedback = "Demo install sheet is not available."
                return
            }
            installFeedback = "Opening the install page…"
            Task {
                if await installPresenter(url) { proceedToNextStep(via: trigger) } else { installFeedback = "Install page closed. Continue when you're done, or try again." }
            }
        case .systemBrowser:
            // Live installs never go through ASWebAuthenticationSession (ephemeral or not).
            if NSWorkspace.shared.open(url) {
                installFeedback = "Opened the install page for \(url.host ?? "Salesforce") in your browser. Finish Install there, then continue."
            } else {
                installFeedback = "Couldn't open your browser. Copy the install link instead."
            }
        }
    }

    func markInstalled() {
        installAcknowledged = true
        installFeedback = "Ready to connect your org."
    }

    /// After the browser install page is open: acknowledge and advance to Connect.
    func proceedToNextStep(via trigger: NetworkActionTrigger) {
        guard requireUserGesture(trigger, action: "proceedToNextStep") else { return }
        installAcknowledged = true
        goToConnect()
    }

    func skipInstall(via trigger: NetworkActionTrigger) {
        guard requireUserGesture(trigger, action: "skipInstall") else { return }
        installAcknowledged = true
        installFeedback = nil
        goToConnect()
    }

    func copyInstallLink() {
        guard gate.canInstall else { installFeedback = WizardGate.noPackageNote; return }
        guard let env = pickedLoginEnvironment() else { return }
        let url = installURL(for: env)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        installFeedback = "Copied the install link for \(url.host ?? "your org"). Send it to your Salesforce admin."
    }

    func goToConnect() {
        guard installAcknowledged || installOpened else { installFeedback = "Install the package first, or skip if it's already there."; return }
        installAcknowledged = true
        guard let env = pickedLoginEnvironment() else { return }
        connectFeedback = nil
        onboarding.send(.installStepDone(env))
    }

    // MARK: Step 2: Connect your org

    var connectFeedback: String?
    /// Unconfirmed sign-in: tokens are in memory only until the user taps "Use this org".
    private(set) var pendingSignIn: TokenManager.SignIn?
    private(set) var pendingProfile: OrgProfile?

    func connectChosen(via trigger: NetworkActionTrigger) {
        guard let attempt = authFlow.beginConnect(trigger, demoMode: allowsProgrammaticNetworkActions) else {
            gfLog("Glassforce: ignored connectChosen — need an explicit click (trigger=%@)", trigger.rawValue)
            return
        }
        guard gate.canConnect else {
            authFlow.cancel()
            connectFeedback = WizardGate.noConsumerKeyNote
            return
        }
        let env: LoginEnvironment
        switch onboarding.step {
        case .connect(let e), .failed(let e, _): env = e
        default:
            authFlow.cancel()
            return
        }
        // Close a previous sheet without treating this click as a cancel of the new attempt.
        stopPresenter()
        guard onboarding.send(.connect) else {
            authFlow.cancel()
            return
        }
        gfLog("Glassforce: connectChosen via %@", trigger.rawValue)
        signInTask = Task { await signIn(env, attempt: attempt) }
    }

    func backToInstall() {
        onboarding.send(.backToInstall)
        installAcknowledged = false
        installOpened = false
        installFeedback = nil
    }

    static func plainWords(_ error: Error) -> String {
        if let auth = error as? AuthError { return "\(auth.title). \(auth.advice)" }
        return error.localizedDescription
    }

    private func handleFailure(_ error: AuthError) {
        gfLog("Glassforce: sign-in failed: %@", error.title)
        // End the attempt. Do not begin another one — Try Again is a separate click.
        authFlow.cancel()
        stopPresenter()
        let shown: AuthError = (error == .cancelled) ? .cancelled : error
        onboarding.send(.signInFailed(shown))
    }

    func cancelSignIn() {
        gfLog("Glassforce: cancelSignIn — ending auth; no automatic restart")
        authFlow.cancel()
        stopPresenter()
        if let pending = pendingSignIn {
            Task { await tokens.discard(pending) }
        }
        pendingSignIn = nil
        pendingProfile = nil
        onboarding.send(.signInFailed(.cancelled))
    }

    /// Cancels the sheet and the Task. Does not change `authFlow` — callers decide
    /// whether this is a user cancel (ended, no restart) or a replacement click.
    private func stopPresenter() {
        activeAuthPresenter?.cancel()
        activeAuthPresenter = nil
        signInTask?.cancel()
        signInTask = nil
    }

    private func signIn(_ environment: LoginEnvironment, attempt: UUID) async {
        do {
            let config: OAuthConfig
            let loginURL: URL
            if let mock {
                config = OAuthConfig(consumerKey: consumerKeyOverride.isEmpty ? MockSalesforce.consumerKey : consumerKeyOverride)
                loginURL = mock.loginURL(for: environment)
            } else {
                config = OAuthConfig.resolve(userOverride: consumerKeyOverride, environment: ProcessInfo.processInfo.environment)
                guard config.isConfigured else { throw AuthError.notConfigured }
                loginURL = environment.loginURL
            }

            // Always ephemeral + prompt=login so a stale browser SSO session cannot silently
            // attach a different org than the login host the user picked.
            let request = AuthorizationRequest(loginURL: loginURL, config: config, forceLogin: true)
            guard let presenter = presenterFactory?() else { throw AuthError.interrupted }
            activeAuthPresenter = presenter
            let callback: URL
            do {
                callback = try await presenter.authenticate(
                    url: request.url,
                    callbackScheme: OAuthConfig.callbackScheme,
                    ephemeral: true
                )
            } catch {
                if !authFlow.acceptsCallback(attempt) || Task.isCancelled {
                    gfLog("Glassforce: dropping auth error — attempt ended")
                    return
                }
                throw error
            }
            guard authFlow.acceptsCallback(attempt), !Task.isCancelled else {
                gfLog("Glassforce: dropping auth callback — attempt invalidated after cancel")
                return
            }
            let code = try request.parseCallback(callback).get()

            // Exchange only — Keychain write waits for "Use this org".
            let signIn = try await tokens.exchangeSignIn(request, code: code)
            guard authFlow.acceptsCallback(attempt), !Task.isCancelled else {
                await tokens.discard(signIn)
                gfLog("Glassforce: discarding exchange — attempt invalidated after cancel")
                return
            }
            let key = signIn.identity.key
            let identity = try await client.identity(org: key, idURL: signIn.credentials.idURL)
            guard SessionAuthPolicy.identityMatches(identity, org: signIn.identity) else {
                gfLog("Glassforce: identity mismatch (userinfo org/user != token id URL); rejecting")
                await tokens.discard(signIn)
                throw AuthError.server("Salesforce returned an identity that doesn't match this sign-in. Nothing was saved.")
            }
            let facts = try await client.organization(org: key, instanceURL: signIn.credentials.instanceURL)
            let profile = OrgProfile(id: key, orgName: facts.name, username: identity.username, kind: facts.kind,
                                     loginURL: signIn.credentials.loginURL, instanceURL: signIn.credentials.instanceURL,
                                     isDefault: directory.isEmpty)
            let expectedHost = environment.loginURL.host ?? ""
            let instanceHost = signIn.credentials.instanceURL.host ?? ""
            let mismatch: Bool = {
                if case .custom = environment {
                    return !LoginHost.instanceMatchesCustomLogin(instanceHost: instanceHost, loginHost: expectedHost)
                }
                return false
            }()
            let pending = PendingOrg(
                orgKey: key, orgName: facts.name, username: identity.username, kind: facts.kind,
                instanceHost: instanceHost, expectedLoginHost: expectedHost, hostMismatch: mismatch
            )
            guard authFlow.acceptsCallback(attempt), !Task.isCancelled else {
                await tokens.discard(signIn)
                gfLog("Glassforce: dropping pending org — attempt invalidated after cancel")
                return
            }
            pendingSignIn = signIn
            pendingProfile = profile
            lastConnected = profile
            guard onboarding.send(.orgDiscovered(pending)) else {
                await tokens.discard(signIn)
                pendingSignIn = nil
                pendingProfile = nil
                throw AuthError.interrupted
            }
            gfLog("Glassforce: awaiting confirm for %@ (%@) on %@", profile.orgName, profile.kind.badgeTitle, instanceHost)
        } catch let error as AuthError {
            guard authFlow.acceptsCallback(attempt) else { return }
            markSyncFailed(error)
            handleFailure(error)
        } catch is CancellationError {
            // Cancel already moved the wizard back to Connect. A stale task must not
            // send another failure — that was restarting the sheet.
            guard authFlow.acceptsCallback(attempt) else { return }
            onboarding.send(.signInFailed(.cancelled))
        } catch {
            guard authFlow.acceptsCallback(attempt) else { return }
            markSyncFailed(error)
            gfLog("Glassforce: sign-in failed: %@", error.localizedDescription)
            onboarding.send(.signInFailed(.server(error.localizedDescription)))
        }
    }

    /// "Use this org": write Keychain, upsert directory, sync.
    /// Requires the pending card's org key to match the in-memory sign-in; otherwise discard and write nothing.
    func confirmPendingOrg(via trigger: NetworkActionTrigger) {
        guard requireUserGesture(trigger, action: "confirmPendingOrg") else { return }
        guard let signIn = pendingSignIn, let profile = pendingProfile else { return }
        guard SessionAuthPolicy.pendingMatchesSignIn(pendingOrgKey: profile.id, signInKey: signIn.identity.key) else {
            gfLog("Glassforce: confirm rejected — pending org key does not match sign-in")
            Task { await tokens.discard(signIn) }
            pendingSignIn = nil
            pendingProfile = nil
            onboarding.send(.rejectOrg)
            connectFeedback = "That org confirmation didn't match. Sign in again."
            return
        }
        guard onboarding.send(.confirmOrg) else { return }
        signInTask = Task { await finishConfirmedSignIn(signIn, profile: profile) }
    }

    /// "Sign in to a different org": drop memory tokens, back to Connect.
    func rejectPendingOrg() {
        if let signIn = pendingSignIn {
            Task { await tokens.discard(signIn) }
        }
        pendingSignIn = nil
        pendingProfile = nil
        lastConnected = directory.defaultOrg
        onboarding.send(.rejectOrg)
        connectFeedback = "Sign in again, and pick the org you meant."
    }

    private func finishConfirmedSignIn(_ signIn: TokenManager.SignIn, profile: OrgProfile) async {
        let key = signIn.identity.key
        do {
            try await tokens.commit(signIn)
            directory.upsert(profile)
            persist()
            lastConnected = directory.org(key)
            pendingSignIn = nil
            pendingProfile = nil
            gfLog("Glassforce: confirmed %@ (%@); starting sync", profile.orgName, profile.kind.badgeTitle)
            if directory.defaultOrg?.id == key { searchModel.status = .syncing(profile.orgName) }

            syncingOrgs.insert(key)
            defer { syncingOrgs.remove(key) }
            let report = try await runSync(key) { progress in
                await MainActor.run { _ = self.onboarding.send(.syncProgressed(progress)) }
            }
            let records = report.records
            logSync(report, org: profile.orgName)
            directory.recordSync(key, count: records.count, at: Date())
            persist()
            lastConnected = directory.org(key)
            if directory.defaultOrg?.id == key,
               SessionAuthPolicy.mayLoadCache(for: key, authenticatedOrgID: key) {
                searchModel.load(records: records)
                searchModel.status = .ready
                searchModel.notice = report.notice(org: profile.orgName)
            }
            updateBadge()
            gfLog("Glassforce: sync finished: %d records", records.count)
            onboarding.send(.syncFinished)
        } catch let error as AuthError {
            markSyncFailed(error)
            handleFailure(error)
        } catch is CancellationError {
            onboarding.send(.signInFailed(.cancelled))
        } catch {
            markSyncFailed(error)
            gfLog("Glassforce: confirm/sync failed: %@", error.localizedDescription)
            onboarding.send(.signInFailed(.server(error.localizedDescription)))
        }
    }

    private func markSyncFailed(_ error: Error) {
        if case .syncing(let org) = searchModel.status {
            searchModel.status = .failed("Couldn't sync \(org): \(Self.plainWords(error))")
        } else if directory.isEmpty {
            searchModel.status = .noOrg
        }
    }

    /// Sends one confirmed field update. Refuses anything that did not come through `ConfirmedWrite`.
    func applyConfirmed(_ write: ConfirmedWrite) async {
        guard let org = directory.defaultOrg else { return }
        guard WriteGuard.allowsSend(write, orgID: org.id, record: searchModel.record(id: write.recordID)) else {
            searchModel.pendingWrite.cancel()
            searchModel.notice = "That change is no longer the record you confirmed. Nothing was saved."
            return
        }
        guard await tokens.hasCredentials(for: org.id) else {
            searchModel.notice = "Connect \(org.label) before changing a record."
            return
        }
        let diff = write.diff
        do {
            try await client.updateField(
                org: org.id, instanceURL: org.instanceURL,
                object: diff.object, id: diff.recordID, field: diff.field, value: diff.after
            )
            gfLog("Glassforce: updated %@ %@ on %@", diff.field, diff.recordID, org.label)
            searchModel.notice = "Updated \(diff.recordTitle): \(diff.fieldLabel) is now \(diff.after)."
        } catch {
            gfLog("Glassforce: write failed: %@", Self.plainWords(error))
            searchModel.notice = "Couldn't update \(diff.recordTitle): \(Self.plainWords(error))"
        }
    }

    func setDefault(_ id: String) {
        directory.setDefault(id)
        persist()
        resumeDefaultOrg()
    }

    func remove(_ id: String) async {
        await tokens.signOut(id)
        local.remove(LocalStore.cacheName(for: id))
        FTSRecordCache.removeFile(directory: local.directory, orgID: id)
        local.remove(SyncState.fileName(for: id))
        directory.remove(id)
        persist()
        resumeDefaultOrg()
    }

    // MARK: Helpers

    /// Per-object counts (never record contents), plus any object that failed in plain words.
    private func logSync(_ report: SyncReport, org: String) {
        for line in report.logLines { gfLog("Glassforce: sync %@ · %@", org, line) }
        if let notice = report.notice(org: org) { gfLog("Glassforce: sync notice: %@", notice) }
    }

    /// Screenshot / demo helper: put one fake org in the in-memory directory and refresh the badge.
    func seedScreenshotOrg(_ profile: OrgProfile) {
        directory.upsert(profile)
        searchModel.status = .ready
        updateBadge()
    }

    func updateBadge() {
        guard let org = directory.defaultOrg else {
            searchModel.writeOrgID = ""
            searchModel.orgBadge = nil
            return
        }
        searchModel.writeOrgID = org.id
        let needsSignIn = org.status == .needsSignIn
        searchModel.orgBadge = OrgBadge(
            title: needsSignIn ? "Needs sign-in · \(org.label)" : "\(org.kind.badgeTitle) · \(org.label)",
            color: needsSignIn ? .gray : org.kind.badgeColor
        )
    }

    /// SQLite FTS5 is the search cache. A leftover JSON cache is imported once, then kept as a fallback copy.
    private func loadCachedRecords(orgID: String) -> [Record] {
        let legacy = LightningHost.migrate(local.load([Record].self, from: LocalStore.cacheName(for: orgID)) ?? [])
        guard let cache = try? FTSRecordCache(directory: local.directory, orgID: orgID) else { return legacy }
        if let rows = try? cache.records(), !rows.isEmpty { return LightningHost.migrate(rows) }
        if !legacy.isEmpty { try? cache.replace(legacy) }
        return legacy
    }

    private func storeCachedRecords(_ records: [Record], orgID: String) {
        if let cache = try? FTSRecordCache(directory: local.directory, orgID: orgID) {
            try? cache.replace(records)
        }
        try? local.save(records, to: LocalStore.cacheName(for: orgID))
    }

    private func persist() {
        do { try local.saveDirectory(directory) } catch { gfLog("Glassforce: couldn't save orgs.json: %@", "\(error)") }
    }
}

extension OrgKind {
    /// Quiet tints for the secondary org badge (low-opacity capsule fill / tiny dot). Not shouty pills.
    var badgeColor: Color {
        switch self {
        case .production: Color.primary.opacity(0.55)
        case .sandbox: Color.orange.opacity(0.75)
        case .developer: Color.accentColor.opacity(0.85)
        }
    }
}
