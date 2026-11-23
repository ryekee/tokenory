// [INPUT]: Shared, persisted HUD preferences and local audio service.
// [OUTPUT]: Visibility, idle-hide switch, triple-click action, position and stepped audio controls with live preview.
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
                                        Button { preferences.placement = placement } label: {
                                            Text(placement.label).frame(width: 82, height: 28)
                                                .background(preferences.placement == placement ? WorkspaceStyle.selection.opacity(0.25) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .strokeBorder(preferences.placement == placement ? WorkspaceStyle.selection : .clear, lineWidth: 1.5)
                                                }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityAddTraits(preferences.placement == placement ? .isSelected : [])
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

struct HUDAudioControls: View {
    @Environment(HUDPreferences.self) private var preferences
    @State private var sound = HUDSound.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("hud.sound")); Spacer()
                SettingsSwitch(label: L("hud.sound"), isOn: Binding(get: { preferences.soundEnabled }, set: { enabled in
                    preferences.soundEnabled = enabled
                    sound.preview(preferences: preferences)
                }))
            }
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
            if let error = sound.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}
