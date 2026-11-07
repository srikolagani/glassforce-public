import Foundation

/// Glassforce's packaged External Client App (unlocked package).
///
/// The consumer key below is a **public** OAuth client id. Glassforce is a public client:
/// PKCE, no client secret exists, and none is ever sent. Env vars and Info.plist still
/// override these shipped defaults for local packaging experiments (`config/glassforce.local.env`).
public enum PackagedApp {
    public static let unsetConsumerKey = "GLASSFORCE_PACKAGED_CONSUMER_KEY_UNSET"
    /// Where Salesforce sends the admin after a successful install (package `postInstallUrl`).
    public static let postInstallURL = "dev.glassforce.app://installed"
    public static let unsetPackageVersionID = "GLASSFORCE_PACKAGE_VERSION_ID_UNSET"

    /// Constant committed in 1f2aaeb. Not a secret (PKCE; no client secret).
    /// Git history has no Dev Hub retrieve for this value. `isRealKey` only rejects an empty or UNSET string,
    /// so a build that uses it is not proof that Salesforce issued a cross-org client id.
    public static let shippedConsumerKey = "3MVG9g9rbsTkKnAVqCOPKskVT9wAkXsHjIeE.5xPqjBkVSdy1B.X.QT4Z74mSOmisabYk2WnHoElehlPYZT_p"
    /// Constant committed beside the client id. Same limit: no packaging-org record is in git.
    public static let shippedPackageVersionID = "04tg7000000d4rlAAA"

    /// Resolution order: environment, then the app's Info.plist, then unset.
    public static func value(_ envKey: String, plistKey: String, unset: String,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        if let v = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        if let v = (info?[plistKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, !v.hasPrefix("$(") { return v }
        return unset
    }

    /// Consumer key of the packaged External Client App (public; PKCE, no secret).
    public static var consumerKey: String {
        let resolved = value("GLASSFORCE_PACKAGED_CONSUMER_KEY", plistKey: "GlassforcePackagedConsumerKey", unset: unsetConsumerKey)
        return isRealKey(resolved) ? resolved : shippedConsumerKey
    }
    /// Subscriber package version id of the managed package (starts with 04t).
    public static var packageVersionID: String {
        let resolved = value("GLASSFORCE_PACKAGE_VERSION_ID", plistKey: "GlassforcePackageVersionID", unset: unsetPackageVersionID)
        return isRealVersion(resolved) ? resolved : shippedPackageVersionID
    }

    public static var hasConsumerKey: Bool { isRealKey(consumerKey) }
    public static var hasPackageVersion: Bool { isRealVersion(packageVersionID) }
    public static var isConfigured: Bool { hasConsumerKey && hasPackageVersion }

    public static func isRealKey(_ key: String) -> Bool { !key.isEmpty && key != unsetConsumerKey && !key.contains("UNSET") }
    public static func isRealVersion(_ id: String) -> Bool { id.hasPrefix("04t") && (id.count == 15 || id.count == 18) }

    /// The admin install page for this exact login host: login.salesforce.com, test.salesforce.com or the My Domain.
    public static func installURL(loginURL: URL, packageVersionID: String = PackagedApp.packageVersionID) -> URL {
        var components = URLComponents(url: loginURL.appendingPathComponent("packaging/installPackage.apexp"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "p0", value: packageVersionID)]
        return components.url!
    }

    /// Message an end user can send their admin.
    public static func adminMessage(installURL: URL) -> String {
        """
        Could you approve Glassforce for our Salesforce org? It's a one-time install (about a minute):
        \(installURL.absoluteString)
        • Glassforce reads records through the REST API, and updates a field only after you confirm the change.
        • It signs in with OAuth 2.0 + PKCE; no passwords or client secrets are stored, tokens stay in each user's Keychain.
        • No servers or telemetry: data stays on the user's Mac. Choose "Install for Admins Only" or the profiles that should use it.
        """
    }
}
