import XCTest
import PlamoTranslateCore
@testable import PlamoTranslateApp

// 入力しながらの翻訳で、変わっていない部分を訳し直さないための純粋な処理（App/Shared/LiveTranslation.swift）

final class TranslationRoutingTests: XCTestCase {
    func testSingleParagraphUsesSingleShot() {
        XCTAssertFalse(TranslationRouting.usesParagraphs("Hello world.", incremental: true))
        // 段落内の改行（空行ではない）は 1 段落
        XCTAssertFalse(TranslationRouting.usesParagraphs("Line 1\nLine 2\r\nLine 3", incremental: true))
        XCTAssertFalse(TranslationRouting.usesParagraphs("", incremental: true))
    }

    func testMultipleParagraphsUseParagraphPathOnlyWhenIncremental() {
        let text = "First paragraph.\n\nSecond paragraph."
        XCTAssertTrue(TranslationRouting.usesParagraphs(text, incremental: true))
        // クイック翻訳・ショートカット・サービスはこれまでどおり（短ければ 1 回で翻訳）
        XCTAssertFalse(TranslationRouting.usesParagraphs(text, incremental: false))
    }

    func testBlankLinesWithSpacesAndCRLFSeparateParagraphs() {
        XCTAssertTrue(TranslationRouting.hasMultipleParagraphs("A\r\n\r\nB"))
        XCTAssertTrue(TranslationRouting.hasMultipleParagraphs("A\n \u{3000}\t\nB"))
        XCTAssertTrue(TranslationRouting.hasMultipleParagraphs("A\r\rB"))
        // 前後の空行だけでは段落は増えない
        XCTAssertFalse(TranslationRouting.hasMultipleParagraphs("\n\nA\n\n"))
        XCTAssertFalse(TranslationRouting.hasMultipleParagraphs("  \n\n  "))
    }

    func testLongTextAlwaysUsesParagraphPath() {
        let long = String(repeating: "a", count: TranslationRouting.longTextThreshold + 1)
        XCTAssertTrue(TranslationRouting.usesParagraphs(long, incremental: false))
        XCTAssertTrue(TranslationRouting.usesParagraphs(long, incremental: true))
        let exact = String(repeating: "a", count: TranslationRouting.longTextThreshold)
        XCTAssertFalse(TranslationRouting.usesParagraphs(exact, incremental: false))
    }
}

final class TranslationMemoTests: XCTestCase {
    private func key(_ text: String = "Hello", target: String = "ja", source: String? = "en",
                     form: TranslationForm? = .polite, context: String? = "tech",
                     glossary: [GlossaryEntry] = [GlossaryEntry(source: "app", target: "アプリ")],
                     history: [HistoryPair] = [], model: String = "plamo-2b", quant: String = "Q4_K_M") -> TranslationMemoKey {
        ParagraphTranslationCache.key(for: TranslationRequest(text: text, targetLang: target, sourceLang: source, form: form,
                                                              context: context, glossary: glossary, history: history),
                                      modelID: model, quant: quant)
    }

    func testKeyIsSensitiveToEverythingSentToTheModelExceptHistory() {
        let base = key()
        XCTAssertEqual(base, key(history: [HistoryPair(source: "Hi", translation: "やあ")]))
        XCTAssertNotEqual(base, key("Hello!"))
        XCTAssertNotEqual(base, key(target: "en"))
        XCTAssertNotEqual(base, key(source: nil))
        XCTAssertNotEqual(base, key(source: "fr"))
        XCTAssertNotEqual(base, key(form: .plain))
        XCTAssertNotEqual(base, key(context: nil))
        XCTAssertNotEqual(base, key(glossary: []))
        XCTAssertNotEqual(base, key(model: "plamo-8b"))
        XCTAssertNotEqual(base, key(quant: "Q8_0"))
        // 文体は訳文が日本語のときだけ効く
        XCTAssertEqual(key(target: "en", form: .plain), key(target: "en", form: .polite))
    }

