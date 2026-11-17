import Foundation
import XCTest
@testable import PlamoTranslateCore

final class SegmenterCRLFTests: XCTestCase {
    private func roundTrip(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(TextSegmenter.join(TextSegmenter.segments(s)), s, file: file, line: line)
    }

    func testCRLFParagraphs() {
        let s = "A\r\nA2\r\n\r\nB\r\n"
        XCTAssertEqual(TextSegmenter.segments(s),
                       [.text("A\r\nA2"), .separator("\r\n\r\n"), .text("B"), .separator("\r\n")])
        XCTAssertEqual(TextSegmenter.paragraphs(s).count, 2)
        XCTAssertEqual(TextSegmenter.paragraphs("a\r\n\r\nb"), ["a", "b"])
        // 空白のみの行も CRLF で区切られていれば空行
        XCTAssertEqual(TextSegmenter.segments("a\r\n \r\nb"), [.text("a"), .separator("\r\n \r\n"), .text("b")])
        XCTAssertEqual(TextSegmenter.segments("\r\n\r\nX"), [.separator("\r\n\r\n"), .text("X")])
        roundTrip(s)
    }

    func testLoneCR() {
        XCTAssertEqual(TextSegmenter.segments("A\r\rB"), [.text("A"), .separator("\r\r"), .text("B")])
        // 段落内の単独 \r は単一改行として段落に残る
        XCTAssertEqual(TextSegmenter.segments("a\rb"), [.text("a\rb")])
        // 末尾の \r は text に残らない
        XCTAssertEqual(TextSegmenter.segments("a\r"), [.text("a"), .separator("\r")])
    }

    func testRoundTripMixedNewlinesAndSurrogates() {
        let cases = [
            "a\r\n\r\nb", "a\r", "\r", "\r\n", "\r\n\r\n", "a\r\r\n\rb", "\r\na\r\n", "😀\r\n\r\n👍🏽",
            "x\n\r\ny", "  x  \r\n\r\n y\r\n", "\u{3000}\r\n本文\r\n\r\n\u{3000}",
        ]
        for s in cases {
            roundTrip(s)
            for seg in TextSegmenter.segments(s) {
                if case .text(let t) = seg {
                    XCTAssertFalse(t.hasSuffix("\r") || t.hasSuffix("\n") || t.utf16.last == 0x0D, "\(Array(s.utf16))")
                }
            }
        }
    }
}

final class DocumentProgressAlignmentTests: XCTestCase {
    func testAlignmentDefaultsToEmpty() {
        let p = DocumentProgress(text: "a", totalParagraphs: 1, completedParagraphs: 0, isFinished: false)
        XCTAssertEqual(p.alignment, [])
        let a = SegmentAlignment(sourceLocation: 0, sourceLength: 1, targetLocation: 0, targetLength: 1, isComplete: true)
        let q = DocumentProgress(text: "a", totalParagraphs: 1, completedParagraphs: 1, isFinished: true,
                                 truncatedParagraphs: 0, alignment: [a])
        XCTAssertEqual(q.alignment, [a])
        XCTAssertNotEqual(p, q)
        XCTAssertEqual(Set([a, a]).count, 1)
    }
}

final class DocumentAssemblerTests: XCTestCase {
    private func align(_ s: Int, _ sl: Int, _ t: Int, _ tl: Int, _ complete: Bool = true) -> SegmentAlignment {
        SegmentAlignment(sourceLocation: s, sourceLength: sl, targetLocation: t, targetLength: tl, isComplete: complete)
    }

    private func substring(_ s: String, _ location: Int, _ length: Int) -> String {
        NSString(string: s).substring(with: NSRange(location: location, length: length))
    }

