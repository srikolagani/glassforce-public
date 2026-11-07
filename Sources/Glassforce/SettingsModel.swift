import Foundation
import Observation
import GlassforceCore

/// Settings › Search objects: the org's searchable objects (describeGlobal), which ones sync, and how each did.
@MainActor
@Observable
final class SettingsModel {
    enum CatalogState: Equatable { case idle, loading, loaded, failed(String) }

    struct Row: Identifiable, Equatable {
        var id: String { apiName }
        let apiName: String
        let label: String
        let custom: Bool
        /// Not from describeGlobal: Reports and Setup pages are always offered.
        let builtIn: Bool
        /// Picked earlier but missing from the org's current object list.
        let missing: Bool
    }

    let session: AppSession
    var filter = ""
    private(set) var catalog: [SObjectSummary] = []
    private(set) var catalogState: CatalogState = .idle
    private(set) var selection: ObjectSelection = .defaults
    private var resyncTask: Task<Void, Never>?
    private var loadedOrg: String?

    init(session: AppSession) { self.session = session }

    var org: OrgProfile? { session.directory.defaultOrg }
    private var orgID: String? { org.map { ObjectSelectionStore.orgID(fromKey: $0.id) } }
    private static func catalogFile(_ orgID: String) -> String { "catalog-\(orgID).json" }

    static let fixedRows = [
        Row(apiName: "Report", label: "Reports", custom: false, builtIn: true, missing: false),
        Row(apiName: ObjectSelection.setup, label: "Setup pages", custom: false, builtIn: true, missing: false),
    ]

    /// Every row, filtered by the search box: enabled first, then the rest, each alphabetical.
    var rows: (enabled: [Row], available: [Row]) {
        let known = Set(catalog.map(\.name))
        var all = Self.fixedRows + catalog.map { Row(apiName: $0.name, label: $0.label, custom: $0.custom, builtIn: false, missing: false) }
        if catalogState == .loaded {
            for name in selection.enabled where !known.contains(name) && !Self.fixedRows.contains(where: { $0.apiName == name }) {
                all.append(Row(apiName: name, label: name, custom: name.hasSuffix("__c"), builtIn: false, missing: true))
            }
        }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            all = all.filter { $0.label.lowercased().contains(needle) || $0.apiName.lowercased().contains(needle) }
        }
        let sorted = all.sorted { ($0.builtIn ? 1 : 0, $0.label.lowercased()) < ($1.builtIn ? 1 : 0, $1.label.lowercased()) }
        return (sorted.filter { selection.isEnabled($0.apiName) }, sorted.filter { !selection.isEnabled($0.apiName) })
    }

    var totalCount: Int { catalog.count + Self.fixedRows.count }
    var enabledCount: Int { selection.enabled.count }

    func isOn(_ name: String) -> Bool { selection.isEnabled(name) }

    /// Loads the saved selection and the cached object list instantly, then refreshes the list from the org (read-only).
    func load() async {
        guard let org, let orgID else { catalogState = .failed("Connect a Salesforce org first."); return }
        if loadedOrg != orgID {
            loadedOrg = orgID
            catalog = session.local.load([SObjectSummary].self, from: Self.catalogFile(orgID)) ?? []
        }
        selection = session.selections.load(orgID: orgID)
        catalogState = catalog.isEmpty ? .loading : .loaded
        do {
            let all = try await session.client.describeGlobal(org: org.id, instanceURL: org.instanceURL)
            catalog = ObjectCatalog.searchObjects(all)
            try? session.local.save(catalog, to: Self.catalogFile(orgID))
            catalogState = .loaded
            gfLog("Glassforce: settings: %@ lists %d objects; %d offered after filtering (plus Reports and Setup), %d enabled",
                  org.label, all.count, catalog.count, selection.enabled.count)
        } catch {
            gfLog("Glassforce: settings: object list failed: %@", error.localizedDescription)
            catalogState = catalog.isEmpty ? .failed("Couldn't load \(org.label)'s objects: \(AppSession.plainWords(error))") : .loaded
        }
    }

    func set(_ name: String, on: Bool) {
        guard let orgID else { return }
        selection.set(name, enabled: on)
        do { try session.selections.save(selection, orgID: orgID) } catch { gfLog("Glassforce: settings: couldn't save selection: %@", "\(error)") }
        gfLog("Glassforce: settings: %@ %@ (%d enabled)", on ? "enabled" : "disabled", name, selection.enabled.count)
        scheduleResync()
    }

    /// Toggles usually come in bursts; resync once they settle.
    private func scheduleResync() {
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, let org = self.org else { return }
            self.session.resync(org.id)
        }
    }

    func resyncNow() {
        guard let org else { return }
        resyncTask?.cancel()
        session.resync(org.id)
    }

    var isSyncing: Bool { org.map { session.syncingOrgs.contains($0.id) } ?? false }

    /// "62 synced", "capped at 50,000", or the plain-words failure for an object from the last sync.
    func detail(for name: String) -> (text: String, problem: Bool)? {
        guard let org, let outcome = session.lastReports[org.id]?.outcome(apiName: name), isOn(name) else { return nil }
        return SyncReport.settingsLine(synced: outcome.synced, failure: outcome.failure, capped: outcome.capped)
    }

    var footer: String {
        guard let org else { return "" }
        if isSyncing { return "Syncing \(org.label)…" }
        guard let sync = org.lastSync else { return "Not synced yet" }
        return "\(org.recordCount.formatted()) records · synced \(sync.formatted(date: .omitted, time: .shortened))"
    }
}
