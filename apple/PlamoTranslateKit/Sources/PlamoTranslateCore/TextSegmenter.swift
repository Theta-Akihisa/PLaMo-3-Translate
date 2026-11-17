import Foundation

/// 文書を空行区切りの段落に分割し、区切り（空行・改行）を保持する。
public enum TextSegmenter {
    public enum Segment: Equatable, Sendable {
        /// 翻訳対象のテキスト（段落の最初の行頭から最後の行末まで。末尾の改行は含まない）
        case text(String)
        /// 区切りや空白のみの部分。翻訳せずそのまま出力に戻す
        case separator(String)

        public var isText: Bool { if case .text = self { return true } else { return false } }
    }

    /// 空行（空白のみの行）で分割する。段落内の単一改行は text の中に残り、
    /// 段落末尾の改行・空行・先頭末尾の空行は separator に入る。
    /// 改行は `\n`・`\r\n`・`\r`（単独）のいずれも認識する（`\r` が text の末尾に残ることはない）。
    /// 全 Segment の文字列を連結すると元のテキストに戻る（UTF-16 単位で分割するので位置も正確に保たれる）。
    public static func segments(_ text: String) -> [Segment] {
        // CRLF は 1 つの Character になるため、Character ではなく UTF-16 コード単位で走査する。
        // 分割位置は常に ASCII の改行の前後なので、サロゲートペアを分断することはない。
        let units = Array(text.utf16)
        let n = units.count
        guard n > 0 else { return [] }

        let lf: UInt16 = 0x0A, cr: UInt16 = 0x0D
        func isBlankUnit(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 || u == 0x3000 }
        func string(_ r: Range<Int>) -> String { String(decoding: units[r], as: UTF16.self) }

        var result: [Segment] = []
        var separatorStart = 0          // 未出力の区切りの開始位置
        var paragraph: Range<Int>?      // 現在の段落（最初の行頭〜最後の非空行の行末。改行は含まない）
        var lineStart = 0
        while lineStart < n {
            var i = lineStart
            var blank = true
            while i < n, units[i] != lf, units[i] != cr {
                if !isBlankUnit(units[i]) { blank = false }
                i += 1
            }
            let contentEnd = i
            // 行末の改行（\r\n / \n / \r）を読み飛ばす
            if i < n {
                if units[i] == cr, i + 1 < n, units[i + 1] == lf { i += 2 } else { i += 1 }
            }
            if blank {
                if let p = paragraph {
                    result.append(.text(string(p)))
                    separatorStart = p.upperBound
                    paragraph = nil
                }
            } else if let p = paragraph {
                paragraph = p.lowerBound..<contentEnd
            } else {
                if separatorStart < lineStart {
                    result.append(.separator(string(separatorStart..<lineStart)))
                }
                paragraph = lineStart..<contentEnd
            }
            lineStart = i
        }
        if let p = paragraph {
            result.append(.text(string(p)))
            separatorStart = p.upperBound
        }
        if separatorStart < n {
            result.append(.separator(string(separatorStart..<n)))
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
