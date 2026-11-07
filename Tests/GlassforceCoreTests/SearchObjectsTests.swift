import Foundation
import Testing
@testable import GlassforceCore

/// Settings › Search objects and the paging sync behind it, against the in-process mock org.
@Suite("Search objects and paged sync")
struct SearchObjectsTests {
    struct Org { let mock: MockSalesforce; let client: SalesforceClient; let key: String; let instance: URL }

    func connected(_ configure: (MockSalesforce) -> Void = { _ in }) async throws -> Org {
        let mock = MockSalesforce(baseURL: URL(string: "http://127.0.0.1:7777")!)
        configure(mock)
        let tokens = TokenManager(transport: mock, store: InMemorySecretStore())
        let signIn = try await MockSalesforceTests().signIn(mock, tokens, env: .production)
        return Org(mock: mock, client: SalesforceClient(tokens: tokens), key: signIn.identity.key, instance: signIn.credentials.instanceURL)
    }

    func tempStore() -> LocalStore {
        LocalStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gf-objects-\(UUID().uuidString)"))
    }

    // MARK: Picker

    @Test func pickerListsSearchableObjectsAndHidesSystemOnes() async throws {
        let org = try await connected()
        let all = try await org.client.describeGlobal(org: org.key, instanceURL: org.instance)
        #expect(all.count == 23)
        let names = ObjectCatalog.searchObjects(all).map(\.name)
        // Sorted by label: Account, Campaign, Case, Contact, Invoice, Lead, Opportunity, Shipment.
        #expect(names == ["Account", "Campaign", "Case", "Contact", "Invoice__c", "Lead", "Opportunity", "Shipment__c"])
        for hidden in ["AccountHistory", "AccountShare", "AccountFeed", "AccountChangeEvent", "AccountTag", "Invoice__History",
                       "Glassforce_Config__mdt", "Order_Placed__e", "Legacy_Thing__c", "Routing_Setting__c", "ApexLog", "Vote", "FieldDefinition", "Report"] {
            #expect(!names.contains(hidden), "\(hidden) should be hidden")
        }
        #expect(ObjectCatalog.searchObjects(all).first { $0.name == "Invoice__c" }?.custom == true)
        #expect(org.mock.dataRequests.allSatisfy { $0.hasPrefix("GET ") })
    }

    @Test func unsafeNamesNeverReachSOQL() {
        #expect(SyncObject.isSafeName("Invoice__c"))
        #expect(SyncObject.isSafeName("ns__Thing__c"))
        #expect(!SyncObject.isSafeName("Account WHERE Id != null"))
        #expect(!SyncObject.isSafeName("../query"))
        #expect(!SyncObject.isSafeName("__c"))
    }

    @Test func defaultSelection() {
        let d = ObjectSelection.defaults
        #expect(Set(d.enabled) == ["Account", "Contact", "Opportunity", "Case", "Lead", "Report", ObjectSelection.setup])
        #expect(!d.isEnabled("Campaign"))
        #expect(ObjectSelectionStore(local: tempStore()).load(orgID: "00DNEW") == .defaults)
    }

    @Test func selectionPersistsPerOrg() throws {
        let local = tempStore()
        defer { try? FileManager.default.removeItem(at: local.directory) }
        let store = ObjectSelectionStore(local: local)
        var a = ObjectSelection.defaults
        a.set("Invoice__c", enabled: true)
        a.set("Lead", enabled: false)
        try store.save(a, orgID: ObjectSelectionStore.orgID(fromKey: "00DAAA:005USER1"))
        #expect(ObjectSelectionStore.orgID(fromKey: "00DAAA:005USER1") == "00DAAA")
        // Same org, another user on this Mac: same selection. Another org: still the defaults.
        #expect(store.load(orgID: ObjectSelectionStore.orgID(fromKey: "00DAAA:005USER2")) == a)
        #expect(store.load(orgID: "00DBBB") == .defaults)
        #expect(store.load(orgID: "00DAAA").isEnabled("Invoice__c"))
        #expect(!store.load(orgID: "00DAAA").isEnabled("Lead"))
    }

    // MARK: Plan (describe → name field)

    @Test func defaultPlanDescribesOnlyNonBuiltIns() async throws {
        let org = try await connected()
        let plan = try await org.client.plan(org: org.key, instanceURL: org.instance, selection: .defaults)
        #expect(plan.objects.map(\.name) == ["Account", "Contact", "Opportunity", "Case", "Lead", "Report"])
        #expect(plan.includeSetup)
        #expect(plan.cap == 50_000)
        #expect(org.mock.dataRequests.filter { $0.hasSuffix("/describe") } == ["GET /sobjects/Lead/describe"])
        let lead = try #require(plan.objects.first { $0.name == "Lead" })
        #expect(lead.titleFields == ["Name"])
        #expect(lead.subtitleFields == ["Company", "Status"])
        #expect(lead.soql(cap: 50_000) == "SELECT Id, Name, Company, Status, LastModifiedDate FROM Lead ORDER BY LastModifiedDate DESC LIMIT 50000")
    }

