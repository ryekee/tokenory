import ServiceManagement
import Observation

@MainActor @Observable
final class LoginItemService {
    var status = SMAppService.mainApp.status
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        refresh()
    }
    var enabled: Bool { status == .enabled || status == .requiresApproval }
    var statusText: String {
        switch status { case .enabled: "已启用"; case .requiresApproval: "等待在系统设置中允许"; case .notRegistered: "未启用"; case .notFound: "请从安装目录启动应用"; @unknown default: "状态未知" }
    }
}
