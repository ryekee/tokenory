// [INPUT]: 接收统计报告、筛选状态和记录详情。
// [OUTPUT]: 提供主窗口导航、统计加载与重试、日期与刷新工具栏、回合页和记录详情。
// [POS]: 主工作区入口；宽窗口并排检查明细，窄窗口使用详情面板。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

private enum DashboardSection: String, CaseIterable {
    case overview, details, turns, imports, sources
    var title: String { L("nav." + rawValue) }
    var icon: String { switch self { case .overview: "chart.bar.xaxis"; case .details: "list.bullet.rectangle"; case .turns: "stopwatch"; case .imports: "square.and.arrow.down"; case .sources: "externaldrive" } }
}
struct DashboardView: View {
    @Environment(UsageStore.self) private var store
    @State private var section: DashboardSection = .overview
    @Environment(\.colorScheme) private var scheme
    @State private var selectedRecordID: UsageDetail.ID?
    @State private var datePickerDraft: DateRangeDraft?
    @State private var visited: Set<DashboardSection> = [.overview]
    private var dashboardSelection: UsageFilter? {
        section == .overview || section == .details ? store.filter : nil
    }
    private var showsReportProgress: Bool {
        (section == .overview || section == .details) && store.report != nil && store.loading
    }
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
                if dashboardSelection == nil || store.connected || store.reportLoadError == nil {
                    ErrorBanner().padding(.horizontal, 20)
                }
                ZStack {
                    // Keep the overview mounted so navigation reuses chart layouts and scroll state.
                    VStack(spacing: 0) {
                        UsageFiltersView(showsSource: false)
                            .padding(.horizontal, 22).padding(.vertical, 14)
                        usageReport { report in OverviewView(report: report, isActive: section == .overview) }
                    }
                    .opacity(section == .overview ? 1 : 0)
                    .allowsHitTesting(section == .overview)
                    .disabled(section != .overview)
                    .accessibilityHidden(section != .overview)
                    if section == .imports { ImportView() }
                    if section == .turns || visited.contains(.turns) {
                        TurnsView(isActive: section == .turns)
                            .opacity(section == .turns ? 1 : 0)
                            .allowsHitTesting(section == .turns)
                            .disabled(section != .turns)
                            .accessibilityHidden(section != .turns)
                    }
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
                            usageReport { records($0) }
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
                        if section == .overview || section == .details || section == .turns {
                            UsageDatePicker(presentation: $datePickerDraft)
                        }
                        Button { store.scan() } label: {
                            Label {
                                Text(L("action.scan"))
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                                    .opacity(showsReportProgress ? 0 : 1)
                                    .overlay {
                                        if showsReportProgress { ProgressView().controlSize(.small).accessibilityHidden(true) }
                                    }
                            }
                        }
                        .accessibilityValue(showsReportProgress ? L("usage.loading_stats") : "")
                        .disabled(store.scanning || !store.connected)
                        if !store.connected && (dashboardSelection == nil || store.reportLoadError == nil) {
                            Button(L("action.reconnect")) { store.start() }
                        }
                    }
                }
        }
        .frame(minWidth: 800, minHeight: 560)
        .onChange(of: section) { _, next in
            visited.insert(next)
            if next != .details { selectedRecordID = nil }
        }
        .onChange(of: store.reportFilter) { _, _ in
            if let id = selectedRecordID, store.report?.details.contains(where: { $0.id == id }) != true {
                selectedRecordID = nil
            }
        }
        .onChange(of: dashboardSelection) { _, selection in
            if let selection { Task { await store.refreshSelection(selection) } }
        }
    }

    private func records(_ report: UsageReport) -> some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 936
            let selected = report.details.first { $0.id == selectedRecordID }
            HStack(spacing: 16) {
                RecordsView(
                    report: report,
                    isActive: section == .details,
                    selectedID: selected?.id,
                    compactColumns: wide && selected != nil,
                    openDetail: { selectedRecordID = $0.id },
                    openDatePicker: {
                        datePickerDraft = DateRangeDraft(filter: store.filter, selectedRange: store.dateRange)
                    }
                )
                if wide, let selected {
                    RecordDetailContent(detail: selected, closeInspector: { selectedRecordID = nil })
                        .frame(width: min(352, geometry.size.width - 632))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: WorkspaceStyle.panelRadius))
                }
            }
            .sheet(item: Binding(get: { wide ? nil : selected }, set: { if $0 == nil && !wide { selectedRecordID = nil } })) { detail in
                RecordDetailSheet(detail: detail)
            }
        }
        .padding(.horizontal, 22).padding(.bottom, 22)
    }

    @ViewBuilder
    private func usageReport<Content: View>(@ViewBuilder content: (UsageReport) -> Content) -> some View {
        if let report = store.report {
            if let error = store.reportLoadError {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("usage.report_failed"))
                        if let filter = store.reportFilter {
                            let range = filter.from.flatMap { from in filter.to.map { Localization.dateRange(from, $0) } }
                            Text(LF("usage.previous_report", range ?? L("range.all"))).foregroundStyle(.secondary)
                        }
                        DisclosureGroup(L("error.details")) { Text(error).textSelection(.enabled) }
                    }
                    Spacer()
                    reportRetryButton
                }
                .font(.callout)
                .padding(.horizontal, 22).padding(.bottom, 12)
            }
            content(report)
        } else if let error = store.reportLoadError {
            ContentUnavailableView {
                Label(L("usage.report_failed"), systemImage: "exclamationmark.circle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                reportRetryButton
            }
        } else {
            ProgressView(L("usage.loading_stats")).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var reportRetryButton: some View {
        Button(L("action.retry")) { Task { await store.retryReport() } }
    }
}

private struct RecordDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let detail: UsageDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RecordDetailContent(detail: detail).frame(maxHeight: 480)
            HStack { Spacer(); Button(L("action.done")) { dismiss() }.keyboardShortcut(.defaultAction) }
                .padding(.horizontal, 24).padding(.bottom, 24)
        }.frame(width: 600)
    }
}

