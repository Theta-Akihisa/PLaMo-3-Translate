import Foundation

// ローカル API（shared/local-api.md）とアプリ本体の境界。
// ルータは APIState（値のスナップショット）だけを見て応答を決めるので、I/O 無しでテストできる。

/// `/health` の status
enum APIHealth: String, Equatable, Sendable {
    case ok
    case loading
    case noModel = "no_model"
}

/// カタログの 1 モデルについて、API から見える状態
struct APIModelInfo: Equatable, Sendable {
    var id: String
    var size: String
    var label: String
    /// そのモデルを使うときの量子化（アプリで選択中のもの。未選択なら既定）
    var quant: String
    /// `quant` のファイルサイズ
    var sizeBytes: Int64
    /// `quant` がダウンロード済みか（= そのモデルをすぐ使えるか）
    var installed: Bool
    /// ダウンロード済みの量子化（カタログ順）
    var installedQuants: [String]
}

/// ルータに渡すアプリ状態のスナップショット
struct APIState: Equatable, Sendable {
    var appName: String = "PLaMo Translate"
    var version: String
    var health: APIHealth
    /// アプリで選択中のモデル ID
    var activeModelID: String
    /// 選択中モデルがメモリに読み込み済みか
    var loaded: Bool
    /// カタログの全モデル（0.8B / 2B / 8B）
    var models: [APIModelInfo]

    func model(id: String) -> APIModelInfo? { models.first { $0.id == id } }
    var activeModel: APIModelInfo? { model(id: activeModelID) }
}

/// API のエラー（OpenAI 互換の `{"error":{"message","type","code"}}` に変換される）
enum APIError: Error, Equatable {
    case forbiddenHost
    case forbiddenOrigin
    case invalidRequest(String)
    case notFound(String)
    case unknownModel(String)
    /// モデルの表示名（例: "2B"）
    case modelNotInstalled(String)
    case methodNotAllowed(String)
    case server(String)

    var status: Int {
        switch self {
        case .forbiddenHost, .forbiddenOrigin: return 403
        case .invalidRequest: return 400
        case .notFound, .unknownModel: return 404
        case .modelNotInstalled: return 409
        case .methodNotAllowed: return 405
        case .server: return 500
        }
    }

    var type: String {
        switch self {
        case .forbiddenHost: return "forbidden_host"
        case .forbiddenOrigin: return "forbidden_origin"
        case .invalidRequest, .methodNotAllowed: return "invalid_request"
        case .notFound, .unknownModel: return "not_found"
        case .modelNotInstalled: return "model_not_installed"
        case .server: return "server_error"
        }
    }

    var message: String {
        switch self {
        case .forbiddenHost:
            return "Host ヘッダが不正です。http://127.0.0.1:<ポート> または http://localhost:<ポート> で接続してください。"
        case .forbiddenOrigin:
            return "このオリジンからのアクセスは許可されていません（Chrome 拡張機能からのみ利用できます）。"
        case .invalidRequest(let m): return m
        case .notFound(let path): return "見つかりません: \(path)"
        case .unknownModel(let id): return "不明なモデル ID です: \(id)"
        case .modelNotInstalled(let label):
            return "モデル \(label) がダウンロードされていません。PLaMo Translate アプリの「モデル」画面でダウンロードしてください。"
        case .methodNotAllowed(let allowed): return "このメソッドは使用できません（使用可能: \(allowed)）。"
        case .server(let m): return m
        }
    }
}

/// 生成が終わった理由（OpenAI 互換の `finish_reason`）
enum APIFinishReason: String, Equatable, Sendable {
    /// EOG・停止文字列で終わった
    case stop
    /// `max_tokens`（またはコンテキストの残り）に達して打ち切られた
    case length
}

/// 生成ストリームの要素。テキスト差分の後に、ちょうど 1 回 `.finished` が来る。
enum APIStreamEvent: Equatable, Sendable {
    case text(String)
    case finished(APIFinishReason)
}

/// ローカル API サーバが状態の取得・モデル切り替え・生成を依頼する相手（AppModel が準拠する）。
@MainActor
protocol APIBackend: AnyObject {
    func apiState() -> APIState
    /// 使用モデルを切り替える（アプリの設定にも反映）。未知なら `.unknownModel`、未ダウンロードなら `.modelNotInstalled` を投げる。
    func apiSelectModel(id: String) throws
    /// 生のプロンプトを補完し、テキスト差分と終了理由のストリームを返す。
    /// `switchTo` が非 nil なら、先にそのモデルへ切り替えてから実行する。
    /// プロンプトがコンテキストに収まらない場合は `.invalidRequest` を（ストリーム経由で）投げる。
    func apiStream(prompt: String, maxTokens: Int, stop: [String],
                   switchTo: String?) async throws -> AsyncThrowingStream<APIStreamEvent, Error>
}
