import SwiftUI
import GlassforceCore

/// Settings › Search objects. Neutral Liquid Glass, same family as the search bar: glass search capsule,
/// one glass card holding the list, system switches.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    searchField
                    Button { model.resyncNow() } label: {
                        Label("Resync", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .disabled(model.org == nil || model.isSyncing)
                }
            }
            list
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 18)
        .frame(minWidth: 560, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Search objects").font(.system(size: 22, weight: .semibold))
                Text(model.org.map { "Pick what Glassforce syncs from \($0.label). Changes resync on their own." }
                     ?? "Connect a Salesforce org to pick what it searches.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if let org = model.org {
                OrgBadgeView(badge: OrgBadge(title: "\(org.kind.badgeTitle) · \(org.label)", color: org.kind.badgeColor))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter objects", text: $model.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !model.filter.isEmpty {
                Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassEffect(.regular, in: Capsule())
    }

    @ViewBuilder private var list: some View {
        let rows = model.rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch model.catalogState {
                case .failed(let message):
                    message_(message, symbol: "exclamationmark.triangle.fill", tint: .orange)
                case .loading where model.catalog.isEmpty:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading objects…").foregroundStyle(.secondary) }
                        .padding(16)
                default:
                    EmptyView()
                }
                if !rows.enabled.isEmpty {
                    sectionHeader("Searching", count: rows.enabled.count)
                    ForEach(rows.enabled) { ObjectRow(model: model, row: $0) }
                }
                if !rows.available.isEmpty {
                    sectionHeader("More objects in this org", count: rows.available.count)
                    ForEach(rows.available) { ObjectRow(model: model, row: $0) }
                }
                if rows.enabled.isEmpty && rows.available.isEmpty && model.catalogState == .loaded {
                    Text("No objects match “\(model.filter)”.").font(.system(size: 13)).foregroundStyle(.secondary).padding(16)
                }
            }
            .padding(8)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func message_(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if model.isSyncing { ProgressView().controlSize(.mini) }
            Text(model.footer).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text("\(model.enabledCount) of \(model.totalCount) on").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct ObjectRow: View {
    let model: SettingsModel
    let row: SettingsModel.Row

    var body: some View {
        let kind = ObjectIcon.kind(for: row.apiName)
        HStack(spacing: 10) {
            IconTile(kind: kind, symbol: ObjectIcon.symbol(for: row.apiName, kind: kind))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if row.custom { pill("Custom") }
                    if row.builtIn { pill("Built in") }
                }
                Text(row.builtIn ? (row.apiName == "Report" ? "Report" : "Users, Permission Sets, Flows, Object Manager") : row.apiName)
                    .font(.system(size: 11, design: row.builtIn ? .default : .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if row.missing {
                Text("Not in this org's object list anymore").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            } else if let detail = model.detail(for: row.apiName) {
                Text(detail.text)
                    .font(.system(size: 11))
                    .foregroundStyle(detail.problem ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            Toggle("", isOn: Binding(get: { model.isOn(row.apiName) }, set: { model.set(row.apiName, on: $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.07), in: Capsule())
    }
}
