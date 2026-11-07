import Foundation

/// A local, fake Salesforce used by `--mock-salesforce` and the tests. It implements just enough of
/// OAuth 2.0 (authorization code + PKCE, refresh token rotation, revoke), the identity service and
/// SOQL queries to drive the whole first-run flow end to end. It never talks to a real org.
///
/// The app serves it over HTTP on 127.0.0.1 for the browser step and also calls it in-process as an
/// `HTTPTransport` for API calls, so both paths share one state.
public final class MockSalesforce: HTTPTransport, @unchecked Sendable {
    public static let consumerKey = "MOCK_GLASSFORCE_CONSUMER_KEY"
    /// A client_id the mock treats as "not installed in this org", to exercise that error path.
    public static let notInstalledConsumerKey = "MOCK_NOT_INSTALLED"

    public struct Org: Sendable, Equatable {
        public let slug: String
        public let orgID: String
        public let userID: String
        public let name: String
        public let username: String
        public let displayName: String
        public let isSandbox: Bool
        public let organizationType: String
    }

    struct PendingCode: Codable { let orgSlug: String; let challenge: String; let clientID: String; let redirectURI: String }
    struct PersistentState: Codable {
        var refreshTokens: [String: String] = [:]  // token -> org slug
        var installedSlugs: [String]? = nil        // orgs where the packaged app is installed
    }

    /// Simulate orgs where Glassforce's packaged app isn't installed until someone uses the install page.
    public var requireInstall = false
    /// Whether the person on the install page may install packages (false simulates a non-admin).
    public var installerIsAdmin = true

    /// Per-object query failures to simulate, e.g. `["Case": QueryError(status: 400, errorCode: "INVALID_FIELD", ...)]`.
    public var queryErrors: [String: QueryError] = [:]
    /// Objects that come back with zero rows, like an org with no data in them.
    public var emptyObjects: Set<String> = []
    /// Rows served for an object instead of MockData (tests: big objects, edits between syncs).
    public var rowOverrides: [String: [[String: Any]]] = [:]
    /// Rows per query page. Salesforce's default batch is 2,000; anything over gets a `nextRecordsUrl`.
    public var pageSize = 2000
    /// Ignore `LIMIT` in queries, to prove the client enforces its own per-object cap.
    public var ignoreLimit = false
    /// Objects whose describe comes back `queryable: false` (e.g. an admin turned it off).
    public var nonQueryable: Set<String> = []
    /// Every data request path (and SOQL, if any), in order. Tests count pages and check read-only use.
    public var dataRequests: [String] { locked { requestLog } }
    /// PATCH bodies from confirmed writes. Tests only. Never a real org.
    public var patchBodies: [String] { locked { patchLog } }
    private var patchLog: [String] = []
    private var requestLog: [String] = []
    private var cursors: [String: [[String: Any]]] = [:]

    public var baseURL: URL
    /// Artificial latency per SOQL query so sync progress is visible in demos.
    public var queryDelay: TimeInterval
    private let stateFile: URL?
    private let lock = NSLock()
    private var codes: [String: PendingCode] = [:]
    private var accessTokens: [String: String] = [:]     // token -> org slug
    private var state = PersistentState()
    private var counter = 0

    public init(baseURL: URL = URL(string: "http://127.0.0.1:0")!, stateFile: URL? = nil, queryDelay: TimeInterval = 0) {
        self.baseURL = baseURL
        self.stateFile = stateFile
        self.queryDelay = queryDelay
        if let stateFile, let data = try? Data(contentsOf: stateFile),
           let saved = try? JSONDecoder().decode(PersistentState.self, from: data) {
            state = saved
        }
    }

    /// Login URL the app should use for an environment while mocking.
    public func loginURL(for environment: LoginEnvironment) -> URL {
        baseURL.appendingPathComponent("env/\(environment.slug)")
    }

