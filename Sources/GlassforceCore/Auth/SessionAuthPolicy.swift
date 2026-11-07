import Foundation

/// Pure rules for when a normal (non-demo) launch may show an org or its cache.
/// Fixtures / FakeData never enter this path — those stay behind explicit launch flags.
public enum SessionAuthPolicy: Sendable {
    /// Show the honest empty "Connect a Salesforce org" state when nothing is Keychain-backed.
    /// A leftover orgs.json alone must not skip onboarding.
    public static func needsOnboarding(directory: OrgDirectory, hasCredentials: (String) -> Bool) -> Bool {
        guard let org = directory.defaultOrg else { return true }
        return !hasCredentials(org.id)
    }

    /// Cache rows may appear only for the org that currently has credentials.
    public static func mayLoadCache(for orgID: String, authenticatedOrgID: String?) -> Bool {
        guard let authenticatedOrgID, !authenticatedOrgID.isEmpty else { return false }
        return authenticatedOrgID == orgID
    }

    /// Salesforce userinfo must match the org/user parsed from the token `id` URL before Keychain write.
    public static func identityMatches(_ identity: IdentityInfo, org: OrgIdentity) -> Bool {
        identity.organizationID == org.orgID && identity.userID == org.userID
    }

    /// Reject confirm when the pending card's org key does not match the in-memory sign-in.
    public static func pendingMatchesSignIn(pendingOrgKey: String, signInKey: String) -> Bool {
        pendingOrgKey == signInKey && !pendingOrgKey.isEmpty
    }
}
