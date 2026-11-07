import Foundation

/// Read-only Salesforce REST calls Glassforce needs: identity, org facts, and the search index sync.
public struct SalesforceClient: Sendable {
    public static let apiVersion = "v62.0"

    public let tokens: TokenManager

    public init(tokens: TokenManager) { self.tokens = tokens }

    public struct OrgFacts: Sendable, Equatable {
        public let name: String
        public let isSandbox: Bool
        public let organizationType: String

        public var kind: OrgKind {
            if isSandbox { return .sandbox }
            return organizationType.localizedCaseInsensitiveContains("developer") ? .developer : .production
        }
    }

    public func identity(org: String, idURL: URL) async throws -> IdentityInfo {
        let response = try await tokens.authorizedSend(org, HTTPRequest(url: idURL, headers: ["Accept": "application/json"]))
        guard response.status == 200 else { throw AuthError.server("Identity request failed (HTTP \(response.status))") }
        return try JSONDecoder().decode(IdentityInfo.self, from: response.body)
    }

    public func organization(org: String, instanceURL: URL) async throws -> OrgFacts {
        let rows = try await query(org: org, instanceURL: instanceURL, soql: "SELECT Name, IsSandbox, OrganizationType FROM Organization LIMIT 1")
        guard let row = rows.first else { throw AuthError.server("Organization not found") }
        return OrgFacts(
            name: row["Name"] as? String ?? "Salesforce org",
            isSandbox: row["IsSandbox"] as? Bool ?? false,
            organizationType: row["OrganizationType"] as? String ?? ""
        )
    }

    /// Pulls the planned objects and turns them into records, reporting progress per object.
    /// Every object gets an outcome (a count or a plain-words failure) so nothing is dropped silently.
    ///
    /// Each object pages through `nextRecordsUrl` up to `plan.cap` rows, newest first. When `state` says the
    /// same query ran fully less than `fullRefreshEvery` ago and `previous` holds its records, only rows with
    /// `LastModifiedDate >=` the last watermark are read and merged by Id; otherwise it's a full read.
    public func syncIndex(org: String, instanceURL: URL, plan: SyncPlan = .builtIns(), previous: [Record] = [],
                          state: SyncState = SyncState(), now: Date = Date(), fullRefreshEvery: TimeInterval = 86_400,
                          progress: @Sendable (SyncProgress) async -> Void) async throws -> SyncReport {
        var records: [Record] = []
        var outcomes: [SyncReport.ObjectOutcome] = []
        var newState = SyncState()
        let cached = Dictionary(grouping: previous.filter { $0.objectName != nil }, by: { $0.objectName! })
        let objects = plan.objects
        for (index, object) in objects.enumerated() {
            await progress(SyncProgress(currentObject: object.plural, recordsSynced: records.count, objectsDone: index, totalObjects: objects.count))
            let fullQuery = object.soql(cap: plan.cap)
            let entry = state.objects[object.name]
            var since: String?
            if let entry, object.ordersByLastModified, entry.query == fullQuery, let watermark = entry.watermark,
               now.timeIntervalSince(entry.lastFullSync) < fullRefreshEvery, cached[object.name] != nil {
                since = watermark
            }
            do {
                let result = try await queryAll(org: org, instanceURL: instanceURL, soql: object.soql(cap: plan.cap, since: since), cap: plan.cap)
                var objectRecords = result.rows.compactMap { object.record(from: $0, instanceURL: instanceURL) }
                let changed = objectRecords.count
                if since != nil {
                    let ids = Set(objectRecords.map(\.id))
                    objectRecords += (cached[object.name] ?? []).filter { !ids.contains($0.id) }
                    if objectRecords.count > plan.cap { objectRecords = Array(objectRecords.prefix(plan.cap)) }
                }
                records += objectRecords
                let newest = [SyncState.newest(result.rows), since == nil ? nil : entry?.watermark].compactMap { $0 }.max()
                newState.objects[object.name] = .init(query: fullQuery, watermark: newest,
                                                      lastFullSync: since == nil ? now : entry!.lastFullSync)
                outcomes.append(.init(object: object.plural, apiName: object.name, status: result.status, totalSize: result.totalSize,
                                      rows: result.rows.count, synced: objectRecords.count, failure: nil,
                                      incremental: since != nil, changed: since != nil ? changed : nil,
                                      pages: result.pages, capped: result.capped ? plan.cap : nil))
            } catch let error as QueryError {
                // Salesforce refused this one object (no permission, object off, bad field): keep going, but say so.
                outcomes.append(.init(object: object.plural, apiName: object.name, status: error.status, totalSize: nil, rows: 0, synced: 0, failure: error.plainWords))
            }
            // Anything else (sign-in expired, offline, the Keychain refusing the saved sign-in) isn't about one
            // object: stop here so it surfaces once, instead of being retried and swallowed per object.
        }
        outcomes += plan.skipped
        if plan.includeSetup {
            let setup = SyncObject.setupShortcuts(instanceURL: instanceURL)
            records += setup
            outcomes.append(.init(object: "Setup", apiName: ObjectSelection.setup, status: nil, totalSize: setup.count, rows: setup.count, synced: setup.count, failure: nil))
        }
        await progress(SyncProgress(currentObject: "Done", recordsSynced: records.count, objectsDone: objects.count, totalObjects: objects.count))
        return SyncReport(records: records, objects: outcomes, state: newState)
    }

