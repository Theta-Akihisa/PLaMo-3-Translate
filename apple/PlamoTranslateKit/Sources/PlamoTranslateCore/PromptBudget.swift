import Foundation

/// プロンプトと生成のトークン予算。history（直前の原文・訳文）をコンテキストに収まるよう間引く。
public enum PromptBudget {
    /// 生成用に確保するトークン数。原文のトークン数の 2 倍 + 64（最低 256）を目安とし、`maxTokens` を上限とする。
    public static func outputReserve(textTokens: Int, maxTokens: Int) -> Int {
        min(max(maxTokens, 0), max(256, textTokens * 2 + 64))
    }

    /// `request.history` を古いものから削り、「プロンプトのトークン数 + 生成用の予約」が
    /// `contextLength` に収まる最大件数（新しい側）だけ残したリクエストを返す。
    ///
    /// history を全て落としても収まらない場合は history なしのリクエストを返す
    /// （プロンプト自体が収まらなければ、推論側が `promptTooLong` を投げる）。
    /// - Parameter countTokens: プロンプト文字列のトークン数（BOS を含む、推論時と同じ数え方）。
    public static func fitHistory(
        _ request: TranslationRequest,
        contextLength: Int,
        maxTokens: Int,
        countTokens: (String) async throws -> Int
    ) async throws -> TranslationRequest {
        let all = request.history
        guard !all.isEmpty else { return request }

        let textTokens = try await countTokens(request.text)
        let reserve = outputReserve(textTokens: textTokens, maxTokens: maxTokens)
        // 推論側はプロンプト + 1 < n_ctx を要求し、生成予算は n_ctx - プロンプト - 1。
        let limit = contextLength - 1 - reserve

        func with(_ k: Int) -> TranslationRequest {
            var r = request
            r.history = Array(all.suffix(k))
            return r
        }

        if try await countTokens(PFML3.buildPrompt(request)) <= limit { return request }
        // history の件数に対してトークン数は単調増加なので、収まる最大件数を二分探索する。
        var lo = 0, hi = all.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if try await countTokens(PFML3.buildPrompt(with(mid))) <= limit {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return with(best)
    }
}
