import Foundation

/// ローカル API サーバが生成を依頼する相手（AppModel が準拠する）。
@MainActor
protocol APIBackend: AnyObject {
    func apiHealth() -> APIHealth
    /// 生のプロンプトを補完し、テキスト差分のストリームを返す。
    func apiStream(prompt: String, maxTokens: Int, stop: [String]) async throws -> AsyncThrowingStream<String, Error>
}
