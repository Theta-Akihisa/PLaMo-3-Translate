import XCTest
@testable import PlamoTranslateApp

final class HTTPRequestParserTests: XCTestCase {
    private func post(_ path: String, body: String, extra: String = "") -> Data {
        let b = Data(body.utf8)
        return Data("POST \(path) HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n\(extra)Content-Length: \(b.count)\r\n\r\n".utf8) + b
    }

    func testSimpleGet() {
        var p = HTTPRequestParser()
        guard case .request(let r) = p.feed(Data("GET /health?x=1 HTTP/1.1\r\nHost: a\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/health")
        XCTAssertEqual(r.query, "x=1")
        XCTAssertEqual(r.headers["host"], "a")
    }

    func testPartialReadsByteByByte() {
        let raw = post("/v1/completions", body: "{\"prompt\":\"こんにちは\"}")
        var p = HTTPRequestParser()
        var result: HTTPRequest?
        for byte in raw {
            switch p.feed(Data([byte])) {
            case .request(let r): result = r
            case .needMore: continue
            default: XCTFail("unexpected")
            }
        }
        XCTAssertEqual(result?.path, "/v1/completions")
        XCTAssertEqual(String(decoding: result?.body ?? Data(), as: UTF8.self), "{\"prompt\":\"こんにちは\"}")
    }

    func testBodyTooLarge() {
        var p = HTTPRequestParser()
        let head = "POST /v1/completions HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n"
        guard case .failure(let r) = p.feed(Data(head.utf8)) else { return XCTFail() }
        XCTAssertEqual(r.status, 413)
    }

    func testMalformedAndChunked() {
        var p1 = HTTPRequestParser()
        guard case .failure(let r1) = p1.feed(Data("BAD\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(r1.status, 400)
        var p2 = HTTPRequestParser()
        guard case .failure(let r2) = p2.feed(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(r2.status, 501)
    }

    func testExpectContinueOnce() {
        var p = HTTPRequestParser()
        let head = "POST /v1/completions HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"
        guard case .needMoreSendContinue = p.feed(Data(head.utf8)) else { return XCTFail() }
        guard case .request(let r) = p.feed(Data("hello".utf8)) else { return XCTFail() }
        XCTAssertEqual(r.body.count, 5)
    }
}

final class APIRouterTests: XCTestCase {
    private let port: UInt16 = 18080
    private let extOrigin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"

    /// 0.8B: 選択中・ダウンロード済み / 2B: ダウンロード済み / 8B: 未ダウンロード
    private func state(health: APIHealth = .ok, active: String = "plamo-3-translate-0.8b",
                       loaded: Bool = false, activeInstalled: Bool = true) -> APIState {
        APIState(version: "1.2.3", health: health, activeModelID: active, loaded: loaded, models: [
            APIModelInfo(id: "plamo-3-translate-0.8b", size: "0.8b", label: "0.8B", quant: "Q4_K_M",
                         sizeBytes: 573_123_200, installed: activeInstalled,
                         installedQuants: activeInstalled ? ["Q4_K_M"] : []),
            APIModelInfo(id: "plamo-3-translate-2b", size: "2b", label: "2B", quant: "Q8_0",
                         sizeBytes: 2_000_000_000, installed: true, installedQuants: ["Q4_K_M", "Q8_0"]),
            APIModelInfo(id: "plamo-3-translate-8b", size: "8b", label: "8B", quant: "Q4_K_M",
                         sizeBytes: 5_300_000_000, installed: false, installedQuants: []),
        ])
    }

    private func req(_ method: String, _ path: String, json: [String: Any]? = nil,
                     host: String? = "127.0.0.1:18080", origin: String? = nil,
                     headers extra: [String: String] = [:]) -> HTTPRequest {
        let body = json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var headers = extra
        if let host { headers["host"] = host }
        if let origin { headers["origin"] = origin }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func route(_ r: HTTPRequest, _ s: APIState? = nil) -> APIRoute {
        APIRouter.route(r, state: s ?? state(), port: port)
    }

    private func respond(_ route: APIRoute) -> HTTPResponse? {
        if case .respond(let r) = route { return r }
        return nil
    }

    private func body(_ r: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    private func errorType(_ r: HTTPResponse) -> String? {
        (body(r)["error"] as? [String: Any])?["type"] as? String
    }

    // MARK: セキュリティ

    func testHostCheck() {
        for ok in ["127.0.0.1:18080", "localhost:18080", "127.0.0.1", "localhost", "LOCALHOST:18080"] {
            XCTAssertEqual(respond(route(req("GET", "/health", host: ok)))?.status, 200, ok)
        }
        for bad in ["evil.example.com", "evil.example.com:18080", "127.0.0.1.evil.com:18080",
                    "localhost:9999", "192.168.0.2:18080", "localhost:abc", ""] {
            let r = respond(route(req("GET", "/health", host: bad)))!
            XCTAssertEqual(r.status, 403, bad)
            XCTAssertEqual(errorType(r), "forbidden_host", bad)
        }
        let missing = respond(route(req("GET", "/health", host: nil)))!
        XCTAssertEqual(missing.status, 403)
        XCTAssertEqual(errorType(missing), "forbidden_host")
        // port 未指定なら任意の数値ポートを許可
        XCTAssertTrue(APIRouter.isAllowedHost("localhost:1234", port: nil))
    }

    func testOriginCheck() {
        // Origin なし（curl など）: 許可、ACAO は付けない
        let plain = respond(route(req("GET", "/health")))!
        XCTAssertEqual(plain.status, 200)
        XCTAssertNil(plain.headers["Access-Control-Allow-Origin"])
        XCTAssertEqual(plain.headers["Vary"], "Origin")

        // 拡張機能: 許可し、Origin をそのままエコー
        let ext = respond(route(req("GET", "/v1/models", origin: extOrigin)))!
        XCTAssertEqual(ext.status, 200)
        XCTAssertEqual(ext.headers["Access-Control-Allow-Origin"], extOrigin)
        XCTAssertEqual(ext.headers["Vary"], "Origin")

        // 一般の Web ページ: 403 forbidden_origin
        for bad in ["https://example.com", "http://localhost:3000", "null", "chrome-extension://", "moz-extension://x"] {
            let r = respond(route(req("POST", "/v1/completions", json: ["prompt": "x"], origin: bad)))!
            XCTAssertEqual(r.status, 403, bad)
            XCTAssertEqual(errorType(r), "forbidden_origin", bad)
            XCTAssertNil(r.headers["Access-Control-Allow-Origin"], bad)
        }
    }

    func testPreflight() {
        let r = respond(route(req("OPTIONS", "/v1/completions", origin: extOrigin,
                                  headers: ["access-control-request-method": "POST",
                                            "access-control-request-private-network": "true"])))!
        XCTAssertEqual(r.status, 204)
        XCTAssertEqual(r.headers["Access-Control-Allow-Origin"], extOrigin)
        XCTAssertEqual(r.headers["Access-Control-Allow-Private-Network"], "true")
        XCTAssertEqual(r.headers["Vary"], "Origin")
        XCTAssertTrue(r.headers["Access-Control-Allow-Methods"]?.contains("POST") ?? false)
        XCTAssertTrue(r.headers["Access-Control-Allow-Headers"]?.contains("Content-Type") ?? false)

        let web = respond(route(req("OPTIONS", "/v1/completions", origin: "https://example.com")))!
        XCTAssertEqual(web.status, 403)
        XCTAssertEqual(errorType(web), "forbidden_origin")
        XCTAssertNil(web.headers["Access-Control-Allow-Origin"])

        let badHost = respond(route(req("OPTIONS", "/v1/completions", host: "attacker.test:18080", origin: extOrigin)))!
        XCTAssertEqual(badHost.status, 403)
        XCTAssertEqual(errorType(badHost), "forbidden_host")
    }

    // MARK: /health

    func testHealth() {
        let ok = respond(route(req("GET", "/health"), state(loaded: true)))!
        XCTAssertEqual(ok.status, 200)
        let b = body(ok)
        XCTAssertEqual(b["status"] as? String, "ok")
        XCTAssertEqual(b["app"] as? String, "PLaMo Translate")
        XCTAssertEqual(b["version"] as? String, "1.2.3")
        XCTAssertEqual(b["api"] as? Int, 1)
        let m = b["model"] as? [String: Any]
        XCTAssertEqual(m?["id"] as? String, "plamo-3-translate-0.8b")
        XCTAssertEqual(m?["size"] as? String, "0.8b")
        XCTAssertEqual(m?["label"] as? String, "0.8B")
        XCTAssertEqual(m?["quant"] as? String, "Q4_K_M")
        XCTAssertEqual(m?["loaded"] as? Bool, true)

        let loading = respond(route(req("GET", "/health"), state(health: .loading)))!
        XCTAssertEqual(loading.status, 503)
        XCTAssertEqual(body(loading)["status"] as? String, "loading")

        let none = respond(route(req("GET", "/health"), state(health: .noModel, activeInstalled: false)))!
        XCTAssertEqual(none.status, 503)
        XCTAssertEqual(body(none)["status"] as? String, "no_model")
        XCTAssertEqual((body(none)["model"] as? [String: Any])?["loaded"] as? Bool, false)
    }

    // MARK: /v1/models

    func testModelsList() {
        let r = respond(route(req("GET", "/v1/models", origin: extOrigin)))!
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(body(r)["object"] as? String, "list")
        let data = body(r)["data"] as? [[String: Any]] ?? []
        XCTAssertEqual(data.count, 4)
        XCTAssertEqual(data[0]["id"] as? String, "plamo-3-translate")
        XCTAssertEqual(data[0]["alias_of"] as? String, "plamo-3-translate-0.8b")
        XCTAssertEqual(data[0]["owned_by"] as? String, "pfnet")

        let small = data[1]
        XCTAssertEqual(small["id"] as? String, "plamo-3-translate-0.8b")
        XCTAssertEqual(small["object"] as? String, "model")
        XCTAssertEqual(small["size"] as? String, "0.8b")
        XCTAssertEqual(small["label"] as? String, "0.8B")
        XCTAssertEqual(small["installed"] as? Bool, true)
        XCTAssertEqual(small["active"] as? Bool, true)
        XCTAssertEqual(small["quant"] as? String, "Q4_K_M")
        XCTAssertEqual(small["installed_quants"] as? [String], ["Q4_K_M"])
        XCTAssertEqual((small["size_bytes"] as? NSNumber)?.int64Value, 573_123_200)

        XCTAssertEqual(data[2]["active"] as? Bool, false)
        XCTAssertEqual(data[2]["quant"] as? String, "Q8_0")
        XCTAssertEqual(data[3]["installed"] as? Bool, false)
        XCTAssertEqual(data[3]["installed_quants"] as? [String], [])
    }

    // MARK: /v1/models/select

    func testSelect() {
        guard case .selectModel(let id, let cors) = route(req("POST", "/v1/models/select",
                                                              json: ["model": "plamo-3-translate-2b"], origin: extOrigin)) else {
            return XCTFail("expected selectModel")
        }
        XCTAssertEqual(id, "plamo-3-translate-2b")
        XCTAssertEqual(cors["Access-Control-Allow-Origin"], extOrigin)

        // 選択中モデル / 別名: 切り替え不要で /health と同じ JSON を 200 で返す
        for same in ["plamo-3-translate-0.8b", "plamo-3-translate"] {
            let r = respond(route(req("POST", "/v1/models/select", json: ["model": same]), state(health: .loading)))!
            XCTAssertEqual(r.status, 200, same)
            XCTAssertEqual(body(r)["api"] as? Int, 1)
        }

        let missing = respond(route(req("POST", "/v1/models/select", json: ["model": "plamo-3-translate-8b"])))!
        XCTAssertEqual(missing.status, 409)
        XCTAssertEqual(errorType(missing), "model_not_installed")

        let unknown = respond(route(req("POST", "/v1/models/select", json: ["model": "gpt-4"])))!
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual(errorType(unknown), "not_found")

        XCTAssertEqual(respond(route(req("POST", "/v1/models/select", json: [:])))?.status, 400)
        XCTAssertEqual(respond(route(req("GET", "/v1/models/select")))?.status, 405)
    }

    // MARK: /v1/completions

    func testCompletionParsing() {
        let r = route(req("POST", "/v1/completions", origin: extOrigin,
            json: ["prompt": "P", "max_tokens": 64, "stop": "X", "stream": true, "temperature": 0]))
        guard case .generate(let c) = r else { return XCTFail() }
        XCTAssertEqual(c.prompt, "P")
        XCTAssertEqual(c.maxTokens, 64)
        XCTAssertTrue(c.stream)
        XCTAssertTrue(c.stop.contains("X"))
        XCTAssertTrue(c.stop.contains("<|plamo:tag|>"))
        XCTAssertEqual(c.kind, .completion)
        XCTAssertEqual(c.model, "plamo-3-translate-0.8b")
        XCTAssertNil(c.switchTo)
        XCTAssertEqual(c.cors["Access-Control-Allow-Origin"], extOrigin)
    }

    func testCompletionModelField() {
        for active in ["plamo-3-translate", "plamo-3-translate-0.8b", ""] {
            guard case .generate(let c) = route(req("POST", "/v1/completions", json: ["prompt": "P", "model": active])) else {
                return XCTFail(active)
            }
            XCTAssertNil(c.switchTo, active)
            XCTAssertEqual(c.model, "plamo-3-translate-0.8b")
        }
        guard case .generate(let c) = route(req("POST", "/v1/completions",
                                                json: ["prompt": "P", "model": "plamo-3-translate-2b"])) else {
            return XCTFail()
        }
        XCTAssertEqual(c.switchTo, "plamo-3-translate-2b")
        XCTAssertEqual(c.model, "plamo-3-translate-2b")

        let notInstalled = respond(route(req("POST", "/v1/completions", json: ["prompt": "P", "model": "plamo-3-translate-8b"])))!
        XCTAssertEqual(notInstalled.status, 409)
        XCTAssertEqual(errorType(notInstalled), "model_not_installed")

        let unknown = respond(route(req("POST", "/v1/completions", json: ["prompt": "P", "model": "nope"])))!
        XCTAssertEqual(unknown.status, 404)
    }

    func testCompletionErrors() {
        let bad = HTTPRequest(method: "POST", path: "/v1/completions", headers: ["host": "127.0.0.1:18080"],
                              body: Data("not json".utf8))
        let r = respond(route(bad))!
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(errorType(r), "invalid_request")
        XCTAssertEqual(respond(route(req("POST", "/v1/completions", json: [:])))?.status, 400)
        // 選択中モデルが未ダウンロード → 409
        let none = respond(route(req("POST", "/v1/completions", json: ["prompt": "x"]),
                                 state(health: .noModel, activeInstalled: false)))!
        XCTAssertEqual(none.status, 409)
        XCTAssertEqual(errorType(none), "model_not_installed")
    }

    func testMaxTokensParsing() {
        func tokens(_ json: [String: Any], path: String = "/v1/completions") -> Int? {
            guard case .generate(let c) = route(req("POST", path, json: json)) else { return nil }
            return c.maxTokens
        }
        var base: [String: Any] = ["prompt": "P"]
        XCTAssertEqual(tokens(base), APIRouter.defaultMaxTokens)              // 省略 → 既定
        base["max_tokens"] = NSNull()
        XCTAssertEqual(tokens(base), APIRouter.defaultMaxTokens)              // null → 既定
        XCTAssertEqual(tokens(["prompt": "P", "max_tokens": 64]), 64)
        XCTAssertEqual(tokens(["prompt": "P", "max_tokens": 64.9]), 64)       // 小数は切り捨て
        XCTAssertEqual(tokens(["prompt": "P", "max_tokens": -1]), APIRouter.defaultMaxTokens)
        XCTAssertEqual(tokens(["prompt": "P", "max_tokens": 0]), APIRouter.defaultMaxTokens)
        XCTAssertEqual(tokens(["prompt": "P", "max_tokens": 100_000]), APIRouter.maxAllowedTokens)   // 上限に丸める
        XCTAssertEqual(tokens(["prompt": "P", "n_predict": 128]), 128)
        XCTAssertEqual(tokens(["prompt": "P", "max_completion_tokens": 32]), 32)
        XCTAssertEqual(tokens(["prompt": "P", "max_tokens": 16, "n_predict": 999]), 16)   // max_tokens が優先

        // 巨大な数値・文字列・真偽値・配列は 400 invalid_request（以前は 1e30 で Int(Double) がトラップした）
        let chat: [String: Any] = ["messages": [["role": "user", "content": "Hello"]]]
        let bads: [Any] = [1e30, -1e30, 1e300, "64", true, false, [64], ["n": 1]]
        let payloads: [(String, [String: Any])] = [("/v1/completions", ["prompt": "P"]), ("/v1/chat/completions", chat)]
        for bad in bads {
            for (path, payload) in payloads {
                for key in ["max_tokens", "n_predict", "max_completion_tokens"] {
                    var json = payload
                    json[key] = bad
                    let r = respond(route(req("POST", path, json: json)))
                    XCTAssertEqual(r?.status, 400, "\(path) \(key)=\(bad)")
                    XCTAssertEqual(r.flatMap { errorType($0) }, "invalid_request", "\(path) \(key)=\(bad)")
                }
            }
        }

        // JSON では表せない値も直接確かめる
        XCTAssertNil(APIRouter.intValue(Double.nan))
        XCTAssertNil(APIRouter.intValue(Double.infinity))
        XCTAssertNil(APIRouter.intValue(-Double.infinity))
        XCTAssertNil(APIRouter.intValue(Double.greatestFiniteMagnitude))
        XCTAssertNil(APIRouter.intValue(9.3e18))
        XCTAssertNil(APIRouter.intValue(nil))
        XCTAssertNil(APIRouter.intValue("12"))
        XCTAssertNil(APIRouter.intValue(NSNumber(value: true)))
        XCTAssertEqual(APIRouter.intValue(NSNumber(value: 42)), 42)
        XCTAssertEqual(APIRouter.intValue(-3.7), -3)
        XCTAssertEqual(APIRouter.intValue(NSDecimalNumber(string: "2048")), 2048)
        if case .failure(let e) = APIRouter.maxTokens(["max_tokens": Double.nan]) {
            XCTAssertEqual(e.status, 400)
        } else {
            XCTFail("NaN must be rejected")
        }
    }

    func testFinishReasonShapes() {
        let tc = GenerationCall(kind: .completion, prompt: "p", maxTokens: 1, stop: [], stream: false, model: "m")
        let b = body(APIResponses.completion(call: tc, id: "cmpl-1", text: "訳", finish: APIFinishReason.length.rawValue))
        XCTAssertEqual((b["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String, "length")

        let chat = GenerationCall(kind: .chat, prompt: "p", maxTokens: 1, stop: [], stream: true, model: "m")
        let cb = body(APIResponses.completion(call: chat, id: "c", text: "x", finish: "length"))
        XCTAssertEqual((cb["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String, "length")
        let tail = String(decoding: APIResponses.sseChunk(call: chat, id: "c", text: nil, finish: "length"), as: UTF8.self)
        XCTAssertTrue(tail.contains("\"finish_reason\":\"length\""))
        let stop = String(decoding: APIResponses.sseChunk(call: tc, id: "c", text: "", finish: APIFinishReason.stop.rawValue), as: UTF8.self)
        XCTAssertTrue(stop.contains("\"finish_reason\":\"stop\""))

        // モデルの切り替え・解放による中断 → 503 unavailable（SSE 途中ならエラーイベント）
        let busy = APIResponses.error(for: APIError.unavailable("x"))
        XCTAssertEqual(busy.status, 503)
        XCTAssertEqual(errorType(busy), "unavailable")
        XCTAssertTrue(String(decoding: APIResponses.sseError(APIError.unavailable("x")), as: UTF8.self).contains("\"code\":503"))

        // プロンプト長超過はバックエンドが invalid_request に変換して投げる → 400
        let tooLong = APIResponses.error(for: APIError.invalidRequest("入力が長すぎます"))
        XCTAssertEqual(tooLong.status, 400)
        XCTAssertEqual(errorType(tooLong), "invalid_request")
    }

    func testNotFoundAndMethod() {
        let nf = respond(route(req("GET", "/nope")))!
        XCTAssertEqual(nf.status, 404)
        XCTAssertEqual(errorType(nf), "not_found")
        let m = respond(route(req("GET", "/v1/completions")))!
        XCTAssertEqual(m.status, 405)
        XCTAssertEqual(m.headers["Allow"], "POST")
    }

    func testErrorShape() {
        let r = respond(route(req("POST", "/v1/completions", json: ["prompt": "P", "model": "plamo-3-translate-8b"],
                                  origin: extOrigin)))!
        let err = body(r)["error"] as? [String: Any]
        XCTAssertNotNil(err?["message"] as? String)
        XCTAssertTrue((err?["message"] as? String)?.contains("8B") ?? false)
        XCTAssertEqual(err?["type"] as? String, "model_not_installed")
        XCTAssertEqual(err?["code"] as? Int, 409)
        XCTAssertEqual(r.headers["Access-Control-Allow-Origin"], extOrigin)   // エラーでも許可した Origin には CORS を付ける
        XCTAssertEqual(r.headers["Content-Type"], "application/json; charset=utf-8")

        // バックエンドのエラーの変換
        XCTAssertEqual(APIResponses.error(for: APIError.modelNotInstalled("2B")).status, 409)
        XCTAssertEqual(APIResponses.error(for: APIError.unknownModel("x")).status, 404)
        struct Boom: Error {}
        let s = APIResponses.error(for: Boom())
        XCTAssertEqual(s.status, 500)
        XCTAssertEqual(errorType(s), "server_error")
        XCTAssertTrue(String(decoding: APIResponses.sseError(APIError.server("x")), as: UTF8.self).contains("server_error"))
    }

    // MARK: /v1/chat/completions

    func testChatBuildsPFML3Prompt() {
        let json: [String: Any] = [
            "messages": [
                ["role": "user", "content": "Good morning"],
                ["role": "assistant", "content": "おはよう"],
                ["role": "user", "content": "Hello"],
            ],
            "chat_template_kwargs": ["target_lang": "ja", "form": "polite", "context": "greeting",
                                     "glossary": [["source": "Hello", "target": "やあ"]]],
        ]
        guard case .generate(let c) = route(req("POST", "/v1/chat/completions", json: json)) else {
            return XCTFail()
        }
        XCTAssertEqual(c.kind, .chat)
        XCTAssertTrue(c.prompt.hasPrefix("<|plamo:tag|>dataset<|plamo:msg|>translation"))
        XCTAssertTrue(c.prompt.contains("greeting"))
        XCTAssertTrue(c.prompt.contains("Good morning"))   // history
        XCTAssertTrue(c.prompt.contains("おはよう"))
        XCTAssertTrue(c.prompt.contains("やあ"))            // glossary
        XCTAssertTrue(c.prompt.contains("polite"))
        XCTAssertTrue(c.prompt.contains("<|plamo:msg|>Hello"))
    }

    func testChatRequiresTrailingUser() {
        let json: [String: Any] = ["messages": [["role": "assistant", "content": "x"]]]
        XCTAssertEqual(respond(route(req("POST", "/v1/chat/completions", json: json)))?.status, 400)
    }

    func testResponseShapes() {
        let call = GenerationCall(kind: .chat, prompt: "p", maxTokens: 1, stop: [], stream: false, model: "m")
        let r = APIResponses.completion(call: call, id: "i", text: " こんにちは \n")
        let choices = body(r)["choices"] as? [[String: Any]]
        XCTAssertEqual((choices?.first?["message"] as? [String: Any])?["content"] as? String, "こんにちは")
        let chunk = String(decoding: APIResponses.sseChunk(call: call, id: "i", text: "a", finish: nil), as: UTF8.self)
        XCTAssertTrue(chunk.hasPrefix("data: {"))
        XCTAssertTrue(chunk.hasSuffix("\n\n"))
        XCTAssertTrue(chunk.contains("\"delta\""))
        XCTAssertEqual(String(decoding: APIResponses.sseDone, as: UTF8.self), "data: [DONE]\n\n")

        let tc = GenerationCall(kind: .completion, prompt: "p", maxTokens: 1, stop: [], stream: false,
                                model: "plamo-3-translate-0.8b", created: 1_700_000_000)
        let b = body(APIResponses.completion(call: tc, id: "cmpl-1", text: "訳"))
        XCTAssertEqual(b["object"] as? String, "text_completion")
        XCTAssertEqual(b["created"] as? Int, 1_700_000_000)
        XCTAssertEqual(b["model"] as? String, "plamo-3-translate-0.8b")
        let c0 = (b["choices"] as? [[String: Any]])?.first
        XCTAssertEqual(c0?["text"] as? String, "訳")
        XCTAssertEqual(c0?["finish_reason"] as? String, "stop")
        let sse = String(decoding: APIResponses.sseChunk(call: tc, id: "cmpl-1", text: "差分", finish: nil), as: UTF8.self)
        XCTAssertTrue(sse.contains("\"finish_reason\":null"))
        XCTAssertTrue(sse.contains("\"text\":\"差分\""))

        let ser = String(decoding: HTTPResponse(status: 200, body: Data("{}".utf8)).serialized(), as: UTF8.self)
        XCTAssertTrue(ser.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(ser.contains("Content-Length: 2"))
        XCTAssertTrue(String(decoding: HTTPResponse(status: 409).serialized(), as: UTF8.self).hasPrefix("HTTP/1.1 409 Conflict"))
    }
}
