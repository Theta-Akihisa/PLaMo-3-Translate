import SwiftUI

enum MacSection: String, CaseIterable, Identifiable {
    case translate, history, models, settings, about
    var id: MacSection { self }

    var title: String {
        switch self {
        case .translate: return "翻訳"
        case .history: return "履歴"
        case .models: return "モデル"
        case .settings: return "設定"
        case .about: return "このアプリについて"
        }
    }

    var icon: String {
        switch self {
        case .translate: return "character.bubble"
        case .history: return "clock.arrow.circlepath"
        case .models: return "cpu"
        case .settings: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

struct MacRootView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: MacSection? = .translate

    var body: some View {
        NavigationSplitView {
            List(MacSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } detail: {
            switch selection ?? .translate {
            case .translate: TranslateView()
            case .history: HistoryView(onSelect: { selection = .translate })
            case .models: ModelsView()
            case .settings: TranslationSettingsView()
            case .about: AboutView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onboardingSheet()
    }
}

struct MacSettingsView: View {
    var body: some View {
        TabView {
            TranslationSettingsView()
                .tabItem { Label("翻訳", systemImage: "textformat") }
            LocalAPISettingsView()
                .tabItem { Label("ローカルAPI", systemImage: "network") }
        }
        .frame(width: 560, height: 560)
    }
}

struct LocalAPISettingsView: View {
    @ObservedObject private var api = LocalAPIController.shared
    @AppStorage(APISettings.enabledKey) private var enabled = false
    @AppStorage(APISettings.portKey) private var port = APISettings.defaultPort
    @State private var portText = ""

    var body: some View {
        Form {
            Section {
                Toggle("ローカルAPIサーバを有効にする", isOn: $enabled)
                HStack {
                    TextField("ポート", text: $portText)
                        .frame(width: 100)
                    Button("適用") { applyPort() }
                }
                LabeledContent("状態", value: api.statusText)
            } header: {
                Text("llama-server 互換 API")
            } footer: {
                Text("127.0.0.1 のみで待ち受けます（同じ Mac 上のアプリ・Chrome 拡張機能から利用可能）。既定ではオフです。")
            }
            Section("エンドポイント") {
                Text("GET /health\nGET /v1/models\nPOST /v1/completions\nPOST /v1/chat/completions")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(port) }
        .onChange(of: enabled) { _, _ in api.apply(enabled: enabled, port: port) }
    }

    private func applyPort() {
        if let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(p) {
            port = p
            api.apply(enabled: enabled, port: p)
        } else {
            portText = String(port)
        }
    }
}
