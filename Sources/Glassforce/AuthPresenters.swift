import AppKit
import AuthenticationServices
import WebKit
import GlassforceCore

/// Opens the Salesforce authorize URL and returns the dev.glassforce.app:// callback URL.
@MainActor
protocol AuthSessionPresenting: AnyObject {
    func authenticate(url: URL, callbackScheme: String, ephemeral: Bool) async throws -> URL
    /// Tear down any in-flight browser session. A cancel must end the flow — no later
    /// completion may resume into confirm (QA round 4 L1: cancel then "awaiting confirm").
    func cancel()
}

/// ASWebAuthenticationSession. We set `prefersEphemeralWebBrowserSession` when asked, but a
/// third-party default browser (e.g. Comet) may still host the session and reuse its own SSO
/// cookies — ephemeral is not a hard guarantee outside Safari. Confirm-before-Keychain is the
/// real wrong-org guard. Call `cancel()` from Cancel so the session cannot complete later.
@MainActor
final class WebAuthSessionPresenter: NSObject, AuthSessionPresenting, ASWebAuthenticationPresentationContextProviding {
    private let anchor: () -> NSWindow?
    private var session: ASWebAuthenticationSession?

    init(anchor: @escaping () -> NSWindow?) { self.anchor = anchor }

    func authenticate(url: URL, callbackScheme: String, ephemeral: Bool) async throws -> URL {
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { [weak self] callback, error in
                self?.session = nil
                let result: Result<URL, Error>
                if let callback {
                    result = .success(callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    result = .failure(AuthError.cancelled)
                } else {
                    result = .failure(AuthError.interrupted)
                }
                once.resume(continuation, with: result)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = ephemeral
            self.session = session
            if !session.start() {
                once.resume(continuation, with: .failure(AuthError.interrupted))
            }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor() ?? NSApp.windows.first ?? NSWindow() }
    }
}

/// ASWebAuthenticationSession can invoke its callback and fail `start()` for the same attempt.
/// Resuming a continuation twice traps. Cancel must still resume exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<URL, Error>, with result: Result<URL, Error>) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        switch result {
        case .success(let url): continuation.resume(returning: url)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

/// Mock/demo only: shows the (local, fake) consent page in a sheet with a WKWebView and catches
/// the custom-scheme redirect. Lets the walkthrough run without a browser taking focus.
@MainActor
final class WebViewAuthPresenter: NSObject, AuthSessionPresenting, WKNavigationDelegate {
    private let anchor: () -> NSWindow?
    private let autoApproveAfter: TimeInterval?
    private let autoClickID: String
    private var continuation: CheckedContinuation<URL, Error>?
    private var resumed = false
    private var callbackScheme = ""
    private var sheet: NSWindow?

    init(anchor: @escaping () -> NSWindow?, autoApproveAfter: TimeInterval? = nil, autoClickID: String = "allow") {
        self.anchor = anchor
        self.autoApproveAfter = autoApproveAfter
        self.autoClickID = autoClickID
    }

    func authenticate(url: URL, callbackScheme: String, ephemeral: Bool) async throws -> URL {
        self.callbackScheme = callbackScheme
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 440))
        web.navigationDelegate = self
        let sheet = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = web
        self.sheet = sheet
        web.load(URLRequest(url: url))
        if let parent = anchor() { parent.beginSheet(sheet, completionHandler: nil) } else { sheet.center(); sheet.orderFrontRegardless() }

        if let delay = autoApproveAfter {
            let id = autoClickID
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                _ = try? await web.evaluateJavaScript("document.getElementById('\(id)').click()")
            }
        }
        return try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    func cancel() {
        if let sheet, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet?.close()
        }
        sheet = nil
        resume(.failure(AuthError.cancelled))
    }

    private func resume(_ result: Result<URL, Error>) {
        guard let continuation, !resumed else { return }
        resumed = true
        self.continuation = nil
        switch result {
        case .success(let url): continuation.resume(returning: url)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, url.scheme == callbackScheme else { return .allow }
        sheet?.sheetParent?.endSheet(sheet!) ?? sheet?.close()
        sheet = nil
        resume(.success(url))
        return .cancel
    }
}
