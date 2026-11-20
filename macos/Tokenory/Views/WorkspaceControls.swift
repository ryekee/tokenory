// [INPUT]: 接收导航项、选项、说明和折叠内容。
// [OUTPUT]: 提供统一导航、下拉选择、悬停、折叠和点击说明控件。
// [POS]: 共享控件保持同一前缘，展开间距由组件统一控制。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct WorkspaceInfoPopover<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(showing ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceHoverStyle())
        .accessibilityLabel(title)
        .popover(isPresented: $showing, arrowEdge: .bottom) { content }
    }
}

struct WorkspaceDropdownTrigger: View {
    let label: String
    let value: String
    let width: CGFloat
    var brand: (name: String, kind: BrandKind)? = nil
    var help: String? = nil
    var flexibleWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let brand { BrandIcon(name: brand.name, kind: brand.kind) }
                Text(value)
                    .lineLimit(1).truncationMode(.tail)
                    .minimumScaleFactor(flexibleWidth ? 0.9 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }.frame(minWidth: flexibleWidth ? 0 : width, idealWidth: width, maxWidth: width)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .help(help ?? value)
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
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if selected || focused {
                    RoundedRectangle(cornerRadius: WorkspaceStyle.fieldRadius)
                        .fill(Color.accentColor.opacity(focused ? 0.16 : 0.1))
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
                .help(title(option))
                .id(option)
            }
            if let noResults { Text(noResults).font(.caption).foregroundStyle(.secondary).padding(16) }
        }.padding(6)
    }

    private func select(_ value: Value) {
        selection = value
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
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selection = item.id }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).frame(width: 18)
                        Text(item.title).fontWeight(selection == item.id ? .semibold : .regular)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selection == item.id ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 12).frame(height: 36).contentShape(Rectangle())
                    .background {
                        if selection == item.id {
                            RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.13))
                                .matchedGeometryEffect(id: "selected-tab", in: indicator)
                        }
                    }
                }
                .buttonStyle(WorkspaceHoverStyle())
                .accessibilityAddTraits(selection == item.id ? [.isSelected] : [])
            }
        }
        .onMoveCommand { direction in
            guard let current = items.firstIndex(where: { $0.id == selection }) else { return }
            let delta = direction == .up ? -1 : direction == .down ? 1 : 0
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                selection = items[min(max(current + delta, 0), items.count - 1)].id
            }
        }
        .padding(12)
    }
}

struct WorkspaceHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledButton(configuration: configuration) }
    private struct StyledButton: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(.primary.opacity(configuration.isPressed ? 0.1 : hovered ? 0.045 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovered = $0 }
        }
    }
}

struct WorkspaceDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0)).frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(WorkspaceHoverStyle())
            .accessibilityValue(L(configuration.isExpanded ? "state.expanded" : "state.collapsed"))
            if configuration.isExpanded {
                configuration.content.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 21)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }.clipped()
    }
}
