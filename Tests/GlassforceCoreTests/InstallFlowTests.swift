import Foundation
import Testing
@testable import GlassforceCore

@Suite("Install the packaged app, then consent")
struct InstallFlowTests {
    @Test func crossOrgAndNotInstalledOfferBackToInstall() {
        let request = AuthorizationRequest(loginURL: LoginEnvironment.sandbox.loginURL, config: OAuthConfig(consumerKey: "K"))
        let crossOrg = URL(string: "dev.glassforce.app://oauth/callback?error=OAUTH_AUTHORIZATION_BLOCKED&error_description=Cross-org+OAuth+flows+are+not+supported+for+this+external+client+app")!
        let notFound = URL(string: "dev.glassforce.app://oauth/callback?error=OAUTH_EC_APP_NOT_FOUND&error_description=External+client+app+not+found")!
        for callback in [crossOrg, notFound] {
            guard case .failure(let error) = request.parseCallback(callback) else { Issue.record("expected failure"); continue }
            var flow = Onboarding(step: .connecting(.sandbox))
            flow.send(.signInFailed(error))
            #expect(flow.step == .failed(.sandbox, .notInstalled))     // an error screen, not an auto-redirect
            #expect(error.offersBackToInstall)
            #expect(!error.title.contains("%") && !error.title.contains("+"))
            flow.send(.backToInstall)
            #expect(flow.step == .install)
        }
    }

    @Test func disabledStatesHaveNotes() {
        let none = WizardGate.live(packageVersionID: PackagedApp.unsetPackageVersionID, oauth: OAuthConfig())
        #expect(!none.canInstall && !none.canConnect)
        #expect(none.installNote == "No published package in this build yet. Run scripts/package-eca.sh, then rebuild.")
        #expect(none.connectNote?.contains("scripts/package-eca.sh") == true)
        let byoKey = WizardGate.live(packageVersionID: PackagedApp.unsetPackageVersionID, oauth: OAuthConfig(consumerKey: "BYO"))
        #expect(!byoKey.canInstall && byoKey.canConnect && byoKey.connectNote == nil)
        let ready = WizardGate.live(packageVersionID: "04t000000000001AAA", oauth: OAuthConfig(consumerKey: "K"))
        #expect(ready.canInstall && ready.canConnect && ready.installNote == nil && ready.connectNote == nil)
    }

    @Test func installURLPerHost() throws {
        let v = "04t000000000001AAA"
        let custom = LoginEnvironment.custom(try LoginHost.normalize("acme").get())
        let cases: [(LoginEnvironment, String)] = [
            (.production, "https://login.salesforce.com/packaging/installPackage.apexp?p0=\(v)"),
            (.sandbox, "https://test.salesforce.com/packaging/installPackage.apexp?p0=\(v)"),
            (custom, "https://acme.my.salesforce.com/packaging/installPackage.apexp?p0=\(v)"),
        ]
        for (env, expected) in cases {
            #expect(PackagedApp.installURL(loginURL: env.loginURL, packageVersionID: v).absoluteString == expected)
        }
    }

