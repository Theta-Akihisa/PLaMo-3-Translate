import Foundation

/// 文書翻訳の訳文を段落ごとに組み立て、原文段落と訳文の対応（`SegmentAlignment`）を記録する。
///
/// 使い方（`Translator.translateDocument` と同じ流れ）:
/// ```swift
/// var doc = DocumentAssembler(source: text)
/// while let paragraph = doc.beginNextParagraph() {
///     var part = ""
///     for delta in stream(paragraph) { part += delta; yield(doc.snapshot(partial: part)) }
///     doc.complete(output: cleaned(part))
///     yield(doc.snapshot())
/// }
/// yield(doc.snapshot())   // 末尾の区切りまで含む最終結果
/// ```
///
/// 区切り（`.separator`）と空白のみの `.text` は翻訳せずそのまま訳文に入れ、対応は作らない。
/// 位置・長さはすべて UTF-16 コード単位（NSString / NSRange と同じ単位）で、
/// 原文側は `source`（= 全 Segment の連結）、訳文側は各 `Snapshot.text` を指す。
public struct DocumentAssembler: Sendable {
    /// ある時点の訳文全体と、その文字列に対する対応。
    public struct Snapshot: Sendable, Equatable {
        public var text: String
        public var alignment: [SegmentAlignment]
        public init(text: String, alignment: [SegmentAlignment]) {
            self.text = text
            self.alignment = alignment
        }
    }

    public let segments: [TextSegmenter.Segment]
    /// 完了した段落と区切りを連結した訳文（翻訳中の段落の途中結果は含まない）
    public private(set) var text = ""
    /// 完了した段落の対応（すべて `isComplete == true`）
    public private(set) var alignment: [SegmentAlignment] = []
    /// 翻訳中の段落の原文範囲（`beginNextParagraph` 後、`complete` 前のみ）
    private var currentSource: Range<Int>?
    /// 次に処理する Segment の添字
    private var nextIndex = 0
    /// `segments[nextIndex]` の原文上の開始位置（UTF-16）
    private var sourceOffset = 0
    /// `text` の長さ（UTF-16）
    private var targetOffset = 0

    public init(segments: [TextSegmenter.Segment]) {
        self.segments = segments
    }

    public init(source: String) {
        self.init(segments: TextSegmenter.segments(source))
    }

    /// 翻訳する Segment か（空白以外の文字を含む `.text`）。
    public static func isTranslatable(_ segment: TextSegmenter.Segment) -> Bool {
        if case .text(let s) = segment { return s.contains { !$0.isWhitespace } }
        return false
    }

    /// 翻訳対象の段落数。
    public var totalParagraphs: Int { segments.filter(Self.isTranslatable).count }

    /// 翻訳中の段落があるか。
    public var isParagraphInProgress: Bool { currentSource != nil }

    /// 次の翻訳対象段落を始め、その原文を返す。手前の区切り・空白のみの段落はそのまま `text` に加える。
    /// 翻訳対象が残っていなければ末尾の区切りまで `text` に加えて nil を返す。
    /// 前の段落が `complete` されていなければ、空の出力で完了させてから進む。
    public mutating func beginNextParagraph() -> String? {
        if currentSource != nil { complete(output: "") }
        while nextIndex < segments.count {
            let segment = segments[nextIndex]
            nextIndex += 1
            switch segment {
            case .text(let s) where Self.isTranslatable(segment):
                let length = s.utf16.count
                currentSource = sourceOffset..<(sourceOffset + length)
                sourceOffset += length
                return s
            case .text(let s), .separator(let s):
                append(s)
                sourceOffset += s.utf16.count
            }
        }
        return nil
    }

    /// 翻訳中の段落を `output` で完了する（空・打ち切りの出力も可）。翻訳中の段落が無ければ何もしない。
    /// `output` は最終的に訳文へ入る文字列そのもの（整形済み）を渡すこと。
    public mutating func complete(output: String) {
        guard let source = currentSource else { return }
        alignment.append(SegmentAlignment(
            sourceLocation: source.lowerBound, sourceLength: source.count,
            targetLocation: targetOffset, targetLength: output.utf16.count,
            isComplete: true))
        append(output)
        currentSource = nil
    }

    /// 現時点の訳文と対応。翻訳中の段落があれば、その途中結果 `partial` を末尾に加え、
    /// `isComplete == false` の要素（`targetLength` は `partial` の長さ）を含める。
    public func snapshot(partial: String = "") -> Snapshot {
        guard let source = currentSource else { return Snapshot(text: text, alignment: alignment) }
        let current = SegmentAlignment(
            sourceLocation: source.lowerBound, sourceLength: source.count,
            targetLocation: targetOffset, targetLength: partial.utf16.count,
            isComplete: false)
        return Snapshot(text: text + partial, alignment: alignment + [current])
    }

    private mutating func append(_ s: String) {
        text += s
        targetOffset += s.utf16.count
    }

    /// 一括で組み立てる（テストや、全訳文が揃っている場合向け）。
    /// - Parameters:
    ///   - outputs: 完了した段落の出力（文書順）。翻訳対象の段落数より少なくてよい。
    ///   - partial: 次の段落の途中結果。nil なら翻訳中の段落なし。
    /// - Returns: `outputs` が全段落分あり `partial` が nil なら末尾の区切りまで含む最終結果。
    ///   そうでなければ、最後の完了段落（または `partial`）までの途中経過。
    public static func assemble(source: String, outputs: [String], partial: String? = nil) -> Snapshot {
        var doc = DocumentAssembler(source: source)
        let total = doc.totalParagraphs
        for output in outputs {
            guard doc.beginNextParagraph() != nil else { break }
            doc.complete(output: output)
        }
        if let partial {
            if doc.beginNextParagraph() != nil { return doc.snapshot(partial: partial) }
        } else if outputs.count >= total {
            _ = doc.beginNextParagraph()   // 末尾の区切りを加える
        }
        return doc.snapshot()
    }
}
