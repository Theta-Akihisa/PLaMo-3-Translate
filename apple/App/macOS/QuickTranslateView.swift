import SwiftUI
import AppKit

/// メニューバーのクイック翻訳（貼り付けて翻訳）
struct QuickTranslateView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var api = LocalAPIController.shared
    @State private var input = ""
    @State private var output = ""
    @State private var error: String?
    /// 訳文が長さの上限で途中で切れたときの警告（途中までの訳文は表示したまま）
    @State private var warning: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("クイック翻訳").font(.headline)
                Spacer()
                Picker("訳文", selection: $model.settings.targetLang) {
                    ForEach(model.targetLanguages) { Text($0.ja).tag($0.code) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }
            TextEditor(text: $input)
                .translationTextFont()
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .frame(height: 100)
            HStack {
                Button("貼り付けて翻訳") {
                    if let s = Clipboard.paste() { input = s; run() }
                }
                Button("翻訳") { run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                if busy {
                    Button("停止") { task?.cancel() }
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading) {
                    if let error { Text(error).foregroundStyle(.red) }
                    if let warning { Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                    Text(output).translationTextFont().textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
            HStack {
                Button("コピー") { Clipboard.copy(output) }.disabled(output.isEmpty)
                Spacer()
                Button("ウィンドウを開く") { MainWindow.show() }
                Button("終了") { NSApplication.shared.terminate(nil) }
            }
            Divider()
            // Chrome 拡張機能向けローカル API の状態
            HStack(spacing: 6) {
                Circle()
                    .fill(api.isRunning ? Color.green : (api.isFailed ? Color.red : Color.secondary))
                    .frame(width: 7, height: 7)
                Text("Chrome 拡張機能: \(api.shortStatusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(api.statusText)
                Spacer()
                if !api.isRunning {
                    Button("API を開始") { api.enableAndStart() }
                        .controlSize(.small)
                }
                SettingsLink { Text("設定…") }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func run() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        error = nil
        warning = nil
        output = ""
        task = Task {
            do {
                let result = try await model.performTranslation(text: text) { output = $0 }
                output = result.text
                warning = result.warning
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
