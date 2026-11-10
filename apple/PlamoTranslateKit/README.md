# PlamoTranslateKit

PFN の **PLaMo 3 Translate**（GGUF）を llama.cpp でオンデバイス実行するための共有 Swift パッケージです（iOS 17 / macOS 14）。
PFML3 プロンプトは Jinja を使わずアプリ側で直接組み立てます（仕様は `shared/README.md`）。

## ターゲット

| ターゲット | 内容 | 依存 |
| --- | --- | --- |
| `PlamoTranslateCore` | 純 Swift（Foundation のみ、Linux でもビルド可）。PFML3、言語・モデルカタログ、段落分割、設定型 | なし |
| `PlamoTranslateKit` | `LlamaEngine` / `ModelStore` / `Translator`（Apple プラットフォーム専用。`#if canImport(llama)`） | Core, `llama` |

`Package.swift` の products は両方公開しているので、アプリは通常 `PlamoTranslateKit` をリンクし、`import PlamoTranslateKit` と `import PlamoTranslateCore` を使います。

## API 概要

```swift
// Core
TranslationRequest(text:targetLang:sourceLang:form:context:glossary:history:)
PFML3.buildPrompt(_:) throws -> String      // PFML3Error（日本語メッセージ）
PFML3.cleanOutput(_:) -> String
PFML3.stopStrings
LanguageCatalog.all / .targets / .name(for:)
ModelCatalog.all / .defaultModel / .spec(id:)
TextSegmenter.segments(_:) -> [Segment]      // .text / .separator（区切りを保持）
TextSegmenter.paragraphs(_:)
TranslationSettings                          // Codable。makeRequest(text:history:)

// Kit
let store = ModelStore()                     // @MainActor, ObservableObject
try await store.download(spec.defaultFile)   // store.downloads[file.file] で進捗 (.downloading(progress:)/.verifying/.failed)
store.cancelDownload(file); try store.delete(file)   // 呼び出し元タスクのキャンセルでも中止できる
try await store.importLocalFile(url:)        // 既存 GGUF を取り込む

let translator = Translator(store: store)    // @MainActor, ObservableObject
try await translator.load(model: spec, quant: nil, contextLength: 8192)
translator.unload()
for try await delta in translator.translate(request, maxTokens: 2048) { ... }  // 差分ストリーム
try await translator.translateOnce(request)                                    // 全文
for try await p in translator.translateDocument(text: t, settings: s) { p.text }  // 段落ごと＋履歴つき
Translator.recommendedModels() / Translator.memoryWarning(for:)

// 低レベル（ローカル API など）
let engine = translator.engine!              // LlamaEngine（actor）
for try await e in engine.completeEvents(prompt: p, maxTokens: n, stop: PFML3.stopStrings) {
    switch e {
    case .text(let delta): ...
    case .finished(let reason): ...          // FinishReason.stop / .length
    }
}
engine.complete(prompt:maxTokens:stop:)      // テキスト差分のみ（終了理由なし）
try await engine.tokenCount(of: text)        // BOS を含むトークン数
```

- エンジンへのリクエストは `LlamaEngine`（actor）で直列化されます。UI と HTTP API から同時に呼んで構いません。
- ストリームを購読するタスクをキャンセル（または break）すると生成が中断されます。
- 生成は greedy（temperature 0）。`<|plamo:tag|>` / `<|plamo:bos|>` または EOG で停止します。
- `prompt + maxTokens` がコンテキストを超える場合は `maxTokens` を自動で切り詰め、プロンプト自体が収まらない場合は `LlamaEngineError.promptTooLong`。

### 出力の打ち切り（`FinishReason.length`）

- `completeEvents` は正常終了時に最後に `.finished` をちょうど 1 回流します。EOG・停止文字列より先にトークン予算
  （`maxTokens` またはコンテキストの残り）を使い切ると `.length` です（`maxTokens <= 0` も `.length`）。
- `Translator.translate` は全差分を流したあと `TranslatorError.outputTruncated` を投げて終わります。`translateOnce` も同様です。
- `translateDocument` は打ち切られた段落の途中までの訳を残して次の段落へ進み、`DocumentProgress.truncatedParagraphs` で件数を報告します
  （その段落は history に加えません）。

### history とコンテキスト長

`translate` / `translateDocument` は、プロンプト + 生成用の予約（原文トークン数 × 2 + 64、最低 256、上限 `maxTokens`）が
コンテキストに収まるよう、history を古いものから削ります（`PromptBudget.fitHistory`）。history を全て削っても
原文自体が収まらない場合は `LlamaEngineError.promptTooLong` です。

### モデルの読み込み・解放

- `load` は、ファイルが無ければ現在のモデルを残したまま `TranslatorError.modelNotInstalled` を投げます。
- `load` / `unload` は直列化され、後から呼んだものが優先されます。追い越された `load` は `CancellationError` を投げます。
- 新しいモデルを読み込む前に、旧エンジンの生成（`engine.complete*` を直接使うものも含む）を中止して停止を待ち、
  メモリを解放します（`LlamaEngine.shutdown()`）。2 つのモデルが同時にメモリに載ることはありません。
  中止された生成のストリームは `CancellationError` で終わります。

## llama.cpp の固定（pin）

`Package.swift` の `binaryTarget("llama")` で、llama.cpp 公式リリースの XCFramework を **b12176** に固定しています（URL + checksum）。
slice は `macos-arm64_x86_64` と `ios-arm64` のみです。

### 更新手順

1. 新しいリリース（例 `bXXXXX`）から `llama-bXXXXX-xcframework.zip` をダウンロード
2. `swift package compute-checksum llama-bXXXXX-xcframework.zip`
3. `Package.swift` の `url` と `checksum` を更新
4. `LlamaEngine.swift` が使う C API（`llama.h`）に変更がないか確認してビルド

## 端末・実行環境の注意

- **iOS シミュレータ slice はありません。** 実機または Mac（My Mac / Designed for iPad ではなくネイティブ macOS）で実行してください。
- 実機では Metal を使います（`gpuLayers: 99`）。
- メモリ目安（コンテキスト 8192、Q4_K_M。**あくまで推定値**）: 0.8B 約 1 GB / 2B 約 2.5 GB / 8B 約 6.5 GB。
  iPhone で 8B は強制終了の恐れがあるため `Translator.memoryWarning(for:)` で警告してください。
- モデルは `Application Support/PlamoTranslate/Models` に保存され、iCloud バックアップ対象外です。ダウンロードは SHA-256 検証後に配置します。
  途中の一時ファイル（`.download-*` / `.import-*`）は失敗・中止時に削除し、`ModelStore` の初期化時にも残骸を掃除します。
  中止したダウンロードの再開データは `.partial/<sha256>.resume` に保存されます。

## 共有データの同期とテスト

`shared/*.json` はパッケージ内にコピーして使います。`shared/` を更新したら:

```sh
apple/scripts/sync-shared.sh
```

テスト（純 Swift 部分。Linux でも可）:

```sh
cd apple/PlamoTranslateKit
swift test --filter PlamoTranslateCoreTests
```
