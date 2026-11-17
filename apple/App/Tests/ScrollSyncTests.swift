import XCTest
import CoreGraphics
import PlamoTranslateCore
@testable import PlamoTranslateApp

private func seg(_ sourceLocation: Int, _ sourceLength: Int, _ targetLocation: Int, _ targetLength: Int,
                 _ isComplete: Bool = true) -> SegmentAlignment {
    SegmentAlignment(sourceLocation: sourceLocation, sourceLength: sourceLength,
                     targetLocation: targetLocation, targetLength: targetLength, isComplete: isComplete)
}

private typealias Boundary = AlignmentUnits.Boundary

private func utf16Length(_ s: String) -> Int { (s as NSString).length }

private func substring(_ s: String, _ location: Int, _ length: Int) -> String {
    (s as NSString).substring(with: NSRange(location: location, length: length))
}

// MARK: - 段落・行（段落対応が無いときの手がかり）

final class TextUnitsTests: XCTestCase {
    func testParagraphStartsCRLF() {
        XCTAssertEqual(TextUnits.paragraphStarts("Hello\r\n\r\nWorld\r\nline2\r\n\r\nEnd"), [0, 9, 25])
        // 改行 1 つ（\r\n）は段落の区切りではない（\r と \n を別々の改行と見誤らない）
        XCTAssertEqual(TextUnits.paragraphStarts("A\r\nB"), [0])
        XCTAssertEqual(TextUnits.paragraphStarts("A\r\rB"), [0, 3])
        XCTAssertEqual(TextUnits.paragraphStarts("A\r\n \u{3000}\r\nB"), [0, 7])
        XCTAssertEqual(TextUnits.paragraphStarts("a\n\nb\n\n\nc"), [0, 3, 7])
    }

    func testParagraphStartsLeadingBlankLinesAreNotCountedTwice() {
        XCTAssertEqual(TextUnits.paragraphStarts("\n\n  Para1\n\nPara2"), [4, 11])
        XCTAssertEqual(TextUnits.paragraphStarts(" \n\n "), [])
    }

    func testLineStartsCRLF() {
        XCTAssertEqual(TextUnits.lineStarts("a\r\nb\r\n\r\nc"), [0, 3, 8])
        XCTAssertEqual(TextUnits.lineStarts("a\rb\r\rc"), [0, 2, 5])
    }

    func testFileLineEndingsAreNormalised() {
        XCTAssertEqual(FileTextLoader.normalizeLineEndings("a\r\nb\rc\u{2028}d\ne"), "a\nb\nc\nd\ne")
        XCTAssertEqual(TextUnits.paragraphStarts(FileTextLoader.normalizeLineEndings("A\r\n\r\nB")),
                       TextUnits.paragraphStarts("A\n\nB"))
    }
}

// MARK: - 段落対応の補正

final class AlignmentAdjustTests: XCTestCase {
    func testLeadingWhitespaceLengthIsUTF16() {
        XCTAssertEqual(AlignmentAdjust.leadingWhitespaceLength("\u{3000} \n😀x"), 3)
        XCTAssertEqual(AlignmentAdjust.leadingWhitespaceLength(" \n "), 3)
        XCTAssertEqual(AlignmentAdjust.leadingWhitespaceLength("😀 "), 0)
    }

    func testShiftAndClamp() {
        let segments = [seg(0, 4, 2, 3), seg(6, 2, 7, 10, false)]
        XCTAssertEqual(AlignmentAdjust.shifted(segments, source: 5, target: -2, targetLength: 9),
                       [seg(5, 4, 0, 3), seg(11, 2, 5, 4, false)])
        XCTAssertEqual(AlignmentAdjust.shifted([seg(0, 1, 0, 3)], source: 0, target: -2, targetLength: 5),
                       [seg(0, 1, 0, 1)])
    }