private struct RecordDetailContent: View {
    @Environment(UsageStore.self) private var store
    let detail: UsageDetail
    var closeInspector: (() -> Void)? = nil
    @State private var price = ""
    @State private var snapshotError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                BrandLabel(name: detail.model, kind: .model, size: 22)
                    .font(.title2).lineLimit(1).truncationMode(.middle)
                    .help(detail.model).textSelection(.enabled)
                if let closeInspector {
                    Spacer(minLength: 8)
                    Button(action: closeInspector) {
                        Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(WorkspaceHoverStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L("record.close_details"))
                    .help(L("record.close_details"))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        row(L("field.date"), Localization.day(detail.date))
                        GridRow {
                            Text(L("field.tool_provider")).foregroundStyle(.secondary)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    toolLabel
                                    Text("/").foregroundStyle(.tertiary)
                                    providerLabel
                                }.fixedSize(horizontal: true, vertical: false)
                                VStack(alignment: .leading, spacing: 4) {
                                    toolLabel
                                    providerLabel
                                }
                            }
                        }
                        row(L("field.source"), detail.source)
                        tokenRow("token.input", detail.tokens.input)
                        tokenRow("token.output", detail.tokens.output)
                        tokenRow("token.cache_read", detail.tokens.cacheRead)
                        tokenRow("token.cache_write", detail.tokens.cacheWrite)
                        tokenRow("token.reasoning", detail.tokens.reasoning)
                        row(L("cost.estimate"), usd(detail.estimatedCostUsd))
                        row(L("field.source_cost"), detail.sourceCostUsd.map { usd($0) } ?? L("value.unavailable"))
                        if let session = detail.sessionId { row(L("field.session"), session) }
                        row(L("field.date_basis"), detail.timezone ?? L("value.unknown_timezone"))
                    }
                    if let basis = detail.costBasis { DisclosureGroup(L("cost.calculation")) { Text(basis).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) } }
                    if !price.isEmpty {
                        DisclosureGroup(L("price.snapshot")) {
                            ScrollView { Text(price).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                                .frame(maxHeight: 180)
                        }
                    } else if let snapshotError {
                        DisclosureGroup(L("record.snapshot_failed")) {
                            Text(snapshotError).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(closeInspector == nil ? 24 : 16)
        .disclosureGroupStyle(WorkspaceDisclosureStyle())
        .id(detail.id)
        .task(id: detail.priceSnapshotId) {
            price = ""
            snapshotError = nil
            guard let id = detail.priceSnapshotId else { return }
            do {
                let value = try await store.perform("priceSnapshot", payload: .object(["id": .string(id)]))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if !Task.isCancelled { price = String(decoding: try encoder.encode(value), as: UTF8.self) }
            } catch {
                if !Task.isCancelled { snapshotError = error.localizedDescription }
            }
        }
    }

    private var toolLabel: some View {
        BrandLabel(name: detail.client, kind: .tool, title: clientName(detail.client))
    }

    private var providerLabel: some View {
        BrandLabel(name: detail.provider, kind: .provider)
    }

    private func tokenRow(_ key: String, _ count: Int64) -> some View {
        row(L(key), count.formatted(.number.locale(Localization.locale)))
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
