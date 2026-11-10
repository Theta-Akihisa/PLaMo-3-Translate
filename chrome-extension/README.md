# PLaMo 3 Translate — Chrome 拡張機能

PFN の翻訳 LLM **PLaMo 3 Translate** をローカルで使う Chrome 拡張機能（Manifest V3）です。DeepL 拡張のような操作感で、テキスト・選択範囲・ページ全体を端末の外に送信せず翻訳します。

**翻訳エンジンは macOS アプリ「PLaMo Translate」（本リポジトリの `apple/`）が基本です。** 拡張機能はアプリが `127.0.0.1:18080` で公開するローカル API に接続して翻訳します（仕様: [`shared/local-api.md`](../shared/local-api.md)）。モデルのダウンロード・切り替えはアプリで行います。llama-server への直接接続（上級者向け）とブラウザ内 WASM（実験的）も選べます。

## 機能

- **選択 → 翻訳アイコン**: テキストを選択すると横に小さな「P」アイコンが出ます。クリックすると選択範囲の近くにカードが開き、訳文がストリーミング表示されます。カード内で翻訳先・文体（自動 / 常体 / 敬体、翻訳先が日本語のとき）を変更でき、コピー、入力欄・contenteditable では「置き換え」もできます。アイコンは設定で無効にできます（右クリック「PLaMoで翻訳」と `Alt+Shift+T` は常に使えます）。
- **ポップアップ（ミニ翻訳）**: 上に原文・下に訳文の 2 ペイン。入力しながら自動翻訳（約 0.5 秒デバウンス、変更時は実行中のジョブをキャンセル）、文字数表示、コピー、⇄ 入れ替え。
- **言語を検出**: `chrome.i18n.detectLanguage` でローカル検出し、「英語（検出）」と表示。信頼できる場合のみ翻訳元をモデルに渡します。検出元が翻訳先と同じ場合は自動で英語（翻訳先が英語なら日本語）に切り替えます。
- **ページ全体の翻訳**: その場で置き換え。表示領域内の段落から順に、1 段落ずつ直列に翻訳します（直前の 1〜2 段落を `history` として渡し訳語・文体を揃えます）。ページ右下のツールバーで「翻訳を停止」「原文に戻す」と進捗を確認できます。コード・`pre`・入力欄・`translate="no"`・翻訳先と同じ言語のブロックはスキップします。
- **macOS アプリとの連携**: ポップアップ下部に接続状態（例「macOS アプリ · 0.8B Q4_K_M — 接続済み」）を表示。アプリが起動していなければ「アプリを起動」ボタン（`plamotranslate://open` を開き、約 15 秒間 `/health` を確認）。モデル（0.8B / 2B / 8B）はポップアップ・設定画面から切り替えられ、アプリの選択と同期します（未ダウンロードのサイズは「アプリでダウンロード」と表示され選べません）。
- 設定: 翻訳エンジン、エンドポイント、モデル、既定の言語・文体、用語集、文脈、最大トークン数。初回インストール時は「はじめに」（セットアップ手順と接続状態）が開きます。
- ショートカット: `Alt+Shift+T` 選択範囲を翻訳 / `Alt+Shift+P` ページ翻訳（`chrome://extensions/shortcuts` で変更可）。

## セットアップ（macOS アプリ方式・推奨）

1. **macOS アプリ「PLaMo Translate」をインストールして起動**（[`apple/README.md`](../apple/README.md)）。アプリのローカル API サーバーは既定で有効で、`http://127.0.0.1:18080` で待ち受けます（外部からは接続できません）。
2. **アプリでモデル（0.8B）をダウンロード**。アプリの「モデル」画面で 0.8B（Q4_K_M、約 573 MB）をダウンロードします。2B / 8B は後から追加できます。
3. **拡張機能をインストール**（下記）。初回は設定画面の「はじめに」が自動で開き、接続状態がリアルタイムに表示されます。「接続テスト」で「接続できました（0.8B Q4_K_M）」と出れば完了です。

既定の翻訳エンジンは「macOS アプリ」、エンドポイントは `http://127.0.0.1:18080` です。アプリ側でポートを変えた場合は、設定画面の「翻訳エンジン → macOS アプリ → エンドポイント」も合わせてください。

### 拡張機能のインストール

```bash
cd chrome-extension
npm install
npm run build        # dist/ に出力
```

Chrome で `chrome://extensions` を開き、「デベロッパー モード」をオン → 「パッケージ化されていない拡張機能を読み込む」で `chrome-extension/dist` を選択します。

