import SwiftUI
import Observation
import GlassforceCore

/// Spotlight-style metrics (macOS 26): one glass capsule that grows into a results panel.
private enum Metrics {
    static let width: CGFloat = 680
    static let barHeight: CGFloat = 56
    static let corner: CGFloat = 28            // capsule when collapsed, soft rect when expanded
    static let rowHeight: CGFloat = 38
    static let headerHeight: CGFloat = 28
    static let listInset: CGFloat = 8
    static let maxListHeight: CGFloat = 380
    static let noResultsHeight: CGFloat = 64
}

struct CommandBarView: View {
    @Bindable var model: CommandBarModel
    @FocusState private var searchFocused: Bool
    private let gearHover = HoverState()

    private var hasQuery: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if let diff = model.pendingWrite.diff {
                Divider().padding(.horizontal, 14)
                writeCard(diff)
            } else if model.pendingWrite.refusal != nil || !model.pendingWrite.choices.isEmpty {
                Divider().padding(.horizontal, 14)
                writeChoices(model.pendingWrite.refusal, choices: model.pendingWrite.choices)
            } else if model.status != .ready && model.results.isEmpty {
                Divider().padding(.horizontal, 14)
                statusView
            } else if hasQuery {
                Divider().padding(.horizontal, 14)
                if model.results.isEmpty { noResults } else { resultsList }
                if let preview = model.preview { previewBar(preview) }
                if model.actionMenu.isOpen, let record = model.selectedRecord { actionMenu(record) }
                if let notice = model.notice { noticeView(notice) }
            }
        }
        .frame(width: Metrics.width)
        // Neutral system Liquid Glass, no tint: the same material Spotlight uses.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .animation(.smooth(duration: 0.22), value: hasQuery)
        .animation(.smooth(duration: 0.18), value: model.results.count)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { searchFocused = true }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 40)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .help("Drag to move Glassforce")

            TextField("Search Salesforce", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($searchFocused)

            if let badge = model.orgBadge {
                OrgBadgeView(badge: badge)
            }
            SettingsGearButton(hover: gearHover) { model.openSettings() }
        }
        .padding(.horizontal, 18)
        .frame(height: Metrics.barHeight)
    }

    // MARK: Results

    private var listHeight: CGFloat {
        let content = CGFloat(model.results.count) * Metrics.rowHeight
            + CGFloat(model.groups.count) * Metrics.headerHeight
            + Metrics.listInset * 2
        return min(content, Metrics.maxListHeight)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups) { group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: Metrics.headerHeight, alignment: .bottom)

                        ForEach(group.records) { record in
                            let index = model.results.firstIndex(of: record) ?? 0
                            ResultRow(record: record, isSelected: index == model.selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedIndex = index; model.open(record) }
                                .id(record.id)
                        }
                    }
                }
                .padding(Metrics.listInset)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight)
            .onChange(of: model.selectedIndex) { _, _ in
                if let id = model.selectedRecord?.id { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        HStack(spacing: 12) {
            switch model.status {
            case .noOrg:
                Image(systemName: "link.badge.plus").font(.system(size: 20)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect a Salesforce org").font(.system(size: 14, weight: .semibold))
                    Text("Press Return to sign in to Production, Sandbox or your My Domain.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect") { model.connectAction?() }.buttonStyle(.glassProminent)
            case .syncing(let org):
                ProgressView().controlSize(.small)
                Text("Syncing \(org)…").font(.system(size: 14, weight: .medium))
                Spacer()
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange)
                Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reconnect") { model.connectAction?() }.buttonStyle(.glass)
            case .ready:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func noticeView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func writeChoices(_ refusal: String?, choices: [WriteChoice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let refusal {
                Text(refusal)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(choices, id: \.recordID) { choice in
                Button {
                    model.chooseWrite(recordID: choice.recordID)
                } label: {
                    HStack(spacing: 8) {
                        Text(choice.recordTitle)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(choice.before)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            Button("Cancel", action: model.cancelWrite)
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func writeCard(_ diff: WriteDiff) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(diff.recordTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(diff.fieldLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Text(diff.before)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("→")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Text(diff.after)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            HStack(spacing: 16) {
                Button("Cancel", action: model.cancelWrite)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Confirm")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(Color.accentColor))
                    .contentShape(Capsule())
                    .onTapGesture { model.confirmWrite() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func previewBar(_ preview: RecordPreview) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preview.typeName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(preview.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            if !preview.subtitle.isEmpty {
                Text(preview.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let host = preview.host {
                Text(host)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func actionMenu(_ record: Record) -> some View {
        let actions = CommandAction.menu(for: record)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let selected = index == model.actionMenu.index
                HStack(spacing: 12) {
                    Text(action.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                    Spacer(minLength: 8)
                    Text(action.shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor)
                    }
                }
            }
        }
        .padding(8)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var noResults: some View {
        Text("No Results")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.noResultsHeight)
    }
}

// MARK: Row

private struct ResultRow: View {
    let record: Record
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            IconTile(kind: record.kind, symbol: ObjectIcon.symbol(for: record.objectName, kind: record.kind))

            Text(record.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .lineLimit(1)
                .layoutPriority(1)

            Text(record.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(record.typeLabel)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.rowHeight)
        .background {
            if isSelected {
                // The system accent colour, exactly like Spotlight's selection.
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor)
            }
        }
    }
}

struct IconTile: View {
    let kind: RecordKind
    var symbol: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(kind.tint.gradient)
            .frame(width: 24, height: 24)
            .overlay {
                Image(systemName: symbol ?? kind.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// Quiet org chip in the command bar: sentence-case, tiny dot, low-opacity capsule.
struct OrgBadgeView: View {
    let badge: OrgBadge

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(badge.color.opacity(0.85))
                .frame(width: 6, height: 6)
            Text(badge.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(badge.color.opacity(0.10), in: Capsule())
    }
}

/// What the search bar shows about the org being searched.
struct OrgBadge: Equatable {
    var title: String
    var color: Color
}

extension RecordKind {
    var tint: Color {
        switch self {
        case .account: Color(red: 0.37, green: 0.36, blue: 0.90)
        case .contact: Color(red: 0.62, green: 0.33, blue: 0.86)
        case .opportunity: Color(red: 0.98, green: 0.58, blue: 0.20)
        case .supportCase: Color(red: 0.93, green: 0.30, blue: 0.45)
        case .other: Color(red: 0.20, green: 0.56, blue: 0.86)
        case .report: Color(red: 0.13, green: 0.68, blue: 0.62)
        case .setup: Color(red: 0.45, green: 0.50, blue: 0.58)
        }
    }
}

/// Row icons for objects without a built-in kind: a few well-known standard objects, a generic cube for custom ones.
enum ObjectIcon {
    static func symbol(for object: String?, kind: RecordKind) -> String {
        guard kind == .other, let object else { return kind.symbolName }
        switch object {
        case "Lead": return "person.crop.circle.badge.plus"
        case "Campaign": return "megaphone.fill"
        case "Product2": return "shippingbox.fill"
        case "Contract": return "doc.text.fill"
        case "Order": return "cart.fill"
        case "User": return "person.crop.square.fill"
        case "Task": return "checklist"
        case "Event": return "calendar"
        default: return object.hasSuffix("__c") ? "cube.fill" : kind.symbolName
        }
    }

    static func kind(for object: String) -> RecordKind {
        switch object {
        case "Account": .account
        case "Contact": .contact
        case "Opportunity": .opportunity
        case "Case": .supportCase
        case "Report": .report
        case ObjectSelection.setup: .setup
        default: .other
        }
    }
}


/// Quiet gear next to the org badge; brightens on hover. Never takes focus from the search field.
private struct SettingsGearButton: View {
    let hover: HoverState
    let action: () -> Void
    private var hovering: Bool { hover.isHovering }

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover.isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
    }
}

/// Hover flag held outside `@State` (the Command Line Tools lack the SwiftUIMacros plugin).
@MainActor @Observable final class HoverState { var isHovering = false }