    /// 絵文字（サロゲートペア）を含む原文の先頭の空白の除去と、訳文の前後の空白の除去
    func testMultibyteOffsetsSurviveTrimming() {
        let display = "\u{3000}😀 段落一\n\n段落二😀"
        let shift = AlignmentAdjust.leadingWhitespaceLength(display)
        XCTAssertEqual(shift, 1)
        // Kit の位置は前後の空白を除いた原文（"😀 段落一\n\n段落二😀"）を指す
        let source = AlignmentAdjust.shifted([seg(0, 6, 0, 3), seg(8, 5, 5, 4)], source: shift, target: 0, targetLength: 9)
        XCTAssertEqual(source.map { substring(display, $0.sourceLocation, $0.sourceLength) }, ["😀 段落一", "段落二😀"])

        let raw = " \nAA😀\n\nBB😀\n\n"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = AlignmentAdjust.shifted([seg(0, 6, 2, 4), seg(8, 5, 8, 4)], source: 0,
                                             target: -AlignmentAdjust.leadingWhitespaceLength(raw),
                                             targetLength: utf16Length(trimmed))
        XCTAssertEqual(target.map { substring(trimmed, $0.targetLocation, $0.targetLength) }, ["AA😀", "BB😀"])
    }
}

// MARK: - 段落対応から作る位置の組

final class AlignmentUnitsTests: XCTestCase {
    private let display = "  P1 src\n\nP2 src\n\nP3 src"

    func testMidStreamMapsOnlyCompletedParagraphs() throws {
        let target = "T1\n\nT2pa"
        let segments = AlignmentAdjust.shifted([seg(0, 6, 0, 2), seg(8, 6, 4, 4, false)], source: 2, target: 0,
                                               targetLength: utf16Length(target))
        let plan = try XCTUnwrap(AlignmentUnits.plan(segments, source: display, targetLength: utf16Length(target)))
        XCTAssertTrue(plan.isPartial)
        XCTAssertEqual(plan.boundaries, [
            Boundary(source: .origin, target: .origin),
            Boundary(source: .top(2), target: .top(0)),
            Boundary(source: .bottom(8), target: .bottom(2)),
            // 未翻訳の最初の段落の上端 ↔ 生成中の段落の訳文の上端
            Boundary(source: .top(10), target: .top(4)),
        ])
    }

    func testBetweenParagraphsIsStillPartial() throws {
        let plan = try XCTUnwrap(AlignmentUnits.plan([seg(2, 6, 0, 2)], source: display, targetLength: 4))
        XCTAssertTrue(plan.isPartial)
        XCTAssertEqual(plan.boundaries.last, Boundary(source: .top(10), target: .bottom(2)))
    }

    func testFinishedEndsAtContentEnd() throws {
        let plan = try XCTUnwrap(AlignmentUnits.plan([seg(2, 6, 0, 2), seg(10, 6, 4, 2), seg(18, 6, 8, 2)],
                                                     source: display, targetLength: 10))
        XCTAssertFalse(plan.isPartial)
        XCTAssertEqual(plan.boundaries.last, Boundary(source: .end, target: .end))
    }

    func testInvalidAlignmentFallsBack() {
        XCTAssertNil(AlignmentUnits.plan([], source: display, targetLength: 4))
        XCTAssertNil(AlignmentUnits.plan([seg(2, 60, 0, 2)], source: display, targetLength: 4))
        XCTAssertNil(AlignmentUnits.plan([seg(10, 2, 0, 2), seg(2, 2, 3, 1)], source: display, targetLength: 4))
    }

    /// 訳文が空の段落（出力が空・打ち切り）: 訳文側は止まったまま、位置の組は単調
    func testEmptyParagraphOutput() throws {
        let source = "A1\n\nB1\n\nC1", target = "X\n\n\n\nZ"
        XCTAssertNotEqual(TextUnits.paragraphStarts(source).count, TextUnits.paragraphStarts(target).count)
        let plan = try XCTUnwrap(AlignmentUnits.plan([seg(0, 2, 0, 1), seg(4, 2, 3, 0), seg(8, 2, 5, 1)],
                                                     source: source, targetLength: utf16Length(target)))
        XCTAssertFalse(plan.isPartial)
        XCTAssertEqual(Array(plan.boundaries[3...4]), [Boundary(source: .top(4), target: .top(3)),
                                                       Boundary(source: .bottom(6), target: .top(3))])
    }

