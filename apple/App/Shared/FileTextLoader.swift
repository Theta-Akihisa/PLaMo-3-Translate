import Foundation
import PDFKit
import Vision
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 翻訳用にファイルからテキストを取り出す（.txt / .md / .rtf / .pdf）。
///
/// PDF はページの文字情報を PDFKit で取り出し、行ごとに改行されたテキストを段落に組み直す。
/// 文字情報の無いページ（スキャン PDF）は Vision の文字認識（日本語・英語）で読み取る。
enum FileTextLoader {
    struct Result: Sendable {
        var text: String
        var fileName: String
        /// PDF のページ数（PDF 以外は nil）
        var pageCount: Int?
        /// 文字認識（OCR）で読み取ったページ数
        var ocrPageCount: Int = 0

        var summary: String {
            guard let pages = pageCount else { return "「\(fileName)」を読み込みました" }
            var s = "「\(fileName)」（\(pages) ページ）を読み込みました"
            if ocrPageCount > 0 { s += "。うち \(ocrPageCount) ページは文字認識で読み取りました" }
            return s
        }
    }

    enum LoadError: LocalizedError {
        case unsupported(String)
        case unreadable
        case encrypted
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "「.\(ext)」形式には対応していません。テキスト（.txt / .md）、リッチテキスト（.rtf）、PDF を読み込めます。"
            case .unreadable: return "ファイルを読み込めませんでした。"
            case .encrypted: return "パスワードで保護された PDF は読み込めません。"
            case .empty: return "ファイルから文字を取り出せませんでした。"
            }
        }
    }

    /// ファイル選択・ドラッグ＆ドロップで受け付ける形式
    static let supportedTypes: [UTType] = [.pdf, .plainText, .utf8PlainText, .rtf, UTType(filenameExtension: "md") ?? .plainText]

    static let textExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || ext == "rtf" || textExtensions.contains(ext)
    }

    /// バックグラウンドで読み込む。`progress` は PDF のページ処理の進み具合（0...1）。
    static func load(url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            switch ext {
            case "pdf":
                return try loadPDF(url: url, fileName: name, progress: progress)
            case "rtf":
                let attr = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                  documentAttributes: nil)
                return try nonEmpty(Result(text: attr.string, fileName: name))
            default:
                guard textExtensions.contains(ext) || ext.isEmpty else { throw LoadError.unsupported(ext) }
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS)
                        ?? String(data: data, encoding: .japaneseEUC) else { throw LoadError.unreadable }
                return try nonEmpty(Result(text: text, fileName: name))
            }
        }.value
    }

    private static func nonEmpty(_ r: Result) throws -> Result {
        guard !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LoadError.empty }
        return r
    }

    // MARK: - PDF

    private static func loadPDF(url: URL, fileName: String, progress: (@Sendable (Double) -> Void)?) throws -> Result {
        guard let doc = PDFDocument(url: url) else { throw LoadError.unreadable }
        if doc.isLocked { throw LoadError.encrypted }
        var pages: [String] = []
        var ocrPages = 0
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            var raw = page.string ?? ""
            // 文字情報がほとんど無いページはスキャン画像とみなして文字認識する
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).count < 20, let ocr = recognizeText(on: page), !ocr.isEmpty {
                raw = ocr
                ocrPages += 1
            }
            let text = PDFTextReflow.paragraphs(fromPageText: raw)
            if !text.isEmpty { pages.append(text) }
            progress?(Double(i + 1) / Double(max(doc.pageCount, 1)))
        }
        return try nonEmpty(Result(text: pages.joined(separator: "\n\n"), fileName: fileName,
                                   pageCount: doc.pageCount, ocrPageCount: ocrPages))
    }

    /// Vision でページ画像を文字認識し、上から順に行を並べたテキストを返す
    private static func recognizeText(on page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        // 長辺がおよそ 2000px 以上になる解像度で描画（小さい文字も認識できるように）
        let scale = max(2.0, 2000 / max(bounds.width, bounds.height, 1))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let cg = cgImage(page.thumbnail(of: size, for: .mediaBox)) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: cg).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }   // Vision の座標は左下原点
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    #if canImport(UIKit)
    private static func cgImage(_ image: UIImage) -> CGImage? { image.cgImage }
    #else
    private static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    #endif
}

/// PDF から取り出した「1 行ずつ改行されたテキスト」を段落単位に組み直す。
/// 段落ごとに翻訳する（直前の段落を文脈として渡す）ため、行の途中で文が切れないようにする。
enum PDFTextReflow {
    static func paragraphs(fromPageText text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let nonEmpty = lines.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "" }

        // 本文の行の長さの目安（短い行 = 段落の最終行・見出しとみなす）
        let lengths = nonEmpty.map(\.count).sorted()
        let typical = lengths[min(lengths.count - 1, lengths.count * 3 / 4)]

        var paragraphs: [String] = []
        var current = ""
        func flush() {
            let p = current.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { paragraphs.append(p) }
            current = ""
        }

        for (i, line) in lines.enumerated() {
            if line.isEmpty { flush(); continue }
            if isPageNumber(line) { continue }
            if current.isEmpty {
                current = line
            } else {
                current = join(current, line)
            }
            let next = i + 1 < lines.count ? lines[i + 1] : ""
            if endsParagraph(line, next: next, typical: typical) { flush() }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    /// 行末で段落が終わるか
    static func endsParagraph(_ line: String, next: String, typical: Int) -> Bool {
        guard !next.isEmpty else { return true }
        if isListItem(next) || isHeading(next) || isHeading(line) { return true }
        let length = Double(line.count), t = Double(typical)
        // 文末記号で終わり、本文の行より少し短い → 段落の最終行
        if let last = line.last, "。．.!?！？:：」』)）".contains(last), length < t * 0.85 { return true }
        // かなり短く、次の行が大文字・CJK で始まる → 見出しや段落の区切り
        if length < t * 0.7, let first = next.first, first.isUppercase || isCJK(first) { return true }
        return false
    }

    /// "2 Method" "3.1 Results" "第2章 …" のような番号付き見出し
    static func isHeading(_ line: String) -> Bool {
        guard line.count <= 40, let last = line.last, !"。．.!?！？,、".contains(last) else { return false }
        return line.range(of: #"^(\d+(\.\d+)*|第\d+[章節])\s*\S"#, options: .regularExpression) != nil
    }

    /// 2 行をつなぐ。英語は空白でつなぎ、行末のハイフネーションは外す。日本語・中国語は空白を入れない。
    static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        if last == "-", a.count >= 2, a[a.index(before: a.index(before: a.endIndex))].isLetter, first.isLowercase {
            return String(a.dropLast()) + b
        }
        if isCJK(last) || isCJK(first) { return a + b }
        return a + " " + b
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            switch s.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    static func isPageNumber(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: CharacterSet(charactersIn: "-–— "))
        return !t.isEmpty && t.count <= 4 && t.allSatisfy(\.isNumber)
    }

    static func isListItem(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if "•・●◦▪■-–*".contains(first) { return true }
        // "1." "2)" "(3)" など
        let head = line.prefix(4)
        return head.range(of: #"^\(?\d{1,2}[.)）]"#, options: .regularExpression) != nil
    }
}
