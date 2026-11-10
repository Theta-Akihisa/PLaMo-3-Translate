# macOS アプリ ローカル API（Chrome 拡張機能 ⇔ macOS アプリ）

Chrome 拡張機能は **macOS アプリ「PLaMo Translate」を翻訳エンジンとして呼び出す方式が既定**です。
macOS アプリが `127.0.0.1` 上に llama-server 互換のサブセット API を公開し、拡張機能は PFML3 プロンプトを組み立てて `/v1/completions` に送ります。
（同じ形式なので、上級者向けに素の `llama-server` にも接続できます。）

## 既定値

| 項目 | 値 |
| --- | --- |
| バインド先 | `127.0.0.1` のみ（外部からは接続不可） |
| ポート | **18080**（アプリ・拡張機能とも設定で変更可） |
| API サーバー | **既定で有効**（アプリ起動中は常に待ち受け。設定でオフにできる） |
| アプリ起動 URL | `plamotranslate://open`（macOS アプリも URL スキームを登録） |

## セキュリティ

1. **Host ヘッダ検査（DNS リバインディング対策）**: `Host` が `127.0.0.1:<port>` / `localhost:<port>`（ポート省略も可）以外なら `403`。
2. **Origin 検査**: `Origin` ヘッダがある場合、`chrome-extension://` で始まるものだけ許可。それ以外（一般の Web ページ）は `403`（`type: "forbidden_origin"`）。
   `Origin` が無いリクエスト（curl など）は許可。
3. CORS: 許可した Origin をそのまま `Access-Control-Allow-Origin` に返し、`Vary: Origin`。`OPTIONS` プリフライトにも同じ判定を適用し、
   `Access-Control-Allow-Private-Network: true` を返す。
4. ボディ上限 1 MB。

## エラー形式（OpenAI 互換）

```json
{"error": {"message": "日本語のメッセージ", "type": "model_not_installed", "code": 409}}
```

| type | HTTP | 意味 |
| --- | --- | --- |
| `forbidden_origin` / `forbidden_host` | 403 | 上記セキュリティ検査で拒否 |
| `model_not_installed` | 409 | 指定（または選択中）のモデルが未ダウンロード。アプリの「モデル」画面でダウンロードが必要 |
| `invalid_request` | 400 | JSON 不正・必須項目なし・PFML3 検証エラーなど |
| `not_found` | 404 | 未知のパス／未知のモデル ID |
| `unavailable` | 503 | モデルの切り替え・解放のため生成を中断した（再試行してよい）。SSE 開始後はエラーイベントとして届く |
| `server_error` | 500 | 推論エラーなど |

## エンドポイント

### `GET /health`

```json
{
  "status": "ok",                 // "ok" | "loading" | "no_model"
  "app": "PLaMo Translate",
  "version": "1.0.0",             // CFBundleShortVersionString
  "api": 1,                       // この仕様のバージョン
  "model": {"id": "plamo-3-translate-0.8b", "size": "0.8b", "label": "0.8B", "quant": "Q4_K_M", "loaded": true}
}
```

- `ok`（HTTP 200）: 選択中モデルがダウンロード済み（未ロードでも可。最初のリクエストで自動ロード）。
- `loading`（HTTP 503）: モデル読み込み中。
- `no_model`（HTTP 503）: 選択中モデルが未ダウンロード（`model` は選択中モデルの情報、`loaded: false`）。

### `GET /v1/models`

カタログの全モデル（0.8B / 2B / 8B）と、選択中モデルの別名 `plamo-3-translate` を返す。

```json
{"object": "list", "data": [
  {"id": "plamo-3-translate", "object": "model", "owned_by": "pfnet", "alias_of": "plamo-3-translate-0.8b"},
  {"id": "plamo-3-translate-0.8b", "object": "model", "owned_by": "pfnet", "size": "0.8b", "label": "0.8B",
   "installed": true, "active": true, "quant": "Q4_K_M", "installed_quants": ["Q4_K_M"], "size_bytes": 573123200},
  {"id": "plamo-3-translate-2b", "object": "model", "owned_by": "pfnet", "size": "2b", "label": "2B",
   "installed": false, "active": false, "quant": "Q4_K_M", "installed_quants": [], "size_bytes": 1807199392},
  {"id": "plamo-3-translate-8b", ...}
]}
```

