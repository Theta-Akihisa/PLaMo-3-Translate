import Foundation
import CoreGraphics
import PlamoTranslateCore

// スクロール連動の純粋な計算（テキストビューに依存しない。App/Tests/ScrollSyncTests.swift で検証する）

// MARK: - 訳文と原文の段落対応

/// 原文ペイン・訳文ペインに表示中の文字列と、その段落対応（Kit の `SegmentAlignment`）。
/// オフセットはどちらも **表示中の文字列** の UTF-16 位置を指す（翻訳時の前後の空白の除去は補正済み）。
struct OutputAlignment: Equatable {
    /// 原文ペインに表示中の文字列（翻訳を始めたときの原文）
    let source: String
    /// 訳文ペインに表示中の文字列
    let target: String
    /// 翻訳した段落ごとの対応（順番どおり。生成中の段落は `isComplete == false`）
    let segments: [SegmentAlignment]
    /// source / target の UTF-16 の長さ
    let sourceLength: Int
    let targetLength: Int

    init(source: String, target: String, segments: [SegmentAlignment]) {
        self.source = source
        self.target = target
        self.segments = segments
        self.sourceLength = (source as NSString).length
        self.targetLength = (target as NSString).length
    }

    /// 安い比較から順に行う（同じ値のコピー同士なら文字列の比較は記憶域が同じなのですぐ済む）
    static func == (a: OutputAlignment, b: OutputAlignment) -> Bool {
        a.sourceLength == b.sourceLength && a.targetLength == b.targetLength
            && a.segments == b.segments && a.target == b.target && a.source == b.source
    }
}

/// KitBridge が受け取った文字列に手を加えたとき（前後の空白の除去）の段落対応の補正
enum AlignmentAdjust {
    /// `trimmingCharacters(in: .whitespacesAndNewlines)` で削られる先頭部分の長さ（UTF-16）
    static func leadingWhitespaceLength(_ s: String) -> Int {
        let ns = s as NSString
        let r = ns.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        return r.location == NSNotFound ? ns.length : r.location
    }

    /// 原文側を `source`、訳文側を `target` だけずらし、訳文側を `0...targetLength` に収める
    static func shifted(_ segments: [SegmentAlignment], source: Int, target: Int, targetLength: Int) -> [SegmentAlignment] {
        segments.map { s in
            let start = min(max(s.targetLocation + target, 0), targetLength)
            let end = min(max(s.targetLocation + s.targetLength + target, start), targetLength)
            return SegmentAlignment(sourceLocation: s.sourceLocation + source, sourceLength: s.sourceLength,
                                    targetLocation: start, targetLength: end - start, isComplete: s.isComplete)
        }
    }
}

/// 段落対応から、原文・訳文で対応する位置の組（Y 座標に直す前）を作る
enum AlignmentUnits {
    /// テキストビュー上の位置
    enum Edge: Equatable {
        /// 本文の先頭（Y = 0）
        case origin
        /// この文字を含む行の上端（文字列の末尾以降なら本文の下端）
        case top(Int)
        /// この位置で終わる範囲の最後の文字を含む行の下端
        case bottom(Int)
        /// 本文の高さ（末尾の余白を含む）
        case end
    }

    struct Boundary: Equatable {
        var source: Edge
        var target: Edge
    }

    struct Plan: Equatable {
        /// 原文・訳文で対応する位置。先頭は (.origin, .origin)。
        /// 翻訳済みなら末尾は (.end, .end)、翻訳途中なら（未翻訳の最初の段落の上端, 翻訳済みの部分の終わり）
        var boundaries: [Boundary]
        /// まだ訳していない段落がある（生成中・中断）
        var isPartial: Bool
    }

