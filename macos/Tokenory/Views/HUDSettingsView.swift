// [INPUT]: Shared, persisted HUD preferences and local audio service.
// [OUTPUT]: Visibility, display metric and independent sound controls.
// [POS]: Settings section and the floating counter's audio popover.
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
                        Toggle(L("hud.show"), isOn: $preferences.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    Divider()
                    HStack {
                        Text(L("hud.metric")); Spacer()
                        Picker(L("hud.metric"), selection: $preferences.metric) {
                            Text(L("usage.tokens")).tag(HUDMetric.tokens)
                            Text(L("hud.cost")).tag(HUDMetric.cost)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    }
                    Text(L("hud.today_help")).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            WorkspacePanel { HUDAudioControls().environment(preferences) }
            Text(L("hud.drag_help")).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct HUDAudioControls: View {
    @Environment(HUDPreferences.self) private var preferences
    @State private var sound = HUDSound.shared
    var body: some View {
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("hud.sound")); Spacer()
                Toggle(L("hud.sound"), isOn: $preferences.soundEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            HStack(spacing: 12) {
                Text(L("hud.volume"))
                Slider(value: $preferences.volume, in: 0...1).labelsHidden().accessibilityLabel(L("hud.volume"))
                Text(preferences.volume.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
            }
            Button(L("hud.preview_sound")) { sound.preview(preferences: preferences) }
                .disabled(!preferences.soundEnabled || preferences.volume == 0)
            if let error = sound.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onChange(of: preferences.soundEnabled) { _, _ in sound.update(preferences: preferences) }
        .onChange(of: preferences.volume) { _, _ in sound.update(preferences: preferences) }
        .onDisappear { sound.stop() }
    }
}
