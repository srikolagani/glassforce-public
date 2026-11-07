import Foundation

/// RFC 7636 Proof Key for Code Exchange, S256 only.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// A fresh 43-character verifier from 32 random bytes.
    public static func generate() -> PKCE {
        PKCE(verifier: randomURLSafeString(byteCount: 32))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(SHA256.hash(Data(verifier.utf8)))
    }

    /// Unreserved characters only, per RFC 7636 §4.1.
    public static func isValidVerifier(_ verifier: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return (43...128).contains(verifier.count) && verifier.allSatisfy(allowed.contains)
    }

    public static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