    @Test func customObjectUsesItsNameFieldNotTheFirstTextField() async throws {
        let org = try await connected()
        var selection = ObjectSelection(enabled: ["Shipment__c", "Invoice__c"])
        selection.set(ObjectSelection.setup, enabled: false)
        let plan = try await org.client.plan(org: org.key, instanceURL: org.instance, selection: selection)
        let shipment = try #require(plan.objects.first { $0.name == "Shipment__c" })
        #expect(shipment.titleFields == ["Name"])          // not Carrier__c, which comes first
        #expect(shipment.subtitleFields == ["Carrier__c"]) // no common field, so the first custom text field
        #expect(plan.objects.first { $0.name == "Invoice__c" }?.subtitleFields == ["Status__c"]) // Amount__c is currency
        #expect(!plan.includeSetup)

        let report = try await org.client.syncIndex(org: org.key, instanceURL: org.instance, plan: plan) { _ in }
        let row = try #require(report.records.first { $0.id == "a02A0000SHP0001" })
        #expect(row.title == "SHP-0001")
        #expect(row.subtitle == "FedEx")
        #expect(row.kind == .other && row.typeLabel == "Shipment" && row.groupTitle == "Shipments")
        #expect(row.url?.path == "/org/production/lightning/r/Shipment__c/a02A0000SHP0001/view")
        #expect(RecordStore.grouped(RecordStore(records: report.records).search("shipments")).first?.title == "Shipments")
    }

    @Test func autoNumberNameGetsTheSubject() {
        let d = SObjectDescribe(name: "WorkOrder", label: "Work Order", labelPlural: "Work Orders", custom: false, queryable: true, fields: [
            .init(name: "Id", type: "id"), .init(name: "WorkOrderNumber", nameField: true, autoNumber: true),
            .init(name: "Subject"), .init(name: "Status", type: "picklist"), .init(name: "LastModifiedDate", type: "datetime"),
        ])
        let o = SyncObject.generic(d)
        #expect(o.titleFields == ["WorkOrderNumber", "Subject"])
        #expect(o.subtitleFields == ["Status"])
        let r = o.record(from: ["Id": "0WO1", "WorkOrderNumber": "00000012", "Subject": "Replace pump", "Status": "New"])
        #expect(r?.title == "00000012 · Replace pump")
        // An object without LastModifiedDate isn't ordered or read incrementally.
        let bare = SyncObject.generic(SObjectDescribe(name: "Thing__c", label: "Thing", labelPlural: "Things", custom: true, queryable: true,
                                                      fields: [.init(name: "Id", type: "id"), .init(name: "Name", nameField: true)]))
        #expect(bare.soql(cap: 10, since: "2026-01-01T00:00:00Z") == "SELECT Id, Name FROM Thing__c LIMIT 10")
    }

    // MARK: Paging and caps

    @Test func pagesPast200AcrossThreePages() async throws {
        let org = try await connected { $0.rowOverrides["Account"] = MockSalesforce.generatedRows("Account", count: 4_500) }
        let report = try await org.client.syncIndex(org: org.key, instanceURL: org.instance) { _ in }
        let accounts = try #require(report.outcome(apiName: "Account"))
        #expect(accounts.synced == 4_500)
        #expect(accounts.pages == 3)
        #expect(accounts.capped == nil)
        #expect(report.records.filter { $0.kind == .account }.count == 4_500)
        #expect(Set(report.records.filter { $0.kind == .account }.map(\.id)).count == 4_500)
        let accountCalls = org.mock.dataRequests.filter { $0.contains("FROM Account") || $0.hasPrefix("GET /query/") }
        #expect(accountCalls.count == 3)
        #expect(accountCalls.dropFirst().allSatisfy { $0.hasPrefix("GET /query/01gMOCK") })
        #expect(report.logLines.contains("Accounts: 4500 (HTTP 200, totalSize 4500, 3 pages)"))
        // Newest first: generated rows are a minute apart, row 0 newest.
        #expect(report.records.first { $0.kind == .account }?.id == "GENACC000000000")
    }

    @Test func capStopsPagingEvenIfTheServerIgnoresLimit() async throws {
        let org = try await connected {
            $0.rowOverrides["Account"] = MockSalesforce.generatedRows("Account", count: 4_500)
            $0.ignoreLimit = true
        }
        let report = try await org.client.syncIndex(org: org.key, instanceURL: org.instance, plan: .builtIns(cap: 2_500)) { _ in }
        let accounts = try #require(report.outcome(apiName: "Account"))
        #expect(accounts.synced == 2_500)
        #expect(accounts.capped == 2_500)
        #expect(accounts.pages == 2) // 2,000 + 2,000 ≥ 2,500: the third page is never fetched
        #expect(report.logLines.contains { $0.hasPrefix("Accounts: 2500 (") && $0.contains("capped at 2500") })
    }

    @Test func capIsSentAsLimit() async throws {
        let org = try await connected { $0.rowOverrides["Case"] = MockSalesforce.generatedRows("Case", count: 3_000) }
        let report = try await org.client.syncIndex(org: org.key, instanceURL: org.instance, plan: .builtIns(cap: 2_100)) { _ in }
        #expect(report.outcome(apiName: "Case")?.synced == 2_100)
        #expect(org.mock.dataRequests.contains { $0.contains("FROM Case ORDER BY LastModifiedDate DESC LIMIT 2100") })
    }

