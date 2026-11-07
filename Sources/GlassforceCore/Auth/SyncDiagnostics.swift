import Foundation

/// `--diagnose-sync`: explains why an object synced empty. Read-only GETs only (query, queryAll,
/// describe, identity), and the output is counts, flags and metadata names only: never record contents or tokens.
public struct SyncDiagnostics: Sendable {
    public let client: SalesforceClient
    public init(client: SalesforceClient) { self.client = client }

    public static let objects = ["Account", "Contact", "Opportunity", "Case"]

    /// What we learned about one object, and the plain-words verdict.
    public struct ObjectFinding: Sendable, Equatable {
        public var object: String
        public var queryable: Bool?
        public var retrieveable: Bool?
        public var visibleCount: Int?
        public var deletedCount: Int?
        public var permRead: Bool?
        public var permViewAll: Bool?
        public var orgWideDefault: String?
        public var error: String?

        /// Exactly one of: records visible, profile lacks read, no records exist, or sharing may hide them.
        public func verdict(viewAllData: Bool?) -> String {
            if let error { return "query failed: \(error)" }
            if queryable == false || permRead == false { return "your user's profile/permission sets lack Read on \(object)" }
            guard let visibleCount else { return "unknown (count query failed)" }
            if visibleCount > 0 { return "\(visibleCount) visible, so search should have them" }
            if viewAllData == true || permViewAll == true {
                return "no \(object) records exist (user can see all of them and there are 0; \(deletedCount ?? 0) in the recycle bin)"
            }
            return "0 visible; user lacks View All, so sharing (org-wide default \(orgWideDefault ?? "?")) could hide records"
        }
    }

    public struct Report: Sendable, Equatable {
        public var lines: [String] = []
        public var findings: [ObjectFinding] = []
        public var viewAllData: Bool?
    }

