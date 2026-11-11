/// First-run flow: Welcome → ⌥Space hint → Install → Connect → Confirm org → sync → done.
public enum OnboardingStep: Equatable, Sendable {
    case welcome
    case hotkey
    /// Step 1: pick Production / Sandbox / Custom Domain and install the package (or skip if already installed).
    case install
    /// Step 2: sign in on the host chosen in step 1.
    case connect(LoginEnvironment)
    case connecting(LoginEnvironment)
    /// After token exchange: show org name / username / host; nothing saved until confirm.
    case confirming(LoginEnvironment, PendingOrg)
    case failed(LoginEnvironment, AuthError)
    case syncing(org: String, progress: SyncProgress)
    case done(org: String)
    case finished
}

/// Org facts shown on the confirmation step. No tokens.
public struct PendingOrg: Equatable, Sendable {
    public let orgKey: String
    public let orgName: String
    public let username: String
    public let kind: OrgKind
    public let instanceHost: String
    public let expectedLoginHost: String
    /// True when the user picked a Custom Domain and the signed-in instance host does not match it.
    public let hostMismatch: Bool

    public init(orgKey: String, orgName: String, username: String, kind: OrgKind,
                instanceHost: String, expectedLoginHost: String, hostMismatch: Bool) {
        self.orgKey = orgKey
        self.orgName = orgName
        self.username = username
        self.kind = kind
        self.instanceHost = instanceHost
        self.expectedLoginHost = expectedLoginHost
        self.hostMismatch = hostMismatch
    }
}

public enum OnboardingEvent: Equatable, Sendable {
    case next
    case back
    /// "Proceed to next step" on the install step, after the browser install page opens or Skip.
    case installStepDone(LoginEnvironment)
    /// Connect / Try Again.
    case connect
    /// "Back to Install" (from Connect, or from a not-installed / cross-org error).
    case backToInstall
    /// Token exchange succeeded; show the confirmation card (Keychain still empty).
    case orgDiscovered(PendingOrg)
    /// "Use this org" — Keychain write + sync may proceed.
    case confirmOrg
    /// "Sign in to a different org" — discard pending tokens, back to Connect.
    case rejectOrg
    case signInFailed(AuthError)
    case syncFailed(LoginEnvironment, AuthError)
    case syncProgressed(SyncProgress)
    case syncFinished
    case addAnotherOrg
    case finish
}

public struct Onboarding: Equatable, Sendable {
    public private(set) var step: OnboardingStep

    public init(step: OnboardingStep = .welcome) { self.step = step }

    /// Applies an event. Returns false (and changes nothing) when it doesn't apply to the current step.
    @discardableResult
    public mutating func send(_ event: OnboardingEvent) -> Bool {
        guard let next = Self.transition(from: step, on: event) else { return false }
        step = next
        return true
    }

    public static func transition(from step: OnboardingStep, on event: OnboardingEvent) -> OnboardingStep? {
        switch (step, event) {
        case (.welcome, .next): return .hotkey
        case (.hotkey, .next): return .install
        case (.hotkey, .back): return .welcome
        case (.install, .installStepDone(let env)): return .connect(env)
        case (.install, .back): return .hotkey
        case (.connect(let env), .connect): return .connecting(env)
        case (.connect, .back), (.connect, .backToInstall): return .install
        case (.connecting(let env), .orgDiscovered(let pending)): return .confirming(env, pending)
        case (.connecting(let env), .signInFailed(.cancelled)): return .connect(env)
        case (.connecting(let env), .signInFailed(let error)): return .failed(env, error)
        case (.confirming(_, let pending), .confirmOrg): return .syncing(org: pending.orgKey, progress: .starting)
        case (.confirming(let env, _), .rejectOrg): return .connect(env)
        case (.confirming(let env, _), .back): return .connect(env)
        case (.failed(let env, _), .connect): return .connecting(env)
        case (.failed(let env, _), .back): return .connect(env)
        case (.failed, .backToInstall): return .install
        case (.syncing, .syncFailed(let env, let error)): return .failed(env, error)
        case (.syncing(let org, _), .syncProgressed(let progress)): return .syncing(org: org, progress: progress)
        case (.syncing(let org, _), .syncFinished): return .done(org: org)
        case (.done, .addAnotherOrg): return .install
        case (.done, .finish): return .finished
        default: return nil
        }
    }
}

/// Whether the wizard's main buttons can run in this build, and the plain note shown when they can't.
public struct WizardGate: Equatable, Sendable {
    public static let noPackageNote = "No published package in this build yet. Run scripts/package-eca.sh, then rebuild."
    public static let noConsumerKeyNote = "No consumer key in this build yet. Run scripts/package-eca.sh, then rebuild, or paste your own key under Advanced."

    public let canInstall: Bool
    public let canConnect: Bool
    public var installNote: String? { canInstall ? nil : Self.noPackageNote }
    public var connectNote: String? { canConnect ? nil : Self.noConsumerKeyNote }

    public init(canInstall: Bool, canConnect: Bool) { self.canInstall = canInstall; self.canConnect = canConnect }

    /// Real orgs: install needs a 04t; connect needs the packaged key or the user's own key.
    public static func live(packageVersionID: String = PackagedApp.packageVersionID, oauth: OAuthConfig) -> WizardGate {
        WizardGate(canInstall: PackagedApp.isRealVersion(packageVersionID), canConnect: oauth.isConfigured)
    }
}

extension AuthError {
    /// Not installed / cross-org: the fix is the install step, so the error screen offers "Back to Install".
    public var offersBackToInstall: Bool { self == .notInstalled }
}

public struct SyncProgress: Equatable, Sendable {
    public var currentObject: String
    public var recordsSynced: Int
    public var objectsDone: Int
    public var totalObjects: Int

    public static let starting = SyncProgress(currentObject: "", recordsSynced: 0, objectsDone: 0, totalObjects: 1)

    public init(currentObject: String, recordsSynced: Int, objectsDone: Int, totalObjects: Int) {
        self.currentObject = currentObject
        self.recordsSynced = recordsSynced
        self.objectsDone = objectsDone
        self.totalObjects = totalObjects
    }

    public var fraction: Double { totalObjects == 0 ? 0 : Double(objectsDone) / Double(totalObjects) }
}
