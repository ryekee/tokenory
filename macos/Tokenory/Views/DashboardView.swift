// [INPUT]: 接收统计报告、筛选状态和记录详情。
// [OUTPUT]: 提供主窗口导航和可滚动的记录详情弹窗。
// [POS]: 主工作区入口；详情操作区独立于长内容滚动。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

private enum DashboardSection: String, CaseIterable {
    case overview, details, imports, sources
    var title: String { L("nav." + rawValue) }
    var icon: String { switch self { case .overview: "chart.bar.xaxis"; case .details: "list.bullet.rectangle"; case .imports: "square.and.arrow.down"; case .sources: "externaldrive" } }
}
struct DashboardView: View {
    @Environment(UsageStore.self) private var store
    @State private var section: DashboardSection = .overview
    @Environment(\.colorScheme) private var scheme
    @State private var selectedDetail: UsageDetail?
    @State private var visited: Set<DashboardSection> = [.overview]
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                WorkspaceTabs(items: DashboardSection.allCases.map { WorkspaceTab(id: $0, title: $0.title, icon: $0.icon) }, selection: $section)
                Spacer()
            }
                .navigationSplitViewColumnWidth(min: 145, ideal: 164, max: 200)
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 7) {
                        Circle().fill(store.connected ? Color.green : Color.orange).frame(width: 5, height: 5)
                        Text(store.statusText).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }.padding(16)
                }
        } detail: {
            VStack(spacing: 0) {
                ErrorBanner().padding(.horizontal, 20)
                ZStack {
                    // Keep the overview mounted so navigation reuses chart layouts and scroll state.
                    VStack(spacing: 0) {
                        UsageFiltersView(showsSource: false)
                            .padding(.horizontal, 22).padding(.vertical, 14)
                        if let report = store.report { OverviewView(report: report) }
                        else { ProgressView(L("usage.loading_stats")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                    .opacity(section == .overview ? 1 : 0)
                    .allowsHitTesting(section == .overview)
                    .disabled(section != .overview)
                    .accessibilityHidden(section != .overview)
                    if section == .imports { ImportView() }
                    if section == .sources || visited.contains(.sources) {
                        SourcesView()
                            .opacity(section == .sources ? 1 : 0)
                            .allowsHitTesting(section == .sources)
                            .disabled(section != .sources)
                            .accessibilityHidden(section != .sources)
                    }
                    if section == .details || visited.contains(.details) {
                        VStack(spacing: 0) {
                            UsageFiltersView(showsSource: true)
                                .padding(.horizontal, 22).padding(.vertical, 14)
                            if let report = store.report { RecordsView(report: report) { selectedDetail = $0 } }
                            else { ProgressView(L("usage.loading_stats")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        }
                        .opacity(section == .details ? 1 : 0)
                        .allowsHitTesting(section == .details)
                        .disabled(section != .details)
                        .accessibilityHidden(section != .details)
                    }
                }
            }.background(WorkspaceStyle.canvas(scheme)).navigationTitle(section.title)
                .toolbar {
                    ToolbarItemGroup {
                        if section == .overview || section == .details { UsageDatePicker() }
                        if store.loading { ProgressView().controlSize(.small) }
                        Button { store.scan() } label: { Label(L("action.scan"), systemImage: "arrow.clockwise") }.disabled(store.scanning || !store.connected)
                        if !store.connected { Button(L("action.reconnect")) { store.start() } }
                    }
                }
        }
        .frame(minWidth: 800, minHeight: 560)
        .onChange(of: section) { _, next in visited.insert(next) }
        .onChange(of: store.filter) { _, _ in Task { await store.refresh() } }
        .sheet(item: $selectedDetail) { detail in DetailSheet(detail: detail) }
    }
}

struct DetailSheet: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let detail: UsageDetail
    @State private var price = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BrandLabel(name: detail.model, kind: .model, size: 22).font(.title2).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        row(L("field.date"), Localization.day(detail.date))
                        GridRow {
                            Text(L("field.tool_provider")).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                BrandLabel(name: detail.client, kind: .tool, title: clientName(detail.client))
                                Text("/").foregroundStyle(.tertiary)
                                BrandLabel(name: detail.provider, kind: .provider)
                            }
                        }
                        row(L("field.source"), detail.source); row(L("token.input"), detail.tokens.input.formatted(.number.locale(Localization.locale))); row(L("token.output"), detail.tokens.output.formatted(.number.locale(Localization.locale))); row(L("token.cache_read"), detail.tokens.cacheRead.formatted(.number.locale(Localization.locale))); row(L("token.cache_write"), detail.tokens.cacheWrite.formatted(.number.locale(Localization.locale))); row(L("token.reasoning"), detail.tokens.reasoning.formatted(.number.locale(Localization.locale)))
                        row(L("cost.estimate"), usd(detail.estimatedCostUsd)); row(L("field.source_cost"), detail.sourceCostUsd.map { usd($0) } ?? L("value.unavailable"))
                        if let session = detail.sessionId { row(L("field.session"), session) }
                        row(L("field.date_basis"), detail.timezone ?? L("value.unknown_timezone"))
                    }
                    if let basis = detail.costBasis { DisclosureGroup(L("cost.calculation")) { Text(basis).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) } }
                    if !price.isEmpty { DisclosureGroup(L("price.snapshot")) { ScrollView { Text(price).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 180) } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 480)
            HStack { Spacer(); Button(L("action.done")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 600)
            .disclosureGroupStyle(WorkspaceDisclosureStyle())
            .task {
                guard let id = detail.priceSnapshotId else { return }
                do { let value = try await store.perform("priceSnapshot", payload: .object(["id": .string(id)])); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; price = String(decoding: try encoder.encode(value), as: UTF8.self) } catch { store.fail(error) }
            }
    }
    private func row(_ title: String, _ value: String) -> some View { GridRow { Text(title).foregroundStyle(.secondary); Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
}
