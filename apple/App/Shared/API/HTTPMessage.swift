import Foundation

// Network.framework に依存しない、最小限の HTTP/1.1 メッセージ型とパーサ。

struct HTTPRequest {
    var method: String
    var path: String            // クエリを除いたパス
    var query: String = ""
    var headers: [String: String] = [:]   // キーは小文字
    var body: Data = Data()
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func reason(_ code: Int) -> String {
        switch code {
        case 100: return "Continue"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    /// Content-Length 付きの完全なレスポンス（常に Connection: close）。
    func serialized() -> Data {
        var h = headers
        h["Content-Length"] = String(body.count)
        h["Connection"] = "close"
        var out = Data(Self.head(status: status, headers: h).utf8)
        out.append(body)
        return out
    }

    /// SSE などストリーミング用のヘッダ部のみ（Content-Length なし、close で終端）。
    static func streamingHead(status: Int = 200, headers: [String: String]) -> Data {
        var h = headers
        h["Connection"] = "close"
        return Data(head(status: status, headers: h).utf8)
    }

    private static func head(status: Int, headers: [String: String]) -> String {
        var s = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for key in headers.keys.sorted() {
            s += "\(key): \(headers[key]!)\r\n"
        }
        s += "\r\n"
        return s
    }
}

enum HTTPParseResult {
    case needMore
    case needMoreSendContinue       // Expect: 100-continue（curl は 1KB 超のボディで送る）
    case request(HTTPRequest)
    case failure(HTTPResponse)
}

/// 1 接続 1 リクエスト用の増分パーサ。部分読み込みに対応する。
struct HTTPRequestParser {
    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 1_048_576   // 1 MB

    private var buffer = Data()
    private var sentContinue = false

    init() {}

    mutating func feed(_ data: Data) -> HTTPParseResult {
        buffer.append(data)
        let separator = Data([13, 10, 13, 10])
        guard let sepRange = buffer.range(of: separator) else {
            if buffer.count > Self.maxHeaderBytes {
                return .failure(Self.error(431, "header too large"))
            }
            return .needMore
        }
        let headerEnd = sepRange.lowerBound
        if headerEnd - buffer.startIndex > Self.maxHeaderBytes {
            return .failure(Self.error(431, "header too large"))
        }
        let headData = buffer[buffer.startIndex..<headerEnd]
        let head = String(data: headData, encoding: .utf8) ?? String(decoding: headData, as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .failure(Self.error(400, "empty request")) }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            return .failure(Self.error(400, "malformed request line"))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(Self.error(400, "malformed header"))
            }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if let te = headers["transfer-encoding"], te.lowercased() != "identity" {
            return .failure(Self.error(501, "Transfer-Encoding is not supported; send Content-Length"))
        }
        var contentLength = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .failure(Self.error(400, "invalid Content-Length")) }
            if n > Self.maxBodyBytes { return .failure(Self.error(413, "body exceeds 1 MB")) }
            contentLength = n
        }
        let bodyStart = sepRange.upperBound
        let available = buffer.endIndex - bodyStart
        if available < contentLength {
            if !sentContinue, headers["expect"]?.lowercased() == "100-continue" {
                sentContinue = true
                return .needMoreSendContinue
            }
            return .needMore
        }
        let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
        var path = parts[1]
        var query = ""
        if let q = path.firstIndex(of: "?") {
            query = String(path[path.index(after: q)...])
            path = String(path[path.startIndex..<q])
        }
        // 絶対 URI 形式 (http://host/path) の場合はパス部分だけ取り出す
        if path.hasPrefix("http://") || path.hasPrefix("https://"),
           let url = URL(string: path) {
            path = url.path.isEmpty ? "/" : url.path
        }
        return .request(HTTPRequest(method: parts[0].uppercased(), path: path, query: query,
                                    headers: headers, body: body))
    }

    private static func error(_ status: Int, _ message: String) -> HTTPResponse {
        APIResponses.error(status: status, message: message)
    }
}
