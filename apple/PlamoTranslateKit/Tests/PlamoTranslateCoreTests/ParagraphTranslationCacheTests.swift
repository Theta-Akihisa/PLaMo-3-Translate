import Foundation
import XCTest
@testable import PlamoTranslateCore

final class ParagraphTranslationCacheTests: XCTestCase {
    private let model = "plamo-3-translate-2b"
    private let quant = "Q4_K_M"

    private func key(_ text: String, _ settings: TranslationSettings = TranslationSettings(),
                     model: String? = nil, quant: String? = nil) -> ParagraphTranslationCache.Key {
        ParagraphTranslationCache.key(for: text, settings: settings,
                                      modelID: model ?? self.model, quant: quant ?? self.quant)
    }

    // MARK: - Key

    func testIdenticalInputsHit() {
        var cache = ParagraphTranslationCache()
        let s = TranslationSettings(targetLang: "ja", sourceLang: "en", form: .polite, context: "ctx",
                                    glossary: [GlossaryEntry(source: "a", target: "あ")])
        XCTAssertTrue(cache.store("訳", for: key("Hello.", s)))
        XCTAssertEqual(cache.lookup(key("Hello.", s)), "訳")
        // 履歴・historyLimit・maxTokens・contextLength・settings 側の modelID はキーに入らない
        var s2 = s
        s2.useHistory = false
        s2.historyLimit = 9
        s2.maxTokens = 10
        s2.contextLength = 1024
        s2.modelID = "other"
        s2.quant = "Q8_0"
        XCTAssertEqual(cache.lookup(key("Hello.", s2)), "訳")
        let withHistory = s.makeRequest(text: "Hello.", history: [HistoryPair(source: "x", translation: "y")])
        XCTAssertEqual(cache.lookup(ParagraphTranslationCache.key(for: withHistory, modelID: model, quant: quant)), "訳")
    }

    func testKeySensitivity() {
        var cache = ParagraphTranslationCache()
        let base = TranslationSettings(targetLang: "ja", sourceLang: "en", form: .plain, context: "ctx",
                                       glossary: [GlossaryEntry(source: "a", target: "あ"),
                                                  GlossaryEntry(source: "b", target: "い")])
        cache.store("訳", for: key("Hello.", base))

        var variants: [(String, ParagraphTranslationCache.Key)] = []
        variants.append(("text", key("Hello!", base)))
        variants.append(("text whitespace", key("Hello. ", base)))
        var s = base; s.targetLang = "en"; s.form = nil
        variants.append(("target", key("Hello.", s)))
        s = base; s.sourceLang = nil
        variants.append(("source auto", key("Hello.", s)))
        s = base; s.sourceLang = "fr"
        variants.append(("source", key("Hello.", s)))
        s = base; s.form = .polite
        variants.append(("form", key("Hello.", s)))
        s = base; s.form = nil
        variants.append(("form nil", key("Hello.", s)))
        s = base; s.context = "other"
        variants.append(("context", key("Hello.", s)))
        s = base; s.context = ""
        variants.append(("context empty", key("Hello.", s)))
        s = base; s.glossary = [GlossaryEntry(source: "a", target: "あ")]
        variants.append(("glossary", key("Hello.", s)))
        s = base; s.glossary = base.glossary.reversed()
        variants.append(("glossary order", key("Hello.", s)))
        variants.append(("model", key("Hello.", base, model: "plamo-3-translate-8b")))
        variants.append(("quant", key("Hello.", base, quant: "Q8_0")))
        for (name, k) in variants {
            XCTAssertNil(cache.lookup(k), name)
        }
        XCTAssertEqual(cache.lookup(key("Hello.", base)), "訳")
    }

