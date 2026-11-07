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
    /// 待ち受け中のポート（Host ヘッダの検査に使う。queue 上でのみ参照）
    private var port: UInt16?

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
            queue.async { [weak self] in self?.port = port }
            l.start(queue: queue)
        } catch {
            onState(.failed(error.localizedDescription))
        }
    }

    func stop() {
        // 再起動時に古いリスナーの .cancelled が新しい状態を上書きしないよう、先にハンドラを外す
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
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
        let c = APIConnection(conn: conn, backend: backend, queue: queue, port: port) { [weak self] closed in
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
    private let port: UInt16?
    private let onClose: (APIConnection) -> Void
    private var parser = HTTPRequestParser()
    private let lock = NSLock()
    private var closed = false
    private var gotRequest = false
    private var genTask: Task<Void, Never>?

    init(conn: NWConnection, backend: any APIBackend, queue: DispatchQueue, port: UInt16?,
         onClose: @escaping (APIConnection) -> Void) {
        self.conn = conn
        self.backend = backend
        self.queue = queue
        self.port = port
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

    /// 接続を閉じ、進行中の生成を中断する（何度呼んでもよい）
    func finish() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let task = genTask
        lock.unlock()
        task?.cancel()
        conn.cancel()
        onClose(self)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                switch self.parser.feed(data) {
                case .needMore:
                    if isComplete || error != nil { self.finish() } else { self.receive() }
                case .needMoreSendContinue:
                    self.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), close: false)
                    self.receive()
                case .request(let req):
                    self.gotRequest = true
                    self.handle(req)
                    self.watchForDisconnect()
                case .failure(var resp):
                    self.gotRequest = true
                    resp.headers["Vary"] = "Origin"
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

    /// リクエスト受信後も読み続け、クライアントが接続を閉じたら（fetch の中断など）生成を止める。
    /// 追加で届いたデータ（パイプライン化されたリクエスト）は読み捨てる。
    private func watchForDisconnect() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if error != nil || isComplete {
                self.finish()
            } else {
                self.watchForDisconnect()
            }
        }
    }

    private func send(_ data: Data, close: Bool) {
        guard !isClosed else { return }
        if close {
            conn.send(content: data, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { [weak self] _ in self?.finish() })
        } else {
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish() }
            })
        }
    }

    private func send(_ resp: HTTPResponse, cors: [String: String]) {
        var r = resp
        r.headers.merge(cors) { _, new in new }
        send(r.serialized(), close: true)
    }

    private func handle(_ req: HTTPRequest) {
        let task = Task { [weak self] in
            guard let self else { return }
            let state = await self.backend.apiState()
            switch APIRouter.route(req, state: state, port: self.port) {
            case .respond(let resp):
                self.send(resp.serialized(), close: true)
            case .selectModel(let id, let cors):
                await self.select(id, cors: cors)
            case .generate(let call):
                await self.generate(call)
            }
        }
        lock.lock()
        let alreadyClosed = closed
        genTask = task
        lock.unlock()
        if alreadyClosed { task.cancel() }
    }

    private func select(_ id: String, cors: [String: String]) async {
        do {
            try await backend.apiSelectModel(id: id)
            let state = await backend.apiState()
            send(APIResponses.health(state, httpStatus: 200), cors: cors)
        } catch {
            send(APIResponses.error(for: error), cors: cors)
        }
    }

    private func generate(_ call: GenerationCall) async {
        let id = APIResponses.newID(call)
        var headSent = false
        // finish_reason: LlamaEngine.complete は停止理由（停止文字列/EOG/max_tokens）を返さないため常に "stop"
        let finish = "stop"
        do {
            let stream = try await backend.apiStream(prompt: call.prompt, maxTokens: call.maxTokens,
                                                     stop: call.stop, switchTo: call.switchTo)
            if isClosed || Task.isCancelled { return }
            var it = stream.makeAsyncIterator()
            if call.stream {
                // 最初の差分（または終了）を待ってからヘッダを送る。
                // プロンプト長超過などの早期エラーを通常の HTTP エラーとして返せる。
                let first = try await it.next()
                if isClosed || Task.isCancelled { return }
                send(HTTPResponse.streamingHead(headers: APIResponses.sseHeaders(cors: call.cors)), close: false)
                headSent = true
                if call.kind == .chat {
                    send(APIResponses.sseChunk(call: call, id: id, text: nil, finish: nil, role: true), close: false)
                }
                var next = first
                while let delta = next {
                    if !delta.isEmpty {
                        send(APIResponses.sseChunk(call: call, id: id, text: delta, finish: nil), close: false)
                    }
                    next = try await it.next()
                    if isClosed || Task.isCancelled { return }
                }
                var tail = APIResponses.sseChunk(call: call, id: id, text: call.kind == .chat ? nil : "", finish: finish)
                tail.append(APIResponses.sseDone)
                send(tail, close: true)
            } else {
                var text = ""
                while let delta = try await it.next() {
                    if isClosed || Task.isCancelled { return }
                    text += delta
                }
                if isClosed || Task.isCancelled { return }
                send(APIResponses.completion(call: call, id: id, text: text, finish: finish), cors: call.cors)
            }
        } catch {
            if isClosed || Task.isCancelled { return }
            if headSent {
                // ストリーム途中のエラー: エラーイベントを送って閉じる
                send(APIResponses.sseError(error) + APIResponses.sseDone, close: true)
            } else {
                send(APIResponses.error(for: error), cors: call.cors)
            }
        }
    }
}
