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
        // ⌘O（ファイルを開く）は翻訳画面で受ける
        .onChange(of: model.showFileImporter) { _, open in if open { selection = .translate } }
    }
}

struct MacSettingsView: View {
    var body: some View {
        TabView {
            ShortcutSettingsView()
                .tabItem { Label("ショートカット", systemImage: "keyboard") }
            TranslationSettingsView()
                .tabItem { Label("翻訳", systemImage: "textformat") }
            LocalAPISettingsView()
                .tabItem { Label("Chrome 拡張機能", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 560, height: 600)
    }
}

/// Chrome 拡張機能が使うローカル API（shared/local-api.md）とログイン時の起動
struct LocalAPISettingsView: View {
    @ObservedObject private var api = LocalAPIController.shared
    @ObservedObject private var loginItem = LoginItemController.shared
    @AppStorage(APISettings.enabledKey) private var enabled = APISettings.defaultEnabled
    @AppStorage(APISettings.portKey) private var port = APISettings.defaultPort
    @State private var portText = ""
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                LabeledContent("状態") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(api.statusText).textSelection(.enabled)
                    }
                }
                Toggle("ローカル API サーバを有効にする", isOn: $enabled)
                LabeledContent("ポート") {
                    HStack {
                        TextField("ポート", text: $portText)
                            .labelsHidden()
                            .frame(width: 90)
                            .onSubmit { applyPort() }
                        Button("適用") { applyPort() }
                            .disabled(portText.trimmingCharacters(in: .whitespaces) == String(port))
                    }
                }
                HStack {
                    Button(copied ? "コピーしました" : "接続テスト用 curl をコピー") { copyCurl() }
                    if api.isFailed {
                        Button("再試行") { api.applyStoredSettings() }
                    }
                }
            } header: {
                Text("Chrome 拡張機能")
            } footer: {
                Text("Chrome 拡張機能「PLaMo Translate」は、このアプリを翻訳エンジンとして使います（既定 http://127.0.0.1:\(String(APISettings.defaultPort))）。ポートを変えた場合は拡張機能のオプションも同じ値にしてください。127.0.0.1 のみで待ち受け、Chrome 拡張機能と curl などのローカルツール以外（一般の Web ページ）からのアクセスは拒否します。翻訳テキストは Mac の外に出ません。")
            }

            Section {
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }))
                if loginItem.needsApproval {
                    HStack {
                        Text("システム設定での許可が必要です").foregroundStyle(.secondary)
                        Button("ログイン項目を開く") { loginItem.openSystemSettings() }
                    }
                }
                if let err = loginItem.lastError {
                    Text(err).foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("起動")
            } footer: {
                Text("ウィンドウを閉じてもメニューバーに常駐し、API は待ち受けを続けます（終了はメニューバーの「終了」から）。ログイン時に起動しておくと、拡張機能からいつでも翻訳できます。")
            }

            Section("エンドポイント（llama-server 互換サブセット）") {
                Text("GET  /health\nGET  /v1/models\nPOST /v1/models/select\nPOST /v1/completions\nPOST /v1/chat/completions")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(port)
            loginItem.refresh()
        }
        .onChange(of: enabled) { _, newValue in api.apply(enabled: newValue, port: port) }
    }

    private var statusColor: Color {
        switch api.status {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private func applyPort() {
        if let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(p) {
            port = p
            api.apply(enabled: enabled, port: p)
        } else {
            portText = String(port)
        }
    }

    private func copyCurl() {
        Clipboard.copy(LocalAPIController.testCurlCommand(port: port))
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}

/// ⌘C を2回押して翻訳（DeepL 風）の設定と Accessibility 権限
struct ShortcutSettingsView: View {
    @ObservedObject private var monitor = DoubleCopyMonitor.shared
    @AppStorage(DoubleCopySettings.enabledKey) private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("⌘C を2回押して選択テキストを翻訳", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in monitor.apply() }
                LabeledContent("アクセシビリティ権限", value: monitor.isTrusted ? "許可済み" : "未許可")
                if !monitor.isTrusted {
                    Button("権限をリクエスト…") { monitor.refreshTrust(prompt: true) }
                    Button("システム設定を開く") { monitor.openSystemSettings() }
                }
                LabeledContent("状態", value: monitor.isRunning ? "有効" : "停止中")
            } header: {
                Text("グローバルショートカット")
            } footer: {
                Text("他のアプリで ⌘C を素早く2回押すと、コピーしたテキストを小さな翻訳ウィンドウで翻訳します。他のアプリのキー入力を検知するため、システム設定 > プライバシーとセキュリティ > アクセシビリティ でこのアプリを許可してください（許可後、数秒で有効になります）。キー入力の内容は保存・送信しません。")
            }
        }
        .formStyle(.grouped)
        .onAppear { monitor.apply() }
    }
}
