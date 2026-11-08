import Foundation
import ServiceManagement

/// 「ログイン時に起動」（SMAppService.mainApp, macOS 13+）。
/// Chrome 拡張機能がアプリを翻訳エンジンとして使えるよう、ログイン時に常駐させる。
@MainActor
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    init() { refresh() }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// 登録済み（承認待ちを含む）
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func setEnabled(_ on: Bool) {
        lastError = nil
        let service = SMAppService.mainApp
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
