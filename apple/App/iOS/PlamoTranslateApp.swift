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

    var body: some View {
        TabView {
            NavigationStack { TranslateView() }
                .tabItem { Label("翻訳", systemImage: "character.bubble") }
            NavigationStack { ModelsView() }
                .tabItem { Label("モデル", systemImage: "cpu") }
            NavigationStack { IOSSettingsRoot() }
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .onboardingSheet()
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