    func testHitPromotesAndEvictsLeastRecentlyUsed() {
        var memo = TranslationMemo<TranslationMemoKey, String>(capacity: 2)
        let a = key("A"), b = key("B"), c = key("C")
        memo.insert("a", for: a)
        memo.insert("b", for: b)
        XCTAssertEqual(memo.value(for: a), "a")   // a が最近使ったものになる
        memo.insert("c", for: c)                  // b が捨てられる
        XCTAssertEqual(memo.count, 2)
        XCTAssertNil(memo.value(for: b))
        XCTAssertEqual(memo.value(for: a), "a")
        XCTAssertEqual(memo.value(for: c), "c")
    }

    func testInsertReplacesSameKeyAndRemoveAll() {
        var memo = TranslationMemo<TranslationMemoKey, String>(capacity: 3)
        memo.insert("old", for: key())
        memo.insert("new", for: key(history: [HistoryPair(source: "x", translation: "y")]))
        XCTAssertEqual(memo.count, 1)
        XCTAssertEqual(memo.value(for: key()), "new")
        memo.removeAll()
        XCTAssertEqual(memo.count, 0)
        XCTAssertNil(memo.value(for: key()))
    }

    func testZeroCapacityKeepsNothing() {
        var memo = TranslationMemo<String, String>(capacity: 0)
        memo.insert("v", for: "k")
        XCTAssertNil(memo.value(for: "k"))
    }
}

final class StickySourceLanguageTests: XCTestCase {
    func testUnsureDetectionKeepsPreviousLanguage() {
        var sticky = StickySourceLanguage()
        XCTAssertNil(sticky.resolve(nil))
        XCTAssertEqual(sticky.resolve("en"), "en")
        XCTAssertEqual(sticky.resolve(nil), "en")    // 確信度が下がっても英語のまま（キャッシュのキーが変わらない）
        XCTAssertEqual(sticky.resolve("fr"), "fr")   // 別の言語をはっきり検出したら切り替える
        sticky.reset()
        XCTAssertNil(sticky.resolve(nil))
    }
}

final class LiveOutputPolicyTests: XCTestCase {
    func testAlwaysAcceptsWhenNotShowingPreviousOutput() {
        XCTAssertTrue(LiveOutputPolicy.acceptsProgress("", previous: nil))
        XCTAssertTrue(LiveOutputPolicy.acceptsProgress("Hel", previous: nil))
    }

    func testKeepsPreviousOutputUntilTheNewOneDiffers() {
        let previous = "First translated.\n\nSecond translated."
        // 空・空白だけの途中経過で訳文を消さない
        XCTAssertFalse(LiveOutputPolicy.acceptsProgress("", previous: previous))
        XCTAssertFalse(LiveOutputPolicy.acceptsProgress("\n\n ", previous: previous))
        // 使い回した段落（前の訳の先頭部分のまま）では縮めない
        XCTAssertFalse(LiveOutputPolicy.acceptsProgress("First translated.\n\n", previous: previous))
        XCTAssertFalse(LiveOutputPolicy.acceptsProgress("First translated.\n\nSec", previous: previous))
        // 新しい訳が違ってきたら書き換える（末尾だけが変わる）
        XCTAssertTrue(LiveOutputPolicy.acceptsProgress("First translated.\n\nAnother", previous: previous))
        XCTAssertTrue(LiveOutputPolicy.acceptsProgress(previous + "\n\nThird", previous: previous))
        // 前の訳と同じ・違う訳が最初から来る
        XCTAssertFalse(LiveOutputPolicy.acceptsProgress(previous, previous: previous))
        XCTAssertTrue(LiveOutputPolicy.acceptsProgress("Totally new", previous: previous))
    }

    func testFirstAcceptedProgressKeepsTheUnchangedPrefixForATailEdit() {
        // 編集した段落より前の訳は同じなので、訳文ペインは末尾だけの書き換えになる（スクロール位置・レイアウトを保つ）
        let previous = String(repeating: "Unchanged paragraph translation. ", count: 3) + "\n\nOld tail."
        let progress = String(repeating: "Unchanged paragraph translation. ", count: 3) + "\n\nNew"
        XCTAssertTrue(LiveOutputPolicy.acceptsProgress(progress, previous: previous))
        let edit = TextTailEdit.make(from: previous, to: progress)
        XCTAssertNotNil(edit)
        XCTAssertEqual(edit?.range.location, (previous as NSString).length - ("Old tail." as NSString).length)
        XCTAssertEqual(edit?.replacement, "New")
    }
}
