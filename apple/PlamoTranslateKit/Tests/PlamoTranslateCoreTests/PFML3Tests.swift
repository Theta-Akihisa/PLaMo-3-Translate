import XCTest
@testable import PlamoTranslateCore

private struct Vectors: Decodable {
    struct Input: Decodable {
        struct G: Decodable { let source: String; let target: String }
        struct H: Decodable { let source: String; let translation: String }
        let text: String
        let target_lang: String?
        let source_lang: String?
        let form: String?
        let context: String?
        let glossary: [G]?
        let history: [H]?
    }
    struct Vector: Decodable { let name: String; let input: Input; let prompt: String }
    let stop: [String]
    let vectors: [Vector]
}

final class PFML3Tests: XCTestCase {
    private func loadVectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pfml3-test-vectors", withExtension: "json"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testAllVectorsMatchExactly() throws {
        let v = try loadVectors()
        XCTAssertEqual(v.stop, PFML3.stopStrings)
        XCTAssertFalse(v.vectors.isEmpty)
        for vec in v.vectors {
            let i = vec.input
            let req = TranslationRequest(
                text: i.text,
                targetLang: i.target_lang ?? "ja",
                sourceLang: i.source_lang,
                form: i.form.flatMap(TranslationForm.init(rawValue:)),
                context: i.context,
                glossary: (i.glossary ?? []).map { GlossaryEntry(source: $0.source, target: $0.target) },
                history: (i.history ?? []).map { HistoryPair(source: $0.source, translation: $0.translation) }
            )
            XCTAssertEqual(try PFML3.buildPrompt(req), vec.prompt, "vector: \(vec.name)")
        }
    }

    func testRejectsReservedToken() {
        XCTAssertThrowsError(try PFML3.buildPrompt(.init(text: "a <|plamo:tag|> b")))
        XCTAssertThrowsError(try PFML3.buildPrompt(.init(text: "a", context: "<|plamo:msg|>")))
        XCTAssertThrowsError(try PFML3.buildPrompt(.init(text: "a", glossary: [.init(source: "<|plamo:x", target: "y")])))
        XCTAssertThrowsError(try PFML3.buildPrompt(.init(text: "a", history: [.init(source: "b", translation: "<|plamo:x")])))
    }

    func testRejectsEmptyText() {
        XCTAssertThrowsError(try PFML3.buildPrompt(.init(text: "")))
        XCTAssertThrowsError(try PFML3.buildPrompt(.init(text: " \n\t ")))
    }

    func testLanguageValidation() {
        for ok in ["ja", "en", "zh-hans", "zh-hant", "fil", "ja(easy)"] { XCTAssertTrue(PFML3.isValidLangCode(ok), ok) }
        for bad in ["", "J", "EN", "english", "en-US", "zh-han", "zh-hans-x", "en_us", "e1", "ja(easy"] {
            XCTAssertFalse(PFML3.isValidLangCode(bad), bad)
        }
        XCTAssertThrowsError(try PFML3.buildPrompt(.init(text: "a", targetLang: "EN")))
        XCTAssertThrowsError(try PFML3.buildPrompt(.init(text: "a", sourceLang: "xx-yy")))
    }

    func testFormOnlyForJapanese() {
        XCTAssertThrowsError(try PFML3.buildPrompt(.init(text: "a", targetLang: "en", form: .polite))) { e in
            XCTAssertEqual(e as? PFML3Error, .formRequiresJapanese)
            XCTAssertNotNil((e as? PFML3Error)?.errorDescription)
        }
        XCTAssertThrowsError(try PFML3.buildPrompt(.init(text: "a", targetLang: "ja(easy)", form: .plain)))
        XCTAssertNoThrow(try PFML3.buildPrompt(.init(text: "a", targetLang: "ja", form: .plain)))
    }

    func testCleanOutput() {
        XCTAssertEqual(PFML3.cleanOutput("  こんにちは。\n<|plamo:tag|>input"), "こんにちは。")
        XCTAssertEqual(PFML3.cleanOutput("Hello<|plamo:bos|>"), "Hello")
        XCTAssertEqual(PFML3.cleanOutput("\nA\nB \n"), "A\nB")
    }
}