開発用: `npm test`（ユニットテスト）、`npm run typecheck`、`npm run e2e`（Playwright E2E。macOS アプリのローカル API を模したモックサーバーを使用。モデル GGUF の置き場所は環境変数 `E2E_MODELS`、スクリーンショット出力先は `E2E_SCRATCH`）。E2E は `node build.mjs --e2e` で作るテスト用ビルド `dist-e2e/` を読み込みます（ページ内 UI の Shadow DOM を Playwright から調べられるよう open にしたもの。配布用の `dist/` は closed で、ページのスクリプトからは操作できません）。

### 旧バージョンからの更新

設定は自動で移行されます。以前の既定（「ローカルサーバー」・`http://127.0.0.1:8080`）のままだった場合は **macOS アプリ（18080）** に切り替わります。エンドポイントを変更していた場合は llama-server 方式のまま維持されます。PLaMo 3 を読み込めないブラウザ内 WASM を選んでいた場合も（モデル URL を上書きしていなければ）macOS アプリに切り替わります。8080 の llama-server を使い続ける場合は、設定画面で「llama-server」を選び直してください。

## 翻訳エンジンの比較

| | macOS アプリ（推奨・既定） | llama-server（上級者向け） | ブラウザ内 WASM（実験的） |
| --- | --- | --- | --- |
| 実行場所 | Mac の「PLaMo Translate」アプリ | 自分で起動した llama.cpp `llama-server` | 拡張機能内の WebAssembly（wllama） |
| 既定エンドポイント | `http://127.0.0.1:18080` | `http://127.0.0.1:8080` | — |
| モデル管理 | アプリの「モデル」画面（拡張機能から切替可） | 起動時に指定 | 初回にダウンロード |
| モデル | 0.8B / 2B / 8B | 0.8B / 2B / 8B | 0.8B / 2B のみ |
| 対応 OS | macOS | macOS / Windows / Linux | — |
| 現状 | 利用可 | 利用可 | **PLaMo 3 未対応**（下記） |

macOS アプリと llama-server はどちらも `POST {endpoint}/v1/completions` に `{model:"plamo-3-translate", prompt, max_tokens, temperature:0, stop:["<|plamo:tag|>","<|plamo:bos|>"], stream:true}` を送り、SSE の `choices[0].text` を連結します（同じコード）。プロンプトは拡張機能側で PFML3 形式に組み立て（`src/core/pfml3.ts`、公式テストベクタと完全一致）、BOS はサーバー側のトークナイザが付加します。macOS アプリでは `model: "plamo-3-translate"` が「アプリで選択中のモデル」の別名なので、アプリでの選択がそのまま使われます。

macOS アプリ方式では、さらに `GET /health`（`ok` / `loading` / `no_model`）、`GET /v1/models`（各サイズの `installed` / `active`）、`POST /v1/models/select`（モデル切替）を使います。通信はすべて拡張機能の Service Worker から行うため、リクエストの `Origin` は `chrome-extension://<拡張機能ID>`（GET では付かない場合あり）で、アプリの Origin 検査を通ります。一般の Web ページからのアクセスはアプリが `403` で拒否します。

### モデルサイズ

| サイズ | Q4_K_M | 必要メモリの目安 | 用途 |
| --- | --- | --- | --- |
| 0.8B（既定） | 573 MB | 2 GB〜 | 軽快・日常用途 |
| 2B | 1.8 GB | 4 GB〜 | 精度と速度のバランス |
| 8B | 5.3 GB | 8 GB〜 | 最高精度（macOS アプリ / llama-server） |

カタログは `../shared/models.json`、言語は `../shared/languages.json`（53 言語 + やさしい日本語 `ja-easy`）からビルド時に取り込みます。

## トラブルシューティング

| 表示 | 原因と対処 |
| --- | --- |
| 「macOS アプリが起動していません」 | アプリが起動していないか、API サーバーがオフです。「アプリを起動」を押す（`plamotranslate://open` を開きます。Chrome の確認ダイアログが出たら「開く」）か、手動でアプリを起動してください。アプリの設定で API サーバーが有効か、ポートが拡張機能の設定（既定 18080）と一致しているか確認します。 |
| 「アプリを起動」を押しても接続されない | アプリがインストールされていない、または URL スキームが登録されていない可能性があります。アプリを一度手動で起動してください。15 秒以内に接続できない場合はその旨を表示します。 |
| 「モデル未ダウンロード」 | アプリで選択中のモデルがまだダウンロードされていません。macOS アプリの『モデル』画面でダウンロードしてください（翻訳時は `409 model_not_installed` のメッセージを表示します）。 |
| 「読み込み中」 | アプリがモデルを読み込んでいます。数秒〜数十秒待つと「接続済み」になります。 |
| 「接続を拒否しました（forbidden_origin / forbidden_host）」 | アプリのセキュリティ検査で拒否されました。エンドポイントは `http://127.0.0.1:<port>` または `http://localhost:<port>` を指定してください（他のホスト名や IP では拒否されます）。 |
| モデルのサイズが選べない | 「アプリでダウンロード」と表示されているサイズは未ダウンロードです。アプリの「モデル」画面でダウンロードすると選べるようになります。アプリ側で切り替えた場合はアプリの選択が優先されます。 |
| 動作確認したい | ターミナルで `curl http://127.0.0.1:18080/health` を実行すると、アプリの状態（`status` と選択中モデル）が返ります。 |

