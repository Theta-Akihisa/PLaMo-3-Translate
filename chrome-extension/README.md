# PLaMo 3 Translate — Chrome 拡張機能

PFN の翻訳 LLM **PLaMo 3 Translate**（GGUF）をローカルで動かす Chrome 拡張機能（Manifest V3）です。DeepL 拡張のような操作感で、テキスト・選択範囲・ページ全体を端末の外に送信せず翻訳します。

## 機能

- **選択 → 翻訳アイコン**: テキストを選択すると横に小さな「P」アイコンが出ます。クリックすると選択範囲の近くにカードが開き、訳文がストリーミング表示されます。カード内で翻訳先・文体（自動 / 常体 / 敬体、翻訳先が日本語のとき）を変更でき、コピー、入力欄・contenteditable では「置き換え」もできます。アイコンは設定で無効にできます（右クリック「PLaMoで翻訳」と `Alt+Shift+T` は常に使えます）。
- **ポップアップ（ミニ翻訳）**: 上に原文・下に訳文の 2 ペイン。入力しながら自動翻訳（約 0.5 秒デバウンス、変更時は実行中のジョブをキャンセル）、文字数表示、コピー、⇄ 入れ替え。
- **言語を検出**: `chrome.i18n.detectLanguage` でローカル検出し、「英語（検出）」と表示。信頼できる場合のみ翻訳元をモデルに渡します。検出元が翻訳先と同じ場合は自動で英語（翻訳先が英語なら日本語）に切り替えます。
- **ページ全体の翻訳**: その場で置き換え。表示領域内の段落から順に、1 段落ずつ直列に翻訳します（直前の 1〜2 段落を `history` として渡し訳語・文体を揃えます）。ページ右下のツールバーで「翻訳を停止」「原文に戻す」と進捗を確認できます。コード・`pre`・入力欄・`translate="no"`・翻訳先と同じ言語のブロックはスキップします。
- 設定: バックエンド、モデルサイズ / 量子化、エンドポイント、既定の言語・文体、用語集、文脈、最大トークン数、キャッシュ削除。
- ショートカット: `Alt+Shift+T` 選択範囲を翻訳 / `Alt+Shift+P` ページ翻訳（`chrome://extensions/shortcuts` で変更可）。

## インストール

```bash
cd chrome-extension
npm install
npm run build        # dist/ に出力
```

Chrome で `chrome://extensions` を開き、「デベロッパー モード」をオン → 「パッケージ化されていない拡張機能を読み込む」で `chrome-extension/dist` を選択します。

開発用: `npm test`（ユニットテスト）、`npm run typecheck`、`npm run e2e`（Playwright E2E。モデル GGUF の置き場所は環境変数 `E2E_MODELS`、スクリーンショット出力先は `E2E_SCRATCH`）。

## バックエンドの選び方

| | ローカルサーバー（既定） | ブラウザ内 (WASM) ※実験的 |
| --- | --- | --- |
| 実行場所 | llama-server / macOS アプリの API サーバー | 拡張機能内の WebAssembly（wllama） |
| モデル | 0.8B / 2B / 8B | 0.8B / 2B のみ |
| 速度 | 速い（ネイティブ / GPU） | 遅い（CPU の WASM） |
| 準備 | サーバー起動が必要 | 不要（初回にモデルをダウンロード） |

> **重要（現状）**: 同梱の `@wllama/wllama` 3.8.1 が含む llama.cpp（`b11364-46ca246`）は `plamo3` アーキテクチャは認識しますが、**PLaMo 3 のトークナイザ (`tokenizer.ggml.model = plamo3`) に未対応**のため、実モデルを読み込めません（`unknown tokenizer: 'plamo3'`）。そのため既定バックエンドはローカルサーバーにしてあり、WASM を選ぶと分かりやすいエラーを表示します。WASM 側のコード（オフスクリーン文書での実行、進捗表示、キャッシュ、キャンセル）は実装・検証済みで（非 PLaMo の小型 GGUF で動作確認）、wllama が PLaMo 3 対応版になれば `package.json` の wllama を更新するだけで使える想定です。

