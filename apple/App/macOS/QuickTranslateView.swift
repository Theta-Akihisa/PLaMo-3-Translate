import SwiftUI
import AppKit

/// メニューバーのクイック翻訳（貼り付けて翻訳）
struct QuickTranslateView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var input = ""
    @State private var output = ""
    @State private var error: String?
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
                    Text(output).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
            HStack {
                Button("コピー") { Clipboard.copy(output) }.disabled(output.isEmpty)
                Spacer()
                Button("ウィンドウを開く") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("終了") { NSApplication.shared.terminate(nil) }
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
        output = ""
        task = Task {
            do {
                output = try await model.performTranslation(text: text) { output = $0 }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
