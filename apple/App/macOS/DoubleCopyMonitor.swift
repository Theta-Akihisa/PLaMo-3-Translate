import AppKit
import ApplicationServices

enum DoubleCopySettings {
    static let enabledKey = "doubleCopyEnabled"   // 既定 true（権限が付与されたときに有効）
}

/// DeepL 風: どのアプリでも ⌘C を 0.4 秒以内に 2 回押すと、クリップボードのテキストを翻訳する。
/// グローバルなキー監視には「アクセシビリティ」権限が必要。
@MainActor
final class DoubleCopyMonitor: ObservableObject {
    static let shared = DoubleCopyMonitor()
    static let interval: TimeInterval = 0.4

    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var isRunning = false

    private var monitor: Any?
    private var lastCopy: Date = .distantPast
    private var timer: Timer?

    var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: DoubleCopySettings.enabledKey) as? Bool) ?? true
    }

    /// 権限を確認する。prompt = true でシステムの許可ダイアログを出す。
    @discardableResult
    func refreshTrust(prompt: Bool = false) -> Bool {
        let trusted: Bool
        if prompt {
            // kAXTrustedCheckOptionPromptKey の値
            trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        } else {
            trusted = AXIsProcessTrusted()
        }
        if trusted != isTrusted { isTrusted = trusted }
        return trusted
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 設定に合わせて監視を開始/停止する。権限が後から付与されても拾えるよう 2 秒ごとに再評価する。
    func startSupervising() {
        apply()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
    }

    func apply() {
        let trusted = refreshTrust()
        let shouldRun = isEnabled && trusted
        if shouldRun, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 8,   // C キー
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return }
                Task { @MainActor in self?.handleCopyKey() }
            }
            isRunning = monitor != nil
        } else if !shouldRun, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            isRunning = false
        }
    }

    private func handleCopyKey() {
        let now = Date()
        guard now.timeIntervalSince(lastCopy) <= Self.interval else {
            lastCopy = now
            return
        }
        lastCopy = .distantPast
        // コピー先アプリがクリップボードを更新するのを少し待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            ResultPanelController.shared.show(source: text, nearMouse: true)
        }
    }
}
