import Foundation

/// Where the user signs in. Mirrors the three onboarding choice cards.
public enum LoginEnvironment: Sendable, Hashable, Codable {
    case production
    case sandbox
    /// A My Domain login URL, already normalized (e.g. https://acme.my.salesforce.com).
    case custom(URL)

    public var loginURL: URL {
        switch self {
        case .production: URL(string: "https://login.salesforce.com")!
        case .sandbox: URL(string: "https://test.salesforce.com")!
        case .custom(let url): url
        }
    }

    /// Kind used for badges before the org itself tells us (Organization.IsSandbox wins later).
    public var expectedKind: OrgKind {
        switch self {
        case .production: .production
        case .sandbox: .sandbox
        case .custom(let url): LoginHost.isSandboxHost(url.host ?? "") ? .sandbox : .production
        }
    }

    /// Short slug used for mock routing and logs.
    public var slug: String {
        switch self {
        case .production: "production"
        case .sandbox: "sandbox"
        case .custom(let url): "custom-" + (url.host ?? "unknown")
        }
    }
}

public enum OrgKind: String, Sendable, Codable, CaseIterable {
    case production, sandbox, developer

    /// Sentence-case label for quiet UI badges (never shouty ALL-CAPS).
    public var badgeTitle: String {
        switch self {
        case .production: "Production"
        case .sandbox: "Sandbox"
        case .developer: "Developer"
        }
    }
}

public enum LoginHostError: Error, Equatable, Sendable {
    case empty
    case invalid
    case notSalesforce
}

public enum LoginHost {
    /// Turns what a user types into a My Domain login URL.
    /// Accepts `acme`, `acme--uat.sandbox`, `acme.my.salesforce.com`, or a full https URL.
    public static func normalize(_ input: String) -> Result<URL, LoginHostError> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return .failure(.empty) }
        if text.hasPrefix("http://") { text.removeFirst("http://".count) }
        if text.hasPrefix("https://") { text.removeFirst("https://".count) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        while text.hasSuffix(".") { text.removeLast() }

        let labelChars = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var host: String
        if !text.contains(".") {
            // Bare My Domain name, e.g. "acme" or "acme--uat".
            guard text.allSatisfy(labelChars.contains) else { return .failure(.invalid) }
            host = text.contains("--") ? "\(text).sandbox.my.salesforce.com" : "\(text).my.salesforce.com"
        } else if text.hasSuffix(".sandbox") {
            host = text + ".my.salesforce.com"
        } else {
            host = text
        }

        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(labelChars.contains) }) else { return .failure(.invalid) }
        let allowedSuffixes = [".salesforce.com", ".force.com", ".salesforce.mil", ".cloudforce.com", ".salesforce-setup.com"]
        guard allowedSuffixes.contains(where: { host.hasSuffix($0) }) else { return .failure(.notSalesforce) }
        guard let url = URL(string: "https://\(host)") else { return .failure(.invalid) }
        return .success(url)
    }

    public static func isSandboxHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "test.salesforce.com" || h.hasSuffix(".sandbox.my.salesforce.com") || h.contains("--")
    }

    /// Whether a signed-in instance host belongs to the My Domain the user typed.
    /// Production / sandbox login hosts always differ from the instance, so callers only use this for `.custom`.
    public static func instanceMatchesCustomLogin(instanceHost: String, loginHost: String) -> Bool {
        let instance = instanceHost.lowercased()
        let login = loginHost.lowercased()
        if instance.isEmpty || login.isEmpty { return false }
        if instance == login { return true }
        // Same My Domain stem on Lightning: acme.develop.my.salesforce.com → acme.develop.lightning.force.com
        if let loginURL = URL(string: "https://\(login)"),
           let lightning = LightningHost.base(for: loginURL).host?.lowercased(),
           instance == lightning {
            return true
        }
        // Shared first label (fixture-login / acme--uat) under a Salesforce suffix.
        let instanceStem = instance.split(separator: ".").first.map(String.init) ?? ""
        let loginStem = login.split(separator: ".").first.map(String.init) ?? ""
        return !instanceStem.isEmpty && instanceStem == loginStem
            && (instance.hasSuffix(".salesforce.com") || instance.hasSuffix(".force.com"))
            && (login.hasSuffix(".salesforce.com") || login.hasSuffix(".force.com"))
    }
}
