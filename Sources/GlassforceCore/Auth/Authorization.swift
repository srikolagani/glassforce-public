import Foundation

/// One in-flight browser sign-in: the URL to open plus the secrets needed to finish it.
public struct AuthorizationRequest: Sendable, Equatable {
    public let url: URL
    public let state: String
    public let pkce: PKCE
    public let loginURL: URL
    public let consumerKey: String

    /// - Parameters:
    ///   - loginURL: login.salesforce.com, test.salesforce.com, or a My Domain URL.
    ///   - forceLogin: add `prompt=login` (used for "Add another org" so an existing
    ///     browser session doesn't silently sign the user into the wrong org).
    public init(
        loginURL: URL,
        config: OAuthConfig,
        pkce: PKCE = .generate(),
        state: String = PKCE.randomURLSafeString(byteCount: 16),
        loginHint: String? = nil,
        forceLogin: Bool = false
    ) {
        self.loginURL = loginURL
        self.pkce = pkce
        self.state = state
        self.consumerKey = config.consumerKey

        var components = URLComponents(url: loginURL.appendingPathComponent("services/oauth2/authorize"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.consumerKey),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.redirectURI),
            URLQueryItem(name: "scope", value: OAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
        ]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        if forceLogin { items.append(URLQueryItem(name: "prompt", value: "login")) }
        components.queryItems = items
        self.url = components.url!
    }

    /// Validates the redirect Salesforce sent back and extracts the authorization code.
    public func parseCallback(_ callback: URL) -> Result<String, AuthError> {
        guard callback.absoluteString.hasPrefix(OAuthConfig.redirectURI) else { return .failure(.interrupted) }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        // Form-encoded: decode `+` and %XX exactly once.
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.map(OAuthText.decode) }

        if let error = value("error") {
            return .failure(AuthError.fromOAuth(error: error, description: value("error_description")))
        }
        // Never use a code that comes back with the wrong (or no) state.
        guard value("state") == state else { return .failure(.interrupted) }
        guard let code = value("code"), !code.isEmpty else { return .failure(.interrupted) }
        return .success(code)
    }
}

/// Every way sign-in or refresh can fail, mapped to what the user sees.
public enum AuthError: Error, Equatable, Sendable {
    case notConfigured
    case notInstalled
    case appBlocked
    case accessDenied
    case notPermitted
    case apiDisabled
    case interrupted
    case cancelled
    case needsSignIn
    case offline
    case server(String)

    public static func fromOAuth(error: String, description: String?) -> AuthError {
        let detail = (description ?? "").lowercased()
        // Packaged app not installed in this org (or a key from an org where it isn't installed yet).
        if error == "OAUTH_EC_APP_NOT_FOUND" || detail.contains("must be installed") || detail.contains("not installed")
            || detail.contains("cross-org oauth flows are not supported") {
            return .notInstalled
        }
        switch error {
        case "access_denied": return .accessDenied
        case "OAUTH_APP_BLOCKED": return .appBlocked
        case "OAUTH_APPROVAL_ERROR_GENERIC", "OAUTH_APP_ACCESS_DENIED":
            // Since Sept 2025 an app that isn't installed in the org fails with this generic code.
            if detail.contains("admin approved") || detail.contains("not approved") { return .notPermitted }
            return .notInstalled
        case "API_DISABLED_FOR_ORG": return .apiDisabled
        case "invalid_grant": return .needsSignIn
        case "invalid_client", "invalid_client_id":
            return .server("Salesforce doesn't recognize this app's key in that org")
        case "redirect_uri_mismatch":
            return .server("Salesforce doesn't accept Glassforce's sign-in callback for this app")
        case "unsupported_grant_type":
            return .server("This org doesn't match the environment you picked. Try Production, Sandbox or your My Domain instead")
        case "invalid_request" where detail.contains("grant type"):
            return .server("This org doesn't match the environment you picked. Try Production, Sandbox or your My Domain instead")
        case "OAUTH_AUTHORIZATION_BLOCKED":
            return .server("Your org blocked this sign-in. An admin can allow Glassforce under External Client App Manager")
        default:
            return .server(description.map { $0.isEmpty ? error : $0 } ?? error)
        }
    }

    public var title: String {
        switch self {
        case .notConfigured: "This build isn't connected to a published Glassforce package yet"
        case .notInstalled: "Glassforce isn't installed in this org yet"
        case .appBlocked: "Your org restricts API apps"
        case .accessDenied: "You chose Deny"
        case .notPermitted: "Your admin needs to give you access"
        case .apiDisabled: "This Salesforce edition doesn't allow API access"
        case .interrupted: "Sign-in was interrupted"
        case .cancelled: "Sign-in cancelled"
        case .needsSignIn: "Needs sign-in"
        case .offline: "You're offline"
        case .server(let message): OAuthText.plainSentence(message)
        }
    }

    public var advice: String {
        switch self {
        case .notConfigured: "Build it with scripts/package-eca.sh (see README), or paste your own External Client App consumer key under Advanced."
        case .notInstalled: "Go back to Install, install the package in this org (or send the link to your admin), then connect again."
        case .appBlocked: "Ask your admin to allow Glassforce under Connected Apps OAuth Usage."
        case .accessDenied: "No changes were made. Try again whenever you're ready."
        case .notPermitted: "Ask your admin to assign Glassforce to your profile or permission set."
        case .apiDisabled: "API access is required to search your org."
        case .interrupted: "Please try again."
        case .cancelled: "Pick an environment to try again."
        case .needsSignIn: "Your session ended. Sign in again to keep searching."
        case .offline: "Showing cached results. Glassforce retries automatically."
        case .server: "Please try again."
        }
    }
}

/// Turns OAuth error text into something a person can read.
public enum OAuthText {
    /// Form-style decoding: `+` is a space, then %XX escapes are decoded once.
    public static func decode(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "+", with: " ")
        return text.removingPercentEncoding ?? text
    }

    /// Plain sentence: decoded, first letter capitalized, ends with a period, no raw codes.
    public static func plainSentence(_ raw: String) -> String {
        var text = (raw.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil ? decode(raw) : raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Salesforce returned an error" }
        if text.range(of: "^[A-Z0-9_]+$", options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: "_", with: " ").lowercased()
            text = "Salesforce returned: " + text
        }
        text = text.prefix(1).uppercased() + text.dropFirst()
        if !text.hasSuffix(".") { text += "." }
        return text
    }
}