    /// 1 つの段落の訳文に空行が入っている: 空行の数では合わないが、段落対応ならそのまま対応づけられる
    func testTranslatedParagraphContainingBlankLine() throws {
        let source = "Para one.\n\nPara two.", target = "Absatz eins.\n\nTeil A\n\nTeil B"
        XCTAssertEqual(TextUnits.paragraphStarts(source).count, 2)
        XCTAssertEqual(TextUnits.paragraphStarts(target).count, 3)
        let plan = try XCTUnwrap(AlignmentUnits.plan([seg(0, 9, 0, 12), seg(11, 9, 14, 14)],
                                                     source: source, targetLength: utf16Length(target)))
        XCTAssertEqual(Array(plan.boundaries[3...]), [Boundary(source: .top(11), target: .top(14)),
                                                      Boundary(source: .bottom(20), target: .bottom(28)),
                                                      Boundary(source: .end, target: .end)])
        // 1 行 20pt・上下の余白 12pt として Y に直した場合: 原文の 2 段落目の半分 → 訳文の 2 段落目（2 ブロック）の半分
        let sy: [CGFloat] = [0, 12, 32, 52, 72, 84], ty: [CGFloat] = [0, 12, 32, 52, 112, 124]
        XCTAssertEqual(ScrollMapping.mappedOffset(aOffset: 62, aMax: 100, bMax: 100, aViewport: 50,
                                                  units: (sy, ty), endBlending: false), 82)
    }
}

// MARK: - スクロール位置の対応づけ

final class ScrollMappingTests: XCTestCase {
    /// 翻訳途中: 基準側が末尾に着いても、相手は翻訳済みの部分の終わりに留まる（末尾へ飛ばない）
    func testMidStreamFollowerStaysAtTranslatedEnd() {
        let sy: [CGFloat] = [0, 12, 32, 52], ty: [CGFloat] = [0, 12, 32, 52]
        XCTAssertEqual(ScrollMapping.mappedOffset(aOffset: 200, aMax: 200, bMax: 300, aViewport: 100,
                                                  units: (sy, ty), endBlending: false), 52)
        // 訳文を基準に未翻訳部分の先へ: 原文は未翻訳の最初の段落の上端
        XCTAssertEqual(ScrollMapping.mappedOffset(aOffset: 90, aMax: 90, bMax: 300, aViewport: 100,
                                                  units: (ty, sy), endBlending: false), 52)
    }

    func testEndBlendingIsMonotoneAndReachesTheEnd() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let n = Int.random(in: 2...12, using: &rng)
            var a = (0..<n).map { _ in CGFloat.random(in: 0...5000, using: &rng) }.sorted()
            var b = (0..<n).map { _ in CGFloat.random(in: 0...5000, using: &rng) }.sorted()
            a[0] = 0; b[0] = 0
            if n > 3 { let k = Int.random(in: 1...(n - 2), using: &rng); b[k + 1] = b[k] }   // 訳文が空の段落
            let units = ScrollMapping.monotone(a: a, b: b)
            let aView = CGFloat.random(in: 100...900, using: &rng), bView = CGFloat.random(in: 100...900, using: &rng)
            let aMax = max(units.a.last! - aView, 1), bMax = max(units.b.last! - bView, 1)
            var previous: CGFloat = -1
            for i in 0...500 {
                let x = aMax * CGFloat(i) / 500
                let y = ScrollMapping.mappedOffset(aOffset: x, aMax: aMax, bMax: bMax, aViewport: aView,
                                                   units: units, endBlending: true)!
                XCTAssertGreaterThanOrEqual(y, previous - 1e-6)
                previous = y
                if i == 0 { XCTAssertEqual(y, 0) }
            }
            XCTAssertEqual(previous, bMax, accuracy: 1e-6)
        }
    }

    func testEndBlendingIsContinuous() {
        let a: [CGFloat] = [0, 100, 200, 1000], b: [CGFloat] = [0, 100, 200, 3000]
        // 合わせ込みが無ければ、最後の 1pt 手前で相手は末尾（2800）より 500pt 手前（以前は最後に飛んでいた）
        XCTAssertEqual(ScrollMapping.mappedOffset(aOffset: 799, aMax: 800, bMax: 2800, aViewport: 200,
                                                  units: (a, b), endBlending: false)!, 2296.5, accuracy: 1e-6)
        XCTAssertEqual(ScrollMapping.mappedOffset(aOffset: 799, aMax: 800, bMax: 2800, aViewport: 200,
                                                  units: (a, b), endBlending: true)!, 2797.5, accuracy: 0.1)
        // 最後の 1 画面より前は段落の対応のまま
        XCTAssertEqual(ScrollMapping.mappedOffset(aOffset: 550, aMax: 800, bMax: 2800, aViewport: 200,
                                                  units: (a, b), endBlending: true),
                       ScrollMapping.interpolate(550, a: a, b: b))
        var previous: CGFloat = 0
        for i in 0...8000 {
            let y = ScrollMapping.mappedOffset(aOffset: CGFloat(i) / 10, aMax: 800, bMax: 2800, aViewport: 200,
                                               units: (a, b), endBlending: true)!
            XCTAssertLessThan(y - previous, 5)   // 0.1pt ごとに大きく飛ばない
            previous = y
        }
        XCTAssertEqual(previous, 2800)
    }

    func testFallbacks() {
        XCTAssertNil(ScrollMapping.mappedOffset(aOffset: 10, aMax: 0, bMax: 100, aViewport: 50, units: nil, endBlending: true))
        XCTAssertNil(ScrollMapping.mappedOffset(aOffset: 10, aMax: 100, bMax: 0, aViewport: 50, units: nil, endBlending: true))
        XCTAssertEqual(ScrollMapping.mappedOffset(aOffset: 50, aMax: 100, bMax: 300, aViewport: 50, units: nil, endBlending: false), 150)
    }
}

