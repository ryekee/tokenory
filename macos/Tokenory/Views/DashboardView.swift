// [INPUT]: 接收统计报告、筛选状态和记录详情。
// [OUTPUT]: 提供主窗口导航、侧栏设置入口、统计加载和错误卡片、日期工具栏、回合页和记录详情。
// [POS]: 主工作区入口；宽窗口并排检查明细，窄窗口使用详情面板。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

private enum DashboardSection: String, CaseIterable {
    case overview, details, turns
    var title: String { L("nav." + rawValue) }
    var icon: String { switch self { case .overview: "chart.bar.xaxis"; case .details: "list.bullet.rectangle"; case .turns: "stopwatch" } }
}
struct DashboardView: View {
    private struct ReportProgress {
        let firstLoad: Bool
        let shownAt: ContinuousClock.Instant
    }

    @Environment(UsageStore.self) private var store
    @State private var section: DashboardSection = .overview
    @AppStorage("overviewLocalOnly") private var overviewLocalOnly = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedRecordID: UsageDetail.ID?
    @State private var datePickerDraft: DateRangeDraft?
    @State private var visited: Set<DashboardSection> = [.overview]
    @State private var progress: ReportProgress?
    private var hasVisibleReport: Bool {
        store.report != nil && (section != .overview || store.reportFilter?.conversation == nil)
    }
    private var dashboardSelection: UsageFilter? {
        section == .overview || section == .details ? store.reportSelection : nil
    }
    private var reportIsPending: Bool {
        dashboardSelection != nil && store.reportLoadError == nil && (!hasVisibleReport || store.loading)
    }
    private var showsScanProgress: Bool { store.scanRequested || showsReportProgress }

