import SwiftUI
import UIKit

@main
@MainActor
struct PlamoTranslateApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(model)
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { TranslateView() }
                .tabItem { Label("翻訳", systemImage: "character.bubble") }
                .tag(0)
            NavigationStack { ModelsView() }
                .tabItem { Label("モデル", systemImage: "cpu") }
                .tag(1)
            NavigationStack { IOSSettingsRoot() }
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(2)
        }
        .onboardingSheet()
        // plamotranslate://translate?text=...&target=en&source=ja
        .onOpenURL { url in
            guard url.scheme == "plamotranslate", url.host == "translate",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            tab = 0
            if let t = value("target"), model.targetLanguages.contains(where: { $0.code == t }) { model.settings.targetLang = t }
            if let s = value("source"), model.sourceLanguages.contains(where: { $0.code == s }) { model.settings.sourceLang = s }
            if let text = value("text"), !text.isEmpty { model.translate(externalText: text) }
        }
        .onChange(of: scenePhase) { _, phase in
            // バックグラウンドでは Metal の実行が許可されないため、生成を止める
            if phase == .background { model.handleBackground() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.releaseEngine()
        }
    }
}

/// 設定タブ: 翻訳設定 + 履歴 / このアプリについて への導線
struct IOSSettingsRoot: View {
    var body: some View {
        TranslationSettingsView()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { AboutView() } label: { Image(systemName: "info.circle") }
                }
            }
    }
}
