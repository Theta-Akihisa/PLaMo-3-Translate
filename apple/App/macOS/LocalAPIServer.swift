import Foundation
import Network

/// 127.0.0.1 にのみバインドする最小の HTTP サーバ（Network.framework）。
/// 1 接続 1 リクエスト、レスポンス後に close する。
final class LocalAPIServer {
    enum State: Equatable {
        case stopped
        case running(UInt16)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "jp.example.plamotranslate.localapi")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: APIConnection] = [:]
    private let backend: any APIBackend

    init(backend: any APIBackend) {
        self.backend = backend
    }

    func start(port: UInt16, onState: @escaping (State) -> Void) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onState(.failed("無効なポート番号です"))
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // ループバック (127.0.0.1) のみ。LAN からは到達できない。
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: onState(.running(port))
                case .failed(let e): onState(.failed(e.localizedDescription))
                case .waiting(let e): onState(.failed(e.localizedDescription))
                case .cancelled: onState(.stopped)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener = l
            l.start(queue: queue)
        } catch {
            onState(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            let all = Array(self.connections.values)
            self.connections.removeAll()
            all.forEach { $0.finish() }
        }
    }

    private func accept(_ conn: NWConnection) {
        let c = APIConnection(conn: conn, backend: backend, queue: queue) { [weak self] closed in
            self?.queue.async { self?.connections.removeValue(forKey: ObjectIdentifier(closed)) }
        }
        connections[ObjectIdentifier(c)] = c
        c.start()
    }
}

final class APIConnection {
    private let conn: NWConnection
    private let backend: any APIBackend
    private let queue: DispatchQueue
    private let onClose: (APIConnection) -> Void
    private var parser = HTTPRequestParser()
    private let lock = NSLock()
    private var closed = false
    private var gotRequest = false
    private var genTask: Task<Void, Never>?

    init(conn: NWConnection, backend: any APIBackend, queue: DispatchQueue,
         onClose: @escaping (APIConnection) -> Void) {
        self.conn = conn
        self.backend = backend
        self.queue = queue
        self.onClose = onClose
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
        // リクエスト未受信のまま放置された接続を切る
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.gotRequest else { return }
            self.finish()
        }
    }

    func finish() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        genTask?.cancel()
        conn.cancel()
        onClose(self)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                switch self.parser.feed(data) {
                case .needMore:
                    self.receive()
                case .needMoreSendContinue:
                    self.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), close: false)
                    self.receive()
                case .request(let req):
                    self.gotRequest = true
                    self.handle(req)
                case .failure(var resp):
                    self.gotRequest = true
                    APIResponses.corsHeaders.forEach { resp.headers[$0.key] = $0.value }
                    self.send(resp.serialized(), close: true)
                }
                return
            }
            if error != nil || isComplete {
                self.finish()
            } else {
                self.receive()
            }
        }
    }

    private func send(_ data: Data, close: Bool) {
        if close {
            conn.send(content: data, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { [weak self] _ in self?.finish() })
        } else {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func handle(_ req: HTTPRequest) {
        genTask = Task { [weak self] in
            guard let self else { return }
            let health = await self.backend.apiHealth()
            switch APIRouter.route(req, health: health) {
            case .respond(let resp):
                self.send(resp.serialized(), close: true)
            case .generate(let call):
                await self.generate(call)
            }
        }
    }

    private func generate(_ call: GenerationCall) async {
        let id = APIResponses.newID(call)
        var started = false
        do {
            let stream = try await backend.apiStream(prompt: call.prompt, maxTokens: call.maxTokens, stop: call.stop)
            if call.stream {
                started = true
                send(HTTPResponse.streamingHead(headers: APIResponses.sseHeaders()), close: false)
                if call.kind == .chat {
                    send(APIResponses.sseChunk(call: call, id: id, text: nil, finish: nil, role: true), close: false)
                }
                for try await delta in stream {
                    if isClosed || Task.isCancelled { return }
                    if delta.isEmpty { continue }
                    send(APIResponses.sseChunk(call: call, id: id, text: delta, finish: nil), close: false)
                }
                var tail = APIResponses.sseChunk(call: call, id: id, text: call.kind == .chat ? nil : "", finish: "stop")
                tail.append(APIResponses.sseDone)
                send(tail, close: true)
            } else {
                var text = ""
                for try await delta in stream {
                    if isClosed || Task.isCancelled { return }
                    text += delta
                }
                send(APIResponses.completion(call: call, id: id, text: text).serialized(), close: true)
            }
        } catch {
            if started {
                // ストリーム途中のエラー: エラーイベントを送って閉じる
                let msg = APIResponses.jsonData(["error": ["message": error.localizedDescription]])
                send(Data(("data: " + String(decoding: msg, as: UTF8.self) + "\n\n").utf8) + APIResponses.sseDone, close: true)
            } else {
                send(APIResponses.error(status: 500, message: error.localizedDescription).serialized(), close: true)
            }
        }
    }
}
