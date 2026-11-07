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

        MenuBarExtra("PLaMo 翻訳", systemImage: "character.bubble") {
            QuickTranslateView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .environmentObject(model)
        }
    }
}

/// macOS の URL スキーム `plamotranslate://`
@MainActor
enum MacURLHandler {
    static func handle(_ url: URL, model: AppModel) {
        guard url.scheme?.lowercased() == "plamotranslate" else { return }
        NSApp.activate(ignoringOtherApps: true)
        switch url.host?.lowercased() {
        case "translate":
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            if let t = value("target"), model.targetLanguages.contains(where: { $0.code == t }) { model.settings.targetLang = t }
            if let s = value("source"), model.sourceLanguages.contains(where: { $0.code == s }) { model.settings.sourceLang = s }
            if let text = value("text"), !text.isEmpty { model.translate(externalText: text) }
        default:
            // "open" など: アプリを前面に出し、拡張機能が接続できるよう API サーバを待ち受け状態にする
            LocalAPIController.shared.ensureRunning()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        APISettings.registerDefaults()
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

    /// ウィンドウを閉じてもメニューバーに常駐し、Chrome 拡張機能向けの API を待ち受け続ける
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stopTranslation()
    }
}
