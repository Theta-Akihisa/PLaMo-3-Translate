import Foundation

public struct ModelFile: Codable, Hashable, Sendable {
    public var quant: String
    public var file: String
    public var sizeBytes: Int64
    public var sha256: String
    public var url: URL
    public init(quant: String, file: String, sizeBytes: Int64, sha256: String, url: URL) {
        self.quant = quant; self.file = file; self.sizeBytes = sizeBytes; self.sha256 = sha256; self.url = url
    }
}

public struct ModelSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var size: String
    public var label: String
    public var description: String
    public var minRamGB: Int
    public var repo: String
    public var defaultQuant: String
    public var files: [ModelFile]

    public init(id: String, size: String, label: String, description: String, minRamGB: Int,
                repo: String, defaultQuant: String, files: [ModelFile]) {
        self.id = id; self.size = size; self.label = label; self.description = description
        self.minRamGB = minRamGB; self.repo = repo; self.defaultQuant = defaultQuant; self.files = files
    }

    public var defaultFile: ModelFile {
        files.first { $0.quant == defaultQuant } ?? files[0]
    }

    public func file(quant: String?) -> ModelFile {
        guard let q = quant, let f = files.first(where: { $0.quant == q }) else { return defaultFile }
        return f
    }
}

public enum ModelCatalog {
    private struct File: Decodable { let models: [ModelSpec] }

    public static let all: [ModelSpec] = {
        do { return try JSONDecoder().decode(File.self, from: SharedResource.data("models")).models }
        catch { fatalError("models.json の読み込みに失敗: \(error)") }
    }()

    /// 既定モデル（0.8B）
    public static let defaultModel: ModelSpec = all.first { $0.size == "0.8b" } ?? all[0]

    public static func spec(id: String) -> ModelSpec? {
        all.first { $0.id == id }
    }
}
