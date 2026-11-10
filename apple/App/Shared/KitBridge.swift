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
//  - LlamaEngine.completeEvents(prompt:maxTokens:stop:) → CompletionEvent（.text / .finished(FinishReason)）
//  - TranslatorError.outputTruncated（translate が全文を流した後、上限で切れていたら投げる）
//  - DocumentProgress.truncatedParagraphs
//  - Translator.load は新しい load に置き換えられると CancellationError を投げる
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

/// 長さの上限（最大トークン数）で訳文が途中で切れたときの警告
enum TruncationWarning {
    static let single = "訳文が長さの上限で途中で切れています。設定の最大トークン数を増やすか、文を分けてください。"

    static func document(paragraphs n: Int) -> String {
        "\(n) 個の段落で訳文が長さの上限で途中で切れています。設定の最大トークン数を増やすか、段落を分けてください。"
    }
}

/// performTranslation の結果
struct TranslationOutput: Equatable, Sendable {
    var text: String
    /// 長さの上限で途中で切れた段落の数（短文の翻訳では 0 か 1）
    var truncatedParagraphs: Int = 0
    /// 段落ごとに翻訳した（長文）
    var isDocument = false
    /// 実際に使った原文言語（明示 or 検出。不明なら nil）
    var sourceLang: String?
    /// 実際に使った訳文言語
    var targetLang: String = ""

    var isTruncated: Bool { truncatedParagraphs > 0 }

    /// 途中で切れていれば UI に出す警告
    var warning: String? {
        guard isTruncated else { return nil }
        return isDocument ? TruncationWarning.document(paragraphs: truncatedParagraphs) : TruncationWarning.single
    }
}

/// 外部（URL スキーム・クイック翻訳パネル）から渡されたテキストで置き換える前の原文
struct ReplacedSource: Equatable {
    var previousText: String
    /// 置き換えた依頼元（例: 「URL スキーム」）
    var origin: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// この文字数を超える入力は translateDocument（段落分割）で翻訳する
    static let longTextThreshold = 1500
    static let historyCapacity = 100
    /// 入力しながらの翻訳結果は、この時間そのままなら履歴に記録する（途中経過で履歴を埋めないため）
    static let historySettleNanos: UInt64 = 4_000_000_000
    /// 履歴の先頭がこの時間内の同じ文章の編集版なら、追加せずに置き換える
    static let historyMergeWindow: TimeInterval = 10 * 60
    /// 履歴ファイルへの書き込みをまとめる間隔
    static let historySaveDelayNanos: UInt64 = 1_000_000_000

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
    /// 訳文が長さの上限で途中で切れたなどの警告（訳文は表示したまま）
    @Published private(set) var warningMessage: String?
    /// 外部から渡されたテキストで原文を置き換えたときの「元に戻す」用
    @Published private(set) var replacedSource: ReplacedSource?

    // ファイル読み込み（.txt / .md / .rtf / .pdf）
    /// ファイル選択ダイアログを開く要求（⌘O・ボタンから）
    @Published var showFileImporter = false
    /// 読み込み中の進み具合（PDF のページ単位, 0...1）。nil なら読み込み中でない
    @Published private(set) var fileLoadProgress: Double?
    /// 直前に読み込んだファイルの説明（原文を編集すると消える）
    @Published private(set) var loadedFileSummary: String?
    private var fileLoadTask: Task<Void, Never>?
    private var assigningFileText = false
    /// replaceSource 中（ペースト・外部テキスト・ファイル・言語の入れ替えなど、入力以外での置き換え）
    private var replacingSource = false

    // モデル管理の状態
    @Published private(set) var downloading: Set<String> = []
    @Published var downloadErrors: [String: String] = [:]
    @Published var quantChoices: [String: String] {
        didSet { UserDefaults.standard.set(quantChoices, forKey: Keys.quantChoices) }
    }