## 上級者向け: llama-server

PLaMo 3 に対応した llama.cpp（2026-11 以降のビルド）が必要です。Windows / Linux ではこちらを使います。

```bash
# macOS / Linux
./scripts/run-llama-server.sh 0.8b          # 2b / 8b も可。量子化は第 2 引数 (既定 Q4_K_M)
# Windows (PowerShell)
.\scripts\run-llama-server.ps1 -Size 0.8b
```

スクリプトは Hugging Face からモデルを `~/.cache/plamo-3-translate` に取得し、`llama-server -m … --port 8080 -c 8192 --jinja --no-prefill-assistant` で起動します。拡張機能の設定で「llama-server」を選び、エンドポイント `http://127.0.0.1:8080` のまま「接続テスト」を押してください。この方式では設定画面のモデルサイズ / 量子化は表示と起動スクリプト引数の目安で、実際には llama-server が読み込んだモデルが使われます。

## 実験的: ブラウザ内 WASM

設定画面の「翻訳エンジン → 詳細設定（実験的なエンジン）」から選べます。

> **現状**: 同梱の `@wllama/wllama` 3.8.1 が含む llama.cpp（`b11364-46ca246`）は `plamo3` アーキテクチャは認識しますが、**PLaMo 3 のトークナイザ (`tokenizer.ggml.model = plamo3`) に未対応**のため、実モデルを読み込めません（`unknown tokenizer: 'plamo3'`）。選ぶと分かりやすいエラーを表示します。WASM 側のコード（オフスクリーン文書での実行、進捗表示、キャッシュ、キャンセル）は実装・検証済みで（非 PLaMo の小型 GGUF で動作確認）、wllama が PLaMo 3 対応版になれば `package.json` の wllama を更新するだけで使える想定です。8B はメモリと WebAssembly / `ArrayBuffer` の 2GB 制限のため、ブラウザ内では実行できません。

## プライバシー

- 翻訳するテキストは端末の外に送信されません。
- 通信が発生するのは、(1) macOS アプリ / llama-server（127.0.0.1 / localhost）への接続、(2) WASM（実験的）使用時のモデルダウンロード（Hugging Face）のみです。
- 設定は `chrome.storage.local`、WASM モデルはブラウザのキャッシュ領域（OPFS 等）に保存され、設定画面から削除できます。
- 権限: `storage` / `contextMenus` / `offscreen`、全ページへのコンテンツスクリプト（選択アイコンとページ翻訳のため）、`127.0.0.1` / `localhost` / `huggingface.co` へのホスト権限。

## 構成

```
src/core/        PFML3 ビルダー、カタログ、設定、言語検出、メッセージ型
src/background/  Service Worker（ジョブキュー・直列化・キャンセル、右クリック/ショートカット）
src/offscreen/   WASM 推論（wllama）を実行するオフスクリーン文書
src/engine/      macOS アプリ / llama-server 共通の HTTP クライアント (health・models・select・SSE) / wllama エンジン
src/content/     選択アイコン・カード・ページ翻訳（Shadow DOM）
src/popup/ src/options/
test/            vitest（公式テストベクタ全件の完全一致 + 検証、設定マイグレーション、/health 解釈）
e2e/             Playwright（macOS アプリのローカル API を模したモック / WASM）
```

メッセージは「popup・コンテンツ → Service Worker（ポート。切断 = キャンセル）→ fetch（macOS アプリ / llama-server）またはオフスクリーン文書（WASM）」の順で流れ、エンジンは 1 つなのでジョブは直列に処理します。

## ライセンス

- モデル（PLaMo 3 Translate）: [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-ja)。利用条件を確認のうえご利用ください。
- llama.cpp / wllama: MIT License。
- 本拡張機能のコード: 本リポジトリのライセンスに従います。
