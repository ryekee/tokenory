// [INPUT]: The macOS appearance and the data role of each mark.
// [OUTPUT]: Tokyo Neon and Tokyo Neon Light colors, warning and dropdown colors, chart highlights and layout metrics.
// [POS]: Shared colors and panel surfaces for the statistics workspace.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

private struct WorkspaceTone: ShapeStyle, Hashable {
    let light: UInt32
    let dark: UInt32

    func color(for scheme: ColorScheme) -> Color {
        let rgb = scheme == .dark ? dark : light
        return Color(.sRGB, red: Double(rgb >> 16) / 255,
                     green: Double((rgb >> 8) & 0xff) / 255, blue: Double(rgb & 0xff) / 255)
    }

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        color(for: environment.colorScheme).resolve(in: environment)
    }
}

enum WorkspaceStyle {
    static let panelRadius: CGFloat = 12
    static let fieldRadius: CGFloat = 8

    private static let page = WorkspaceTone(light: 0xF6F8FA, dark: 0x100E18)
    private static let panel = WorkspaceTone(light: 0xFFFFFF, dark: 0x20182C)
    private static let pink = WorkspaceTone(light: 0xE10067, dark: 0xFF4081)
    private static let mint = WorkspaceTone(light: 0x00A677, dark: 0x69F0AE)
    private static let yellow = WorkspaceTone(light: 0xBF8A00, dark: 0xFFEA00)

    static let text = Color(WorkspaceTone(light: 0x231B32, dark: 0xFFFFFF))
    static let subtext = Color(WorkspaceTone(light: 0x60566E, dark: 0xC5C3C8))
    static let warning = Color(WorkspaceTone(light: 0x9D5200, dark: 0xFFAE58))
    static let warningSurface = Color(WorkspaceTone(light: 0xFCE7CC, dark: 0x402A19))
    static let lightFilterLabel = Color(.sRGB, red: 89 / 255, green: 99 / 255, blue: 110 / 255)
    static let darkDropdownLabel = Color(.sRGB, red: 197 / 255, green: 195 / 255, blue: 202 / 255)
    static let darkDropdownUnderlay = Color.white.opacity(0.12)
    static let selection = Color("AccentColor")
    static let chartHighlight = Color.white.opacity(0.18)
    static let onSelection = Color(WorkspaceTone(light: 0xFFFFFF, dark: 0x20182C))
    static let localUsage = Color(WorkspaceTone(light: 0x008CE0, dark: 0x00B0FF))
    static let outputTokens = Color(mint)
    static let cacheRead = Color(WorkspaceTone(light: 0x5260BD, dark: 0x5C6BC0))
    static let cacheWrite = Color(WorkspaceTone(light: 0xC31978, dark: 0xF50057))
    static let reasoningTokens = Color(WorkspaceTone(light: 0x716B80, dark: 0xA19EA6))
    static let toolWait = Color(WorkspaceTone(light: 0xB86B2B, dark: 0xFFB067))
    static let otherTurnTime = Color(WorkspaceTone(light: 0x5260BD, dark: 0x7986CB))

    static func canvas(_ scheme: ColorScheme) -> Color { page.color(for: scheme) }
    static func surface(_ scheme: ColorScheme) -> Color { panel.color(for: scheme) }
    static func costColor(_ scheme: ColorScheme) -> Color { pink.color(for: scheme) }
    static func otherDevices(_ scheme: ColorScheme) -> Color { mint.color(for: scheme) }
    static func fastUsage(_ scheme: ColorScheme) -> Color { yellow.color(for: scheme) }

    static func toolColor(_ key: String) -> Color {
        switch key {
        case "codex": localUsage
        case "claude": .orange
        case "micode": outputTokens
        case "copilot": cacheRead
        case "cline": cacheWrite
        default: reasoningTokens
        }
    }
}

struct WorkspacePanel<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var surface: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        // Native controls use inherited foreground styles to draw their inactive bezels.
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface ?? WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: WorkspaceStyle.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceStyle.panelRadius)
                    .strokeBorder(.primary.opacity(scheme == .dark ? 0.05 : 0.035), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 3, y: 1)
    }
}
