import Foundation
import PlamoTranslateCore

// shared/local-api.md（Chrome 拡張機能 ⇔ macOS アプリ）のルーティング。
// I/O を持たず、APIState のスナップショットから結果をモデル値で返す（テスト可能）。

struct GenerationCall {
    enum Kind { case completion, chat }
    var kind: Kind
    var prompt: String
    var maxTokens: Int
    var stop: [String]
    var stream: Bool
    /// 応答の `model`（実際に使うモデル ID）
    var model: String
    /// 非 nil なら、生成前にこのモデルへ切り替える
    var switchTo: String? = nil
    /// 応答に付ける CORS ヘッダ（許可した Origin のエコー + Vary）
    var cors: [String: String] = [:]
    var created: Int = Int(Date().timeIntervalSince1970)
}

enum APIRoute {
    case respond(HTTPResponse)
    case generate(GenerationCall)
    /// バックエンドでモデルを切り替え、`/health` と同じ JSON を HTTP 200 で返す
    case selectModel(id: String, cors: [String: String])
}

/// 要求された `model` の解決結果
struct ModelChoice: Equatable {
    var id: String
    var needsSwitch: Bool
}

enum APIRouter {
    /// 選択中モデルの別名
    static let aliasModelID = "plamo-3-translate"
    /// shared/local-api.md の仕様バージョン
    static let apiVersion = 1
    static let defaultMaxTokens = 2048
    static let maxAllowedTokens = 8192

    /// - Parameter port: 待ち受けポート。指定すると Host ヘッダのポートもこれと一致する必要がある。
    static func route(_ req: HTTPRequest, state: APIState, port: UInt16? = nil) -> APIRoute {
        let origin = req.headers["origin"]
        // 1. DNS リバインディング対策
        guard isAllowedHost(req.headers["host"], port: port) else {
            return .respond(APIResponses.error(.forbiddenHost, headers: ["Vary": "Origin"]))
        }
        // 2. 一般の Web ページからの呼び出しを拒否（プリフライトにも同じ判定）
        guard isAllowedOrigin(origin) else {
            return .respond(APIResponses.error(.forbiddenOrigin, headers: ["Vary": "Origin"]))
        }
        if req.method == "OPTIONS" {
            return .respond(HTTPResponse(status: 204, headers: APIResponses.preflightHeaders(origin: origin)))
        }
        let cors = APIResponses.corsHeaders(origin: origin)
        switch routeAllowed(req, state: state, cors: cors) {
        case .respond(var r):
            r.headers.merge(cors) { _, new in new }
            return .respond(r)
        case let other:
            return other
        }
    }

    // MARK: - セキュリティ

