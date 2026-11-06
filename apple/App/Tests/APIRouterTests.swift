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
    private func req(_ method: String, _ path: String, json: [String: Any]? = nil) -> HTTPRequest {
        let body = json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return HTTPRequest(method: method, path: path, body: body)
    }

    private func respond(_ route: APIRoute) -> HTTPResponse? {
        if case .respond(let r) = route { return r }
        return nil
    }

    private func body(_ r: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    func testHealth() {
        XCTAssertEqual(respond(APIRouter.route(req("GET", "/health"), health: .ok))?.status, 200)
        XCTAssertEqual(respond(APIRouter.route(req("GET", "/health"), health: .loading))?.status, 503)
        let r = respond(APIRouter.route(req("GET", "/health"), health: .ok))!
        XCTAssertEqual(body(r)["status"] as? String, "ok")
    }

    func testModelsAndCORS() {
        let r = respond(APIRouter.route(req("GET", "/v1/models"), health: .ok))!
        XCTAssertEqual(r.headers["Access-Control-Allow-Origin"], "*")
        let data = body(r)["data"] as? [[String: Any]]
        XCTAssertEqual(data?.first?["id"] as? String, "plamo-3-translate")
    }

    func testOptionsPreflight() {
        let r = respond(APIRouter.route(req("OPTIONS", "/v1/chat/completions"), health: .ok))!
        XCTAssertEqual(r.status, 204)
        XCTAssertNotNil(r.headers["Access-Control-Allow-Headers"])
    }

    func testNotFoundAndMethod() {
        XCTAssertEqual(respond(APIRouter.route(req("GET", "/nope"), health: .ok))?.status, 404)
        XCTAssertEqual(respond(APIRouter.route(req("GET", "/v1/completions"), health: .ok))?.status, 405)
    }

    func testCompletionParsing() {
        let route = APIRouter.route(req("POST", "/v1/completions",
            json: ["prompt": "P", "max_tokens": 64, "stop": "X", "stream": true, "temperature": 0]), health: .ok)
        guard case .generate(let c) = route else { return XCTFail() }
        XCTAssertEqual(c.prompt, "P")
        XCTAssertEqual(c.maxTokens, 64)
        XCTAssertTrue(c.stream)
        XCTAssertTrue(c.stop.contains("X"))
        XCTAssertTrue(c.stop.contains("<|plamo:tag|>"))
        XCTAssertEqual(c.kind, .completion)
    }

    func testCompletionErrors() {
        let bad = HTTPRequest(method: "POST", path: "/v1/completions", body: Data("not json".utf8))
        XCTAssertEqual(respond(APIRouter.route(bad, health: .ok))?.status, 400)
        XCTAssertEqual(respond(APIRouter.route(req("POST", "/v1/completions", json: [:]), health: .ok))?.status, 400)
        XCTAssertEqual(respond(APIRouter.route(req("POST", "/v1/completions", json: ["prompt": "x"]), health: .noModel))?.status, 503)
    }

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
        guard case .generate(let c) = APIRouter.route(req("POST", "/v1/chat/completions", json: json), health: .ok) else {
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
        XCTAssertEqual(respond(APIRouter.route(req("POST", "/v1/chat/completions", json: json), health: .ok))?.status, 400)
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
        let ser = String(decoding: HTTPResponse(status: 200, body: Data("{}".utf8)).serialized(), as: UTF8.self)
        XCTAssertTrue(ser.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(ser.contains("Content-Length: 2"))
    }
}
