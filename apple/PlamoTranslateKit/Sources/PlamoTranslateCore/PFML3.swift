import Foundation

public enum PFML3Error: LocalizedError, Equatable, Sendable {
    case emptyText(field: String)
    case reservedToken(field: String)
    case invalidLanguage(field: String, value: String)
    case formRequiresJapanese

    public var errorDescription: String? {
        switch self {
        case .emptyText(let f): return "\(f)が空です。"
        case .reservedToken(let f): return "\(f)に予約済みトークン（<|plamo:…）を含めることはできません。"
        case .invalidLanguage(let f, let v): return "\(f)の言語コード「\(v)」が不正です（例: en, ja, zh-hans, ja(easy)）。"
        case .formRequiresJapanese: return "文体（form）は翻訳先が日本語（ja）のときのみ指定できます。"
        }
    }
}

/// PFML3 プロンプトの組み立て（公式チャットテンプレートと同一出力）。
/// 先頭の `<|plamo:bos|>` は含めない（トークナイズ時に BOS を付加する）。
public enum PFML3 {
    public static let stopStrings = ["<|plamo:tag|>", "<|plamo:bos|>"]

    private static let reserved = "<|plamo:"

    /// 空判定は ASCII 空白（space, tab, CR, LF）のみ（公式テンプレートに合わせる）。
    private static func isBlank(_ s: String) -> Bool {
        for u in s.unicodeScalars where !(u == " " || u == "\t" || u == "\r" || u == "\n") { return false }
        return true
    }

    private static func checkText(_ s: String, _ name: String) throws {
        if isBlank(s) { throw PFML3Error.emptyText(field: name) }
        if s.contains(reserved) { throw PFML3Error.reservedToken(field: name) }
    }

    /// 小文字 2-3 文字、任意で `-` + 4 文字のスクリプト、または `ja(easy)`。
    public static func isValidLangCode(_ v: String) -> Bool {
        if v == "ja(easy)" { return true }
        let parts = v.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 2, let head = parts.first else { return false }
        func lower(_ s: Substring) -> Bool {
            !s.isEmpty && s.utf8.allSatisfy { $0 >= 97 && $0 <= 122 }
        }
        guard lower(head), head.count == 2 || head.count == 3 else { return false }
        if parts.count == 2 { return lower(parts[1]) && parts[1].count == 4 }
        return true
    }

    private static func checkLang(_ v: String, _ name: String) throws {
        try checkText(v, name)
        if !isValidLangCode(v) { throw PFML3Error.invalidLanguage(field: name, value: v) }
    }

    public static func buildPrompt(_ r: TranslationRequest) throws -> String {
        try checkText(r.text, "原文")
        try checkLang(r.targetLang, "翻訳先言語")
        if let s = r.sourceLang { try checkLang(s, "翻訳元言語") }
        if r.form != nil && r.targetLang != "ja" { throw PFML3Error.formRequiresJapanese }

        var out = "<|plamo:tag|>dataset<|plamo:msg|>translation"

        if let c = r.context, !isBlank(c) {
            try checkText(c, "文脈")
            out += "<|plamo:tag|>context<|plamo:msg|>" + c
        }

        let srcKey = r.sourceLang.map { "<|plamo:key|>lang<|plamo:val|>" + $0 } ?? ""
        for h in r.history {
            try checkText(h.source, "履歴の原文")
            try checkText(h.translation, "履歴の訳文")
            out += "<|plamo:tag|>input" + srcKey + "<|plamo:msg|>" + h.source
            out += "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + r.targetLang + "<|plamo:msg|>" + h.translation
        }

        if !r.glossary.isEmpty {
            out += "<|plamo:tag|>glossary"
            for g in r.glossary {
                try checkText(g.source, "用語集の原語")
                try checkText(g.target, "用語集の訳語")
                out += "<|plamo:index|>" + g.source + "<|plamo:item|>" + g.target
            }
        }

        out += "<|plamo:tag|>input" + srcKey + "<|plamo:msg|>" + r.text
        out += "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + r.targetLang
        if let f = r.form { out += "<|plamo:key|>form<|plamo:val|>" + f.rawValue }
        out += "<|plamo:msg|>"
        return out
    }

    /// 生成結果から停止文字列以降を取り除き、前後の空白を trim する。
    public static func cleanOutput(_ s: String) -> String {
        var end = s.endIndex
        for stop in stopStrings {
            if let r = s.range(of: stop), r.lowerBound < end { end = r.lowerBound }
        }
        return String(s[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
