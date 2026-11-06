import SwiftUI
import PlamoTranslateCore

struct TranslateView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var sourceFocused: Bool
    #if os(iOS)
    @State private var showHistory = false
    #endif

    var body: some View {
        VStack(spacing: 12) {
            LanguageBar()
            if model.settings.targetLang == "ja" { formPicker }
            sourcePane
            actionBar
            outputPane
        }
        .padding()
        .navigationTitle("翻訳")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHistory = true } label: { Label("履歴", systemImage: "clock.arrow.circlepath") }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("閉じる") { sourceFocused = false }
            }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                HistoryView(onSelect: { showHistory = false })
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("完了") { showHistory = false } }
                    }
            }
            .environmentObject(model)
        }
        #endif
    }

    // MARK: 文体

    private var formBinding: Binding<String> {
        Binding(get: { model.settings.form?.rawValue ?? "" },
                set: { model.settings.form = TranslationForm(rawValue: $0) })
    }

    private var formPicker: some View {
        Picker("文体", selection: formBinding) {
            Text("常体").tag("plain")
            Text("敬体").tag("polite")
            Text("指定なし").tag("")
        }
        .pickerStyle(.segmented)
    }

    // MARK: 原文

    private var sourcePane: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.sourceText)
                    .focused($sourceFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if model.sourceText.isEmpty {
                    Text("翻訳したいテキストを入力")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .frame(minHeight: 110, maxHeight: .infinity)

            HStack {
                Text(counterText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let s = Clipboard.paste() { model.sourceText = s }
                } label: { Label("貼り付け", systemImage: "doc.on.clipboard") }
                Button {
                    model.sourceText = ""
                    model.outputText = ""
                } label: { Label("クリア", systemImage: "xmark.circle") }
                .disabled(model.sourceText.isEmpty && model.outputText.isEmpty)
            }
            .labelStyle(.titleAndIcon)
            .font(.callout)
        }
    }

    private var counterText: String {
        let n = model.sourceText.count
        // 日本語中心でおおよそ 1 文字 ≒ 0.7〜1 トークン。目安として表示する
        let approx = Int((Double(n) * 0.8).rounded(.up))
        var s = "\(n) 文字 / 約 \(approx) トークン"
        if n > AppModel.longTextThreshold { s += "（長文: 段落ごとに翻訳）" }
        return s
    }

    // MARK: 操作

    private var actionBar: some View {
        VStack(spacing: 6) {
            HStack {
                if model.isTranslating {
                    Button(role: .destructive) { model.stopTranslation() } label: {
                        Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    ProgressView().controlSize(.small)
                } else {
                    Button { sourceFocused = false; model.startTranslation() } label: {
                        Label("翻訳", systemImage: "arrow.right.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .controlSize(.large)

            HStack(spacing: 6) {
                if model.isLoadingModel { ProgressView().controlSize(.mini) }
                Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if !model.hasAnyInstalledModel {
                Text("モデルが未ダウンロードです。「モデル」画面からダウンロードしてください。")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 訳文

    private var outputPane: some View {
        VStack(spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let err = model.errorMessage {
                        Text(err).foregroundStyle(.red).font(.callout)
                    }
                    if model.outputText.isEmpty, model.errorMessage == nil {
                        Text("訳文がここに表示されます").foregroundStyle(.secondary)
                    } else {
                        Text(model.outputText).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .frame(minHeight: 110, maxHeight: .infinity)

            if !model.outputText.isEmpty {
                HStack {
                    Spacer()
                    Button { Clipboard.copy(model.outputText) } label: { Label("コピー", systemImage: "doc.on.doc") }
                    ShareLink(item: model.outputText) { Label("共有", systemImage: "square.and.arrow.up") }
                }
                .font(.callout)
            }
        }
    }
}

/// 原文言語 ⇄ 訳文言語の選択バー
struct LanguageBar: View {
    @EnvironmentObject var model: AppModel

    private var sourceBinding: Binding<String> {
        Binding(get: { model.settings.sourceLang ?? "" },
                set: { model.settings.sourceLang = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        HStack {
            Picker("原文", selection: sourceBinding) {
                Text("自動検出").tag("")
                ForEach(model.sourceLanguages) { Text($0.ja).tag($0.code) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Button { model.swapLanguages() } label: { Image(systemName: "arrow.left.arrow.right") }
                .disabled(model.settings.sourceLang == nil)
                .help("言語を入れ替え")

            Picker("訳文", selection: $model.settings.targetLang) {
                ForEach(model.targetLanguages) { Text($0.ja).tag($0.code) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .pickerStyle(.menu)
    }
}