    // MARK: Errors

    @Test func goneOrNonQueryableObjectsAreReportedAndSkipped() async throws {
        let org = try await connected {
            $0.nonQueryable = ["Invoice__c"]
            $0.queryErrors["Lead"] = QueryError(status: 400, errorCode: "INVALID_FIELD", message: "No such column 'Company' on entity 'Lead'")
        }
        let selection = ObjectSelection(enabled: ["Account", "Lead", "Invoice__c", "Gone__c"])
        let plan = try await org.client.plan(org: org.key, instanceURL: org.instance, selection: selection)
        #expect(plan.objects.map(\.name) == ["Account", "Lead"])
        let report = try await org.client.syncIndex(org: org.key, instanceURL: org.instance, plan: plan) { _ in }
        #expect((report.outcome(apiName: "Account")?.synced ?? 0) > 0)
        #expect(report.outcome(apiName: "Invoice__c")?.failure?.contains("can't be queried anymore") == true)
        #expect(report.outcome(apiName: "Gone__c")?.failure?.hasPrefix("this org doesn't have it") == true)
        #expect(report.outcome(apiName: "Lead")?.failure?.hasPrefix("Salesforce rejected Glassforce's query") == true)
        #expect(!report.records.contains { $0.objectName == "Lead" || $0.objectName == "Invoice__c" })
        let problem = try #require(report.problem)
        #expect(problem.contains("Leads") && problem.contains("Invoices") && problem.contains("Gone__c"))
    }

    // MARK: Incremental

    @Test func secondSyncReadsOnlyChangesAndMergesById() async throws {
        let org = try await connected { $0.rowOverrides["Account"] = MockSalesforce.generatedRows("Account", count: 2_300) }
        let t0 = Date(timeIntervalSince1970: 1_793_100_000)
        let first = try await org.client.syncIndex(org: org.key, instanceURL: org.instance, now: t0) { _ in }
        let entry = try #require(first.state.objects["Account"])
        #expect(entry.watermark == "2026-10-26T07:33:20Z")
        #expect(first.outcome(apiName: "Account")?.incremental == false)

        // One record renamed and one added after the first sync.
        var rows = MockSalesforce.generatedRows("Account", count: 2_300)
        rows[5]["Name"] = "Renamed Account"; rows[5]["LastModifiedDate"] = "2026-10-27T09:00:00.000+0000"
        rows.append(["Id": "001NEW", "Name": "Brand New Account", "LastModifiedDate": "2026-10-27T10:00:00.000+0000"])
        org.mock.rowOverrides["Account"] = rows

        let second = try await org.client.syncIndex(org: org.key, instanceURL: org.instance, previous: first.records,
                                                    state: first.state, now: t0.addingTimeInterval(3_600)) { _ in }
        let accounts = try #require(second.outcome(apiName: "Account"))
        #expect(accounts.incremental)
        #expect(accounts.synced == 2_301)
        #expect(org.mock.dataRequests.contains { $0.contains("FROM Account WHERE LastModifiedDate >= 2026-10-26T07:33:20Z") })
        let merged = second.records.filter { $0.objectName == "Account" }
        #expect(Set(merged.map(\.id)).count == 2_301)
        #expect(merged.contains { $0.id == "001NEW" })
        #expect(merged.first { $0.id == rows[5]["Id"] as? String }?.title == "Renamed Account")
        #expect(second.state.objects["Account"]?.watermark == "2026-10-27T10:00:00Z")
        #expect(second.state.objects["Account"]?.lastFullSync == t0)

        // A day later it reads everything again, which is how deletions drop out.
        org.mock.rowOverrides["Account"] = Array(rows.prefix(10))
        let third = try await org.client.syncIndex(org: org.key, instanceURL: org.instance, previous: second.records,
                                                   state: second.state, now: t0.addingTimeInterval(90_000)) { _ in }
        #expect(third.outcome(apiName: "Account")?.incremental == false)
        #expect(third.outcome(apiName: "Account")?.synced == 10)
    }

    @Test func changedQueryForcesAFullRead() async throws {
        let org = try await connected()
        let first = try await org.client.syncIndex(org: org.key, instanceURL: org.instance) { _ in }
        let second = try await org.client.syncIndex(org: org.key, instanceURL: org.instance, plan: .builtIns(cap: 1_000),
                                                    previous: first.records, state: first.state) { _ in }
        #expect(second.objects.filter { $0.status != nil }.allSatisfy { !$0.incremental })
    }

    @Test func watermarkLiteral() {
        #expect(SyncState.literal("2026-11-04T22:55:03.000+0000") == "2026-11-04T22:55:03Z")
        #expect(SyncState.literal("2026-11-04T22:55:03Z") == "2026-11-04T22:55:03Z")
        #expect(SyncState.literal("2026-11-04T22:55:03.000-0500") == nil)
        #expect(SyncState.literal("garbage") == nil)
        #expect(SyncState.literal(nil) == nil)
    }
}