    @Test func installURLUsesTheExactLoginHost() {
        let v = "04t000000000001AAA"
        #expect(PackagedApp.installURL(loginURL: LoginEnvironment.production.loginURL, packageVersionID: v).absoluteString
                == "https://login.salesforce.com/packaging/installPackage.apexp?p0=04t000000000001AAA")
        #expect(PackagedApp.installURL(loginURL: LoginEnvironment.sandbox.loginURL, packageVersionID: v).absoluteString
                == "https://test.salesforce.com/packaging/installPackage.apexp?p0=04t000000000001AAA")
        let custom = LoginEnvironment.custom(try! LoginHost.normalize("acme--uat.sandbox").get())
        #expect(PackagedApp.installURL(loginURL: custom.loginURL, packageVersionID: v).absoluteString
                == "https://acme--uat.sandbox.my.salesforce.com/packaging/installPackage.apexp?p0=04t000000000001AAA")
        #expect(PackagedApp.isConfigured == (PackagedApp.hasConsumerKey && PackagedApp.hasPackageVersion))
        let message = PackagedApp.adminMessage(installURL: URL(string: "https://login.salesforce.com/packaging/installPackage.apexp?p0=\(v)")!)
        #expect(message.contains("p0=\(v)") && message.split(separator: "\n").count == 5)
        #expect(!message.localizedCaseInsensitiveContains("only reads"))
        #expect(!message.localizedCaseInsensitiveContains("read-only"))
        #expect(message.contains("only after you confirm"))
    }

    @Test func mockSimulatesInstallThenConsent() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        mock.requireInstall = true
        let tokens = TokenManager(transport: mock, store: InMemorySecretStore())
        let request = AuthorizationRequest(loginURL: mock.loginURL(for: .sandbox), config: OAuthConfig(consumerKey: MockSalesforce.consumerKey))

        let blocked = try await mock.send(HTTPRequest(url: request.url))
        #expect(request.parseCallback(URL(string: try #require(blocked.headers["Location"]))!) == .failure(.notInstalled))

        let installPage = PackagedApp.installURL(loginURL: mock.loginURL(for: .sandbox), packageVersionID: "04tMOCK")
        let html = String(decoding: try await mock.send(HTTPRequest(url: installPage)).body, as: UTF8.self)
        #expect(!html.contains("read-only API"))
        #expect(html.contains("only after you confirm"))
        let install = try #require(MockSalesforceTests.link(id: "install", in: html, relativeTo: installPage))
        _ = try await mock.send(HTTPRequest(url: install))
        #expect(mock.isInstalled("sandbox") && !mock.isInstalled("production"))

        let page = String(decoding: try await mock.send(HTTPRequest(url: request.url)).body, as: UTF8.self)
        let allow = try #require(MockSalesforceTests.link(id: "allow", in: page, relativeTo: request.url))
        let callback = URL(string: try #require(try await mock.send(HTTPRequest(url: allow)).headers["Location"]))!
        let signIn = try await tokens.completeSignIn(request, code: try request.parseCallback(callback).get())
        #expect(signIn.credentials.instanceURL.path.hasPrefix("/org/sandbox"))
    }

    @Test func mockNonAdminCannotInstall() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        mock.requireInstall = true
        mock.installerIsAdmin = false
        let installPage = PackagedApp.installURL(loginURL: mock.loginURL(for: .production), packageVersionID: "04tMOCK")
        let html = String(decoding: try await mock.send(HTTPRequest(url: installPage)).body, as: UTF8.self)
        #expect(html.contains("Insufficient Privileges"))
        _ = try await mock.send(HTTPRequest(url: mock.loginURL(for: .production).appendingPathComponent("mock/install")))
        #expect(!mock.isInstalled("production"))
    }

    @Test func packagedAppResolutionFallsBackToShippedPublicDefaults() {
        // value() itself still returns unset without env/plist — that's the low-level helper.
        #expect(PackagedApp.value("X_KEY", plistKey: "K", unset: PackagedApp.unsetConsumerKey, environment: [:], info: [:]) == PackagedApp.unsetConsumerKey)
        #expect(PackagedApp.value("X_KEY", plistKey: "K", unset: "u", environment: [:], info: ["K": "$(GF_KEY)"]) == "u")
        #expect(PackagedApp.value("X_KEY", plistKey: "K", unset: "u", environment: [:], info: ["K": "PLIST"]) == "PLIST")
        #expect(PackagedApp.value("X_KEY", plistKey: "K", unset: "u", environment: ["X_KEY": "ENV"], info: ["K": "PLIST"]) == "ENV")
        #expect(!PackagedApp.isRealKey(PackagedApp.unsetConsumerKey) && PackagedApp.isRealKey("ABC123"))
        #expect(!PackagedApp.isRealVersion(PackagedApp.unsetPackageVersionID) && PackagedApp.isRealVersion("04t000000000001AAA"))
        // Fresh clone / test runner: shipped public client id + 04t are enough. No env file needed.
        #expect(PackagedApp.isRealKey(PackagedApp.shippedConsumerKey))
        #expect(PackagedApp.isRealVersion(PackagedApp.shippedPackageVersionID))
        #expect(PackagedApp.isConfigured)
        #expect(OAuthConfig.resolve(userOverride: nil, environment: [:]).isConfigured)
        #expect(OAuthConfig.resolve(userOverride: nil, environment: [:]).isPackagedApp)
        // No client secret anywhere in the authorize URL for the packaged key.
        let request = AuthorizationRequest(loginURL: LoginEnvironment.production.loginURL,
                                           config: OAuthConfig(consumerKey: PackagedApp.shippedConsumerKey))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_secret"] == nil)
        #expect(items["client_id"] == PackagedApp.shippedConsumerKey)
    }

    @Test func unconfiguredBuildMessage() {
        #expect(AuthError.notConfigured.title == "This build isn't connected to a published Glassforce package yet")
        #expect(!AuthError.notConfigured.advice.contains("OAUTH"))
    }

    @Test func notInstalledCodesIncludingCrossOrg() {
        #expect(AuthError.fromOAuth(error: "OAUTH_EC_APP_NOT_FOUND", description: "External client app is not installed in this org") == .notInstalled)
        #expect(AuthError.fromOAuth(error: "OAUTH_AUTHORIZATION_BLOCKED", description: "Cross-org OAuth flows are not supported for this external client app") == .notInstalled)
        #expect(AuthError.fromOAuth(error: "invalid_client", description: "app must be installed into org") == .notInstalled)
        #expect(AuthError.fromOAuth(error: "OAUTH_AUTHORIZATION_BLOCKED", description: "blocked by admin") != .notInstalled)
    }

    @Test func callbackErrorsAreDecodedIntoPlainText() {
        let request = AuthorizationRequest(loginURL: LoginEnvironment.production.loginURL, config: OAuthConfig(consumerKey: "K"))
        let cross = URL(string: "dev.glassforce.app://oauth/callback?error=OAUTH_AUTHORIZATION_BLOCKED&error_description=Cross-org+OAuth+flows+are+not+supported+for+this+external+client+app")!
        #expect(request.parseCallback(cross) == .failure(.notInstalled))
        let other = URL(string: "dev.glassforce.app://oauth/callback?error=server_error&error_description=Something+went%2Bwrong%20here")!
        guard case .failure(let error) = request.parseCallback(other) else { Issue.record("expected failure"); return }
        #expect(error.title == "Something went+wrong here.")
        #expect(OAuthText.decode("a+b%2Cc%2B") == "a b,c+")
        #expect(OAuthText.plainSentence("OAUTH_SOMETHING_ODD") == "Salesforce returned: oauth something odd.")
        #expect(!AuthError.server("bad%20thing").title.contains("%"))
    }

    @Test func mockInstallReturnsToAppLikePostInstallURL() async throws {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        mock.requireInstall = true
        let response = try await mock.send(HTTPRequest(url: mock.loginURL(for: .production).appendingPathComponent("mock/install")))
        #expect(response.headers["Location"] == PackagedApp.postInstallURL)
    }
}