    /// `127.0.0.1` / `localhost`（`:<port>` は省略可）のみ許可
    static func isAllowedHost(_ host: String?, port: UInt16?) -> Bool {
        guard let raw = host?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return false }
        var name = raw
        if let colon = raw.lastIndex(of: ":") {
            name = String(raw[raw.startIndex..<colon])
            let portText = raw[raw.index(after: colon)...]
            guard let p = UInt16(portText) else { return false }
            if let port, p != port { return false }
        }
        return name == "127.0.0.1" || name == "localhost"
    }

    /// Origin が無い（curl など）か、`chrome-extension://` で始まる場合のみ許可
    static func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        let prefix = "chrome-extension://"
        let lower = origin.lowercased()
        return lower.hasPrefix(prefix) && lower.count > prefix.count
    }

    // MARK: - ルーティング

    private static func routeAllowed(_ req: HTTPRequest, state: APIState, cors: [String: String]) -> APIRoute {
        switch req.path {
        case "/health", "/v1/health":
            guard req.method == "GET" || req.method == "HEAD" else { return fail(.methodNotAllowed("GET")) }
            return .respond(APIResponses.health(state))
        case "/v1/models", "/models":
            guard req.method == "GET" else { return fail(.methodNotAllowed("GET")) }
            return .respond(APIResponses.models(state))
        case "/v1/models/select", "/models/select":
            guard req.method == "POST" else { return fail(.methodNotAllowed("POST")) }
            return parseSelect(req, state: state, cors: cors)
        case "/v1/completions", "/completion", "/completions":
            guard req.method == "POST" else { return fail(.methodNotAllowed("POST")) }
            return parseCompletion(req, state: state, cors: cors)
        case "/v1/chat/completions", "/chat/completions":
            guard req.method == "POST" else { return fail(.methodNotAllowed("POST")) }
            return parseChat(req, state: state, cors: cors)
        default:
            return fail(.notFound(req.path))
        }
    }

    private static func fail(_ e: APIError) -> APIRoute {
        .respond(APIResponses.error(e))
    }

    // MARK: - モデルの解決

    /// - `nil` / 空 / 別名 / 選択中モデル ID → 選択中モデル（未ダウンロードなら 409）
    /// - 別のダウンロード済みモデル ID → 切り替えて使う
    /// - 未ダウンロード → 409、カタログに無い ID → 404
    static func resolveModel(_ requested: String?, state: APIState) -> Result<ModelChoice, APIError> {
        let name = requested?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty || name == aliasModelID || name == state.activeModelID {
            guard let active = state.activeModel else { return .failure(.unknownModel(state.activeModelID)) }
            guard active.installed else { return .failure(.modelNotInstalled(active.label)) }
            return .success(ModelChoice(id: active.id, needsSwitch: false))
        }
        guard let m = state.model(id: name) else { return .failure(.unknownModel(name)) }
        guard m.installed else { return .failure(.modelNotInstalled(m.label)) }
        return .success(ModelChoice(id: m.id, needsSwitch: true))
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

    private static let invalidJSON = APIError.invalidRequest("JSON ボディが不正です。")

    // MARK: - /v1/models/select

    private static func parseSelect(_ req: HTTPRequest, state: APIState, cors: [String: String]) -> APIRoute {
        guard let obj = jsonObject(req) else { return fail(invalidJSON) }
        guard let id = obj["model"] as? String, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            return fail(.invalidRequest("'model' を指定してください。"))
        }
        switch resolveModel(id, state: state) {
        case .failure(let e):
            return fail(e)
        case .success(let choice):
            if choice.needsSwitch { return .selectModel(id: choice.id, cors: cors) }
            return .respond(APIResponses.health(state, httpStatus: 200))
        }
    }

    // MARK: - /v1/completions

    private static func parseCompletion(_ req: HTTPRequest, state: APIState, cors: [String: String]) -> APIRoute {
        guard let obj = jsonObject(req) else { return fail(invalidJSON) }
        var prompt: String?
        if let p = obj["prompt"] as? String { prompt = p }
        else if let arr = obj["prompt"] as? [String], let first = arr.first { prompt = first }
        guard let prompt, !prompt.isEmpty else {
            return fail(.invalidRequest("'prompt' を指定してください。"))
        }
        let choice: ModelChoice
        switch resolveModel(obj["model"] as? String, state: state) {
        case .failure(let e): return fail(e)
        case .success(let c): choice = c
        }
        return .generate(GenerationCall(kind: .completion, prompt: prompt, maxTokens: maxTokens(obj),
                                        stop: stopList(obj), stream: (obj["stream"] as? Bool) ?? false,
                                        model: choice.id, switchTo: choice.needsSwitch ? choice.id : nil,
                                        cors: cors))
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

    private static func parseChat(_ req: HTTPRequest, state: APIState, cors: [String: String]) -> APIRoute {
        guard let obj = jsonObject(req) else { return fail(invalidJSON) }
        guard let messages = obj["messages"] as? [[String: Any]], !messages.isEmpty else {
            return fail(.invalidRequest("'messages' を指定してください。"))
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
            return fail(.invalidRequest("最後のメッセージは空でない user メッセージにしてください。"))
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
            return fail(.invalidRequest("プロンプトを組み立てられません: \(error)"))
        }
        let choice: ModelChoice
        switch resolveModel(obj["model"] as? String, state: state) {
        case .failure(let e): return fail(e)
        case .success(let c): choice = c
        }
        return .generate(GenerationCall(kind: .chat, prompt: prompt, maxTokens: maxTokens(obj),
                                        stop: stopList(obj), stream: (obj["stream"] as? Bool) ?? false,
                                        model: choice.id, switchTo: choice.needsSwitch ? choice.id : nil,
                                        cors: cors))
    }
}

// MARK: - レスポンス生成

enum APIResponses {
    /// 許可済みリクエストへの CORS ヘッダ。Origin があればそのままエコーする（`*` は使わない）。
    static func corsHeaders(origin: String?) -> [String: String] {
        var h = ["Vary": "Origin"]
        if let origin {
            h["Access-Control-Allow-Origin"] = origin
            h["Access-Control-Allow-Private-Network"] = "true"
        }
        return h
    }

    /// OPTIONS プリフライトの応答ヘッダ
    static func preflightHeaders(origin: String?) -> [String: String] {
        var h = corsHeaders(origin: origin)
        h["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        h["Access-Control-Allow-Headers"] = "Content-Type, Authorization, Accept"
        h["Access-Control-Allow-Private-Network"] = "true"
        h["Access-Control-Max-Age"] = "600"
        return h
    }

    static func jsonData(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: jsonData(obj))
    }