final class SegmenterTests: XCTestCase {
    private func roundTrip(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(TextSegmenter.join(TextSegmenter.segments(s)), s, file: file, line: line)
    }

    func testBasicParagraphs() {
        let segs = TextSegmenter.segments("A\nA2\n\nB")
        XCTAssertEqual(segs, [.text("A\nA2"), .separator("\n\n"), .text("B")])
        XCTAssertEqual(TextSegmenter.paragraphs("A\nA2\n\nB"), ["A\nA2", "B"])
    }

    func testSeparatorsPreserved() {
        let s = "\n\nFirst\n\n\n  \nSecond\n"
        XCTAssertEqual(TextSegmenter.segments(s),
                       [.separator("\n\n"), .text("First"), .separator("\n\n\n  \n"), .text("Second"), .separator("\n")])
        roundTrip(s)
    }

    func testEdgeCases() {
        XCTAssertEqual(TextSegmenter.segments(""), [])
        XCTAssertEqual(TextSegmenter.segments("   \n \n"), [.separator("   \n \n")])
        XCTAssertEqual(TextSegmenter.segments("one"), [.text("one")])
        for s in ["", "a", "a\n", "\na", "a\n\n", "a\r\n\r\nb", "a\n \nb\n\n\nc\n", "\n\n\n", "  x  \n\n y"] { roundTrip(s) }
    }

    func testWhitespaceOnlyNotTranslated() {
        XCTAssertTrue(TextSegmenter.paragraphs(" \n\n \n").isEmpty)
    }
}

final class CatalogTests: XCTestCase {
    func testModels() {
        XCTAssertEqual(ModelCatalog.all.count, 3)
        XCTAssertEqual(ModelCatalog.defaultModel.size, "0.8b")
        XCTAssertEqual(ModelCatalog.defaultModel.defaultQuant, "Q4_K_M")
        XCTAssertEqual(ModelCatalog.defaultModel.defaultFile.sizeBytes, 573123200)
        XCTAssertEqual(ModelCatalog.spec(id: "plamo-3-translate-8b")?.minRamGB, 8)
        XCTAssertNil(ModelCatalog.spec(id: "nope"))
        for m in ModelCatalog.all {
            XCTAssertFalse(m.files.isEmpty)
            XCTAssertEqual(m.defaultFile.quant, m.defaultQuant)
            for f in m.files {
                XCTAssertEqual(f.sha256.count, 64)
                XCTAssertTrue(f.sizeBytes > 0)
                XCTAssertTrue(f.url.absoluteString.hasSuffix(f.file))
            }
        }
        XCTAssertEqual(ModelCatalog.all.first { $0.size == "2b" }?.defaultFile.sizeBytes, 1807199392)
        XCTAssertEqual(ModelCatalog.all.first { $0.size == "8b" }?.defaultFile.sizeBytes, 5280442080)
    }

    func testLanguages() {
        XCTAssertEqual(LanguageCatalog.all.count, 53)
        XCTAssertEqual(LanguageCatalog.targets.count, 54)
        XCTAssertEqual(LanguageCatalog.name(for: "en"), "英語")
        XCTAssertEqual(LanguageCatalog.name(for: "ja(easy)"), "やさしい日本語")
        XCTAssertEqual(LanguageCatalog.name(for: "zz"), "zz")
        for l in LanguageCatalog.targets { XCTAssertTrue(PFML3.isValidLangCode(l.code), l.code) }
    }

    func testSettingsRequest() {
        var s = TranslationSettings()
        s.form = .polite
        s.context = "  "
        XCTAssertEqual(s.makeRequest(text: "x").form, .polite)
        XCTAssertNil(s.makeRequest(text: "x").context)
        s.targetLang = "en"
        XCTAssertNil(s.makeRequest(text: "x").form)
        let data = try? JSONEncoder().encode(s)
        XCTAssertEqual(try? JSONDecoder().decode(TranslationSettings.self, from: data ?? Data()), s)
    }
}
