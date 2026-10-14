import AppKit
import Combine
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?
    private var subscription: AnyCancellable?
    var requested: Bool { status == .enabled || status == .requiresApproval }
    var description: String {
        switch status {
        case .enabled: return "AppSweep will open when you log in."
        case .requiresApproval: return "Approval is needed in System Settings → General → Login Items."
        case .notRegistered: return "Open AppSweep manually when you need it."
        case .notFound: return "macOS could not find this app. Keep it in a stable location, such as Applications."
        @unknown default: return "Login item status is unavailable."
        }
    }
    init() {
        subscription = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
    }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = "Launch at login could not be changed: \(error.localizedDescription)" }
        refresh()
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