    public func run(org: String, instanceURL: URL) async -> Report {
        var report = Report()
        func line(_ s: String) { report.lines.append(s) }
        line("api \(SalesforceClient.apiVersion), instance host \(instanceURL.host ?? "?")")

        let credentials = try? await client.tokens.credentials(for: org)
        if let credentials {
            line("saved sign-in: instance host \(credentials.instanceURL.host ?? "?") (\(credentials.instanceURL == instanceURL ? "matches" : "DIFFERS from") the org directory), identity host \(credentials.idURL.host ?? "?")")
            if let info = await identityFacts(org: org, idURL: credentials.idURL) { line("identity: \(info)") }
        } else {
            line("saved sign-in: none readable")
        }

        let userID = org.split(separator: ":").last.map(String.init) ?? ""
        let safeID = userID.allSatisfy { $0.isLetter || $0.isNumber } && (userID.count == 15 || userID.count == 18)
        if safeID {
            if let row = try? await client.query(org: org, instanceURL: instanceURL,
                                                 soql: "SELECT UserType, Profile.Name, Profile.UserLicense.Name FROM User WHERE Id = '\(userID)'").first {
                let profile = row["Profile"] as? [String: Any]
                let license = (profile?["UserLicense"] as? [String: Any])?["Name"] as? String
                line("user: type \(row["UserType"] as? String ?? "?"), profile \(profile?["Name"] as? String ?? "?"), license \(license ?? "?")")
            } else { line("user: lookup failed") }
            switch await count(org, instanceURL, "SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = '\(userID)' AND PermissionSet.PermissionsViewAllData = true") {
            case .success(let n): report.viewAllData = n > 0; line("View All Data: \(n > 0 ? "yes" : "no") (\(n) granting assignments)")
            case .failure(let e): line("View All Data: unknown (\(e))")
            }
        } else { line("user id: not parseable from org key") }

        var findings = Self.objects.map { ObjectFinding(object: $0) }
        if safeID, let rows = try? await client.query(org: org, instanceURL: instanceURL, soql:
            "SELECT SobjectType, PermissionsRead, PermissionsViewAllRecords FROM ObjectPermissions WHERE ParentId IN (SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId = '\(userID)') AND SobjectType IN ('Account','Contact','Opportunity','Case')") {
            for i in findings.indices {
                let mine = rows.filter { ($0["SobjectType"] as? String) == findings[i].object }
                findings[i].permRead = mine.contains { $0["PermissionsRead"] as? Bool == true }
                findings[i].permViewAll = mine.contains { $0["PermissionsViewAllRecords"] as? Bool == true }
            }
        }
        if let owd = try? await client.query(org: org, instanceURL: instanceURL,
            soql: "SELECT DefaultAccountAccess, DefaultContactAccess, DefaultOpportunityAccess, DefaultCaseAccess FROM Organization LIMIT 1").first {
            for i in findings.indices { findings[i].orgWideDefault = owd["Default\(findings[i].object)Access"] as? String }
        }

        for i in findings.indices {
            let object = findings[i].object
            if let flags = await describe(org, instanceURL, object) { findings[i].queryable = flags.0; findings[i].retrieveable = flags.1 }
            switch await count(org, instanceURL, "SELECT COUNT() FROM \(object)") {
            case .success(let n): findings[i].visibleCount = n
            case .failure(let e): findings[i].error = e
            }
            if case .success(let n) = await count(org, instanceURL, "SELECT COUNT() FROM \(object) WHERE IsDeleted = true", endpoint: "queryAll") {
                findings[i].deletedCount = n
            }
            let f = findings[i]
            func b(_ v: Bool?) -> String { v.map { $0 ? "yes" : "no" } ?? "?" }
            line("\(object): COUNT() \(f.visibleCount.map(String.init) ?? "-"), recycle bin \(f.deletedCount.map(String.init) ?? "-"), describe queryable \(b(f.queryable)) retrieveable \(b(f.retrieveable)), perm Read \(b(f.permRead)) ViewAll \(b(f.permViewAll)), OWD \(f.orgWideDefault ?? "?")")
            line("\(object) verdict: \(f.verdict(viewAllData: report.viewAllData))")
        }
        for (label, soql) in [("Users", "SELECT COUNT() FROM User"), ("Reports", "SELECT COUNT() FROM Report")] {
            switch await count(org, instanceURL, soql) {
            case .success(let n): line("sanity \(label): COUNT() \(n)")
            case .failure(let e): line("sanity \(label): \(e)")
            }
        }
        for object in SyncObject.builtIns { line("sync query: \(object.soql(cap: SyncPlan.defaultCap))") }
        report.findings = findings
        return report
    }

    enum CountResult { case success(Int), failure(String) }

    private func count(_ org: String, _ instanceURL: URL, _ soql: String, endpoint: String = "query") async -> CountResult {
        var components = URLComponents(url: instanceURL.appendingPathComponent("services/data/\(SalesforceClient.apiVersion)/\(endpoint)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: soql)]
        do {
            let r = try await client.tokens.authorizedSend(org, HTTPRequest(url: components.url!, headers: ["Accept": "application/json"]))
            guard r.status == 200 else { return .failure(QueryError(status: r.status, body: r.body).plainWords) }
            guard let n = ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any])?["totalSize"] as? Int else { return .failure("no totalSize") }
            return .success(n)
        } catch { return .failure("\(error.localizedDescription)") }
    }

    private func describe(_ org: String, _ instanceURL: URL, _ object: String) async -> (Bool?, Bool?)? {
        let url = instanceURL.appendingPathComponent("services/data/\(SalesforceClient.apiVersion)/sobjects/\(object)/describe")
        guard let r = try? await client.tokens.authorizedSend(org, HTTPRequest(url: url, headers: ["Accept": "application/json"])), r.status == 200,
              let json = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] else { return nil }
        return (json["queryable"] as? Bool, json["retrieveable"] as? Bool)
    }

    private func identityFacts(org: String, idURL: URL) async -> String? {
        guard let r = try? await client.tokens.authorizedSend(org, HTTPRequest(url: idURL, headers: ["Accept": "application/json"])), r.status == 200,
              let json = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] else { return nil }
        return "user_type \(json["user_type"] as? String ?? "?"), active \(json["active"].map { "\($0)" } ?? "?")"
    }
}
