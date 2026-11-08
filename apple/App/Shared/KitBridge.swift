import Foundation
import Combine
import SwiftUI
import PlamoTranslateCore
import PlamoTranslateKit

// ============================================================
// このファイルだけが PlamoTranslateKit / Core の具体 API に触れる。
// Kit 側の名前が違っていたらここだけ直せばよい。
// 【仮定している Kit API（要確認）】
//  - Translator(store:) に ModelStore を共有させる（別インスタンスだとインストール状態がずれる）
//  - ModelStore.downloads: [ModelFile.file: DownloadStatus]
//  - Translator.engine: LlamaEngine?（ロード済みなら非 nil）
//  - Translator.unload()（エンジン解放）
//  - DocumentProgress.text（累積した翻訳全文）
//  - TranslationSettings() が既定値で生成でき、全プロパティが var
//  - Translator.load(model: ModelSpec, quant: String, contextLength: Int)
//  - ModelStore.importLocalFile(url:)（macOS）
// ============================================================

enum AppError: LocalizedError {
    case modelNotInstalled(String)
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let label):
            return "モデル \(label) がダウンロードされていません。「モデル」画面からダウンロードしてください。"
        case .engineUnavailable:
            return "翻訳エンジンを利用できません。"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// この文字数を超える入力は translateDocument（段落分割）で翻訳する
    static let longTextThreshold = 1500
    static let historyCapacity = 100

    private enum Keys {
        static let settings = "translationSettings.v1"
        static let history = "translationHistory.v1"
        static let quantChoices = "quantChoices.v1"
        static let live = "liveTranslate.v1"
    }

    let modelStore: ModelStore
    let translator: Translator

    // 設定（変更時に自動保存）
    @Published var settings: TranslationSettings {
        didSet { saveSettings() }
    }

    // 翻訳画面の状態
    @Published var sourceText = "" {
        didSet { sourceChanged(old: oldValue) }
    }
    @Published var outputText = ""
    @Published var isTranslating = false
    @Published var errorMessage: String?

    // モデル管理の状態
    @Published private(set) var downloading: Set<String> = []
    @Published var downloadErrors: [String: String] = [:]
    @Published var quantChoices: [String: String] {
        didSet { UserDefaults.standard.set(quantChoices, forKey: Keys.quantChoices) }
    }

    @Published private(set) var history: [HistoryEntry]

    /// 入力しながら自動翻訳（DeepL 風）。デバウンス後に翻訳する
    @Published var liveTranslate: Bool {
        didSet { UserDefaults.standard.set(liveTranslate, forKey: Keys.live) }
    }
    static let liveDebounceNanos: UInt64 = 500_000_000
    /// 「言語を検出」選択時の検出結果（確信度が高く、対応言語のときだけ非 nil）
    @Published private(set) var detectedLang: String?
    private var debounceTask: Task<Void, Never>?
    private var suppressLive = false
    private var immediateNext = false
    private var runID = 0

    private var sinks = Set<AnyCancellable>()
    private var translateTask: Task<Void, Never>?
    private var loadTask: Task<Void, Error>?
    private var loadedKey: String?

    init() {
        let store = ModelStore()
        self.modelStore = store
        self.translator = Translator(store: store)
        let d = UserDefaults.standard
        var s: TranslationSettings = d.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(TranslationSettings.self, from: $0) } ?? TranslationSettings()
        // 旧表記のやさしい日本語（ja(easy)）を ja-easy に移行
        s.targetLang = PFML3.normalizeLang(s.targetLang)
        if ModelCatalog.spec(id: s.modelID) == nil {
            s.modelID = ModelCatalog.defaultModel.id
            s.quant = ModelCatalog.defaultModel.defaultQuant
        }
        self.settings = s
        self.quantChoices = (d.dictionary(forKey: Keys.quantChoices) as? [String: String]) ?? [:]
        self.liveTranslate = (d.object(forKey: Keys.live) as? Bool) ?? true
        self.history = d.data(forKey: Keys.history)
            .flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []

        // 子オブジェクトの変更を View に伝える
        modelStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &sinks)
        translator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &sinks)
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Keys.settings)
        }
    }

    // MARK: - カタログ

    var sourceLanguages: [Language] { LanguageCatalog.all }
    var targetLanguages: [Language] { LanguageCatalog.targets }
    var models: [ModelSpec] { ModelCatalog.all }
    var recommendedModelIDs: Set<String> { Set(Translator.recommendedModels().map { $0.id }) }

    var currentSpec: ModelSpec {
        ModelCatalog.spec(id: settings.modelID) ?? ModelCatalog.defaultModel
    }

    var currentFile: ModelFile {
        currentSpec.files.first { $0.quant == settings.quant } ?? currentSpec.defaultFile
    }

    var isCurrentModelInstalled: Bool { modelStore.isInstalled(currentFile) }

    var hasAnyInstalledModel: Bool {
        ModelCatalog.all.contains { spec in spec.files.contains { modelStore.isInstalled($0) } }
    }

    /// モデルカードで選択中の量子化ファイル
    func selectedFile(for spec: ModelSpec) -> ModelFile {
        let q = quantChoices[spec.id] ?? (spec.id == settings.modelID ? settings.quant : spec.defaultQuant)
        return spec.files.first { $0.quant == q } ?? spec.defaultFile
    }

    func chooseQuant(_ file: ModelFile, for spec: ModelSpec) {
        quantChoices[spec.id] = file.quant
        if spec.id == settings.modelID, modelStore.isInstalled(file) {
            activate(spec, file: file)
        }
    }

    func isActive(_ spec: ModelSpec) -> Bool {
        spec.id == settings.modelID && modelStore.isInstalled(currentFile)
    }

    func isInstalled(_ file: ModelFile) -> Bool { modelStore.isInstalled(file) }

    func progress(for file: ModelFile) -> Double? {
        switch modelStore.downloads[file.file] {
        case .downloading(let p): return p
        case .verifying: return 1.0
        case .failed, .none: return nil
        }
    }

    var statusText: String {
        switch translator.state {
        case .noModel: return isCurrentModelInstalled ? "待機中（\(currentSpec.label)）" : "モデル未ダウンロード"
        case .loading: return "モデルを読み込み中…"
        case .ready: return "準備完了（\(currentSpec.label)）"
        case .error(let m): return "エラー: \(m)"
        }
    }

    var isLoadingModel: Bool {
        if case .loading = translator.state { return true }
        return false
    }

    // MARK: - モデル操作

    func activate(_ spec: ModelSpec, file: ModelFile) {
        guard settings.modelID != spec.id || settings.quant != file.quant else { return }
        settings.modelID = spec.id
        settings.quant = file.quant
        quantChoices[spec.id] = file.quant
        // 次回の翻訳時に ensureLoaded が再ロードする
    }

    func download(_ spec: ModelSpec, file: ModelFile) {
        guard !downloading.contains(file.file) else { return }
        downloading.insert(file.file)
        downloadErrors[file.file] = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.modelStore.download(file)
                if !self.isCurrentModelInstalled { self.activate(spec, file: file) }
            } catch {
                let cancelled = (error as? URLError)?.code == .cancelled || error is CancellationError
                if !cancelled { self.downloadErrors[file.file] = error.localizedDescription }
            }
            self.downloading.remove(file.file)
        }
    }

    func cancelDownload(_ file: ModelFile) {
        modelStore.cancelDownload(file)
    }

    func delete(_ file: ModelFile) {
        if file.file == currentFile.file { releaseEngine() }
        do { try modelStore.delete(file) } catch { downloadErrors[file.file] = error.localizedDescription }
    }

    #if os(macOS)
    /// 手元の GGUF ファイルを取り込む（macOS のみ）
    func importGGUF(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { _ = try await modelStore.importLocalFile(url: url) } catch { errorMessage = error.localizedDescription }
    }
    #endif

    // MARK: - ロード / 解放

    func ensureLoaded() async throws {
        let spec = currentSpec
        let file = currentFile
        guard modelStore.isInstalled(file) else { throw AppError.modelNotInstalled(spec.label) }
        let ctx = settings.contextLength
        let key = "\(spec.id)|\(file.quant)|\(ctx)"
        if loadedKey == key, case .ready = translator.state { return }
        if let pending = loadTask {
            try await pending.value
            if loadedKey == key { return }
        }
        let t = Task { try await self.translator.load(model: spec, quant: file.quant, contextLength: ctx) }
        loadTask = t
        defer { loadTask = nil }
        try await t.value
        loadedKey = key
    }

    /// メモリ警告・モデル削除時にエンジンを解放する
    func releaseEngine() {
        stopTranslation()
        loadedKey = nil
        translator.unload()
    }

    /// iOS: バックグラウンド移行時は GPU を使えないので生成を止める
    func handleBackground() {
        stopTranslation()
    }

    // MARK: - 翻訳

    private func recentHistoryPairs(target: String, limit: Int) -> [HistoryPair] {
        guard limit > 0 else { return [] }
        let candidates = history.filter { $0.targetLang == target && $0.source.count <= 600 && $0.translation.count <= 1200 }
        return candidates.prefix(limit).reversed().map { HistoryPair(source: $0.source, translation: $0.translation) }
    }

    private static func assembled(_ p: DocumentProgress) -> String { p.text }

    /// 翻訳の中核。onPartial には累積テキストが渡される。UI・メニューバー・ショートカット・サービスで共用。
    func performTranslation(text: String,
                            targetLang: String? = nil,
                            useHistory: Bool = false,
                            onPartial: @escaping (String) -> Void = { _ in }) async throws -> String {
        var s = settings
        let autoDetected = s.sourceLang == nil
        if autoDetected { s.sourceLang = LanguageDetector.detect(text) }
        if let t = targetLang {
            s.targetLang = t
        } else if autoDetected, let src = s.sourceLang, src == (PFML3.normalizeLang(s.targetLang) == "ja-easy" ? "ja" : s.targetLang) {
            s.targetLang = (src == "ja") ? "en" : "ja"   // DeepL 風: 同一言語なら ja⇄en
        }
        if s.targetLang != "ja" { s.form = nil }
        try await ensureLoaded()
        var acc = ""
        if text.count > Self.longTextThreshold {
            for try await p in translator.translateDocument(text: text, settings: s) {
                acc = Self.assembled(p)
                onPartial(acc)
            }
        } else {
            let pairs = (useHistory && s.useHistory) ? recentHistoryPairs(target: s.targetLang, limit: s.historyLimit) : []
            let req = TranslationRequest(text: text,
                                         targetLang: s.targetLang,
                                         sourceLang: s.sourceLang,
                                         form: s.targetLang == "ja" ? s.form : nil,
                                         context: s.context.isEmpty ? nil : s.context,
                                         glossary: s.glossary,
                                         history: pairs)
            for try await delta in translator.translate(req, maxTokens: s.maxTokens) {
                acc += delta
                onPartial(acc)
            }
        }
        if Task.isCancelled { throw CancellationError() }
        return acc.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: ライブ翻訳

    private func sourceChanged(old: String) {
        guard !suppressLive, sourceText != old else { return }
        debounceTask?.cancel()
        stopTranslation()   // 編集されたら進行中の生成を中断
        if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputText = ""
            errorMessage = nil
            detectedLang = nil
            return
        }
        updateDetection()
        guard liveTranslate else { return }
        scheduleTranslation(immediate: immediateNext || sourceText.count - old.count >= 12)
        immediateNext = false
    }

    /// 検出言語の更新と、DeepL 風のスマート既定ターゲット（ja⇄en）
    private func updateDetection() {
        guard settings.sourceLang == nil else { detectedLang = nil; return }
        let d = LanguageDetector.detect(sourceText)
        detectedLang = d
        guard let d else { return }
        let target = PFML3.normalizeLang(settings.targetLang) == "ja-easy" ? "ja" : settings.targetLang
        if d == target {
            settings.targetLang = (d == "ja") ? "en" : "ja"
            settings.form = nil
        }
    }

    /// 検出結果の表示名（例: 「英語（検出）」）
    var autoDetectLabel: String {
        if let d = detectedLang { return "\(LanguageCatalog.name(for: d))（検出）" }
        return "言語を検出"
    }

    private func scheduleTranslation(immediate: Bool) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: Self.liveDebounceNanos) }
            guard !Task.isCancelled, let self else { return }
            self.startTranslation()
        }
    }

    /// 言語・文体を変えたときの再翻訳
    func retranslateIfLive() {
        guard liveTranslate, !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        scheduleTranslation(immediate: true)
    }

    /// クリップボードの内容を原文にして即翻訳（ペースト時は待たない）
    func pasteFromClipboard() {
        guard let s = Clipboard.paste(), !s.isEmpty else { return }
        immediateNext = true
        if s == sourceText { startTranslation() } else { sourceText = s }
        immediateNext = false
    }

    /// 外部（URL スキーム・ダブルコピー等）から原文を渡して翻訳する
    func translate(externalText: String) {
        immediateNext = true
        sourceText = externalText
        immediateNext = false
        if !liveTranslate { startTranslation() }
    }

    func startTranslation() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        translateTask?.cancel()
        runID += 1
        let id = runID
        isTranslating = true
        errorMessage = nil
        outputText = ""
        let target = settings.targetLang
        let source = settings.sourceLang
        translateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.performTranslation(text: text, useHistory: true) { [weak self] partial in
                    if let self, self.runID == id { self.outputText = partial }
                }
                if self.runID == id {
                    self.outputText = result
                    self.addHistory(source: text, translation: result, sourceLang: source, targetLang: target)
                }
            } catch is CancellationError {
                // 中断: 部分結果は残す
            } catch {
                if self.runID == id, !Task.isCancelled { self.errorMessage = error.localizedDescription }
            }
            if self.runID == id { self.isTranslating = false }
        }
    }

    func stopTranslation() {
        runID += 1
        translateTask?.cancel()
        isTranslating = false
    }

    /// 文字列を取り出す（ドラッグ&ドロップ / ファイル読み込み用）
    func loadText(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) else {
                errorMessage = "テキストとして読み込めませんでした。"
                return
            }
            immediateNext = true
            sourceText = text
            immediateNext = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func swapLanguages() {
        guard let src = settings.sourceLang ?? detectedLang else { return }
        let newSource = PFML3.normalizeLang(settings.targetLang) == "ja-easy" ? "ja" : settings.targetLang
        settings.sourceLang = newSource
        settings.targetLang = src
        if settings.targetLang != "ja" { settings.form = nil }
        if !outputText.isEmpty {
            let o = outputText
            immediateNext = true
            sourceText = o
            immediateNext = false
        }
    }

    // MARK: - 履歴

    private func addHistory(source: String, translation: String, sourceLang: String?, targetLang: String) {
        guard !translation.isEmpty, source.count <= 20_000 else { return }
        if let first = history.first, first.source == source, first.targetLang == targetLang { history.removeFirst() }
        history.insert(HistoryEntry(source: source, translation: translation,
                                    sourceLang: sourceLang, targetLang: targetLang), at: 0)
        if history.count > Self.historyCapacity { history.removeLast(history.count - Self.historyCapacity) }
        saveHistory()
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    func restore(_ entry: HistoryEntry) {
        suppressLive = true
        sourceText = entry.source
        suppressLive = false
        stopTranslation()
        outputText = entry.translation
        settings.sourceLang = entry.sourceLang
        settings.targetLang = entry.targetLang
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Keys.history)
        }
    }
}

