import SwiftUI
import AppKit

@main
@MainActor
struct PlamoTranslateMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("PLaMo Translate", id: "main") {
            MacRootView()
                .environmentObject(model)
        }

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            APISettings.enabledKey: false,
            APISettings.portKey: APISettings.defaultPort,
        ])
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

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stopTranslation()
    }
}
