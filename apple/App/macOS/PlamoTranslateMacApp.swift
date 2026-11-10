import SwiftUI
import AppKit

@main
@MainActor
struct PlamoTranslateMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        // @AppStorage / LocalAPIController より先に既定値（API サーバ: 有効, ポート 18080）を登録する
        APISettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup("PLaMo Translate", id: "main") {
            MacRootView()
                .environmentObject(model)
                // plamotranslate://open（Chrome 拡張機能の「アプリを起動」）
                // plamotranslate://translate?text=...&target=en&source=ja
                .onOpenURL { url in MacURLHandler.handle(url, model: model) }
                // 既存のウィンドウがあれば新しいウィンドウを作らずにそこで受ける
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            OpenFileCommands()
            TextSizeCommands()
        }

        MenuBarExtra {
            QuickTranslateView()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .environmentObject(model)
        }
    }
}

extension Notification.Name {
    /// メインウィンドウを開く依頼（`MenuBarLabel` が `openWindow` で受ける）
    static let openMainWindowRequest = Notification.Name("PlamoTranslate.openMainWindowRequest")
}

/// メインウィンドウ（WindowGroup "main"）を前面に出す。閉じられていれば SwiftUI の openWindow で開き直す。
@MainActor
enum MainWindow {
    /// 表示中（または最小化中）のメインウィンドウ。パネル・設定・メニューバーのポップアップは除く
    static var existing: NSWindow? {
        NSApp.windows.first { w in
            !(w is NSPanel) && w.canBecomeMain && w.styleMask.contains(.titled)
                && (w.isVisible || w.isMiniaturized)
                && !(w.identifier?.rawValue.contains("Settings") ?? false)
        }
    }

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = existing {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // URL スキーム経由で開くと onOpenURL が再び呼ばれる（API の設定に触れる）ので使わない
            NotificationCenter.default.post(name: .openMainWindowRequest, object: nil)
        }
    }
}

/// メニューバーのアイコン。常に存在する SwiftUI ビューなので、ここでメインウィンドウを開く依頼を受ける
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "character.bubble")
            .accessibilityLabel("PLaMo 翻訳")
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindowRequest)) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// macOS の URL スキーム `plamotranslate://`
@MainActor
enum MacURLHandler {
    static func handle(_ url: URL, model: AppModel) {
        // Finder の「このアプリケーションで開く」・Dock へのドロップで渡された PDF / テキスト
        if url.isFileURL {
            NSApp.activate(ignoringOtherApps: true)
            model.loadText(from: url)
            return
        }
        guard url.scheme?.lowercased() == "plamotranslate" else { return }
        NSApp.activate(ignoringOtherApps: true)
        switch url.host?.lowercased() {
        case "translate":
            // 原文を置き換えるので、必ずウィンドウを前面に出して見えるようにする（元に戻す案内も出る）
            MainWindow.show()
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            if let t = value("target"), model.targetLanguages.contains(where: { $0.code == t }) { model.settings.targetLang = t }
            if let s = value("source"), model.sourceLanguages.contains(where: { $0.code == s }) { model.settings.sourceLang = s }
            if let text = value("text"), !text.isEmpty { model.translate(externalText: text, from: "URL スキーム") }
        default:
            // "open" など: アプリを前面に出す。API がオンなら待ち受けを確実にし、
            // オフなら設定は変えずに、メインウィンドウで「API をオンにする」か確認する
            if LocalAPIController.shared.handleOpenRequest() {
                MainWindow.show()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = ServicesProvider()
    private var textSizeKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        APISettings.registerDefaults()
        installTextSizeKeyMonitor()
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        LocalAPIController.shared.applyStoredSettings()
        // ⌘C×2 翻訳（権限が無ければ初回のみシステムの許可ダイアログを出す）
        if DoubleCopyMonitor.shared.isEnabled, !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            DoubleCopyMonitor.shared.refreshTrust(prompt: true)
        }
        DoubleCopyMonitor.shared.startSupervising()
    }

    /// 文字サイズのショートカットをキーボード配列に依存せず受け付ける。
    /// 表示メニューの ⌘+ は US 配列では ⌘= / ⌘⇧=、JIS 配列では ⌘⇧; で入力されるため、
    /// メニューの照合に任せず、ここで文字を見て処理する（クイック翻訳などのパネルでも効く）。
    private func installTextSizeKeyMonitor() {
        textSizeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.command), !mods.contains(.control), !mods.contains(.option) else { return event }
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                TextScale.increase()
                return nil
            case "-":
                guard !mods.contains(.shift) else { return event }
                TextScale.decrease()
                return nil
            case "0":
                guard !mods.contains(.shift) else { return event }
                TextScale.reset()
                return nil
            default:
                return event
            }
        }
    }

    /// ウィンドウを閉じてもメニューバーに常駐し、Chrome 拡張機能向けの API を待ち受け続ける
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stopTranslation()
        AppModel.shared.flushHistory()
    }
}