    // MARK: エラー

    static func errorBody(status: Int, message: String, type: String) -> [String: Any] {
        ["error": ["message": message, "type": type, "code": status] as [String: Any]]
    }

    static func error(status: Int, message: String, type: String = "invalid_request") -> HTTPResponse {
        json(errorBody(status: status, message: message, type: type), status: status)
    }

    static func error(_ e: APIError, headers extra: [String: String] = [:]) -> HTTPResponse {
        var r = error(status: e.status, message: e.message, type: e.type)
        if case .methodNotAllowed(let allowed) = e { r.headers["Allow"] = allowed }
        for (k, v) in extra { r.headers[k] = v }
        return r
    }

    /// バックエンドが投げたエラーを応答にする（APIError 以外は 500 server_error）
    static func error(for err: Error) -> HTTPResponse {
        if let e = err as? APIError { return error(e) }
        return error(.server(err.localizedDescription))
    }

    // MARK: /health, /v1/models

    static func healthBody(_ s: APIState) -> [String: Any] {
        var body: [String: Any] = ["status": s.health.rawValue, "app": s.appName,
                                   "version": s.version, "api": APIRouter.apiVersion]
        if let m = s.activeModel {
            body["model"] = ["id": m.id, "size": m.size, "label": m.label, "quant": m.quant, "loaded": s.loaded] as [String: Any]
        } else {
            body["model"] = NSNull()
        }
        return body
    }

    /// `ok` は 200、`loading` / `no_model` は 503（httpStatus で上書き可）
    static func health(_ s: APIState, httpStatus: Int? = nil) -> HTTPResponse {
        json(healthBody(s), status: httpStatus ?? (s.health == .ok ? 200 : 503))
    }

    static func models(_ s: APIState) -> HTTPResponse {
        var data: [[String: Any]] = [[
            "id": APIRouter.aliasModelID, "object": "model", "owned_by": "pfnet", "alias_of": s.activeModelID,
        ]]
        for m in s.models {
            data.append([
                "id": m.id, "object": "model", "owned_by": "pfnet",
                "size": m.size, "label": m.label,
                "installed": m.installed, "active": m.id == s.activeModelID,
                "quant": m.quant, "installed_quants": m.installedQuants, "size_bytes": m.sizeBytes,
            ])
        }
        return json(["object": "list", "data": data] as [String: Any])
    }

    // MARK: 生成

    static func sseHeaders(cors: [String: String] = [:]) -> [String: String] {
        var h = cors
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
            return json(["id": id, "object": "text_completion", "created": call.created, "model": call.model,
                         "choices": [["index": 0, "text": text, "finish_reason": finish] as [String: Any]]] as [String: Any])
        case .chat:
            let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return json(["id": id, "object": "chat.completion", "created": call.created, "model": call.model,
                         "choices": [["index": 0, "message": ["role": "assistant", "content": msg],
                                      "finish_reason": finish] as [String: Any]]] as [String: Any])
        }
    }

    private static func sse(_ obj: Any) -> Data {
        Data(("data: " + String(decoding: jsonData(obj), as: UTF8.self) + "\n\n").utf8)
    }

    /// SSE の 1 チャンク（`data: {...}\n\n`）。finish が非 nil なら終端チャンク。
    static func sseChunk(call: GenerationCall, id: String, text: String?, finish: String?, role: Bool = false) -> Data {
        let finishValue: Any = finish ?? NSNull()
        let obj: [String: Any]
        switch call.kind {
        case .completion:
            obj = ["id": id, "object": "text_completion", "created": call.created, "model": call.model,
                   "choices": [["index": 0, "text": text ?? "", "finish_reason": finishValue] as [String: Any]]]
        case .chat:
            var delta: [String: Any] = [:]
            if role { delta["role"] = "assistant" }
            if let text { delta["content"] = text }
            obj = ["id": id, "object": "chat.completion.chunk", "created": call.created, "model": call.model,
                   "choices": [["index": 0, "delta": delta, "finish_reason": finishValue] as [String: Any]]]
        }
        return sse(obj)
    }

    /// ストリーム途中のエラーイベント（エラー形式は通常の応答と同じ）
    static func sseError(_ err: Error) -> Data {
        let e = (err as? APIError) ?? .server(err.localizedDescription)
        return sse(errorBody(status: e.status, message: e.message, type: e.type))
    }

    static let sseDone = Data("data: [DONE]\n\n".utf8)
}
