import Foundation

/// 文書を空行区切りの段落に分割し、区切り（空行・改行）を保持する。
public enum TextSegmenter {
    public enum Segment: Equatable, Sendable {
        /// 翻訳対象のテキスト（前後の空白は含まない）
        case text(String)
        /// 区切りや空白のみの部分。翻訳せずそのまま出力に戻す
        case separator(String)

        public var isText: Bool { if case .text = self { return true } else { return false } }
    }

    /// 空行（空白のみの行）で分割する。段落内の単一改行は text の中に残り、
    /// 段落末尾の改行・空行・先頭末尾の空白は separator に入る。
    /// 全 Segment の文字列を連結すると元のテキストに戻る。
    public static func segments(_ text: String) -> [Segment] {
        func isBlank(_ s: String) -> Bool {
            s.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\u{3000}" }
        }
        // CRLF は 1 つの Character になるため split(separator:) ではなく UTF-16 単位で分割する
        let lines = text.components(separatedBy: "\n")
        var result: [Segment] = []
        var para: [String] = []      // 現在の段落の行（改行なし）
        var sep = ""                  // 現在の区切り

        func flushPara() {
            guard !para.isEmpty else { return }
            result.append(.text(para.joined(separator: "\n")))
            para = []
            sep = "\n"               // 段落末尾の改行
        }
        for (i, line) in lines.enumerated() {
            let isLast = i == lines.count - 1
            if isBlank(line) {
                flushPara()
                sep += line + (isLast ? "" : "\n")
            } else {
                if para.isEmpty, !sep.isEmpty {
                    result.append(.separator(sep)); sep = ""
                }
                para.append(line)
            }
        }
        if !para.isEmpty {
            result.append(.text(para.joined(separator: "\n")))
        } else if !sep.isEmpty {
            result.append(.separator(sep))
        }
        return result
    }

    /// Segment 列を元の文字列へ連結する。
    public static func join(_ segments: [Segment]) -> String {
        segments.map { seg -> String in
            switch seg { case .text(let s), .separator(let s): return s }
        }.joined()
    }

    /// 翻訳対象の段落のみ。
    public static func paragraphs(_ text: String) -> [String] {
        segments(text).compactMap { if case .text(let s) = $0 { return s } else { return nil } }
    }
}
