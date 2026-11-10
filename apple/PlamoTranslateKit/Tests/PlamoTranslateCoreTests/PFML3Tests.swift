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
        for ok in ["ja", "en", "zh-hans", "zh-hant", "fil", "ja-easy", "ja(easy)"] { XCTAssertTrue(PFML3.isValidLangCode(ok), ok) }
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
        // 既定は 0.8B の Q4_K_M
        XCTAssertEqual(ModelCatalog.defaultModel.size, "0.8b")
        XCTAssertEqual(ModelCatalog.defaultModel.defaultQuant, "Q4_K_M")
        XCTAssertEqual(ModelCatalog.defaultModel.defaultFile.quant, "Q4_K_M")
        XCTAssertEqual(ModelCatalog.spec(id: "plamo-3-translate-8b")?.minRamGB, 8)
        XCTAssertNil(ModelCatalog.spec(id: "nope"))
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count)
        for m in ModelCatalog.all {
            XCTAssertFalse(m.files.isEmpty, m.id)
            XCTAssertEqual(m.defaultFile.quant, m.defaultQuant, m.id)
            XCTAssertEqual(Set(m.files.map(\.quant)).count, m.files.count, m.id)
            for f in m.files {
                XCTAssertTrue(Self.matches(f.sha256, "^[0-9a-f]{64}$"), "sha256 must be 64 lowercase hex: \(f.file)")
                XCTAssertGreaterThan(f.sizeBytes, 0, f.file)
                XCTAssertTrue(f.file.hasSuffix(".gguf"), f.file)
                XCTAssertEqual(f.url.lastPathComponent, f.file)
                XCTAssertTrue(f.url.absoluteString.hasSuffix("/" + f.file), f.url.absoluteString)
            }
        }
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    func testLanguages() {
        XCTAssertEqual(LanguageCatalog.all.count, 53)
        XCTAssertEqual(LanguageCatalog.targets.count, 54)
        XCTAssertEqual(LanguageCatalog.name(for: "en"), "英語")
        XCTAssertEqual(LanguageCatalog.name(for: "ja-easy"), "やさしい日本語")
        XCTAssertEqual(LanguageCatalog.name(for: "ja(easy)"), "やさしい日本語")
        XCTAssertEqual(PFML3.normalizeLang("ja(easy)"), "ja-easy")
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

    func testCatalogURLsArePinnedToRevision() {
        // main などのブランチを指すと配布元の更新でサイズ・SHA-256 がずれるため、
        // 必ず 40 桁のコミット SHA に固定した URL を使う
        for m in ModelCatalog.all {
            for f in m.files {
                let url = f.url.absoluteString
                let pattern = "^https://huggingface\\.co/"
                    + NSRegularExpression.escapedPattern(for: m.repo)
                    + "/resolve/[0-9a-f]{40}/"
                    + NSRegularExpression.escapedPattern(for: f.file) + "$"
                XCTAssertTrue(Self.matches(url, pattern), url)
                XCTAssertFalse(url.contains("/resolve/main/"), url)
            }
        }
    }

    /// パッケージ内のコピーが shared/*.json と一致すること（apple/scripts/sync-shared.sh の実行忘れ検出）。
    func testBundledResourcesMatchShared() throws {
        // <repo>/apple/PlamoTranslateKit/Tests/PlamoTranslateCoreTests/<this file>
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PlamoTranslateCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PlamoTranslateKit
            .deletingLastPathComponent()   // apple
            .deletingLastPathComponent()   // <repo>
        let shared = repoRoot.appendingPathComponent("shared", isDirectory: true)
        guard FileManager.default.fileExists(atPath: shared.appendingPathComponent("models.json").path) else {
            throw XCTSkip("shared/ が見つからない（パッケージ単体でのテスト）: \(shared.path)")
        }
        for name in ["models", "languages"] {
            let expected = try Data(contentsOf: shared.appendingPathComponent(name + ".json"))
            XCTAssertEqual(SharedResource.data(name), expected,
                           "\(name).json が shared/ と異なります。apple/scripts/sync-shared.sh を実行してください")
        }
        let vectorsURL = try XCTUnwrap(Bundle.module.url(forResource: "pfml3-test-vectors", withExtension: "json"))
        XCTAssertEqual(try Data(contentsOf: vectorsURL),
                       try Data(contentsOf: shared.appendingPathComponent("pfml3-test-vectors.json")),
                       "pfml3-test-vectors.json が shared/ と異なります。apple/scripts/sync-shared.sh を実行してください")
    }
}