    private var showsReportProgress: Bool {
        dashboardSelection != nil && progress?.firstLoad == false && store.reportLoadError == nil
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
                            .animation(DashboardMotion.animation(DashboardMotion.state, reduceMotion: reduceMotion), value: store.connected)
                        Text(store.statusText).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        SettingsLink {
                            Image(systemName: "gearshape")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(WorkspaceHoverStyle())
                        .accessibilityLabel(L("settings.title"))
                    }.padding(16)
                }
        } detail: {
            VStack(spacing: 0) {
                let showsErrorBanner = store.error != nil && (dashboardSelection == nil || store.connected || store.reportLoadError == nil)
                if showsErrorBanner {
                    ErrorBanner().padding(.horizontal, 22).padding(.top, 12)
                        .transition(.opacity)
                }
                ZStack {
                    // Keep the overview mounted so navigation reuses chart layouts and scroll state.
                    VStack(spacing: 0) {
                        UsageFiltersView(showsSource: false, localOnly: overviewLocalOnly)
                            .padding(.horizontal, 22).padding(.vertical, 14)
                        usageReport(allowConversationReport: false) { report in
                            OverviewView(report: report, localOnly: overviewLocalOnly, isActive: section == .overview, openDatePicker: openDatePicker)
                                #if CLOUD_DEVELOPMENT
                                .onAppear {
                                    if ProcessInfo.processInfo.arguments.contains("--cloud-sync-receipt") {
                                        FileHandle.standardError.write(Data("TOKENORY_OVERVIEW_READY \(Date().timeIntervalSince1970)\n".utf8))
                                    }
                                }
                                #endif
                        }
                    }
                    .opacity(section == .overview ? 1 : 0)
                    .allowsHitTesting(section == .overview)
                    .disabled(section != .overview)
                    .accessibilityHidden(section != .overview)
                    if section == .turns || visited.contains(.turns) {
                        TurnsView(isActive: section == .turns, openDatePicker: openDatePicker)
                            .opacity(section == .turns ? 1 : 0)
                            .allowsHitTesting(section == .turns)
                            .disabled(section != .turns)
                            .accessibilityHidden(section != .turns)
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
            }
            .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion),
                       value: store.error != nil && (dashboardSelection == nil || store.connected || store.reportLoadError == nil))
            .background(WorkspaceStyle.canvas(scheme)).navigationTitle(section.title)
                .toolbar {
                    ToolbarItemGroup {
                        if section == .overview && (overviewLocalOnly || !store.cloud.sources.isEmpty) {
                            OverviewLocalToggle(localOnly: $overviewLocalOnly).fixedSize()
                        }
                        if section == .overview || section == .details || section == .turns {
                            UsageDatePicker(presentation: $datePickerDraft)
                        }
                        Button { store.scan() } label: {
                            Label {
                                Text(L("action.scan"))
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                                    .opacity(showsScanProgress ? 0 : 1)
                                    .overlay {
                                        if showsScanProgress { ProgressView().controlSize(.small).accessibilityHidden(true) }
                                    }
                            }
                        }
                        .accessibilityValue(store.scanInProgress ? L("status.scanning") : (showsReportProgress ? L("usage.loading_stats") : ""))
                        .disabled(store.scanInProgress || !store.connected)
                        if !store.connected && store.errorAction != .reconnect && (dashboardSelection == nil || store.reportLoadError == nil) {
                            Button(L("action.reconnect")) { store.start() }
                        }
                    }
                }
        }
        .tint(WorkspaceStyle.selection)
        .frame(minWidth: 800, minHeight: 560)
        .task(id: reportIsPending) {
            let clock = ContinuousClock()
            do {
                if reportIsPending {
                    guard progress == nil else { return }
                    try await clock.sleep(for: .milliseconds(300))
                    progress = ReportProgress(firstLoad: !hasVisibleReport, shownAt: clock.now)
                } else if let progress {
                    try await clock.sleep(until: progress.shownAt.advanced(by: .milliseconds(500)))
                    self.progress = nil
                }
            } catch { /* A new loading state replaced this timer. */ }
        }
        .onChange(of: section, initial: true) { _, next in
            store.recordsAreActive = next == .details
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
                    openDetail: { detail in
                        let next = wide && selectedRecordID == detail.id ? nil : detail.id
                        if wide {
                            DashboardMotion.withAnimation(DashboardMotion.panel, reduceMotion: reduceMotion) {
                                selectedRecordID = next
                            }
                        } else {
                            selectedRecordID = next
                        }
                    },
                    openDatePicker: openDatePicker
                )
                if wide, let selected {
                    RecordDetailContent(detail: selected, closeInspector: {
                        DashboardMotion.withAnimation(DashboardMotion.panel, reduceMotion: reduceMotion) {
                            selectedRecordID = nil
                        }
                    })
                        .frame(width: min(352, geometry.size.width - 632))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: WorkspaceStyle.panelRadius))
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .clipped()
            .sheet(item: Binding(get: { wide ? nil : selected }, set: { if $0 == nil && !wide { selectedRecordID = nil } })) { detail in
                RecordDetailSheet(detail: detail)
            }
        }
        .padding(.horizontal, 22).padding(.bottom, 22)
    }

    private func openDatePicker() {
        datePickerDraft = DateRangeDraft(filter: store.filter, selectedRange: store.dateRange)
    }

    private enum ReportPhase: Equatable {
        case loading, content, error, empty
    }

    private func reportPhase(allowConversationReport: Bool) -> ReportPhase {
        if progress?.firstLoad == true, store.reportLoadError == nil { return .loading }
        if store.report != nil, allowConversationReport || store.reportFilter?.conversation == nil { return .content }
        if store.reportLoadError != nil { return .error }
        return .empty
    }

    @ViewBuilder
    private func usageReport<Content: View>(
        allowConversationReport: Bool = true,
        @ViewBuilder content: (UsageReport) -> Content
    ) -> some View {
        let phase = reportPhase(allowConversationReport: allowConversationReport)
        VStack(spacing: 0) {
            if progress?.firstLoad == true, store.reportLoadError == nil {
                if allowConversationReport {
                    ProgressView(L("usage.loading_stats")).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    OverviewLoadingPlaceholder()
                        .transition(.opacity)
                }
            } else if let report = store.report, allowConversationReport || store.reportFilter?.conversation == nil {
                if let error = store.reportLoadError {
                    let note = store.reportFilter.map { filter in
                        let range = filter.from.flatMap { from in filter.to.map { Localization.dateRange(from, $0) } }
                        return LF("usage.previous_report", range ?? L("range.all"))
                    }
                    WorkspacePanel(surface: WorkspaceStyle.warningSurface) {
                        WorkspaceErrorMessage(title: L("usage.report_failed"), note: note, detail: error) {
                            reportRetryButton
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 12)
                    .transition(.opacity)
                }
                content(report)
                    .transition(.opacity)
            } else if let error = store.reportLoadError {
                ScrollView {
                    WorkspacePanel(surface: WorkspaceStyle.warningSurface) {
                        WorkspaceErrorMessage(title: L("usage.report_failed"), detail: error) {
                            reportRetryButton
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 22)
                }
                .transition(.opacity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(DashboardMotion.animation(DashboardMotion.load, reduceMotion: reduceMotion), value: phase)
        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: store.reportLoadError != nil)
    }

    private var reportRetryButton: some View {
        Button(L("action.retry")) { Task { await store.retryReport() } }
    }
}

private struct OverviewLoadingPlaceholder: View {
    var body: some View {
        VStack(spacing: 0) {
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        metric("Tokens", value: "000.00", primary: true)
                        metric(L("cost.estimate"), value: "$0,000.00", primary: true)
                        metric(L("overview.models"), value: "00", primary: false)
                    }
                    Capsule().fill(.quaternary).frame(height: 5)
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("usage.trend")).font(.headline)
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(height: 210)
                    }
                }
                .redacted(reason: .placeholder)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("usage.loading_stats"))
    }

    private func metric(_ label: String, value: String, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption)
            Text(value).font(DisplayNumberFont.font(size: primary ? 32 : 23))
        }.frame(maxWidth: primary ? .infinity : nil, alignment: .leading)
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
                    .textSelection(.enabled)
                if let mode = detail.inferenceSpeed, mode.isFast {
                    FastModeMark(title: L("fast.title"), helpText: mode.fastHelp)
                        .padding(.top, 4)
                }
                if let closeInspector {
                    Spacer(minLength: 8)
                    Button(action: closeInspector) {
                        Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(WorkspaceHoverStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L("record.close_details"))
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
                        WorkspaceErrorMessage(title: L("record.snapshot_failed"), detail: snapshotError) {}
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
