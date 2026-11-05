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
        switch status { case .enabled: L("login.enabled"); case .requiresApproval: L("login.approval"); case .notRegistered: L("login.disabled"); case .notFound: L("login.install"); @unknown default: L("login.unknown") }
    }
}
