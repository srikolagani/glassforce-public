import AppKit
import SwiftUI
import GlassforceCore

/// First-run window: Setup Assistant restraint, real Liquid Glass, one primary action, compact.
struct OnboardingView: View {
    @Bindable var session: AppSession
    var onFinish: () -> Void

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 0) {
                Group {
                    switch session.onboarding.step {
                    case .welcome: WelcomeBody()
                    case .hotkey: HotkeyBody()
                    case .install: InstallBody(session: session)
                    case .connect(let env): ConnectBody(session: session, environment: env)
                    case .connecting(let env): ConnectingBody(environment: env)
                    case .confirming(_, let pending): ConfirmBody(pending: pending)
                    case .failed(_, let error): FailedBody(error: error)
                    case .syncing(_, let progress): SyncingBody(org: session.lastConnected, progress: progress)
                    case .done: DoneBody(session: session)
                    case .finished: Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
                    .padding(.horizontal, 22)
                    .padding(.top, 6)

                StepDots(current: stepIndex)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
            }
            .padding(.top, 12)
            .frame(width: 480, height: 360)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .frame(width: 560, height: 440)
        .containerBackground(.clear, for: .window)
        .animation(.smooth(duration: 0.28), value: stepID)
    }

    private var stepIndex: Int {
        switch session.onboarding.step {
        case .welcome: 0
        case .hotkey: 1
        case .install: 2
        case .connect, .connecting, .confirming, .failed: 3
        case .syncing, .done, .finished: 4
        }
    }

    private var stepID: String { "\(session.onboarding.step)" }

    // MARK: Shared trailing footer — same chrome on every step

    @ViewBuilder
    private var footer: some View {
        switch session.onboarding.step {
        case .welcome:
            StepFooter(allowsKeyboardDefault: OnboardingChrome.allowsKeyboardDefault(for: .welcomeGetStarted)) {
                Button("Get Started") { session.onboarding.send(.next) }
            }
        case .hotkey:
            StepFooter(secondaryTitle: "Back", secondaryAction: { session.onboarding.send(.back) },
                        allowsKeyboardDefault: OnboardingChrome.allowsKeyboardDefault(for: .hotkeyContinue)) {
                Button("Continue") { session.onboarding.send(.next) }
            }
        case .install:
            installFooter
        case .connect:
            let gate = session.gate
            // Secondary is local (back); primary is click-only network.
            StepFooter(secondaryTitle: "Back to Install", secondaryAction: session.backToInstall) {
                ClickOnlyControl(title: "Connect", enabled: gate.canConnect) { session.connectChosen(via: $0) }
            }
        case .connecting:
            StepFooter(allowsKeyboardDefault: OnboardingChrome.allowsKeyboardDefault(for: .connectingCancel)) {
                Button("Cancel", action: session.cancelSignIn)
            }
        case .confirming:
            StepFooter(
                secondaryTitle: "Sign in to a different org",
                secondaryAction: session.rejectPendingOrg
            ) {
                ClickOnlyControl(title: "Use this org") { session.confirmPendingOrg(via: $0) }
            }
        case .failed(_, let error):
            if error.offersBackToInstall {
                // Both actions are network-ish / navigation — Try Again must be click-only (was a Button).
                HStack(alignment: .center, spacing: 16) {
                    ClickOnlyControl(title: "Try Again", prominent: false) { session.connectChosen(via: $0) }
                    Spacer(minLength: 0)
                    ClickOnlyControl(title: "Back to Install") { _ in session.backToInstall() }
                }
            } else {
                StepFooter(secondaryTitle: "Back", secondaryAction: { session.onboarding.send(.back) }) {
                    ClickOnlyControl(title: "Try Again") { session.connectChosen(via: $0) }
                }
            }
        case .done:
            StepFooter(secondaryTitle: "Add Another Org", secondaryAction: { session.onboarding.send(.addAnotherOrg) },
                        allowsKeyboardDefault: OnboardingChrome.allowsKeyboardDefault(for: .doneStartSearching)) {
                Button("Start Searching", action: onFinish)
            }
        case .syncing, .finished:
            EmptyView()
        }
    }

    @ViewBuilder
    private var installFooter: some View {
        let gate = session.gate
        if session.installOpened || session.installAcknowledged {
            HStack(alignment: .center, spacing: 16) {
                ClickOnlyControl(
                    title: "Having a problem? Try again",
                    prominent: false,
                    enabled: gate.canInstall
                ) { session.openInstallPage(via: $0) }
                Spacer(minLength: 0)
                ClickOnlyControl(
                    title: "Proceed to next step",
                    enabled: session.pickedLoginEnvironment() != nil
                ) { session.proceedToNextStep(via: $0) }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 16) {
                    ClickOnlyControl(title: "Already installed? Skip", prominent: false) { session.skipInstall(via: $0) }
                    Spacer(minLength: 0)
                    ClickOnlyControl(title: "Install Package", enabled: gate.canInstall) { session.openInstallPage(via: $0) }
                }
                // Copy link is local pasteboard only — Button is fine (no browser/network).
                Button("Not an admin? Copy install link", action: session.copyInstallLink)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .disabled(!gate.canInstall)
            }
        }
    }
}

