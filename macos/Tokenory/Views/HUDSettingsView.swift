// [INPUT]: Shared, persisted HUD preferences and local audio service.
// [OUTPUT]: Visibility, six screen positions, display metric and independent sound controls.
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
                    HStack(alignment: .top) {
                        Text(L("hud.position")); Spacer()
                        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(0..<2) { row in
                                GridRow {
                                    ForEach(0..<3) { column in
                                        let placement = HUDPlacement.allCases[row * 3 + column]
                                        Button { preferences.placement = placement } label: {
                                            Text(placement.label).frame(width: 82, height: 28)
                                                .background(preferences.placement == placement ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .strokeBorder(preferences.placement == placement ? Color.accentColor : .clear, lineWidth: 1.5)
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
            if let error = sound.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onChange(of: preferences.soundEnabled) { _, _ in sound.update(preferences: preferences) }
        .onChange(of: preferences.volume) { _, _ in sound.update(preferences: preferences) }
        .onDisappear { sound.stop() }
    }
}