    public static func org(forSlug slug: String) -> Org {
        switch slug {
        case "production":
            return Org(slug: slug, orgID: "00D5g000004GLASS", userID: "0055g00000SRIKOL", name: "Acme Corp",
                       username: "sri@acme.example", displayName: "Sri Kolagani", isSandbox: false, organizationType: "Enterprise Edition")
        case "sandbox":
            return Org(slug: slug, orgID: "00D7z000000UAT01", userID: "0057z00000SRIUAT", name: "Acme Corp (UAT)",
                       username: "sri@acme.example.uat", displayName: "Sri Kolagani", isSandbox: true, organizationType: "Enterprise Edition")
        default:
            let host = slug.replacingOccurrences(of: "custom-", with: "")
            let first = host.split(separator: ".").first.map(String.init) ?? "custom"
            let company = first.split(separator: "-").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Custom"
            let sandbox = LoginHost.isSandboxHost(host)
            // Stable across launches (Swift's hashValue is randomized per process).
            let digest = SHA256.hash(Data(host.utf8)).map { String(format: "%02X", $0) }.joined()
            return Org(slug: slug, orgID: "00D" + digest.prefix(12), userID: "005" + digest.suffix(12),
                       name: company + (sandbox ? " (Sandbox)" : ""), username: "sri@\(first).example",
                       displayName: "Sri Kolagani", isSandbox: sandbox, organizationType: "Enterprise Edition")
        }
    }

    // MARK: Test hooks

    /// Forgets every access token, as if sessions timed out. The next API call gets a 401.
    public func expireAccessTokens() { locked { accessTokens.removeAll() } }

    /// Revokes every refresh token, as if an admin revoked access. The next refresh gets invalid_grant.
    public func revokeAllRefreshTokens() { locked { state.refreshTokens.removeAll(); persist() } }

    public var validRefreshTokenCount: Int { locked { state.refreshTokens.count } }

