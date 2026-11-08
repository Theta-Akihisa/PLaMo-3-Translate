import AppIntents
import Foundation

enum IntentLanguage: String, AppEnum {
    case ja, en
    case zhHans = "zh-hans"
    case zhHant = "zh-hant"
    case ko, fr, de, es, it, ru, vi, th, id

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "言語"

    static var caseDisplayRepresentations: [IntentLanguage: DisplayRepresentation] = [
        .ja: "日本語", .en: "英語", .zhHans: "中国語（簡体字）", .zhHant: "中国語（繁体字）",
        .ko: "韓国語", .fr: "フランス語", .de: "ドイツ語", .es: "スペイン語", .it: "イタリア語",
        .ru: "ロシア語", .vi: "ベトナム語", .th: "タイ語", .id: "インドネシア語",
    ]
}

/// ショートカット App 用。メモリの都合でアプリ本体を前面に出して実行する。
struct TranslateTextIntent: AppIntent {
    static var title: LocalizedStringResource = "PLaMoで翻訳"
    static var description = IntentDescription("PLaMo 3 Translate（端末内モデル）でテキストを翻訳します。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "テキスト")
    var text: String

    @Parameter(title: "翻訳先の言語", default: .ja)
    var targetLanguage: IntentLanguage

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw IntentError.message("翻訳するテキストが空です。")
        }
        let result = try await model.performTranslation(text: input, targetLang: targetLanguage.rawValue)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let m): return "\(m)"
        }
    }
}

struct PlamoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TranslateTextIntent(),
            phrases: ["\(.applicationName)で翻訳", "Translate with \(.applicationName)"],
            shortTitle: "PLaMoで翻訳",
            systemImageName: "character.bubble"
        )
    }
}