`quant` は「そのモデルを使うときの量子化」（アプリで選択中のもの。未選択なら既定 `Q4_K_M`）、`size_bytes` はその量子化のファイルサイズ。

### `POST /v1/models/select`

```json
{"model": "plamo-3-translate-2b"}
```

アプリの使用モデルを切り替える（アプリの設定にも反映され、UI と同期）。量子化はアプリで選択済みのものを使う。
成功時は `/health` と同じ JSON（HTTP 200）。未ダウンロードなら `409 model_not_installed`、未知の ID は `404`。

### `POST /v1/completions`（llama-server 互換サブセット）

```json
{"model": "plamo-3-translate", "prompt": "<|plamo:tag|>dataset<|plamo:msg|>translation…<|plamo:msg|>",
 "max_tokens": 2048, "temperature": 0, "stop": ["<|plamo:tag|>", "<|plamo:bos|>"], "stream": true}
```

- `prompt` は PFML3 文字列（BOS は含めない。アプリがトークナイズ時に付加）。
- `model` は省略可。`plamo-3-translate` または選択中モデルの ID なら選択中モデルで実行。
  別のダウンロード済みモデル ID が指定された場合は `/v1/models/select` と同様に切り替えてから実行。
- `max_tokens`（別名 `n_predict` / `max_completion_tokens`）: 省略・`null`・0 以下（`-1` など）は既定 2048、上限 8192 に丸める。
  数値でない値・有限でない値・極端に大きい値（`1e30` など）は `400 invalid_request`。
- 非ストリーム: `{"id","object":"text_completion","created","model","choices":[{"index":0,"text":"…","finish_reason":"stop"|"length"}]}`
- `stream: true`: SSE で `data: {"choices":[{"index":0,"text":"差分","finish_reason":null}]}` を送り、最後に `finish_reason` 付きチャンクと `data: [DONE]`。
- `finish_reason`: `max_tokens`（またはコンテキストの残り）に達して打ち切られたら `"length"`、EOG・停止文字列で終わったら `"stop"`。
  `"length"` のときは訳文が途中で切れている可能性がある。
- プロンプトがモデルのコンテキスト長に収まらない場合は `400 invalid_request`（SSE でもヘッダ送信前に通常の HTTP エラーとして返す）。
- クライアントが接続を閉じたら生成を中断する。リクエストはアプリ内で直列化される（UI の翻訳と同じエンジン）。

### `POST /v1/chat/completions`（便利 API）

`messages` と `chat_template_kwargs`（`target_lang` / `source_lang` / `form` / `context` / `glossary`）を受け取り、アプリ側で PFML3 を組み立てる。
応答は OpenAI Chat 形式（`choices[0].message.content`、ストリーム時は `delta.content`）。

## 拡張機能側の振る舞い（要約）

- 既定バックエンド: **macOS アプリ**（`http://127.0.0.1:18080`）。上級者向けに「llama-server」（既定 `http://127.0.0.1:8080`）、実験的に「ブラウザ内 WASM」。
- 起動していない（接続拒否）→「macOS アプリが起動していません」と表示し、「アプリを起動」ボタンで `plamotranslate://open` を開いてから `/health` をポーリング。
  アプリは `open` で API のオン/オフ設定を変えない。オフに設定されている場合はアプリ側に「API をオンにする」確認を表示し、ユーザーがオンにするまで接続できない（拡張機能はポーリングがタイムアウトしたら「アプリの設定で API をオンにしてください」と案内する）。
- `no_model` →「アプリでモデルをダウンロードしてください」。
- モデルサイズ選択（0.8B / 2B / 8B）は `/v1/models` の `installed` を反映し、変更時に `/v1/models/select` を呼ぶ。未ダウンロードのサイズは選択不可（「アプリでダウンロード」と表示）。