    // MARK: Objects (describe)

    /// describeGlobal: every object in the org with its flags. One GET.
    public func describeGlobal(org: String, instanceURL: URL) async throws -> [SObjectSummary] {
        let url = instanceURL.appendingPathComponent("services/data/\(Self.apiVersion)/sobjects")
        let response = try await tokens.authorizedSend(org, HTTPRequest(url: url, headers: ["Accept": "application/json"]))
        guard response.status == 200 else { throw QueryError(status: response.status, body: response.body) }
        struct Global: Decodable { let sobjects: [SObjectSummary] }
        guard let global = try? JSONDecoder().decode(Global.self, from: response.body) else {
            throw QueryError(status: response.status, errorCode: nil, message: "Salesforce answered, but not with an object list Glassforce can read")
        }
        return global.sobjects
    }

    public func describe(org: String, instanceURL: URL, object: String) async throws -> SObjectDescribe {
        guard SyncObject.isSafeName(object) else { throw QueryError(status: 400, errorCode: "INVALID_TYPE", message: "not an object name") }
        let url = instanceURL.appendingPathComponent("services/data/\(Self.apiVersion)/sobjects/\(object)/describe")
        let response = try await tokens.authorizedSend(org, HTTPRequest(url: url, headers: ["Accept": "application/json"]))
        guard response.status == 200 else { throw QueryError(status: response.status, body: response.body) }
        guard let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any], let d = SObjectDescribe(json: json) else {
            throw QueryError(status: response.status, errorCode: nil, message: "Salesforce answered, but not with a describe Glassforce can read")
        }
        return d
    }

    /// Turns the objects picked in Settings into a plan. Built-ins need no call; every other object is described
    /// once to find its name field. An object that's gone or no longer queryable is reported and skipped.
    public func plan(org: String, instanceURL: URL, selection: ObjectSelection, cap: Int = SyncPlan.defaultCap) async throws -> SyncPlan {
        var objects: [SyncObject] = []
        var skipped: [SyncReport.ObjectOutcome] = []
        let builtInOrder = ["Account", "Contact", "Opportunity", "Case"]
        for name in builtInOrder where selection.isEnabled(name) { objects.append(SyncObject.builtIn(name)!) }
        let others = selection.enabled.filter { !builtInOrder.contains($0) && $0 != "Report" && $0 != ObjectSelection.setup }
        var described: [SyncObject] = []
        for name in others {
            do {
                let d = try await describe(org: org, instanceURL: instanceURL, object: name)
                guard d.queryable else {
                    skipped.append(.init(object: d.labelPlural, apiName: name, status: 200, totalSize: nil, rows: 0, synced: 0,
                                         failure: "Salesforce says it can't be queried anymore, so it was skipped"))
                    continue
                }
                described.append(SyncObject.generic(d))
            } catch let error as QueryError {
                skipped.append(.init(object: name, apiName: name, status: error.status, totalSize: nil, rows: 0, synced: 0, failure: error.plainWords))
            }
        }
        objects += described.sorted { $0.plural.localizedLowercase < $1.plural.localizedLowercase }
        if selection.isEnabled("Report") { objects.append(.report) }
        return SyncPlan(objects: objects, includeSetup: selection.isEnabled(ObjectSelection.setup), cap: cap, skipped: skipped)
    }

    /// One field update. Callers must pass a `ConfirmedWrite`; this method does not confirm.
    /// The id and field are identifiers only. Tests drive this through `MockSalesforce`.
    public func updateField(org: String, instanceURL: URL, object: String, id: String, field: String, value: String) async throws {
        guard SyncObject.isSafeName(object), SyncObject.isSafeName(field) else {
            throw QueryError(status: 400, errorCode: "INVALID_FIELD", message: "not a field Glassforce will write")
        }
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw QueryError(status: 400, errorCode: "INVALID_ID", message: "not a record id")
        }
        let url = instanceURL.appendingPathComponent("services/data/\(Self.apiVersion)/sobjects/\(object)/\(id)")
        let body = try JSONSerialization.data(withJSONObject: [field: value])
        let response = try await tokens.authorizedSend(org, HTTPRequest(
            method: "PATCH", url: url,
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: body
        ))
        guard (200..<300).contains(response.status) else { throw QueryError(status: response.status, body: response.body) }
    }

    // MARK: Query

    func query(org: String, instanceURL: URL, soql: String) async throws -> [[String: Any]] {
        try await queryPage(org: org, instanceURL: instanceURL, soql: soql).rows
    }

    struct QueryPage { let status: Int; let totalSize: Int?; let rows: [[String: Any]]; let nextRecordsURL: String? }
    struct QueryResult { let status: Int; let totalSize: Int?; let rows: [[String: Any]]; let pages: Int; let capped: Bool }

    func queryPage(org: String, instanceURL: URL, soql: String) async throws -> QueryPage {
        var components = URLComponents(url: instanceURL.appendingPathComponent("services/data/\(Self.apiVersion)/query"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: soql)]
        return try await fetchPage(org: org, url: components.url!)
    }

    /// Reads every page of a query (Salesforce sends up to 2,000 rows per page plus a `nextRecordsUrl`),
    /// stopping once `cap` rows are in. The query itself also carries `LIMIT cap`.
    func queryAll(org: String, instanceURL: URL, soql: String, cap: Int) async throws -> QueryResult {
        var page = try await queryPage(org: org, instanceURL: instanceURL, soql: soql)
        let first = page
        var rows = page.rows
        var pages = 1
        while rows.count < cap, let next = page.nextRecordsURL {
            // nextRecordsUrl is a path on the same instance; never follow it anywhere else with the token.
            guard let url = URL(string: next, relativeTo: instanceURL)?.absoluteURL,
                  url.host == instanceURL.host, url.port == instanceURL.port, url.scheme == instanceURL.scheme else {
                throw QueryError(status: first.status, errorCode: nil, message: "Salesforce sent a next-page link Glassforce won't follow")
            }
            page = try await fetchPage(org: org, url: url)
            rows += page.rows
            pages += 1
        }
        let capped = rows.count >= cap && (page.nextRecordsURL != nil || rows.count > cap || (first.totalSize ?? 0) >= cap)
        if rows.count > cap { rows = Array(rows.prefix(cap)) }
        return QueryResult(status: first.status, totalSize: first.totalSize, rows: rows, pages: pages, capped: capped)
    }

    private func fetchPage(org: String, url: URL) async throws -> QueryPage {
        // Read-only: the only data calls Glassforce makes are GETs to the query and describe endpoints.
        let response = try await tokens.authorizedSend(org, HTTPRequest(url: url, headers: ["Accept": "application/json"]))
        guard response.status == 200 else { throw QueryError(status: response.status, body: response.body) }
        guard let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let rows = json["records"] as? [[String: Any]] else {
            throw QueryError(status: response.status, errorCode: nil, message: "Salesforce answered, but not with query results Glassforce can read")
        }
        let done = json["done"] as? Bool ?? true
        return QueryPage(status: response.status, totalSize: json["totalSize"] as? Int, rows: rows,
                         nextRecordsURL: done ? nil : json["nextRecordsUrl"] as? String)
    }
}