    func testKeyNormalization() {
        // 旧表記 ja(easy) は ja-easy と同じ
        var a = TranslationSettings(); a.targetLang = "ja(easy)"
        var b = TranslationSettings(); b.targetLang = "ja-easy"
        XCTAssertEqual(key("x", a), key("x", b))
        // 翻訳先が ja 以外なら文体は無視される
        var c = TranslationSettings(targetLang: "en", form: .polite)
        let d = TranslationSettings(targetLang: "en", form: nil)
        XCTAssertEqual(key("x", c), key("x", d))
        c.targetLang = "ja"
        XCTAssertNotEqual(key("x", c), key("x", TranslationSettings(targetLang: "ja", form: nil)))
        // 空白のみの文脈・空の用語集エントリは makeRequest と同じく無視される
        let e = TranslationSettings(context: "  \n", glossary: [GlossaryEntry(source: "", target: "x")])
        XCTAssertEqual(key("x", e), key("x", TranslationSettings()))
    }

    // MARK: - Store rules

    func testEmptyAndTruncatedOutputsAreNotStored() {
        var cache = ParagraphTranslationCache()
        XCTAssertFalse(cache.store("", for: key("a")))
        XCTAssertFalse(cache.store(" \n\t", for: key("a")))
        XCTAssertFalse(cache.store("途中まで", for: key("a"), truncated: true))
        XCTAssertTrue(cache.isEmpty)
        XCTAssertNil(cache.lookup(key("a")))
        XCTAssertEqual(cache.totalBytes, 0)
    }

