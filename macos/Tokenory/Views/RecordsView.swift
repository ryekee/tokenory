// [INPUT]: 当前日期范围的报表和明细操作。
// [OUTPUT]: 显示当前筛选的记录和合计，数据缩减时自动回到有效页。
// [POS]: 主工作区明细页；保留记录身份与分页。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct RecordsView: View {
    let report: UsageReport
    let isActive: Bool
    let selectedID: UsageDetail.ID?
    let compactColumns: Bool
    let openDetail: (UsageDetail) -> Void
    let openDatePicker: () -> Void
    @Environment(UsageStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pageIndicator

    private struct TableLayout {
        let date: CGFloat
        let tool: CGFloat
        let tokens: CGFloat
        let cost: CGFloat
        let spacing: CGFloat
        let inset: CGFloat
        let arrow: CGFloat = 12

        static let standard = Self(date: 108, tool: 104, tokens: 102, cost: 100, spacing: 12, inset: 16)
        static let compact = Self(date: 92, tool: 72, tokens: 96, cost: 84, spacing: 8, inset: 12)
    }
    private var displayedFilter: UsageFilter { store.reportFilter ?? store.reportSelection }
    private var hasDimensions: Bool {
        displayedFilter.client != nil || displayedFilter.provider != nil || displayedFilter.model != nil
            || displayedFilter.source != nil || displayedFilter.conversation != nil
    }
    private var page: Int { displayedFilter.offset / displayedFilter.limit }
    private var pageCount: Int { max(1, (Int(report.summary.recordCount) + displayedFilter.limit - 1) / displayedFilter.limit) }
    private var replacementPage: Int? {
        guard isActive, displayedFilter == store.reportSelection, !store.loading, page >= pageCount else { return nil }
        return pageCount - 1
    }
    enum PageItem: Hashable {
        case page(Int)
        case leadingEllipsis
        case trailingEllipsis

        static func make(page: Int, pageCount: Int) -> [Self] {
            let candidates = Set([0, pageCount - 1, page - 1, page, page + 1].filter { $0 >= 0 && $0 < pageCount }).sorted()
            var result: [Self] = []
            for candidate in candidates {
                if let previous = result.last, case .page(let prev) = previous, candidate - prev > 1 {
                    result.append(prev == 0 ? .leadingEllipsis : .trailingEllipsis)
                }
                result.append(.page(candidate))
            }
            return result
        }
    }

    private var pageItems: [PageItem] {
        PageItem.make(page: page, pageCount: pageCount)
    }
    var body: some View {
        let days = Set(report.details.map(\.date))
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let compact = compactColumns || geometry.size.width < 670
                let layout: TableLayout = compact ? .compact : .standard
                let dates = Dictionary(uniqueKeysWithValues: days.map { ($0, Localization.day($0, compact: compact)) })
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        reportHeader(layout)
                        Divider()
                        columns(layout) {
                            Text(L("field.date"))
                            Text(L("field.tool"))
                            Text(L("field.model"))
                            Text("Tokens")
                            Text(L("cost.estimate"))
                            Text("")
                        }
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .frame(height: 36).background(WorkspaceStyle.canvas(scheme).opacity(0.65))
                        Divider()
                        if report.details.isEmpty {
                            emptyRecords.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollViewReader { scroll in
                                ScrollView(.vertical) {
                                    LazyVStack(spacing: 0) {
                                        Color.clear.frame(height: 0).id("top")
                                        ForEach(report.details) { detail in
                                            Button { openDetail(detail) } label: {
                                                columns(layout) {
                                                    Text(dates[detail.date]!)
                                                    BrandLabel(name: detail.client, kind: .tool, title: clientName(detail.client))
                                                    HStack(spacing: 5) {
                                                        BrandLabel(name: detail.model, kind: .model).fontWeight(.medium)
                                                        if let mode = detail.inferenceSpeed, mode.isFast {
                                                            FastModeMark(helpText: mode.fastHelp)
                                                        }
                                                    }
                                                    Text(compactTokens(detail.total)).monospacedDigit()
                                                    Text(usd(detail.estimatedCostUsd))
                                                        .monospacedDigit()
                                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                                                }
                                                .font(.callout).frame(height: 38).contentShape(Rectangle())
                                                .background(selectedID == detail.id ? WorkspaceStyle.selection.opacity(0.12) : .clear)
                                            }
                                            .buttonStyle(WorkspaceHoverStyle())
                                            .accessibilityElement(children: .combine)
                                            .accessibilityHint(L("action.record_details"))
                                            .accessibilityAddTraits(selectedID == detail.id ? .isSelected : [])
                                            Divider().opacity(0.55).padding(.horizontal, 16)
                                        }
                                    }
                                }
                                .onChange(of: displayedFilter) { _, _ in scroll.scrollTo("top", anchor: .top) }
                            }
                        }
                    }.frame(width: max(550, geometry.size.width), height: geometry.size.height)
                }
            }
            if !report.details.isEmpty {
                Divider()
                Group {
                    if pageCount > 1 {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { rangeLabel; Spacer(minLength: 8); pageSize; pageButtons }
                            VStack(spacing: 10) {
                                HStack { rangeLabel; Spacer(); pageSize }
                                HStack { Spacer(); pageButtons }
                            }
                        }
                    } else {
                        HStack {
                            rangeLabel
                            Spacer()
                            if report.summary.recordCount > 50 { pageSize }
                        }
                    }
                }.padding(12)
            }
        }
        .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: replacementPage, initial: true) { _, page in
            if let page { go(to: page) }
        }
    }

    private func reportHeader(_ layout: TableLayout) -> some View {
        let summary = report.summary
        let range = isActive ? DashboardDateSpan(from: displayedFilter.from, to: displayedFilter.to) : nil
        let tokenTotal = summary.tokens.formatted(.number.locale(Localization.locale))
        let costTotal = usd(summary.knownEstimatedCostUsd)
        return HStack(spacing: layout.spacing) {
            DashboardRollingValue(text: LF("usage.record_count", summary.recordCount),
                                  value: Double(summary.recordCount),
                                  range: range,
                                  style: .headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if summary.recordCount > 0 {
                DashboardRollingValue(text: tokenTotal, value: Double(summary.tokens), range: range, style: .calloutMedium)
                    .accessibilityLabel(L("usage.tokens"))
                    .accessibilityValue(tokenTotal)
                    .frame(width: layout.tokens, alignment: .trailing)
                DashboardRollingValue(text: summary.knownEstimatedCostUsd == nil ? "—" : costTotal,
                                      value: summary.knownEstimatedCostUsd, range: range, style: .calloutMedium)
                    .accessibilityLabel(L(summary.costStatus == "partial" ? "cost.known" : "cost.estimate"))
                    .accessibilityValue(costTotal)
                    .frame(width: layout.cost, alignment: .trailing)
                Color.clear.frame(width: layout.arrow, height: 1).accessibilityHidden(true)
            }
        }
        .font(.callout.weight(.medium)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.8)
        .padding(.horizontal, layout.inset)
        .frame(height: 50)
    }

    @ViewBuilder private var emptyRecords: some View {
        let hasOtherPages = report.summary.recordCount > 0
        let title = hasOtherPages ? "record.empty_page" : hasDimensions ? "record.no_matches" : "usage.empty"
        if hasOtherPages && (replacementPage != nil || store.loading) {
            ProgressView().controlSize(.small).accessibilityLabel(L("usage.loading"))
        } else {
            ContentUnavailableView {
                Label(L(title), systemImage: hasDimensions ? "line.3.horizontal.decrease.circle" : "list.bullet.rectangle")
            } actions: {
                if displayedFilter == store.reportSelection && !store.loading {
                    if hasOtherPages {
                        Button(L("record.first_page")) { go(to: 0) }
                    } else if hasDimensions {
                        Button(L("record.clear_filters"), action: store.clearRecordFilters)
                    } else {
                        Button(L("record.change_dates"), action: openDatePicker)
                    }
                }
            }
        }
    }


    private func columns<Content: View>(_ layout: TableLayout, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: layout.spacing) {
            Group(subviews: content()) { columns in
                columns[0].frame(width: layout.date, alignment: .leading)
                columns[1].frame(width: layout.tool, alignment: .leading)
                columns[2].frame(maxWidth: .infinity, alignment: .leading)
                columns[3].frame(width: layout.tokens, alignment: .trailing)
                columns[4].frame(width: layout.cost, alignment: .trailing)
                columns[5].frame(width: layout.arrow)
            }
        }.lineLimit(1).truncationMode(.middle).padding(.horizontal, layout.inset)
    }
    private var rangeLabel: some View {
        Text(LF("record.range", report.details.isEmpty ? 0 : displayedFilter.offset + 1,
                displayedFilter.offset + report.details.count, report.summary.recordCount))
            .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
    }
    private var pageSize: some View {
        WorkspaceDropdown(
            label: L("pagination.page_size"),
            selection: Binding(
                get: { store.filter.limit },
                set: { value in
                    var filter = store.filter; filter.limit = value; filter.offset = 0; store.filter = filter
                }
            ),
            options: [50, 100, 200], width: 100, title: { LF("pagination.per_page", $0) }
        ).controlSize(.small).disabled(store.loading)
    }
    private var pageButtons: some View {
        HStack(spacing: 3) {
            pageArrow("chevron.left", title: L("action.previous"), destination: page - 1).disabled(page == 0 || store.loading)
            ForEach(pageItems, id: \.self) { item in
                switch item {
                case .leadingEllipsis, .trailingEllipsis:
                    Text("…").foregroundStyle(.secondary).frame(width: 20)
                case .page(let number):
                    Button { go(to: number) } label: {
                        Text("\(number + 1)").monospacedDigit()
                            .fontWeight(number == page ? .semibold : .regular)
                            .frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
                            .background {
                                if number == page {
                                    RoundedRectangle(cornerRadius: 6).fill(WorkspaceStyle.selection.opacity(0.15))
                                        .matchedGeometryEffect(id: "page", in: pageIndicator)
                                }
                            }
                    }.buttonStyle(WorkspaceHoverStyle()).disabled(store.loading)
                        .accessibilityLabel(LF("pagination.go_to", number + 1))
                        .accessibilityAddTraits(number == page ? [.isSelected] : [])
                }
            }
            pageArrow("chevron.right", title: L("action.next"), destination: page + 1).disabled(page == pageCount - 1 || store.loading)
        }.font(.callout).fixedSize()
            .animation(DashboardMotion.animation(DashboardMotion.pagination, reduceMotion: reduceMotion), value: page)
    }
    private func pageArrow(_ icon: String, title: String, destination: Int) -> some View {
        Button { go(to: destination) } label: { Image(systemName: icon).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(WorkspaceHoverStyle()).accessibilityLabel(title)
    }
    private func go(to page: Int) {
        guard (0..<pageCount).contains(page) else { return }
        let offset = page * store.filter.limit
        if store.filter.offset != offset { store.filter.offset = offset }
    }
}
