#if canImport(llama)
import Foundation
import PlamoTranslateCore

public enum TranslatorError: LocalizedError {
    case noModel
    case modelNotInstalled(String)
    /// 出力がトークン上限（maxTokens またはコンテキストの残り）に達し、訳文が途中で切れた
    case outputTruncated

    public var errorDescription: String? {
        switch self {
        case .noModel: return "モデルが読み込まれていません。"
        case .modelNotInstalled(let n): return "モデル \(n) がダウンロードされていません。"
        case .outputTruncated:
            return "出力が最大トークン数に達したため、訳文が途中で打ち切られました。入力を短く分けるか、最大トークン数を増やしてください。"
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
    /// load / unload のたびに増える。古い load は自分の世代が最新でなくなったら中止する
    private var loadGeneration = 0
    /// 最後に開始した load / unload の処理。次の load / unload はこれの完了を待ってから始める（直列化）
    private var lifecycle: Task<Void, Never>?

    public init(store: ModelStore) { self.store = store }
    public convenience init() { self.init(store: ModelStore()) }

    // MARK: - Load

    /// モデルを読み込む。
    ///
    /// - ファイルが無ければ、現在のエンジンはそのままで `modelNotInstalled` を投げる。
    /// - load / unload は直列化され、後から呼ばれたものが優先される。追い越された load は
    ///   `CancellationError` を投げる（呼び出し元タスクのキャンセルでも同様）。
    /// - 新しいエンジンを作る前に、旧エンジンの生成を中止して停止を待ち、メモリを解放する
    ///   （2 つのモデルが同時にメモリに載ることはない）。
    public func load(model: ModelSpec, quant: String? = nil, contextLength: Int = 8192) async throws {
        let file = model.file(quant: quant)
        guard store.isInstalled(file) else {
            throw TranslatorError.modelNotInstalled("\(model.label) \(file.quant)")
        }
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        let previous = lifecycle
        let url = store.localURL(for: file)
        let modelID = model.id
        let work: Task<Void, Error> = Task { @MainActor in
            _ = await previous?.value
            try await self.performLoad(generation: generation, modelID: modelID, url: url, contextLength: contextLength)
        }
        lifecycle = Task { _ = await work.result }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func isCurrentLoad(_ generation: Int) -> Bool {
        generation == loadGeneration && !Task.isCancelled
    }

    private func performLoad(generation: Int, modelID: String, url: URL, contextLength: Int) async throws {
        do {
            guard isCurrentLoad(generation) else { throw CancellationError() }
            // 旧エンジンの生成を止め、停止を待ってから解放する
            if let old = engine {
                engine = nil
                loadedModelID = nil
                await old.shutdown()
            }
            guard isCurrentLoad(generation) else { throw CancellationError() }
            let e = try await Task.detached(priority: .userInitiated) {
                try LlamaEngine(modelURL: url, contextLength: contextLength)
            }.value
            // 読み込み中に別の load / unload が始まっていたら（またはキャンセルされたら）、この結果は捨てる
            guard isCurrentLoad(generation) else {
                await e.shutdown()
                throw CancellationError()
            }
            engine = e
            loadedModelID = modelID
            state = .ready(modelID: modelID)
        } catch {
            // 追い越された場合、state は新しい load / unload が管理する
            if generation == loadGeneration {
                if error is CancellationError {
                    // キャンセルされた load: 旧エンジンが残っていればその状態に戻す
                    if let id = loadedModelID { state = .ready(modelID: id) } else { state = .noModel }
                } else {
                    state = .error(error.localizedDescription)
                }
            }
            throw error
        }
    }

    /// エンジンを解放する。読み込み中の load は中止され（`CancellationError`）、
    /// 実行中の生成は中断される。メモリの解放はバックグラウンドで完了し、次の load はその完了を待つ。
    public func unload() {
        loadGeneration += 1
        let old = engine
        engine = nil
        loadedModelID = nil
        state = .noModel
        let previous = lifecycle
        lifecycle = Task {
            _ = await previous?.value
            await old?.shutdown()
        }
    }

    // MARK: - Translate

    /// 1 リクエスト（1 セグメント）を翻訳し、テキスト差分をストリームする。
    /// 先頭の空白は取り除く。末尾の空白・停止文字列は差分には含まれない（停止文字列は保留して捨てる）。
    /// `request.history` はコンテキストに収まるよう古いものから削る。
    /// 出力がトークン上限で切れた場合は、全差分を流したあと `TranslatorError.outputTruncated` を投げて終わる。
    public func translate(_ request: TranslationRequest, maxTokens: Int = 2048) -> AsyncThrowingStream<String, Error> {
        guard let engine else {
            return AsyncThrowingStream { $0.finish(throwing: TranslatorError.noModel) }
        }
        do { _ = try PFML3.buildPrompt(request) }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var started = false
                var reason: FinishReason?
                do {
                    let fitted = try await Self.fitHistory(request, engine: engine, maxTokens: maxTokens)
                    let prompt = try PFML3.buildPrompt(fitted)
                    for try await event in engine.completeEvents(prompt: prompt, maxTokens: maxTokens, stop: PFML3.stopStrings) {
                        switch event {
                        case .text(let delta):
                            var d = Substring(delta)
                            if !started {
                                d = d.drop(while: { $0.isWhitespace })
                                if d.isEmpty { continue }
                                started = true
                            }
                            continuation.yield(String(d))
                        case .finished(let r):
                            reason = r
                        }
                    }
                    if reason == .length {
                        continuation.finish(throwing: TranslatorError.outputTruncated)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// history があれば、プロンプト + 生成用の予約がコンテキストに収まるまで古い順に削る。
    private nonisolated static func fitHistory(_ request: TranslationRequest, engine: LlamaEngine,
                                               maxTokens: Int) async throws -> TranslationRequest {
        guard !request.history.isEmpty else { return request }
        return try await PromptBudget.fitHistory(request, contextLength: engine.contextLength, maxTokens: maxTokens) {
            try await engine.tokenCount(of: $0)
        }
    }

    /// 全文を翻訳して返す（ストリームを読み切る）。出力が切れた場合は `TranslatorError.outputTruncated`。
    public func translateOnce(_ request: TranslationRequest, maxTokens: Int = 2048) async throws -> String {
        var out = ""
        for try await d in translate(request, maxTokens: maxTokens) { out += d }
        return PFML3.cleanOutput(out)
    }

    /// 文書を空行区切りの段落に分けて順に翻訳する。
    /// `useHistory` が有効なら直前 `historyLimit` 件の（原文, 訳文）を history として渡す
    /// （コンテキストに収まらない分は古い順に削る）。
    /// 各要素は「現時点で組み立て済みの全訳文」（区切りは原文のまま保持）。
    /// 出力が上限で切れた段落は途中までの訳を残して次の段落へ進み、`truncatedParagraphs` で報告する
    /// （その段落は history に加えない）。
    public func translateDocument(text: String, settings: TranslationSettings) -> AsyncThrowingStream<DocumentProgress, Error> {
        let segments = TextSegmenter.segments(text)
        let total = segments.filter { $0.isText }.count
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                var assembled = ""
                var done = 0
                var truncatedCount = 0
                var history: [HistoryPair] = []
                func progress(_ text: String, finished: Bool = false) -> DocumentProgress {
                    DocumentProgress(text: text, totalParagraphs: total, completedParagraphs: done,
                                     isFinished: finished, truncatedParagraphs: truncatedCount)
                }
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
                            var truncated = false
                            do {
                                for try await d in self.translate(req, maxTokens: settings.maxTokens) {
                                    part += d
                                    continuation.yield(progress(assembled + part))
                                }
                            } catch TranslatorError.outputTruncated {
                                truncated = true
                            }
                            let cleaned = PFML3.cleanOutput(part)
                            assembled += cleaned
                            done += 1
                            if truncated {
                                truncatedCount += 1
                            } else if !cleaned.isEmpty {
                                history.append(HistoryPair(source: src, translation: cleaned))
                            }
                            continuation.yield(progress(assembled))
                        }
                    }
                    continuation.yield(progress(assembled, finished: true))
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
