import Foundation

public struct Language: Codable, Hashable, Sendable, Identifiable {
    public var code: String
    public var ja: String
    public var en: String
    public var id: String { code }
    public init(code: String, ja: String, en: String) {
        self.code = code; self.ja = ja; self.en = en
    }
}

public enum LanguageCatalog {
    private struct File: Decodable { let languages: [Language] }

    /// 対応 53 言語（`shared/languages.json`）。
    public static let all: [Language] = {
        do { return try JSONDecoder().decode(File.self, from: SharedResource.data("languages")).languages }
        catch { fatalError("languages.json の読み込みに失敗: \(error)") }
    }()

    /// 翻訳先として選べる言語（`all` + やさしい日本語）。
    public static let targets: [Language] = {
        var t = all
        if !t.contains(where: { $0.code == "ja(easy)" }) {
            t.append(Language(code: "ja(easy)", ja: "やさしい日本語", en: "Easy Japanese"))
        }
        return t
    }()

    /// 表示名（日本語）。未知のコードはコードそのまま。
    public static func name(for code: String) -> String {
        targets.first { $0.code == code }?.ja ?? code
    }
}
