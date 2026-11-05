import SwiftUI

enum WorkspaceStyle {
    static let panelRadius: CGFloat = 12
    static let fieldRadius: CGFloat = 8

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.085, green: 0.09, blue: 0.105)
            : Color(red: 0.95, green: 0.955, blue: 0.965)
    }

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.13, green: 0.14, blue: 0.155)
            : Color(nsColor: .controlBackgroundColor)
    }

    static func costColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1, green: 0.68, blue: 0.32) : Color(red: 0.65, green: 0.3, blue: 0.04)
    }

    static func toolColor(_ key: String) -> Color {
        switch key {
        case "codex": .blue
        case "claude": .orange
        case "micode": .teal
        case "copilot": .purple
        case "cline": .pink
        default: .gray
        }
    }
}

struct WorkspacePanel<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: WorkspaceStyle.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceStyle.panelRadius)
                    .strokeBorder(.primary.opacity(scheme == .dark ? 0.05 : 0.035), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 3, y: 1)
    }
}
