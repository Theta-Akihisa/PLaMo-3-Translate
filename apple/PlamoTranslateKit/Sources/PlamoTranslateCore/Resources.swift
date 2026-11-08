import Foundation

enum SharedResource {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("バンドルリソース \(name).json が見つかりません（apple/scripts/sync-shared.sh を実行してください）")
        }
        return data
    }
}