    @Published private(set) var history: [HistoryEntry]
    private let historyFile: HistoryFile
    private var historySaveTask: Task<Void, Never>?
    /// まだ履歴に記録していない最新の翻訳結果（落ち着いたら記録）
    private var pendingHistory: HistoryEntry?
    private var historySettleTask: Task<Void, Never>?

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
    /// 進行中のモデル読み込み（UI・クイック翻訳・API で共有する）
    private var loadTask: Task<Void, Error>?
    /// loadTask が読み込んでいるモデルのキー
    private var loadTaskKey: String?
    /// loadTask を識別する番号（古いタスクが新しいタスクの状態を消さないように）
    private var loadGeneration = 0
    /// 読み込み済みのモデルのキー（読み込みタスクの中で設定する）
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
        let historyFile = HistoryFile()
        self.historyFile = historyFile
        if let saved = historyFile.load() {
            self.history = saved
        } else {
            // 旧バージョン: UserDefaults に保存していた履歴をファイルへ移す
            let legacy = d.data(forKey: Keys.history)
                .flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
            self.history = legacy
            if !legacy.isEmpty { historyFile.saveNow(legacy) }
            // 書き込めたときだけ旧データを消す（失敗したら次回また移す）
            if legacy.isEmpty || historyFile.load() != nil { d.removeObject(forKey: Keys.history) }
        }

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

    private static func loadKey(_ modelID: String, _ quant: String, _ contextLength: Int) -> String {
        "\(modelID)|\(quant)|\(contextLength)"
    }

    /// 選択中のモデルを読み込む（読み込み済みなら何もしない）。
    /// UI・クイック翻訳・ローカル API から同時に呼ばれても、同じモデルなら 1 つの読み込みを共有する。
    /// 読み込み中に設定が変わって別の読み込みに置き換えられた場合は、その時点で必要なモデルを確かめ直す。
    func ensureLoaded() async throws {
        for _ in 0..<4 {
            let spec = currentSpec
            let file = currentFile
            guard modelStore.isInstalled(file) else { throw AppError.modelNotInstalled(spec.label) }
            let ctx = settings.contextLength
            let key = Self.loadKey(spec.id, file.quant, ctx)
            if loadedKey == key, translator.engine != nil { return }

            let task: Task<Void, Error>
            if let pending = loadTask, loadTaskKey == key {
                task = pending
            } else {
                task = startLoad(spec: spec, quant: file.quant, contextLength: ctx, key: key)
            }
            do {
                try await task.value
            } catch is CancellationError {
                // 呼び出し元自身が中断されたのでなければ、新しい読み込み（設定変更など）に置き換えられただけ
                try Task.checkCancellation()
                continue
            }
            try Task.checkCancellation()
            if loadedKey == key, translator.engine != nil { return }
            // 読み込みの間に設定が変わった・エンジンが解放された → もう一度確かめる
        }
        throw AppError.engineUnavailable
    }