// MARK: - ローカル API 用バックエンド（shared/local-api.md）

extension AppModel: APIBackend {
    /// API から見た「そのモデルを使うときの量子化ファイル」。
    /// 選択中モデルは設定の量子化。それ以外はモデルカードで選んだ量子化（未選択なら既定）で、
    /// それが未ダウンロードかつ別の量子化がダウンロード済みなら、そちらを使う。
    private func apiFile(for spec: ModelSpec) -> ModelFile {
        if spec.id == settings.modelID { return currentFile }
        let chosen = selectedFile(for: spec)
        if modelStore.isInstalled(chosen) { return chosen }
        return spec.files.first { modelStore.isInstalled($0) } ?? chosen
    }

    private var isCurrentModelLoaded: Bool {
        guard case .ready(let id) = translator.state, id == currentSpec.id else { return false }
        return loadedKey == "\(currentSpec.id)|\(currentFile.quant)|\(settings.contextLength)"
    }

    func apiState() -> APIState {
        let health: APIHealth
        if !isCurrentModelInstalled {
            health = .noModel
        } else if case .loading = translator.state {
            health = .loading
        } else {
            health = .ok   // 未ロードでも可（最初のリクエストで自動ロード）
        }
        let models = ModelCatalog.all.map { spec -> APIModelInfo in
            let file = apiFile(for: spec)
            return APIModelInfo(id: spec.id, size: spec.size, label: spec.label,
                                quant: file.quant, sizeBytes: file.sizeBytes,
                                installed: modelStore.isInstalled(file),
                                installedQuants: spec.files.filter { modelStore.isInstalled($0) }.map(\.quant))
        }
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        return APIState(version: version, health: health, activeModelID: settings.modelID,
                        loaded: isCurrentModelLoaded, models: models)
    }

    func apiSelectModel(id: String) throws {
        guard let spec = ModelCatalog.spec(id: id) else { throw APIError.unknownModel(id) }
        let file = apiFile(for: spec)
        guard modelStore.isInstalled(file) else { throw APIError.modelNotInstalled(spec.label) }
        activate(spec, file: file)   // settings に保存され、UI にも反映される
    }

    func apiStream(prompt: String, maxTokens: Int, stop: [String],
                   switchTo: String?) async throws -> AsyncThrowingStream<String, Error> {
        if let id = switchTo, id != settings.modelID { try apiSelectModel(id: id) }
        guard isCurrentModelInstalled else { throw APIError.modelNotInstalled(currentSpec.label) }
        try await ensureLoaded()
        guard let engine = translator.engine else { throw AppError.engineUnavailable }
        return engine.complete(prompt: prompt, maxTokens: maxTokens, stop: stop)
    }
}
