import SwiftUI

struct RecordsView: View {
    let report: UsageReport
    let openDetail: (UsageDetail) -> Void
    @Environment(UsageStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pageIndicator
    private var displayedFilter: UsageFilter { store.reportFilter ?? store.filter }
    private var page: Int { displayedFilter.offset / displayedFilter.limit }
    private var pageCount: Int { max(1, (Int(report.summary.recordCount) + displayedFilter.limit - 1) / displayedFilter.limit) }
    private var pageItems: [Int] {
        let candidates = Set([0, pageCount - 1, page - 1, page, page + 1].filter { $0 >= 0 && $0 < pageCount }).sorted()
        var result: [Int] = []
        for candidate in candidates {
            if let previous = result.last, candidate - previous > 1 { result.append(-1) }
            result.append(candidate)
        }
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LF("usage.record_count", report.summary.recordCount)).font(.headline)
                Spacer()
                Text(L("record.daily_note")).font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        columns {
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
                            ContentUnavailableView(L("usage.empty"), systemImage: "line.3.horizontal.decrease.circle")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollViewReader { scroll in
                                ScrollView(.vertical) {
                                    LazyVStack(spacing: 0) {
                                        Color.clear.frame(height: 0).id("top")
                                        ForEach(report.details) { detail in
                                            Button { openDetail(detail) } label: {
                                                columns {
                                                    Text(Localization.day(detail.date))
                                                    BrandLabel(name: detail.client, kind: .tool, title: clientName(detail.client))
                                                    BrandLabel(name: detail.model, kind: .model).fontWeight(.medium).help(detail.model)
                                                    Text(compactTokens(detail.total)).monospacedDigit()
                                                        .help(detail.total.formatted(.number.locale(Localization.locale)))
                                                    Text(usd(detail.estimatedCostUsd))
                                                        .monospacedDigit().help(usd(detail.estimatedCostUsd))
                                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                                                }
                                                .font(.callout).frame(height: 38).contentShape(Rectangle())
                                            }
                                            .buttonStyle(WorkspaceHoverStyle())
                                            .accessibilityElement(children: .combine)
                                            .accessibilityHint(L("action.record_details"))
                                            Divider().opacity(0.55).padding(.horizontal, 16)
                                        }
                                    }
                                }
                                .onChange(of: displayedFilter) { _, _ in scroll.scrollTo("top", anchor: .top) }
                            }
                        }
                    }.frame(width: max(650, geometry.size.width), height: geometry.size.height)
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { rangeLabel; Spacer(minLength: 8); pageSize; pageButtons }
                VStack(spacing: 10) {
                    HStack { rangeLabel; Spacer(); pageSize }
                    HStack { Spacer(); pageButtons }
                }
            }.padding(12)
        }
        .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 22).padding(.bottom, 22)
    }

    private func columns<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Group(subviews: content()) { columns in
                columns[0].frame(width: 108, alignment: .leading)
                columns[1].frame(width: 104, alignment: .leading)
                columns[2].frame(maxWidth: .infinity, alignment: .leading)
                columns[3].frame(width: 82, alignment: .trailing)
                columns[4].frame(width: 100, alignment: .trailing)
                columns[5].frame(width: 12)
            }
        }.lineLimit(1).truncationMode(.middle).padding(.horizontal, 16)
    }
    private var rangeLabel: some View {
        Text(LF("record.range", report.details.isEmpty ? 0 : displayedFilter.offset + 1,
                displayedFilter.offset + report.details.count, report.summary.recordCount))
            .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
    }
    private var pageSize: some View {
        Picker(L("pagination.page_size"), selection: Binding(
            get: { store.filter.limit },
            set: { value in
                var filter = store.filter; filter.limit = value; filter.offset = 0; store.filter = filter
            })) {
            ForEach([50, 100, 200], id: \.self) { Text(LF("pagination.per_page", $0)).tag($0) }
        }.labelsHidden().fixedSize().controlSize(.small).disabled(store.loading)
    }
    private var pageButtons: some View {
        HStack(spacing: 3) {
            pageArrow("chevron.left", title: L("action.previous"), destination: page - 1).disabled(page == 0 || store.loading)
            ForEach(Array(pageItems.enumerated()), id: \.offset) { _, number in
                if number == -1 {
                    Text("…").foregroundStyle(.secondary).frame(width: 20)
                } else {
                    Button { go(to: number) } label: {
                        Text("\(number + 1)").monospacedDigit()
                            .fontWeight(number == page ? .semibold : .regular)
                            .frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
                            .background {
                                if number == page {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15))
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: page)
    }
    private func pageArrow(_ icon: String, title: String, destination: Int) -> some View {
        Button { go(to: destination) } label: { Image(systemName: icon).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(WorkspaceHoverStyle()).help(title).accessibilityLabel(title)
    }
    private func go(to page: Int) { store.filter.offset = page * store.filter.limit }
}
