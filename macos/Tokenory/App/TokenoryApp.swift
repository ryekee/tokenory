import AppKit
import SwiftUI

@main
struct TokenoryApp: App {
    var body: some Scene {
        MenuBarExtra("Tokenory", systemImage: "chart.bar.xaxis") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Window("Tokenory", id: "dashboard") {
            ContentUnavailableView("尚未采集", systemImage: "chart.bar.xaxis", description: Text("用量记录将在这里显示。"))
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 960, height: 640)

        Settings {
            Form {
                Text("Tokenory · 本机 AI 用量记录")
            }
            .padding(24)
            .frame(width: 420)
        }
    }
}