    /// 各要素が原文の段落・訳文の出力をちょうど指し、文書順で重ならないことを確認する。
    private func verify(source: String, outputs: [String], partial: String? = nil,
                        file: StaticString = #filePath, line: UInt = #line) -> DocumentAssembler.Snapshot {
        let snap = DocumentAssembler.assemble(source: source, outputs: outputs, partial: partial)
        let paragraphs = TextSegmenter.segments(source).filter(DocumentAssembler.isTranslatable).map { seg -> String in
            if case .text(let s) = seg { return s } else { return "" }
        }
        var sourceEnd = 0
        var targetEnd = 0
        for (k, a) in snap.alignment.enumerated() {
            XCTAssertEqual(substring(source, a.sourceLocation, a.sourceLength), paragraphs[k], "source #\(k)", file: file, line: line)
            let expected = k < outputs.count ? outputs[k] : (partial ?? "")
            XCTAssertEqual(substring(snap.text, a.targetLocation, a.targetLength), expected, "target #\(k)", file: file, line: line)
            XCTAssertEqual(a.isComplete, k < outputs.count, "isComplete #\(k)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(a.sourceLocation, sourceEnd, file: file, line: line)
            XCTAssertGreaterThanOrEqual(a.targetLocation, targetEnd, file: file, line: line)
            sourceEnd = a.sourceLocation + a.sourceLength
            targetEnd = a.targetLocation + a.targetLength
        }
        XCTAssertLessThanOrEqual(sourceEnd, source.utf16.count, file: file, line: line)
        XCTAssertLessThanOrEqual(targetEnd, snap.text.utf16.count, file: file, line: line)
        return snap
    }

    func testBasic() {
        let snap = verify(source: "A\n\nB", outputs: ["あ", "い"])
        XCTAssertEqual(snap.text, "あ\n\nい")
        XCTAssertEqual(snap.alignment, [align(0, 1, 0, 1), align(3, 1, 3, 1)])
    }

    func testEmptyOutputStillGetsEntry() {
        let snap = verify(source: "A\n\nB\n\nC", outputs: ["x", "", "z"])
        XCTAssertEqual(snap.text, "x\n\n\n\nz")
        XCTAssertEqual(snap.alignment, [align(0, 1, 0, 1), align(3, 1, 3, 0), align(6, 1, 5, 1)])
    }

    func testOutputContainingBlankLine() {
        let snap = verify(source: "A\n\nB", outputs: ["x\n\ny", "z"])
        XCTAssertEqual(snap.text, "x\n\ny\n\nz")
        XCTAssertEqual(snap.alignment, [align(0, 1, 0, 4), align(3, 1, 6, 1)])
    }

    func testLeadingBlankLines() {
        let snap = verify(source: "\n\n  \nA\n\nB", outputs: ["xx", "y"])
        XCTAssertEqual(snap.text, "\n\n  \nxx\n\ny")
        XCTAssertEqual(snap.alignment, [align(5, 1, 5, 2), align(8, 1, 9, 1)])
    }

    func testSurrogatePairsUseUTF16Offsets() {
        // 😀 = 2 units, 👍🏽 = 4 units（Character では 1 つ）
        let snap = verify(source: "😀 hi\n\nB", outputs: ["👍🏽ok", "é"])
        XCTAssertEqual(snap.text, "👍🏽ok\n\né")
        XCTAssertEqual(snap.alignment, [align(0, 5, 0, 6), align(7, 1, 8, 1)])
        let flags = verify(source: "😀\n\n🇯🇵", outputs: ["😀😀"], partial: "🇯")
        XCTAssertEqual(flags.text, "😀😀\n\n🇯")
        XCTAssertEqual(flags.alignment, [align(0, 2, 0, 4), align(4, 4, 6, 2, false)])
    }

    func testInProgressParagraph() {
        let snap = verify(source: "A\n\nB\n\nC", outputs: ["x"], partial: "yy")
        XCTAssertEqual(snap.text, "x\n\nyy")
        XCTAssertEqual(snap.alignment, [align(0, 1, 0, 1), align(3, 1, 3, 2, false)])
        let empty = verify(source: "A\n\nB\n\nC", outputs: ["x"], partial: "")
        XCTAssertEqual(empty.text, "x\n\n")
        XCTAssertEqual(empty.alignment, [align(0, 1, 0, 1), align(3, 1, 3, 0, false)])
        // 段落完了直後（次の区切りはまだ入らない）
        let between = verify(source: "A\n\nB", outputs: ["x"])
        XCTAssertEqual(between.text, "x")
        XCTAssertEqual(between.alignment, [align(0, 1, 0, 1)])
    }

    func testCRLFSource() {
        let snap = verify(source: "A\r\n\r\nB\r\n", outputs: ["x", "y"])
        XCTAssertEqual(snap.text, "x\r\n\r\ny\r\n")
        XCTAssertEqual(snap.alignment, [align(0, 1, 0, 1), align(5, 1, 5, 1)])
    }

    func testWhitespaceOnlyTextPassesThrough() {
        // NBSP だけの行は空行扱いではないが、翻訳せずそのまま出力し、対応も作らない
        let source = "A\n\n\u{00A0}\n\nB"
        XCTAssertEqual(DocumentAssembler(source: source).totalParagraphs, 2)
        let snap = verify(source: source, outputs: ["x", "y"])
        XCTAssertEqual(snap.text, "x\n\n\u{00A0}\n\ny")
        XCTAssertEqual(snap.alignment, [align(0, 1, 0, 1), align(6, 1, 6, 1)])
    }

    func testIncrementalMatchesTranslatorFlow() {
        let source = "\r\n# 見出し\r\n\r\n本文 😀\r\n2 行目\r\n\r\n\r\n終わり\r\n"
        var doc = DocumentAssembler(source: source)
        XCTAssertEqual(doc.totalParagraphs, 3)
        var outputs: [String] = []
        let translations = ["# Heading", "Body 😀\n\nline two", ""]
        var k = 0
        while let src = doc.beginNextParagraph() {
            XCTAssertTrue(doc.isParagraphInProgress)
            XCTAssertFalse(src.isEmpty)
            var part = ""
            for ch in translations[k] {
                part.append(ch)
                let snap = doc.snapshot(partial: part)
                XCTAssertEqual(snap, DocumentAssembler.assemble(source: source, outputs: outputs, partial: part))
                XCTAssertEqual(snap.alignment.last?.isComplete, false)
            }
            doc.complete(output: translations[k])
            outputs.append(translations[k])
            XCTAssertFalse(doc.isParagraphInProgress)
            XCTAssertEqual(doc.snapshot().alignment.count, k + 1)
            k += 1
        }
        let finished = doc.snapshot()
        XCTAssertEqual(finished.text, "\r\n# Heading\r\n\r\nBody 😀\n\nline two\r\n\r\n\r\n\r\n")
        XCTAssertEqual(finished, verify(source: source, outputs: translations))
        XCTAssertTrue(finished.alignment.allSatisfy(\.isComplete))
        // 原文をそのまま出力に使えば原文が再現される
        XCTAssertEqual(DocumentAssembler.assemble(source: source, outputs: TextSegmenter.paragraphs(source)).text, source)
    }

    func testEmptySource() {
        var doc = DocumentAssembler(source: "")
        XCTAssertNil(doc.beginNextParagraph())
        XCTAssertEqual(doc.snapshot(), DocumentAssembler.Snapshot(text: "", alignment: []))
        XCTAssertEqual(DocumentAssembler.assemble(source: " \n\n", outputs: []).text, " \n\n")
    }
}