    /// - Parameters:
    ///   - source: 原文ペインの文字列（`segments` の原文側が指す文字列）
    /// - Returns: 段落対応が文字列に収まらない・順番が崩れている・空なら nil（空行・行の数での対応づけに任せる）
    static func plan(_ segments: [SegmentAlignment], source: String, targetLength: Int) -> Plan? {
        let sourceLength = (source as NSString).length
        guard !segments.isEmpty else { return nil }
        var sourceEnd = 0, targetEnd = 0
        for s in segments {
            guard s.sourceLocation >= sourceEnd, s.sourceLength >= 0, s.sourceLocation + s.sourceLength <= sourceLength,
                  s.targetLocation >= targetEnd, s.targetLength >= 0, s.targetLocation + s.targetLength <= targetLength
            else { return nil }
            sourceEnd = s.sourceLocation + s.sourceLength
            targetEnd = s.targetLocation + s.targetLength
        }
        // 対応づけるのは訳し終えた段落だけ（生成中の段落の訳文はまだ伸びる・後で整形される）
        let completed = Array(segments.prefix { $0.isComplete })
        var boundaries = [Boundary(source: .origin, target: .origin)]
        for s in completed {
            boundaries.append(Boundary(source: .top(s.sourceLocation), target: .top(s.targetLocation)))
            boundaries.append(Boundary(source: s.sourceLength > 0 ? .bottom(s.sourceLocation + s.sourceLength) : .top(s.sourceLocation),
                                       target: s.targetLength > 0 ? .bottom(s.targetLocation + s.targetLength) : .top(s.targetLocation)))
        }
        let translatedSourceEnd = completed.last.map { $0.sourceLocation + $0.sourceLength } ?? 0
        // 訳し終えた段落の後に（空白以外の）原文が残っていれば翻訳途中
        let next = TextUnits.firstNonWhitespace(in: source, from: translatedSourceEnd)
        let isPartial = completed.count < segments.count || next < sourceLength
        if isPartial {
            let targetTail: Edge
            if completed.count < segments.count {
                targetTail = .top(segments[completed.count].targetLocation)   // 生成中の段落の訳文の上端
            } else if let last = completed.last, last.targetLength > 0 {
                targetTail = .bottom(last.targetLocation + last.targetLength)
            } else {
                targetTail = .top(completed.last?.targetLocation ?? 0)
            }
            boundaries.append(Boundary(source: .top(next), target: targetTail))
        } else {
            boundaries.append(Boundary(source: .end, target: .end))
        }
        return Plan(boundaries: boundaries, isPartial: isPartial)
    }
}

// MARK: - スクロール位置の対応づけ

/// 2 つのテキストビュー間でスクロール位置を対応づける
enum ScrollMapping {
    /// - Parameters:
    ///   - aOffset: 動かした側（基準側）の表示上端
    ///   - aMax / bMax: それぞれのスクロールできる最大値
    ///   - aViewport: 基準側の表示領域の高さ（末尾での合わせ込みの幅）
    ///   - units: 対応する Y の組（基準側, 相手側）。同じ要素数で、どちらも単調増加（`monotone` で整える）。
    ///     基準側が最後の要素より先にあれば相手は最後の要素の位置に留まる（翻訳途中の未翻訳部分）。nil なら全体の割合で合わせる
    ///   - endBlending: 基準側の最後の 1 画面分で、相手を少しずつ末尾へ寄せる（翻訳済みのときだけ）
    /// - Returns: 相手のスクロール位置。nil なら動かさない（どちらかがスクロールできない）
    static func mappedOffset(aOffset: CGFloat, aMax: CGFloat, bMax: CGFloat, aViewport: CGFloat,
                             units: (a: [CGFloat], b: [CGFloat])?, endBlending: Bool) -> CGFloat? {
        // 動かした側・相手がスクロールできない（短い）なら、相手はそのままにする
        guard aMax > 0, bMax > 0 else { return nil }
        let x = min(max(aOffset, 0), aMax)
        var y: CGFloat
        if let units, units.a.count >= 2, units.a.count == units.b.count {
            y = interpolate(x, a: units.a, b: units.b)
        } else {
            y = x / aMax * bMax
        }
        y = min(max(y, 0), bMax)
        if endBlending { y = blendTowardEnd(y, aOffset: x, aMax: aMax, bMax: bMax, aViewport: aViewport) }
        return y
    }

