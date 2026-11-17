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

/// 編集した段落の訳を生成している間、その後ろの（変わっていない）段落に前回の訳を仮に並べる。
///
/// Kit の `translateDocument` は、生成中の段落より後ろの段落を、その段落が終わるまで返さない
/// （キャッシュにある段落も、次にモデルを呼ぶ直前か最後にまとめて返る）。そのままだと、文章の途中を編集したとき
/// 編集した段落の訳が流れている間だけ後ろの訳が消え、終わると戻る（ちらつく）。
/// 前回の訳のうち、原文が同じ段落の訳を後ろにつなげて表示しておく。
enum TailSplice {
    /// - Parameters:
    ///   - progressText: 途中経過の訳（Kit の `DocumentProgress.text`）
    ///   - progressSegments: その段落対応（原文側は `source`、訳側は `progressText` の UTF-16 位置）
    ///   - source: `translateDocument` に渡した原文
    ///   - previous: 前回の翻訳結果（表示していた原文・訳とその段落対応）。無ければそのまま返す
    /// - Returns: 表示する訳と段落対応（つなげた段落は `isComplete: true`）。つなげられる段落が無ければ入力のまま
    static func splice(progressText: String, progressSegments: [SegmentAlignment], source: String,
                       previous: OutputAlignment?) -> (text: String, segments: [SegmentAlignment]) {
        guard let previous, !progressSegments.isEmpty else { return (progressText, progressSegments) }

        // 前回の訳: 原文の段落 → その訳
        let oldSource = previous.source as NSString, oldTarget = previous.target as NSString
        var known: [String: String] = [:]
        for s in previous.segments where s.isComplete {
            guard s.sourceLocation >= 0, s.targetLocation >= 0,
                  s.sourceLocation + s.sourceLength <= oldSource.length,
                  s.targetLocation + s.targetLength <= oldTarget.length else { continue }
            let paragraph = oldSource.substring(with: NSRange(location: s.sourceLocation, length: s.sourceLength))
            if known[paragraph] == nil {
                known[paragraph] = oldTarget.substring(with: NSRange(location: s.targetLocation, length: s.targetLength))
            }
        }
        guard !known.isEmpty else { return (progressText, progressSegments) }

        // 新しい原文の段落（Kit と同じ区切り方）と、その前にある区切り（空行・翻訳しない空白だけの段落）
        var paragraphs: [(location: Int, text: String, separatorBefore: String)] = []
        var offset = 0
        var pendingSeparator = ""
        for segment in TextSegmenter.segments(source) {
            let piece: String
            switch segment {
            case .text(let s): piece = s
            case .separator(let s): piece = s
            }
            if DocumentAssembler.isTranslatable(segment) {
                paragraphs.append((offset, piece, pendingSeparator))
                pendingSeparator = ""
            } else {
                pendingSeparator += piece
            }
            offset += piece.utf16.count
        }

        // 途中経過に入っていない段落から、前回の訳がある限り続けてつなげる
        let next = progressSegments.count
        guard next < paragraphs.count else { return (progressText, progressSegments) }
        var text = progressText
        var segments = progressSegments
        var targetLength = (progressText as NSString).length
        for j in next..<paragraphs.count {
            guard let translation = known[paragraphs[j].text] else { break }
            let separator = paragraphs[j].separatorBefore
            text += separator
            targetLength += separator.utf16.count
            let length = translation.utf16.count
            segments.append(SegmentAlignment(sourceLocation: paragraphs[j].location,
                                             sourceLength: paragraphs[j].text.utf16.count,
                                             targetLocation: targetLength, targetLength: length,
                                             isComplete: true))
            text += translation
            targetLength += length
        }
        return (text, segments)
    }
}
