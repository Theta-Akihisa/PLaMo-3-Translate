import Foundation
import PlamoTranslateCore

// 入力しながらの翻訳（翻訳画面）で、変わっていない部分を訳し直さないための純粋な処理。
// App/Tests/LiveTranslationTests.swift で検証する。

/// 短文の 1 回の翻訳（`translate`）と、段落ごとの翻訳（`translateDocument`）のどちらを使うか
enum TranslationRouting {
    /// この文字数を超える入力は常に段落ごとに翻訳する
    static let longTextThreshold = 1500

    /// 段落ごとに翻訳するか。
    /// - Parameters:
    ///   - text: 翻訳する文字列（前後の空白を除いたもの）
    ///   - incremental: 翻訳画面の翻訳。空行で区切った段落が 2 つ以上あれば、短くても段落ごとに翻訳する
    ///     （Kit が変わっていない段落の訳を使い回すので、途中を編集しても前の段落を訳し直さない）
    static func usesParagraphs(_ text: String, incremental: Bool, threshold: Int = longTextThreshold) -> Bool {
        if text.count > threshold { return true }
        return incremental && hasMultipleParagraphs(text)
    }

    /// 翻訳する段落（空行区切り）が 2 つ以上あるか（`TextSegmenter` と同じ区切り方）
    static func hasMultipleParagraphs(_ text: String) -> Bool {
        var count = 0
        for segment in TextSegmenter.segments(text) where segment.isText {
            count += 1
            if count >= 2 { return true }
        }
        return false
    }
}

/// 短文（1 段落）の訳の覚え書きのキー。Kit の段落キャッシュと同じキー
/// （原文・正規化した訳文言語／原文言語・文体・文脈・用語集・モデル・量子化。few-shot の履歴は含めない）。
/// `ParagraphTranslationCache.key(for:modelID:quant:)` で作る。
typealias TranslationMemoKey = ParagraphTranslationCache.Key

/// 入力しながらの翻訳で使う原文言語（「言語を検出」のとき）。
/// Kit の段落キャッシュのキーには実際に渡した原文言語が入るので、編集のたびに検出結果が
/// 「英語」⇄「不明（nil）」と揺れると、すべての段落がキャッシュに当たらなくなる。
/// そこで、検出に自信が無いときは直前に検出した言語を使い続け、別の言語をはっきり検出したときだけ切り替える。
/// 原文をクリア・置き換えたら忘れる。
struct StickySourceLanguage: Equatable {
    private(set) var current: String?

    /// - Parameter detected: いまの原文の検出結果（確信度が低い・未対応なら nil）
    /// - Returns: 翻訳に使う原文言語
    mutating func resolve(_ detected: String?) -> String? {
        if let detected { current = detected }
        return current
    }

    mutating func reset() {
        current = nil
    }
}

/// 直近の数件だけを覚える（最近使ったものを残す）。元に戻す（undo）などで同じ原文に戻ったとき、すぐに訳を出す
struct TranslationMemo<Key: Hashable, Value> {
    let capacity: Int
    /// 古い順（末尾が最近使ったもの）
    private(set) var entries: [(key: Key, value: Value)] = []

    init(capacity: Int) {
        self.capacity = max(capacity, 0)
    }

    var count: Int { entries.count }

    /// 見つかれば最近使ったものにする
    mutating func value(for key: Key) -> Value? {
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let e = entries.remove(at: i)
        entries.append(e)
        return e.value
    }

    /// 同じキーは置き換える。容量を超えたら最も長く使っていないものを捨てる
    mutating func insert(_ value: Value, for key: Key) {
        entries.removeAll { $0.key == key }
        guard capacity > 0 else { return }
        entries.append((key: key, value: value))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

/// 原文を編集した後も、新しい訳の途中経過が届くまで前の訳を（「更新中」として）表示しておくための判定
enum LiveOutputPolicy {
    /// 途中経過で訳文ペインを書き換えるか。
    /// - Parameters:
    ///   - text: 新しい訳の途中経過
    ///   - previous: 表示中の編集前の訳（前の訳を表示していなければ nil）
    /// - Returns: 前の訳を表示している間は、途中経過が空白だけ・前の訳の先頭部分のまま
    ///   （前の訳と同じ訳をなぞっている）なら false（訳文が一瞬消えたり縮んだりしないように）。
    ///   新しい訳が前の訳と違ってきたら true。翻訳が終われば、呼び出し側は結果で必ず書き換える
    static func acceptsProgress(_ text: String, previous: String?) -> Bool {
        guard let previous else { return true }
        guard text.contains(where: { !$0.isWhitespace }) else { return false }
        return !previous.utf16.starts(with: text.utf16)
    }
}
