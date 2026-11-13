// [INPUT]: 接收导航项、选择状态和折叠内容。
// [OUTPUT]: 提供统一导航、悬停和折叠控件。
// [POS]: 共享控件保持同一前缘，展开间距由组件统一控制。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

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
