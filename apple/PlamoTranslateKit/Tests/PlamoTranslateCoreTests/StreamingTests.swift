import XCTest
@testable import PlamoTranslateCore

final class StopSequenceDecoderTests: XCTestCase {
    private let stops = PFML3.stopStrings

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testPlainTextPassesThrough() {
        var d = StopSequenceDecoder(stop: stops)
        XCTAssertEqual(d.feed(bytes("Hello")), "Hello")
        XCTAssertEqual(d.feed(bytes(", world")), ", world")
        XCTAssertEqual(d.flush(), "")
        XCTAssertFalse(d.isStopped)
    }

    func testSplitMultibyteSequenceIsHeld() {
        var d = StopSequenceDecoder(stop: stops)
        let a = bytes("あ")          // E3 81 82
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(d.feed(a[0..<1]), "")
        XCTAssertEqual(d.feed(a[1..<2]), "")
        XCTAssertEqual(d.feed(a[2..<3]), "あ")

        let emoji = bytes("x😀y")    // 78 F0 9F 98 80 79
        XCTAssertEqual(d.feed(emoji[0..<3]), "x")
        XCTAssertEqual(d.feed(emoji[3..<5]), "😀")
        XCTAssertEqual(d.feed(emoji[5...]), "y")
        XCTAssertEqual(d.flush(), "")
    }

    func testIncompleteTailAtEndIsFlushedAsReplacement() {
        var d = StopSequenceDecoder(stop: stops)
        XCTAssertEqual(d.feed([0x61, 0xE3, 0x81]), "a")
        XCTAssertEqual(d.flush(), "\u{FFFD}")
    }

    func testStopStringSplitAcrossTokens() {
        var d = StopSequenceDecoder(stop: stops)
        XCTAssertEqual(d.feed(bytes("こんにちは<|pla")), "こんにちは")
        XCTAssertFalse(d.isStopped)
        XCTAssertEqual(d.feed(bytes("mo:ta")), "")
        XCTAssertEqual(d.feed(bytes("g|>input")), "")
        XCTAssertTrue(d.isStopped)
        XCTAssertEqual(d.feed(bytes("more")), "")
        XCTAssertEqual(d.flush(), "")
    }

    func testStopStringInsideOneToken() {
        var d = StopSequenceDecoder(stop: stops)
        XCTAssertEqual(d.feed(bytes("Hi<|plamo:bos|>junk")), "Hi")
        XCTAssertTrue(d.isStopped)
    }

    func testFalseStopPrefixIsReleased() {
        var d = StopSequenceDecoder(stop: stops)
        XCTAssertEqual(d.feed(bytes("a<|")), "a")
        XCTAssertEqual(d.feed(bytes("b")), "<|b")
        XCTAssertEqual(d.feed(bytes("<|plamo:")), "")
        XCTAssertEqual(d.flush(), "<|plamo:")
        XCTAssertFalse(d.isStopped)
    }

    func testStopPrefixAndMultibyteTogether() {
        var d = StopSequenceDecoder(stop: stops)
        let s = bytes("訳<|plamo:tag|>")
        XCTAssertEqual(d.feed(s[0..<2]), "")       // 「訳」の途中
        XCTAssertEqual(d.feed(s[2..<5]), "訳")     // 残り 1 バイト + "<|"
        XCTAssertEqual(d.feed(s[5...]), "")
        XCTAssertTrue(d.isStopped)
    }

    func testHelpers() {
        let st = stops.map { Array($0.utf8) }
        XCTAssertNil(StopSequenceDecoder.findStop(in: bytes("abc"), stops: st))
        XCTAssertEqual(StopSequenceDecoder.findStop(in: bytes("x<|plamo:bos|>y<|plamo:tag|>"), stops: st), 1)
        XCTAssertEqual(StopSequenceDecoder.findStop(in: bytes("xy<|plamo:tag|><|plamo:bos|>"), stops: st), 2)
        XCTAssertEqual(StopSequenceDecoder.longestStopPrefixSuffix(bytes("abc<|plamo:t"), stops: st), 9)
        XCTAssertEqual(StopSequenceDecoder.longestStopPrefixSuffix(bytes("abc<"), stops: st), 1)
        XCTAssertEqual(StopSequenceDecoder.longestStopPrefixSuffix(bytes("abc"), stops: st), 0)
        XCTAssertEqual(StopSequenceDecoder.incompleteUTF8Tail([]), 0)
        XCTAssertEqual(StopSequenceDecoder.incompleteUTF8Tail(bytes("aあ")), 0)
        XCTAssertEqual(StopSequenceDecoder.incompleteUTF8Tail([0x61, 0xE3]), 1)
        XCTAssertEqual(StopSequenceDecoder.incompleteUTF8Tail([0x61, 0xE3, 0x81]), 2)
        XCTAssertEqual(StopSequenceDecoder.incompleteUTF8Tail([0xF0, 0x9F, 0x98]), 3)
        XCTAssertEqual(StopSequenceDecoder.incompleteUTF8Tail([0xF0, 0x9F, 0x98, 0x80]), 0)
        XCTAssertEqual(StopSequenceDecoder.incompleteUTF8Tail([0x80, 0x80]), 0)   // 不正（待っても完結しない）
    }
}