// MARK: - 末尾だけの書き換え

final class TextTailEditTests: XCTestCase {
    private let base = String(repeating: "x", count: 40)

    private func apply(_ edit: TextTailEdit, to old: String) -> String {
        (old as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func testExtend() {
        XCTAssertEqual(TextTailEdit.make(from: base, to: base + "abc"),
                       TextTailEdit(range: NSRange(location: 40, length: 0), replacement: "abc"))
        XCTAssertEqual(TextTailEdit.make(from: "ab", to: "abc"),
                       TextTailEdit(range: NSRange(location: 2, length: 0), replacement: "c"))
        XCTAssertEqual(TextTailEdit.make(from: "", to: "abc"),
                       TextTailEdit(range: NSRange(location: 0, length: 0), replacement: "abc"))
    }

    /// 段落を訳し終えると生成中の生の出力が整形され、訳文が短くなることがある
    func testShrinkWhenParagraphIsCleaned() throws {
        let old = base + "raw  </out>", new = base + "raw"
        let edit = try XCTUnwrap(TextTailEdit.make(from: old, to: new))
        XCTAssertEqual(edit, TextTailEdit(range: NSRange(location: 43, length: 8), replacement: ""))
        XCTAssertEqual(apply(edit, to: old), new)
        let edit2 = try XCTUnwrap(TextTailEdit.make(from: base + "abc", to: base + "xyz12"))
        XCTAssertEqual(apply(edit2, to: base + "abc"), base + "xyz12")
    }

    func testShortSharedPrefixReplacesEverything() {
        XCTAssertNil(TextTailEdit.make(from: base, to: "y" + base))
        XCTAssertNil(TextTailEdit.make(from: "Hello world, this is a long translation.", to: "Bonjour"))
    }

    func testSurrogatePairsAreNotSplit() throws {
        XCTAssertEqual(TextTailEdit.commonPrefixLength("日本😀", "日本😃"), 2)
        XCTAssertEqual(TextTailEdit.commonPrefixLength("日本😀a", "日本😀b"), 4)
        let edit = try XCTUnwrap(TextTailEdit.make(from: "日本😀", to: "日本😃", minimumSharedPrefix: 1))
        XCTAssertEqual(edit, TextTailEdit(range: NSRange(location: 2, length: 2), replacement: "😃"))
        XCTAssertEqual(apply(edit, to: "日本😀"), "日本😃")
    }
}