    func testReplaceSameKey() {
        var cache = ParagraphTranslationCache()
        cache.store("one", for: key("a"))
        cache.store("three", for: key("a"))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.lookup(key("a")), "three")
        XCTAssertEqual(cache.totalBytes, 1 + 5)
    }

    // MARK: - Eviction

    func testEvictionByCountIsLeastRecentlyUsed() {
        var cache = ParagraphTranslationCache(maxEntries: 3, maxBytes: 1_000)
        cache.store("A", for: key("a"))
        cache.store("B", for: key("b"))
        cache.store("C", for: key("c"))
        // a を使うと b が最も古くなる
        XCTAssertEqual(cache.lookup(key("a")), "A")
        cache.store("D", for: key("d"))
        XCTAssertEqual(cache.count, 3)
        XCTAssertFalse(cache.contains(key("b")))
        XCTAssertTrue(cache.contains(key("a")))
        XCTAssertTrue(cache.contains(key("c")))
        XCTAssertTrue(cache.contains(key("d")))
        // 次は c
        cache.store("E", for: key("e"))
        XCTAssertFalse(cache.contains(key("c")))
        XCTAssertEqual(Set(["a", "d", "e"].filter { cache.contains(key($0)) }), ["a", "d", "e"])
        // contains は順序を変えない: a が最も古いまま
        cache.store("F", for: key("f"))
        XCTAssertFalse(cache.contains(key("a")))
    }

    func testEvictionByBytes() {
        // 1 件 = 原文 1 バイト + 訳文 9 バイト = 10 バイト
        var cache = ParagraphTranslationCache(maxEntries: 100, maxBytes: 25)
        cache.store("123456789", for: key("a"))
        cache.store("123456789", for: key("b"))
        XCTAssertEqual(cache.totalBytes, 20)
        cache.store("123456789", for: key("c"))
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.totalBytes, 20)
        XCTAssertFalse(cache.contains(key("a")))
        // 1 件で上限を超えるものは保存せず、既存も消さない
        XCTAssertFalse(cache.store(String(repeating: "x", count: 30), for: key("d")))
        XCTAssertEqual(cache.count, 2)
        // 大きめの 1 件で複数を追い出す
        XCTAssertTrue(cache.store(String(repeating: "y", count: 20), for: key("e")))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalBytes, 21)
    }

    func testRemoveAllAndRemove() {
        var cache = ParagraphTranslationCache(maxEntries: 2, maxBytes: 1_000)
        cache.store("A", for: key("a"))
        cache.store("B", for: key("b"))
        XCTAssertEqual(cache.remove(key("a")), "A")
        XCTAssertEqual(cache.totalBytes, 2)
        cache.removeAll()
        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(cache.totalBytes, 0)
        // 消去後も LRU が正しく動く
        cache.store("C", for: key("c"))
        cache.store("D", for: key("d"))
        _ = cache.lookup(key("c"))
        cache.store("E", for: key("e"))
        XCTAssertTrue(cache.contains(key("c")))
        XCTAssertFalse(cache.contains(key("d")))
    }

    func testManyOperationsStayWithinBounds() {
        var cache = ParagraphTranslationCache(maxEntries: 50, maxBytes: 600)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<5_000 {
            let k = key("p\(Int.random(in: 0..<200, using: &rng))")
            if i % 3 == 0 {
                _ = cache.lookup(k)
            } else {
                cache.store(String(repeating: "z", count: Int.random(in: 1..<40, using: &rng)), for: k)
            }
            XCTAssertLessThanOrEqual(cache.count, 50)
            XCTAssertLessThanOrEqual(cache.totalBytes, 600)
        }
    }

    // MARK: - Document flow (Translator.translateDocument と同じ手順)

    /// キャッシュを引き、無ければ `translate` で訳して保存しながら文書を組み立てる。
    private func run(_ source: String, cache: inout ParagraphTranslationCache, settings: TranslationSettings,
                     translate: (String) -> String) -> (snapshot: DocumentAssembler.Snapshot, reused: Int, translated: [String]) {
        var doc = DocumentAssembler(source: source)
        var reused = 0
        var translated: [String] = []
        while let src = doc.beginNextParagraph() {
            let k = ParagraphTranslationCache.key(for: settings.makeRequest(text: src), modelID: model, quant: quant)
            if let hit = cache.lookup(k) {
                doc.complete(output: hit)
                reused += 1
                continue
            }
            let out = translate(src)
            translated.append(src)
            doc.complete(output: out)
            cache.store(out, for: k)
        }
        return (doc.snapshot(), reused, translated)
    }

    func testEditInTheMiddleReusesUnchangedParagraphs() {
        var cache = ParagraphTranslationCache()
        let settings = TranslationSettings()
        let fake: (String) -> String = { "<" + $0.uppercased() + ">" }

        let v1 = "alpha\n\nbravo\n\ncharlie\n\ndelta\n"
        let r1 = run(v1, cache: &cache, settings: settings, translate: fake)
        XCTAssertEqual(r1.reused, 0)
        XCTAssertEqual(r1.translated, ["alpha", "bravo", "charlie", "delta"])

        // 中央の段落を編集し、段落を 1 つ追加
        let v2 = "alpha\n\nbravo!\n\ncharlie\n\necho\n\ndelta\n"
        let r2 = run(v2, cache: &cache, settings: settings, translate: fake)
        XCTAssertEqual(r2.translated, ["bravo!", "echo"])
        XCTAssertEqual(r2.reused, 3)
        // キャッシュ由来でも fresh でも、組み立て結果と対応は一括計算と同じ
        let expected = DocumentAssembler.assemble(source: v2, outputs: TextSegmenter.paragraphs(v2).map(fake))
        XCTAssertEqual(r2.snapshot, expected)
        XCTAssertEqual(r2.snapshot.text, "<ALPHA>\n\n<BRAVO!>\n\n<CHARLIE>\n\n<ECHO>\n\n<DELTA>\n")

        // 設定を変えると全段落が再翻訳される
        var other = settings
        other.context = "new context"
        let r3 = run(v2, cache: &cache, settings: other, translate: fake)
        XCTAssertEqual(r3.reused, 0)
        XCTAssertEqual(r3.translated.count, 5)
    }

    func testDocumentProgressReusedDefaultsToZero() {
        let p = DocumentProgress(text: "", totalParagraphs: 1, completedParagraphs: 0, isFinished: false)
        XCTAssertEqual(p.reusedParagraphs, 0)
        let q = DocumentProgress(text: "x", totalParagraphs: 2, completedParagraphs: 2, isFinished: true,
                                 truncatedParagraphs: 0, alignment: [], reusedParagraphs: 1)
        XCTAssertEqual(q.reusedParagraphs, 1)
    }
}