final class PromptBudgetTests: XCTestCase {
    /// 擬似トークナイザ: Unicode スカラー数 + BOS
    private static func count(_ s: String) -> Int { s.unicodeScalars.count + 1 }

    private func request(pairs: Int) -> TranslationRequest {
        TranslationRequest(
            text: "The quick brown fox jumps over the lazy dog.",
            targetLang: "ja",
            history: (0..<pairs).map {
                HistoryPair(source: "Source sentence number \($0) with some padding text.",
                            translation: "訳文その\($0)。いくらかの埋め草を含む。")
            })
    }

    private func prompt(_ r: TranslationRequest, keeping k: Int) throws -> String {
        var r = r
        r.history = Array(r.history.suffix(k))
        return try PFML3.buildPrompt(r)
    }

    func testOutputReserve() {
        XCTAssertEqual(PromptBudget.outputReserve(textTokens: 10, maxTokens: 2048), 256)
        XCTAssertEqual(PromptBudget.outputReserve(textTokens: 500, maxTokens: 2048), 1064)
        XCTAssertEqual(PromptBudget.outputReserve(textTokens: 5000, maxTokens: 2048), 2048)
        XCTAssertEqual(PromptBudget.outputReserve(textTokens: 10, maxTokens: 100), 100)
        XCTAssertEqual(PromptBudget.outputReserve(textTokens: 10, maxTokens: 0), 0)
        XCTAssertEqual(PromptBudget.outputReserve(textTokens: 10, maxTokens: -5), 0)
    }

    func testNoHistoryIsUnchanged() async throws {
        let r = request(pairs: 0)
        var calls = 0
        let out = try await PromptBudget.fitHistory(r, contextLength: 10, maxTokens: 512) { s in
            calls += 1
            return Self.count(s)
        }
        XCTAssertEqual(out, r)
        XCTAssertEqual(calls, 0)
    }

    func testEverythingFits() async throws {
        let r = request(pairs: 5)
        let out = try await PromptBudget.fitHistory(r, contextLength: 100_000, maxTokens: 512) { Self.count($0) }
        XCTAssertEqual(out, r)
    }

    func testDropsOldestPairsFirst() async throws {
        let r = request(pairs: 5)
        let reserve = PromptBudget.outputReserve(textTokens: Self.count(r.text), maxTokens: 512)
        for keep in 0...4 {
            // ちょうど `keep` 件が収まる（keep + 1 件は収まらない）コンテキスト長
            let ctx = try Self.count(prompt(r, keeping: keep)) + reserve + 1
            let out = try await PromptBudget.fitHistory(r, contextLength: ctx, maxTokens: 512) { Self.count($0) }
            XCTAssertEqual(out.history, Array(r.history.suffix(keep)), "keep=\(keep)")
            XCTAssertEqual(out.text, r.text)
            // 1 少ないと 1 件減る
            if keep > 0 {
                let out2 = try await PromptBudget.fitHistory(r, contextLength: ctx - 1, maxTokens: 512) { Self.count($0) }
                XCTAssertEqual(out2.history, Array(r.history.suffix(keep - 1)), "keep=\(keep) ctx-1")
            }
        }
    }

    func testDropsAllWhenNothingFits() async throws {
        let r = request(pairs: 3)
        let out = try await PromptBudget.fitHistory(r, contextLength: 50, maxTokens: 512) { Self.count($0) }
        XCTAssertEqual(out.history, [])
        XCTAssertEqual(out.text, r.text)
    }

    func testFewTokenizationsForLongHistory() async throws {
        let r = request(pairs: 64)
        var calls = 0
        let reserve = PromptBudget.outputReserve(textTokens: Self.count(r.text), maxTokens: 512)
        let ctx = try Self.count(prompt(r, keeping: 20)) + reserve + 1
        let out = try await PromptBudget.fitHistory(r, contextLength: ctx, maxTokens: 512) { s in
            calls += 1
            return Self.count(s)
        }
        XCTAssertEqual(out.history.count, 20)
        XCTAssertLessThanOrEqual(calls, 2 + 7)   // 原文 + 全件 + 二分探索
    }
}

final class DocumentProgressTests: XCTestCase {
    func testTruncatedParagraphsDefaultsToZero() {
        let p = DocumentProgress(text: "a", totalParagraphs: 2, completedParagraphs: 1, isFinished: false)
        XCTAssertEqual(p.truncatedParagraphs, 0)
        XCTAssertEqual(p.fraction, 0.5)
        let q = DocumentProgress(text: "a", totalParagraphs: 2, completedParagraphs: 2, isFinished: true,
                                 truncatedParagraphs: 1)
        XCTAssertEqual(q.truncatedParagraphs, 1)
        XCTAssertNotEqual(p, q)
    }
}
