import Foundation
import PlamoTranslateCore

// llama-server 互換サブセットのルーティング。I/O を持たず、結果をモデル値で返す（テスト可能）。

enum APIHealth: Equatable {
    case ok, loading, noModel
}

struct GenerationCall {
    enum Kind { case completion, chat }
    var kind: Kind
    var prompt: String
    var maxTokens: Int
    var stop: [String]
    var stream: Bool
    var model: String
}

enum APIRoute {
    case respond(HTTPResponse)
    case generate(GenerationCall)
}

enum APIRouter {
    static let modelID = "plamo-3-translate"
    static let defaultMaxTokens = 2048
    static let maxAllowedTokens = 8192

    static func route(_ req: HTTPRequest, health: APIHealth) -> APIRoute {
        if req.method == "OPTIONS" {
            return .respond(HTTPResponse(status: 204, headers: APIResponses.corsHeaders))
        }
        switch req.path {
        case "/health", "/v1/health":
            guard req.method == "GET" || req.method == "HEAD" else { return .respond(methodNotAllowed("GET")) }
            switch health {
            case .ok: return .respond(APIResponses.json(["status": "ok"]))
            case .loading: return .respond(APIResponses.json(["status": "loading"], status: 503))
            case .noModel: return .respond(APIResponses.json(["status": "no_model"], status: 503))
            }
        case "/v1/models", "/models":
            guard req.method == "GET" else { return .respond(methodNotAllowed("GET")) }
            let obj: [String: Any] = ["object": "list",
                                      "data": [["id": modelID, "object": "model"]]]
            return .respond(APIResponses.json(obj))
        case "/v1/completions", "/completion", "/completions":
            guard req.method == "POST" else { return .respond(methodNotAllowed("POST")) }
            if health == .noModel { return .respond(APIResponses.error(status: 503, message: "no model installed")) }
            return parseCompletion(req)
        case "/v1/chat/completions", "/chat/completions":
            guard req.method == "POST" else { return .respond(methodNotAllowed("POST")) }
            if health == .noModel { return .respond(APIResponses.error(status: 503, message: "no model installed")) }
            return parseChat(req)
        default:
            return .respond(APIResponses.error(status: 404, message: "not found: \(req.path)"))
        }
    }

    private static func methodNotAllowed(_ allowed: String) -> HTTPResponse {
        var r = APIResponses.error(status: 405, message: "method not allowed")
        r.headers["Allow"] = allowed
        return r
    }

    // MARK: - JSON helpers