// MARK: - Shared chrome

/// Quiet secondary on the leading edge; one accent-filled primary trailing.
/// `.borderedProminent` / `.glassProminent` + `.tint` stay gray inside a `.glassEffect` host —
/// the glass material swallows the tint. Paint the fill with `Color.accentColor` ourselves.
/// Primary footer.
///
/// Network / browser actions use a **click-only** control (no `Button`, no `.defaultAction`).
/// A focused SwiftUI `Button` still activates on Space even without a keyboard shortcut —
/// that is what auto-opened Install / Connect / Confirm in QA (Return/Space after the
/// window became key). Local-only steps may keep a real `Button` + optional Return shortcut.
private struct StepFooter<Primary: View>: View {
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var secondaryDisabled = false
    var allowsKeyboardDefault = false
    @ViewBuilder var primary: () -> Primary

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .disabled(secondaryDisabled)
            }
            Spacer(minLength: 0)
            if allowsKeyboardDefault {
                primary()
                    .buttonStyle(AccentPrimaryButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                // Caller still passes a Button{...}; we cannot strip that. Network footers
                // below use ClickOnlyControl instead of Button.
                primary()
                    .buttonStyle(AccentPrimaryButtonStyle())
                    .controlSize(.large)
            }
        }
    }
}

/// Capsule filled with the system accent (same blue as the step dots). White label.
private struct AccentPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(fillOpacity(configuration.isPressed)))
            )
            .opacity(isEnabled ? 1 : 0.45)
    }

    private func fillOpacity(_ pressed: Bool) -> Double {
        if !isEnabled { return 0.55 }
        return pressed ? 0.85 : 1
    }
}

/// Mouse / trackpad / VoiceOver only. Not a `Button`, so Space / Return cannot activate it
/// when focused. Passes `NetworkActionTrigger` into the action so AppSession can refuse
/// anything that did not come from a real click (or accessibility activate).
private struct ClickOnlyControl: View {
    let title: String
    var prominent: Bool = true
    var enabled: Bool = true
    let action: (NetworkActionTrigger) -> Void

    var body: some View {
        label
            // Not a Button and not focusable: Space / Return cannot activate it when the
            // window is key. VoiceOver uses accessibilityAction, which is an allowed trigger.
            .focusable(false)
            .onTapGesture {
                guard enabled else { return }
                action(.mouseClick)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard enabled else { return }
                action(.accessibility)
            }
            .allowsHitTesting(enabled)
    }

    @ViewBuilder
    private var label: some View {
        if prominent {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(enabled ? 1 : 0.55))
                )
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Capsule())
        } else {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
    }
}



private struct StepHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
    }
}

private struct StepDots: View {
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.25), value: current)
    }
}

// MARK: - Step bodies (content only; footer lives in OnboardingView)

