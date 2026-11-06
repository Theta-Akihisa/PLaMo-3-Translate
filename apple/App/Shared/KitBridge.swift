import Foundation
import Combine
import SwiftUI
import PlamoTranslateCore
import PlamoTranslateKit

// ============================================================
// このファイルだけが PlamoTranslateKit / Core の具体 API に触れる。
// Kit 側の名前が違っていたらここだけ直せばよい。
// 【仮定している Kit API（要確認）】
//  - ModelStore() / Translator() は引数なしで生成できる
//  - ModelStore.progress は [String: Double]（キー = ModelFile.file, 0...1）
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
    }

    let modelStore = ModelStore()
    let translator = Translator()

    // 設定（変更時に自動保存）
    @Published var settings: TranslationSettings {
        didSet { saveSettings() }
    }

    // 翻訳画面の状態
    @Published var sourceText = ""
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

    private var sinks = Set<AnyCancellable>()
    private var translateTask: Task<Void, Never>?
    private var loadTask: Task<Void, Error>?
    private var loadedKey: String?

    init() {
        let d = UserDefaults.standard
        var s: TranslationSettings = d.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(TranslationSettings.self, from: $0) } ?? TranslationSettings()
        if ModelCatalog.spec(id: s.modelID) == nil {
            s.modelID = ModelCatalog.defaultModel.id
            s.quant = ModelCatalog.defaultModel.defaultQuant
        }
        self.settings = s
        self.quantChoices = (d.dictionary(forKey: Keys.quantChoices) as? [String: String]) ?? [:]
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

    func progress(for file: ModelFile) -> Double? { modelStore.progress[file.file] }

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
        do { try await modelStore.importLocalFile(url: url) } catch { errorMessage = error.localizedDescription }
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
        if let t = targetLang {
            s.targetLang = t
            if t != "ja" { s.form = nil }
        }
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

    func startTranslation() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isTranslating else { return }
        isTranslating = true
        errorMessage = nil
        outputText = ""
        let target = settings.targetLang
        let source = settings.sourceLang
        translateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.performTranslation(text: text, useHistory: true) { [weak self] partial in
                    self?.outputText = partial
                }
                self.outputText = result
                self.addHistory(source: text, translation: result, sourceLang: source, targetLang: target)
            } catch is CancellationError {
                // ユーザー操作による中断。部分結果は残す
            } catch {
                if !Task.isCancelled { self.errorMessage = error.localizedDescription }
            }
            self.isTranslating = false
        }
    }

    func stopTranslation() {
        translateTask?.cancel()
    }

    func swapLanguages() {
        guard let src = settings.sourceLang else { return }
        let newSource = settings.targetLang == "ja(easy)" ? "ja" : settings.targetLang
        settings.sourceLang = newSource
        settings.targetLang = src
        if settings.targetLang != "ja" { settings.form = nil }
        if !outputText.isEmpty {
            sourceText = outputText
            outputText = ""
        }
    }

    // MARK: - 履歴

    private func addHistory(source: String, translation: String, sourceLang: String?, targetLang: String) {
        guard !translation.isEmpty, source.count <= 20_000 else { return }
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
        sourceText = entry.source
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

// MARK: - ローカル API 用バックエンド

extension AppModel: APIBackend {
    func apiHealth() -> APIHealth {
        switch translator.state {
        case .loading: return .loading
        case .ready: return .ok
        default: return isCurrentModelInstalled ? .ok : .noModel
        }
    }

    func apiStream(prompt: String, maxTokens: Int, stop: [String]) async throws -> AsyncThrowingStream<String, Error> {
        try await ensureLoaded()
        guard let engine = translator.engine else { throw AppError.engineUnavailable }
        return await engine.complete(prompt: prompt, maxTokens: maxTokens, stop: stop)
    }
}
