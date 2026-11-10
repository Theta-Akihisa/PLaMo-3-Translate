#if canImport(llama)
import Foundation
import llama
import PlamoTranslateCore

public enum LlamaEngineError: LocalizedError {
    case modelLoadFailed(String)
    case contextInitFailed
    case tokenizeFailed
    case promptTooLong(promptTokens: Int, contextLength: Int)
    case decodeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let p): return "モデルを読み込めませんでした: \(p)"
        case .contextInitFailed: return "推論コンテキストの作成に失敗しました（メモリ不足の可能性があります）。"
        case .tokenizeFailed: return "プロンプトのトークナイズに失敗しました。"
        case .promptTooLong(let n, let c): return "入力が長すぎます（\(n) トークン / コンテキスト \(c)）。"
        case .decodeFailed(let c): return "推論に失敗しました（コード \(c)）。"
        }
    }
}

/// 生成が終わった理由。
public enum FinishReason: String, Sendable {
    /// EOG トークンまたは停止文字列で終わった
    case stop
    /// トークン予算（`maxTokens`、またはコンテキストの残り）を使い切った（出力は途中で切れている）
    case length
}

/// `LlamaEngine.completeEvents` が流すイベント。
public enum CompletionEvent: Sendable {
    /// UTF-8 として完結したテキスト差分（停止文字列は含まない）
    case text(String)
    /// 生成の終了。正常終了時に必ず最後に 1 回だけ流れる
    case finished(FinishReason)
}

/// 実行中の生成タスクの登録簿（nonisolated な `completeEvents` から使うのでロックで保護する）。
private final class GenerationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// 閉じていなければ `make` でタスクを作って登録する（閉じていれば nil）。
    /// タスク側の `remove` はこのロックを待つので、登録より先に削除されることはない。
    func start(_ make: (UUID) -> Task<Void, Never>) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        let id = UUID()
        let task = make(id)
        tasks[id] = task
        return task
    }

    func remove(_ id: UUID) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }

    /// 以降の登録を拒否し、実行中のタスクを返す。
    func close() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return Array(tasks.values)
    }
}