private struct WelcomeBody: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 88, height: 88)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            StepHeader(
                title: "Welcome to Glassforce",
                subtitle: "Search Salesforce from anywhere on your Mac."
            )
            Label("Your data stays on this Mac. No servers, no telemetry.", systemImage: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HotkeyBody: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            StepHeader(
                title: "One shortcut, everywhere",
                subtitle: "Press ⌥ Space in any app to open Glassforce. Type, use ↑ ↓, press ↩ to open, esc to close."
            )
            HStack(spacing: 12) {
                BigKeycap("⌥", caption: "option")
                Text("+").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                BigKeycap("Space", caption: nil, wide: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BigKeycap: View {
    let label: String
    let caption: String?
    var wide = false
    init(_ label: String, caption: String?, wide: Bool = false) {
        self.label = label; self.caption = caption; self.wide = wide
    }
    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 26, weight: .medium))
            if let caption { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .frame(width: wide ? 180 : 76, height: 72)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct InstallBody: View {
    @Bindable var session: AppSession

    var body: some View {
        let gate = session.gate
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            StepHeader(
                title: "Install Glassforce in your org",
                subtitle: "An admin installs it once per org. Choose where you sign in."
            )

            Picker("Environment", selection: Binding(
                get: { session.pickedEnvironment },
                set: { session.pick($0) }
            )) {
                Text("Production").tag(AppSession.PickedEnvironment.production)
                Text("Sandbox").tag(AppSession.PickedEnvironment.sandbox)
                Text("Custom Domain").tag(AppSession.PickedEnvironment.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: 400)
            .padding(3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            // Native info / field row — system field chrome, secondary glyph.
            environmentField

            if session.pickedEnvironment == .custom {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("acme or acme--uat.sandbox", text: $session.customDomain)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                    if let error = session.customDomainError {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: 400)
            }

            if let note = gate.installNote {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            if let feedback = session.installFeedback {
                Label(feedback, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .labelStyle(.titleAndIcon)
            }

            if session.mode == .mock, !session.suppressDevChrome {
                Label("Mock Salesforce: a local fake org, no real data", systemImage: "hammer")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var environmentField: some View {
        HStack(spacing: 8) {
            Image(systemName: environmentSymbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 16)
            Text(environmentCaption)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 400)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
    }

    private var environmentSymbol: String {
        switch session.pickedEnvironment {
        case .production: "building.2"
        case .sandbox: "testtube.2"
        case .custom: "link"
        }
    }

    private var environmentCaption: String {
        switch session.pickedEnvironment {
        case .production: "login.salesforce.com"
        case .sandbox: "test.salesforce.com"
        case .custom: "Your My Domain host"
        }
    }
}

private struct ConnectBody: View {
    @Bindable var session: AppSession
    let environment: LoginEnvironment

    var body: some View {
        let gate = session.gate
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            StepHeader(
                title: "Connect your org",
                subtitle: "Sign in and click Allow. Glassforce reads records, and updates a field only after you confirm the change. Your sign-in stays in the Keychain."
            )
            Label(environment.loginURL.host ?? "Salesforce", systemImage: "network")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassEffect(.regular, in: Capsule())

            DisclosureGroup("Advanced", isExpanded: $session.showAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Consumer key (optional)", text: $session.consumerKeyOverride)
                        .textFieldStyle(.roundedBorder)
                    Text("Use your own External Client App key if your admin gave you one. Public; no secret.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 400)
            .font(.system(size: 12))

            if let note = gate.connectNote {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 400)
            } else if let feedback = session.connectFeedback {
                Text(feedback).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConfirmBody: View {
    let pending: PendingOrg

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            StepHeader(
                title: "Is this the right org?",
                subtitle: "Nothing is saved until you confirm this org. Glassforce reads records, and updates a field only after you confirm the change. Your sign-in stays in the Keychain."
            )
            VStack(alignment: .leading, spacing: 8) {
                ConfirmRow(label: "Org", value: pending.orgName)
                ConfirmRow(label: "User", value: pending.username)
                ConfirmRow(label: "Host", value: pending.instanceHost)
                QuietOrgChip(title: pending.kind.badgeTitle, tint: pending.kind.badgeColor)
            }
            .padding(14)
            .frame(maxWidth: 400, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if pending.hostMismatch {
                Label(
                    "This org's host is \(pending.instanceHost), but you entered \(pending.expectedLoginHost).",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .symbolRenderingMode(.hierarchical)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConfirmRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

private struct ConnectingBody: View {
    let environment: LoginEnvironment
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ProgressView().controlSize(.large)
            StepHeader(
                title: "Waiting for Salesforce…",
                subtitle: "Sign in and allow access in the window that opened (\(environment.loginURL.host ?? "Salesforce"))."
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailedBody: View {
    let error: AuthError
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
                .symbolRenderingMode(.hierarchical)
            StepHeader(title: error.title, subtitle: error.advice)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SyncingBody: View {
    let org: OrgProfile?
    let progress: SyncProgress
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
            if let org {
                Text("Connected to \(org.orgName)")
                    .font(.system(size: 22, weight: .semibold))
                OrgRow(org: org)
            }
            VStack(spacing: 8) {
                ProgressView(value: max(progress.fraction, 0.04)).frame(width: 320)
                Text(progress.currentObject.isEmpty
                     ? "Starting sync…"
                     : "Indexing \(progress.currentObject)… \(progress.recordsSynced) records")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DoneBody: View {
    @Bindable var session: AppSession
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
            StepHeader(
                title: "You're all set",
                subtitle: "Press ⌥ Space anywhere to search. You won't be asked to sign in again."
            )
            VStack(spacing: 8) {
                ForEach(session.directory.orgs) { OrgRow(org: $0) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One org: quiet badge, name, username, record count, default star.
struct OrgRow: View {
    let org: OrgProfile
    var body: some View {
        HStack(spacing: 10) {
            QuietOrgChip(
                title: org.status == .needsSignIn ? "Needs sign-in" : org.kind.badgeTitle,
                tint: org.status == .needsSignIn ? Color.secondary : org.kind.badgeColor
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(org.label).font(.system(size: 13, weight: .semibold))
                Text(org.username).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if org.recordCount > 0 {
                Text("\(org.recordCount) records")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if org.isDefault {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Default org")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 400)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct QuietOrgChip: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint.opacity(0.85))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: Capsule())
    }
}