8B はメモリと WebAssembly / `ArrayBuffer` の 2GB 制限のため、ブラウザ内では実行できません（ローカルサーバー専用）。

### モデルサイズ

| サイズ | Q4_K_M | 必要メモリの目安 | 用途 |
| --- | --- | --- | --- |
| 0.8B（既定） | 573 MB | 2 GB〜 | 軽快・日常用途 |
| 2B | 1.8 GB | 4 GB〜 | 精度と速度のバランス |
| 8B | 5.3 GB | 8 GB〜 | 最高精度（ローカルサーバーのみ） |

カタログは `../shared/models.json`、言語は `../shared/languages.json`（53 言語 + やさしい日本語 `ja(easy)`）からビルド時に取り込みます。

## ローカルサーバーのセットアップ

### A. llama-server（llama.cpp）

PLaMo 3 に対応した llama.cpp（2026-11 以降のビルド）が必要です。

```bash
# macOS / Linux
./scripts/run-llama-server.sh 0.8b          # 2b / 8b も可。量子化は第 2 引数 (既定 Q4_K_M)
# Windows (PowerShell)
.\scripts\run-llama-server.ps1 -Size 0.8b
```

スクリプトは Hugging Face からモデルを `~/.cache/plamo-3-translate` に取得し、`llama-server -m … --port 8080 -c 8192 --jinja --no-prefill-assistant` で起動します。拡張機能の設定では「ローカルサーバー」、エンドポイント `http://127.0.0.1:8080` のまま「接続テスト」を押してください。

### B. macOS アプリの内蔵 API サーバー

本リポジトリの macOS アプリは、同じポート (8080)・同じエンドポイント（`GET /health`、`POST /v1/completions`）の API サーバーを内蔵しています。アプリで API サーバーを有効にすれば、拡張機能は設定変更なしで接続できます。

拡張機能は `POST {endpoint}/v1/completions` に `{model:"plamo-3-translate", prompt, max_tokens, temperature:0, stop:["<|plamo:tag|>","<|plamo:bos|>"], stream:true}` を送り、SSE の `choices[0].text` を連結します。プロンプトは拡張機能側で PFML3 形式に組み立て（`src/core/pfml3.ts`、公式テストベクタと完全一致）、BOS はサーバーのトークナイザが付加します。

## プライバシー

- 翻訳するテキストは端末の外に送信されません。
- 通信が発生するのは、(1) ローカルサーバー（127.0.0.1 / localhost）への接続、(2) WASM バックエンド使用時のモデルダウンロード（Hugging Face）のみです。
- 設定は `chrome.storage.local`、WASM モデルはブラウザのキャッシュ領域（OPFS 等）に保存され、設定画面から削除できます。
- 権限: `storage` / `contextMenus` / `offscreen`、全ページへのコンテンツスクリプト（選択アイコンとページ翻訳のため）、`127.0.0.1` / `localhost` / `huggingface.co` へのホスト権限。

## 構成

```
src/core/        PFML3 ビルダー、カタログ、設定、言語検出、メッセージ型
src/background/  Service Worker（ジョブキュー・直列化・キャンセル、右クリック/ショートカット）
src/offscreen/   WASM 推論（wllama）を実行するオフスクリーン文書
src/engine/      ローカルサーバー(SSE) / wllama エンジン
src/content/     選択アイコン・カード・ページ翻訳（Shadow DOM）
src/popup/ src/options/
test/            vitest（公式テストベクタ全件の完全一致 + 検証）
e2e/             Playwright（モック OpenAI 互換サーバー / WASM）
```

メッセージは「popup・コンテンツ → Service Worker（ポート。切断 = キャンセル）→ fetch（ローカル）またはオフスクリーン文書（WASM）」の順で流れ、エンジンは 1 つなのでジョブは直列に処理します。

## ライセンス

- モデル（PLaMo 3 Translate）: [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-ja)。利用条件を確認のうえご利用ください。
- llama.cpp / wllama: MIT License。
- 本拡張機能のコード: 本リポジトリのライセンスに従います。
