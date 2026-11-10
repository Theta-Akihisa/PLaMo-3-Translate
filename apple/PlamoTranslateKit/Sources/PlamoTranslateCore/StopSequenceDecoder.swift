import Foundation

/// 生成トークンのバイト列を順に受け取り、UTF-8 として完結し、かつ停止文字列を含まないテキストだけを返す。
///
/// - トークンの境界で分断されたマルチバイト文字は、続きのバイトが届くまで保留する。
/// - 停止文字列の接頭辞になり得る末尾も保留し、停止文字列が複数トークンにまたがっても検出する。
/// - 停止文字列を検出したら、その手前までを返して `isStopped` を true にする（以降の入力は無視）。
public struct StopSequenceDecoder: Sendable {
    public private(set) var isStopped = false
    private var pending: [UInt8] = []
    private let stops: [[UInt8]]

    public init(stop: [String]) {
        self.stops = stop.map { Array($0.utf8) }.filter { !$0.isEmpty }
    }

    /// バイト列を追加し、出力してよいテキストを返す（空文字列のこともある）。
    public mutating func feed<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        guard !isStopped else { return "" }
        pending.append(contentsOf: bytes)
        if let idx = Self.findStop(in: pending, stops: stops) {
            let head = String(decoding: pending[..<idx], as: UTF8.self)
            pending.removeAll()
            isStopped = true
            return head
        }
        // 停止文字列の接頭辞になり得る末尾と、不完全なマルチバイト末尾は保留する
        let hold = max(Self.longestStopPrefixSuffix(pending, stops: stops), Self.incompleteUTF8Tail(pending))
        let cut = pending.count - min(hold, pending.count)
        guard cut > 0 else { return "" }
        let out = String(decoding: pending[..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return out
    }

    /// 生成の終了時（EOG・トークン上限）に保留分をすべて返す。不完全な UTF-8 は U+FFFD になる。
    public mutating func flush() -> String {
        guard !isStopped, !pending.isEmpty else { return "" }
        let out = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return out
    }

    // MARK: - Pure helpers

    /// いずれかの停止文字列が最初に現れるバイト位置。
    public static func findStop(in bytes: [UInt8], stops: [[UInt8]]) -> Int? {
        var best: Int? = nil
        for s in stops where !s.isEmpty && bytes.count >= s.count {
            var i = 0
            let last = bytes.count - s.count
            while i <= last {
                if let b = best, i >= b { break }
                if bytes[i] == s[0] && bytes[i..<(i + s.count)].elementsEqual(s) {
                    best = i
                    break
                }
                i += 1
            }
        }
        return best
    }

    /// bytes の末尾が、いずれかの停止文字列の（真の）接頭辞と一致する最大長。
    public static func longestStopPrefixSuffix(_ bytes: [UInt8], stops: [[UInt8]]) -> Int {
        var best = 0
        for s in stops where s.count > 1 {
            let maxK = min(s.count - 1, bytes.count)
            guard maxK > best else { continue }
            for k in stride(from: maxK, to: best, by: -1)
            where bytes[(bytes.count - k)...].elementsEqual(s[..<k]) {
                best = k
                break
            }
        }
        return best
    }

    /// 末尾の不完全な UTF-8 シーケンスのバイト数（0 なら完結、または不正なバイト列で待っても完結しない）。
    public static func incompleteUTF8Tail(_ bytes: [UInt8]) -> Int {
        var i = bytes.count - 1
        var cont = 0
        while i >= 0 && cont < 3 && (bytes[i] & 0xC0) == 0x80 { cont += 1; i -= 1 }
        guard i >= 0 else { return 0 }
        let lead = bytes[i]
        let need: Int
        if lead & 0x80 == 0 { need = 1 }
        else if lead & 0xE0 == 0xC0 { need = 2 }
        else if lead & 0xF0 == 0xE0 { need = 3 }
        else if lead & 0xF8 == 0xF0 { need = 4 }
        else { return 0 }
        return (cont + 1) < need ? cont + 1 : 0
    }
}