    /// 区分線形の対応。`a` の範囲外は端の値に留める
    static func interpolate(_ x: CGFloat, a: [CGFloat], b: [CGFloat]) -> CGFloat {
        guard let aFirst = a.first, let aLast = a.last, let bFirst = b.first, let bLast = b.last else { return x }
        if x <= aFirst { return bFirst }
        if x >= aLast { return bLast }
        // a[i] <= x となる最後の i（x < aLast なので i + 1 は範囲内で、a[i + 1] > x）
        var lo = 0, hi = a.count - 1, i = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if a[mid] <= x { i = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let span = a[i + 1] - a[i]
        guard span > 0 else { return b[i + 1] }
        return b[i] + (x - a[i]) / span * (b[i + 1] - b[i])
    }

    /// 末尾の合わせ込み: 基準側の最後の 1 画面分（`aMax - h ... aMax`）で、段落の対応による位置 `y` から
    /// 相手の末尾 `bMax` へ線形に寄せる（両方の下端が同時に本文の終わりに着く）。
    /// `y` が単調増加・`bMax` 以下なら結果も単調増加で連続（y + t·(bMax − y) の t も単調増加なので）。
    static func blendTowardEnd(_ y: CGFloat, aOffset: CGFloat, aMax: CGFloat, bMax: CGFloat, aViewport: CGFloat) -> CGFloat {
        let h = min(max(aViewport, 0), aMax)
        guard h > 0 else { return y }
        let t = min(max((aOffset - (aMax - h)) / h, 0), 1)
        let base = min(y, bMax)
        return base + t * (bMax - base)
    }

    /// 両方の列を単調増加（同じ値は可）に整える（行の上端・下端の取り方で前後することがあるため）
    static func monotone(a: [CGFloat], b: [CGFloat]) -> (a: [CGFloat], b: [CGFloat]) {
        func runningMax(_ xs: [CGFloat]) -> [CGFloat] {
            var out: [CGFloat] = []
            out.reserveCapacity(xs.count)
            var m = -CGFloat.greatestFiniteMagnitude
            for x in xs { m = max(m, x); out.append(m) }
            return out
        }
        return (runningMax(a), runningMax(b))
    }
}

// MARK: - 段落・行（段落対応が無いときの手がかり）

/// 段落・行の開始位置（UTF-16 オフセット）。改行は \n・\r\n・\r（と U+2028 など）のどれでもよい
enum TextUnits {
    /// 改行 1 つ（\r\n は分けない）。`(?>…)` で、\r\n の \r だけに当たって 1 つの改行を空行と見誤るのを防ぐ
    private static let lineBreak = "(?>\\r\\n|[\\n\\u000B\\u000C\\r\\u0085\\u2028\\u2029])"
    /// 空行（空白だけの行を含む）と、その後の空白
    private static let paragraphBreak = try! NSRegularExpression(pattern: lineBreak + "[ \\t\\u3000]*" + lineBreak + "\\s*")

    /// 空行で区切られた段落の開始位置（重複なし・昇順）
    static func paragraphStarts(_ s: String) -> [Int] {
        let ns = s as NSString
        let first = firstNonWhitespace(in: s, from: 0)
        guard first < ns.length else { return [] }
        var starts = [first]
        for m in paragraphBreak.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let end = NSMaxRange(m.range)
            // 先頭の空行の後ろ（= first）を二重に数えない
            if end < ns.length, end > starts[starts.count - 1] { starts.append(end) }
        }
        return starts
    }

    /// 空でない行の開始位置（`lineRange(for:)` は \r\n・\r・\n・U+2028 などを改行として扱う）
    static func lineStarts(_ s: String) -> [Int] {
        let ns = s as NSString
        var starts: [Int] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { starts.append(line.location) }
            location = line.location + max(line.length, 1)
        }
        return starts
    }

    /// `i` 以降で最初の空白・改行以外の文字の位置。無ければ文字列の長さ
    static func firstNonWhitespace(in s: String, from i: Int) -> Int {
        let ns = s as NSString
        let start = min(max(i, 0), ns.length)
        let r = ns.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted,
                                    range: NSRange(location: start, length: ns.length - start))
        return r.location == NSNotFound ? ns.length : r.location
    }
}

// MARK: - 文字列の末尾だけの書き換え

/// 表示中の文字列を新しい文字列にするための、末尾だけの置き換え。
/// 先頭の共通部分のレイアウト・スクロール位置・選択範囲をそのまま使えるようにする。
struct TextTailEdit: Equatable {
    /// 置き換える範囲（古い文字列の UTF-16 範囲。末尾まで）
    var range: NSRange
    var replacement: String

    /// 共通の先頭部分がこれより短ければ（古い文字列がそれより短ければその長さ）全体を置き換える（別の訳文など）
    static let minimumSharedPrefix = 32

    /// - Returns: 末尾の置き換え。共通の先頭部分が短ければ nil（全体を置き換える）
    static func make(from old: String, to new: String, minimumSharedPrefix: Int = TextTailEdit.minimumSharedPrefix) -> TextTailEdit? {
        let prefix = commonPrefixLength(old, new)
        let oldLength = (old as NSString).length
        guard prefix >= min(minimumSharedPrefix, oldLength) else { return nil }
        return TextTailEdit(range: NSRange(location: prefix, length: oldLength - prefix),
                            replacement: (new as NSString).substring(from: prefix))
    }

    /// UTF-16 単位の共通の先頭部分の長さ。サロゲートペアの途中では切らない
    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var ia = a.utf16.makeIterator(), ib = b.utf16.makeIterator()
        var n = 0
        var lastWasLead = false
        while let x = ia.next(), let y = ib.next(), x == y {
            n += 1
            lastWasLead = UTF16.isLeadSurrogate(x)
        }
        return lastWasLead ? n - 1 : n
    }
}
