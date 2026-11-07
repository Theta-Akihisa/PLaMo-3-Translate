import Foundation

/// UserDefaults キー（nonisolated: @AppStorage の初期化から参照するため）
enum APISettings {
    static let enabledKey = "apiServerEnabled"
    static let portKey = "apiServerPort"
    static let settingsVersionKey = "apiServerSettingsVersion"
    /// shared/local-api.md の既定ポート（Chrome 拡張機能の既定と同じ）
    static let defaultPort = 18080
    /// 既定で有効（Chrome 拡張機能がアプリを翻訳エンジンとして使うため）
    static let defaultEnabled = true
    /// 旧バージョンの既定ポート（llama-server の既定と衝突するため移行する）
    static let legacyDefaultPort = 8080

    /// キーが無いときの既定値を登録し、旧設定を移行する。起動直後（View 生成前）に呼ぶ。
    static func registerDefaults() {
        let d = UserDefaults.standard
        d.register(defaults: [enabledKey: defaultEnabled, portKey: defaultPort])
        if d.integer(forKey: settingsVersionKey) < 2 {
            // 旧既定 8080 のままなら新しい既定 18080 に移す
            if d.object(forKey: portKey) != nil, d.integer(forKey: portKey) == legacyDefaultPort {
                d.set(defaultPort, forKey: portKey)
            }
            d.set(2, forKey: settingsVersionKey)
        }
    }

    static var storedEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var storedPort: Int {
        let p = UserDefaults.standard.integer(forKey: portKey)
        return p == 0 ? defaultPort : p
    }
}

/// ローカル API サーバの起動/停止を管理する。設定は UserDefaults（@AppStorage と共有）。
@MainActor
final class LocalAPIController: ObservableObject {
    static let shared = LocalAPIController()

    enum Status: Equatable {
        case stopped
        case starting(UInt16)
        case running(UInt16)
        case failed(String)
    }

    @Published private(set) var status: Status = .stopped
    private lazy var server = LocalAPIServer(backend: AppModel.shared)

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    var statusText: String {
        switch status {
        case .stopped: return "停止中"
        case .starting(let p): return "起動中… (ポート \(p))"
        case .running(let p): return "待ち受け中 http://127.0.0.1:\(p)"
        case .failed(let m): return "エラー: \(m)"
        }
    }

    /// メニューバー用の短い表示
    var shortStatusText: String {
        switch status {
        case .stopped: return "停止中"
        case .starting: return "起動中…"
        case .running(let p): return "待ち受け中 :\(p)"
        case .failed: return "エラー"
        }
    }

    func applyStoredSettings() {
        apply(enabled: APISettings.storedEnabled, port: APISettings.storedPort)
    }

    /// 拡張機能から `plamotranslate://open` で呼ばれたときなど、サーバを確実に待ち受け状態にする。
    /// オフに設定されていた場合も、拡張機能から明示的に起動されたのでオンにする。
    func ensureRunning() {
        if !APISettings.storedEnabled {
            UserDefaults.standard.set(true, forKey: APISettings.enabledKey)   // @AppStorage にも反映される
        }
        switch status {
        case .running, .starting: return
        case .stopped, .failed: applyStoredSettings()
        }
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
        let p = UInt16(port)
        // 同じポートで起動済み/起動中なら何もしない（起動時と URL スキームの二重呼び出し対策）
        switch status {
        case .running(let cur), .starting(let cur):
            if cur == p { return }
        case .stopped, .failed:
            break
        }
        status = .starting(p)
        server.start(port: p) { [weak self] state in
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

    /// 接続テスト用の curl コマンド（/health と短い翻訳）
    static func testCurlCommand(port: Int) -> String {
        let base = "http://127.0.0.1:\(port)"
        let body = #"{"messages":[{"role":"user","content":"Hello, world!"}],"chat_template_kwargs":{"target_lang":"ja"}}"#
        return "curl -s \(base)/health && echo && curl -s \(base)/v1/chat/completions -H 'Content-Type: application/json' -d '\(body)'"
    }
}