    // MARK: HTTPTransport

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (response, delay) = handle(request)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return response
    }

    /// Routes one request. Returns the response and how long to wait before sending it.
    public func handle(_ request: HTTPRequest) -> (HTTPResponse, TimeInterval) {
        let parts = request.url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }

        // /env/<slug>/services/oauth2/{authorize,token,revoke} and /env/<slug>/mock/{approve,deny}
        if parts.count >= 3, parts[0] == "env" {
            let slug = parts[1]
            let rest = parts.dropFirst(2).joined(separator: "/")
            switch (request.method, rest) {
            case ("GET", "services/oauth2/authorize"): return (authorizePage(slug: slug, query: query), 0)
            case ("GET", "packaging/installPackage.apexp"): return (installPage(slug: slug, query: query), 0)
            case ("GET", "mock/install"):
                guard installerIsAdmin else { return (installPage(slug: slug, query: query), 0) }
                locked {
                    var set = Set(state.installedSlugs ?? []); set.insert(slug)
                    state.installedSlugs = set.sorted(); persist()
                }
                // Like the package's postInstallUrl: hand control back to the app.
                return (HTTPResponse(status: 302, headers: ["Location": q("return") ?? PackagedApp.postInstallURL]), 0.6)
            case ("GET", "mock/approve"): return (approve(slug: slug, q: q), 0.4)
            case ("GET", "mock/deny"): return (redirect(q("redirect_uri"), ["error": "access_denied", "error_description": "end-user denied authorization", "state": q("state") ?? ""]), 0)
            case ("POST", "services/oauth2/token"): return (token(slug: slug, form: form(request)), 0.3)
            case ("POST", "services/oauth2/revoke"):
                let token = form(request)["token"] ?? ""
                locked { state.refreshTokens[token] = nil; accessTokens[token] = nil; persist() }
                return (HTTPResponse(status: 200), 0)
            default: break
            }
        }
        // /id/<orgId>/<userId>
        if parts.count == 3, parts[0] == "id" {
            guard let slug = authorizedSlug(request) else { return (invalidSession(), 0) }
            let org = Self.org(forSlug: slug)
            return (json(200, [
                "id": baseURL.appendingPathComponent("id/\(org.orgID)/\(org.userID)").absoluteString,
                "username": org.username, "display_name": org.displayName,
                "organization_id": org.orgID, "user_id": org.userID,
            ]), 0.2)
        }
        // /org/<slug>/services/data/<version>/{query?q=…, query/<cursor>, sobjects, sobjects/<Name>/describe}
        if parts.count >= 6, parts[0] == "org", parts[2] == "services", parts[3] == "data" {
            guard let slug = authorizedSlug(request), slug == parts[1] else { return (invalidSession(), 0) }
            let tail = Array(parts.dropFirst(5))
            locked { requestLog.append(([request.method, "/" + tail.joined(separator: "/")] + (q("q").map { [$0] } ?? [])).joined(separator: " ")) }
            if request.method == "PATCH", tail.count == 3, tail[0] == "sobjects" {
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                locked { patchLog.append(body) }
                return (HTTPResponse(status: 204), 0)
            }
            guard request.method == "GET" else { return (json(405, [["errorCode": "METHOD_NOT_ALLOWED", "message": "mock is read-only"]]), 0) }
            switch tail.count {
            case 1 where tail[0] == "query":
                let soql = q("q") ?? ""
                if let object = Self.object(in: soql), let error = queryErrors[object] {
                    return (json(error.status, [["errorCode": error.errorCode ?? "", "message": error.message ?? ""]]), queryDelay)
                }
                let records = Self.object(in: soql).map(emptyObjects.contains) == true ? [] : rows(for: soql, slug: slug)
                return (firstPage(records, slug: slug), queryDelay)
            case 2 where tail[0] == "query":
                return (nextPage(cursor: tail[1], slug: slug), queryDelay)
            case 1 where tail[0] == "sobjects":
                return (json(200, ["encoding": "UTF-8", "maxBatchSize": 200, "sobjects": MockData.globalObjects]), queryDelay)
            case 3 where tail[0] == "sobjects" && tail[2] == "describe":
                let name = tail[1]
                guard var describe = MockData.describe(name) else {
                    return (json(404, [["errorCode": "NOT_FOUND", "message": "The requested resource does not exist"]]), 0)
                }
                if nonQueryable.contains(name) { describe["queryable"] = false }
                return (json(200, describe), 0.05)
            default: break
            }
        }
        return (HTTPResponse(status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8)), 0)
    }

    // MARK: Package install

    public func isInstalled(_ slug: String) -> Bool { locked { (state.installedSlugs ?? []).contains(slug) } }

    public func uninstallAll() { locked { state.installedSlugs = []; persist() } }

    private func installPage(slug: String, query: [URLQueryItem]) -> HTTPResponse {
        let org = Self.org(forSlug: slug)
        guard installerIsAdmin else {
            return page(title: "Insufficient Privileges", body: "<h1>Insufficient Privileges</h1><p>You can't install packages in \(org.name). Ask your Salesforce admin to install Glassforce.</p>")
        }
        let qs = (URLComponents(string: "x:?")!.with(query).percentEncodedQuery ?? "").replacingOccurrences(of: "&", with: "&amp;")
        return page(title: "Install Glassforce", body: """
          <span class="tag">PACKAGE INSTALL</span>
          <h1>Install Glassforce in \(org.name)</h1>
          <p>Publisher: Glassforce · Version 0.1 · Contains: External Client App “Glassforce” (reads records; updates a field only after you confirm, PKCE)</p>
          <ul><li>Install for Admins Only</li><li>Install for All Users</li></ul>
          <div class="row"><a id="install" href="/env/\(slug)/mock/install?\(qs)">Install</a></div>
        """)
    }

    private func page(title: String, body: String) -> HTTPResponse {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Mock Salesforce · \(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 14px -apple-system, system-ui, sans-serif; margin: 0; display: grid; place-items: center; min-height: 100vh;
                 background: light-dark(#f2f3f7, #1c1c1e); color: light-dark(#1d1d1f, #f5f5f7); }
          .card { width: 380px; padding: 28px; border-radius: 18px; background: light-dark(#fff, #2c2c2e); box-shadow: 0 8px 30px rgba(0,0,0,.12); }
          .tag { font-size: 11px; font-weight: 700; letter-spacing: .06em; color: #8e8e93; }
          h1 { font-size: 20px; margin: 12px 0 6px; } p, ul { color: light-dark(#6e6e73, #a1a1a6); line-height: 1.5; }
          .row { display: flex; } a { flex: 1; text-align: center; text-decoration: none; padding: 10px; border-radius: 10px; font-weight: 600; background: #0a84ff; color: #fff; }
          .mock { margin-top: 16px; font-size: 11px; color: #8e8e93; text-align: center; }
        </style></head><body><div class="card">\(body)<div class="mock">Mock Salesforce running on this Mac. No real org is contacted.</div></div></body></html>
        """
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    // MARK: OAuth

    private func authorizePage(slug: String, query: [URLQueryItem]) -> HTTPResponse {
        let org = Self.org(forSlug: slug)
        let clientID = query.first { $0.name == "client_id" }?.value ?? ""
        let redirectURI = query.first { $0.name == "redirect_uri" }?.value
        let state = query.first { $0.name == "state" }?.value ?? ""
        if requireInstall, !isInstalled(slug) {
            // Real orgs (since Sept 2025): an app that isn't installed fails after login with this code.
            return redirect(redirectURI, ["error": "OAUTH_APPROVAL_ERROR_GENERIC", "error_description": "app must be installed into org", "state": state])
        }
        if clientID == Self.notInstalledConsumerKey {
            return redirect(redirectURI, ["error": "invalid_client", "error_description": "app must be installed into org", "state": state])
        }
        // Absolute paths: the page lives at /env/<slug>/services/oauth2/authorize, so a relative
        // "mock/approve" would resolve under /services/oauth2/ in a real browser.
        let qs = (URLComponents(string: "x:?")!.with(query).percentEncodedQuery ?? "").replacingOccurrences(of: "&", with: "&amp;")
        let approveHref = "/env/\(slug)/mock/approve?\(qs)"
        let denyHref = "/env/\(slug)/mock/deny?\(qs)"
        let env = org.isSandbox ? "SANDBOX" : "PRODUCTION"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>Mock Salesforce · Allow access</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 14px -apple-system, system-ui, sans-serif; margin: 0; display: grid; place-items: center; min-height: 100vh;
                 background: light-dark(#f2f3f7, #1c1c1e); color: light-dark(#1d1d1f, #f5f5f7); }
          .card { width: 360px; padding: 28px; border-radius: 18px; background: light-dark(#fff, #2c2c2e); box-shadow: 0 8px 30px rgba(0,0,0,.12); }
          .tag { display: inline-block; font-size: 11px; font-weight: 700; letter-spacing: .06em; padding: 3px 8px; border-radius: 999px;
                 background: \(org.isSandbox ? "#ffb02033" : "#ff3b3026"); color: \(org.isSandbox ? "#b26a00" : "#d70015"); }
          h1 { font-size: 20px; margin: 14px 0 6px; } p { color: light-dark(#6e6e73, #a1a1a6); line-height: 1.45; margin: 0 0 6px; }
          ul { padding-left: 18px; color: light-dark(#6e6e73, #a1a1a6); margin: 12px 0 20px; line-height: 1.6; }
          .row { display: flex; gap: 10px; } a { flex: 1; text-align: center; text-decoration: none; padding: 10px; border-radius: 10px; font-weight: 600; }
          #allow { background: #0a84ff; color: #fff; } #deny { background: light-dark(#e8e8ed, #3a3a3c); color: inherit; }
          .mock { margin-top: 16px; font-size: 11px; color: #8e8e93; text-align: center; }
        </style></head><body><div class="card">
          <span class="tag">\(env)</span>
          <h1>Allow Glassforce to access \(org.name)?</h1>
          <p>Signed in as <b>\(org.username)</b></p>
          <ul><li>Access and manage your data (api)</li><li>Perform requests at any time (refresh_token)</li><li>Access your basic information (id)</li></ul>
          <div class="row"><a id="deny" href="\(denyHref)">Deny</a><a id="allow" href="\(approveHref)">Allow</a></div>
          <div class="mock">Mock Salesforce running on this Mac. No real org is contacted.</div>
        </div></body></html>
        """
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    private func approve(slug: String, q: (String) -> String?) -> HTTPResponse {
        guard let redirectURI = q("redirect_uri"), let challenge = q("code_challenge"), q("code_challenge_method") == "S256" else {
            return redirect(q("redirect_uri"), ["error": "invalid_request", "error_description": "PKCE S256 code_challenge required", "state": q("state") ?? ""])
        }
        let code = locked { () -> String in
            let code = nextToken("mockcode")
            codes[code] = PendingCode(orgSlug: slug, challenge: challenge, clientID: q("client_id") ?? "", redirectURI: redirectURI)
            return code
        }
        return redirect(redirectURI, ["code": code, "state": q("state") ?? ""])
    }

    private func token(slug: String, form: [String: String]) -> HTTPResponse {
        switch form["grant_type"] {
        case "authorization_code":
            return locked {
                guard let code = form["code"], let pending = codes.removeValue(forKey: code) else {
                    return oauthError("invalid_grant", "invalid authorization code")
                }
                guard pending.redirectURI == form["redirect_uri"], pending.clientID == form["client_id"] else {
                    return oauthError("invalid_grant", "redirect_uri or client_id mismatch")
                }
                guard let verifier = form["code_verifier"], PKCE.challenge(for: verifier) == pending.challenge else {
                    return oauthError("invalid_grant", "invalid code verifier")
                }
                return issueTokens(slug: pending.orgSlug, includeRefresh: true)
            }
        case "refresh_token":
            return locked {
                guard let old = form["refresh_token"], let orgSlug = state.refreshTokens.removeValue(forKey: old) else {
                    return oauthError("invalid_grant", "expired access/refresh token")
                }
                // Refresh token rotation: the old token is now dead; a new one is issued.
                return issueTokens(slug: orgSlug, includeRefresh: true)
            }
        default:
            return oauthError("unsupported_grant_type", "grant type not supported")
        }
    }

    /// Caller holds the lock.
    private func issueTokens(slug: String, includeRefresh: Bool) -> HTTPResponse {
        let org = Self.org(forSlug: slug)
        let access = nextToken("mockat")
        accessTokens[access] = slug
        var body: [String: Any] = [
            "access_token": access,
            "instance_url": baseURL.appendingPathComponent("org/\(slug)").absoluteString,
            "id": baseURL.appendingPathComponent("id/\(org.orgID)/\(org.userID)").absoluteString,
            "token_type": "Bearer",
            "issued_at": "\(Int(Date().timeIntervalSince1970 * 1000))",
            "scope": "api refresh_token id",
        ]
        if includeRefresh {
            let refresh = nextToken("mockrt")
            state.refreshTokens[refresh] = slug
            body["refresh_token"] = refresh
            persist()
        }
        return json(200, body)
    }

    // MARK: Data

    /// Rows for `SELECT … FROM <Object> [WHERE LastModifiedDate >= <t>] [ORDER BY LastModifiedDate DESC] [LIMIT n]`.
    private func rows(for soql: String, slug: String) -> [[String: Any]] {
        let org = Self.org(forSlug: slug)
        guard let object = Self.object(in: soql) else { return [] }
        if object == "Organization" {
            return [["Name": org.name, "IsSandbox": org.isSandbox, "OrganizationType": org.organizationType]]
        }
        var records = locked { rowOverrides[object] } ?? MockData.rows(sandbox: org.isSandbox)[object] ?? []
        records = records.map { row in
            var row = row
            if row["LastModifiedDate"] == nil { row["LastModifiedDate"] = MockData.defaultModified }
            return row
        }
        if let since = Self.clause(#"LastModifiedDate >= (\S+)"#, in: soql) {
            records = records.filter { (($0["LastModifiedDate"] as? String).flatMap { SyncState.literal($0) } ?? "") >= since }
        }
        if soql.range(of: "ORDER BY LastModifiedDate DESC", options: .caseInsensitive) != nil {
            records = records.enumerated().sorted { a, b in
                let l = a.element["LastModifiedDate"] as? String ?? "", r = b.element["LastModifiedDate"] as? String ?? ""
                return l != r ? l > r : a.offset < b.offset
            }.map(\.element)
        }
        if !ignoreLimit, let limit = Self.clause(#"LIMIT (\d+)"#, in: soql).flatMap(Int.init) { records = Array(records.prefix(limit)) }
        return records
    }

    private func firstPage(_ records: [[String: Any]], slug: String) -> HTTPResponse {
        guard records.count > pageSize else { return json(200, ["totalSize": records.count, "done": true, "records": records]) }
        let cursor = locked { () -> String in
            counter += 1
            let id = "01gMOCK\(counter)"
            cursors[id] = records
            return id
        }
        return page(records, from: 0, cursor: cursor, slug: slug)
    }

    private func nextPage(cursor: String, slug: String) -> HTTPResponse {
        let bits = cursor.split(separator: "-")
        guard bits.count == 2, let offset = Int(bits[1]), let records = locked({ cursors[String(bits[0])] }) else {
            return json(400, [["errorCode": "INVALID_QUERY_LOCATOR", "message": "invalid query locator"]])
        }
        return page(records, from: offset, cursor: String(bits[0]), slug: slug)
    }

    private func page(_ records: [[String: Any]], from offset: Int, cursor: String, slug: String) -> HTTPResponse {
        let end = min(offset + pageSize, records.count)
        var body: [String: Any] = ["totalSize": records.count, "done": end >= records.count, "records": Array(records[offset..<end])]
        if end < records.count {
            // Like Salesforce, a path on the instance; the mock's instance lives under /org/<slug>.
            body["nextRecordsUrl"] = "/org/\(slug)/services/data/\(SalesforceClient.apiVersion)/query/\(cursor)-\(end)"
        }
        return json(200, body)
    }

    static func clause(_ pattern: String, in soql: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: soql, range: NSRange(soql.startIndex..., in: soql)),
              let r = Range(m.range(at: 1), in: soql) else { return nil }
        return String(soql[r])
    }

    /// `count` fictional rows for an object, newest first, one minute apart (tests: paging and caps).
    public static func generatedRows(_ object: String, count: Int) -> [[String: Any]] {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'+0000'"
        return (0..<count).map { n in
            var row: [String: Any] = ["Id": String(format: "GEN%@%09d", object.prefix(3).uppercased(), n),
                                      "LastModifiedDate": f.string(from: base.addingTimeInterval(TimeInterval(-60 * n)))]
            switch object {
            case "Case": row["CaseNumber"] = String(format: "%08d", n); row["Subject"] = "Generated case \(n)"; row["Priority"] = "Low"
            default: row["Name"] = "Generated \(object) \(n)"
            }
            return row
        }
    }

    // MARK: Helpers

    /// The object a `SELECT … FROM <Object> …` query reads.
    static func object(in soql: String) -> String? {
        let words = soql.split(separator: " ")
        guard let from = words.firstIndex(where: { $0.uppercased() == "FROM" }), from + 1 < words.count else { return nil }
        return String(words[from + 1])
    }

    private func authorizedSlug(_ request: HTTPRequest) -> String? {
        guard let header = request.headers["Authorization"], header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        return locked { accessTokens[token] }
    }

    private func invalidSession() -> HTTPResponse {
        json(401, [["message": "Session expired or invalid", "errorCode": "INVALID_SESSION_ID"]])
    }

    private func oauthError(_ error: String, _ description: String) -> HTTPResponse {
        json(400, ["error": error, "error_description": description])
    }

    private func redirect(_ uri: String?, _ params: [String: String]) -> HTTPResponse {
        guard let uri, var components = URLComponents(string: uri) else {
            return HTTPResponse(status: 400, body: Data("Missing redirect_uri".utf8))
        }
        components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return HTTPResponse(status: 302, headers: ["Location": components.url!.absoluteString, "Content-Length": "0"])
    }

    private func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    private func form(_ request: HTTPRequest) -> [String: String] {
        FormEncoding.decode(String(decoding: request.body ?? Data(), as: UTF8.self))
    }

    /// Caller holds the lock.
    private func nextToken(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)_\(counter)_" + PKCE.randomURLSafeString(byteCount: 18)
    }

    /// Caller holds the lock.
    private func persist() {
        guard let stateFile else { return }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private extension URLComponents {
    func with(_ items: [URLQueryItem]) -> URLComponents {
        var copy = self
        copy.queryItems = items
        return copy
    }
}
