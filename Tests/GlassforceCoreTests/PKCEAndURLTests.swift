import Foundation
import Testing
@testable import GlassforceCore

@Suite("PKCE")
struct PKCETests {
    @Test func rfc7636AppendixBVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pkce.method == "S256")
    }

    @Test func sha256KnownAnswers() {
        let hex = { (s: String) in SHA256.hash(Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        #expect(hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(String(repeating: "a", count: 1000)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test func generatedVerifiersAreValidAndUnique() {
        let a = PKCE.generate(), b = PKCE.generate()
        #expect(PKCE.isValidVerifier(a.verifier))
        #expect(a.verifier.count == 43)
        #expect(a.verifier != b.verifier)
        #expect(!a.challenge.contains("=") && !a.challenge.contains("+") && !a.challenge.contains("/"))
    }

    @Test func rejectsShortOrIllegalVerifiers() {
        #expect(!PKCE.isValidVerifier("short"))
        #expect(!PKCE.isValidVerifier(String(repeating: "a", count: 42) + "!"))
    }
}

@Suite("Login hosts and authorize URLs")
struct LoginURLTests {
    let config = OAuthConfig(consumerKey: "KEY123")

    @Test func environmentsMapToTheRightLoginHosts() {
        #expect(LoginEnvironment.production.loginURL.absoluteString == "https://login.salesforce.com")
        #expect(LoginEnvironment.sandbox.loginURL.absoluteString == "https://test.salesforce.com")
        #expect(LoginEnvironment.sandbox.expectedKind == .sandbox)
        #expect(LoginEnvironment.production.expectedKind == .production)
    }

    @Test(arguments: [
        ("acme", "https://acme.my.salesforce.com"),
        ("  ACME  ", "https://acme.my.salesforce.com"),
        ("acme--uat", "https://acme--uat.sandbox.my.salesforce.com"),
        ("acme--uat.sandbox", "https://acme--uat.sandbox.my.salesforce.com"),
        ("acme.my.salesforce.com", "https://acme.my.salesforce.com"),
        ("https://acme--uat.sandbox.my.salesforce.com/", "https://acme--uat.sandbox.my.salesforce.com"),
        ("https://acme.my.salesforce.com/lightning/page/home", "https://acme.my.salesforce.com"),
    ])
    func normalizesMyDomainInput(input: String, expected: String) throws {
        #expect(try LoginHost.normalize(input).get().absoluteString == expected)
    }

    @Test func rejectsBadDomains() {
        #expect(LoginHost.normalize("") == .failure(.empty))
        #expect(LoginHost.normalize("acme corp") == .failure(.invalid))
        #expect(LoginHost.normalize("evil.example.com") == .failure(.notSalesforce))
        #expect(LoginHost.normalize("https://salesforce.com.evil.io") == .failure(.notSalesforce))
    }

    @Test func detectsSandboxHosts() {
        #expect(LoginHost.isSandboxHost("acme--uat.sandbox.my.salesforce.com"))
        #expect(LoginHost.isSandboxHost("test.salesforce.com"))
        #expect(!LoginHost.isSandboxHost("acme.my.salesforce.com"))
        let custom = LoginEnvironment.custom(URL(string: "https://acme--uat.sandbox.my.salesforce.com")!)
        #expect(custom.expectedKind == .sandbox)
    }

    @Test func authorizeURLHasPKCEStateScopesAndCallback() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let request = AuthorizationRequest(loginURL: LoginEnvironment.sandbox.loginURL, config: config, pkce: pkce, state: "STATE1")
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.host == "test.salesforce.com")
        #expect(components.path == "/services/oauth2/authorize")
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "KEY123")
        #expect(items["redirect_uri"] == "dev.glassforce.app://oauth/callback")
        #expect(items["scope"] == "api refresh_token id")
        #expect(items["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "STATE1")
        #expect(items["prompt"] == nil)
        #expect(items["client_secret"] == nil)
    }

    @Test func addAnotherOrgForcesLoginAndHints() throws {
        let request = AuthorizationRequest(loginURL: LoginEnvironment.production.loginURL, config: config, loginHint: "sri@acme.example", forceLogin: true)
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "prompt", value: "login")))
        #expect(query.contains(URLQueryItem(name: "login_hint", value: "sri@acme.example")))
    }

    @Test func myDomainAuthorizeURLUsesThatHost() throws {
        let url = try LoginHost.normalize("acme").get()
        let request = AuthorizationRequest(loginURL: url, config: config)
        #expect(request.url.absoluteString.hasPrefix("https://acme.my.salesforce.com/services/oauth2/authorize?"))
    }

    @Test func callbackRequiresMatchingState() {
        let request = AuthorizationRequest(loginURL: LoginEnvironment.production.loginURL, config: config, state: "GOOD")
        #expect(request.parseCallback(URL(string: "dev.glassforce.app://oauth/callback?code=abc&state=GOOD")!) == .success("abc"))
        #expect(request.parseCallback(URL(string: "dev.glassforce.app://oauth/callback?code=abc&state=EVIL")!) == .failure(.interrupted))
        #expect(request.parseCallback(URL(string: "dev.glassforce.app://oauth/callback?state=GOOD")!) == .failure(.interrupted))
        #expect(request.parseCallback(URL(string: "https://evil.example/cb?code=abc&state=GOOD")!) == .failure(.interrupted))
    }

    @Test(arguments: [
        ("access_denied", "end-user denied authorization", AuthError.accessDenied),
        ("invalid_client", "app must be installed into org", AuthError.notInstalled),
        ("OAUTH_APP_BLOCKED", "", AuthError.appBlocked),
        ("OAUTH_APPROVAL_ERROR_GENERIC", "", AuthError.notInstalled),
        ("OAUTH_APPROVAL_ERROR_GENERIC", "user is not admin approved to access this app", AuthError.notPermitted),
        ("API_DISABLED_FOR_ORG", "", AuthError.apiDisabled),
    ])
    func callbackErrorsMapToScreens(error: String, description: String, expected: AuthError) {
        let request = AuthorizationRequest(loginURL: LoginEnvironment.production.loginURL, config: config, state: "S")
        var components = URLComponents(string: "dev.glassforce.app://oauth/callback")!
        components.queryItems = [URLQueryItem(name: "error", value: error), URLQueryItem(name: "error_description", value: description), URLQueryItem(name: "state", value: "S")]
        #expect(request.parseCallback(components.url!) == .failure(expected))
    }

    @Test func consumerKeyResolution() {
        #expect(!OAuthConfig().isConfigured)
        #expect(OAuthConfig.resolve(userOverride: nil, environment: [:]).consumerKey == (PackagedApp.hasConsumerKey ? PackagedApp.consumerKey : OAuthConfig.placeholderConsumerKey))
        #expect(OAuthConfig.resolve(userOverride: nil, environment: [:]).isPackagedApp == PackagedApp.hasConsumerKey)
        #expect(OAuthConfig.resolve(userOverride: nil, environment: ["GLASSFORCE_CONSUMER_KEY": "ENV"]).consumerKey == "ENV")
        #expect(OAuthConfig.resolve(userOverride: " BYO ", environment: ["GLASSFORCE_CONSUMER_KEY": "ENV"]).consumerKey == "BYO")
        #expect(OAuthConfig(consumerKey: "BYO").isConfigured)
    }

    @Test func authorizeURLUsesChosenLoginHost() throws {
        let cases: [(LoginEnvironment, String)] = [
            (.production, "login.salesforce.com"),
            (.sandbox, "test.salesforce.com"),
            (.custom(try LoginHost.normalize("acme").get()), "acme.my.salesforce.com"),
            (.custom(try LoginHost.normalize("fixture-login.develop.my.salesforce.com").get()),
             "fixture-login.develop.my.salesforce.com"),
        ]
        for (env, host) in cases {
            let request = AuthorizationRequest(loginURL: env.loginURL, config: config, forceLogin: true)
            let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
            #expect(components.host == host)
            #expect(components.path == "/services/oauth2/authorize")
            let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(items["prompt"] == "login")
            #expect(items["client_secret"] == nil)
        }
    }

    @Test func customDomainInstanceMatch() throws {
        // Fixture labels only. Not a connected org.
        let login = try LoginHost.normalize("fixture-login.develop.my.salesforce.com").get().host!
        #expect(LoginHost.instanceMatchesCustomLogin(
            instanceHost: "fixture-login.develop.my.salesforce.com", loginHost: login))
        #expect(LoginHost.instanceMatchesCustomLogin(
            instanceHost: "fixture-login.develop.lightning.force.com", loginHost: login))
        #expect(!LoginHost.instanceMatchesCustomLogin(
            instanceHost: "fixture-other.develop.my.salesforce.com", loginHost: login))
    }
}
