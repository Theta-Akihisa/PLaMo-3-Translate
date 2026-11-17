import Foundation

/// 文書翻訳（`Translator.translateDocument`）の段落単位の訳文キャッシュ。上限つきの LRU。
///
/// キーは段落の原文そのものと、出力を変えうる設定（正規化した翻訳先・翻訳元言語、文体、文脈、用語集）、
/// 読み込み済みモデルの ID と量子化。**history（直前の段落）はキーに含めない**:
/// 前後の段落が変わっても、原文と設定が同じ段落は以前の訳文を再利用する（意図した動作）。
///
/// 値は整形済み（`PFML3.cleanOutput` 後）の訳文。空の出力・打ち切られた出力は保存しない。
/// 件数（既定 4,000）または原文＋訳文の UTF-8 バイト数（既定 約 4 MB）のどちらかを超えたら、
/// 最も長く使われていないものから捨てる。
///
/// 値型なので、共有する場合は 1 つの隔離領域（`Translator` では MainActor）に置くこと。
public struct ParagraphTranslationCache: Sendable {
    public struct Key: Hashable, Sendable {
        /// 段落の原文（完全一致）
        public var text: String
        /// `PFML3.normalizeLang` 済みの翻訳先言語
        public var targetLang: String
        /// `PFML3.normalizeLang` 済みの翻訳元言語（自動なら nil）
        public var sourceLang: String?
        /// 文体（翻訳先が `ja` のときのみ。それ以外は nil）
        public var form: TranslationForm?
        public var context: String?
        /// 用語集（順序も区別する）
        public var glossary: [GlossaryEntry]
        public var modelID: String
        public var quant: String

        public init(text: String, targetLang: String, sourceLang: String?, form: TranslationForm?,
                    context: String?, glossary: [GlossaryEntry], modelID: String, quant: String) {
            self.text = text
            self.targetLang = targetLang
            self.sourceLang = sourceLang
            self.form = form
            self.context = context
            self.glossary = glossary
            self.modelID = modelID
            self.quant = quant
        }
    }

    public static let defaultMaxEntries = 4_000
    public static let defaultMaxBytes = 4_000_000

    /// 保持する最大件数
    public let maxEntries: Int
    /// 保持する原文＋訳文の最大 UTF-8 バイト数（1 件でこれを超えるものは保存しない）
    public let maxBytes: Int
    /// 保持している原文＋訳文の UTF-8 バイト数
    public private(set) var totalBytes = 0

    private struct Entry: Sendable {
        var output: String
        var tick: UInt64
        var bytes: Int
    }

    private var entries: [Key: Entry] = [:]
    /// 最終使用時刻（単調増加のカウンタ）→ キー。生きている tick のみ持つ
    private var order: [UInt64: Key] = [:]
    /// 次に払い出す tick
    private var nextTick: UInt64 = 0
    /// これより小さい tick は `order` に存在しない（追い出しの走査開始位置）
    private var oldestTick: UInt64 = 0

    public init(maxEntries: Int = ParagraphTranslationCache.defaultMaxEntries,
                maxBytes: Int = ParagraphTranslationCache.defaultMaxBytes) {
        self.maxEntries = max(0, maxEntries)
        self.maxBytes = max(0, maxBytes)
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    // MARK: - Key

    /// 実際にモデルへ送るリクエストからキーを作る（`request.history` は無視する）。
    public static func key(for request: TranslationRequest, modelID: String, quant: String) -> Key {
        let target = PFML3.normalizeLang(request.targetLang)
        return Key(text: request.text,
                   targetLang: target,
                   sourceLang: request.sourceLang.map(PFML3.normalizeLang),
                   form: target == "ja" ? request.form : nil,
                   context: request.context,
                   glossary: request.glossary,
                   modelID: modelID,
                   quant: quant)
    }

    /// 段落の原文と設定からキーを作る（`settings.makeRequest(text:)` と同じ正規化。
    /// `settings.modelID` / `quant` ではなく、実際に読み込まれているモデルを渡すこと）。
    public static func key(for paragraph: String, settings: TranslationSettings,
                           modelID: String, quant: String) -> Key {
        key(for: settings.makeRequest(text: paragraph), modelID: modelID, quant: quant)
    }

    // MARK: - Lookup / store

    /// キャッシュ済みの訳文。見つかれば最近使ったものとして扱う。
    public mutating func lookup(_ key: Key) -> String? {
        guard var entry = entries[key] else { return nil }
        order[entry.tick] = nil
        entry.tick = issueTick()
        order[entry.tick] = key
        entries[key] = entry
        return entry.output
    }

    /// 使用順を変えずに有無だけ調べる。
    public func contains(_ key: Key) -> Bool { entries[key] != nil }

    /// 訳文を保存する。打ち切られた出力・空白のみの出力・1 件で `maxBytes` を超えるものは保存せず false を返す。
    /// 同じキーがあれば置き換える。保存後、上限を超えた分を古いものから捨てる。
    @discardableResult
    public mutating func store(_ output: String, for key: Key, truncated: Bool = false) -> Bool {
        guard !truncated, output.contains(where: { !$0.isWhitespace }) else { return false }
        let bytes = key.text.utf8.count + output.utf8.count
        guard maxEntries > 0, bytes <= maxBytes else { return false }
        if let old = entries.removeValue(forKey: key) {
            order[old.tick] = nil
            totalBytes -= old.bytes
        }
        let tick = issueTick()
        entries[key] = Entry(output: output, tick: tick, bytes: bytes)
        order[tick] = key
        totalBytes += bytes
        while entries.count > maxEntries || totalBytes > maxBytes {
            guard evictOldest() else { break }
        }
        return true
    }

    /// 1 件削除する。
    @discardableResult
    public mutating func remove(_ key: Key) -> String? {
        guard let old = entries.removeValue(forKey: key) else { return nil }
        order[old.tick] = nil
        totalBytes -= old.bytes
        return old.output
    }

    /// すべて削除する。
    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalBytes = 0
        nextTick = 0
        oldestTick = 0
    }

    // MARK: - LRU

    private mutating func issueTick() -> UInt64 {
        let t = nextTick
        nextTick += 1
        return t
    }

    /// 最も古いものを 1 件捨てる。tick は単調増加なので、空いた tick を読み飛ばすだけでよい（償却 O(1)）。
    private mutating func evictOldest() -> Bool {
        while oldestTick < nextTick {
            let tick = oldestTick
            oldestTick += 1
            if let key = order.removeValue(forKey: tick) {
                if let old = entries.removeValue(forKey: key) { totalBytes -= old.bytes }
                return true
            }
        }
        return false
    }
}