/// llama.cpp のモデル／コンテキストを 1 つ保持する。actor なのでリクエストは直列化される。
public actor LlamaEngine {
    // C ポインタは init で設定後、actor 内からのみ使う（shutdown または deinit で解放）。
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    /// shutdown で C 側のリソースを解放済みか
    private var released = false
    private nonisolated let registry = GenerationRegistry()
    public nonisolated let contextLength: Int

    /// static let は遅延・スレッドセーフに 1 回だけ評価される。
    private static let backendInitialized: Void = { llama_backend_init() }()

    private static func ensureBackend() { _ = backendInitialized }

    public init(modelURL: URL, contextLength: Int = 8192, gpuLayers: Int32 = 99, threads: Int? = nil) throws {
        Self.ensureBackend()

        var mp = llama_model_default_params()
        mp.n_gpu_layers = gpuLayers
        guard let m = llama_model_load_from_file(modelURL.path, mp) else {
            throw LlamaEngineError.modelLoadFailed(modelURL.lastPathComponent)
        }

        let nThreads = Int32(max(1, min(threads ?? (ProcessInfo.processInfo.activeProcessorCount - 1), 8)))
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextLength)
        cp.n_batch = UInt32(max(512, min(contextLength, 2048)))
        cp.n_ubatch = min(cp.n_batch, 512)
        cp.n_threads = nThreads
        cp.n_threads_batch = nThreads
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw LlamaEngineError.contextInitFailed
        }

        let sp = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sp)!
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())

        self.model = m
        self.ctx = c
        self.vocab = llama_model_get_vocab(m)!
        self.sampler = chain
        self.contextLength = Int(llama_n_ctx(c))
    }

    deinit {
        if !released {
            llama_sampler_free(sampler)
            llama_free(ctx)
            llama_model_free(model)
        }
    }

    // MARK: - Lifecycle

    /// 実行中・待機中の生成をすべて中止して停止を待ち、llama.cpp のモデル／コンテキストを解放する。
    /// 以降の生成・トークン数計算は `CancellationError` で失敗する。何度呼んでもよい。
    /// 戻った時点でモデルのメモリは解放済み（このインスタンスへの参照がどこかに残っていても）。
    public func shutdown() async {
        let tasks = registry.close()
        for t in tasks { t.cancel() }
        // 待っている間は actor が空くので、実行中・待機中の run はキャンセルを検知して抜けられる
        for t in tasks { await t.value }
        guard !released else { return }
        released = true
        llama_sampler_free(sampler)
        llama_free(ctx)
        llama_model_free(model)
    }

    // MARK: - Tokenize / detokenize

    private func tokenize(_ text: String) throws -> [llama_token] {
        let utf8Count = text.utf8.count
        guard utf8Count < Int(Int32.max) - 16 else { throw LlamaEngineError.tokenizeFailed }
        var cap = utf8Count + 16
        var buf = [llama_token](repeating: 0, count: cap)
        var n = llama_tokenize(vocab, text, Int32(utf8Count), &buf, Int32(cap), true, true)
        if n < 0 && n != Int32.min {   // INT32_MIN はオーバーフロー
            cap = Int(-n)
            buf = [llama_token](repeating: 0, count: cap)
            n = llama_tokenize(vocab, text, Int32(utf8Count), &buf, Int32(cap), true, true)
        }
        guard n >= 0 else { throw LlamaEngineError.tokenizeFailed }
        return Array(buf.prefix(Int(n)))
    }

    /// special=true: 制御トークン（<|plamo:tag|> など）も文字列として出力させ、停止判定に使う。
    private func piece(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        }
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    // MARK: - Public API

    /// テキストのトークン数（推論時と同じく BOS を含む）。プロンプトがコンテキストに収まるかの判定に使う。
    public func tokenCount(of text: String) throws -> Int {
        guard !released else { throw CancellationError() }
        return try tokenize(text).count
    }

    /// プロンプトを補完し、UTF-8 として完結したテキスト差分を `.text` で流す。
    /// 正常終了時は最後に `.finished` をちょうど 1 回流す。トークン予算（`maxTokens`、または
    /// コンテキストの残り）を EOG・停止文字列より先に使い切った場合は `.finished(.length)`
    /// （`maxTokens <= 0` も `.length`）。プロンプト自体が収まらなければ `promptTooLong` を投げる。
    /// ストリームの購読を終了（またはそのタスクをキャンセル）すると生成を中断する。
    /// `shutdown()` で中断された場合は `CancellationError` を投げる。
    public nonisolated func completeEvents(prompt: String, maxTokens: Int, stop: [String]) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let registry = self.registry
            let task = registry.start { id in
                Task.detached(priority: .userInitiated) { [self] in
                    defer { registry.remove(id) }
                    do {
                        try await self.run(prompt: prompt, maxTokens: maxTokens, stop: stop) { event in
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            guard let task else {
                // shutdown 済み
                continuation.finish(throwing: CancellationError())
                return
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `completeEvents` のテキスト差分だけを流す版（終了理由が不要な場合）。
    /// `prompt + maxTokens` がコンテキストを超える場合は maxTokens を切り詰め、
    /// プロンプト自体が収まらなければ `promptTooLong` を投げる。
    public nonisolated func complete(prompt: String, maxTokens: Int, stop: [String]) -> AsyncThrowingStream<String, Error> {
        let events = completeEvents(prompt: prompt, maxTokens: maxTokens, stop: stop)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case .text(let s) = event { continuation.yield(s) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(prompt: String, maxTokens: Int, stop: [String], emit: @Sendable (CompletionEvent) -> Void) throws {
        guard !released else { throw CancellationError() }
        try Task.checkCancellation()
        var tokens = try tokenize(prompt)
        let nCtx = Int(llama_n_ctx(ctx))
        guard tokens.count + 1 < nCtx else {
            throw LlamaEngineError.promptTooLong(promptTokens: tokens.count, contextLength: nCtx)
        }
        let budget = min(maxTokens, nCtx - tokens.count - 1)
        // 予算 0 を空の「成功」にしない（打ち切り扱い）
        guard budget > 0 else { emit(.finished(.length)); return }

        // 前回のリクエストの KV を破棄
        llama_memory_clear(llama_get_memory(ctx), true)
        llama_sampler_reset(sampler)

        let nBatch = Int(llama_n_batch(ctx))
        var decoded = 0
        // プロンプトを n_batch ごとに分割して投入（最後のチャンクの末尾 logits を使う）
        while decoded < tokens.count {
            try Task.checkCancellation()
            let end = min(decoded + nBatch, tokens.count)
            let rc: Int32 = tokens.withUnsafeMutableBufferPointer { p in
                let batch = llama_batch_get_one(p.baseAddress! + decoded, Int32(end - decoded))
                return llama_decode(ctx, batch)
            }
            if rc != 0 { throw LlamaEngineError.decodeFailed(rc) }
            decoded = end
        }

        var decoder = StopSequenceDecoder(stop: stop)
        var generated = 0
        var reason = FinishReason.length

        while generated < budget {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { reason = .stop; break }
            generated += 1
            let text = decoder.feed(piece(token))
            if !text.isEmpty { emit(.text(text)) }
            if decoder.isStopped { emit(.finished(.stop)); return }
            if generated >= budget { break }   // 予算切れ（reason は .length のまま）

            var t = token
            let rc: Int32 = withUnsafeMutablePointer(to: &t) { p in
                llama_decode(ctx, llama_batch_get_one(p, 1))
            }
            if rc != 0 { throw LlamaEngineError.decodeFailed(rc) }
        }
        let rest = decoder.flush()
        if !rest.isEmpty { emit(.text(rest)) }
        emit(.finished(reason))
    }
}
#endif
