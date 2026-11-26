// [INPUT]: 接收导航项、选项、说明、错误信息和折叠内容。
// [OUTPUT]: 统一总览卡片标题、下拉选择和搜索，以及设置、导航、悬停、折叠和错误反馈。
// [POS]: 共享控件保持同一前缘。设置操作和下拉使用系统失焦颜色，保留原生交互反馈。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI

struct OverviewCardTitle: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkspaceStyle.selection)
                .frame(width: 22, height: 22)
                .background(WorkspaceStyle.selection.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(WorkspaceStyle.selection.opacity(0.32), lineWidth: 1)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).foregroundStyle(WorkspaceStyle.text)
                    .frame(minHeight: 22, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                }
            }
        }
    }
}

struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
    }
}

extension View {
    func settingsActionForeground() -> some View {
        modifier(SettingsActionForeground())
    }
}

private struct SettingsActionForeground: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.foregroundColor(appearsActive ? nil : Color(nsColor: .disabledControlTextColor))
    }
}

struct WorkspaceInfoPopover<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(showing ? WorkspaceStyle.selection : Color.secondary)
                .animation(DashboardMotion.animation(DashboardMotion.state, reduceMotion: reduceMotion), value: showing)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceHoverStyle())
        .accessibilityLabel(title)
        .popover(isPresented: $showing, arrowEdge: .bottom) { content }
    }
}

extension EnvironmentValues {
    @Entry var dropdownLabelColor: Color? = nil
}

struct WorkspaceDropdownTrigger: View {
    @Environment(\.dropdownLabelColor) private var labelColor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appearsActive) private var appearsActive
    private static let labelSpacing: CGFloat = 8
    private static let chevronSize: CGFloat = 9

    let label: String
    let value: String
    let width: CGFloat
    var brand: (name: String, kind: BrandKind)? = nil
    var flexibleWidth = false
    let action: () -> Void

    private var effectiveLabelColor: Color? {
        guard appearsActive else { return Color(nsColor: .disabledControlTextColor) }
        guard scheme == .dark else { return labelColor }
        return WorkspaceStyle.darkDropdownLabel.opacity(isEnabled ? 1 : 0.5)
    }

    static func fittingWidth(for titles: [String], includesChevron: Bool = true) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textWidth = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        guard includesChevron else { return ceil(textWidth) }
        let symbol = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: chevronSize, weight: .semibold))
        return ceil(textWidth + labelSpacing + (symbol?.size.width ?? chevronSize))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Self.labelSpacing) {
                if let brand { BrandIcon(name: brand.name, kind: brand.kind) }
                Text(value)
                    .foregroundColor(effectiveLabelColor)
                    .lineLimit(1).truncationMode(.tail)
                    .minimumScaleFactor(flexibleWidth ? 0.9 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: Self.chevronSize, weight: .semibold))
                    .foregroundStyle(effectiveLabelColor?.opacity(0.78) ?? Color.secondary)
            }.frame(minWidth: flexibleWidth ? 0 : width, idealWidth: width, maxWidth: width)
                .foregroundColor(appearsActive ? nil : Color(nsColor: .disabledControlTextColor))
        }
        .buttonStyle(.bordered)
        .background {
            if scheme == .dark {
                RoundedRectangle(cornerRadius: 6).fill(WorkspaceStyle.darkDropdownUnderlay)
            }
        }
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

struct WorkspaceDropdownSearchField: View {
    let prompt: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus).onSubmit(submit)
            if !text.isEmpty {
                Button {
                    text = ""
                    focus.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(WorkspaceHoverStyle())
                .accessibilityLabel(L("turns.clear_search"))
            }
        }.padding(14)
    }
}

