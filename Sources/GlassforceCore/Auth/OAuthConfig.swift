import Foundation

/// OAuth client settings. Glassforce is a public client: PKCE instead of a client secret.
public struct OAuthConfig: Sendable, Equatable {
    /// Placeholder until the packaged External Client App exists. Replace with its (public) consumer key.
    public static let placeholderConsumerKey = "GLASSFORCE_CONSUMER_KEY_NOT_CONFIGURED"
    public static let redirectURI = "dev.glassforce.app://oauth/callback"
    public static let callbackScheme = "dev.glassforce.app"
    public static let scopes = ["api", "refresh_token", "id"]

    public var consumerKey: String

    public init(consumerKey: String = OAuthConfig.placeholderConsumerKey) {
        self.consumerKey = consumerKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Built-in key, overridable with the GLASSFORCE_CONSUMER_KEY environment variable
    /// or a per-user "bring your own key" from Advanced settings.
    public static func resolve(userOverride: String?, environment: [String: String]) -> OAuthConfig {
        if let key = userOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { return OAuthConfig(consumerKey: key) }
        if let key = environment["GLASSFORCE_CONSUMER_KEY"], !key.isEmpty { return OAuthConfig(consumerKey: key) }
        return OAuthConfig(consumerKey: PackagedApp.hasConsumerKey ? PackagedApp.consumerKey : placeholderConsumerKey)
    }

    /// Whether this is Glassforce's own packaged app (so "not installed" means: install the package).
    public var isPackagedApp: Bool { consumerKey == PackagedApp.consumerKey }

    public var isConfigured: Bool { !consumerKey.isEmpty && consumerKey != Self.placeholderConsumerKey }
}
