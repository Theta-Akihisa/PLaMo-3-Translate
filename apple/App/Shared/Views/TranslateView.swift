import SwiftUI
import UniformTypeIdentifiers
import PlamoTranslateCore

/// 保存用のプレーンテキスト文書
struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// DeepL 風の 2 ペイン翻訳画面。広い幅では左右、狭い幅（iPhone）では上下に並べる。
struct TranslateView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var sourceFocused: Bool
    /// 原文・訳文のスクロール連動
    @StateObject private var scrollSync = ScrollSyncController()
    @AppStorage(TextScale.key) private var textScale = TextScale.defaultValue
    @ScaledMetric(relativeTo: .title3) private var baseFontSize: CGFloat = TextScale.basePointSize
    private var paneFontSize: CGFloat { baseFontSize * TextScale.clamp(textScale) }
    @State private var showGlossary = false
    @State private var showExporter = false
    #if os(iOS)
    @State private var showHistory = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            LanguageBar()
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            GeometryReader { geo in
                if geo.size.width >= 620 {
                    HStack(spacing: 0) {
                        sourcePane
                        Divider()
                        targetPane
                    }
                } else {
                    VStack(spacing: 0) {
                        sourcePane
                        Divider()
                        targetPane
                    }
                }
            }
            .pinchToScaleText()
        }
        .navigationTitle("翻訳")
        .onChange(of: model.settings.targetLang) { _, _ in model.retranslateIfLive() }
        .onChange(of: model.settings.sourceLang) { _, _ in model.retranslateIfLive() }
        .onChange(of: model.settings.form) { _, _ in model.retranslateIfLive() }
        .sheet(isPresented: $showGlossary) { GlossarySheet().environmentObject(model) }
        .fileExporter(isPresented: $showExporter,
                      document: TextDocument(text: model.outputText),
                      contentType: .plainText,
                      defaultFilename: "translation") { _ in }
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

    // MARK: 原文ペイン

    private var sourcePane: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                SyncedTextView(text: $model.sourceText, isEditable: true, fontSize: paneFontSize,
                               side: .source, controller: scrollSync)
                if model.sourceText.isEmpty {
                    emptyOverlay
                }
                if !model.sourceText.isEmpty {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                model.sourceText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).imageScale(.large)
                            }
                            .buttonStyle(.plain)
                            .help("クリア")
                            .padding(10)
                        }
                        Spacer()
                    }
                }
            }
            if let p = model.fileLoadProgress {
                HStack(spacing: 8) {
                    ProgressView(value: p).frame(maxWidth: 160)
                    Text("ファイルを読み込み中…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("中止") { model.cancelFileLoad() }.controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            } else if let summary = model.loadedFileSummary {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            HStack {
                Text(counterText).font(.caption).foregroundStyle(.secondary)
                Button { model.showFileImporter = true } label: {
                    Label("ファイルを開く", systemImage: "doc.badge.plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("ファイルを開く（⌘O）— テキスト / PDF / RTF")
                Spacer()
                if !model.liveTranslate || model.isTranslating == false && model.outputText.isEmpty && !model.sourceText.isEmpty {
                    Button("翻訳") { sourceFocused = false; model.startTranslation() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: FileTextLoader.supportedTypes + [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
        .fileImporter(isPresented: $model.showFileImporter,
                      allowedContentTypes: FileTextLoader.supportedTypes) { result in
            switch result {
            case .success(let url): model.loadText(from: url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
    }

    /// Finder / ファイル App などからドロップされたファイルを読み込む
    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let model = self.model
        // ファイルの実体を受け取る（iOS のファイル App・macOS の Finder の両方で使える）
        if let type = FileTextLoader.supportedTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return }
                // url はこのコールバックの間だけ有効なので一時フォルダへコピーする
                var name = url.lastPathComponent
                if URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                    name += "." + ext
                }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let dest = dir.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: dest)
                } catch { return }
                Task { @MainActor in model.loadText(from: dest) }
            }
            return true
        }
        // ファイル URL（形式が拡張子でしか判別できない場合）
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL, FileTextLoader.isSupported(url) else { return }
                Task { @MainActor in model.loadText(from: url) }
            }
            return true
        }
        return false
    }

    /// 空のときの案内と、目立つ貼り付けボタン（DeepL iOS 風）
    private var emptyOverlay: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("翻訳したいテキストを入力")
                .translationTextFont().foregroundStyle(.tertiary)
                .allowsHitTesting(false)
            HStack(spacing: 10) {
                Button { model.pasteFromClipboard() } label: {
                    Label("貼り付け", systemImage: "doc.on.clipboard")
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                Button { model.showFileImporter = true } label: {
                    Label("ファイル（PDF など）", systemImage: "doc.badge.plus")
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
            #if os(macOS)
            Text("PDF・テキスト（.txt / .md）・RTF ファイルをここにドラッグするか、⌘O で開いて翻訳できます")
                .font(.caption).foregroundStyle(.tertiary)
            #endif
            if !model.hasAnyInstalledModel {
                Text("モデルが未ダウンロードです。「モデル」画面からダウンロードしてください。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 12)
    }

    private var counterText: String {
        let n = model.sourceText.count
        var s = "\(n) 文字"
        if n > AppModel.longTextThreshold { s += "（長文: 段落ごとに翻訳）" }
        return s
    }

    // MARK: 訳文ペイン

    private var formBinding: Binding<String> {
        Binding(get: { model.settings.form?.rawValue ?? "" },
                set: { model.settings.form = TranslationForm(rawValue: $0) })
    }

    private var targetToolbar: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("文体", selection: formBinding) {
                    Text("自動").tag("")
                    Text("常体").tag("plain")
                    Text("敬体").tag("polite")
                }
            } label: {
                Label("文体: \(formLabel)", systemImage: "textformat")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.settings.targetLang != "ja")
            .fixedSize()

            Button { showGlossary = true } label: { Label("用語集", systemImage: "character.book.closed") }
            Spacer()
            if model.isTranslating { ProgressView().controlSize(.small) }
            TextSizeMenu()
            ScrollSyncToggle()
            if !model.outputText.isEmpty {
                Button { Clipboard.copy(model.outputText) } label: { Label("コピー", systemImage: "doc.on.doc") }
                ShareLink(item: model.outputText) { Label("共有", systemImage: "square.and.arrow.up") }
                Button { showExporter = true } label: { Label("訳文を保存", systemImage: "square.and.arrow.down") }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var formLabel: String {
        switch model.settings.form {
        case .some(.plain): return "常体"
        case .some(.polite): return "敬体"
        default: return "自動"
        }
    }

    private var targetPane: some View {
        VStack(spacing: 0) {
            targetToolbar
            if let err = model.errorMessage {
                Text(err).foregroundStyle(.red).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 17)
                    .padding(.bottom, 4)
            }
            ZStack(alignment: .topLeading) {
                SyncedTextView(text: Binding(get: { model.outputText }, set: { _ in }), isEditable: false,
                               fontSize: paneFontSize, side: .target, controller: scrollSync)
                if model.outputText.isEmpty, model.errorMessage == nil {
                    Text("訳文がここに表示されます")
                        .translationTextFont()
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 6) {
                if model.isLoadingModel { ProgressView().controlSize(.mini) }
                Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.08))
    }
}

struct GlossarySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { GlossaryEditor() }
                .formStyle(.grouped)
                .navigationTitle("用語集")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } }
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
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
                Text(model.autoDetectLabel).tag("")
                ForEach(model.sourceLanguages) { Text($0.ja).tag($0.code) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Button { model.swapLanguages() } label: { Image(systemName: "arrow.left.arrow.right") }
                .disabled(model.settings.sourceLang == nil && model.detectedLang == nil)
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