/// A SOQL query Salesforce refused, with its error code turned into plain words.
public struct QueryError: LocalizedError, Equatable, Sendable {
    public let status: Int
    public let errorCode: String?
    public let message: String?

    public init(status: Int, errorCode: String?, message: String?) {
        self.status = status
        self.errorCode = errorCode
        self.message = message
    }

    /// Salesforce REST errors look like `[{"message": "...", "errorCode": "INVALID_FIELD"}]`.
    init(status: Int, body: Data) {
        let first = ((try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]])?.first
        self.init(status: status, errorCode: first?["errorCode"] as? String, message: first?["message"] as? String)
    }

    public var errorDescription: String? { plainWords }

    public var plainWords: String {
        let why: String
        switch errorCode {
        case "INSUFFICIENT_ACCESS", "INSUFFICIENT_ACCESS_OR_READONLY": why = "your user doesn't have access"
        case "INVALID_TYPE", "NOT_FOUND": why = "this org doesn't have it, or your user can't see it"
        case "INVALID_FIELD", "MALFORMED_QUERY": why = "Salesforce rejected Glassforce's query"
        case "REQUEST_LIMIT_EXCEEDED": why = "the org has used up its API requests for today"
        case "API_DISABLED_FOR_ORG", "API_CURRENTLY_DISABLED": why = "API access is turned off for this org or user"
        default: why = status == 403 ? "your user doesn't have access" : "Salesforce returned HTTP \(status)"
        }
        let detail = [errorCode, message.map { String($0.prefix(160)) }].compactMap { $0 }.joined(separator: ": ")
        return detail.isEmpty ? why : "\(why) (\(detail))"
    }
}

