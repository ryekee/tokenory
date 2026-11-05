import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tokenory").font(.headline)
            Text("尚未采集用量").foregroundStyle(.secondary)
            Divider()
            Button("查看统计") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            SettingsLink { Text("设置…") }
            Button("退出 Tokenory") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .padding(20)
        .frame(width: 300, alignment: .leading)
    }
}
