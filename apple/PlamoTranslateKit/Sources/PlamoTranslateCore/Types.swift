import Foundation

/// 日本語出力の文体。`targetLang == "ja"` のときのみ指定可能。
public enum TranslationForm: String, Codable, Sendable, CaseIterable {
    case plain
    case polite
}

public struct GlossaryEntry: Codable, Hashable, Sendable {
    public var source: String
    public var target: String
    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

public struct HistoryPair: Codable, Hashable, Sendable {
    public var source: String
    public var translation: String
    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

public struct TranslationRequest: Codable, Hashable, Sendable {
    public var text: String
    public var targetLang: String
    public var sourceLang: String?
    public var form: TranslationForm?
    public var context: String?
    public var glossary: [GlossaryEntry]
    public var history: [HistoryPair]

    public init(
        text: String,
        targetLang: String = "ja",
        sourceLang: String? = nil,
        form: TranslationForm? = nil,
        context: String? = nil,
        glossary: [GlossaryEntry] = [],
        history: [HistoryPair] = []
    ) {
        self.text = text
        self.targetLang = targetLang
        self.sourceLang = sourceLang
        self.form = form
        self.context = context
        self.glossary = glossary
        self.history = history
    }
}

/// アプリが永続化する翻訳設定。
public struct TranslationSettings: Codable, Hashable, Sendable {
    public var targetLang: String
    public var sourceLang: String?
    public var form: TranslationForm?
    public var context: String
    public var glossary: [GlossaryEntry]
    public var useHistory: Bool
    public var historyLimit: Int
    public var modelID: String
    public var quant: String
    public var contextLength: Int
    public var maxTokens: Int

    public init(
        targetLang: String = "ja",
        sourceLang: String? = nil,
        form: TranslationForm? = nil,
        context: String = "",
        glossary: [GlossaryEntry] = [],
        useHistory: Bool = true,
        historyLimit: Int = 3,
        modelID: String = "plamo-3-translate-0.8b",
        quant: String = "Q4_K_M",
        contextLength: Int = 8192,
        maxTokens: Int = 2048
    ) {
        self.targetLang = targetLang
        self.sourceLang = sourceLang
        self.form = form
        self.context = context
        self.glossary = glossary
        self.useHistory = useHistory
        self.historyLimit = historyLimit
        self.modelID = modelID
        self.quant = quant
        self.contextLength = contextLength
        self.maxTokens = maxTokens
    }

    /// 設定からリクエストを作る（`history` は呼び出し側で付与）。
    public func makeRequest(text: String, history: [HistoryPair] = []) -> TranslationRequest {
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranslationRequest(
            text: text,
            targetLang: targetLang,
            sourceLang: sourceLang,
            // form は日本語出力のときのみ有効
            form: targetLang == "ja" ? form : nil,
            context: ctx.isEmpty ? nil : context,
            glossary: glossary.filter { !$0.source.isEmpty && !$0.target.isEmpty },
            history: history
        )
    }
}

/// 文書翻訳の進捗。`text` は完了済みの段落＋翻訳中の途中結果＋区切りを連結した、現時点の全訳文。
public struct DocumentProgress: Sendable, Equatable {
    public var text: String
    /// 翻訳対象の段落数
    public var totalParagraphs: Int
    /// 翻訳が完了した段落数（打ち切られた段落も含む）
    public var completedParagraphs: Int
    public var isFinished: Bool
    /// 出力がトークン上限に達して途中で打ち切られた段落の数（その段落の途中までの訳は `text` に含まれる）
    public var truncatedParagraphs: Int
    public init(text: String, totalParagraphs: Int, completedParagraphs: Int, isFinished: Bool,
                truncatedParagraphs: Int = 0) {
        self.text = text
        self.totalParagraphs = totalParagraphs
        self.completedParagraphs = completedParagraphs
        self.isFinished = isFinished
        self.truncatedParagraphs = truncatedParagraphs
    }
    public var fraction: Double {
        totalParagraphs == 0 ? 1 : Double(completedParagraphs) / Double(totalParagraphs)
    }
}
