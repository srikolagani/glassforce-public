import Foundation

/// Salesforce's token endpoint response (authorization_code and refresh_token grants).
public struct TokenResponse: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let instanceURL: URL
    public let id: URL
    public let issuedAt: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case instanceURL = "instance_url"
        case id
        case issuedAt = "issued_at"
    }
}

struct OAuthErrorBody: Decodable {
    let error: String
    let errorDescription: String?
    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// The only secret Glassforce keeps: stored as JSON in one Keychain item per org.
public struct OrgCredentials: Codable, Sendable, Equatable {
    public var refreshToken: String
    public var consumerKey: String
    public var loginURL: URL
    public var instanceURL: URL
    public var idURL: URL

    public init(refreshToken: String, consumerKey: String, loginURL: URL, instanceURL: URL, idURL: URL) {
        self.refreshToken = refreshToken
        self.consumerKey = consumerKey
        self.loginURL = loginURL
        self.instanceURL = instanceURL
        self.idURL = idURL
    }
}

/// Org + user identity, from the `id` URL. The org key is `<orgId>:<userId>`.
public struct OrgIdentity: Sendable, Equatable {
    public let orgID: String
    public let userID: String

    public var key: String { "\(orgID):\(userID)" }

    /// Parses `https://login.salesforce.com/id/<orgId>/<userId>`.
    public init?(idURL: URL) {
        let parts = idURL.path.split(separator: "/").map(String.init)
        guard let idIndex = parts.lastIndex(of: "id"), parts.count >= idIndex + 3 else { return nil }
        orgID = parts[idIndex + 1]
        userID = parts[idIndex + 2]
    }
}

/// What the identity service says about the signed-in user.
public struct IdentityInfo: Decodable, Sendable, Equatable {
    public let username: String
    public let displayName: String
    public let organizationID: String
    public let userID: String

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case organizationID = "organization_id"
        case userID = "user_id"
    }
}
