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

/// llama.cpp のモデル／コンテキストを 1 つ保持する。actor なのでリクエストは直列化される。
public actor LlamaEngine {
    // C ポインタは init で設定後、actor 内からのみ使う（deinit で解放）。
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
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
        llama_sampler_free(sampler)
        llama_free(ctx)
        llama_model_free(model)
    }

    // MARK: - Tokenize / detokenize

    private func tokenize(_ text: String) throws -> [llama_token] {
        let utf8Count = text.utf8.count
        var cap = utf8Count + 16
        var buf = [llama_token](repeating: 0, count: cap)
        var n = llama_tokenize(vocab, text, Int32(utf8Count), &buf, Int32(cap), true, true)
        if n < 0 {
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

    /// プロンプトを補完し、UTF-8 として完結したテキスト差分を流す。
    /// ストリームの Task をキャンセル（または購読を終了）すると生成を中断する。
    /// `prompt + maxTokens` がコンテキストを超える場合は maxTokens を切り詰め、
    /// プロンプト自体が収まらなければ `promptTooLong` を投げる。
    public nonisolated func complete(prompt: String, maxTokens: Int, stop: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                do {
                    try await self.run(prompt: prompt, maxTokens: maxTokens, stop: stop) { delta in
                        continuation.yield(delta)
                    }
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

    private func run(prompt: String, maxTokens: Int, stop: [String], emit: @Sendable (String) -> Void) throws {
        var tokens = try tokenize(prompt)
        let nCtx = Int(llama_n_ctx(ctx))
        guard tokens.count + 1 < nCtx else {
            throw LlamaEngineError.promptTooLong(promptTokens: tokens.count, contextLength: nCtx)
        }
        let budget = min(maxTokens, nCtx - tokens.count - 1)
        guard budget > 0 else { return }

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

        var pending = [UInt8]()   // UTF-8 として未完結 or 停止文字列の接頭辞候補のバイト列
        let stopBytes = stop.map { Array($0.utf8) }
        var generated = 0

        func flush(final: Bool) -> Bool {
            // 停止文字列が見つかれば、その手前までを出して true（終了）を返す
            if let (idx, _) = Self.findStop(in: pending, stops: stopBytes) {
                let head = Array(pending[..<idx])
                if !head.isEmpty { emit(String(decoding: head, as: UTF8.self)) }
                pending.removeAll()
                return true
            }
            // 停止文字列の接頭辞になり得る末尾は保留
            var hold = final ? 0 : Self.longestStopPrefixSuffix(pending, stops: stopBytes)
            // 不完全なマルチバイト末尾も保留
            if !final { hold = max(hold, Self.incompleteUTF8Tail(pending)) }
            let cut = pending.count - min(hold, pending.count)
            if cut > 0 {
                emit(String(decoding: pending[..<cut], as: UTF8.self))
                pending.removeFirst(cut)
            }
            return false
        }

        while generated < budget {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            generated += 1
            pending.append(contentsOf: piece(token))
            if flush(final: false) { return }
            if generated >= budget { break }

            var t = token
            let rc: Int32 = withUnsafeMutablePointer(to: &t) { p in
                llama_decode(ctx, llama_batch_get_one(p, 1))
            }
            if rc != 0 { throw LlamaEngineError.decodeFailed(rc) }
        }
        _ = flush(final: true)
    }

    // MARK: - Buffer helpers (pure)

    static func findStop(in bytes: [UInt8], stops: [[UInt8]]) -> (Int, Int)? {
        var best: (Int, Int)? = nil
        for (si, s) in stops.enumerated() where !s.isEmpty && bytes.count >= s.count {
            for i in 0...(bytes.count - s.count) where Array(bytes[i..<(i + s.count)]) == s {
                if best == nil || i < best!.0 { best = (i, si) }
                break
            }
        }
        return best
    }

    /// bytes の末尾が、いずれかの停止文字列の（真の）接頭辞と一致する最大長。
    static func longestStopPrefixSuffix(_ bytes: [UInt8], stops: [[UInt8]]) -> Int {
        var best = 0
        for s in stops where s.count > 1 {
            let maxK = min(s.count - 1, bytes.count)
            if maxK <= best { continue }
            for k in stride(from: maxK, to: best, by: -1) where Array(bytes[(bytes.count - k)...]) == Array(s[..<k]) {
                best = k
                break
            }
        }
        return best
    }

    /// 末尾の不完全な UTF-8 シーケンスのバイト数（0 なら完結）。
    static func incompleteUTF8Tail(_ bytes: [UInt8]) -> Int {
        var i = bytes.count - 1
        var cont = 0
        while i >= 0 && cont < 3 && (bytes[i] & 0xC0) == 0x80 { cont += 1; i -= 1 }
        guard i >= 0 else { return 0 }
        let lead = bytes[i]
        let need: Int
        if lead & 0x80 == 0 { need = 1 }
        else if lead & 0xE0 == 0xC0 { need = 2 }
        else if lead & 0xF0 == 0xE0 { need = 3 }
        else if lead & 0xF8 == 0xF0 { need = 4 }
        else { return 0 }
        return (cont + 1) < need ? cont + 1 : 0
    }
}
#endif
