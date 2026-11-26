// [INPUT]: Shared, persisted HUD preferences and local audio service.
// [OUTPUT]: Visibility, idle-hide switch, triple-click action, placement and audio controls that reveal volume when sound is on.
// [POS]: Settings section and its sound controls.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct HUDSettingsView: View {
    @State private var preferences = HUDPreferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspacePanel {
                VStack(spacing: 16) {
                    HStack {
                        Text(L("hud.show")); Spacer()
                        SettingsSwitch(label: L("hud.show"), isOn: $preferences.enabled)
                    }
                    HStack {
                        Text(L("hud.auto_hide")); Spacer()
                        SettingsSwitch(label: L("hud.auto_hide"), isOn: $preferences.autoHideWhenIdle)
                    }
                    HStack {
                        Text(L("hud.follow_pointer")); Spacer()
                        SettingsSwitch(label: L("hud.follow_pointer"), isOn: $preferences.followPointer)
                    }
                    HStack {
                        Text(L("hud.dismiss.title")); Spacer()
                        WorkspaceDropdown(
                            label: L("hud.dismiss.title"), selection: $preferences.dismissal,
                            options: HUDDismissal.allCases,
                            width: WorkspaceDropdownTrigger.fittingWidth(for: HUDDismissal.allCases.map(\.label)),
                            title: { $0.label }
                        )
                    }
                    Divider()
                    HStack(alignment: .top) {
                        Text(L("hud.position")); Spacer()
                        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(0..<2) { row in
                                GridRow {
                                    ForEach(0..<3) { column in
                                        let placement = HUDPlacement.allCases[row * 3 + column]
                                        HUDPlacementButton(
                                            label: placement.label,
                                            selected: preferences.matchedPlacement == placement
                                        ) {
                                            preferences.placement = placement
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            WorkspacePanel { HUDAudioControls().environment(preferences) }
        }
    }
}

private struct HUDPlacementButton: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).frame(width: 82, height: 28)
        }
        .buttonStyle(HUDPlacementButtonStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct HUDPlacementButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, selected: selected)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        private var fill: Color {
            if selected {
                return WorkspaceStyle.selection.opacity(configuration.isPressed ? 0.32 : hovered ? 0.28 : 0.25)
            }
            return Color.primary.opacity(configuration.isPressed ? 0.14 : hovered ? 0.10 : 0.06)
        }

        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? WorkspaceStyle.selection : .clear, lineWidth: 1.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .animation(DashboardMotion.animation(DashboardMotion.state, reduceMotion: reduceMotion), value: selected)
                .animation(DashboardMotion.animation(DashboardMotion.hover, reduceMotion: reduceMotion), value: hovered)
                .animation(DashboardMotion.animation(DashboardMotion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}

struct HUDAudioControls: View {
    @Environment(HUDPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sound = HUDSound.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("hud.sound")); Spacer()
                SettingsSwitch(label: L("hud.sound"), isOn: Binding(get: { preferences.soundEnabled }, set: { enabled in
                    DashboardMotion.withAnimation(DashboardMotion.panel, reduceMotion: reduceMotion) {
                        preferences.soundEnabled = enabled
                    }
                    sound.preview(preferences: preferences)
                }))
            }
            if preferences.soundEnabled {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(L("hud.volume"))
                        Spacer(minLength: 12)
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                            Slider(value: Binding(get: { preferences.volume }, set: { volume in
                                guard volume != preferences.volume else { return }
                                preferences.volume = volume
                                sound.preview(preferences: preferences)
                            }), in: 0...1, step: 0.05) { Text(L("hud.volume")) }
                                .labelsHidden()
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(preferences.volume.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                        }
                        .frame(maxWidth: 300)
                    }
                    if let error = sound.error {
                        WorkspaceErrorMessage(title: error) {}
                            .transition(.opacity)
                    }
                }
                .transition(.opacity)
            }
        }
        .clipped()
        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: preferences.soundEnabled)
        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: sound.error != nil)
    }
}