struct WorkspaceDropdownRow<Content: View>: View {
    let selected: Bool
    var focused: Bool = false
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .foregroundStyle(WorkspaceStyle.selection)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if selected || focused {
                    RoundedRectangle(cornerRadius: WorkspaceStyle.fieldRadius)
                        .fill(WorkspaceStyle.selection.opacity(focused ? 0.16 : 0.1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceHoverStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WorkspaceDropdown<Value: Hashable>: View {
    struct Search {
        let prompt: String
        let noResults: String
        let clearValue: Value
    }

    let label: String
    @Binding var selection: Value
    let options: [Value]
    let width: CGFloat
    var popoverWidth: CGFloat? = nil
    var search: Search? = nil
    var flexibleWidth = false
    let title: (Value) -> String
    var brand: (Value) -> (name: String, kind: BrandKind)? = { _ in nil }

    @State private var showing = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedOption: Value?

    var body: some View {
        WorkspaceDropdownTrigger(
            label: label, value: title(selection), width: width, brand: brand(selection), flexibleWidth: flexibleWidth
        ) {
            query = ""
            showing = true
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            let matches = matchedOptions
            let displayed = search.map { [$0.clearValue] + matches } ?? matches
            VStack(spacing: 0) {
                if let search {
                    WorkspaceDropdownSearchField(prompt: search.prompt, text: $query, focus: $searchFocused) {
                        if let first = matches.first { select(first) }
                    }
                    Divider()
                }
                ScrollViewReader { proxy in
                    if displayed.count > 8 {
                        ScrollView { rows(displayed, noResults: matches.isEmpty ? search?.noResults : nil) }
                            .frame(height: 290)
                            .onChange(of: focusedOption) { _, value in
                                if let value { proxy.scrollTo(value) }
                            }
                            .onAppear { if search == nil { proxy.scrollTo(selection) } }
                    } else {
                        rows(displayed, noResults: matches.isEmpty ? search?.noResults : nil)
                    }
                }
            }
            .frame(width: popoverWidth ?? max(200, width + 24))
            .onAppear {
                if search != nil { searchFocused = true }
                else { focusedOption = displayed.contains(selection) ? selection : displayed.first }
            }
            .onMoveCommand { direction in
                guard !displayed.isEmpty, direction == .up || direction == .down else { return }
                let step = direction == .up ? -1 : 1
                let index = focusedOption.flatMap { displayed.firstIndex(of: $0) } ?? (step > 0 ? -1 : displayed.count)
                focusedOption = displayed[min(max(index + step, 0), displayed.count - 1)]
            }
        }
    }

    private var matchedOptions: [Value] {
        guard let search else { return options }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.filter { value in
            value != search.clearValue && (query.isEmpty || title(value).localizedCaseInsensitiveContains(query))
        }
    }

    private func rows(_ displayed: [Value], noResults: String?) -> some View {
        VStack(spacing: 2) {
            ForEach(displayed, id: \.self) { option in
                WorkspaceDropdownRow(selected: selection == option, focused: focusedOption == option, action: { select(option) }) {
                    if let icon = brand(option) { BrandIcon(name: icon.name, kind: icon.kind) }
                    Text(title(option)).lineLimit(1).truncationMode(.middle)
                }
                .focused($focusedOption, equals: option)
                .onKeyPress(.return) { select(option); return .handled }
                .id(option)
            }
            if let noResults { Text(noResults).font(.caption).foregroundStyle(.secondary).padding(16) }
        }.padding(6)
    }

    private func select(_ value: Value) {
        if value != selection { selection = value }
        showing = false
    }
}

struct WorkspaceTab<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let icon: String
}

struct WorkspaceTabs<ID: Hashable>: View {
    let items: [WorkspaceTab<ID>]
    @Binding var selection: ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    var body: some View {
        VStack(spacing: 4) {
            ForEach(items) { item in
                Button {
                    selection = item.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).frame(width: 18)
                        Text(item.title).fontWeight(selection == item.id ? .semibold : .regular)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selection == item.id ? WorkspaceStyle.selection : Color.primary)
                    .padding(.horizontal, 12).frame(height: 36).contentShape(Rectangle())
                    .background {
                        if selection == item.id {
                            RoundedRectangle(cornerRadius: 8).fill(WorkspaceStyle.selection.opacity(0.13))
                                .matchedGeometryEffect(id: "selected-tab", in: indicator)
                        }
                    }
                }
                .buttonStyle(WorkspaceHoverStyle())
                .accessibilityAddTraits(selection == item.id ? [.isSelected] : [])
            }
        }
        .animation(DashboardMotion.animation(DashboardMotion.tab, reduceMotion: reduceMotion), value: selection)
        .onMoveCommand { direction in
            guard let current = items.firstIndex(where: { $0.id == selection }) else { return }
            let delta = direction == .up ? -1 : direction == .down ? 1 : 0
            selection = items[min(max(current + delta, 0), items.count - 1)].id
        }
        .padding(12)
    }
}

struct WorkspaceHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledButton(configuration: configuration) }
    private struct StyledButton: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(.primary.opacity(configuration.isPressed ? 0.1 : hovered ? 0.045 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .animation(DashboardMotion.animation(DashboardMotion.hover, reduceMotion: reduceMotion), value: hovered)
                .animation(DashboardMotion.animation(DashboardMotion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}

struct WorkspaceDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 12)
                    .frame(minHeight: 36).contentShape(Rectangle())
            }
            .buttonStyle(WorkspaceHoverStyle())
            .padding(.horizontal, -12)
            .accessibilityValue(L(configuration.isExpanded ? "state.expanded" : "state.collapsed"))
            if configuration.isExpanded {
                configuration.content.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }
}

struct WorkspaceErrorMessage<Actions: View>: View {
    let title: String
    var note: String? = nil
    var detail: String? = nil
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(WorkspaceStyle.warning)
                    .frame(width: 16, alignment: .leading)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline).foregroundStyle(WorkspaceStyle.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Text(note).fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail {
                        Text(detail).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
                .foregroundStyle(WorkspaceStyle.subtext)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .controlSize(.small)
                .fixedSize()
        }
        .accessibilityElement(children: .contain)
    }
}
