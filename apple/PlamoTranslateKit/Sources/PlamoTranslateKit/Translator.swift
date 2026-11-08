#if canImport(llama)
import Foundation
import PlamoTranslateCore

public enum TranslatorError: LocalizedError {
    case noModel
    case modelNotInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .noModel: return "モデルが読み込まれていません。"
        case .modelNotInstalled(let n): return "モデル \(n) がダウンロードされていません。"
        }
    }
}

public enum TranslatorState: Equatable, Sendable {
    case noModel
    case loading
    case ready(modelID: String)
    case error(String)
}

/// アプリ向けの高レベル API。エンジンへのリクエストは `LlamaEngine`（actor）で直列化される。
@MainActor
public final class Translator: ObservableObject {
    @Published public private(set) var state: TranslatorState = .noModel
    public let store: ModelStore
    public private(set) var engine: LlamaEngine?
    public private(set) var loadedModelID: String?
    private var loadGeneration = 0

    public init(store: ModelStore) { self.store = store }
    public convenience init() { self.init(store: ModelStore()) }

    // MARK: - Load

    /// 前のエンジンを解放してからモデルをバックグラウンドで読み込む。
    public func load(model: ModelSpec, quant: String? = nil, contextLength: Int = 8192) async throws {
        let file = model.file(quant: quant)
        loadGeneration += 1
        let generation = loadGeneration
        engine = nil
        loadedModelID = nil
        state = .loading

        guard store.isInstalled(file) else {
            let e = TranslatorError.modelNotInstalled("\(model.label) \(file.quant)")
            state = .error(e.localizedDescription)
            throw e
        }
        let url = store.localURL(for: file)
        do {
            let e = try await Task.detached(priority: .userInitiated) {
                try LlamaEngine(modelURL: url, contextLength: contextLength)
            }.value
            // 読み込み中に別の load が始まっていたら、この結果は捨てる
            guard generation == loadGeneration else { return }
            engine = e
            loadedModelID = model.id
            state = .ready(modelID: model.id)
        } catch {
            guard generation == loadGeneration else { throw error }
            state = .error(error.localizedDescription)
            throw error
        }
    }

    public func unload() {
        loadGeneration += 1
        engine = nil
        loadedModelID = nil
        state = .noModel
    }

    // MARK: - Translate

    /// 1 リクエスト（1 セグメント）を翻訳し、テキスト差分をストリームする。
    /// 先頭の空白は取り除く。末尾の空白・停止文字列は差分には含まれない（停止文字列は保留して捨てる）。
    public func translate(_ request: TranslationRequest, maxTokens: Int = 2048) -> AsyncThrowingStream<String, Error> {
        guard let engine else {
            return AsyncThrowingStream { $0.finish(throwing: TranslatorError.noModel) }
        }
        let prompt: String
        do { prompt = try PFML3.buildPrompt(request) }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }

        let inner = engine.complete(prompt: prompt, maxTokens: maxTokens, stop: PFML3.stopStrings)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var started = false
                do {
                    for try await delta in inner {
                        var d = Substring(delta)
                        if !started {
                            d = d.drop(while: { $0.isWhitespace })
                            if d.isEmpty { continue }
                            started = true
                        }
                        continuation.yield(String(d))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 全文を翻訳して返す（ストリームを読み切る）。
    public func translateOnce(_ request: TranslationRequest, maxTokens: Int = 2048) async throws -> String {
        var out = ""
        for try await d in translate(request, maxTokens: maxTokens) { out += d }
        return PFML3.cleanOutput(out)
    }

    /// 文書を空行区切りの段落に分けて順に翻訳する。
    /// `useHistory` が有効なら直前 `historyLimit` 件の（原文, 訳文）を history として渡す。
    /// 各要素は「現時点で組み立て済みの全訳文」（区切りは原文のまま保持）。
    public func translateDocument(text: String, settings: TranslationSettings) -> AsyncThrowingStream<DocumentProgress, Error> {
        let segments = TextSegmenter.segments(text)
        let total = segments.filter { $0.isText }.count
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                var assembled = ""
                var done = 0
                var history: [HistoryPair] = []
                do {
                    for seg in segments {
                        try Task.checkCancellation()
                        switch seg {
                        case .separator(let s):
                            assembled += s
                        case .text(let src):
                            let hist = settings.useHistory && settings.historyLimit > 0
                                ? Array(history.suffix(settings.historyLimit)) : []
                            let req = settings.makeRequest(text: src, history: hist)
                            var part = ""
                            for try await d in self.translate(req, maxTokens: settings.maxTokens) {
                                part += d
                                continuation.yield(DocumentProgress(
                                    text: assembled + part, totalParagraphs: total,
                                    completedParagraphs: done, isFinished: false))
                            }
                            let cleaned = PFML3.cleanOutput(part)
                            assembled += cleaned
                            done += 1
                            if !cleaned.isEmpty { history.append(HistoryPair(source: src, translation: cleaned)) }
                            continuation.yield(DocumentProgress(
                                text: assembled, totalParagraphs: total,
                                completedParagraphs: done, isFinished: false))
                        }
                    }
                    continuation.yield(DocumentProgress(
                        text: assembled, totalParagraphs: total, completedParagraphs: done, isFinished: true))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Device RAM

    public nonisolated static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// 端末の RAM が `minRamGB` を満たす（報告値は実容量より小さいので 10% の余裕を見る）モデル。
    public nonisolated static func recommendedModels(from catalog: [ModelSpec] = ModelCatalog.all) -> [ModelSpec] {
        catalog.filter { physicalMemoryGB >= Double($0.minRamGB) * 0.9 }
    }

    /// 警告が必要なら日本語メッセージを返す（例: iPhone で 8B）。
    public nonisolated static func memoryWarning(for model: ModelSpec) -> String? {
        let ram = physicalMemoryGB
        if ram < Double(model.minRamGB) * 0.9 {
            return String(format: "このモデルには RAM %d GB 以上を推奨します（この端末: 約 %.1f GB）。動作が不安定になる可能性があります。",
                          model.minRamGB, ram)
        }
        #if os(iOS)
        if model.size == "8b" {
            return "8B モデルは iPhone ではメモリ負荷が非常に高く、アプリが強制終了される場合があります。0.8B / 2B を推奨します。"
        }
        #endif
        return nil
    }
}
#endif