/// What one sync pulled, per object. Counts only: never record contents.
public struct SyncReport: Sendable, Equatable {
    public struct ObjectOutcome: Sendable, Equatable {
        public let object: String
        public let status: Int?
        public let totalSize: Int?
        public let rows: Int
        public let synced: Int
        public let failure: String?
        /// API name ("Account", "Invoice__c", or ObjectSelection.setup), so Settings can show the outcome on its row.
        public let apiName: String?
        /// Only rows changed since the last sync were read and merged into the cached ones.
        public let incremental: Bool
        /// Incremental reads: rows with LastModifiedDate at or after the watermark (second precision, so it
        /// includes rows from the watermark's own second that may not have changed since).
        public let changed: Int?
        public let pages: Int
        /// Set when the object hit the per-object cap, so the index may be missing older records.
        public let capped: Int?

        public init(object: String, apiName: String? = nil, status: Int?, totalSize: Int?, rows: Int, synced: Int, failure: String?,
                    incremental: Bool = false, changed: Int? = nil, pages: Int = 1, capped: Int? = nil) {
            self.object = object; self.apiName = apiName; self.status = status; self.totalSize = totalSize
            self.rows = rows; self.synced = synced; self.failure = failure
            self.incremental = incremental; self.changed = changed; self.pages = pages; self.capped = capped
        }
    }

    public let records: [Record]
    public let objects: [ObjectOutcome]
    /// What the next sync needs to read incrementally.
    public let state: SyncState

    public init(records: [Record], objects: [ObjectOutcome], state: SyncState = SyncState()) {
        self.records = records
        self.objects = objects
        self.state = state
    }

    public func outcome(apiName: String) -> ObjectOutcome? { objects.first { $0.apiName == apiName } }

    public func count(_ object: String) -> Int? { objects.first { $0.object == object }.flatMap { $0.failure == nil ? $0.synced : nil } }

    /// One log line per object, e.g. "Accounts: 12 (HTTP 200, totalSize 12)" or "Cases: FAILED, your user doesn't have access (...)".
    public var logLines: [String] {
        objects.map { o in
            if let failure = o.failure {
                return "\(o.object): FAILED (HTTP \(o.status.map(String.init) ?? "-")), \(failure)"
            }
            var facts: [String] = []
            if let status = o.status { facts.append("HTTP \(status)") }
            if o.incremental {
                facts.append("incremental, \(o.changed ?? o.rows) rows modified at or after the last watermark")
            } else {
                if let total = o.totalSize, o.status != nil { facts.append("totalSize \(total)") }
                if o.rows != o.synced { facts.append("\(o.rows - o.synced) rows unreadable") }
            }
            if o.pages > 1 { facts.append("\(o.pages) pages") }
            if let cap = o.capped { facts.append("capped at \(cap)") }
            return "\(o.object): \(o.synced)" + (facts.isEmpty ? "" : " (\(facts.joined(separator: ", ")))")
        }
    }

    /// Objects Salesforce answered for with zero rows this user can see.
    public var emptyObjects: [String] { objects.filter { $0.failure == nil && $0.status != nil && $0.synced == 0 }.map(\.object) }

    /// What the search panel should say about this sync: only real failures. An object with 0 rows is not an error.
    public func notice(org: String) -> String? { problem }

    /// Settings row for one object. Zero rows is "0 synced", never a warning.
    public static func settingsLine(synced: Int, failure: String?, capped: Int?) -> (text: String, problem: Bool) {
        if let failure { return (failure, true) }
        if let capped { return ("\(synced.formatted()) · capped at \(capped.formatted())", true) }
        return ("\(synced.formatted()) synced", false)
    }

    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " or " + names.last!
    }

    /// Plain words for the search panel when some objects couldn't be read; nil when everything synced.
    public var problem: String? {
        let failed = objects.filter { $0.failure != nil }
        guard !failed.isEmpty else { return nil }
        if failed.count == 1, let only = failed.first, let failure = only.failure {
            return "Couldn't sync \(only.object): \(failure)."
        }
        return "Couldn't sync " + failed.map { "\($0.object) (\($0.failure ?? ""))" }.joined(separator: "; ") + "."
    }
}