    private static func jsonObject(_ req: HTTPRequest) -> [String: Any]? {
        guard !req.body.isEmpty,
              let any = try? JSONSerialization.jsonObject(with: req.body),
              let obj = any as? [String: Any] else { return nil }
        return obj
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    private static func maxTokens(_ obj: [String: Any]) -> Int {
        let raw = intValue(obj["max_tokens"]) ?? intValue(obj["n_predict"]) ?? intValue(obj["max_completion_tokens"])
        guard let n = raw, n > 0 else { return defaultMaxTokens }   // -1 などは既定値
        return min(n, maxAllowedTokens)
    }

    private static func stopList(_ obj: [String: Any]) -> [String] {
        var out: [String] = []
        if let s = obj["stop"] as? String { out = [s] }
        else if let a = obj["stop"] as? [String] { out = a }
        for s in PFML3.stopStrings where !out.contains(s) { out.append(s) }
        return out.filter { !$0.isEmpty }
    }

    // MARK: - /v1/completions

    private static func parseCompletion(_ req: HTTPRequest) -> APIRoute {
        guard let obj = jsonObject(req) else {
            return .respond(APIResponses.error(status: 400, message: "invalid JSON body"))
        }
        var prompt: String?
        if let p = obj["prompt"] as? String { prompt = p }
        else if let arr = obj["prompt"] as? [String], let first = arr.first { prompt = first }
        guard let prompt, !prompt.isEmpty else {
            return .respond(APIResponses.error(status: 400, message: "'prompt' is required"))
        }
        return .generate(GenerationCall(kind: .completion, prompt: prompt, maxTokens: maxTokens(obj),
                                        stop: stopList(obj), stream: (obj["stream"] as? Bool) ?? false,
                                        model: modelID))
    }

    // MARK: - /v1/chat/completions

    private static func messageText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            let texts = parts.compactMap { ($0["type"] as? String ?? "text") == "text" ? $0["text"] as? String : nil }
            return texts.isEmpty ? nil : texts.joined()
        }
        return nil
    }

    private static func glossary(_ any: Any?) -> [GlossaryEntry] {
        if let arr = any as? [[String: Any]] {
            return arr.compactMap {
                guard let s = $0["source"] as? String, let t = $0["target"] as? String, !s.isEmpty else { return nil }
                return GlossaryEntry(source: s, target: t)
            }
        }
        if let dict = any as? [String: String] {
            return dict.keys.sorted().map { GlossaryEntry(source: $0, target: dict[$0]!) }
        }
        return []
    }

    private static func parseChat(_ req: HTTPRequest) -> APIRoute {
        guard let obj = jsonObject(req) else {
            return .respond(APIResponses.error(status: 400, message: "invalid JSON body"))
        }
        guard let messages = obj["messages"] as? [[String: Any]], !messages.isEmpty else {
            return .respond(APIResponses.error(status: 400, message: "'messages' is required"))
        }
        var systemTexts: [String] = []
        var history: [HistoryPair] = []
        var pendingUser: String?
        for m in messages {
            let role = (m["role"] as? String) ?? ""
            guard let text = messageText(m["content"]) else { continue }
            switch role {
            case "system", "developer":
                systemTexts.append(text)
            case "user":
                pendingUser = text
            case "assistant":
                if let u = pendingUser {
                    history.append(HistoryPair(source: u, translation: text))
                    pendingUser = nil
                }
            default:
                break
            }
        }
        guard let userText = pendingUser, !userText.isEmpty else {
            return .respond(APIResponses.error(status: 400, message: "the last message must be a non-empty user message"))
        }
        let kw = (obj["chat_template_kwargs"] as? [String: Any]) ?? [:]
        let target = (kw["target_lang"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ja"
        let source = (kw["source_lang"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var form: TranslationForm?
        if target == "ja", let f = kw["form"] as? String { form = TranslationForm(rawValue: f) }
        var context = (kw["context"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if context == nil, !systemTexts.isEmpty { context = systemTexts.joined(separator: "\n") }

        let request = TranslationRequest(text: userText, targetLang: target, sourceLang: source,
                                         form: form, context: context,
                                         glossary: glossary(kw["glossary"]), history: history)
        let prompt: String
        do {
            prompt = try PFML3.buildPrompt(request)
        } catch {
            return .respond(APIResponses.error(status: 400, message: "cannot build prompt: \(error)"))
        }
        return .generate(GenerationCall(kind: .chat, prompt: prompt, maxTokens: maxTokens(obj),
                                        stop: stopList(obj), stream: (obj["stream"] as? Bool) ?? false,
                                        model: modelID))
    }
}

// MARK: - レスポンス生成

enum APIResponses {
    static let corsHeaders: [String: String] = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
        "Access-Control-Allow-Private-Network": "true",
        "Access-Control-Max-Age": "86400",
    ]

    static func jsonData(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        var h = corsHeaders
        h["Content-Type"] = "application/json; charset=utf-8"
        return HTTPResponse(status: status, headers: h, body: jsonData(obj))
    }

    static func error(status: Int, message: String) -> HTTPResponse {
        json(["error": ["message": message, "type": "invalid_request_error", "code": status]], status: status)
    }

    static func sseHeaders() -> [String: String] {
        var h = corsHeaders
        h["Content-Type"] = "text/event-stream; charset=utf-8"
        h["Cache-Control"] = "no-cache"
        return h
    }

    static func newID(_ call: GenerationCall) -> String {
        (call.kind == .chat ? "chatcmpl-" : "cmpl-") + UUID().uuidString.prefix(12).lowercased()
    }

    /// 非ストリーミングの完全なレスポンス
    static func completion(call: GenerationCall, id: String, text: String, finish: String = "stop") -> HTTPResponse {
        switch call.kind {
        case .completion:
            return json(["id": id, "object": "text_completion", "model": call.model,
                         "choices": [["index": 0, "text": text, "finish_reason": finish]]])
        case .chat:
            let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return json(["id": id, "object": "chat.completion", "model": call.model,
                         "choices": [["index": 0, "message": ["role": "assistant", "content": msg],
                                      "finish_reason": finish]]])
        }
    }

    /// SSE の 1 チャンク（`data: {...}\n\n`）。text が nil のときは終端チャンク。
    static func sseChunk(call: GenerationCall, id: String, text: String?, finish: String?, role: Bool = false) -> Data {
        let finishValue: Any = finish ?? NSNull()
        let obj: [String: Any]
        switch call.kind {
        case .completion:
            obj = ["id": id, "object": "text_completion", "model": call.model,
                   "choices": [["index": 0, "text": text ?? "", "finish_reason": finishValue]]]
        case .chat:
            var delta: [String: Any] = [:]
            if role { delta["role"] = "assistant" }
            if let text { delta["content"] = text }
            obj = ["id": id, "object": "chat.completion.chunk", "model": call.model,
                   "choices": [["index": 0, "delta": delta, "finish_reason": finishValue]]]
        }
        return Data(("data: " + String(decoding: jsonData(obj), as: UTF8.self) + "\n\n").utf8)
    }

    static let sseDone = Data("data: [DONE]\n\n".utf8)
}
