import Foundation
import AppKit
import Observation
import GlassforceCore

@MainActor
@Observable
final class CommandBarModel {
    var query: String = "" {
        didSet { refresh() }
    }
    private(set) var results: [Record] = []
    private(set) var groups: [RecordGroup] = []
    var selectedIndex: Int = 0
    /// Badge for the org being searched; nil on fake data (milestone 1).
    var orgBadge: OrgBadge?
    /// Why the list may be empty: no org yet, first sync running, or a sync error.
    var status: PanelStatus = .ready
    /// Plain-words note when the last sync couldn't read some objects (e.g. "Couldn't sync Cases: …").
    var notice: String?
    /// Opens onboarding (Return on the "Connect a Salesforce org" state).
    var connectAction: (() -> Void)?
    /// Opens Settings; shared by ⌘, and the gear button so both behave the same.
    var settingsAction: (() -> Void)?
    func openSettings() { settingsAction?() }
    /// Bumped every time the panel is shown so the view re-focuses the search field.
    private(set) var focusRequest: Int = 0
    /// Cmd-K action menu for the selected record.
    var actionMenu = ActionMenuState()
    /// A parsed write that is shown and not sent until Confirm is clicked.
    var pendingWrite = PendingWrite()
    /// Org the staged write is bound to. Changing it drops any unsent change.
    var writeOrgID: String = "" {
        didSet {
            guard writeOrgID != oldValue else { return }
            pendingWrite.setOrg(writeOrgID)
            pendingWrite.stage(query: query, records: store.records)
        }
    }
    /// Invoked only with a confirmed diff. The app wires this to the mock or the signed-in org.
    var performWrite: (ConfirmedWrite) -> Void = { _ in }

    var preview: RecordPreview? {
        guard hasResults, let record = selectedRecord else { return nil }
        return RecordPreview.make(record)
    }

    private var hasResults: Bool { !results.isEmpty }

    /// Runs the highlighted Cmd-K item. Open and Copy Link only; nothing writes to Salesforce.
    func runMenuAction() {
        guard let record = selectedRecord else { return }
        guard let action = actionMenu.selected(in: CommandAction.menu(for: record)) else { return }
        switch action.kind {
        case .open: open(record)
        case .copyLink: copySelectedLink()
        }
        actionMenu.close()
    }

    private var store: RecordStore
    /// How often each record was opened from the panel (record id → count), so frequent picks rank higher.
    /// Ids only, never record contents. Kept in UserDefaults, capped to the 500 most recent ids.
    private var opens: [String: Int] = UserDefaults.standard.dictionary(forKey: "recordOpens") as? [String: Int] ?? [:]
    /// The panel renders at most this many rows; ranking puts the best ones first.
    static let resultLimit = 80

    init(store: RecordStore = RecordStore()) {
        self.store = store
        refresh()
    }

    var selectedRecord: Record? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    func moveSelection(by delta: Int) {
        selectedIndex = Selection.move(selectedIndex, by: delta, count: results.count)
        pendingWrite.noteSelection(selectedRecord?.id)
    }

    func record(id: String) -> Record? {
        store.records.first { $0.id == id }
    }

    /// Opens URLs in the default browser; swapped in tests. Click, Return and --open-first all use `open(_:)`.
    var opener = RecordOpener { url in Task { @MainActor in NSWorkspace.shared.open(url) } }
    /// Pasteboard write for Cmd-C. The string is the record link only.
    var copyText: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copies the selected record's Lightning link. Returns nil when there is nothing to copy.
    @discardableResult
    func copySelectedLink(fieldSelectionLength: Int = 0) -> String? {
        guard let text = CommandKeys.linkText(for: selectedRecord, fieldSelectionLength: fieldSelectionLength) else { return nil }
        copyText(text)
        return text
    }
    /// Hides the panel after an open (set by PanelController).
    var afterOpen: (() -> Void)?

    /// Open a result's Salesforce page and remember the pick for ranking.
    @discardableResult
    func open(_ record: Record) -> URL? {
        noteOpened(record)
        let url = opener.open(record)
        afterOpen?()
        return url
    }

    func requestFocus() { focusRequest &+= 1 }

    /// Remember an open so the record ranks a little higher next time.
    func noteOpened(_ record: Record) {
        opens[record.id, default: 0] += 1
        if opens.count > 500, let rarest = opens.min(by: { $0.value < $1.value })?.key { opens[rarest] = nil }
        UserDefaults.standard.set(opens, forKey: "recordOpens")
    }

    /// Swaps in a new search index (e.g. after an org sync) and re-runs the current query.
    func load(records: [Record]) {
        store = RecordStore(records: records)
        refresh()
    }

    /// Binds one deal from the ambiguous list. Does not write.
    func chooseWrite(recordID: String) {
        pendingWrite.choose(recordID: recordID, records: store.records)
    }

    /// Confirm is a click. Return does not call this. Ambiguous and no-op plans confirm to nil.
    func confirmWrite() {
        guard let write = pendingWrite.confirmed() else { return }
        performWrite(write)
        query = ""
    }

    func cancelWrite() {
        pendingWrite.cancel()
        query = ""
    }

    private func refresh() {
        results = store.search(query, limit: Self.resultLimit, boosts: opens)
        groups = RecordStore.grouped(results)
        selectedIndex = 0
        actionMenu.close()
        pendingWrite.stage(query: query, records: store.records)
    }
}
