import SwiftUI
import PlamoTranslateCore

/// 用語集・文脈・履歴・性能の設定フォーム（iOS / macOS 共通）
struct TranslationSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                TextField("文脈（任意）", text: $model.settings.context, axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                Text("文脈")
            } footer: {
                Text("文書の種類や話題など、翻訳の手がかりになる情報（例: 技術ドキュメント、カジュアルな会話）。")
            }

            GlossaryEditor()

            Section {
                Toggle("直前の翻訳を文脈として使う", isOn: $model.settings.useHistory)
                if model.settings.useHistory {
                    Stepper("参照する件数: \(model.settings.historyLimit)", value: $model.settings.historyLimit, in: 1...5)
                }
                Button("翻訳履歴を消去", role: .destructive) { confirmClear = true }
                    .disabled(model.history.isEmpty)
            } header: {
                Text("履歴")
            } footer: {
                Text("訳語や文体が揃いやすくなります。履歴は端末内にのみ保存されます。")
            }

            Section {
                Picker("コンテキスト長", selection: $model.settings.contextLength) {
                    Text("4096").tag(4096)
                    Text("8192（推奨）").tag(8192)
                    Text("16384").tag(16384)
                }
                Stepper("最大出力トークン: \(model.settings.maxTokens)", value: $model.settings.maxTokens, in: 256...8192, step: 256)
            } header: {
                Text("性能")
            } footer: {
                Text("コンテキスト長を大きくするとメモリ使用量が増えます。変更後は次回の翻訳時にモデルが再読み込みされます。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("設定")
        .confirmationDialog("翻訳履歴をすべて消去しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("消去", role: .destructive) { model.clearHistory() }
        }
    }
}

struct GlossaryEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var rows: [GlossaryRow] = []
    @State private var loaded = false

    var body: some View {
        Section {
            ForEach($rows) { $row in
                HStack {
                    TextField("原語", text: $row.source)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("訳語", text: $row.target)
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                    .buttonStyle(.borderless)
                }
            }
            Button { rows.append(GlossaryRow()) } label: { Label("用語を追加", systemImage: "plus.circle") }
        } header: {
            Text("用語集")
        } footer: {
            Text("指定した訳語を優先して翻訳します。原語と訳語の両方が入力された行だけが使われます。")
        }
        .onAppear {
            guard !loaded else { return }
            rows = model.settings.glossary.map { GlossaryRow(source: $0.source, target: $0.target) }
            loaded = true
        }
        .onChange(of: rows) { _, new in
            guard loaded else { return }
            model.settings.glossary = new
                .filter { !$0.source.isEmpty && !$0.target.isEmpty }
                .map { GlossaryEntry(source: $0.source, target: $0.target) }
        }
    }
}