    private func startLoad(spec: ModelSpec, quant: String, contextLength: Int, key: String) -> Task<Void, Error> {
        loadGeneration += 1
        let generation = loadGeneration
        loadedKey = nil   // Translator.load は前のエンジンを解放する
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                try await self.translator.load(model: spec, quant: quant, contextLength: contextLength)
                guard self.loadGeneration == generation else { return }
                self.loadTask = nil
                self.loadTaskKey = nil
                if self.translator.engine != nil { self.loadedKey = key }
            } catch {
                if self.loadGeneration == generation {
                    self.loadTask = nil
                    self.loadTaskKey = nil
                }
                throw error
            }
        }
        loadTask = task
        loadTaskKey = key
        return task
    }

    /// メモリ警告・モデル削除時にエンジンを解放する
    func releaseEngine() {
        stopTranslation()
        loadGeneration += 1
        loadTask = nil
        loadTaskKey = nil
        loadedKey = nil
        translator.unload()
    }

    /// iOS: バックグラウンド移行時は GPU を使えないので生成を止める
    func handleBackground() {
        stopTranslation()
        flushHistory()
    }

    // MARK: - 翻訳

    /// 履歴から few-shot に使う（原文, 訳文）の組。
    /// 原文言語・訳文言語の両方が一致するものだけを使い、いま翻訳する文章（とその編集前後の版）は除く。
    private func recentHistoryPairs(text: String, sourceLang: String?, target: String, limit: Int) -> [HistoryPair] {
        guard limit > 0, let sourceLang else { return [] }   // 原文言語が分からないときは使わない
        var out: [HistoryPair] = []
        for e in history {
            if out.count >= limit { break }
            guard e.targetLang == target, e.source.count <= 600, e.translation.count <= 1200 else { continue }
            // 原文言語を明示していなかった古い履歴は、その場で検出する
            guard (e.sourceLang ?? e.detectedLang ?? LanguageDetector.detect(e.source)) == sourceLang else { continue }
            guard !HistoryRevision.isRevision(e.source, text) else { continue }
            out.append(HistoryPair(source: e.source, translation: e.translation))
        }
        return out.reversed()   // 古い順
    }

    /// 翻訳の中核。onPartial には累積テキストが渡される。UI・メニューバー・ショートカット・サービスで共用。
    /// 訳文が長さの上限で切れた場合も、途中までの訳文を返す（`TranslationOutput.isTruncated`）。
    func performTranslation(text: String,
                            targetLang: String? = nil,
                            useHistory: Bool = false,
                            onPartial: @escaping (String) -> Void = { _ in }) async throws -> TranslationOutput {
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
        try Task.checkCancellation()
        var acc = ""
        var truncated = 0
        let isDocument = text.count > Self.longTextThreshold
        if isDocument {
            do {
                for try await p in translator.translateDocument(text: text, settings: s) {
                    acc = p.text
                    truncated = p.truncatedParagraphs
                    onPartial(acc)
                }
            } catch TranslatorError.outputTruncated {
                truncated = max(truncated, 1)
            }
        } else {
            let pairs = (useHistory && s.useHistory)
                ? recentHistoryPairs(text: text, sourceLang: s.sourceLang, target: s.targetLang, limit: s.historyLimit)
                : []
            let req = TranslationRequest(text: text,
                                         targetLang: s.targetLang,
                                         sourceLang: s.sourceLang,
                                         form: s.targetLang == "ja" ? s.form : nil,
                                         context: s.context.isEmpty ? nil : s.context,
                                         glossary: s.glossary,
                                         history: pairs)
            do {
                for try await delta in translator.translate(req, maxTokens: s.maxTokens) {
                    acc += delta
                    onPartial(acc)
                }
            } catch TranslatorError.outputTruncated {
                // 全文を流し終えた後に投げられる。途中までの訳文は acc に入っている
                truncated = 1
            }
        }
        if Task.isCancelled { throw CancellationError() }
        return TranslationOutput(text: acc.trimmingCharacters(in: .whitespacesAndNewlines),
                                 truncatedParagraphs: truncated, isDocument: isDocument,
                                 sourceLang: s.sourceLang, targetLang: s.targetLang)
    }

    // MARK: ライブ翻訳

    private func sourceChanged(old: String) {
        if !assigningFileText { loadedFileSummary = nil }
        guard sourceText != old else { return }
        if !replacingSource { replacedSource = nil }   // 自分で編集したら「元に戻す」の案内は消す
        let isEmpty = sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 原文の置き換え・クリアなら直前の訳を履歴に記録し、入力途中の編集なら途中経過として捨てる
        if replacingSource || isEmpty {
            commitPendingHistory()
        } else {
            discardPendingHistory()
        }
        guard !suppressLive else { return }
        debounceTask?.cancel()
        stopTranslation()   // 編集されたら進行中の生成を中断
        if isEmpty {
            outputText = ""
            errorMessage = nil
            warningMessage = nil
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
            self.startTranslation(explicit: false)
        }
    }

    /// 言語・文体を変えたときの再翻訳
    func retranslateIfLive() {
        guard liveTranslate, !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        scheduleTranslation(immediate: true)
    }

    /// 入力以外で原文を置き換える（ペースト・外部テキスト・ファイル・言語の入れ替えなど）。すぐに翻訳する。
    /// - Parameter origin: 外部から渡されたテキストのとき、その依頼元。入力済みの原文を置き換えたら元に戻せるようにする。
    private func replaceSource(with text: String, origin: String? = nil) {
        let previous = sourceText
        replacingSource = true
        immediateNext = true
        sourceText = text
        immediateNext = false
        replacingSource = false
        if let origin, previous != text, !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            replacedSource = ReplacedSource(previousText: previous, origin: origin)
        }
    }

    /// クリップボードの内容を原文にして即翻訳（ペースト時は待たない）
    func pasteFromClipboard() {
        guard let s = Clipboard.paste(), !s.isEmpty else { return }
        if s == sourceText { startTranslation() } else { replaceSource(with: s) }
    }

    /// 外部（URL スキーム・クイック翻訳パネル等）から原文を渡して翻訳する。
    /// 入力済みの原文を置き換えた場合は、案内を出して元に戻せるようにする（`replacedSource`）。
    func translate(externalText: String, from origin: String) {
        if externalText == sourceText {
            if !liveTranslate || (outputText.isEmpty && !isTranslating) { startTranslation() }
            return
        }
        replaceSource(with: externalText, origin: origin)
        if !liveTranslate { startTranslation() }
    }

    /// 外部テキストで置き換える前の原文に戻す
    func undoSourceReplacement() {
        guard let r = replacedSource else { return }
        replacedSource = nil
        replaceSource(with: r.previousText)
        if !liveTranslate { startTranslation() }
    }

    func dismissSourceReplacementNotice() {
        replacedSource = nil
    }

    /// - Parameter explicit: 「翻訳」ボタン・⌘↩ など明示的な実行。結果をすぐ履歴に記録する
    ///   （入力しながらの自動翻訳は、結果がしばらくそのままのときだけ記録する）。
    func startTranslation(explicit: Bool = true) {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        translateTask?.cancel()
        runID += 1
        let id = runID
        isTranslating = true
        errorMessage = nil
        warningMessage = nil
        outputText = ""
        let source = settings.sourceLang
        translateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.performTranslation(text: text, useHistory: true) { [weak self] partial in
                    if let self, self.runID == id { self.outputText = partial }
                }
                if self.runID == id {
                    self.outputText = output.text
                    // 長さの上限で切れた訳は表示したまま警告し、履歴（＝次の翻訳の文脈）には残さない
                    self.warningMessage = output.warning
                    if !output.isTruncated {
                        let entry = HistoryEntry(source: text, translation: output.text,
                                                 sourceLang: source, targetLang: output.targetLang,
                                                 detectedLang: source == nil ? output.sourceLang : nil)
                        self.stageHistory(entry, settled: explicit)
                    }
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
    /// ファイル（.txt / .md / .rtf / .pdf）を読み込んで原文にする。PDF は段落に組み直し、スキャンページは文字認識する。
    func loadText(from url: URL) {
        fileLoadTask?.cancel()
        stopTranslation()
        errorMessage = nil
        fileLoadProgress = 0
        fileLoadTask = Task { [weak self] in
            do {
                let result = try await FileTextLoader.load(url: url) { p in
                    Task { @MainActor [weak self] in
                        if self?.fileLoadProgress != nil { self?.fileLoadProgress = p }
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.fileLoadProgress = nil
                self.assigningFileText = true
                self.replaceSource(with: result.text)
                self.assigningFileText = false
                self.loadedFileSummary = result.summary
            } catch is CancellationError {
                self?.fileLoadProgress = nil
            } catch {
                guard let self else { return }
                self.fileLoadProgress = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelFileLoad() {
        fileLoadTask?.cancel()
        fileLoadTask = nil
        fileLoadProgress = nil
    }

    func swapLanguages() {
        guard let src = settings.sourceLang ?? detectedLang else { return }
        let newSource = PFML3.normalizeLang(settings.targetLang) == "ja-easy" ? "ja" : settings.targetLang
        settings.sourceLang = newSource
        settings.targetLang = src
        if settings.targetLang != "ja" { settings.form = nil }
        if !outputText.isEmpty {
            replaceSource(with: outputText)
        }
    }

    // MARK: - 履歴

    /// 翻訳結果を履歴の候補にする。`settled` ならすぐ記録し、そうでなければ一定時間そのままなら記録する。
    private func stageHistory(_ entry: HistoryEntry, settled: Bool) {
        historySettleTask?.cancel()
        pendingHistory = entry
        if settled {
            commitPendingHistory()
            return
        }
        historySettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.historySettleNanos)
            guard !Task.isCancelled, let self else { return }
            self.commitPendingHistory()
        }
    }

    /// 表示中の訳を履歴に記録する（コピー・共有・保存、原文のクリア・置き換え、バックグラウンド移行時など）
    func commitPendingHistory() {
        historySettleTask?.cancel()
        historySettleTask = nil
        guard let entry = pendingHistory else { return }
        pendingHistory = nil
        addHistory(entry)
    }

    private func discardPendingHistory() {
        historySettleTask?.cancel()
        historySettleTask = nil
        pendingHistory = nil
    }

    private func addHistory(_ entry: HistoryEntry) {
        guard !entry.translation.isEmpty, entry.source.count <= 20_000 else { return }
        // 同じ原文、または直前に記録した原文の編集版（書き足し・手直し）なら、先頭を置き換える
        if let first = history.first, first.targetLang == entry.targetLang,
           first.source == entry.source
            || (entry.date.timeIntervalSince(first.date) < Self.historyMergeWindow
                && HistoryRevision.isRevision(first.source, entry.source)) {
            history.removeFirst()
        }
        history.insert(entry, at: 0)
        if history.count > Self.historyCapacity { history.removeLast(history.count - Self.historyCapacity) }
        scheduleHistorySave()
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        scheduleHistorySave()
    }

    func clearHistory() {
        discardPendingHistory()
        history = []
        scheduleHistorySave()
    }

    func restore(_ entry: HistoryEntry) {
        commitPendingHistory()
        suppressLive = true
        sourceText = entry.source
        suppressLive = false
        stopTranslation()
        outputText = entry.translation
        errorMessage = nil
        warningMessage = nil
        settings.sourceLang = entry.sourceLang
        settings.targetLang = entry.targetLang
    }

    /// 履歴の書き込みはまとめて、メインスレッドの外で行う
    private func scheduleHistorySave() {
        historySaveTask?.cancel()
        historySaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.historySaveDelayNanos)
            guard !Task.isCancelled, let self else { return }
            self.historySaveTask = nil
            self.historyFile.save(self.history)
        }
    }

    /// 未記録の訳を記録し、履歴をすぐにファイルへ書き込む（終了・バックグラウンド移行時）
    func flushHistory() {
        commitPendingHistory()
        guard historySaveTask != nil else { return }
        historySaveTask?.cancel()
        historySaveTask = nil
        historyFile.saveNow(history)
    }
}

/// 2 つの原文が「同じ文章の書き足し・手直し」かどうか
enum HistoryRevision {
    /// 共通の先頭 + 末尾が、長い方のこの割合以上なら同じ文章の編集とみなす
    static let minOverlap = 0.6

    static func isRevision(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y || x.hasPrefix(y) || y.hasPrefix(x) { return true }
        let ca = Array(x), cb = Array(y)
        let n = min(ca.count, cb.count)
        var prefix = 0
        while prefix < n, ca[prefix] == cb[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < n - prefix, ca[ca.count - 1 - suffix] == cb[cb.count - 1 - suffix] { suffix += 1 }
        return Double(prefix + suffix) >= minOverlap * Double(max(ca.count, cb.count))
    }
}

/// 翻訳履歴の保存先（Application Support/<バンドル ID>/history.json）。
/// エンコードと書き込みは専用のキューで行い、メインスレッドを止めない。
final class HistoryFile: Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "plamotranslate.history", qos: .utility)

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let folder = Bundle.main.bundleIdentifier ?? "PlamoTranslate"
        url = base.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("history.json")
    }

    /// 保存済みの履歴。ファイルが無ければ nil
    func load() -> [HistoryEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    /// バックグラウンドで書き込む（呼んだ順に書かれるので、最後の内容が残る）
    func save(_ entries: [HistoryEntry]) {
        let url = self.url
        queue.async { Self.write(entries, to: url) }
    }

    /// すぐに書き込む（それまでに頼んだ書き込みも済ませる）
    func saveNow(_ entries: [HistoryEntry]) {
        let url = self.url
        queue.sync { Self.write(entries, to: url) }
    }

    private static func write(_ entries: [HistoryEntry], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: [.atomic])
        } catch {
            // 書き込めなくても翻訳は続けられる（次回の保存で再試行）
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
        return translator.engine != nil
            && loadedKey == Self.loadKey(currentSpec.id, currentFile.quant, settings.contextLength)
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
                   switchTo: String?) async throws -> AsyncThrowingStream<APIStreamEvent, Error> {
        if let id = switchTo, id != settings.modelID { try apiSelectModel(id: id) }
        guard isCurrentModelInstalled else { throw APIError.modelNotInstalled(currentSpec.label) }
        try await ensureLoaded()
        guard let engine = translator.engine else { throw AppError.engineUnavailable }
        return AppModel.apiEvents(engine.completeEvents(prompt: prompt, maxTokens: maxTokens, stop: stop))
    }

    /// Kit の CompletionEvent を API 用のイベントに変換する（メインスレッドを経由しない）。
    /// プロンプト長超過は 400 invalid_request にする。
    private nonisolated static func apiEvents(
        _ inner: AsyncThrowingStream<CompletionEvent, Error>
    ) -> AsyncThrowingStream<APIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    for try await event in inner {
                        switch event {
                        case .text(let s):
                            continuation.yield(.text(s))
                        case .finished(let reason):
                            continuation.yield(.finished(reason == .length ? .length : .stop))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AppModel.apiError(for: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func apiError(for error: Error) -> Error {
        if let e = error as? LlamaEngineError, case .promptTooLong = e {
            return APIError.invalidRequest(e.localizedDescription)
        }
        return error
    }
}
