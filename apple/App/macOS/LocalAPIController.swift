import Foundation

/// UserDefaults キー（nonisolated: @AppStorage の初期化から参照するため）
enum APISettings {
    static let enabledKey = "apiServerEnabled"
    static let portKey = "apiServerPort"
    static let defaultPort = 8080
}

/// ローカル API サーバの起動/停止を管理する。設定は UserDefaults（@AppStorage と共有）。
@MainActor
final class LocalAPIController: ObservableObject {
    static let shared = LocalAPIController()

    enum Status: Equatable {
        case stopped
        case running(UInt16)
        case failed(String)
    }

    @Published private(set) var status: Status = .stopped
    private lazy var server = LocalAPIServer(backend: AppModel.shared)

    var statusText: String {
        switch status {
        case .stopped: return "停止中"
        case .running(let p): return "起動中 — http://127.0.0.1:\(p)"
        case .failed(let m): return "起動に失敗しました: \(m)"
        }
    }

    func applyStoredSettings() {
        let d = UserDefaults.standard
        apply(enabled: d.bool(forKey: APISettings.enabledKey), port: d.integer(forKey: APISettings.portKey))
    }

    func apply(enabled: Bool, port: Int) {
        guard enabled else {
            server.stop()
            status = .stopped
            return
        }
        guard (1024...65535).contains(port) else {
            status = .failed("ポートは 1024〜65535 で指定してください")
            return
        }
        server.start(port: UInt16(port)) { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .stopped: self.status = .stopped
                case .running(let p): self.status = .running(p)
                case .failed(let m): self.status = .failed(m)
                }
            }
        }
    }
}
