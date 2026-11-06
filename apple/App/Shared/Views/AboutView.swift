import SwiftUI

struct AboutView: View {
    private let licenseURL = URL(string: "https://plamo.preferredai.jp/info/plamo-community-license-ja")!
    private let hfURL = URL(string: "https://huggingface.co/pfnet")!
    private let llamaURL = URL(string: "https://github.com/ggml-org/llama.cpp")!

    var body: some View {
        Form {
            Section("このアプリ") {
                Text("PLaMo 3 Translate を端末上で動かすローカル翻訳アプリです。翻訳テキストは外部に送信されません（モデルのダウンロード時のみ通信します）。")
                    .font(.callout)
                Text("非公式アプリです。Preferred Networks, Inc. とは関係ありません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("モデル") {
                Text("PLaMo 3 Translate © Preferred Networks, Inc.")
                Link("Hugging Face: pfnet", destination: hfURL)
                Link("PLaMo Community License", destination: licenseURL)
                Text("モデルの利用は PLaMo Community License に従います。商用利用する場合は、ライセンスに定められた Preferred Networks への登録が必要です。詳細はライセンス本文を確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("オープンソース") {
                Text("llama.cpp — MIT License\nCopyright (c) 2023-2025 The ggml authors")
                    .font(.callout)
                Link("github.com/ggml-org/llama.cpp", destination: llamaURL)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("このアプリについて")
    }
}
